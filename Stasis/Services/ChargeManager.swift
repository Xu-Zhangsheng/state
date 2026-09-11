import Defaults
import Foundation
import IOKit.pwr_mgt
import Observation
import UserNotifications
import os.log
import smc_power

@MainActor
@Observable
class ChargeManager {
    private struct PowerStateRequest: Equatable {
        let charging: Bool?
        let externalPower: Bool?
        let led: MagSafeLEDState?
    }

    private let batteryService: BatteryService

    private var metricsObservation: Task<Void, Never>?
    private var settingsObservation: Task<Void, Never>?

    private var lastAdapterConnected: Bool?
    private var lastManageChargingEnabled: Bool?
    private var hasReachedChargeLimit = false
    private var lastNotifiedChargingState: Bool?
    private var queuedPowerState: PowerStateRequest?
    private var lastAppliedPowerState: PowerStateRequest?
    private var powerStateTask: Task<Void, Never>?
    private var moduleEnabled = true
    private var isShuttingDown = false

    private(set) var chargeLimitOverrideActive = false
    private(set) var forceDischargeActive = false
    private(set) var calibrationOverrideActive = false
    private var sleepAssertionID: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)

    private let logger = Logger(
        subsystem: "com.srimanachanta.stasis",
        category: "ChargeManager"
    )

    init(batteryService: BatteryService) {
        self.batteryService = batteryService
        startObservingMetrics()
        startObservingSettings()
    }

    private func startObservingMetrics() {
        metricsObservation = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.evaluate(controlState: self.batteryService.controlState)
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.batteryService.controlState
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
                    .manageCharging, .sailingMode, .automaticDischarge,
                    .disableSleepUntilChargeLimit,
                    .enableHeatProtectionMode, .manageMagSafeLED, .useHardwarePercentage,
                    .chargeLimit, .sailingModeLimit, .heatProtectionLimit,
                    .heatProtectionMagSafeLEDState,
                ],
                initial: false
            ) {
                guard let self else { return }
                self.evaluate(controlState: self.batteryService.controlState)
            }
        }
    }

    private func evaluate(controlState: BatteryControlState) {
        guard !isShuttingDown else { return }
        var stateWasCleared = false

        if controlState.adapterConnected != lastAdapterConnected {
            logger.info("Adapter connection changed: \(controlState.adapterConnected)")
            lastAdapterConnected = controlState.adapterConnected
            clearCachedState()
            stateWasCleared = true
        }

        let policyEnabled = Defaults[.manageCharging] || calibrationOverrideActive
        guard moduleEnabled, policyEnabled, controlState.adapterConnected else {
            if chargeLimitOverrideActive, !controlState.adapterConnected {
                chargeLimitOverrideActive = false
            }
            if forceDischargeActive, !controlState.adapterConnected {
                forceDischargeActive = false
            }
            resetToDefaults()
            return
        }

        guard ChargingHelperManager.shared.isOperational else {
            updateSleepAssertion(shouldPreventSleep: false)
            return
        }

        if lastManageChargingEnabled != true {
            lastManageChargingEnabled = true
            clearCachedState()
            stateWasCleared = true
        }

        let chargeLimit = (chargeLimitOverrideActive || calibrationOverrideActive)
            ? 100 : Defaults[.chargeLimit]
        let sailingModeEnabled = calibrationOverrideActive ? false : Defaults[.sailingMode]
        let automaticDischargeEnabled = calibrationOverrideActive
            ? false : Defaults[.automaticDischarge]
        let batteryPercentage =
            Defaults[.useHardwarePercentage]
            ? controlState.hardwareBatteryPercentage : controlState.batteryPercentage

        if stateWasCleared && sailingModeEnabled
            && batteryPercentage >= chargeLimit - Defaults[.sailingModeLimit] {
            hasReachedChargeLimit = true
        }

        var desiredCharging: Bool?
        var desiredAdapter: Bool?
        var desiredLED: MagSafeLEDState?
        var chargingStateReason: String?

        if batteryPercentage > chargeLimit {
            hasReachedChargeLimit = true
            desiredCharging = false
            desiredAdapter = automaticDischargeEnabled ? false : true
            desiredLED = Defaults[.manageMagSafeLED] ? .green : nil
            chargingStateReason = "Battery is above the charge limit of \(chargeLimit)%"
        } else if batteryPercentage == chargeLimit {
            hasReachedChargeLimit = true
            desiredCharging = false
            desiredAdapter = true
            desiredLED = Defaults[.manageMagSafeLED] ? .green : nil
            chargingStateReason = "Battery has reached the charge limit of \(chargeLimit)%"
        } else if sailingModeEnabled {
            let sailingThreshold = chargeLimit - Defaults[.sailingModeLimit]
            let inSailingRange = batteryPercentage >= sailingThreshold

            if inSailingRange && hasReachedChargeLimit {
                desiredCharging = false
                desiredAdapter = true
                desiredLED = Defaults[.manageMagSafeLED] ? .green : nil
                chargingStateReason = "Sailing mode is maintaining charge below \(chargeLimit)%"
            } else {
                let droppedOutOfSailingRange = !inSailingRange && hasReachedChargeLimit
                hasReachedChargeLimit = false
                desiredCharging = true
                desiredAdapter = true
                desiredLED = Defaults[.manageMagSafeLED] ? .orange : nil
                if inSailingRange {
                    chargingStateReason = "Charging to reach charge limit of \(chargeLimit)%"
                } else if droppedOutOfSailingRange {
                    chargingStateReason =
                        "Battery dropped below sailing threshold of \(sailingThreshold)%"
                } else {
                    chargingStateReason = "Battery is below the charge limit of \(chargeLimit)%"
                }
            }
        } else {
            desiredCharging = true
            desiredAdapter = true
            desiredLED = Defaults[.manageMagSafeLED] ? .orange : nil
            chargingStateReason = "Battery is below the charge limit of \(chargeLimit)%"
        }

        if Defaults[.enableHeatProtectionMode]
            && controlState.batteryTemperature > Double(Defaults[.heatProtectionLimit])
        {
            desiredCharging = false
            chargingStateReason =
                "Battery temperature exceeds \(Defaults[.heatProtectionLimit])°C"
            if Defaults[.manageMagSafeLED] {
                desiredLED = Defaults[.heatProtectionMagSafeLEDState]
            }
        }

        if forceDischargeActive {
            desiredCharging = false
            desiredAdapter = false
        }

        let capabilities = batteryService.deviceCapabilities

        if let desiredCharging {
            sendChargingStateNotification(
                charging: desiredCharging, reason: chargingStateReason
            )
        }
        enqueuePowerState(PowerStateRequest(
            charging: capabilities.chargingControl ? desiredCharging : nil,
            externalPower: capabilities.adapterControl ? desiredAdapter : nil,
            led: capabilities.hasMagSafe && capabilities.magsafeLEDControl
                ? (desiredLED ?? .reset) : nil
        ))

        let shouldPreventSleep = Defaults[.disableSleepUntilChargeLimit]
            && desiredCharging == true
        updateSleepAssertion(shouldPreventSleep: shouldPreventSleep)
    }

    private func clearCachedState() {
        lastNotifiedChargingState = nil
        hasReachedChargeLimit = false
        queuedPowerState = nil
        lastAppliedPowerState = nil
    }

    private func resetToDefaults() {
        let shouldRestoreHardware = lastManageChargingEnabled == true
            || chargeLimitOverrideActive
            || forceDischargeActive
            || calibrationOverrideActive
        hasReachedChargeLimit = false
        lastManageChargingEnabled = false
        updateSleepAssertion(shouldPreventSleep: false)
        guard shouldRestoreHardware, ChargingHelperManager.shared.isInstalled else { return }
        enqueuePowerState(defaultPowerState)
    }

    /// Fixed recovery path used when a module loses its control lease. This
    /// does not trust a module-supplied command: it restores charging,
    /// external power and the MagSafe indicator through the existing typed
    /// helper operations.
    func restoreSystemDefaults() {
        clearCachedState()
        hasReachedChargeLimit = false
        updateSleepAssertion(shouldPreventSleep: false)
        guard ChargingHelperManager.shared.isInstalled else { return }
        enqueuePowerState(defaultPowerState)
    }

    /// Synchronous-from-the-caller recovery used by orderly application
    /// termination. Unlike the fire-and-forget setters, this waits for the
    /// helper replies before AppKit is allowed to end the process.
    func restoreSystemDefaultsAndWait() async {
        isShuttingDown = true
        stopObservingPolicyInputs()
        clearCachedState()
        hasReachedChargeLimit = false
        updateSleepAssertion(shouldPreventSleep: false)
        guard ChargingHelperManager.shared.isInstalled else { return }
        await powerStateTask?.value
        let request = defaultPowerState
        do {
            try await batteryService.applyPowerState(
                chargingEnabled: request.charging,
                externalPowerEnabled: request.externalPower,
                magSafeLED: request.led
            )
            lastAppliedPowerState = request
        } catch {
            lastAppliedPowerState = nil
            logger.error("Failed to restore grouped power state during shutdown: \(error)")
        }
    }

    private var defaultPowerState: PowerStateRequest {
        let capabilities = batteryService.deviceCapabilities
        return PowerStateRequest(
            charging: capabilities.chargingControl ? true : nil,
            externalPower: capabilities.adapterControl ? true : nil,
            led: capabilities.hasMagSafe && capabilities.magsafeLEDControl ? .reset : nil
        )
    }

    private func enqueuePowerState(_ request: PowerStateRequest) {
        guard !isShuttingDown else { return }
        guard request != lastAppliedPowerState || powerStateTask != nil else { return }
        queuedPowerState = request
        guard powerStateTask == nil else { return }
        powerStateTask = Task { [weak self] in
            await self?.drainPowerStateQueue()
        }
    }

    private func drainPowerStateQueue() async {
        while let request = queuedPowerState {
            queuedPowerState = nil
            logger.info(
                "Applying grouped power state: charging=\(String(describing: request.charging)), adapter=\(String(describing: request.externalPower)), LED=\(String(describing: request.led))"
            )
            do {
                try await batteryService.applyPowerState(
                    chargingEnabled: request.charging,
                    externalPowerEnabled: request.externalPower,
                    magSafeLED: request.led
                )
                lastAppliedPowerState = request
                ChargingHelperManager.shared.markOperational()
                batteryService.scheduleSinglePoll()
            } catch {
                lastAppliedPowerState = nil
                logger.error("Failed to apply grouped power state: \(error)")
            }
        }
        powerStateTask = nil
    }

    private func updateSleepAssertion(shouldPreventSleep: Bool) {
        let assertionActive = sleepAssertionID != IOPMAssertionID(kIOPMNullAssertionID)

        if shouldPreventSleep && !assertionActive {
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "state: Charging towards charge limit" as CFString,
                &sleepAssertionID
            )
            if result == kIOReturnSuccess {
                logger.info("Sleep assertion created")
            } else {
                logger.error("Failed to create sleep assertion: \(result)")
            }
        } else if !shouldPreventSleep && assertionActive {
            IOPMAssertionRelease(sleepAssertionID)
            sleepAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
            logger.info("Sleep assertion released")
        }
    }

    private func sendChargingStateNotification(charging: Bool, reason: String?) {
        guard charging != lastNotifiedChargingState else { return }
        lastNotifiedChargingState = charging

        guard !Defaults[.disableNotifications],
            Defaults[.showChargingStatusChangedNotification]
        else { return }

        let content = UNMutableNotificationContent()
        content.title = charging ? String(localized: "Charging Resumed") : String(localized: "Charging Paused")
        if let reason {
            content.body = reason
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "chargingStateChanged",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { [logger] error in
            if let error {
                logger.error("Failed to deliver notification: \(error)")
            }
        }
    }

    func toggleChargeLimitOverride() {
        guard !calibrationOverrideActive else { return }
        chargeLimitOverrideActive.toggle()
        evaluate(controlState: batteryService.controlState)
    }

    func toggleForceDischarge() {
        guard !calibrationOverrideActive else { return }
        forceDischargeActive.toggle()
        evaluate(controlState: batteryService.controlState)
    }

    func setModuleEnabled(_ enabled: Bool) {
        guard moduleEnabled != enabled else { return }
        moduleEnabled = enabled
        if !enabled {
            chargeLimitOverrideActive = false
            forceDischargeActive = false
        }
        evaluate(controlState: batteryService.controlState)
    }

    func setCalibrationOverrideActive(_ active: Bool) {
        guard calibrationOverrideActive != active else { return }
        calibrationOverrideActive = active
        if active {
            chargeLimitOverrideActive = false
            forceDischargeActive = false
        }
        clearCachedState()
        evaluate(controlState: batteryService.controlState)
    }

    func stop() {
        stopObservingPolicyInputs()
        powerStateTask?.cancel()
        powerStateTask = nil
        queuedPowerState = nil
        updateSleepAssertion(shouldPreventSleep: false)
    }

    private func stopObservingPolicyInputs() {
        metricsObservation?.cancel()
        metricsObservation = nil
        settingsObservation?.cancel()
        settingsObservation = nil
    }
}
