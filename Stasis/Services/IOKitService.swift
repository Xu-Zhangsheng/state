import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import os.log

@MainActor
class IOKitService {
    private var notificationPort: IONotificationPortRef?
    private var interestNotification: io_object_t = 0
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var powerSourceObserver: NSObjectProtocol?

    /// Posted from the IOKit callbacks, which must never touch this object:
    /// their refcon outlives the instance and dereferencing it crashed the app.
    private static let powerSourceChanged = Notification.Name(
        "com.srimanachanta.stasis.powerSourceChanged"
    )
    private var batteryService: io_service_t = 0

    private var continuation: AsyncStream<(BatteryMetrics, AdapterMetrics)>.Continuation?

    private let logger = Logger(
        subsystem: "com.srimanachanta.stasis",
        category: "IOKitService"
    )

    func metricsStream() -> AsyncStream<(BatteryMetrics, AdapterMetrics)> {
        AsyncStream { continuation in
            self.continuation = continuation

            continuation.onTermination = { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.stop()
                }
            }

            self.startNotifications()
        }
    }

    /// Ask IOKit for a fresh power-source snapshot. Interest notifications are
    /// normally enough, but menu-bar focus can change before a notification is
    /// delivered, so opening Stasis explicitly refreshes the authoritative
    /// charging state.
    func refresh() {
        guard batteryService != 0 else { return }
        emitMetrics()
    }

    private func startNotifications() {
        logger.info("Starting IOKit monitoring")

        batteryService = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        if batteryService == 0 {
            logger.error("Failed to get AppleSmartBattery service")
        }

        guard batteryService != 0 else { return }

        notificationPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let notificationPort else {
            logger.error("Failed to create IONotificationPort")
            return
        }

        let notificationSource = IONotificationPortGetRunLoopSource(notificationPort).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), notificationSource, .commonModes)

        let callback: IOServiceInterestCallback = { _, _, _, _ in
            NotificationCenter.default.post(name: IOKitService.powerSourceChanged, object: nil)
        }

        let result = IOServiceAddInterestNotification(
            notificationPort,
            batteryService,
            kIOGeneralInterest,
            callback,
            nil,
            &interestNotification
        )

        if result == KERN_SUCCESS {
            logger.info("IORegistry interest notification registered for AppleSmartBattery")
        } else {
            logger.error("Failed to register interest notification: \(result)")
        }

        // AppleSmartBattery interest notifications do not fire for every
        // adapter change, which left the menu-bar icon showing the previous
        // charging state until the menu was opened. The documented power-source
        // run-loop source does fire on connect and disconnect, so register it
        // as well and republish immediately.
        // This callback is not guaranteed to arrive on the main thread, so it
        // must hop instead of asserting isolation. assertIsolated here crashed
        // the app with SIGSEGV on the first adapter change.
        let powerSourceCallback: IOPowerSourceCallbackType = { _ in
            NotificationCenter.default.post(name: IOKitService.powerSourceChanged, object: nil)
        }
        if let source = IOPSNotificationCreateRunLoopSource(
            powerSourceCallback,
            nil
        )?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            powerSourceRunLoopSource = source
            logger.info("Power-source notification registered")
        } else {
            logger.error("Failed to register power-source notification")
        }

        powerSourceObserver = NotificationCenter.default.addObserver(
            forName: Self.powerSourceChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.emitMetrics()
            }
        }

        emitMetrics()
    }

    private func stop() {
        if let powerSourceObserver {
            NotificationCenter.default.removeObserver(powerSourceObserver)
            self.powerSourceObserver = nil
        }
        if let powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSourceRunLoopSource, .commonModes)
            self.powerSourceRunLoopSource = nil
        }
        if interestNotification != 0 {
            IOObjectRelease(interestNotification)
            interestNotification = 0
        }
        if let notificationPort {
            let source = IONotificationPortGetRunLoopSource(notificationPort).takeUnretainedValue()
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }
        if batteryService != 0 {
            IOObjectRelease(batteryService)
            batteryService = 0
        }
        continuation = nil
    }

    private func emitMetrics() {
        logger.debug("IOKit notification triggered")

        guard let powerInfo = getPowerSourceInfo() as? [String: Any] else {
            // A transiently unavailable power-source snapshot must not be
            // published as "on battery". Keeping the last coherent snapshot
            // avoids a false icon transition while IOKit is reconnecting.
            logger.warning("Power-source snapshot unavailable; keeping last state")
            return
        }
        var batteryMetrics = BatteryMetrics()
        var adapterMetrics = AdapterMetrics()

        let percentages = getBatteryPercentages(powerInfo: powerInfo)
        batteryMetrics.batteryPercentage = percentages.displayed
        batteryMetrics.hardwareBatteryPercentage = percentages.hardware

        batteryMetrics.isCharging = powerInfo[kIOPSIsChargingKey] as? Bool ?? false
        batteryMetrics.isUsingACPower =
            powerInfo[kIOPSPowerSourceStateKey] as? String
            == kIOPSACPowerValue
        if batteryMetrics.isCharging {
            batteryMetrics.timeRemaining = getTimeToFull(powerInfo: powerInfo) ?? -1
        } else {
            batteryMetrics.timeRemaining = getTimeRemaining(powerInfo: powerInfo) ?? -1
        }

        let capacities = getBatteryCapacities()
        batteryMetrics.batteryHealth =
            capacities.design > 0
            ? (capacities.max * 100) / capacities.design
            : 100

        batteryMetrics.externalConnected =
            getPropertyValue(batteryService, key: "ExternalConnected") ?? false

        adapterMetrics.adapterConnected = isAdapterConnected()

        populateElectricalMetrics(
            battery: &batteryMetrics,
            adapter: &adapterMetrics
        )

        if let temp = getBatteryTemperature(powerInfo: powerInfo) {
            batteryMetrics.batteryTemperature = temp
        }

        batteryMetrics.cycleCount =
            getPropertyValue(batteryService, key: "CycleCount") ?? 0

        logger.debug(
            "IOKit metrics: battery=\(batteryMetrics.batteryPercentage)%, hardwareBattery=\(batteryMetrics.hardwareBatteryPercentage)%, health=\(batteryMetrics.batteryHealth)%, charging=\(batteryMetrics.isCharging), usingAC=\(batteryMetrics.isUsingACPower), temp=\(batteryMetrics.batteryTemperature)°C, cycles=\(batteryMetrics.cycleCount), timeRemaining=\(batteryMetrics.timeRemaining), externalConnected=\(batteryMetrics.externalConnected), adapterConnected=\(adapterMetrics.adapterConnected)"
        )

        continuation?.yield((batteryMetrics, adapterMetrics))
    }

    private nonisolated func getPowerSourceInfo() -> CFDictionary? {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources =
            IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array
        guard let source = sources.first else { return nil }
        return IOPSGetPowerSourceDescription(snapshot, source)
            .takeUnretainedValue()
    }

    private nonisolated func getPropertyValue<T>(_ service: io_service_t, key: String) -> T? {
        guard
            let prop = IORegistryEntryCreateCFProperty(
                service,
                key as CFString,
                kCFAllocatorDefault,
                0
            )
        else {
            return nil
        }
        return prop.takeRetainedValue() as? T
    }

    private func getBatteryPercentages(powerInfo: [String: Any]?) -> (
        displayed: Int, hardware: Int
    ) {
        let publishedCurrent = powerInfo?[kIOPSCurrentCapacityKey] as? Int ?? 0
        let publishedMax = powerInfo?[kIOPSMaxCapacityKey] as? Int ?? 0
        let displayedPercent: Int
        if publishedMax > 0 {
            displayedPercent = Int(
                (Double(publishedCurrent) * 100 / Double(publishedMax)).rounded()
            )
        } else {
            displayedPercent = publishedCurrent
        }

        let rawCurrentCapacity: Int =
            getPropertyValue(batteryService, key: "AppleRawCurrentCapacity")
            ?? 0
        let rawMaxCapacity: Int =
            getPropertyValue(batteryService, key: "AppleRawMaxCapacity") ?? 0

        let hardwarePercent: Int
        if rawMaxCapacity > 0 {
            hardwarePercent = Int(
                (Double(rawCurrentCapacity) * 100 / Double(rawMaxCapacity)).rounded()
            )
        } else {
            let currentCapacity: Int =
                getPropertyValue(batteryService, key: "CurrentCapacity")
                ?? displayedPercent
            hardwarePercent = currentCapacity
        }

        return (
            max(0, min(100, displayedPercent)),
            max(0, min(100, hardwarePercent))
        )
    }

    private func getTimeRemaining(powerInfo: [String: Any]?) -> Int? {
        guard let timeToEmpty = powerInfo?[kIOPSTimeToEmptyKey] as? Int,
              timeToEmpty > 0,
              timeToEmpty != Int(kIOPSTimeRemainingUnknown) else {
            return nil
        }

        return timeToEmpty
    }

    private func getTimeToFull(powerInfo: [String: Any]?) -> Int? {
        guard let timeToFull = powerInfo?[kIOPSTimeToFullChargeKey] as? Int,
              timeToFull > 0,
              timeToFull != Int(kIOPSTimeRemainingUnknown) else {
            return nil
        }

        return timeToFull
    }

    private func isAdapterConnected() -> Bool {
        guard let adapterDetails: [String: Any] = getPropertyValue(batteryService, key: "AdapterDetails"),
              let watts = adapterDetails["Watts"] as? Int else {
            return false
        }

        return watts > 0
    }

    private func getBatteryTemperature(powerInfo: [String: Any]?) -> Double? {
        // On current macOS the public power-source dictionary publishes this
        // value directly in Celsius. Older releases used other encodings, so
        // only accept it when it already falls in a plausible Celsius range.
        if let raw = powerInfo?[kIOPSTemperatureKey],
           let temperature = numericValue(raw),
           (0...80).contains(temperature) {
            return temperature
        }

        // macOS 27 publishes the temperature inside the BatteryData dictionary
        // of the AppleSmartBatteryPack child. Searching for a standalone
        // Temperature property on AppleSmartBattery always returns nil there.
        if let packData = batteryPackData() {
            for key in ["VirtualTemperature", "Temperature"] {
                if let encoded = numericValue(packData[key]),
                   (100...8_000).contains(encoded) {
                    let celsius = encoded / 100
                    if (0...80).contains(celsius) { return celsius }
                }
            }
        }

        // Legacy AppleSmartBattery exposes Temperature as decikelvin.
        if let temp: Int = getPropertyValue(batteryService, key: "Temperature"),
           temp > 0, temp <= 5_000 {
            return decikelvinToCelsius(temp)
        }
        return nil
    }

    private func populateElectricalMetrics(
        battery: inout BatteryMetrics,
        adapter: inout AdapterMetrics
    ) {
        let telemetry: [String: Any]? = getPropertyValue(
            batteryService,
            key: "PowerTelemetryData"
        )
        if let voltageRaw = firstNumericProperty(["Voltage", "AppleRawBatteryVoltage"]),
           let currentRaw = firstNumericProperty(["Amperage", "InstantAmperage"]),
           voltageRaw > 0 {
            battery.batteryVoltage = voltageRaw / 1_000
            battery.batteryCurrent = currentRaw / 1_000
            battery.batteryPower = battery.batteryVoltage * battery.batteryCurrent
            battery.electricalMetricsAvailable = true
        }

        // The current sensor can briefly report zero after a power-source
        // transition while the battery is still supplying the computer.
        // The same registry snapshot carries a direct battery-power estimate.
        if let batteryPowerRaw = numericValue(telemetry?["BatteryPower"]),
           batteryPowerRaw.isFinite,
           abs(batteryPowerRaw) <= 500_000,
           abs(battery.batteryPower) < 0.1,
           abs(batteryPowerRaw) >= 100 {
            battery.batteryPower = batteryPowerRaw / 1_000
            if battery.batteryVoltage > 0 {
                battery.batteryCurrent = battery.batteryPower / battery.batteryVoltage
            }
            battery.electricalMetricsAvailable = true
        }

        if let telemetry {
            let voltage = numericValue(telemetry["SystemVoltageIn"])
            let current = numericValue(telemetry["SystemCurrentIn"])
            let power = numericValue(telemetry["SystemPowerIn"])
            if let voltage, voltage > 0 {
                adapter.adapterVoltage = voltage / 1_000
                adapter.adapterCurrent = (current ?? 0) / 1_000
                adapter.adapterPower = power.map { $0 / 1_000 }
                    ?? adapter.adapterVoltage * adapter.adapterCurrent
                adapter.electricalMetricsAvailable = true
                adapter.adapterConnected = true
            }
        }

        if !adapter.electricalMetricsAvailable,
           let details: [String: Any] = getPropertyValue(
               batteryService,
               key: "AdapterDetails"
           ) {
            let voltage = numericValue(details["AdapterVoltage"])
            let current = numericValue(details["Current"])
            let watts = numericValue(details["Watts"])
            if let voltage, voltage > 0 {
                adapter.adapterVoltage = voltage / 1_000
                adapter.adapterCurrent = (current ?? 0) / 1_000
                adapter.adapterPower = watts
                    ?? adapter.adapterVoltage * adapter.adapterCurrent
                adapter.electricalMetricsAvailable = true
            }
        }
    }

    private func firstNumericProperty(_ keys: [String]) -> Double? {
        for key in keys {
            if let value: NSNumber = getPropertyValue(batteryService, key: key) {
                return value.doubleValue
            }
        }
        return nil
    }

    private nonisolated func numericValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let number = value as? Int64 { return Double(number) }
        return nil
    }

    private func batteryPackData() -> [String: Any]? {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(batteryService, kIOServicePlane, &iterator)
            == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        while true {
            let child = IOIteratorNext(iterator)
            guard child != 0 else { return nil }
            defer { IOObjectRelease(child) }
            guard IOObjectConformsTo(child, "AppleSmartBatteryPack") != 0 else { continue }
            let data: [String: Any]? = getPropertyValue(child, key: "BatteryData")
            if let data { return data }
        }
    }

    private nonisolated func decikelvinToCelsius(_ decikelvin: Int) -> Double? {
        let celsius = (Double(decikelvin) / 10.0) - 273.15
        return (0...80).contains(celsius) ? celsius : nil
    }

    private func getBatteryCapacities() -> (current: Int, max: Int, design: Int) {
        let currentCapacity: Int =
            getPropertyValue(batteryService, key: "AppleRawCurrentCapacity")
            ?? 0
        let maxCapacity: Int =
            getPropertyValue(batteryService, key: "AppleRawMaxCapacity") ?? 0
        let designCapacity: Int =
            getPropertyValue(batteryService, key: "DesignCapacity") ?? 0

        return (currentCapacity, maxCapacity, designCapacity)
    }
}
