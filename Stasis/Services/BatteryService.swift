import Foundation
import Observation
import os.log
import smc_power

enum XPCError: LocalizedError {
    case helperUnavailable
    case connectionFailed(String)
    case commandFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .helperUnavailable:
            "XPC helper is unavailable"
        case .connectionFailed(let message):
            "XPC connection failed: \(message)"
        case .commandFailed(let message):
            "Command failed: \(message)"
        case .timedOut:
            "XPC command timed out"
        }
    }
}

@MainActor
private final class XPCCommandAttempt {
    private var didFinish = false
    private let continuation: CheckedContinuation<Void, Error>

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<Void, Error>) {
        guard !didFinish else { return }
        didFinish = true
        continuation.resume(with: result)
    }
}

@MainActor
@Observable
class BatteryService {
    private(set) var metrics = BatteryMetrics()
    private(set) var adapterMetrics = AdapterMetrics()
    /// Incremented only after battery and adapter values have been published
    /// together. Consumers can use it as the single observation point for a
    /// coherent status snapshot.
    private(set) var telemetryRevision: UInt = 0
    private(set) var controlState = BatteryControlState()
    private(set) var deviceCapabilities = DeviceCapabilities(
        chargingControl: false,
        adapterControl: false,
        hasMagSafe: false,
        magsafeLEDControl: false
    )

    private let xpcManager = SMCReaderConnection(
        serviceName: "com.srimanachanta.stasis.helper"
    )
    private let ioKitService = IOKitService()

    private var ioKitMonitorTask: Task<Void, Never>?
    private var smcPollTask: Task<Void, Never>?
    private var delayedPollTask: Task<Void, Never>?
    private(set) var isRunning = false

    private let logger = Logger(
        subsystem: "com.srimanachanta.stasis",
        category: "BatteryService"
    )

    init() {
        logger.info("BatteryService initialized")
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        xpcManager.connect()
        startIOKitMonitoring()
    }

    func loadCapabilities() async {
        guard isRunning else { return }
        let logger = self.logger
        guard
            let helper = xpcManager.getHelper(errorHandler: { error in
                logger.error(
                    "XPC error loading capabilities: \(error.localizedDescription)")
            })
        else {
            logger.warning("Helper unavailable for capability probe")
            return
        }

        let capabilities: DeviceCapabilities = await withCheckedContinuation { continuation in
            helper.getCapabilities { chargingControl, adapterControl, hasMagSafe, magsafeLEDControl in
                continuation.resume(
                    returning: DeviceCapabilities(
                        chargingControl: chargingControl,
                        adapterControl: adapterControl,
                        hasMagSafe: hasMagSafe,
                        magsafeLEDControl: magsafeLEDControl
                    )
                )
            }
        }

        self.deviceCapabilities = capabilities
        logger.info(
            "Capabilities loaded: charging=\(capabilities.chargingControl), adapter=\(capabilities.adapterControl), magSafe=\(capabilities.hasMagSafe)"
        )
    }

    private func startIOKitMonitoring() {
        logger.info("Starting IOKit monitoring in main app")
        ioKitMonitorTask = Task {
            for await (newBatteryMetrics, newAdapterMetrics) in self.ioKitService.metricsStream() {
                guard !Task.isCancelled else { break }
                self.handleIOKitUpdate(newBatteryMetrics, adapterUpdate: newAdapterMetrics)
            }
        }
    }

    func enableFastPolling() {
        guard isRunning else { return }
        guard smcPollTask == nil else {
            logger.warning("Fast polling already enabled")
            return
        }

        logger.info("Enabling fast SMC polling")

        smcPollTask = Task {
            await self.pollSMCOnce()
            while !Task.isCancelled {
                // IOKit already pushes state changes. This poll only refines
                // the SMC power readings shown in an open menu.
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                await self.pollSMCOnce()
            }
        }
    }

    func refreshPowerState() {
        guard isRunning else { return }
        ioKitService.refresh()
    }

    func scheduleSinglePoll(delay: Duration = .seconds(3)) {
        guard isRunning else { return }
        delayedPollTask?.cancel()
        delayedPollTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self.pollSMCOnce()
        }
    }

    func disableFastPolling() {
        guard smcPollTask != nil else {
            logger.warning("Fast polling not enabled")
            return
        }

        logger.info("Disabling fast SMC polling")
        smcPollTask?.cancel()
        smcPollTask = nil
    }

    private func fetchSMCBatteryData() async -> SMCBatteryReading? {
        let logger = self.logger
        guard
            let helper = xpcManager.getHelper(errorHandler: { error in
                logger.error(
                    "XPC error during SMC battery poll: \(error.localizedDescription)"
                )
            })
        else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            helper.readBatteryMetrics { batteryVoltage, batteryCurrent, batteryPower in
                continuation.resume(
                    returning: SMCBatteryReading(
                        batteryVoltage: batteryVoltage,
                        batteryCurrent: batteryCurrent,
                        batteryPower: batteryPower
                    )
                )
            }
        }
    }

    private func fetchSMCAdapterData() async -> SMCAdapterReading? {
        let logger = self.logger
        guard
            let helper = xpcManager.getHelper(errorHandler: { error in
                logger.error(
                    "XPC error during SMC adapter poll: \(error.localizedDescription)"
                )
            })
        else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            helper.readAdapterMetrics { adapterVoltage, adapterCurrent, adapterPower in
                continuation.resume(
                    returning: SMCAdapterReading(
                        adapterVoltage: adapterVoltage,
                        adapterCurrent: adapterCurrent,
                        adapterPower: adapterPower
                    )
                )
            }
        }
    }

    private func pollSMCOnce() async {
        async let batteryData = fetchSMCBatteryData()
        async let adapterData = fetchSMCAdapterData()

        guard let batteryReading = await batteryData, let adapterReading = await adapterData else {
            logger.error("No helper available for SMC battery polling")
            return
        }

        var updatedBattery = metrics
        updatedBattery.batteryVoltage = batteryReading.batteryVoltage
        updatedBattery.batteryCurrent = batteryReading.batteryCurrent
        updatedBattery.batteryPower = batteryReading.batteryPower

        var updatedAdapter = adapterMetrics
        updatedAdapter.adapterVoltage = adapterReading.adapterVoltage
        updatedAdapter.adapterCurrent = adapterReading.adapterCurrent
        updatedAdapter.adapterPower = adapterReading.adapterPower

        publishSnapshot(battery: updatedBattery, adapter: updatedAdapter)
    }

    private func handleIOKitUpdate(_ newBatteryMetrics: BatteryMetrics, adapterUpdate: AdapterMetrics) {
        logger.debug("Received IOKit update")

        var updatedBattery = newBatteryMetrics
        updatedBattery.batteryVoltage = metrics.batteryVoltage
        updatedBattery.batteryCurrent = metrics.batteryCurrent
        updatedBattery.batteryPower = metrics.batteryPower

        var updatedAdapter = adapterUpdate
        updatedAdapter.adapterVoltage = adapterMetrics.adapterVoltage
        updatedAdapter.adapterCurrent = adapterMetrics.adapterCurrent
        updatedAdapter.adapterPower = adapterMetrics.adapterPower

        publishSnapshot(battery: updatedBattery, adapter: updatedAdapter)
    }

    private func publishSnapshot(
        battery: BatteryMetrics,
        adapter: AdapterMetrics
    ) {
        let batteryChanged = battery != metrics
        let adapterChanged = adapter != adapterMetrics
        guard batteryChanged || adapterChanged else { return }

        // Do not expose a state transition between these two assignments.
        // MenuViewModel observes telemetryRevision below and reads both values
        // only after this complete pair has been published.
        metrics = battery
        adapterMetrics = adapter
        updateControlState(from: battery, adapter: adapter)
        telemetryRevision &+= 1
    }

    private func updateControlState(from metrics: BatteryMetrics, adapter: AdapterMetrics) {
        let newState = BatteryControlState(
            batteryPercentage: metrics.batteryPercentage,
            hardwareBatteryPercentage: metrics.hardwareBatteryPercentage,
            adapterConnected: adapter.adapterConnected,
            batteryTemperature: metrics.batteryTemperature
        )
        if newState != controlState {
            controlState = newState
        }
    }

    func manageBatteryCharging(enabled: Bool) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let attempt = XPCCommandAttempt(continuation: continuation)
            guard let helper = ChargingHelperManager.shared.getHelper(errorHandler: { error in
                let message = error.localizedDescription
                Task { @MainActor in
                    attempt.finish(.failure(XPCError.connectionFailed(message)))
                }
            }) else {
                attempt.finish(.failure(XPCError.helperUnavailable))
                return
            }
            helper.manageBatteryCharging(enabled: enabled) { success, errorMessage in
                Task { @MainActor in
                    attempt.finish(
                        success
                        ? .success(())
                        : .failure(XPCError.commandFailed(errorMessage ?? "Unknown error"))
                    )
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(3))
                attempt.finish(.failure(XPCError.timedOut))
            }
        }
    }

    func manageExternalPower(enabled: Bool) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let attempt = XPCCommandAttempt(continuation: continuation)
            guard let helper = ChargingHelperManager.shared.getHelper(errorHandler: { error in
                let message = error.localizedDescription
                Task { @MainActor in
                    attempt.finish(.failure(XPCError.connectionFailed(message)))
                }
            }) else {
                attempt.finish(.failure(XPCError.helperUnavailable))
                return
            }
            helper.manageExternalPower(enabled: enabled) { success, errorMessage in
                Task { @MainActor in
                    attempt.finish(
                        success
                        ? .success(())
                        : .failure(XPCError.commandFailed(errorMessage ?? "Unknown error"))
                    )
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(3))
                attempt.finish(.failure(XPCError.timedOut))
            }
        }
    }

    func readChipPower() async -> Double? {
        let logger = self.logger
        guard let helper = ChargingHelperManager.shared.getHelper(errorHandler: { error in
            logger.error("XPC error during chip power sample: \(error.localizedDescription)")
        }) else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            helper.readChipPower { watts in
                continuation.resume(returning: watts > 0 ? watts : nil)
            }
        }
    }

    func manageMagsafeLED(target: MagSafeLEDState) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let attempt = XPCCommandAttempt(continuation: continuation)
            guard let helper = ChargingHelperManager.shared.getHelper(errorHandler: { error in
                let message = error.localizedDescription
                Task { @MainActor in
                    attempt.finish(.failure(XPCError.connectionFailed(message)))
                }
            }) else {
                attempt.finish(.failure(XPCError.helperUnavailable))
                return
            }
            helper.manageMagsafeLED(target: target.rawValue) { success, errorMessage in
                Task { @MainActor in
                    attempt.finish(
                        success
                        ? .success(())
                        : .failure(XPCError.commandFailed(errorMessage ?? "Unknown error"))
                    )
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(3))
                attempt.finish(.failure(XPCError.timedOut))
            }
        }
    }

    func applyPowerState(
        chargingEnabled: Bool?,
        externalPowerEnabled: Bool?,
        magSafeLED: MagSafeLEDState?
    ) async throws {
        if !ChargingHelperManager.shared.supportsGroupedPowerState {
            // Keep 1.0 Beta compatible with the 0.2.4 package-installed
            // helper. The old XPC protocol has the individual operations but
            // cannot decode applyPowerState. Preserve the grouped ordering as
            // closely as that protocol allows and update the LED last.
            if chargingEnabled == false {
                try await manageBatteryCharging(enabled: false)
            }
            if externalPowerEnabled == false {
                try await manageExternalPower(enabled: false)
            }
            if externalPowerEnabled == true {
                try await manageExternalPower(enabled: true)
            }
            if chargingEnabled == true {
                try await manageBatteryCharging(enabled: true)
            }
            if let magSafeLED {
                try await manageMagsafeLED(target: magSafeLED)
            }
            return
        }

        try await withCheckedThrowingContinuation { continuation in
            let attempt = XPCCommandAttempt(continuation: continuation)
            guard let helper = ChargingHelperManager.shared.getHelper(errorHandler: { error in
                let message = error.localizedDescription
                Task { @MainActor in
                    attempt.finish(.failure(XPCError.connectionFailed(message)))
                }
            }) else {
                attempt.finish(.failure(XPCError.helperUnavailable))
                return
            }
            helper.applyPowerState(
                chargingEnabled: chargingEnabled ?? true,
                controlsCharging: chargingEnabled != nil,
                externalPowerEnabled: externalPowerEnabled ?? true,
                controlsExternalPower: externalPowerEnabled != nil,
                magSafeLEDTarget: (magSafeLED ?? .reset).rawValue,
                controlsMagSafeLED: magSafeLED != nil
            ) { success, errorMessage in
                Task { @MainActor in
                    attempt.finish(
                        success
                            ? .success(())
                            : .failure(XPCError.commandFailed(errorMessage ?? "Unknown error"))
                    )
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(3))
                attempt.finish(.failure(XPCError.timedOut))
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        logger.info("BatteryService stopping")
        ioKitMonitorTask?.cancel()
        ioKitMonitorTask = nil
        smcPollTask?.cancel()
        smcPollTask = nil
        delayedPollTask?.cancel()
        delayedPollTask = nil
        xpcManager.disconnect()
    }
}
