import Foundation

public enum ModuleRole: String, Codable, Sendable { case presentation, data, business, control }
public enum SettingsArea: String, Codable, Sendable { case general, panel, feature }
public enum MetricQuality: String, Codable, Sendable { case sensor, calculated, estimated, stale, unavailable }

public struct ModuleDependency: Codable, Hashable, Sendable {
    public let serviceID: String
    public let version: String
    public let optional: Bool
    public init(serviceID: String, version: String, optional: Bool = false) {
        self.serviceID = serviceID; self.version = version; self.optional = optional
    }
}

public struct ServiceDescriptor: Codable, Hashable, Sendable {
    public let id: String
    public let version: String
    /// Nil means the service supports its legacy, provider-defined field set.
    /// Catalog modules should publish an explicit set so the host can validate
    /// subscriptions without understanding service-specific payloads.
    public let fields: Set<String>?
    public let minimumInterval: TimeInterval?
    public let maximumInterval: TimeInterval?

    public init(
        id: String,
        version: String,
        fields: Set<String>? = nil,
        minimumInterval: TimeInterval? = nil,
        maximumInterval: TimeInterval? = nil
    ) {
        self.id = id
        self.version = version
        self.fields = fields
        self.minimumInterval = minimumInterval
        self.maximumInterval = maximumInterval
    }
}

public struct ModuleDescriptor: Codable, Identifiable, Sendable {
    public let id: String
    public let version: String
    public let protocolVersion: String
    public let minHostVersion: String
    public let minOSVersion: String
    public let architectures: [String]
    public let roles: Set<ModuleRole>
    public let entrypoint: String?
    public let provides: [ServiceDescriptor]
    public let requires: [ModuleDependency]
    public let permissions: [String]
    public let uiCapabilities: [String]
    public let author: String
    public let license: String
    public let settingsVersion: Int
    public let displayName: String
    public let summary: String
    public let systemImage: String
    public let settingsAreas: Set<SettingsArea>

    public init(
        id: String, version: String, protocolVersion: String, minHostVersion: String,
        minOSVersion: String, architectures: [String], roles: Set<ModuleRole>,
        entrypoint: String?, provides: [ServiceDescriptor], requires: [ModuleDependency],
        permissions: [String], uiCapabilities: [String], author: String, license: String,
        settingsVersion: Int, displayName: String, summary: String, systemImage: String,
        settingsAreas: Set<SettingsArea>
    ) {
        self.id = id; self.version = version; self.protocolVersion = protocolVersion
        self.minHostVersion = minHostVersion; self.minOSVersion = minOSVersion
        self.architectures = architectures; self.roles = roles; self.entrypoint = entrypoint
        self.provides = provides; self.requires = requires; self.permissions = permissions
        self.uiCapabilities = uiCapabilities; self.author = author; self.license = license
        self.settingsVersion = settingsVersion; self.displayName = displayName
        self.summary = summary; self.systemImage = systemImage; self.settingsAreas = settingsAreas
    }
}

public enum PresentationComponentKind: String, Codable, Sendable {
    case infoRow, section, button, toggle, progress, divider
}

public struct PresentationComponent: Codable, Identifiable, Sendable {
    public let id: String
    public let kind: PresentationComponentKind
    public let title: String?
    public let systemImage: String?
    public let value: String?
    public let binding: String?
    public let actionID: String?
    public let children: [PresentationComponent]
    public init(
        id: String, kind: PresentationComponentKind, title: String? = nil,
        systemImage: String? = nil, value: String? = nil, binding: String? = nil,
        actionID: String? = nil, children: [PresentationComponent] = []
    ) {
        self.id = id; self.kind = kind; self.title = title; self.systemImage = systemImage
        self.value = value; self.binding = binding; self.actionID = actionID; self.children = children
    }
}

public struct PresentationDescriptor: Codable, Sendable {
    public let panel: [PresentationComponent]
    public let menuBar: [PresentationComponent]
    public init(panel: [PresentationComponent], menuBar: [PresentationComponent] = []) {
        self.panel = panel; self.menuBar = menuBar
    }
}

public enum SettingValueType: String, Codable, Sendable { case boolean, integer, number, string, choice }

public struct SettingOption: Codable, Identifiable, Sendable {
    public var id: String { value }
    public let value: String
    public let title: String
    public init(value: String, title: String) { self.value = value; self.title = title }
}

public struct SettingCondition: Codable, Sendable {
    public let settingID: String
    public let equals: JSONValue

    public init(settingID: String, equals: JSONValue) {
        self.settingID = settingID
        self.equals = equals
    }
}

public struct SettingDefinition: Codable, Identifiable, Sendable {
    public let id: String
    public let type: SettingValueType
    public let title: String
    public let description: String?
    public let area: SettingsArea
    public let defaultValue: JSONValue
    public let minimum: Double?
    public let maximum: Double?
    public let step: Double?
    public let options: [SettingOption]
    public let visibleWhen: SettingCondition?
    public init(
        id: String, type: SettingValueType, title: String, description: String? = nil,
        area: SettingsArea, defaultValue: JSONValue, minimum: Double? = nil,
        maximum: Double? = nil, step: Double? = nil, options: [SettingOption] = [],
        visibleWhen: SettingCondition? = nil
    ) {
        self.id = id; self.type = type; self.title = title; self.description = description
        self.area = area; self.defaultValue = defaultValue; self.minimum = minimum
        self.maximum = maximum; self.step = step; self.options = options
        self.visibleWhen = visibleWhen
    }
}

public struct SettingsSchema: Codable, Sendable {
    public let version: Int
    public let settings: [SettingDefinition]
    public init(version: Int, settings: [SettingDefinition]) {
        self.version = version; self.settings = settings
    }
}

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
        else if let decoded = try? value.decode(Double.self) { self = .number(decoded) }
        else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
        else if let decoded = try? value.decode([String: JSONValue].self) { self = .object(decoded) }
        else { self = .array(try value.decode([JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let decoded): try value.encode(decoded)
        case .number(let decoded): try value.encode(decoded)
        case .bool(let decoded): try value.encode(decoded)
        case .object(let decoded): try value.encode(decoded)
        case .array(let decoded): try value.encode(decoded)
        case .null: try value.encodeNil()
        }
    }
}

/// Converts public contract types to and from the JSON value used by the
/// process protocol without exposing a shared Swift binary ABI.
public enum JSONValueCoder {
    public static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    public static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }
}

/// Module-owned text resources. The file representation is a dictionary whose
/// first key is a BCP-47 language tag and whose second key is a stable text ID.
public struct ModuleLocalizationTable: Codable, Equatable, Sendable {
    public let values: [String: [String: String]]

    public init(_ values: [String: [String: String]] = [:]) {
        self.values = values
    }

    public init(from decoder: Decoder) throws {
        values = try decoder.singleValueContainer().decode([String: [String: String]].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }

    public func resolve(
        _ key: String,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        for language in preferredLanguages {
            for candidate in Self.languageCandidates(for: language) {
                if let value = values[candidate]?[key] { return value }
            }
        }
        return values["en"]?[key] ?? key
    }

    private static func languageCandidates(for identifier: String) -> [String] {
        let normalized = identifier.replacingOccurrences(of: "_", with: "-")
        var candidates = [normalized]
        if normalized.lowercased().hasPrefix("zh-hant") {
            candidates.append("zh-Hant")
        } else if normalized.lowercased().hasPrefix("zh-hans") {
            candidates.append("zh-Hans")
        }
        if let language = normalized.split(separator: "-").first {
            candidates.append(String(language))
        }
        return candidates.reduce(into: []) { result, value in
            if !result.contains(value) { result.append(value) }
        }
    }
}

public struct MetricSample: Codable, Identifiable, Sendable {
    public let id: String
    public let value: Double?
    public let unit: String
    public let source: String
    public let sampledAt: Date
    public let quality: MetricQuality

    public init(id: String, value: Double?, unit: String, source: String, sampledAt: Date, quality: MetricQuality) {
        self.id = id; self.value = value; self.unit = unit; self.source = source
        self.sampledAt = sampledAt; self.quality = quality
    }
}

public struct TelemetrySnapshot: Codable, Sendable {
    public let sessionID: UUID
    public let sequence: UInt64
    public let windowStartedAt: Date
    public let sampledAt: Date
    public let metrics: [MetricSample]

    public init(sessionID: UUID, sequence: UInt64, windowStartedAt: Date, sampledAt: Date, metrics: [MetricSample]) {
        self.sessionID = sessionID; self.sequence = sequence; self.windowStartedAt = windowStartedAt
        self.sampledAt = sampledAt; self.metrics = metrics
    }
}

public enum DemandPurpose: String, Codable, Sendable {
    case menuBar, visiblePanel, preview, backgroundTask
}

public struct Demand: Codable, Identifiable, Sendable {
    public let id: UUID
    public let consumerID: String
    public let serviceID: String
    public let fields: Set<String>
    public let interval: TimeInterval
    public let purpose: DemandPurpose
    public init(
        id: UUID = UUID(), consumerID: String, serviceID: String,
        fields: Set<String>, interval: TimeInterval, purpose: DemandPurpose
    ) {
        self.id = id; self.consumerID = consumerID; self.serviceID = serviceID
        self.fields = fields; self.interval = interval; self.purpose = purpose
    }
}

public struct ModuleAction: Codable, Identifiable, Sendable {
    public let id: String
    public let parameters: JSONValue?
    public init(id: String, parameters: JSONValue? = nil) {
        self.id = id; self.parameters = parameters
    }
}

public enum ModuleTaskState: String, Codable, Sendable {
    case running, succeeded, failed, cancelled
}

public struct ControlLease: Codable, Identifiable, Sendable {
    public let id: UUID
    public let resourceID: String
    public let sessionID: UUID
    public let renewAfterSeconds: TimeInterval
    public init(id: UUID, resourceID: String, sessionID: UUID, renewAfterSeconds: TimeInterval = 5) {
        self.id = id; self.resourceID = resourceID; self.sessionID = sessionID
        self.renewAfterSeconds = renewAfterSeconds
    }
}

public struct ModuleError: Codable, Error, Sendable {
    public let code: String
    public let message: String
    public let recoverable: Bool
    public init(code: String, message: String, recoverable: Bool) {
        self.code = code; self.message = message; self.recoverable = recoverable
    }
}

public struct RPCRequest: Codable, Sendable {
    public let jsonrpc: String
    public let id: String
    public let method: String
    public let params: JSONValue?
    public init(id: String, method: String, params: JSONValue? = nil) {
        jsonrpc = "2.0"; self.id = id; self.method = method; self.params = params
    }
}

public struct RPCResponse: Codable, Sendable {
    public struct Failure: Codable, Sendable {
        public let code: Int
        public let message: String
        public let data: JSONValue?
        public init(code: Int, message: String, data: JSONValue? = nil) {
            self.code = code; self.message = message; self.data = data
        }
    }
    public let jsonrpc: String
    public let id: String
    public let result: JSONValue?
    public let error: Failure?
    public init(id: String, result: JSONValue? = nil, error: Failure? = nil) {
        jsonrpc = "2.0"; self.id = id; self.result = result; self.error = error
    }
}
