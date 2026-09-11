import AppKit
import Defaults
import Foundation

/// Owns the status item and lets AppKit draw the button chrome.
///
/// The previous implementation inserted an `NSHostingView` into the status
/// button.  That view filled the button's bounds and consequently covered the
/// native hover/pressed background with a dark rounded rectangle. Rendering
/// Control Center's own battery assets directly on `NSStatusBarButton`
/// preserves the system menu-bar metrics and appearance.
@MainActor
final class StatusBarManager {
    private let statusItem: NSStatusItem
    private let viewModel: MenuViewModel
    private let registry: ModuleRegistry
    private let presentationState: ModulePresentationStateStore
    private var viewModelObservation: Task<Void, Never>?
    private var settingsObservation: Task<Void, Never>?
    private var powerStateObserver: NSObjectProtocol?
    private var moduleObservation: Task<Void, Never>?
    private var isMenuHighlighted = false

    init(
        viewModel: MenuViewModel,
        registry: ModuleRegistry,
        presentationState: ModulePresentationStateStore
    ) {
        self.viewModel = viewModel
        self.registry = registry
        self.presentationState = presentationState
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton()
        startObservingState()
        observeSystemPowerState()
        updateButton()
    }

    func setMenu(_ menu: NSMenu) {
        statusItem.menu = menu
    }

    func setMenuHighlighted(_ highlighted: Bool) {
        guard isMenuHighlighted != highlighted else { return }
        isMenuHighlighted = highlighted
        updateButton()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }

        // Keep the NSStatusBarButton's own background and highlight handling.
        // In particular, do not remove/add subviews here.
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.wantsLayer = false
        button.imageScaling = .scaleNone
        button.imagePosition = .imageOnly
        button.imageHugsTitle = true
        // Keep the percentage slightly more compact than the battery artwork.
        button.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        button.title = ""
    }

    private func observeSystemPowerState() {
        powerStateObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateButton()
            }
        }
    }

    private func startObservingState() {
        viewModelObservation = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.updateButton()
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.viewModel.statusRevision
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }

        settingsObservation = Task { [weak self] in
            guard let self else { return }
            for await _ in Defaults.updates(
                [.batteryPercentageDisplayLocation, .showBatteryStateInStatusIcon],
                initial: false
            ) {
                guard !Task.isCancelled else { return }
                self.updateButton()
            }
        }

        moduleObservation = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.updateButton()
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.registry.modules
                        _ = self.registry.menuBarProviderID
                        _ = self.presentationState.states
                    } onChange: {
                        Task { @MainActor in continuation.resume() }
                    }
                }
            }
        }
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }

        guard let providerID = registry.menuBarProviderID,
              let provider = registry.module(id: providerID), provider.isEnabled
        else {
            let fallback = NSImage(systemSymbolName: "circle.grid.2x2", accessibilityDescription: "state")
            fallback?.isTemplate = true
            button.image = fallback
            button.imagePosition = .imageOnly
            button.title = ""
            button.toolTip = "state"
            return
        }

        if providerID != BuiltInModuleCatalog.batteryStatusID {
            updateButton(button, with: provider)
            return
        }

        let location = Defaults[.batteryPercentageDisplayLocation]
        let showState = Defaults[.showBatteryStateInStatusIcon]
        let percentage = max(0, min(100, viewModel.displayPercentage))

        let state: SystemBatteryIconState = switch viewModel.chargingMode {
        case .charging: .charging
        case .pluggedIn: .pluggedIn
        case .discharging: .discharging
        }

        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            button.image = SystemBatteryIconRenderer.image(
                level: percentage,
                state: state,
                isLowPowerModeEnabled: viewModel.isLowPowerModeEnabled,
                showState: showState,
                isHighlighted: isMenuHighlighted,
                foregroundColor: .labelColor
            )
        }
        button.contentTintColor = nil
        button.title = location == .nextToIcon ? "\(percentage)%" : ""
        // The system Battery menu extra places the percentage before the icon.
        button.imagePosition = location == .nextToIcon ? .imageRight : .imageOnly
        button.toolTip = statusTooltip(level: percentage)
    }

    private func updateButton(_ button: NSStatusBarButton, with module: InstalledModule) {
        guard let component = module.localizedPresentation?.menuBar.first else {
            button.image = NSImage(systemSymbolName: module.descriptor.systemImage, accessibilityDescription: module.displayName)
            button.image?.isTemplate = true
            button.imagePosition = .imageOnly
            button.title = ""
            button.toolTip = module.displayName
            return
        }

        let imageName = component.systemImage ?? module.descriptor.systemImage
        let image = NSImage(systemSymbolName: imageName, accessibilityDescription: component.title ?? module.displayName)
        image?.isTemplate = true
        button.image = image
        let value = resolvedText(for: component, moduleID: module.id)
        let menuBarValue = conciseMenuBarText(value)
        button.title = menuBarValue
        button.imagePosition = menuBarValue.isEmpty ? .imageOnly : .imageLeft
        button.toolTip = value.isEmpty ? (component.title ?? module.displayName) : value
    }

    private func resolvedText(for component: PresentationComponent, moduleID: String) -> String {
        let stateValue = component.binding.flatMap {
            presentationState.value(moduleID: moduleID, binding: $0)
        }
        switch stateValue {
        case .string(let value): return value
        case .number(let value): return value.formatted(.number.precision(.fractionLength(0...1)))
        case .bool(let value): return value ? String(localized: "On") : String(localized: "Off")
        case .none, .null, .object, .array: return component.value ?? ""
        }
    }

    private func conciseMenuBarText(_ value: String) -> String {
        let singleLine = value.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard singleLine.count > 18 else { return singleLine }
        return String(singleLine.prefix(17)) + "…"
    }

    private func statusTooltip(level: Int) -> String {
        var description = "\(level)% " + String(localized: "Battery")
        switch viewModel.chargingMode {
        case .charging:
            description += " — " + String(localized: "Charging")
        case .pluggedIn:
            description += " — " + String(localized: "Plugged In (Not Charging)")
        case .discharging:
            break
        }
        return description
    }

    deinit {
        MainActor.assumeIsolated {
            viewModelObservation?.cancel()
            settingsObservation?.cancel()
            moduleObservation?.cancel()
            if let powerStateObserver {
                NotificationCenter.default.removeObserver(powerStateObserver)
            }
        }
    }
}
