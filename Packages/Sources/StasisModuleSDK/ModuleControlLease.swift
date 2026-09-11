import Foundation
import StasisContracts

/// A typed client for the host's expiring hardware-control lease. Modules must
/// retain this actor for as long as they need control and call `release()` on
/// orderly shutdown. If the worker hangs or exits, renewal stops and the host
/// restores the resource after its fixed lease lifetime.
public actor ModuleControlLease {
    public let leaseID: UUID
    public let resourceID: String
    public let sessionID: UUID

    private let host: ModuleHostClient
    private let renewAfter: TimeInterval
    private var renewalTask: Task<Void, Never>?
    private var released = false

    private init(
        host: ModuleHostClient,
        leaseID: UUID,
        resourceID: String,
        sessionID: UUID,
        renewAfter: TimeInterval
    ) {
        self.host = host
        self.leaseID = leaseID
        self.resourceID = resourceID
        self.sessionID = sessionID
        self.renewAfter = renewAfter
    }

    public static func acquire(
        resourceID: String,
        using host: ModuleHostClient
    ) async throws -> ModuleControlLease {
        let sessionID = UUID()
        let result = try await host.request(
            "control.acquire",
            parameters: .object([
                "resourceID": .string(resourceID),
                "sessionID": .string(sessionID.uuidString),
            ])
        )
        guard case .object(let object) = result,
              case .string(let leaseString)? = object["leaseID"],
              let leaseID = UUID(uuidString: leaseString),
              case .string(let acceptedResource)? = object["resourceID"],
              acceptedResource == resourceID,
              case .string(let acceptedSession)? = object["sessionID"],
              acceptedSession == sessionID.uuidString
        else { throw ModuleControlLeaseError.invalidHostResponse }
        let renewAfter: TimeInterval
        if case .number(let value)? = object["renewAfterSeconds"], value.isFinite, value > 0 {
            renewAfter = value
        } else {
            renewAfter = 5
        }
        let lease = ModuleControlLease(
            host: host,
            leaseID: leaseID,
            resourceID: resourceID,
            sessionID: sessionID,
            renewAfter: renewAfter
        )
        await lease.startRenewing()
        return lease
    }

    public func apply(enabled: Bool) async throws {
        guard !released else { throw ModuleControlLeaseError.released }
        _ = try await host.request(
            "control.apply",
            parameters: leaseParameters.merging(["enabled": .bool(enabled)]) { _, new in new }
                .asJSONValue
        )
    }

    public func release() async throws {
        guard !released else { return }
        released = true
        renewalTask?.cancel()
        renewalTask = nil
        _ = try await host.request("control.release", parameters: leaseParameters.asJSONValue)
    }

    private func startRenewing() {
        renewalTask = Task { [weak self, renewAfter] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(renewAfter))
                guard !Task.isCancelled, let self else { return }
                do {
                    try await self.renew()
                } catch {
                    await self.invalidate()
                    return
                }
            }
        }
    }

    private func renew() async throws {
        guard !released else { throw ModuleControlLeaseError.released }
        _ = try await host.request("control.renew", parameters: leaseParameters.asJSONValue)
    }

    private func invalidate() {
        released = true
        renewalTask?.cancel()
        renewalTask = nil
    }

    private var leaseParameters: [String: JSONValue] {
        [
            "leaseID": .string(leaseID.uuidString),
            "resourceID": .string(resourceID),
            "sessionID": .string(sessionID.uuidString),
        ]
    }
}

public enum ModuleControlLeaseError: LocalizedError {
    case invalidHostResponse
    case released

    public var errorDescription: String? {
        switch self {
        case .invalidHostResponse: "The Stasis host returned an invalid control lease."
        case .released: "The module control lease is no longer active."
        }
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    var asJSONValue: JSONValue { .object(self) }
}
