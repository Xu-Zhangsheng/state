import AppKit
import Defaults
import Observation
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var runtime: StasisRuntime!
    private var menu: NSMenu!
    private var settingsObservation: Task<Void, Never>?
    private var adapterObservation: Task<Void, Never>?
    private var highEnergyAppsObservation: Task<Void, Never>?
    private var menuRebuildTask: Task<Void, Never>?
    private var moduleObservation: Task<Void, Never>?
    private var terminationInProgress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        migrateRemovedPercentageLocation()

        Task {
            await setupServices()
            setupMenu()
            requestNotificationPermissions()
        }
    }

    private func migrateRemovedPercentageLocation() {
        let key = "batteryPercentageDisplayLocation"
        if UserDefaults.standard.string(forKey: key) == "insideIcon" {
            UserDefaults.standard.set(PercentageDisplayLocation.nextToIcon.rawValue, forKey: key)
        }

    }

    private func setupServices() async {
        runtime = StasisRuntime()
        if runtime.registry.needsInitialModuleChoice {
            runtime.registry.completeInitialModuleChoice(
                useRecommendedSuite: chooseInitialModuleSuite()
            )
        }
        if Defaults[.manageCharging] {
            await ChargingHelperManager.shared.verifyAvailability()
        }
        await runtime.bootstrap { [weak self] in self?.rebuildMenu() }
    }

    private func chooseInitialModuleSuite() -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Choose How state Starts")
        alert.informativeText = String(localized: "Enable the recommended battery modules, or start with an empty core and enable modules later in Settings.")
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "Use Recommended Modules"))
        alert.addButton(withTitle: String(localized: "Start with Empty Core"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func setupMenu() {
        menu = runtime.menuBuilder.buildMenu()
        menu.delegate = self
        runtime.statusBarManager.setMenu(menu)
        observeMenuSettingsChanges()
    }

    private func observeMenuSettingsChanges() {
        settingsObservation = Task { [weak self] in
            for await _ in Defaults.updates(
                [
                    .showPowerSource, .showTimeTillDischarge, .showBatteryCycleCount,
                    .showBatteryHealth, .showBatteryTemperature, .showUptime,
                    .showBatteryMode, .showInternalPower, .showExternalPower,
                    .showPowerDistribution, .showHighEnergyApps,
                    .powerFlowDetailLevel,
                    .highEnergyAppLimit, .showChargeLimitControl,
                    .showChargeLimitOverride, .showForceDischarge,
                    .dashboardLayout, .dashboardModuleLayout,
                    .dashboardVisibleModules, .manageCharging,
                    .batteryPercentageDisplayLocation,
                ],
                initial: false
            ) {
                self?.rebuildMenu()
            }
        }

        adapterObservation = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.rebuildMenu()
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.runtime.menuViewModel.adapterConnected
                        _ = self.runtime.menuViewModel.powerSource
                        _ = self.runtime.menuViewModel.isCharging
                        _ = self.runtime.menuViewModel.showsDetailedPowerFlow
                    } onChange: {
                        Task { @MainActor in
                            continuation.resume()
                        }
                    }
                }
            }
        }

        highEnergyAppsObservation = Task { [weak self] in
            var lastVisibleCount = -1
            while !Task.isCancelled {
                guard let self else { return }
                let visibleCount = min(
                    self.runtime.menuViewModel.highEnergyApps.count,
                    max(0, Defaults[.highEnergyAppLimit])
                )
                if visibleCount != lastVisibleCount {
                    lastVisibleCount = visibleCount
                    self.rebuildMenu()
                }
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.runtime.menuViewModel.highEnergyApps
                    } onChange: {
                        Task { @MainActor in
                            continuation.resume()
                        }
                    }
                }
            }
        }

        moduleObservation = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.runtime.menuViewModel.updateModuleDemand(
                    visibleModuleIDs: Set(self.runtime.registry.visibleModules.map(\.id))
                )
                self.rebuildMenu()
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.runtime.registry.modules
                        _ = self.runtime.registry.layout
                    } onChange: {
                        Task { @MainActor in continuation.resume() }
                    }
                }
            }
        }
    }

    private func rebuildMenu() {
        // A settings page can persist several defaults in quick succession.
        // Coalescing prevents rebuilding every hosting view for each switch.
        menuRebuildTask?.cancel()
        menuRebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, let self else { return }
            self.runtime.menuBuilder.populateMenu(self.menu)
        }
    }

    private func requestNotificationPermissions() {
        guard !Defaults[.disableNotifications],
              runtime.registry.module(id: BuiltInModuleCatalog.chargingControlID)?.isEnabled == true
                || runtime.registry.enabledModules.contains(where: {
                    $0.descriptor.permissions.contains("notifications")
                })
        else { return }
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in }
    }

    func menuWillOpen(_ menu: NSMenu) {
        runtime.statusBarManager.setMenuHighlighted(true)
        runtime.menuWillOpen()
    }

    func menuDidClose(_ menu: NSMenu) {
        runtime.statusBarManager.setMenuHighlighted(false)
        runtime.menuDidClose()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let runtime else { return .terminateNow }
        guard !terminationInProgress else { return .terminateLater }
        terminationInProgress = true
        Task { @MainActor in
            await runtime.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
