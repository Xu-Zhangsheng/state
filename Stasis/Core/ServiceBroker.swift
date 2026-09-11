import Foundation

actor ServiceBroker {
    typealias SnapshotHandler = @Sendable (TelemetrySnapshot) async -> Void

    private struct Subscription {
        let serviceID: String
        let consumerID: String
        let handler: SnapshotHandler
    }

    private var providers: [String: String] = [:]
    private var subscriptions: [UUID: Subscription] = [:]
    private var latestSnapshots: [String: TelemetrySnapshot] = [:]
    private var latestSnapshotProviders: [String: String] = [:]
    private var sequenceGate = TelemetrySequenceGate()
    let scheduler: DemandScheduler

    init(scheduler: DemandScheduler) {
        self.scheduler = scheduler
    }

    func register(service: ModuleServiceDeclaration, providerID: String) throws {
        if let existing = providers[service.id], existing != providerID {
            throw ServiceBrokerError.providerConflict(service.id)
        }
        providers[service.id] = providerID
    }

    func unregister(providerID: String) {
        let removedServices = providers.filter { $0.value == providerID }.map(\.key)
        providers = providers.filter { $0.value != providerID }
        for serviceID in removedServices {
            latestSnapshots[serviceID] = nil
            latestSnapshotProviders[serviceID] = nil
            sequenceGate.reset(serviceID: serviceID)
        }
    }

    func synchronizeProviders(_ selection: [String: String]) {
        for (serviceID, previousProvider) in providers
            where selection[serviceID] != previousProvider {
            latestSnapshots[serviceID] = nil
            latestSnapshotProviders[serviceID] = nil
            sequenceGate.reset(serviceID: serviceID)
        }
        providers = selection
        latestSnapshots = latestSnapshots.filter { selection[$0.key] != nil }
        latestSnapshotProviders = latestSnapshotProviders.filter { selection[$0.key] == $0.value }
    }

    func subscribe(demand: ModuleDemand, handler: @escaping SnapshotHandler) async throws -> UUID {
        guard providers[demand.serviceID] != nil else {
            throw ServiceBrokerError.missingProvider(demand.serviceID)
        }
        let id = UUID()
        subscriptions[id] = Subscription(
            serviceID: demand.serviceID,
            consumerID: demand.consumerID,
            handler: handler
        )
        await scheduler.submit(demand)
        if let cached = latestSnapshots[demand.serviceID] {
            await handler(cached)
        }
        return id
    }

    func unsubscribe(_ id: UUID, demandID: UUID) async {
        subscriptions[id] = nil
        await scheduler.cancel(demandID)
    }

    func publish(_ snapshot: TelemetrySnapshot, serviceID: String, providerID: String) async throws {
        guard providers[serviceID] == providerID else {
            throw ServiceBrokerError.unauthorizedPublisher(serviceID)
        }
        guard sequenceGate.shouldAccept(snapshot, serviceID: serviceID) else { return }
        latestSnapshots[serviceID] = snapshot
        latestSnapshotProviders[serviceID] = providerID
        let handlers = subscriptions.values
            .filter { $0.serviceID == serviceID }
            .map(\.handler)
        for handler in handlers { await handler(snapshot) }
    }
}

enum ServiceBrokerError: LocalizedError {
    case providerConflict(String)
    case unauthorizedPublisher(String)
    case missingProvider(String)

    var errorDescription: String? {
        switch self {
        case .providerConflict(let id): return "More than one provider registered for \(id)."
        case .unauthorizedPublisher(let id): return "The process is not the provider for \(id)."
        case .missingProvider(let id): return "No active module provides \(id)."
        }
    }
}
