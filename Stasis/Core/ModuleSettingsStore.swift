import Foundation
import Observation
import os

@MainActor
@Observable
final class ModuleSettingsStore {
    struct Namespace: Codable, Sendable {
        var schemaVersion: Int
        var revision: UInt64
        var values: [String: JSONValue]
    }

    private(set) var revisions: [String: UInt64] = [:]
    private var namespaces: [String: Namespace] = [:]
    private var schemas: [String: ModuleSettingsSchema] = [:]
    private let rootURL: URL
    private let logger = Logger(subsystem: "com.srimanachanta.stasis", category: "ModuleSettings")

    init(fileManager: FileManager = .default) {
        rootURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Stasis/Configuration", isDirectory: true)
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func value(moduleID: String, key: String) -> JSONValue? {
        loadIfNeeded(moduleID)
        return namespaces[moduleID]?.values[key]
    }

    func register(schema: ModuleSettingsSchema, moduleID: String) {
        do {
            try prepare(schema: schema, moduleID: moduleID)
        } catch {
            logger.error("Failed to migrate settings for \(moduleID): \(error.localizedDescription)")
        }
    }

    /// Validates and persists a schema migration before exposing it to the
    /// running host. Callers can restore `backup(moduleID:)` if a module update
    /// later fails its worker health check.
    func prepare(schema: ModuleSettingsSchema, moduleID: String) throws {
        loadIfNeeded(moduleID)
        guard var namespace = namespaces[moduleID] else {
            let values = Dictionary(uniqueKeysWithValues: schema.settings.map { ($0.id, $0.defaultValue) })
            try validate(values, against: schema)
            let initial = Namespace(schemaVersion: schema.version, revision: 0, values: values)
            try persist(initial, moduleID: moduleID)
            schemas[moduleID] = schema
            namespaces[moduleID] = initial
            revisions[moduleID] = initial.revision
            return
        }

        if namespace.schemaVersion == schema.version {
            try validate(namespace.values, against: schema)
            schemas[moduleID] = schema
            return
        }

        let currentURL = url(for: moduleID)
        if FileManager.default.fileExists(atPath: currentURL.path) {
            let backupURL = rootURL.appendingPathComponent(
                "\(moduleID.replacingOccurrences(of: "/", with: "_"))-v\(namespace.schemaVersion)-backup.json"
            )
            if !FileManager.default.fileExists(atPath: backupURL.path) {
                try FileManager.default.copyItem(at: currentURL, to: backupURL)
            }
        }
        let known = Set(schema.settings.map(\.id))
        namespace.values = namespace.values.filter { known.contains($0.key) }
        for definition in schema.settings where namespace.values[definition.id] == nil {
            namespace.values[definition.id] = definition.defaultValue
        }
        try validate(namespace.values, against: schema)
        namespace.schemaVersion = schema.version
        namespace.revision &+= 1
        try persist(namespace, moduleID: moduleID)
        schemas[moduleID] = schema
        namespaces[moduleID] = namespace
        revisions[moduleID] = namespace.revision
    }

    func backup(moduleID: String) -> Namespace? {
        loadIfNeeded(moduleID)
        return namespaces[moduleID]
    }

    func restore(_ backup: Namespace?, moduleID: String) throws {
        if let backup {
            try persist(backup, moduleID: moduleID)
            namespaces[moduleID] = backup
            revisions[moduleID] = backup.revision
        } else {
            let configurationURL = url(for: moduleID)
            if FileManager.default.fileExists(atPath: configurationURL.path) {
                try FileManager.default.removeItem(at: configurationURL)
            }
            namespaces[moduleID] = nil
            revisions[moduleID] = 0
        }
        schemas[moduleID] = nil
    }

    @discardableResult
    func apply(
        moduleID: String,
        expectedRevision: UInt64,
        schemaVersion: Int,
        patch: [String: JSONValue]
    ) throws -> UInt64 {
        loadIfNeeded(moduleID)
        if let schema = schemas[moduleID], schema.version != schemaVersion {
            throw SettingsStoreError.schemaVersionMismatch(
                expected: schema.version,
                received: schemaVersion
            )
        }
        var namespace = namespaces[moduleID] ?? Namespace(
            schemaVersion: schemaVersion,
            revision: 0,
            values: [:]
        )
        guard namespace.revision == expectedRevision else {
            throw SettingsStoreError.revisionConflict(current: namespace.revision)
        }
        if let schema = schemas[moduleID] {
            try validate(patch, against: schema)
        }
        namespace.values.merge(patch) { _, proposed in proposed }
        namespace.schemaVersion = schemaVersion
        namespace.revision &+= 1
        try persist(namespace, moduleID: moduleID)
        namespaces[moduleID] = namespace
        revisions[moduleID] = namespace.revision
        NotificationCenter.default.post(name: .stasisModuleConfigurationChanged, object: moduleID)
        return namespace.revision
    }

    private func validate(_ patch: [String: JSONValue], against schema: ModuleSettingsSchema) throws {
        let definitions = Dictionary(uniqueKeysWithValues: schema.settings.map { ($0.id, $0) })
        for (key, value) in patch {
            guard let definition = definitions[key] else {
                throw SettingsStoreError.unknownSetting(key)
            }
            switch (definition.type, value) {
            case (.boolean, .bool), (.string, .string):
                break
            case (.choice, .string(let selected)):
                guard definition.options.contains(where: { $0.value == selected }) else {
                    throw SettingsStoreError.invalidChoice(key)
                }
            case (.integer, .number(let number)):
                guard number.rounded() == number else { throw SettingsStoreError.typeMismatch(key) }
                try validateRange(number, definition: definition)
            case (.number, .number(let number)):
                try validateRange(number, definition: definition)
            default:
                throw SettingsStoreError.typeMismatch(key)
            }
        }
    }

    private func validateRange(_ number: Double, definition: SettingDefinition) throws {
        if let minimum = definition.minimum, number < minimum {
            throw SettingsStoreError.outOfRange(definition.id)
        }
        if let maximum = definition.maximum, number > maximum {
            throw SettingsStoreError.outOfRange(definition.id)
        }
    }

    func snapshot(moduleID: String, schemaVersion: Int = 1) -> Namespace {
        loadIfNeeded(moduleID)
        return namespaces[moduleID] ?? Namespace(schemaVersion: schemaVersion, revision: 0, values: [:])
    }

    private func loadIfNeeded(_ moduleID: String) {
        guard namespaces[moduleID] == nil else { return }
        let url = url(for: moduleID)
        if let data = try? Data(contentsOf: url),
           let namespace = try? JSONDecoder().decode(Namespace.self, from: data) {
            namespaces[moduleID] = namespace
            revisions[moduleID] = namespace.revision
        } else {
            revisions[moduleID] = 0
        }
    }

    private func persist(_ namespace: Namespace, moduleID: String) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(namespace).write(to: url(for: moduleID), options: .atomic)
    }

    private func url(for moduleID: String) -> URL {
        let safeName = moduleID.replacingOccurrences(of: "/", with: "_")
        return rootURL.appendingPathComponent("\(safeName).json")
    }
}

enum SettingsStoreError: LocalizedError {
    case revisionConflict(current: UInt64)
    case unknownSetting(String)
    case typeMismatch(String)
    case invalidChoice(String)
    case outOfRange(String)
    case schemaVersionMismatch(expected: Int, received: Int)

    var errorDescription: String? {
        switch self {
        case .revisionConflict(let current):
            return "The module configuration changed elsewhere (revision \(current))."
        case .unknownSetting(let key): return "Unknown module setting: \(key)."
        case .typeMismatch(let key): return "The value type is invalid for \(key)."
        case .invalidChoice(let key): return "The selected value is invalid for \(key)."
        case .outOfRange(let key): return "The value is outside the allowed range for \(key)."
        case .schemaVersionMismatch(let expected, let received):
            return "The module used settings schema \(received), but the host requires schema \(expected)."
        }
    }
}

extension Notification.Name {
    static let stasisModuleConfigurationChanged = Notification.Name("StasisModuleConfigurationChanged")
}
