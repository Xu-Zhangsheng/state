import Defaults
import Foundation
import Observation

/// Runs a user-guided battery gauge calibration cycle.
///
/// macOS does not expose a public API for rewriting the fuel-gauge health
/// value. This coordinator therefore performs the safe, reversible part of a
/// calibration: it requests a temporary 100% policy override, waits for the
/// user to unplug and discharge to 10%, then waits for a full recharge. It
/// never rewrites the user's persistent charging configuration.
@MainActor
@Observable
final class BatteryCalibrationManager {
    enum Phase: String, CaseIterable, Sendable {
        case idle
        case chargingToFull
        case discharging
        case chargingAgain
        case completed
    }

    private struct LegacySavedConfiguration: Codable {
        let manageCharging: Bool
        let chargeLimit: Int
        let sailingMode: Bool
        let automaticDischarge: Bool
    }

    private let batteryService: BatteryService
    private let chargeManager: ChargeManager
    private let storage = UserDefaults.standard
    private let phaseKey = "batteryCalibration.phase"
    private var monitorTask: Task<Void, Never>?
    private var interfaceVisible = false

    private(set) var phase: Phase
    private(set) var currentPercentage = 0
    private(set) var adapterConnected = false
    private(set) var errorMessage: String?

    init(batteryService: BatteryService, chargeManager: ChargeManager) {
        self.batteryService = batteryService
        self.chargeManager = chargeManager
        self.phase = Phase(rawValue: storage.string(forKey: phaseKey) ?? "") ?? .idle
        migrateLegacyPersistentOverrideIfNeeded()
        refreshSnapshot()
        chargeManager.setCalibrationOverrideActive(isActive)
        if isActive { startMonitoringIfNeeded() }
    }

    var isActive: Bool {
        phase != .idle && phase != .completed
    }

    var progress: Double {
        Double(currentPercentage) / 100
    }

    var statusTitle: String {
        switch phase {
        case .idle:
            String(localized: "Ready to calibrate")
        case .chargingToFull:
            String(localized: "Charge to 100%")
        case .discharging:
            String(localized: "Discharge to 10%")
        case .chargingAgain:
            String(localized: "Recharge to 100%")
        case .completed:
            String(localized: "Calibration complete")
        }
    }

    var statusDescription: String {
        switch phase {
        case .idle:
            String(localized: "Connect the power adapter before starting.")
        case .chargingToFull:
            String(localized: "Keep the adapter connected until the battery reaches 100%.")
        case .discharging:
            if adapterConnected {
                String(localized: "Unplug the adapter and use your Mac until the battery reaches 10%.")
            } else {
                String(localized: "Use your Mac until the battery reaches 10%.")
            }
        case .chargingAgain:
            if adapterConnected {
                String(localized: "Keep the adapter connected until the battery reaches 100%.")
            } else {
                String(localized: "Connect the adapter to begin the final charge.")
            }
        case .completed:
            String(localized: "The calibration cycle is complete and your previous settings were restored.")
        }
    }

    func start() {
        guard phase == .idle || phase == .completed else { return }

        guard ChargingHelperManager.shared.isOperational else {
            errorMessage = String(localized: "Charging control is unavailable. Install and authorize the state helper first.")
            return
        }
        guard batteryService.adapterMetrics.adapterConnected else {
            errorMessage = String(localized: "Connect the power adapter before starting battery calibration.")
            return
        }

        errorMessage = nil
        setPhase(.chargingToFull)
        startMonitoringIfNeeded()
        refreshSnapshot()
    }

    func cancel() {
        guard isActive else {
            if phase == .completed { setPhase(.idle) }
            return
        }
        setPhase(.idle)
        errorMessage = nil
    }

    func dismissError() {
        errorMessage = nil
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    func startMonitoringIfNeeded() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshSnapshot()
                self?.advancePhaseIfNeeded()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func setInterfaceVisible(_ visible: Bool) {
        interfaceVisible = visible
        if visible || isActive {
            startMonitoringIfNeeded()
        } else {
            stopMonitoring()
        }
    }

    private func refreshSnapshot() {
        let metrics = batteryService.metrics
        currentPercentage = max(
            0,
            min(
                100,
                Defaults[.useHardwarePercentage]
                    ? metrics.hardwareBatteryPercentage
                    : metrics.batteryPercentage
            )
        )
        adapterConnected = batteryService.adapterMetrics.adapterConnected
    }

    private func advancePhaseIfNeeded() {
        switch phase {
        case .chargingToFull where currentPercentage >= 99 && adapterConnected:
            setPhase(.discharging)
        case .discharging where currentPercentage <= 10 && !adapterConnected:
            setPhase(.chargingAgain)
        case .chargingAgain where currentPercentage >= 99 && adapterConnected:
            setPhase(.completed)
        default:
            break
        }
    }

    private func setPhase(_ newPhase: Phase) {
        phase = newPhase
        storage.set(newPhase.rawValue, forKey: phaseKey)
        chargeManager.setCalibrationOverrideActive(isActive)
        if !isActive && !interfaceVisible { stopMonitoring() }
    }

    private func migrateLegacyPersistentOverrideIfNeeded() {
        let legacyKey = "batteryCalibration.savedConfiguration"
        defer { storage.removeObject(forKey: legacyKey) }
        guard let data = storage.data(forKey: legacyKey),
              let saved = try? JSONDecoder().decode(LegacySavedConfiguration.self, from: data)
        else { return }
        Defaults[.manageCharging] = saved.manageCharging
        Defaults[.chargeLimit] = saved.chargeLimit
        Defaults[.sailingMode] = saved.sailingMode
        Defaults[.automaticDischarge] = saved.automaticDischarge
    }
}
