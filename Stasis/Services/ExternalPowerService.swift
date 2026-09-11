import Foundation
import IOKit

/// A menu-open snapshot of power that macOS has allocated to external USB
/// devices. USB-C/Thunderbolt devices do not expose a universal live watt
/// counter, so the registry's negotiated sink allocation is presented as an
/// estimate rather than as a measurement.
struct ExternalPowerSnapshot: Equatable {
    let watts: Double
    let deviceCount: Int

    static let empty = ExternalPowerSnapshot(watts: 0, deviceCount: 0)
}

enum ExternalPowerService {
    private static let usbDeviceClass = "IOUSBHostDevice"
    private static let allocationKey = "UsbPowerSinkAllocation"

    static func snapshot() -> ExternalPowerSnapshot {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching(usbDeviceClass),
            &iterator
        ) == KERN_SUCCESS else {
            return .empty
        }
        defer { IOObjectRelease(iterator) }

        var totalWatts = 0.0
        var deviceCount = 0

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            guard !isBuiltIn(service),
                  let milliamps = numberProperty(service, key: allocationKey),
                  milliamps > 0
            else { continue }

            // UsbPowerSinkAllocation is expressed in mA at the USB VBUS
            // voltage. Five volts is the conservative USB-C baseline.
            totalWatts += min(milliamps, 5_000) * 5.0 / 1_000.0
            deviceCount += 1
        }

        return ExternalPowerSnapshot(
            watts: max(0, totalWatts),
            deviceCount: deviceCount
        )
    }

    private static func isBuiltIn(_ service: io_service_t) -> Bool {
        guard let value = IORegistryEntrySearchCFProperty(
            service,
            kIOServicePlane,
            "Built-In" as CFString,
            kCFAllocatorDefault,
            0
        ) else {
            return false
        }

        if let boolean = value as? Bool {
            return boolean
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            return string.caseInsensitiveCompare("yes") == .orderedSame
                || string.caseInsensitiveCompare("true") == .orderedSame
        }
        return false
    }

    private static func numberProperty(_ service: io_service_t, key: String) -> Double? {
        guard let property = IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else {
            return nil
        }

        if let number = property as? NSNumber {
            return number.doubleValue
        }
        if let data = property as? Data, data.count <= MemoryLayout<UInt64>.size {
            var value: UInt64 = 0
            _ = withUnsafeMutableBytes(of: &value) { destination in
                data.copyBytes(to: destination)
            }
            return Double(value)
        }
        return nil
    }
}
