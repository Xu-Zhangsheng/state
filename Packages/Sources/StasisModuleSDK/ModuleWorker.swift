import Foundation
import StasisContracts

public protocol StasisModuleWorker: Sendable {
    func connect(to host: ModuleHostClient) async
    func initialize(_ parameters: JSONValue?) async throws -> JSONValue?
    func activate(_ parameters: JSONValue?) async throws -> JSONValue?
    func updateDemand(_ parameters: JSONValue?) async throws -> JSONValue?
    func handleNotification(_ method: String, parameters: JSONValue?) async
    func validateConfigurationPatch(_ parameters: JSONValue?) async throws -> JSONValue?
    func configurationChanged(_ parameters: JSONValue?) async throws -> JSONValue?
    func handleAction(_ parameters: JSONValue?) async throws -> JSONValue?
    func deactivate(_ parameters: JSONValue?) async throws -> JSONValue?
    func shutdown(_ parameters: JSONValue?) async throws -> JSONValue?
}

public actor ModuleHostClient {
    private var pending: [String: CheckedContinuation<JSONValue?, Error>] = [:]
    private let writer: MessageWriter

    fileprivate init(writer: MessageWriter) {
        self.writer = writer
    }

    public func request(_ method: String, parameters: JSONValue? = nil) async throws -> JSONValue? {
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try writer.write(RPCRequest(id: id, method: method, params: parameters))
            } catch {
                pending[id] = nil
                continuation.resume(throwing: error)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                await self?.timeOut(id)
            }
        }
    }

    public func reportTaskProgress(
        taskID: String,
        title: String,
        detail: String? = nil,
        progress: Double? = nil
    ) async throws {
        var values: [String: JSONValue] = [
            "taskID": .string(taskID),
            "title": .string(title),
        ]
        if let detail { values["detail"] = .string(detail) }
        if let progress { values["progress"] = .number(progress) }
        _ = try await request("tasks.reportProgress", parameters: .object(values))
    }

    public func finishTask(
        taskID: String,
        state: ModuleTaskState,
        detail: String? = nil
    ) async throws {
        var values: [String: JSONValue] = [
            "taskID": .string(taskID),
            "state": .string(state.rawValue),
        ]
        if let detail { values["detail"] = .string(detail) }
        _ = try await request("tasks.finish", parameters: .object(values))
    }

    fileprivate func receive(_ response: RPCResponse) {
        guard let continuation = pending.removeValue(forKey: response.id) else { return }
        if let error = response.error {
            continuation.resume(throwing: ModuleHostError.remote(code: error.code, message: error.message))
        } else {
            continuation.resume(returning: response.result)
        }
    }

    fileprivate func close() {
        pending.values.forEach { $0.resume(throwing: ModuleHostError.disconnected) }
        pending.removeAll()
    }

    private func timeOut(_ id: String) {
        pending.removeValue(forKey: id)?.resume(throwing: ModuleHostError.timeout)
    }
}

public enum ModuleWorkerRunner {
    public static func run(_ worker: any StasisModuleWorker) async throws {
        let writer = MessageWriter()
        let host = ModuleHostClient(writer: writer)
        let dispatcher = WorkerDispatcher(worker: worker, writer: writer)
        await worker.connect(to: host)

        let decoder = JSONDecoder()
        var line = Data()
        for try await byte in FileHandle.standardInput.bytes {
            if byte != 0x0A {
                line.append(byte)
                guard line.count <= 1_048_576 else { throw WorkerError.messageTooLarge }
                continue
            }
            guard !line.isEmpty else { continue }
            let data = line
            line.removeAll(keepingCapacity: true)
            let envelope = try decoder.decode(MessageEnvelope.self, from: data)
            if let method = envelope.method {
                if envelope.id != nil,
                   let request = try? decoder.decode(RPCRequest.self, from: data) {
                    await dispatcher.enqueue(.request(request))
                } else {
                    await dispatcher.enqueue(.notification(method, envelope.params))
                }
            } else if envelope.id != nil,
                      let response = try? decoder.decode(RPCResponse.self, from: data) {
                await host.receive(response)
            }
        }
        await host.close()
    }
}

private actor WorkerDispatcher {
    enum Incoming: Sendable {
        case request(RPCRequest)
        case notification(String, JSONValue?)
    }

    let worker: any StasisModuleWorker
    let writer: MessageWriter
    private var queue: [Incoming] = []
    private var isDraining = false

    init(worker: any StasisModuleWorker, writer: MessageWriter) {
        self.worker = worker
        self.writer = writer
    }

    func enqueue(_ incoming: Incoming) {
        queue.append(incoming)
        guard !isDraining else { return }
        isDraining = true
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let incoming = queue.removeFirst()
            switch incoming {
            case .request(let request):
                await handle(request)
            case .notification(let method, let parameters):
                await worker.handleNotification(method, parameters: parameters)
            }
        }
        isDraining = false
    }

    private func handle(_ request: RPCRequest) async {
        do {
            let result: JSONValue?
            switch request.method {
            case "initialize": result = try await worker.initialize(request.params)
            case "activate": result = try await worker.activate(request.params)
            case "updateDemand": result = try await worker.updateDemand(request.params)
            case "validateConfigurationPatch":
                result = try await worker.validateConfigurationPatch(request.params)
            case "configurationChanged": result = try await worker.configurationChanged(request.params)
            case "handleAction": result = try await worker.handleAction(request.params)
            case "deactivate": result = try await worker.deactivate(request.params)
            case "shutdown": result = try await worker.shutdown(request.params)
            default: throw WorkerError.unknownMethod(request.method)
            }
            try writer.write(RPCResponse(id: request.id, result: result))
        } catch {
            try? writer.write(
                RPCResponse(
                    id: request.id,
                    error: .init(code: -32000, message: error.localizedDescription)
                )
            )
        }
    }
}

private final class MessageWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let encoder = JSONEncoder()

    func write<T: Encodable>(_ message: T) throws {
        var data = try encoder.encode(message)
        guard data.count <= 1_048_576 else { throw WorkerError.messageTooLarge }
        data.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        try FileHandle.standardOutput.write(contentsOf: data)
    }
}

private struct MessageEnvelope: Decodable {
    let id: String?
    let method: String?
    let params: JSONValue?
}

public enum ModuleHostError: LocalizedError {
    case remote(code: Int, message: String)
    case timeout
    case disconnected

    public var errorDescription: String? {
        switch self {
        case .remote(_, let message): message
        case .timeout: "The Stasis host did not respond in time."
        case .disconnected: "The Stasis host connection closed."
        }
    }
}

public enum WorkerError: LocalizedError {
    case unknownMethod(String)
    case messageTooLarge

    public var errorDescription: String? {
        switch self {
        case .unknownMethod(let method): "Unknown method: \(method)"
        case .messageTooLarge: "The module message exceeds 1 MiB."
        }
    }
}

public extension StasisModuleWorker {
    func connect(to host: ModuleHostClient) async {}
    func activate(_ parameters: JSONValue?) async throws -> JSONValue? { nil }
    func updateDemand(_ parameters: JSONValue?) async throws -> JSONValue? { nil }
    func handleNotification(_ method: String, parameters: JSONValue?) async {}
    func validateConfigurationPatch(_ parameters: JSONValue?) async throws -> JSONValue? { nil }
    func configurationChanged(_ parameters: JSONValue?) async throws -> JSONValue? { nil }
    func handleAction(_ parameters: JSONValue?) async throws -> JSONValue? { nil }
    func deactivate(_ parameters: JSONValue?) async throws -> JSONValue? { nil }
    func shutdown(_ parameters: JSONValue?) async throws -> JSONValue? { nil }
}
