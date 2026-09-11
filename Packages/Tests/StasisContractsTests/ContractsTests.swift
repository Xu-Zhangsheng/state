import Foundation
import Testing
@testable import StasisContracts

@Test func unavailableMetricIsNotEncodedAsZero() throws {
    let sample = MetricSample(id: "battery.power", value: nil, unit: "W", source: "test", sampledAt: .now, quality: .unavailable)
    let decoded = try JSONDecoder().decode(MetricSample.self, from: JSONEncoder().encode(sample))
    #expect(decoded.value == nil)
    #expect(decoded.quality == .unavailable)
}

@Test func rpcUsesVersionTwo() throws {
    let request = RPCRequest(id: "1", method: "initialize")
    let decoded = try JSONDecoder().decode(RPCRequest.self, from: JSONEncoder().encode(request))
    #expect(decoded.jsonrpc == "2.0")
}

@Test func descriptorAndPresentationRoundTrip() throws {
    let descriptor = ModuleDescriptor(
        id: "com.example.module",
        version: "1.0.0",
        protocolVersion: "1.0",
        minHostVersion: "0.3.0",
        minOSVersion: "14.8",
        architectures: ["arm64", "x86_64"],
        roles: [.presentation],
        entrypoint: nil,
        provides: [],
        requires: [],
        permissions: [],
        uiCapabilities: ["native.rows.v1"],
        author: "Example",
        license: "MIT",
        settingsVersion: 1,
        displayName: "Example",
        summary: "Example module",
        systemImage: "puzzlepiece.extension",
        settingsAreas: [.panel]
    )
    let decoded = try JSONDecoder().decode(
        ModuleDescriptor.self,
        from: JSONEncoder().encode(descriptor)
    )
    #expect(decoded.id == descriptor.id)

    let presentation = PresentationDescriptor(panel: [
        .init(id: "value", kind: .infoRow, title: "Value", binding: "metric.value")
    ])
    let roundTrip = try JSONDecoder().decode(
        PresentationDescriptor.self,
        from: JSONEncoder().encode(presentation)
    )
    #expect(roundTrip.panel.first?.binding == "metric.value")
}

@Test func serviceCapabilitiesRoundTripAndLegacyDescriptorsRemainCompatible() throws {
    let service = ServiceDescriptor(
        id: "system.power",
        version: "1.0",
        fields: ["battery", "adapter"],
        minimumInterval: 1,
        maximumInterval: 60
    )
    let decoded = try JSONDecoder().decode(
        ServiceDescriptor.self,
        from: JSONEncoder().encode(service)
    )
    #expect(decoded.fields == ["battery", "adapter"])
    #expect(decoded.minimumInterval == 1)
    #expect(decoded.maximumInterval == 60)

    let legacy = try JSONDecoder().decode(
        ServiceDescriptor.self,
        from: Data(#"{"id":"legacy.service","version":"1.0"}"#.utf8)
    )
    #expect(legacy.fields == nil)
    #expect(legacy.minimumInterval == nil)
}

@Test func moduleLocalizationFallsBackFromRegionAndThenToEnglish() {
    let table = ModuleLocalizationTable([
        "en": ["module.name": "Battery"],
        "zh-Hans": ["module.name": "电池"],
        "zh-Hant": ["module.name": "電池"],
    ])
    #expect(table.resolve("module.name", preferredLanguages: ["zh-Hans-CN"]) == "电池")
    #expect(table.resolve("module.name", preferredLanguages: ["fr-FR"]) == "Battery")
    #expect(table.resolve("missing.key", preferredLanguages: ["en-US"]) == "missing.key")
}
