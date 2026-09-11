import CryptoKit
import Darwin
import Foundation
import StasisContracts

typealias Descriptor = ModuleDescriptor

enum CLIError: LocalizedError {
    case usage
    case missing(String)
    case invalid(String)
    var errorDescription: String? {
        switch self {
        case .usage: "Usage: stasis-module <init|validate|dev|test|package> [path]"
        case .missing(let value): "Missing required file: \(value)"
        case .invalid(let value): value
        }
    }
}

@main
enum StasisModuleCLI {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else { throw CLIError.usage }
        let url = URL(fileURLWithPath: arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
        switch command {
        case "init": try initialize(at: url)
        case "validate": _ = try validate(at: url); print("Module is valid")
        case "dev":
            let descriptor = try validate(at: url)
            try runLifecycleTest(for: descriptor, at: url)
            print("Development host completed a live lifecycle check for \(descriptor.id) \(descriptor.version)")
        case "test":
            let descriptor = try validate(at: url)
            try runLifecycleTest(for: descriptor, at: url)
            print("Contract and lifecycle checks passed")
        case "package": try package(at: url)
        default: throw CLIError.usage
        }
    }

    static func initialize(at root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = "com.example.stasis-module"
        let module = """
        {
          "id": "\(id)", "version": "0.1.0", "protocolVersion": "1.0",
          "minHostVersion": "1.0.0-beta.1", "minOSVersion": "14.8",
          "architectures": ["arm64"], "roles": ["presentation"],
          "entrypoint": null, "provides": [], "requires": [], "permissions": [],
          "uiCapabilities": ["native.rows.v1"], "author": "Your Name",
          "license": "MIT", "settingsVersion": 1, "displayName": "Example Module",
          "summary": "A declaration-only example.", "systemImage": "puzzlepiece.extension",
          "settingsAreas": ["general", "panel"]
        }
        """
        let presentation = """
        {"panel":[{"id":"status","kind":"infoRow","title":"Example","systemImage":"sparkles","value":"Ready","actionID":null,"children":[]}],"menuBar":[]}
        """
        let settings = "{\"version\":1,\"settings\":[]}"
        try write(module, to: root.appendingPathComponent("module.json"))
        try write(presentation, to: root.appendingPathComponent("presentation.json"))
        try write(settings, to: root.appendingPathComponent("settings.schema.json"))
        print("Created module template at \(root.path)")
    }

    @discardableResult
    static func validate(at root: URL) throws -> Descriptor {
        let descriptorURL = root.appendingPathComponent("module.json")
        guard FileManager.default.fileExists(atPath: descriptorURL.path) else { throw CLIError.missing("module.json") }
        for name in ["presentation.json", "settings.schema.json"] {
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) else { throw CLIError.missing(name) }
        }
        let data = try Data(contentsOf: descriptorURL)
        let descriptor = try JSONDecoder().decode(Descriptor.self, from: data)
        guard descriptor.id.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]+$"#, options: .regularExpression) != nil else {
            throw CLIError.invalid("Invalid module ID")
        }
        guard descriptor.protocolVersion.hasPrefix("1.") else { throw CLIError.invalid("Unsupported protocol") }
        guard descriptor.version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$"#, options: .regularExpression) != nil else {
            throw CLIError.invalid("Module version must use semantic versioning")
        }
        guard !descriptor.architectures.isEmpty,
              descriptor.architectures.allSatisfy({ $0 == "arm64" || $0 == "x86_64" })
        else { throw CLIError.invalid("Unsupported architecture declaration") }

        let presentation = try JSONDecoder().decode(
            PresentationDescriptor.self,
            from: Data(contentsOf: root.appendingPathComponent("presentation.json"))
        )
        let schema = try JSONDecoder().decode(
            SettingsSchema.self,
            from: Data(contentsOf: root.appendingPathComponent("settings.schema.json"))
        )
        guard schema.version == descriptor.settingsVersion else {
            throw CLIError.invalid("Settings schema version does not match module.json")
        }
        try validatePresentation(presentation)
        try validateSettings(schema)
        let localizationURL = root.appendingPathComponent("Resources/localizations.json")
        if FileManager.default.fileExists(atPath: localizationURL.path) {
            let table = try JSONDecoder().decode(
                ModuleLocalizationTable.self,
                from: Data(contentsOf: localizationURL)
            )
            try validateLocalizations(table)
        }

        let supportedCapabilities = Set([
            "native.rows.v1", "native.settings.v1", "settings.validation.v1",
        ])
        guard Set(descriptor.uiCapabilities).isSubset(of: supportedCapabilities) else {
            throw CLIError.invalid("The module requests an unsupported native UI capability")
        }
        let supportedPermissions = Set(["hardware.control", "notifications"])
        guard Set(descriptor.permissions).isSubset(of: supportedPermissions) else {
            throw CLIError.invalid("The module requests an unsupported core permission")
        }
        if descriptor.roles.contains(.control), !descriptor.permissions.contains("hardware.control") {
            throw CLIError.invalid("A control module must declare hardware.control")
        }
        if !descriptor.roles.isDisjoint(with: [.data, .business, .control]), descriptor.entrypoint == nil {
            throw CLIError.invalid("Data, business and control modules require a worker entrypoint")
        }
        guard Set(descriptor.provides.map(\.id)).count == descriptor.provides.count,
              Set(descriptor.requires.map(\.serviceID)).count == descriptor.requires.count
        else { throw CLIError.invalid("Service declarations must be unique") }
        for service in descriptor.provides {
            guard !service.id.isEmpty, !service.version.isEmpty,
                  service.fields?.allSatisfy({ !$0.isEmpty }) != false,
                  service.minimumInterval.map({ $0.isFinite && $0 > 0 }) != false,
                  service.maximumInterval.map({ $0.isFinite && $0 > 0 }) != false
            else { throw CLIError.invalid("Invalid service capability for \(service.id)") }
            if let minimum = service.minimumInterval,
               let maximum = service.maximumInterval,
               minimum > maximum {
                throw CLIError.invalid("Invalid sampling interval range for \(service.id)")
            }
        }
        if let entrypoint = descriptor.entrypoint {
            guard !entrypoint.hasPrefix("/"), !entrypoint.contains("..") else { throw CLIError.invalid("Unsafe entrypoint") }
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent(entrypoint).path) else {
                throw CLIError.missing(entrypoint)
            }
            guard FileManager.default.isExecutableFile(atPath: root.appendingPathComponent(entrypoint).path) else {
                throw CLIError.invalid("Worker entrypoint is not executable")
            }
        }
        return descriptor
    }

    private static func validatePresentation(_ presentation: PresentationDescriptor) throws {
        var identifiers = Set<String>()
        func visit(_ component: PresentationComponent) throws {
            guard !component.id.isEmpty, identifiers.insert(component.id).inserted else {
                throw CLIError.invalid("Presentation component IDs must be non-empty and unique")
            }
            if let symbol = component.systemImage,
               symbol.range(of: #"^[A-Za-z0-9.]+$"#, options: .regularExpression) == nil {
                throw CLIError.invalid("Invalid SF Symbol name in presentation")
            }
            try component.children.forEach(visit)
        }
        try (presentation.panel + presentation.menuBar).forEach(visit)
    }

    private static func validateSettings(_ schema: SettingsSchema) throws {
        guard schema.version >= 1,
              schema.settings.allSatisfy({ !$0.id.isEmpty }),
              Set(schema.settings.map(\.id)).count == schema.settings.count
        else {
            throw CLIError.invalid("Setting IDs must be unique")
        }
        let definitions = Dictionary(uniqueKeysWithValues: schema.settings.map { ($0.id, $0) })
        for setting in schema.settings {
            if let condition = setting.visibleWhen {
                guard condition.settingID != setting.id,
                      let source = definitions[condition.settingID],
                      settingValue(condition.equals, matches: source)
                else { throw CLIError.invalid("Invalid visibility condition for setting \(setting.id)") }
            }
            if let minimum = setting.minimum, let maximum = setting.maximum, minimum > maximum {
                throw CLIError.invalid("Invalid range for setting \(setting.id)")
            }
            if let step = setting.step, step <= 0 {
                throw CLIError.invalid("Invalid step for setting \(setting.id)")
            }
            if case .choice = setting.type {
                guard !setting.options.isEmpty,
                      Set(setting.options.map(\.value)).count == setting.options.count
                else { throw CLIError.invalid("Invalid choices for setting \(setting.id)") }
            } else if !setting.options.isEmpty {
                throw CLIError.invalid("Only choice settings may declare options")
            }
            switch (setting.type, setting.defaultValue) {
            case (.boolean, .bool), (.string, .string): break
            case (.integer, .number(let value)) where
                value.rounded() == value && valueIsInRange(value, setting): break
            case (.number, .number(let value)) where valueIsInRange(value, setting): break
            case (.choice, .string(let value)) where setting.options.contains(where: { $0.value == value }): break
            default: throw CLIError.invalid("Invalid default value for setting \(setting.id)")
            }
        }
    }

    private static func settingValue(_ value: JSONValue, matches definition: SettingDefinition) -> Bool {
        switch (definition.type, value) {
        case (.boolean, .bool), (.string, .string): return true
        case (.integer, .number(let number)): return number.isFinite && number.rounded() == number
        case (.number, .number(let number)): return number.isFinite
        case (.choice, .string(let selected)):
            return definition.options.contains { $0.value == selected }
        default: return false
        }
    }

    private static func valueIsInRange(_ value: Double, _ setting: SettingDefinition) -> Bool {
        guard value.isFinite else { return false }
        if let minimum = setting.minimum, value < minimum { return false }
        if let maximum = setting.maximum, value > maximum { return false }
        return true
    }

    private static func validateLocalizations(_ table: ModuleLocalizationTable) throws {
        guard table.values.keys.allSatisfy({ !$0.isEmpty && $0.count <= 64 }),
              table.values.values.allSatisfy({ dictionary in
                  dictionary.keys.allSatisfy { !$0.isEmpty && $0.count <= 256 }
                      && dictionary.values.allSatisfy { $0.count <= 4_096 }
              })
        else { throw CLIError.invalid("Invalid module localization resources") }
    }

    private static func runLifecycleTest(for descriptor: Descriptor, at root: URL) throws {
        guard let entrypoint = descriptor.entrypoint else { return }
        let executable = root.appendingPathComponent(entrypoint)
        let host = LifecycleTestHost(executable: executable)
        try host.start()
        defer { host.stop() }
        try host.request("initialize", params: [
            "protocolVersion": "1.0",
            "locale": "en",
            "sessionID": UUID().uuidString,
            "configuration": ["schemaVersion": descriptor.settingsVersion, "revision": 0, "values": [:]],
            "hostCapabilities": [
                "services.v1", "settings.v1", "settings.validation.v1",
                "presentation.v1", "control-leases.v1",
            ],
        ])
        try host.request("activate")
        if descriptor.uiCapabilities.contains("settings.validation.v1") {
            try host.request("validateConfigurationPatch", params: [
                "expectedRevision": 0,
                "schemaVersion": descriptor.settingsVersion,
                "currentValues": [:],
                "patch": [:],
            ])
        }
        if descriptor.roles.contains(.presentation) {
            try host.request("updateDemand", params: [
                "kind": "presentation",
                "purposes": ["visiblePanel"],
                "visibleComponentIDs": [],
            ])
        }
        if let service = descriptor.provides.first {
            try host.request("updateDemand", params: [
                "kind": "service",
                "active": true,
                "serviceID": service.id,
                "fields": Array(service.fields ?? []),
                "interval": service.minimumInterval ?? 1,
            ])
            try host.request("updateDemand", params: [
                "kind": "service",
                "active": false,
                "serviceID": service.id,
                "fields": [],
            ])
        }
        if descriptor.roles.contains(.presentation) {
            try host.request("updateDemand", params: [
                "kind": "presentation",
                "purposes": [],
                "visibleComponentIDs": [],
            ])
        }
        try host.request("deactivate")
        try host.request("shutdown")
    }

    static func package(at root: URL) throws {
        let descriptor = try validate(at: root)
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("stasis-module-\(UUID().uuidString)", isDirectory: true)
        let payload = temporaryRoot.appendingPathComponent(descriptor.id, isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        for name in ["module.json", "presentation.json", "settings.schema.json", "Resources"] {
            let source = root.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try FileManager.default.copyItem(at: source, to: payload.appendingPathComponent(name))
        }
        if let entrypoint = descriptor.entrypoint {
            let topLevelName = entrypoint.split(separator: "/").first.map(String.init) ?? entrypoint
            let source = root.appendingPathComponent(topLevelName)
            let destination = payload.appendingPathComponent(topLevelName)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: source, to: destination)
            }
        }

        let checksums = try checksumManifest(root: payload)
        let manifest = try JSONSerialization.data(withJSONObject: checksums, options: [.prettyPrinted, .sortedKeys])
        try manifest.write(to: payload.appendingPathComponent("checksums.json"), options: .atomic)
        let destination = root.deletingLastPathComponent().appendingPathComponent("\(descriptor.id)-\(descriptor.version).stasismodule")
        try? FileManager.default.removeItem(at: destination)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", payload.path, destination.path]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CLIError.invalid("Packaging failed") }
        print("Created \(destination.path)")
    }

    static func checksumManifest(root: URL) throws -> [String: String] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            throw CLIError.invalid("Cannot read module directory")
        }
        var result: [String: String] = [:]
        for case let url as URL in enumerator {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
                throw CLIError.invalid("Symbolic links are not allowed")
            }
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  url.lastPathComponent != "checksums.json"
            else { continue }
            let rootPath = root.resolvingSymlinksInPath().path
            let filePath = url.resolvingSymlinksInPath().path
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            guard filePath.hasPrefix(prefix) else { throw CLIError.invalid("File escaped module root") }
            let relative = String(filePath.dropFirst(prefix.count))
            let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            result[relative] = digest
        }
        return result
    }

    private static func write(_ value: String, to url: URL) throws {
        try Data(value.utf8).write(to: url, options: .atomic)
    }
}

private final class LifecycleTestHost {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()

    init(executable: URL) {
        process.executableURL = executable
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    }

    func start() throws { try process.run() }

    func stop() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }

    func request(_ method: String, params: [String: Any]? = nil) throws {
        let id = UUID().uuidString
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { message["params"] = params }
        try write(message)

        while true {
            let response = try readMessage(timeoutMilliseconds: 5_000)
            if let incomingMethod = response["method"] as? String,
               let incomingID = response["id"] as? String {
                try answerHostRequest(
                    incomingMethod,
                    id: incomingID,
                    params: response["params"] as? [String: Any]
                )
                continue
            }
            guard response["id"] as? String == id else { continue }
            if let error = response["error"] as? [String: Any] {
                throw CLIError.invalid("Worker rejected \(method): \(error["message"] as? String ?? "unknown error")")
            }
            return
        }
    }

    private func answerHostRequest(
        _ method: String,
        id: String,
        params: [String: Any]?
    ) throws {
        let result: Any
        switch method {
        case "settings.read":
            result = ["schemaVersion": 1, "revision": 0, "values": [:]]
        case "services.subscribe":
            result = ["subscriptionID": params?["subscriptionID"] as? String ?? UUID().uuidString]
        case "control.acquire", "control.apply", "control.renew":
            try write([
                "jsonrpc": "2.0", "id": id,
                "error": ["code": -32001, "message": "Control is unavailable in the test host"],
            ])
            return
        default:
            result = NSNull()
        }
        try write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func write(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func readMessage(timeoutMilliseconds: Int32) throws -> [String: Any] {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                guard let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                    throw CLIError.invalid("Worker emitted invalid JSON-RPC")
                }
                return object
            }

            var descriptor = pollfd(
                fd: Int32(output.fileHandleForReading.fileDescriptor),
                events: Int16(POLLIN),
                revents: 0
            )
            let result = Darwin.poll(&descriptor, 1, timeoutMilliseconds)
            guard result > 0 else { throw CLIError.invalid("Worker lifecycle request timed out") }
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else {
                throw CLIError.invalid("Worker exited before completing the lifecycle")
            }
            buffer.append(chunk)
            guard buffer.count <= 1_048_576 else { throw CLIError.invalid("Worker message exceeds 1 MiB") }
        }
    }
}
