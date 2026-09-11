import Foundation
import Testing
@testable import stasis_module

@Test func createsAndValidatesTemplate() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try StasisModuleCLI.initialize(at: root)
    let descriptor = try StasisModuleCLI.validate(at: root)
    #expect(descriptor.protocolVersion == "1.0")
    #expect(descriptor.architectures.contains("arm64"))
}

@Test func checksumManifestExcludesItself() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try StasisModuleCLI.initialize(at: root)
    let result = try StasisModuleCLI.checksumManifest(root: root)
    #expect(result["module.json"] != nil)
    #expect(result["checksums.json"] == nil)
}

@Test func rejectsDuplicatePresentationIdentifiers() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try StasisModuleCLI.initialize(at: root)
    let duplicate = """
    {"panel":[
      {"id":"same","kind":"infoRow","title":"One","children":[]},
      {"id":"same","kind":"infoRow","title":"Two","children":[]}
    ],"menuBar":[]}
    """
    try Data(duplicate.utf8).write(to: root.appendingPathComponent("presentation.json"))
    #expect(throws: CLIError.self) { try StasisModuleCLI.validate(at: root) }
}

@Test func rejectsInvalidServiceSamplingRange() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try StasisModuleCLI.initialize(at: root)
    let descriptorURL = root.appendingPathComponent("module.json")
    let original = try String(contentsOf: descriptorURL, encoding: .utf8)
    let invalid = original.replacingOccurrences(
        of: #""provides": []"#,
        with: #""provides": [{"id":"bad","version":"1.0","minimumInterval":5,"maximumInterval":1}]"#
    )
    try Data(invalid.utf8).write(to: descriptorURL)
    #expect(throws: CLIError.self) { try StasisModuleCLI.validate(at: root) }
}

@Test func rejectsOutOfRangeSettingDefault() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try StasisModuleCLI.initialize(at: root)
    let invalid = #"{"version":1,"settings":[{"id":"limit","type":"integer","title":"Limit","area":"feature","defaultValue":120,"minimum":50,"maximum":100,"options":[]}]}"#
    try Data(invalid.utf8).write(to: root.appendingPathComponent("settings.schema.json"))
    #expect(throws: CLIError.self) { try StasisModuleCLI.validate(at: root) }
}

@Test func rejectsInvalidSettingVisibilityReference() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try StasisModuleCLI.initialize(at: root)
    let invalid = #"{"version":1,"settings":[{"id":"detail","type":"boolean","title":"Detail","area":"feature","defaultValue":true,"options":[],"visibleWhen":{"settingID":"missing","equals":true}}]}"#
    try Data(invalid.utf8).write(to: root.appendingPathComponent("settings.schema.json"))
    #expect(throws: CLIError.self) { try StasisModuleCLI.validate(at: root) }
}
