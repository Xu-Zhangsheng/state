import Foundation
@_exported import StasisContracts

// The host and third-party SDK intentionally share these wire types. Keeping
// the aliases here lets the app use domain-oriented names without creating a
// second Codable definition that could drift from StasisContracts.
typealias ModuleRole = StasisContracts.ModuleRole
typealias ModuleSettingsArea = StasisContracts.SettingsArea
typealias ModuleDependency = StasisContracts.ModuleDependency
typealias ModuleServiceDeclaration = StasisContracts.ServiceDescriptor
typealias ModuleDescriptor = StasisContracts.ModuleDescriptor
typealias PresentationComponentKind = StasisContracts.PresentationComponentKind
typealias PresentationComponent = StasisContracts.PresentationComponent
typealias PresentationDescriptor = StasisContracts.PresentationDescriptor
typealias SettingValueType = StasisContracts.SettingValueType
typealias SettingOption = StasisContracts.SettingOption
typealias SettingDefinition = StasisContracts.SettingDefinition
typealias ModuleSettingsSchema = StasisContracts.SettingsSchema
typealias MetricQuality = StasisContracts.MetricQuality
typealias MetricSample = StasisContracts.MetricSample
typealias TelemetrySnapshot = StasisContracts.TelemetrySnapshot
typealias DemandPurpose = StasisContracts.DemandPurpose
typealias ModuleDemand = StasisContracts.Demand
typealias JSONValue = StasisContracts.JSONValue
typealias JSONRPCRequest = StasisContracts.RPCRequest
typealias JSONRPCResponse = StasisContracts.RPCResponse
typealias ModuleLocalizationTable = StasisContracts.ModuleLocalizationTable

enum ModuleOrigin: String, Codable, Sendable {
    case builtIn
    case catalog
    case local
}

enum ModuleRuntimeState: String, Codable, Sendable {
    case inactive
    case starting
    case active
    case failed
    case incompatible
}

struct InstalledModule: Codable, Identifiable, Sendable {
    var descriptor: ModuleDescriptor
    var presentation: PresentationDescriptor?
    var settingsSchema: ModuleSettingsSchema?
    var localizations: ModuleLocalizationTable
    var isEnabled: Bool
    var isVisible: Bool
    var notificationsEnabled: Bool
    var origin: ModuleOrigin
    var runtimeState: ModuleRuntimeState
    var lastError: String?

    var id: String { descriptor.id }

    enum CodingKeys: String, CodingKey {
        case descriptor, presentation, settingsSchema, localizations
        case isEnabled, isVisible, notificationsEnabled, origin, runtimeState, lastError
    }

    init(
        descriptor: ModuleDescriptor,
        presentation: PresentationDescriptor? = nil,
        settingsSchema: ModuleSettingsSchema? = nil,
        localizations: ModuleLocalizationTable = .init(),
        isEnabled: Bool,
        isVisible: Bool,
        notificationsEnabled: Bool = true,
        origin: ModuleOrigin,
        runtimeState: ModuleRuntimeState,
        lastError: String?
    ) {
        self.descriptor = descriptor
        self.presentation = presentation
        self.settingsSchema = settingsSchema
        self.localizations = localizations
        self.isEnabled = isEnabled
        self.isVisible = isVisible
        self.notificationsEnabled = notificationsEnabled
        self.origin = origin
        self.runtimeState = runtimeState
        self.lastError = lastError
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        descriptor = try values.decode(ModuleDescriptor.self, forKey: .descriptor)
        presentation = try values.decodeIfPresent(PresentationDescriptor.self, forKey: .presentation)
        settingsSchema = try values.decodeIfPresent(ModuleSettingsSchema.self, forKey: .settingsSchema)
        localizations = try values.decodeIfPresent(
            ModuleLocalizationTable.self,
            forKey: .localizations
        ) ?? .init()
        isEnabled = try values.decode(Bool.self, forKey: .isEnabled)
        isVisible = try values.decode(Bool.self, forKey: .isVisible)
        notificationsEnabled = try values.decodeIfPresent(
            Bool.self,
            forKey: .notificationsEnabled
        ) ?? true
        origin = try values.decode(ModuleOrigin.self, forKey: .origin)
        runtimeState = try values.decode(ModuleRuntimeState.self, forKey: .runtimeState)
        lastError = try values.decodeIfPresent(String.self, forKey: .lastError)
    }

    var displayName: String {
        localizations.resolve(
            descriptor.displayName,
            preferredLanguages: AppLanguage.preferredLanguageIdentifiers
        )
    }

    var summary: String {
        localizations.resolve(
            descriptor.summary,
            preferredLanguages: AppLanguage.preferredLanguageIdentifiers
        )
    }

    var localizedPresentation: PresentationDescriptor? {
        guard let presentation else { return nil }
        return PresentationDescriptor(
            panel: presentation.panel.map(localize),
            menuBar: presentation.menuBar.map(localize)
        )
    }

    var localizedSettingsSchema: ModuleSettingsSchema? {
        guard let settingsSchema else { return nil }
        return ModuleSettingsSchema(
            version: settingsSchema.version,
            settings: settingsSchema.settings.map { setting in
                SettingDefinition(
                    id: setting.id,
                    type: setting.type,
                    title: localized(setting.title),
                    description: setting.description.map(localized),
                    area: setting.area,
                    defaultValue: setting.defaultValue,
                    minimum: setting.minimum,
                    maximum: setting.maximum,
                    step: setting.step,
                    options: setting.options.map {
                        SettingOption(value: $0.value, title: localized($0.title))
                    },
                    visibleWhen: setting.visibleWhen
                )
            }
        )
    }

    private func localize(_ component: PresentationComponent) -> PresentationComponent {
        PresentationComponent(
            id: component.id,
            kind: component.kind,
            title: component.title.map(localized),
            systemImage: component.systemImage,
            value: component.value.map(localized),
            binding: component.binding,
            actionID: component.actionID,
            children: component.children.map(localize)
        )
    }

    private func localized(_ key: String) -> String {
        localizations.resolve(
            key,
            preferredLanguages: AppLanguage.preferredLanguageIdentifiers
        )
    }
}
