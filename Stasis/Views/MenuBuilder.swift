import AppKit
import Defaults
import StasisNativeUI
import SwiftUI

@MainActor
class MenuBuilder {
    private let viewModel: MenuViewModel
    private let registry: ModuleRegistry
    private let supervisor: RuntimeSupervisor
    private let presentationState: ModulePresentationStateStore
    private let settingsWindowController: SettingsWindowController
    private let contentHeightDidChange: @MainActor () -> Void

    init(
        viewModel: MenuViewModel,
        registry: ModuleRegistry,
        supervisor: RuntimeSupervisor,
        presentationState: ModulePresentationStateStore,
        settingsWindowController: SettingsWindowController,
        contentHeightDidChange: @escaping @MainActor () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.registry = registry
        self.supervisor = supervisor
        self.presentationState = presentationState
        self.settingsWindowController = settingsWindowController
        self.contentHeightDidChange = contentHeightDidChange
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu(title: "state")
        populateMenu(menu)
        return menu
    }

    func populateMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        var addedModule = false
        for module in registry.visibleModules {
            let legacyItems = ModuleDashboardBridge.items(for: module.id)
                .filter(DashboardLayoutStore.isVisible)
                .compactMap(makeDashboardItem)
            let moduleItems: [NSMenuItem]
            if legacyItems.isEmpty,
               let presentation = module.localizedPresentation,
               !presentation.panel.isEmpty {
                moduleItems = [createMenuItem(view: StasisDeclarativePanelView(
                    components: presentation.panel,
                    state: presentationState.states[module.id] ?? [:],
                    resolvesPublishedState: true,
                    horizontalPadding: StasisMenuMetrics.horizontalPadding,
                    verticalPadding: 6,
                    action: { [weak self] actionID, value in
                        guard let self else { return }
                        Task { _ = try? await self.supervisor.request(
                            moduleID: module.id,
                            method: "handleAction",
                            params: .object([
                                "actionID": .string(actionID),
                                "value": value ?? .null,
                            ])
                        ) }
                    }
                ))]
            } else {
                moduleItems = legacyItems
            }
            guard !moduleItems.isEmpty else { continue }

            if addedModule {
                menu.addItem(NSMenuItem.separator())
            }
            moduleItems.forEach(menu.addItem)
            addedModule = true
        }

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(
            title: String(localized:  "Settings"),
            action: #selector(handleSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
    }

    private func makeDashboardItem(for itemID: DashboardItemID) -> NSMenuItem? {
        switch itemID {
        case .powerSource:
            return createInfoItem(label: itemID.title, keyPath: \.powerSourceText)
        case .timeRemaining:
            return createInfoItem(label: itemID.title, keyPath: \.timeRemainingText)
        case .uptime:
            return createInfoItem(label: itemID.title, keyPath: \.uptimeText)
        case .batteryMode:
            return createInfoItem(label: itemID.title, keyPath: \.batteryModeText)
        case .batteryTemperature:
            return createInfoItem(label: itemID.title, keyPath: \.batteryTemperatureText)
        case .internalPower:
            return createInfoItem(label: itemID.title, keyPath: \.internalInputText)
        case .externalPower:
            guard viewModel.adapterConnected else { return nil }
            return createInfoItem(label: itemID.title, keyPath: \.externalInputText)
        case .powerDistribution:
            return createMenuItem(view: PowerSankeyViewWrapper(viewModel: viewModel))
        case .cycleCount:
            return createInfoItem(label: itemID.title, keyPath: \.cycleCountText)
        case .batteryHealth:
            return createInfoItem(label: itemID.title, keyPath: \.batteryHealthText)
        case .highEnergyApps:
            return createMenuItem(view: HighEnergyAppsView(provider: viewModel))
        case .chargeLimit:
            guard viewModel.manageChargingEnabled else { return nil }
            return createMenuItem(view: ChargeLimitControlView())
        case .chargeLimitOverride:
            guard viewModel.manageChargingEnabled && viewModel.adapterConnected else { return nil }
            return createMenuItem(view: ChargeLimitOverrideToggleView(viewModel: viewModel))
        case .forceDischarge:
            guard viewModel.manageChargingEnabled && viewModel.adapterConnected else { return nil }
            return createMenuItem(view: ForceDischargeToggleView(viewModel: viewModel))
        }
    }

    private func createInfoItem(
        label: String,
        keyPath: KeyPath<MenuViewModel, String>
    ) -> NSMenuItem {
        createMenuItem(
            view: BatteryAdditionalInfoObserverView(
                label: label,
                viewModel: viewModel,
                keyPath: keyPath
            )
        )
    }

    private static let menuWidth = StasisMenuMetrics.width

    private func createMenuItem<V: View>(view: V) -> NSMenuItem {
        // Keep the AppKit bridge non-generic so the optimizer does not need to
        // specialize a different NSHostingView subclass for every menu row.
        let hostingView = AdaptiveMenuHostingView(rootView: AnyView(view))
        let height = hostingView.fittingSize.height
        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: Self.menuWidth,
            height: height
        )
        hostingView.establishHeightBaseline(height)
        hostingView.fittingHeightDidChange = { [weak self] in
            self?.contentHeightDidChange()
        }

        let menuItem = NSMenuItem()
        menuItem.view = hostingView

        return menuItem
    }

    @objc private func handleSettings() {
        settingsWindowController.showSettings()
    }

}

/// NSMenu does not automatically resize a custom NSHostingView when its
/// SwiftUI root changes intrinsic height. This bridge observes only fitting
/// height changes and asks the menu builder to lay out fresh items; content
/// updates that keep the same height remain entirely inside SwiftUI.
@MainActor
private final class AdaptiveMenuHostingView: NSHostingView<AnyView> {
    var fittingHeightDidChange: (() -> Void)?

    private var baselineHeight: CGFloat = 0
    private var sizeCheckScheduled = false

    func establishHeightBaseline(_ height: CGFloat) {
        baselineHeight = height
    }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        scheduleFittingHeightCheck()
    }

    override func layout() {
        super.layout()
        scheduleFittingHeightCheck()
    }

    private func scheduleFittingHeightCheck() {
        guard !sizeCheckScheduled else { return }
        sizeCheckScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.sizeCheckScheduled = false
            let newHeight = self.fittingSize.height
            guard newHeight.isFinite,
                  newHeight > 0,
                  abs(newHeight - self.baselineHeight) > 0.5
            else { return }
            self.baselineHeight = newHeight
            self.fittingHeightDidChange?()
        }
    }
}

struct ChargeLimitControlView: View {
    @Default(.chargeLimit) private var chargeLimit

    var body: some View {
        HStack(spacing: 10) {
            Text("Charge limit")
                .lineLimit(1)

            Slider(
                value: Binding(
                    get: { Double(chargeLimit) },
                    set: { chargeLimit = Int($0.rounded()) }
                ),
                in: 50...100,
                step: 5
            )
            .controlSize(.small)

            Text("\(chargeLimit)%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .font(.callout)
        .stasisMenuRowPadding(vertical: 5)
    }
}

struct BatteryAdditionalInfoObserverView: View {
    let label: String
    let viewModel: MenuViewModel
    let keyPath: KeyPath<MenuViewModel, String>

    var body: some View {
        BatteryAdditionalInfo(label: label, value: viewModel[keyPath: keyPath])
    }
}

struct PowerSankeyViewWrapper: View {
    let viewModel: MenuViewModel

    var body: some View {
        PowerSankeyView(
            powerSource: viewModel.powerSource,
            isCharging: viewModel.isCharging,
            batteryPower: viewModel.batteryPower,
            adapterPower: viewModel.adapterPower,
            systemPower: viewModel.systemPower,
            powerBreakdown: viewModel.powerBreakdown
        )
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}

struct ChargeLimitOverrideToggleView: View {
    let viewModel: MenuViewModel

    var body: some View {
        HStack {
            Text("Charge Limit Override")
            Spacer(minLength: 20)
            Toggle(
                "Charge Limit Override",
                isOn: Binding(
                    get: { viewModel.chargeLimitOverrideActive },
                    set: { _ in viewModel.toggleChargeLimitOverride() }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(viewModel.forceDischargeActive || viewModel.calibrationOverrideActive)
        }
        .foregroundStyle(.secondary)
        .font(.callout)
        .stasisMenuRowPadding()
    }
}

struct ForceDischargeToggleView: View {
    let viewModel: MenuViewModel

    var body: some View {
        HStack {
            Text("Force Discharge")
            Spacer(minLength: 20)
            Toggle(
                "Force Discharge",
                isOn: Binding(
                    get: { viewModel.forceDischargeActive },
                    set: { _ in viewModel.toggleForceDischarge() }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(viewModel.chargeLimitOverrideActive || viewModel.calibrationOverrideActive)
        }
        .foregroundStyle(.secondary)
        .font(.callout)
        .stasisMenuRowPadding()
    }
}
