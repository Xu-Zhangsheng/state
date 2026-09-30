import AppKit
import Foundation

struct BatteryMetrics: Codable, Equatable {
    var batteryPercentage: Int = 0
    var hardwareBatteryPercentage: Int = 0
    var isCharging: Bool = false
    var timeRemaining: Int = 0

    var batteryVoltage: Double = 0
    var batteryCurrent: Double = 0
    var batteryPower: Double = 0
    /// True when voltage/current/power came from the current IOKit snapshot.
    /// SMC is retained only as a compatibility fallback on older systems.
    var electricalMetricsAvailable: Bool = false
    /// Negative means the sensor has not returned a usable value.
    var batteryTemperature: Double = -1

    var batteryHealth: Int = 0
    var cycleCount: Int = 0

    var externalConnected: Bool = false
    var isUsingACPower: Bool = false
}

struct AdapterMetrics: Equatable {
    var adapterConnected: Bool = false
    var adapterVoltage: Double = 0
    var adapterCurrent: Double = 0
    var adapterPower: Double = 0
    var electricalMetricsAvailable: Bool = false
}

struct BatteryControlState: Equatable {
    var batteryPercentage: Int = 0
    var hardwareBatteryPercentage: Int = 0
    var adapterConnected: Bool = false
    var batteryTemperature: Double = 0
}

/// A menu-open branch in the power-flow diagram. The UI intentionally renders
/// only the system icon and watt value; the name remains available for
/// accessibility and the hover description.
struct PowerBreakdownItem: Identifiable {
    let id: String
    let name: String
    let power: Double
    let systemImage: String
    let icon: NSImage?
    let isEstimated: Bool
}
