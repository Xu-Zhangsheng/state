import Defaults
import SwiftUI

struct DashboardSettingsView: View {
    @Default(.powerFlowDetailLevel) private var powerFlowDetailLevel
    @Default(.highEnergyAppLimit) private var highEnergyAppLimit

    @State private var modules: [DashboardModuleID]
    @State private var itemsByModule: [DashboardModuleID: [DashboardItemID]]
    @State private var visibleModules: Set<DashboardModuleID>
    @State private var visibleItems: Set<DashboardItemID>
    @State private var expandedModules: Set<DashboardModuleID>

    init() {
        let modules = DashboardLayoutStore.orderedModules
        _modules = State(initialValue: modules)
        _itemsByModule = State(
            initialValue: Dictionary(
                uniqueKeysWithValues: modules.map {
                    ($0, DashboardLayoutStore.orderedItems(in: $0))
                }
            )
        )
        _visibleModules = State(
            initialValue: Set(modules.filter(DashboardLayoutStore.isModuleVisible))
        )
        _visibleItems = State(
            initialValue: Set(DashboardItemID.allCases.filter(DashboardLayoutStore.isVisible))
        )
        _expandedModules = State(initialValue: Set(modules))
    }

    var body: some View {
        Form {
            Section {
                DashboardMenuPreview(
                    modules: modules,
                    itemsByModule: itemsByModule,
                    visibleModules: visibleModules,
                    visibleItems: visibleItems,
                    powerFlowDetailLevel: powerFlowDetailLevel
                )
                .frame(maxWidth: .infinity)
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Menu Preview")
                    Text("The preview updates immediately as you reorder or hide items.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(modules) { module in
                    moduleEditor(module)
                        .dropDestination(for: String.self) { payloads, _ in
                            moveModule(payloads.first, to: module)
                        }
                }
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Menu Layout")
                    Text("Drag modules or their items to change their position in the menu.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Restore Default Layout") {
                    restoreDefaults()
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 0)
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private func moduleEditor(_ module: DashboardModuleID) -> some View {
        DisclosureGroup(isExpanded: expansionBinding(for: module)) {
            VStack(spacing: 0) {
                ForEach(itemsByModule[module] ?? module.defaultItems) { item in
                    Divider()
                        .padding(.leading, 28)

                    itemEditor(item, in: module)
                        .dropDestination(for: String.self) { payloads, _ in
                            moveItem(payloads.first, to: item, in: module)
                        }

                    if item == .powerDistribution,
                       visibleItems.contains(.powerDistribution)
                    {
                        Picker("Power flow level", selection: $powerFlowDetailLevel) {
                            ForEach(PowerFlowDetailLevel.allCases) { level in
                                Text(level.title).tag(level)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.leading, 28)
                        .padding(.vertical, 8)
                        .disabled(!visibleModules.contains(module))
                        .opacity(visibleModules.contains(module) ? 1 : 0.55)
                    }

                    if item == .highEnergyApps,
                       visibleItems.contains(.highEnergyApps)
                    {
                        Stepper(value: $highEnergyAppLimit, in: 0...10) {
                            HStack {
                                Text("High energy apps shown")
                                Spacer()
                                Text("\(highEnergyAppLimit)")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        .padding(.leading, 28)
                        .padding(.vertical, 8)
                        .disabled(!visibleModules.contains(module))
                        .opacity(visibleModules.contains(module) ? 1 : 0.55)
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: module.systemImage)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)

                Text(module.title)
                    .fontWeight(.medium)

                Spacer()

                Toggle(module.title, isOn: moduleVisibilityBinding(for: module))
                    .labelsHidden()

                dragHandle
                    .draggable("module:\(module.rawValue)")
            }
        }
    }

    private func itemEditor(
        _ item: DashboardItemID,
        in module: DashboardModuleID
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(for: item))
                .frame(width: 18)
                .foregroundStyle(.secondary)

            Toggle(item.title, isOn: itemVisibilityBinding(for: item))

            dragHandle
                .draggable("item:\(item.rawValue)")
        }
        .padding(.leading, 28)
        .padding(.vertical, 5)
        .opacity(visibleModules.contains(module) ? 1 : 0.55)
        .disabled(!visibleModules.contains(module))
    }

    private var dragHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .help(String(localized: "Drag to reorder"))
    }

    private func expansionBinding(for module: DashboardModuleID) -> Binding<Bool> {
        Binding(
            get: { expandedModules.contains(module) },
            set: { expanded in
                if expanded {
                    expandedModules.insert(module)
                } else {
                    expandedModules.remove(module)
                }
            }
        )
    }

    private func moduleVisibilityBinding(for module: DashboardModuleID) -> Binding<Bool> {
        Binding(
            get: { visibleModules.contains(module) },
            set: { visible in
                if visible {
                    visibleModules.insert(module)
                } else {
                    visibleModules.remove(module)
                }
                DashboardLayoutStore.setModuleVisible(visible, for: module)
            }
        )
    }

    private func itemVisibilityBinding(for item: DashboardItemID) -> Binding<Bool> {
        Binding(
            get: { visibleItems.contains(item) },
            set: { visible in
                if visible {
                    visibleItems.insert(item)
                } else {
                    visibleItems.remove(item)
                }
                DashboardLayoutStore.setVisible(visible, for: item)
            }
        )
    }

    private func moveModule(_ payload: String?, to target: DashboardModuleID) -> Bool {
        guard let payload,
              payload.hasPrefix("module:"),
              let source = DashboardModuleID(rawValue: String(payload.dropFirst(7))),
              source != target,
              let sourceIndex = modules.firstIndex(of: source),
              let targetIndex = modules.firstIndex(of: target)
        else { return false }

        modules.remove(at: sourceIndex)
        let insertionIndex = min(targetIndex, modules.count)
        modules.insert(source, at: insertionIndex)
        DashboardLayoutStore.saveModules(modules)
        return true
    }

    private func moveItem(
        _ payload: String?,
        to target: DashboardItemID,
        in module: DashboardModuleID
    ) -> Bool {
        guard let payload,
              payload.hasPrefix("item:"),
              let source = DashboardItemID(rawValue: String(payload.dropFirst(5))),
              source != target,
              module.defaultItems.contains(source),
              var items = itemsByModule[module],
              let sourceIndex = items.firstIndex(of: source),
              let targetIndex = items.firstIndex(of: target)
        else { return false }

        items.remove(at: sourceIndex)
        let insertionIndex = min(targetIndex, items.count)
        items.insert(source, at: insertionIndex)
        itemsByModule[module] = items
        DashboardLayoutStore.saveItems(items, in: module)
        return true
    }

    private func restoreDefaults() {
        DashboardLayoutStore.restoreDefaults()
        modules = DashboardModuleID.defaultOrder
        itemsByModule = Dictionary(
            uniqueKeysWithValues: DashboardModuleID.defaultOrder.map {
                ($0, $0.defaultItems)
            }
        )
        visibleModules = Set(DashboardModuleID.defaultOrder)
        visibleItems = Set(DashboardItemID.allCases.filter(DashboardLayoutStore.isVisible))
        expandedModules = Set(DashboardModuleID.defaultOrder)
    }

    private func icon(for item: DashboardItemID) -> String {
        switch item {
        case .powerSource: return "powerplug"
        case .timeRemaining: return "clock"
        case .uptime: return "gauge.with.dots.needle.67percent"
        case .batteryMode: return "bolt"
        case .batteryTemperature: return "thermometer.medium"
        case .internalPower: return "battery.75"
        case .externalPower: return "powerplug.fill"
        case .powerDistribution: return "arrow.triangle.branch"
        case .cycleCount: return "arrow.2.circlepath"
        case .batteryHealth: return "heart.text.square"
        case .highEnergyApps: return "flame"
        case .chargeLimit: return "slider.horizontal.3"
        case .chargeLimitOverride: return "battery.badge.exclamationmark"
        case .forceDischarge: return "bolt.slash"
        }
    }
}

private struct DashboardMenuPreview: View {
    let modules: [DashboardModuleID]
    let itemsByModule: [DashboardModuleID: [DashboardItemID]]
    let visibleModules: Set<DashboardModuleID>
    let visibleItems: Set<DashboardItemID>
    let powerFlowDetailLevel: PowerFlowDetailLevel

    private var displayedModules: [(DashboardModuleID, [DashboardItemID])] {
        modules.compactMap { module in
            guard visibleModules.contains(module) else { return nil }
            let items = (itemsByModule[module] ?? module.defaultItems)
                .filter(visibleItems.contains)
            return items.isEmpty ? nil : (module, items)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(displayedModules.indices, id: \.self) { moduleIndex in
                    if moduleIndex > 0 {
                        Divider()
                            .padding(.horizontal, StasisMenuMetrics.horizontalPadding)
                            .padding(.vertical, StasisMenuMetrics.sectionSpacing)
                    }

                    let items = displayedModules[moduleIndex].1
                    ForEach(items) { item in
                        previewItem(item)
                    }
                }

                Divider()
                    .padding(.horizontal, StasisMenuMetrics.horizontalPadding)
                    .padding(.vertical, StasisMenuMetrics.sectionSpacing)

                BatteryAdditionalInfo(label: String(localized: "Settings"), value: "⌘,")
            }
            .frame(width: StasisMenuMetrics.width)
        }
        .frame(height: 280)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func previewItem(_ item: DashboardItemID) -> some View {
        switch item {
        case .powerSource:
            previewInfo(item, "Power Adapter")
        case .timeRemaining:
            previewInfo(item, String(localized: "Calculating…"))
        case .uptime:
            previewInfo(item, "1d 5h")
        case .batteryMode:
            previewInfo(item, String(localized: "Charging"))
        case .batteryTemperature:
            previewInfo(item, "34.2°C")
        case .internalPower:
            previewInfo(item, "11.42V @ 0.42A")
        case .externalPower:
            previewInfo(item, "20.1V @ 1.08A")
        case .powerDistribution:
            PowerFlowSettingsPreview(level: powerFlowDetailLevel)
        case .cycleCount:
            previewInfo(item, "98")
        case .batteryHealth:
            previewInfo(item, "94%")
        case .highEnergyApps:
            HStack(spacing: 8) {
                Image(systemName: "safari")
                    .frame(width: 18)
                Text("Safari")
                Spacer()
            }
            .font(.callout)
            .stasisMenuRowPadding(vertical: StasisMenuMetrics.regularRowPadding)
        case .chargeLimit:
            HStack(spacing: 10) {
                Text("Charge limit")
                Slider(value: .constant(80), in: 50...100, step: 5)
                    .controlSize(.small)
                Text("80%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .stasisMenuRowPadding(vertical: 5)
            .allowsHitTesting(false)
        case .chargeLimitOverride, .forceDischarge:
            HStack {
                Text(item.title)
                Spacer()
                Toggle(item.title, isOn: .constant(false))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            .foregroundStyle(.secondary)
            .font(.callout)
            .stasisMenuRowPadding()
            .allowsHitTesting(false)
        }
    }

    private func previewInfo(_ item: DashboardItemID, _ value: String) -> some View {
        BatteryAdditionalInfo(label: item.title, value: value)
    }
}

private struct PowerFlowSettingsPreview: View {
    let level: PowerFlowDetailLevel

    private var breakdown: [PowerBreakdownItem] {
        guard level == .level3 else { return [] }
        return [
            PowerBreakdownItem(
                id: "preview-external",
                name: String(localized: "External Devices"),
                power: 2.1,
                systemImage: "arrow.up.forward",
                icon: nil,
                isEstimated: true
            ),
            PowerBreakdownItem(
                id: "preview-display",
                name: String(localized: "Display"),
                power: 2.8,
                systemImage: "display",
                icon: nil,
                isEstimated: true
            ),
            PowerBreakdownItem(
                id: "preview-chip",
                name: String(localized: "M2 Chip"),
                power: 5.4,
                systemImage: "cpu",
                icon: nil,
                isEstimated: false
            ),
            PowerBreakdownItem(
                id: "preview-other",
                name: String(localized: "Other"),
                power: 3.5,
                systemImage: "ellipsis",
                icon: nil,
                isEstimated: true
            ),
        ]
    }

    var body: some View {
        PowerSankeyView(
            powerSource: .acAdapter,
            isCharging: true,
            batteryPower: 4.8,
            adapterPower: 18.6,
            systemPower: 13.8,
            powerBreakdown: breakdown
        )
        .accessibilityLabel(String(localized: "Power flow preview"))
    }
}

#Preview {
    DashboardSettingsView()
}
