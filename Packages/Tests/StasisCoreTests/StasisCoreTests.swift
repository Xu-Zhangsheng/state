import Foundation
import StasisContracts
import StasisCore
import Testing

@Test func demandsMergeFieldsAndFastestInterval() async {
    let scheduler = DemandScheduler()
    let first = Demand(consumerID: "a", serviceID: "power", fields: ["battery"], interval: 2, purpose: .visiblePanel)
    let second = Demand(consumerID: "b", serviceID: "power", fields: ["chip"], interval: 1, purpose: .preview)
    await scheduler.submit(first)
    await scheduler.submit(second)
    let merged = await scheduler.effectiveDemand(for: "power")
    #expect(merged?.fields == ["battery", "chip"])
    #expect(merged?.interval == 1)
    await scheduler.cancel(first.id)
    await scheduler.cancel(second.id)
    #expect(await scheduler.effectiveDemand(for: "power") == nil)
}

private actor RecoveryRecorder {
    var resources: [String] = []
    func append(_ value: String) { resources.append(value) }
}

@Test func leaseExpiryRestoresResource() async throws {
    let recorder = RecoveryRecorder()
    let manager = ControlLeaseManager(lifetime: .milliseconds(30)) { resource in
        await recorder.append(resource)
    }
    _ = try await manager.acquire(resourceID: "battery.charging", moduleID: "module", sessionID: UUID())
    try await Task.sleep(for: .milliseconds(80))
    #expect(await recorder.resources == ["battery.charging"])
}

@Test func sleepDoesNotConsumeLeaseLifetime() async throws {
    let recorder = RecoveryRecorder()
    let manager = ControlLeaseManager(lifetime: .milliseconds(50)) { resource in
        await recorder.append(resource)
    }
    _ = try await manager.acquire(resourceID: "battery.charging", moduleID: "module", sessionID: UUID())
    await manager.suspendExpirations()
    try await Task.sleep(for: .milliseconds(90))
    #expect(await recorder.resources.isEmpty)

    await manager.resumeExpirations()
    try await Task.sleep(for: .milliseconds(20))
    #expect(await recorder.resources.isEmpty)
    try await Task.sleep(for: .milliseconds(60))
    #expect(await recorder.resources == ["battery.charging"])
}

@Test func releaseAllRestoresEveryResource() async throws {
    let recorder = RecoveryRecorder()
    let manager = ControlLeaseManager { resource in
        await recorder.append(resource)
    }
    _ = try await manager.acquire(resourceID: "battery.charging", moduleID: "module", sessionID: UUID())
    _ = try await manager.acquire(resourceID: "battery.external-power", moduleID: "module", sessionID: UUID())
    await manager.releaseAll()
    #expect(Set(await recorder.resources) == ["battery.charging", "battery.external-power"])
}

@Test func anotherModuleCannotRenewAControlLease() async throws {
    let manager = ControlLeaseManager()
    let session = UUID()
    let lease = try await manager.acquire(
        resourceID: "battery.charging",
        moduleID: "owner",
        sessionID: session
    )
    await #expect(throws: ControlLeaseError.self) {
        try await manager.renew(
            lease.id,
            resourceID: lease.resourceID,
            moduleID: "intruder",
            sessionID: session
        )
    }
}

@Test func telemetrySequenceGateRejectsRetiredAndOutOfOrderSessions() {
    var gate = TelemetrySequenceGate()
    let firstSession = UUID()
    let secondSession = UUID()
    let start = Date()

    func snapshot(session: UUID, sequence: UInt64, time: Date) -> TelemetrySnapshot {
        TelemetrySnapshot(
            sessionID: session,
            sequence: sequence,
            windowStartedAt: time,
            sampledAt: time,
            metrics: []
        )
    }

    let acceptsFirst = gate.shouldAccept(
        snapshot(session: firstSession, sequence: 1, time: start), serviceID: "power"
    )
    let rejectsDuplicate = !gate.shouldAccept(
        snapshot(session: firstSession, sequence: 1, time: start), serviceID: "power"
    )
    let acceptsSecondSession = gate.shouldAccept(
        snapshot(session: secondSession, sequence: 1, time: start.addingTimeInterval(1)),
        serviceID: "power"
    )
    let rejectsRetiredSession = !gate.shouldAccept(
        snapshot(session: firstSession, sequence: 3, time: start.addingTimeInterval(2)),
        serviceID: "power"
    )
    #expect(acceptsFirst)
    #expect(rejectsDuplicate)
    #expect(acceptsSecondSession)
    #expect(rejectsRetiredSession)

    gate.reset(serviceID: "power")
    let acceptsAfterReset = gate.shouldAccept(
        snapshot(session: firstSession, sequence: 1, time: start),
        serviceID: "power"
    )
    #expect(acceptsAfterReset)
}
