import AppKit
import Defaults
import Foundation
import Observation

@MainActor
@Observable
class MenuViewModel {
    private enum BatteryFlowDirection {
        case idle
        case charging
        case discharging
    }

    private static let flowEnterThreshold = 0.5
    private static let flowExitThreshold = 0.2

    private let batteryService: BatteryService
    private let chargeManager: ChargeManager
    private let highEnergyAppsService: HighEnergyAppsService
    private let bootTimestamp: Date?

    var batteryPercentageText: String = "0%"
    var powerSourceText: String = String(localized: "Battery")
    var timeRemainingText: String = String(localized: "Calculating…")
    var uptimeText: String = "0m"
    var batteryModeText: String = String(localized: "Unknown")
    var batteryTemperatureText: String = "0°C"
    var externalInputText: String = "0V @ 0A"
    var internalInputText: String = "0V @ 0A"
    var cycleCountText: String = "0"
    var batteryHealthText: String = "100%"

    var displayPercentage: Int = 0
    var chargingMode: ChargingMode = .discharging
    /// Published after all display-facing battery fields have been formatted.
    /// The status item observes this revision instead of individual fields so
    /// it never renders a new percentage with the previous charging state.
    private(set) var statusRevision: UInt = 0
    var batteryPower: Double = 0
    var adapterPower: Double = 0
    var systemPower: Double = 0
    var powerSource: PowerSource = .battery
    var isCharging: Bool = false
    var highEnergyApps: [HighEnergyApp] = []
    var isHighEnergySampleReady = false
    var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    private(set) var externalPowerSnapshot = ExternalPowerSnapshot.empty
    private(set) var chipPowerReading: Double?
    /// Discrete layout state observed by AppKit. Continuous watt changes do
    /// not touch this flag, so the menu is resized only when the flow switches
    /// between its compact and detailed structures.
    private(set) var showsDetailedPowerFlow = false

    /// Builds the third-level branches selected in Dashboard settings. The
    /// values are snapshots for the open menu: no external-device scan or chip
    /// sampler is started for the second-level view or a hidden power flow.
    var powerBreakdown: [PowerBreakdownItem] {
        guard DashboardLayoutStore.isModuleVisible(.powerMonitoring),
              Defaults[.showPowerDistribution],
              Defaults[.powerFlowDetailLevel] == .level3,
              systemPower > 0.1
        else { return [] }

        // SMC power updates are intentionally fast for the main readout. Keep
        // the optional branch accounting on a slower, smoothed total so the
        // residual "other" branch does not amplify every sensor tick.
        let total = max(0, smoothedPowerBreakdownTotal ?? systemPower)
        var remaining = total
        var result: [PowerBreakdownItem] = []

        if externalPowerSnapshot.watts > 0.1 {
            let power = min(remaining, externalPowerSnapshot.watts)
            result.append(
                PowerBreakdownItem(
                    id: "external-devices",
                    name: String(localized: "External Devices"),
                    power: power,
                    systemImage: "arrow.up.forward",
                    icon: nil,
                    isEstimated: true
                )
            )
            remaining -= power
        }

        let displayCeiling = min(
            remaining * 0.35,
            Double(max(1, NSScreen.screens.count)) * 3.5
        )
        let displayPower = min(remaining, max(0, displayCeiling))
        if displayPower > 0.1 {
            result.append(
                PowerBreakdownItem(
                    id: "display",
                    name: String(localized: "Display"),
                    power: displayPower,
                    systemImage: "display",
                    icon: nil,
                    isEstimated: true
                )
            )
            remaining -= displayPower
        }

        if let chipPowerReading {
            let power = min(
                remaining,
                max(0, chipPowerReading)
            )
            if power > 0.1 {
                result.append(
                    PowerBreakdownItem(
                        id: "m2-chip",
                        name: String(localized: "M2 Chip"),
                        power: power,
                        systemImage: "cpu",
                        icon: nil,
                        isEstimated: false
                    )
                )
                remaining -= power
            }
        }

        if remaining > 0.1 {
            result.append(
                PowerBreakdownItem(
                    id: "other-system-power",
                    name: String(localized: "Other"),
                    power: remaining,
                    systemImage: "ellipsis",
                    icon: nil,
                    isEstimated: true
                )
            )
        }

        return result
    }

    var chargeLimitOverrideActive: Bool { chargeManager.chargeLimitOverrideActive }
    var forceDischargeActive: Bool { chargeManager.forceDischargeActive }
    var calibrationOverrideActive: Bool { chargeManager.calibrationOverrideActive }
    var manageChargingEnabled: Bool {
        Defaults[.manageCharging] && ChargingHelperManager.shared.isOperational
    }
    var adapterConnected: Bool = false
    private var visibleModuleIDs = Set(BuiltInModuleCatalog.recommended.map(\.id))

    private var highEnergyAppsEnabled: Bool {
        visibleModuleIDs.contains(BuiltInModuleCatalog.energyAppsID)
            && Defaults[.showHighEnergyApps]
    }

    private var uptimeEnabled: Bool {
        visibleModuleIDs.contains(BuiltInModuleCatalog.systemInfoID)
            && Defaults[.showUptime]
    }

    private var metricsObservation: Task<Void, Never>?
    private var settingsObservation: Task<Void, Never>?
    private var uptimeTask: Task<Void, Never>?
    private var highEnergyObservation: Task<Void, Never>?
    private var chipPowerTask: Task<Void, Never>?
    private var chipPowerSamples: [Double] = []
    private var smoothedPowerBreakdownTotal: Double?
    private var systemPowerStateObserver: NSObjectProtocol?
    private var isMenuOpen = false
    private var didRefreshExternalPowerForMenu = false
    private var batteryFlowDirection: BatteryFlowDirection = .idle

    init(
        batteryService: BatteryService,
        chargeManager: ChargeManager,
        highEnergyAppsService: HighEnergyAppsService = HighEnergyAppsService()
    ) {
        self.batteryService = batteryService
        self.chargeManager = chargeManager
        self.highEnergyAppsService = highEnergyAppsService
        self.bootTimestamp = SystemService.bootTimestamp()
        startObservingMetrics()
        startObservingSettings()
        startObservingHighEnergyApps()
        observeSystemPowerState()
    }

    private func startObservingMetrics() {
        metricsObservation = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.updateFormattedValues(
                    from: self.batteryService.metrics,
                    adapter: self.batteryService.adapterMetrics
                )
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        // BatteryService increments this only after its
                        // battery and adapter values are published together.
                        _ = self.batteryService.telemetryRevision
                    } onChange: {
                        Task { @MainActor in
                            continuation.resume()
                        }
                    }
                }
            }
        }
    }

    private func startObservingSettings() {
        settingsObservation = Task { [weak self] in
            for await _ in Defaults.updates(
                [
                    .useHardwarePercentage, .showHighEnergyApps,
                    .showPowerDistribution, .powerFlowDetailLevel,
                    .dashboardVisibleModules, .showUptime,
                ],
                initial: false
            ) {
                guard let self else { return }
                self.updateFormattedValues(
                    from: self.batteryService.metrics,
                    adapter: self.batteryService.adapterMetrics
                )
                if self.highEnergyAppsEnabled && self.isMenuOpen {
                    self.highEnergyAppsService.startSampling()
                } else {
                    self.highEnergyAppsService.stopSampling()
                    if !self.highEnergyAppsEnabled {
                        self.highEnergyApps = []
                    }
                }
                self.configurePowerBreakdownSampling()
                if self.uptimeEnabled && self.isMenuOpen {
                    self.updateUptimeText()
                    self.startUptimeTimer()
                } else {
                    self.stopUptimeTimer()
                }
            }
        }
    }

    private func startObservingHighEnergyApps() {
        highEnergyObservation = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.highEnergyApps = self.highEnergyAppsService.apps
                self.isHighEnergySampleReady = self.highEnergyAppsService.hasCompletedSample
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.highEnergyAppsService.apps
                        _ = self.highEnergyAppsService.hasCompletedSample
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }
    }

    func toggleChargeLimitOverride() {
        chargeManager.toggleChargeLimitOverride()
    }

    func toggleForceDischarge() {
        chargeManager.toggleForceDischarge()
    }

    private func updateFormattedValues(from metrics: BatteryMetrics, adapter: AdapterMetrics) {
        let useHardware = Defaults[.useHardwarePercentage]
        let selectedPercentage =
            useHardware
            ? metrics.hardwareBatteryPercentage : metrics.batteryPercentage
        let percentage = max(0, min(100, selectedPercentage))
        displayPercentage = percentage
        batteryPercentageText = "\(percentage)%"

        let stableBatteryPower = stabilizedBatteryPower(metrics.batteryPower)
        let stableAdapterPower = abs(adapter.adapterPower) >= Self.flowEnterThreshold
            ? adapter.adapterPower : 0
        let derivedPowerSource = derivePowerSource(
            battery: metrics,
            adapter: adapter,
            batteryPower: stableBatteryPower,
            adapterPower: stableAdapterPower
        )

        switch derivedPowerSource {
        case .battery:
            powerSourceText = String(localized: "Battery")
        case .acAdapter:
            powerSourceText = String(localized: "Power Adapter")
        case .both:
            powerSourceText = String(localized: "Battery & Power Adapter")
        }

        let formatted = formatTimeRemaining(minutes: metrics.timeRemaining)
        if !formatted.isEmpty {
            timeRemainingText = formatted
        } else if derivedPowerSource == .acAdapter && !metrics.isCharging {
            timeRemainingText = String(localized: "Not Charging")
        } else {
            timeRemainingText = String(localized: "Calculating…")
        }

        updateUptimeText()

        if metrics.isUsingACPower || metrics.isCharging {
            if metrics.isCharging {
                chargingMode = .charging
                batteryModeText = String(localized: "Charging")
            } else {
                chargingMode = .pluggedIn
                batteryModeText = String(localized: "Plugged In (Not Charging)")
            }
        } else {
            chargingMode = .discharging
            batteryModeText = String(localized: "Discharging")
        }

        batteryTemperatureText =
            "\(metrics.batteryTemperature.formatted(.number.precision(.fractionLength(1))))°C"

        let voltageFormat = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(2))
        let currentFormat = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(2))

        externalInputText =
            "\(adapter.adapterVoltage.formatted(voltageFormat))V @ \(adapter.adapterCurrent.formatted(currentFormat))A"

        internalInputText =
            "\(metrics.batteryVoltage.formatted(voltageFormat))V @ \(metrics.batteryCurrent.formatted(currentFormat))A"

        batteryPower = stableBatteryPower
        adapterPower = stableAdapterPower
        systemPower = max(0, stableAdapterPower - stableBatteryPower)
        if powerSource != derivedPowerSource {
            powerSource = derivedPowerSource
            // USB output can change when the adapter is connected or removed.
            // Force one fresh menu-open scan after a real source transition.
            didRefreshExternalPowerForMenu = false
        }
        if isCharging != metrics.isCharging {
            isCharging = metrics.isCharging
        }
        if adapterConnected != adapter.adapterConnected {
            adapterConnected = adapter.adapterConnected
        }

        updatePowerBreakdownSmoothing(systemPower: systemPower)

        cycleCountText = "\(metrics.cycleCount)"
        batteryHealthText = "\(metrics.batteryHealth)%"

        configurePowerBreakdownSampling()
        updatePowerBreakdownVisibility()
        statusRevision &+= 1
    }

    private func derivePowerSource(
        battery: BatteryMetrics,
        adapter: AdapterMetrics,
        batteryPower: Double,
        adapterPower: Double
    ) -> PowerSource {
        if battery.isUsingACPower || battery.isCharging {
            return .acAdapter
        }

        guard adapter.adapterConnected || battery.externalConnected else {
            return .battery
        }

        // A connected adapter can coexist with intentional battery discharge.
        // Only show a merged flow when both measurements are meaningfully
        // outside their noise floor.
        if batteryPower < 0, adapterPower > 0 {
            return .both
        }
        return .battery
    }

    private func stabilizedBatteryPower(_ rawPower: Double) -> Double {
        switch batteryFlowDirection {
        case .idle:
            if rawPower >= Self.flowEnterThreshold {
                batteryFlowDirection = .charging
            } else if rawPower <= -Self.flowEnterThreshold {
                batteryFlowDirection = .discharging
            }

        case .charging:
            if rawPower <= -Self.flowEnterThreshold {
                batteryFlowDirection = .discharging
            } else if rawPower <= Self.flowExitThreshold {
                batteryFlowDirection = .idle
            }

        case .discharging:
            if rawPower >= Self.flowEnterThreshold {
                batteryFlowDirection = .charging
            } else if rawPower >= -Self.flowExitThreshold {
                batteryFlowDirection = .idle
            }
        }

        return batteryFlowDirection == .idle ? 0 : rawPower
    }

    private func updatePowerBreakdownSmoothing(systemPower: Double) {
        guard isMenuOpen,
              DashboardLayoutStore.isModuleVisible(.powerMonitoring),
              Defaults[.showPowerDistribution],
              Defaults[.powerFlowDetailLevel] == .level3
        else {
            smoothedPowerBreakdownTotal = nil
            return
        }

        let sample = max(0, systemPower)
        guard let previous = smoothedPowerBreakdownTotal else {
            smoothedPowerBreakdownTotal = sample
            return
        }

        // A light EMA removes sensor jitter without making a real adapter
        // load change wait for a long averaging window.
        smoothedPowerBreakdownTotal = previous + (sample - previous) * 0.25
    }

    private func updateUptimeText() {
        guard let bootTimestamp else {
            uptimeText = String(localized: "Unknown")
            return
        }

        let elapsed = Duration.seconds(Date().timeIntervalSince(bootTimestamp))
        uptimeText = elapsed.formatted(.units(
            allowed: [.days, .hours, .minutes],
            width: .condensedAbbreviated,
            zeroValueUnits: .hide
        ))
    }

    private func startUptimeTimer() {
        guard uptimeTask == nil else { return }

        uptimeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.updateUptimeText()
            }
        }
    }

    private func stopUptimeTimer() {
        uptimeTask?.cancel()
        uptimeTask = nil
    }

    func menuWillOpen() {
        isMenuOpen = true
        didRefreshExternalPowerForMenu = false
        configurePowerBreakdownSampling()
        updatePowerBreakdownVisibility()
        batteryService.refreshPowerState()
        if uptimeEnabled {
            updateUptimeText()
            startUptimeTimer()
        }
        batteryService.enableFastPolling()
        if highEnergyAppsEnabled {
            highEnergyAppsService.startSampling()
        }
    }

    func updateModuleDemand(visibleModuleIDs: Set<String>) {
        self.visibleModuleIDs = visibleModuleIDs
        if isMenuOpen {
            if highEnergyAppsEnabled { highEnergyAppsService.startSampling() }
            else { highEnergyAppsService.stopSampling() }
            configurePowerBreakdownSampling()
        }
    }

    func menuDidClose() {
        isMenuOpen = false
        stopUptimeTimer()
        batteryService.disableFastPolling()
        highEnergyAppsService.stopSampling()
        chipPowerTask?.cancel()
        chipPowerTask = nil
        chipPowerReading = nil
        chipPowerSamples.removeAll(keepingCapacity: false)
        smoothedPowerBreakdownTotal = nil
        externalPowerSnapshot = .empty
        didRefreshExternalPowerForMenu = false
        updatePowerBreakdownVisibility()
    }

    private func configurePowerBreakdownSampling() {
        guard isMenuOpen,
              visibleModuleIDs.contains(BuiltInModuleCatalog.powerMonitoringID),
              Defaults[.showPowerDistribution],
              Defaults[.powerFlowDetailLevel] == .level3
        else {
            chipPowerTask?.cancel()
            chipPowerTask = nil
            chipPowerReading = nil
            chipPowerSamples.removeAll(keepingCapacity: false)
            smoothedPowerBreakdownTotal = nil
            externalPowerSnapshot = .empty
            return
        }

        if !didRefreshExternalPowerForMenu {
            externalPowerSnapshot = ExternalPowerService.snapshot()
            didRefreshExternalPowerForMenu = true
        }

        guard chipPowerTask == nil else {
            return
        }

        chipPowerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let reading = await self.batteryService.readChipPower()
                guard !Task.isCancelled else { return }
                if let reading, reading.isFinite, reading >= 0 {
                    self.chipPowerSamples.append(reading)
                    if self.chipPowerSamples.count > 3 {
                        self.chipPowerSamples.removeFirst()
                    }
                    let sorted = self.chipPowerSamples.sorted()
                    let median = sorted[sorted.count / 2]
                    if let current = self.chipPowerReading {
                        self.chipPowerReading = current + (median - current) * 0.3
                    } else {
                        self.chipPowerReading = median
                    }
                    self.updatePowerBreakdownVisibility()
                }
                // powermetrics itself samples for one second. Pausing another
                // second keeps this optional branch near a two-second cadence
                // and prevents a privileged sampler from running in a tight
                // loop. This task is cancelled as soon as the menu closes.
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func updatePowerBreakdownVisibility() {
        let isVisible = !powerBreakdown.isEmpty
        if showsDetailedPowerFlow != isVisible {
            showsDetailedPowerFlow = isVisible
        }
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func formatTimeRemaining(minutes: Int) -> String {
        if minutes < 0 {
            return ""
        }
        let hours = minutes / 60
        let mins = minutes % 60
        return String(format: "%02d:%02d", hours, mins)
    }

    private func observeSystemPowerState() {
        systemPowerStateObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
                self.statusRevision &+= 1
            }
        }
    }

    deinit {
        MainActor.assumeIsolated {
            metricsObservation?.cancel()
            settingsObservation?.cancel()
            uptimeTask?.cancel()
            highEnergyObservation?.cancel()
            highEnergyAppsService.stopSampling()
            if let systemPowerStateObserver {
                NotificationCenter.default.removeObserver(systemPowerStateObserver)
            }
        }
    }
}
