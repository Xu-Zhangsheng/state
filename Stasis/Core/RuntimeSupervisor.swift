import Foundation
import os

@MainActor
final class RuntimeSupervisor {
    typealias HostRequestHandler = @Sendable (
        _ moduleID: String,
        _ method: String,
        _ parameters: JSONValue?
    ) async throws -> JSONValue?
    typealias TerminationHandler = @Sendable (_ moduleID: String) async -> Void

    private final class Worker {
        let process: Process
        let input: FileHandle
        let output: FileHandle
        var pending: [String: CheckedContinuation<JSONRPCResponse, Error>] = [:]
        var readTask: Task<Void, Never>?
        var errorReadTask: Task<Void, Never>?

        init(process: Process, input: FileHandle, output: FileHandle) {
            self.process = process
            self.input = input
            self.output = output
        }
    }

    private var workers: [String: Worker] = [:]
    private let logger = Logger(subsystem: "com.srimanachanta.stasis", category: "ModuleRuntime")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var hostRequestHandler: HostRequestHandler?
    private var terminationHandler: TerminationHandler?

    func setHostRequestHandler(_ handler: @escaping HostRequestHandler) {
        hostRequestHandler = handler
    }

    func setTerminationHandler(_ handler: @escaping TerminationHandler) {
        terminationHandler = handler
    }

    func isRunning(moduleID: String) -> Bool {
        workers[moduleID]?.process.isRunning == true
    }

    func start(module: InstalledModule, executableURL: URL) throws {
        guard workers[module.id] == nil else { return }
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        try process.run()

        let worker = Worker(
            process: process,
            input: inputPipe.fileHandleForWriting,
            output: outputPipe.fileHandleForReading
        )
        workers[module.id] = worker
        worker.readTask = Task { [weak self, weak worker] in
            guard let self, let worker else { return }
            await self.readMessages(moduleID: module.id, worker: worker)
        }
        worker.errorReadTask = Task { [weak self] in
            do {
                for try await line in errorPipe.fileHandleForReading.bytes.lines {
                    guard !Task.isCancelled else { return }
                    self?.logger.info("Worker \(module.id, privacy: .public): \(line, privacy: .public)")
                }
            } catch {
                self?.logger.error("Worker \(module.id, privacy: .public) log pipe failed: \(error.localizedDescription)")
            }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.workerDidTerminate(module.id) }
        }
    }

    func request(moduleID: String, method: String, params: JSONValue?) async throws -> JSONRPCResponse {
        guard let worker = workers[moduleID], worker.process.isRunning else {
            throw RuntimeSupervisorError.notRunning
        }
        let id = UUID().uuidString
        let request = JSONRPCRequest(id: id, method: method, params: params)
        var data = try encoder.encode(request)
        guard data.count <= 1_048_576 else { throw RuntimeSupervisorError.messageTooLarge }
        data.append(0x0A)
        let response: JSONRPCResponse = try await withCheckedThrowingContinuation { continuation in
            worker.pending[id] = continuation
            do {
                try worker.input.write(contentsOf: data)
            } catch {
                worker.pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
                return
            }
            Task { @MainActor [weak worker] in
                try? await Task.sleep(for: .seconds(5))
                worker?.pending.removeValue(forKey: id)?.resume(
                    throwing: RuntimeSupervisorError.timeout
                )
            }
        }
        if let error = response.error {
            throw RuntimeSupervisorError.remote(code: error.code, message: error.message)
        }
        return response
    }

    func notify(moduleID: String, method: String, params: JSONValue?) throws {
        guard let worker = workers[moduleID], worker.process.isRunning else {
            throw RuntimeSupervisorError.notRunning
        }
        var data = try encoder.encode(JSONRPCNotification(method: method, params: params))
        guard data.count <= 1_048_576 else { throw RuntimeSupervisorError.messageTooLarge }
        data.append(0x0A)
        try worker.input.write(contentsOf: data)
    }

    func stop(moduleID: String) {
        guard let worker = workers.removeValue(forKey: moduleID) else { return }
        worker.readTask?.cancel()
        worker.errorReadTask?.cancel()
        try? worker.input.close()
        if worker.process.isRunning { worker.process.terminate() }
        worker.pending.values.forEach { $0.resume(throwing: RuntimeSupervisorError.terminated) }
        worker.pending.removeAll()
    }

    func stopAll() {
        Array(workers.keys).forEach(stop)
    }

    private func readMessages(moduleID: String, worker: Worker) async {
        do {
            var line = Data()
            for try await byte in worker.output.bytes {
                if byte != 0x0A {
                    line.append(byte)
                    guard line.count <= 1_048_576 else {
                        throw RuntimeSupervisorError.messageTooLarge
                    }
                    continue
                }
                guard !line.isEmpty else { continue }
                let data = line
                line.removeAll(keepingCapacity: true)
                let envelope = try decoder.decode(JSONRPCEnvelope.self, from: data)
                if let method = envelope.method {
                    guard let requestID = envelope.id else { continue }
                    await handleHostRequest(
                        moduleID: moduleID,
                        requestID: requestID,
                        method: method,
                        params: envelope.params,
                        worker: worker
                    )
                } else if let responseID = envelope.id {
                    let response = try decoder.decode(JSONRPCResponse.self, from: data)
                    worker.pending.removeValue(forKey: responseID)?.resume(returning: response)
                }
            }
        } catch {
            logger.error("Worker \(moduleID) output failed: \(error.localizedDescription)")
            if worker.process.isRunning { worker.process.terminate() }
        }
        if worker.process.isRunning { worker.process.terminate() }
    }

    private func handleHostRequest(
        moduleID: String,
        requestID: String,
        method: String,
        params: JSONValue?,
        worker: Worker
    ) async {
        let response: JSONRPCResponse
        do {
            guard let hostRequestHandler else { throw RuntimeSupervisorError.unsupportedHostMethod }
            let result = try await hostRequestHandler(moduleID, method, params)
            response = JSONRPCResponse(id: requestID, result: result)
        } catch {
            response = JSONRPCResponse(
                id: requestID,
                error: .init(code: -32000, message: error.localizedDescription, data: nil)
            )
        }
        do {
            var data = try encoder.encode(response)
            guard data.count <= 1_048_576 else { throw RuntimeSupervisorError.messageTooLarge }
            data.append(0x0A)
            try worker.input.write(contentsOf: data)
        } catch {
            logger.error("Could not answer worker \(moduleID): \(error.localizedDescription)")
        }
    }

    private func workerDidTerminate(_ moduleID: String) {
        guard let worker = workers.removeValue(forKey: moduleID) else { return }
        worker.readTask?.cancel()
        worker.errorReadTask?.cancel()
        worker.pending.values.forEach { $0.resume(throwing: RuntimeSupervisorError.terminated) }
        if let terminationHandler {
            Task { await terminationHandler(moduleID) }
        }
    }
}

private struct JSONRPCEnvelope: Decodable {
    let id: String?
    let method: String?
    let params: JSONValue?
}

private struct JSONRPCNotification: Encodable {
    let jsonrpc = "2.0"
    let method: String
    let params: JSONValue?
}

enum RuntimeSupervisorError: LocalizedError {
    case notRunning
    case timeout
    case terminated
    case messageTooLarge
    case unsupportedHostMethod
    case remote(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .notRunning: return "The module process is not running."
        case .timeout: return "The module process did not respond in time."
        case .terminated: return "The module process exited."
        case .messageTooLarge: return "The module message exceeds 1 MiB."
        case .unsupportedHostMethod: return "The module called an unsupported host method."
        case .remote(_, let message): return "The module rejected the request: \(message)"
        }
    }
}
