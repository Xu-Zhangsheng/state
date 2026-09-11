import Foundation
import StasisContracts

public actor DemandScheduler {
    public struct EffectiveDemand: Sendable, Equatable {
        public let serviceID: String
        public let fields: Set<String>
        public let interval: TimeInterval
        public let purposes: Set<DemandPurpose>
    }

    private var demands: [UUID: Demand] = [:]
    private var continuations: [UUID: AsyncStream<[EffectiveDemand]>.Continuation] = [:]

    public init() {}

    public func submit(_ demand: Demand) { demands[demand.id] = demand; publish() }
    public func cancel(_ id: UUID) { demands[id] = nil; publish() }
    public func cancel(consumerID: String) {
        demands = demands.filter { $0.value.consumerID != consumerID }
        publish()
    }

    public func effectiveDemand(for serviceID: String) -> EffectiveDemand? {
        Self.merge(demands.values.filter { $0.serviceID == serviceID })
    }

    public func updates() -> AsyncStream<[EffectiveDemand]> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.yield(allEffectiveDemands())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) { continuations[id] = nil }
    private func publish() { continuations.values.forEach { $0.yield(allEffectiveDemands()) } }
    private func allEffectiveDemands() -> [EffectiveDemand] {
        Dictionary(grouping: demands.values, by: \.serviceID).values
            .compactMap(Self.merge)
            .sorted { $0.serviceID < $1.serviceID }
    }

    private static func merge<C: Collection>(_ values: C) -> EffectiveDemand? where C.Element == Demand {
        guard let first = values.first else { return nil }
        return EffectiveDemand(
            serviceID: first.serviceID,
            fields: values.reduce(into: Set<String>()) { $0.formUnion($1.fields) },
            interval: values.map(\.interval).min() ?? first.interval,
            purposes: Set(values.map(\.purpose))
        )
    }
}
