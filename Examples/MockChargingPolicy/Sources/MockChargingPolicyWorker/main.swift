import Foundation
import StasisContracts
import StasisModuleSDK

actor MockChargingPolicy: StasisModuleWorker {
    private var host: ModuleHostClient?
    func connect(to host: ModuleHostClient) async { self.host = host }

    func initialize(_ parameters: JSONValue?) async throws -> JSONValue? {
        guard let host else { return nil }
        _ = try await host.request("settings.read")
        return .object(["mode": .string("simulation")])
    }

    func activate(_ parameters: JSONValue?) async throws -> JSONValue? {
        try await publish(status: "Ready")
        return nil
    }

    func handleAction(_ parameters: JSONValue?) async throws -> JSONValue? {
        try await publish(status: "Simulated")
        return .object(["accepted": .bool(true)])
    }

    func validateConfigurationPatch(_ parameters: JSONValue?) async throws -> JSONValue? {
        guard case .object(let request) = parameters,
              case .object(let patch) = request["patch"]
        else {
            return .object([
                "accepted": .bool(false),
                "message": .string("Invalid settings request."),
            ])
        }
        if case .number(let target) = patch["target"], target == 95 {
            return .object([
                "accepted": .bool(false),
                "message": .string("The simulated policy reserves 95% for its validation example."),
            ])
        }
        return .object(["accepted": .bool(true)])
    }

    private func publish(status: String) async throws {
        guard let host else { return }
        _ = try await host.request("presentation.publishState", parameters: .object([
            "state": .object(["status": .string(status)])
        ]))
    }
}

@main enum MockChargingPolicyMain {
    static func main() async throws { try await ModuleWorkerRunner.run(MockChargingPolicy()) }
}
