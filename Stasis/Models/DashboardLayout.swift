import Defaults
import Foundation

/// Stable identifiers used to persist the order of menu dashboard sections.
/// Raw values are intentionally kept independent from localized titles.
enum DashboardItemID: String, CaseIterable, Codable, Identifiable, Sendable {
    case powerSource
    case timeRemaining
    case uptime
    case batteryMode
    case batteryTemperature
    case internalPower
    case externalPower
    case powerDistribution
    case cycleCount
    case batteryHealth
    case highEnergyApps
    case chargeLimit
    case chargeLimitOverride
    case forceDischarge

    var id: String { rawValue }

    static let defaultOrder: [DashboardItemID] = [
        .powerSource, .timeRemaining, .batteryMode,
        .batteryTemperature, .uptime, .internalPower, .externalPower,
        .powerDistribution, .cycleCount, .batteryHealth, .highEnergyApps, .chargeLimit,
        .chargeLimitOverride, .forceDischarge,
    ]

    var title: String {
        switch self {
        case .powerSource: return String(localized: "Power Source")
        case .timeRemaining: return String(localized: "Time Remaining")
        case .uptime: return String(localized: "Uptime")
        case .batteryMode: return String(localized: "Battery Mode")
        case .batteryTemperature: return String(localized: "Battery Temperature")
        case .internalPower: return String(localized: "Battery Power")
        case .externalPower: return String(localized: "Adapter Power")
        case .powerDistribution: return String(localized: "Power Distribution")
        case .cycleCount: return String(localized: "Cycle Count")
        case .batteryHealth: return String(localized: "Battery Health")
        case .highEnergyApps: return String(localized: "High Energy Apps")
        case .chargeLimit: return String(localized: "Charge limit")
        case .chargeLimitOverride: return String(localized: "Charge Limit Override")
        case .forceDischarge: return String(localized: "Force Discharge")
        }
    }
}

enum PowerFlowDetailLevel: String, Defaults.Serializable, CaseIterable, Identifiable, Sendable {
    case level2
    case level3

    var id: String { rawValue }

    var title: String {
        switch self {
        case .level2: return String(localized: "Second-level display")
        case .level3: return String(localized: "Third-level display")
        }
    }
}

enum DashboardModuleID: String, CaseIterable, Identifiable, Sendable {
    case batteryStatus
    case powerMonitoring
    case batteryHealth
    case energyApps
    case chargingControls

    var id: String { rawValue }

    static let defaultOrder: [DashboardModuleID] = [
        .batteryStatus, .powerMonitoring, .batteryHealth, .energyApps,
        .chargingControls,
    ]

    var title: String {
        switch self {
        case .batteryStatus: return String(localized: "Battery Status")
        case .powerMonitoring: return String(localized: "Power Monitoring")
        case .batteryHealth: return String(localized: "Battery Health")
        case .energyApps: return String(localized: "Energy Apps")
        case .chargingControls: return String(localized: "Charging Controls")
        }
    }

    var systemImage: String {
        switch self {
        case .batteryStatus: return "battery.75"
        case .powerMonitoring: return "bolt.horizontal"
        case .batteryHealth: return "heart.text.square"
        case .energyApps: return "flame"
        case .chargingControls: return "slider.horizontal.3"
        }
    }

    var defaultItems: [DashboardItemID] {
        switch self {
        case .batteryStatus:
            return [
                .powerSource, .timeRemaining, .batteryMode,
                .batteryTemperature, .uptime,
            ]
        case .powerMonitoring:
            return [.internalPower, .externalPower, .powerDistribution]
        case .batteryHealth:
            return [.cycleCount, .batteryHealth]
        case .energyApps:
            return [.highEnergyApps]
        case .chargingControls:
            return [.chargeLimit, .chargeLimitOverride, .forceDischarge]
        }
    }
}

extension DashboardModuleID {
    var moduleID: String {
        switch self {
        case .batteryStatus: BuiltInModuleCatalog.batteryStatusID
        case .powerMonitoring: BuiltInModuleCatalog.powerMonitoringID
        case .batteryHealth: BuiltInModuleCatalog.batteryHealthID
        case .energyApps: BuiltInModuleCatalog.energyAppsID
        case .chargingControls: BuiltInModuleCatalog.chargingControlID
        }
    }

    static func legacyModule(for moduleID: String) -> DashboardModuleID? {
        allCases.first { $0.moduleID == moduleID }
    }
}

enum ModuleDashboardBridge {
    static func items(for moduleID: String) -> [DashboardItemID] {
        if moduleID == BuiltInModuleCatalog.systemInfoID {
            return Defaults[.dashboardLayout].compactMap(DashboardItemID.init(rawValue:)).filter { $0 == .uptime }
        }
        guard let module = DashboardModuleID.legacyModule(for: moduleID) else { return [] }
        let items = DashboardLayoutStore.orderedItems(in: module)
        if module == .batteryStatus { return items.filter { $0 != .uptime } }
        return items
    }
}

enum DashboardLayoutStore {
    static func normalized(_ rawValues: [String]) -> [DashboardItemID] {
        let decoded = rawValues.compactMap(DashboardItemID.init(rawValue:))
        let unique = decoded.reduce(into: [DashboardItemID]()) { result, item in
            if !result.contains(item) { result.append(item) }
        }
        return unique + DashboardItemID.defaultOrder.filter { !unique.contains($0) }
    }

    static var orderedItems: [DashboardItemID] {
        orderedModules.flatMap(orderedItems(in:))
    }

    static var orderedModules: [DashboardModuleID] {
        let decoded = Defaults[.dashboardModuleLayout].compactMap(DashboardModuleID.init(rawValue:))
        let unique = decoded.reduce(into: [DashboardModuleID]()) { result, module in
            if !result.contains(module) { result.append(module) }
        }
        return unique + DashboardModuleID.defaultOrder.filter { !unique.contains($0) }
    }

    static func orderedItems(in module: DashboardModuleID) -> [DashboardItemID] {
        let stored = normalized(Defaults[.dashboardLayout])
        return stored.filter(module.defaultItems.contains)
            + module.defaultItems.filter { !stored.contains($0) }
    }

    static func save(_ items: [DashboardItemID]) {
        Defaults[.dashboardLayout] = items.map(\.rawValue)
    }

    static func saveModules(_ modules: [DashboardModuleID]) {
        Defaults[.dashboardModuleLayout] = modules.map(\.rawValue)
    }

    static func saveItems(_ items: [DashboardItemID], in module: DashboardModuleID) {
        var itemsByModule = Dictionary(
            uniqueKeysWithValues: DashboardModuleID.allCases.map {
                ($0, orderedItems(in: $0))
            }
        )
        itemsByModule[module] = items
        Defaults[.dashboardLayout] = DashboardModuleID.defaultOrder
            .flatMap { itemsByModule[$0] ?? $0.defaultItems }
            .map(\.rawValue)
    }

    static func isModuleVisible(_ module: DashboardModuleID) -> Bool {
        Defaults[.dashboardVisibleModules].contains(module.rawValue)
    }

    static func setModuleVisible(_ visible: Bool, for module: DashboardModuleID) {
        var visibleModules = Set(Defaults[.dashboardVisibleModules])
        if visible {
            visibleModules.insert(module.rawValue)
        } else {
            visibleModules.remove(module.rawValue)
        }
        Defaults[.dashboardVisibleModules] = DashboardModuleID.defaultOrder
            .map(\.rawValue)
            .filter(visibleModules.contains)
    }

    static func restoreDefaults() {
        Defaults[.dashboardModuleLayout] = DashboardModuleID.defaultOrder.map(\.rawValue)
        Defaults[.dashboardVisibleModules] = DashboardModuleID.defaultOrder.map(\.rawValue)
        Defaults[.dashboardLayout] = DashboardItemID.defaultOrder.map(\.rawValue)
    }

    static func isVisible(_ item: DashboardItemID) -> Bool {
        switch item {
        case .powerSource: return Defaults[.showPowerSource]
        case .timeRemaining: return Defaults[.showTimeTillDischarge]
        case .uptime: return Defaults[.showUptime]
        case .batteryMode: return Defaults[.showBatteryMode]
        case .batteryTemperature: return Defaults[.showBatteryTemperature]
        case .internalPower: return Defaults[.showInternalPower]
        case .externalPower: return Defaults[.showExternalPower]
        case .powerDistribution: return Defaults[.showPowerDistribution]
        case .cycleCount: return Defaults[.showBatteryCycleCount]
        case .batteryHealth: return Defaults[.showBatteryHealth]
        case .highEnergyApps: return Defaults[.showHighEnergyApps]
        case .chargeLimit: return Defaults[.showChargeLimitControl]
        case .chargeLimitOverride: return Defaults[.showChargeLimitOverride]
        case .forceDischarge: return Defaults[.showForceDischarge]
        }
    }

    static func setVisible(_ visible: Bool, for item: DashboardItemID) {
        switch item {
        case .powerSource: Defaults[.showPowerSource] = visible
        case .timeRemaining: Defaults[.showTimeTillDischarge] = visible
        case .uptime: Defaults[.showUptime] = visible
        case .batteryMode: Defaults[.showBatteryMode] = visible
        case .batteryTemperature: Defaults[.showBatteryTemperature] = visible
        case .internalPower: Defaults[.showInternalPower] = visible
        case .externalPower: Defaults[.showExternalPower] = visible
        case .powerDistribution: Defaults[.showPowerDistribution] = visible
        case .cycleCount: Defaults[.showBatteryCycleCount] = visible
        case .batteryHealth: Defaults[.showBatteryHealth] = visible
        case .highEnergyApps: Defaults[.showHighEnergyApps] = visible
        case .chargeLimit: Defaults[.showChargeLimitControl] = visible
        case .chargeLimitOverride: Defaults[.showChargeLimitOverride] = visible
        case .forceDischarge: Defaults[.showForceDischarge] = visible
        }
    }
}
