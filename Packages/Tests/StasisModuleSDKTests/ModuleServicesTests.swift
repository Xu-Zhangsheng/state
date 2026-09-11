import Foundation
import StasisContracts
@testable import StasisModuleSDK
import Testing

@Test func serviceSnapshotNotificationDecodesTypedContract() throws {
    let now = Date()
    let source = TelemetrySnapshot(
        sessionID: UUID(),
        sequence: 4,
        windowStartedAt: now,
        sampledAt: now,
        metrics: [.init(
            id: "example.value",
            value: 42.5,
            unit: "percent",
            source: "test",
            sampledAt: now,
            quality: .estimated
        )]
    )
    let decoded = try #require(ModuleServiceSnapshot.decode(
        method: "services.snapshot",
        parameters: .object([
            "serviceID": .string("example.metrics"),
            "snapshot": try JSONValueCoder.encode(source),
        ])
    ))
    #expect(decoded.serviceID == "example.metrics")
    #expect(decoded.snapshot.sequence == 4)
    #expect(decoded.snapshot.metrics.first?.value == 42.5)
}

@Test func unrelatedNotificationIsIgnored() throws {
    let decoded = try ModuleServiceSnapshot.decode(method: "other.event", parameters: nil)
    #expect(decoded == nil)
}
