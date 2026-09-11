import Foundation
import StasisContracts

/// Rejects duplicate, out-of-order and retired-session telemetry before it can
/// replace the host's visible cache. The gate is service-scoped and is reset
/// whenever the selected provider changes.
public struct TelemetrySequenceGate: Sendable {
    private struct State: Sendable {
        var sessionID: UUID
        var sequence: UInt64
        var sampledAt: Date
        var retiredSessions: Set<UUID>
    }

    private var states: [String: State] = [:]

    public init() {}

    public mutating func shouldAccept(
        _ snapshot: TelemetrySnapshot,
        serviceID: String
    ) -> Bool {
        guard var current = states[serviceID] else {
            states[serviceID] = State(
                sessionID: snapshot.sessionID,
                sequence: snapshot.sequence,
                sampledAt: snapshot.sampledAt,
                retiredSessions: []
            )
            return true
        }

        if current.sessionID == snapshot.sessionID {
            guard snapshot.sequence > current.sequence else { return false }
        } else {
            guard !current.retiredSessions.contains(snapshot.sessionID),
                  snapshot.sampledAt >= current.sampledAt
            else { return false }
            current.retiredSessions.insert(current.sessionID)
            current.sessionID = snapshot.sessionID
        }
        current.sequence = snapshot.sequence
        current.sampledAt = snapshot.sampledAt
        states[serviceID] = current
        return true
    }

    public mutating func reset(serviceID: String) {
        states[serviceID] = nil
    }
}
