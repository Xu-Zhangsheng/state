import StasisContracts
import SwiftUI

/// Native controls for a module's schema-defined settings. Persistence and
/// business validation remain host responsibilities and are supplied through
/// the change closure.
public struct StasisModuleSettingsFields: View {
    public let definitions: [SettingDefinition]
    public let values: [String: JSONValue]
    public let onChange: (SettingDefinition, JSONValue) -> Void

    public init(
        definitions: [SettingDefinition],
        values: [String: JSONValue],
        onChange: @escaping (SettingDefinition, JSONValue) -> Void
    ) {
        self.definitions = definitions
        self.values = values
        self.onChange = onChange
    }

    public var body: some View {
        ForEach(definitions.filter(isVisible)) { definition in
            field(definition)
        }
    }

    @ViewBuilder
    private func field(_ definition: SettingDefinition) -> some View {
        switch definition.type {
        case .boolean:
            Toggle(
                definition.title,
                isOn: Binding(
                    get: { booleanValue(definition) },
                    set: { onChange(definition, .bool($0)) }
                )
            )
            description(definition)
        case .integer:
            LabeledContent(definition.title) {
                HStack(spacing: 8) {
                    Slider(
                        value: Binding(
                            get: { numberValue(definition) },
                            set: { onChange(definition, .number($0.rounded())) }
                        ),
                        in: (definition.minimum ?? 0)...(definition.maximum ?? 100),
                        step: definition.step ?? 1
                    )
                    Text("\(Int(numberValue(definition)))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }
            }
            description(definition)
        case .number:
            LabeledContent(definition.title) {
                Slider(
                    value: Binding(
                        get: { numberValue(definition) },
                        set: { onChange(definition, .number($0)) }
                    ),
                    in: (definition.minimum ?? 0)...(definition.maximum ?? 1),
                    step: definition.step ?? 0.01
                )
            }
            description(definition)
        case .string:
            TextField(
                definition.title,
                text: Binding(
                    get: { stringValue(definition) },
                    set: { onChange(definition, .string($0)) }
                )
            )
            description(definition)
        case .choice:
            Picker(
                definition.title,
                selection: Binding(
                    get: { stringValue(definition) },
                    set: { onChange(definition, .string($0)) }
                )
            ) {
                ForEach(definition.options) { option in
                    Text(option.title).tag(option.value)
                }
            }
            description(definition)
        }
    }

    @ViewBuilder
    private func description(_ definition: SettingDefinition) -> some View {
        if let description = definition.description {
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func booleanValue(_ definition: SettingDefinition) -> Bool {
        if case .bool(let value) = values[definition.id] ?? definition.defaultValue { return value }
        return false
    }

    private func numberValue(_ definition: SettingDefinition) -> Double {
        if case .number(let value) = values[definition.id] ?? definition.defaultValue { return value }
        return definition.minimum ?? 0
    }

    private func stringValue(_ definition: SettingDefinition) -> String {
        if case .string(let value) = values[definition.id] ?? definition.defaultValue { return value }
        return definition.options.first?.value ?? ""
    }

    private func isVisible(_ definition: SettingDefinition) -> Bool {
        guard let condition = definition.visibleWhen,
              let source = definitions.first(where: { $0.id == condition.settingID })
        else { return definition.visibleWhen == nil }
        return (values[source.id] ?? source.defaultValue) == condition.equals
    }
}
