import Foundation
import StasisContracts

public struct ModuleServiceSubscription: Hashable, Sendable {
    public let id: String
    public let serviceID: String

    public init(id: String, serviceID: String) {
        self.id = id
        self.serviceID = serviceID
    }
}

public struct ModuleServiceSnapshot: Sendable {
    public let serviceID: String
    public let snapshot: TelemetrySnapshot

    public init(serviceID: String, snapshot: TelemetrySnapshot) {
        self.serviceID = serviceID
        self.snapshot = snapshot
    }

    /// Returns nil for unrelated notifications and throws for a malformed
    /// service snapshot notification.
    public static func decode(
        method: String,
        parameters: JSONValue?
    ) throws -> ModuleServiceSnapshot? {
        guard method == "services.snapshot" else { return nil }
        guard case .object(let object) = parameters,
              case .string(let serviceID)? = object["serviceID"],
              let encodedSnapshot = object["snapshot"]
        else { throw ModuleServiceClientError.invalidHostResponse }
        return ModuleServiceSnapshot(
            serviceID: serviceID,
            snapshot: try JSONValueCoder.decode(TelemetrySnapshot.self, from: encodedSnapshot)
        )
    }
}

public extension ModuleHostClient {
    func subscribe(
        to serviceID: String,
        fields: Set<String>,
        interval: TimeInterval,
        purpose: DemandPurpose = .visiblePanel,
        subscriptionID: String = UUID().uuidString
    ) async throws -> ModuleServiceSubscription {
        let result = try await request(
            "services.subscribe",
            parameters: .object([
                "serviceID": .string(serviceID),
                "subscriptionID": .string(subscriptionID),
                "fields": .array(fields.sorted().map(JSONValue.string)),
                "interval": .number(interval),
                "purpose": .string(purpose.rawValue),
            ])
        )
        guard case .object(let object) = result,
              case .string(let acceptedID)? = object["subscriptionID"],
              acceptedID == subscriptionID
        else { throw ModuleServiceClientError.invalidHostResponse }
        return ModuleServiceSubscription(id: acceptedID, serviceID: serviceID)
    }

    func unsubscribe(_ subscription: ModuleServiceSubscription) async throws {
        _ = try await request(
            "services.unsubscribe",
            parameters: .object(["subscriptionID": .string(subscription.id)])
        )
    }

    func publish(_ snapshot: TelemetrySnapshot, to serviceID: String) async throws {
        _ = try await request(
            "services.publish",
            parameters: .object([
                "serviceID": .string(serviceID),
                "snapshot": try JSONValueCoder.encode(snapshot),
            ])
        )
    }

    func publishPresentationState(_ state: [String: JSONValue]) async throws {
        _ = try await request(
            "presentation.publishState",
            parameters: .object(["state": .object(state)])
        )
    }
}

public enum ModuleServiceClientError: LocalizedError {
    case invalidHostResponse

    public var errorDescription: String? {
        "The Stasis host returned an invalid service response."
    }
}
