import Foundation

public actor ControlLeaseManager {
    public struct Lease: Identifiable, Sendable {
        public let id: UUID
        public let resourceID: String
        public let moduleID: String
        public let sessionID: UUID
        public var expiresAt: ContinuousClock.Instant
    }

    private var leases: [String: Lease] = [:]
    private let clock = ContinuousClock()
    private let lifetime: Duration
    private var restore: @Sendable (String) async -> Void
    private var suspendedAt: ContinuousClock.Instant?

    public init(
        lifetime: Duration = .seconds(15),
        restore: @escaping @Sendable (String) async -> Void = { _ in }
    ) {
        self.lifetime = lifetime
        self.restore = restore
    }

    public func setRestoreHandler(_ handler: @escaping @Sendable (String) async -> Void) {
        restore = handler
    }

    public func acquire(resourceID: String, moduleID: String, sessionID: UUID) throws -> Lease {
        expireStaleLeases()
        if let current = leases[resourceID], current.moduleID != moduleID {
            throw ControlLeaseError.inUse(current.moduleID)
        }
        let lease = Lease(
            id: UUID(), resourceID: resourceID, moduleID: moduleID, sessionID: sessionID,
            expiresAt: clock.now.advanced(by: lifetime)
        )
        leases[resourceID] = lease
        scheduleExpiry(for: lease)
        return lease
    }

    public func renew(
        _ leaseID: UUID,
        resourceID: String,
        moduleID: String,
        sessionID: UUID
    ) throws -> Lease {
        expireStaleLeases()
        guard var lease = leases[resourceID], lease.id == leaseID,
              lease.moduleID == moduleID, lease.sessionID == sessionID
        else {
            throw ControlLeaseError.invalid
        }
        lease.expiresAt = clock.now.advanced(by: lifetime)
        leases[resourceID] = lease
        scheduleExpiry(for: lease)
        return lease
    }

    public func validate(leaseID: UUID, resourceID: String, moduleID: String, sessionID: UUID) throws {
        expireStaleLeases()
        guard let lease = leases[resourceID], lease.id == leaseID,
              lease.moduleID == moduleID, lease.sessionID == sessionID
        else { throw ControlLeaseError.invalid }
    }

    public func release(_ leaseID: UUID, resourceID: String) async {
        guard let lease = leases[resourceID], lease.id == leaseID else { return }
        leases[resourceID] = nil
        await restore(resourceID)
    }

    public func releaseAll(moduleID: String) async {
        for resource in leases.values.filter({ $0.moduleID == moduleID }).map(\.resourceID) {
            leases[resource] = nil
            await restore(resource)
        }
    }

    /// Releases every control resource. The host calls this before it exits so
    /// a module cannot leave hardware in an overridden state.
    public func releaseAll() async {
        let resources = Array(leases.keys)
        leases.removeAll()
        for resource in resources {
            await restore(resource)
        }
    }

    /// Freezes lease deadlines while macOS is asleep. A sleeping machine is
    /// not evidence that a module stopped renewing its lease.
    public func suspendExpirations() {
        guard suspendedAt == nil else { return }
        suspendedAt = clock.now
    }

    /// Shifts all deadlines by the sleep duration and schedules fresh checks.
    public func resumeExpirations() {
        guard let suspendedAt else { return }
        let sleptFor = suspendedAt.duration(to: clock.now)
        self.suspendedAt = nil
        for resourceID in Array(leases.keys) {
            guard var lease = leases[resourceID] else { continue }
            lease.expiresAt = lease.expiresAt.advanced(by: sleptFor)
            leases[resourceID] = lease
        }
        for lease in leases.values {
            scheduleExpiry(for: lease)
        }
    }

    private func expireStaleLeases() {
        guard suspendedAt == nil else { return }
        for resource in leases.values.filter({ $0.expiresAt <= clock.now }).map(\.resourceID) {
            leases[resource] = nil
            Task { await restore(resource) }
        }
    }

    private func scheduleExpiry(for lease: Lease) {
        Task { [weak self, lifetime] in
            try? await Task.sleep(for: lifetime)
            await self?.expireIfCurrent(lease)
        }
    }

    private func expireIfCurrent(_ expected: Lease) async {
        guard suspendedAt == nil else { return }
        guard let current = leases[expected.resourceID], current.id == expected.id,
              current.expiresAt <= clock.now else { return }
        leases[expected.resourceID] = nil
        await restore(expected.resourceID)
    }
}

public enum ControlLeaseError: LocalizedError {
    case inUse(String)
    case invalid
    public var errorDescription: String? {
        switch self {
        case .inUse(let moduleID): "The control resource is held by \(moduleID)."
        case .invalid: "The control lease is invalid or expired."
        }
    }
}
