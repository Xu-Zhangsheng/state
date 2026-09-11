import Foundation
import StasisContracts
import StasisModuleSDK

actor MetricDashboard: StasisModuleWorker {
    private var host: ModuleHostClient?
    private var subscription: ModuleServiceSubscription?

    func connect(to host: ModuleHostClient) async {
        self.host = host
    }

    func initialize(_ parameters: JSONValue?) async throws -> JSONValue? {
        .object(["ready": .bool(true)])
    }

    func updateDemand(_ parameters: JSONValue?) async throws -> JSONValue? {
        guard case .object(let object) = parameters,
              case .string("presentation")? = object["kind"]
        else { return .object(["accepted": .bool(false)]) }
        let isVisible: Bool
        if case .array(let purposes)? = object["purposes"] {
            isVisible = !purposes.isEmpty
        } else {
            isVisible = false
        }
        if isVisible {
            try await startSubscriptionIfNeeded()
        } else {
            await stopSubscription()
        }
        return .object(["accepted": .bool(true)])
    }

    func handleNotification(_ method: String, parameters: JSONValue?) async {
        guard let message = try? ModuleServiceSnapshot.decode(
            method: method,
            parameters: parameters
        ), message.serviceID == "example.metrics",
              let sample = message.snapshot.metrics.first(where: { $0.id == "example.value" })
        else { return }
        let value = sample.value.map { String(format: "%.1f%%", $0) } ?? "—"
        try? await host?.publishPresentationState(["metricValue": .string(value)])
    }

    func deactivate(_ parameters: JSONValue?) async throws -> JSONValue? {
        await stopSubscription()
        return nil
    }

    func shutdown(_ parameters: JSONValue?) async throws -> JSONValue? {
        await stopSubscription()
        return nil
    }

    private func startSubscriptionIfNeeded() async throws {
        guard subscription == nil, let host else { return }
        subscription = try await host.subscribe(
            to: "example.metrics",
            fields: ["example.value"],
            interval: 1,
            purpose: .visiblePanel
        )
    }

    private func stopSubscription() async {
        guard let subscription else { return }
        self.subscription = nil
        try? await host?.unsubscribe(subscription)
    }
}

@main enum MetricDashboardMain {
    static func main() async throws {
        try await ModuleWorkerRunner.run(MetricDashboard())
    }
}
