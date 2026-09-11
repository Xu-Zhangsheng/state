import Foundation
import os.log
import smc_power

private enum Constants {
    static let subsystem = "com.srimanachanta.stasis.charging-helper"
}

final class ChargingHelper: NSObject, ChargingHelperProtocol {
    private let battery: SMCBattery
    private let adapter: SMCAdapter
    private let logger = Logger(
        subsystem: Constants.subsystem,
        category: "ChargingHelper"
    )

    init(battery: SMCBattery, adapter: SMCAdapter) {
        self.battery = battery
        self.adapter = adapter
        super.init()
        logger.info(
            "Initialized (charging=\(battery.capabilities.inhibitChargeControl), discharge=\(battery.capabilities.forceDischargeControl), magSafe=\(adapter.capabilities.magSafeControl))"
        )
    }

    func checkAvailability(reply: @escaping @Sendable (Bool, String?) -> Void) {
        reply(true, nil)
    }

    func manageBatteryCharging(enabled: Bool, reply: @escaping @Sendable (Bool, String?) -> Void) {
        do {
            try setBatteryCharging(enabled: enabled)
            reply(true, nil)
        } catch {
            logger.error("manageBatteryCharging failed: \(error.localizedDescription)")
            reply(false, error.localizedDescription)
        }
    }

    func manageExternalPower(enabled: Bool, reply: @escaping @Sendable (Bool, String?) -> Void) {
        do {
            try setExternalPower(enabled: enabled)
            reply(true, nil)
        } catch {
            logger.error("manageExternalPower failed: \(error.localizedDescription)")
            reply(false, error.localizedDescription)
        }
    }

    func manageMagsafeLED(target: UInt8, reply: @escaping @Sendable (Bool, String?) -> Void) {
        do {
            guard let ledState = MagSafeLEDState(rawValue: target) else {
                reply(false, "Invalid MagSafe LED state: \(target)")
                return
            }
            try setMagSafeLED(ledState)
            reply(true, nil)
        } catch {
            logger.error("manageMagsafeLED failed: \(error.localizedDescription)")
            reply(false, error.localizedDescription)
        }
    }

    func applyPowerState(
        chargingEnabled: Bool,
        controlsCharging: Bool,
        externalPowerEnabled: Bool,
        controlsExternalPower: Bool,
        magSafeLEDTarget: UInt8,
        controlsMagSafeLED: Bool,
        reply: @escaping @Sendable (Bool, String?) -> Void
    ) {
        do {
            if controlsCharging, controlsExternalPower,
               chargingEnabled, !externalPowerEnabled {
                throw ChargingHelperCommandError.contradictoryPowerState
            }
            if controlsExternalPower && !externalPowerEnabled {
                // Never request battery discharge while charging is still
                // enabled. This avoids exposing a contradictory SMC state.
                if controlsCharging { try setBatteryCharging(enabled: false) }
                try setExternalPower(enabled: false)
                if controlsCharging && chargingEnabled {
                    try setBatteryCharging(enabled: true)
                }
            } else {
                // Restore the adapter path before allowing charging again.
                if controlsExternalPower { try setExternalPower(enabled: externalPowerEnabled) }
                if controlsCharging { try setBatteryCharging(enabled: chargingEnabled) }
            }
            if controlsMagSafeLED {
                guard let state = MagSafeLEDState(rawValue: magSafeLEDTarget) else {
                    throw ChargingHelperCommandError.invalidLEDState(magSafeLEDTarget)
                }
                try setMagSafeLED(state)
            }
            reply(true, nil)
        } catch {
            let recoveryErrors = restoreDefaults()
            let recovery = recoveryErrors.isEmpty
                ? "System defaults were restored."
                : "Recovery also failed: \(recoveryErrors.joined(separator: "; "))"
            logger.error("applyPowerState failed: \(error.localizedDescription). \(recovery)")
            reply(false, "\(error.localizedDescription) \(recovery)")
        }
    }

    /// powermetrics is the only Apple-provided sampler that reports the
    /// combined CPU/GPU/ANE estimate for Apple silicon. This helper is already
    /// installed as a privileged daemon for charging control, so reading one
    /// menu-open sample does not introduce another password prompt.
    func readChipPower(reply: @escaping @Sendable (Double) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
        process.arguments = [
            "-n", "1",
            "-i", "1000",
            // Ask powermetrics for all three Apple-silicon SoC rails so the
            // menu reports the whole chip, rather than CPU cores only.
            "-s", "cpu_power,gpu_power,ane_power",
            "-b", "1",
        ]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let watts = Self.parseChipPower(String(decoding: output, as: UTF8.self))
            reply(watts ?? -1)
        } catch {
            logger.error("powermetrics failed: \(error.localizedDescription)")
            reply(-1)
        }
    }

    private static func parseChipPower(_ output: String) -> Double? {
        let pattern = #"([0-9]+(?:\.[0-9]+)?)\s*(mW|W)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        func value(on line: String) -> Double? {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let numberRange = Range(match.range(at: 1), in: line),
                  let unitRange = Range(match.range(at: 2), in: line),
                  let number = Double(line[numberRange])
            else { return nil }
            return line[unitRange].caseInsensitiveCompare("mW") == .orderedSame
                ? number / 1_000
                : number
        }

        for line in output.split(whereSeparator: \.isNewline) {
            let text = String(line)
            if text.localizedCaseInsensitiveContains("combined power"),
               let watts = value(on: text) {
                return watts
            }
        }

        let componentLabels = ["cpu power", "gpu power", "ane power"]
        let componentWatts = output
            .split(whereSeparator: \.isNewline)
            .filter { line in
                let text = String(line)
                return componentLabels.contains { text.localizedCaseInsensitiveContains($0) }
            }
            .compactMap { value(on: String($0)) }

        let total = componentWatts.reduce(0, +)
        return total > 0 ? total : nil
    }

    func resetToDefaults() {
        let errors = restoreDefaults()
        if errors.isEmpty {
            logger.info("SMC keys reset to defaults")
        } else {
            logger.error("resetToDefaults failed: \(errors.joined(separator: "; "))")
        }
    }

    private func setBatteryCharging(enabled: Bool) throws {
        guard battery.capabilities.inhibitChargeControl else {
            throw ChargingHelperCommandError.unsupportedCharging
        }
        let currentlyInhibited = try battery.getChargingInhibited()
        if currentlyInhibited != !enabled {
            try battery.setChargingInhibited(!enabled)
            logger.debug("SMC set charging inhibited to: \(!enabled)")
        }
    }

    private func setExternalPower(enabled: Bool) throws {
        guard battery.capabilities.forceDischargeControl else {
            throw ChargingHelperCommandError.unsupportedAdapter
        }
        let currentlyDischarging = try battery.getForceDischarging()
        if currentlyDischarging != !enabled {
            try battery.setForceDischarging(!enabled)
            logger.debug("SMC set force discharging to: \(!enabled)")
        }
    }

    private func setMagSafeLED(_ state: MagSafeLEDState) throws {
        guard adapter.capabilities.magSafeControl else {
            throw ChargingHelperCommandError.unsupportedLED
        }
        let currentState = try adapter.getMagSafeLEDState()
        if currentState != state {
            try adapter.setMagSafeLEDState(state)
            logger.debug("SMC MagSafe LED set to: \(state.rawValue)")
        }
    }

    private func restoreDefaults() -> [String] {
        var errors: [String] = []
        if battery.capabilities.forceDischargeControl {
            do { try setExternalPower(enabled: true) }
            catch { errors.append("adapter: \(error.localizedDescription)") }
        }
        if battery.capabilities.inhibitChargeControl {
            do { try setBatteryCharging(enabled: true) }
            catch { errors.append("charging: \(error.localizedDescription)") }
        }
        if adapter.capabilities.magSafeControl {
            do { try setMagSafeLED(.reset) }
            catch { errors.append("MagSafe LED: \(error.localizedDescription)") }
        }
        return errors
    }
}

private enum ChargingHelperCommandError: LocalizedError {
    case unsupportedCharging
    case unsupportedAdapter
    case unsupportedLED
    case invalidLEDState(UInt8)
    case contradictoryPowerState

    var errorDescription: String? {
        switch self {
        case .unsupportedCharging: "Charging control is not supported on this device"
        case .unsupportedAdapter: "Adapter control is not supported on this device"
        case .unsupportedLED: "MagSafe LED control is not supported on this device"
        case .invalidLEDState(let value): "Invalid MagSafe LED state: \(value)"
        case .contradictoryPowerState: "Charging cannot be enabled while external power is disabled"
        }
    }
}
