import Foundation
import StasisContracts
import StasisModuleSDK

actor MetricProvider: StasisModuleWorker {
    private var host: ModuleHostClient?
    private let sessionID = UUID()
    private var sequence: UInt64 = 0
    private var samplingTask: Task<Void, Never>?
    private var samplingInterval: TimeInterval?

    func connect(to host: ModuleHostClient) async { self.host = host }
    func initialize(_ parameters: JSONValue?) async throws -> JSONValue? { .object(["ready": .bool(true)]) }

    func updateDemand(_ parameters: JSONValue?) async throws -> JSONValue? {
        guard case .object(let demand) = parameters,
              case .string("service")? = demand["kind"],
              case .string("example.metrics")? = demand["serviceID"]
        else { return .object(["accepted": .bool(false)]) }
        if case .bool(false)? = demand["active"] {
            stopSampling()
            return .object(["accepted": .bool(true)])
        }
        let interval: TimeInterval
        if case .number(let requested)? = demand["interval"] {
            interval = min(60, max(0.5, requested))
        } else {
            interval = 1
        }
        if samplingInterval != interval || samplingTask == nil {
            stopSampling()
            samplingInterval = interval
            samplingTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.publishSample()
                    try? await Task.sleep(for: .seconds(interval))
                }
            }
        }
        return .object(["accepted": .bool(true), "interval": .number(interval)])
    }

    func deactivate(_ parameters: JSONValue?) async throws -> JSONValue? {
        stopSampling()
        return nil
    }

    func shutdown(_ parameters: JSONValue?) async throws -> JSONValue? {
        stopSampling()
        return nil
    }

    private func stopSampling() {
        samplingTask?.cancel()
        samplingTask = nil
        samplingInterval = nil
    }

    private func publishSample() async {
        guard let host else { return }
        sequence &+= 1
        let now = Date()
        let snapshot = TelemetrySnapshot(
            sessionID: sessionID,
            sequence: sequence,
            windowStartedAt: now,
            sampledAt: now,
            metrics: [MetricSample(
                id: "example.value",
                value: Double.random(in: 0...100),
                unit: "percent",
                source: "example",
                sampledAt: now,
                quality: .estimated
            )]
        )
        try? await host.publish(snapshot, to: "example.metrics")
    }
}

@main enum MetricProviderMain {
    static func main() async throws { try await ModuleWorkerRunner.run(MetricProvider()) }
}
