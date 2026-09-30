import Foundation

enum BuiltInModuleCatalog {
    static let releaseVersion = "1.0.0-beta.2"
    static let telemetryID = "app.stasis.macos-telemetry"
    static let batteryStatusID = "app.stasis.battery-status"
    static let systemInfoID = "app.stasis.system-info"
    static let powerMonitoringID = "app.stasis.power-monitoring"
    static let batteryHealthID = "app.stasis.battery-health"
    static let energyAppsID = "app.stasis.energy-apps"
    static let chargingControlID = "app.stasis.charging-control"
    static let calibrationID = "app.stasis.battery-calibration"

    static let recommended: [ModuleDescriptor] = [
        descriptor(
            id: telemetryID,
            name: "macOS Data Service",
            summary: "Provides battery, power, system and hardware telemetry.",
            icon: "waveform.path.ecg",
            roles: [.data],
            areas: [.general, .feature],
            provides: ["battery.status", "battery.health", "system.info", "power.telemetry", "process.energy"]
        ),
        descriptor(
            id: batteryStatusID,
            name: "Battery Status",
            summary: "Battery percentage, source, remaining time, mode and temperature.",
            icon: "battery.75",
            roles: [.presentation],
            areas: [.general, .panel],
            requires: ["battery.status"]
        ),
        descriptor(
            id: systemInfoID,
            name: "System Info",
            summary: "Basic system information such as uptime.",
            icon: "desktopcomputer",
            roles: [.presentation],
            areas: [.panel],
            requires: ["system.info"]
        ),
        descriptor(
            id: powerMonitoringID,
            name: "Power Monitoring",
            summary: "Battery, adapter and device power flow with demand-driven detail.",
            icon: "bolt.horizontal",
            roles: [.presentation, .business],
            areas: [.general, .panel, .feature],
            requires: ["power.telemetry"]
        ),
        descriptor(
            id: batteryHealthID,
            name: "Battery Health",
            summary: "Cycle count, capacity and health information.",
            icon: "heart.text.square",
            roles: [.presentation],
            areas: [.panel],
            requires: ["battery.health"]
        ),
        descriptor(
            id: energyAppsID,
            name: "Energy Apps",
            summary: "Shows applications with significant energy use while the panel is open.",
            icon: "flame",
            roles: [.presentation, .business],
            areas: [.general, .panel, .feature],
            requires: ["process.energy"]
        ),
        descriptor(
            id: chargingControlID,
            name: "Charging Control",
            summary: "Charge limit, sailing, heat protection and temporary controls.",
            icon: "battery.100.bolt",
            roles: [.presentation, .business, .control],
            areas: [.general, .panel, .feature],
            provides: ["charging.policy"],
            requires: ["battery.status"]
        ),
        descriptor(
            id: calibrationID,
            name: "Battery Calibration",
            summary: "A recoverable guided calibration workflow using charging policy overrides.",
            icon: "arrow.triangle.2.circlepath",
            roles: [.business],
            areas: [.general, .feature],
            requires: ["battery.status", "charging.policy"]
        ),
    ]

    /// Built-in descriptors persist stable English keys. Resolving them from
    /// the same table used by installable modules prevents an old localized
    /// value in module-registry.json from pinning the settings sidebar to the
    /// language that happened to be active during registration.
    static let localizations = ModuleLocalizationTable([
        "en": [:],
        "zh-Hans": [
            "macOS Data Service": "macOS 数据服务",
            "Provides battery, power, system and hardware telemetry.": "提供电池、功率、系统与硬件遥测数据。",
            "Battery Status": "电池状态",
            "Battery percentage, source, remaining time, mode and temperature.": "显示电量、供电来源、剩余时间、模式与温度。",
            "System Info": "系统信息",
            "Basic system information such as uptime.": "显示开机时长等基本系统信息。",
            "Power Monitoring": "功率监控",
            "Battery, adapter and device power flow with demand-driven detail.": "按需显示电池、适配器与设备功率流。",
            "Battery Health": "电池健康",
            "Cycle count, capacity and health information.": "显示循环次数、容量与健康信息。",
            "Energy Apps": "高能耗应用",
            "Shows applications with significant energy use while the panel is open.": "面板打开时显示能耗较高的应用。",
            "Charging Control": "充电控制",
            "Charge limit, sailing, heat protection and temporary controls.": "提供充电上限、巡航、温控保护与临时控制。",
            "Battery Calibration": "电池校准",
            "A recoverable guided calibration workflow using charging policy overrides.": "通过临时充电策略执行可恢复的引导式电池校准。",
        ],
        "zh-Hant": [
            "macOS Data Service": "macOS 資料服務",
            "Provides battery, power, system and hardware telemetry.": "提供電池、功率、系統與硬體遙測資料。",
            "Battery Status": "電池狀態",
            "Battery percentage, source, remaining time, mode and temperature.": "顯示電量、供電來源、剩餘時間、模式與溫度。",
            "System Info": "系統資訊",
            "Basic system information such as uptime.": "顯示開機時長等基本系統資訊。",
            "Power Monitoring": "功率監控",
            "Battery, adapter and device power flow with demand-driven detail.": "按需顯示電池、電源轉接器與裝置功率流。",
            "Battery Health": "電池健康",
            "Cycle count, capacity and health information.": "顯示循環次數、容量與健康資訊。",
            "Energy Apps": "高耗能應用程式",
            "Shows applications with significant energy use while the panel is open.": "面板開啟時顯示耗能較高的應用程式。",
            "Charging Control": "充電控制",
            "Charge limit, sailing, heat protection and temporary controls.": "提供充電上限、巡航、溫控保護與暫時控制。",
            "Battery Calibration": "電池校準",
            "A recoverable guided calibration workflow using charging policy overrides.": "透過暫時充電策略執行可復原的引導式電池校準。",
        ],
    ])

    private static func descriptor(
        id: String,
        name: String,
        summary: String,
        icon: String,
        roles: Set<ModuleRole>,
        areas: Set<ModuleSettingsArea>,
        provides: [String] = [],
        requires: [String] = []
    ) -> ModuleDescriptor {
        ModuleDescriptor(
            id: id,
            version: releaseVersion,
            protocolVersion: "1.0",
            minHostVersion: releaseVersion,
            minOSVersion: "14.8",
            architectures: ["arm64"],
            roles: roles,
            entrypoint: nil,
            provides: provides.map { .init(id: $0, version: "1.0") },
            requires: requires.map { .init(serviceID: $0, version: "1.0") },
            permissions: roles.contains(.control) ? ["hardware.control"] : [],
            uiCapabilities: ["native.rows.v1", "native.settings.v1"],
            author: "Stasis Project",
            license: "GPL-3.0",
            settingsVersion: 1,
            displayName: name,
            summary: summary,
            systemImage: icon,
            settingsAreas: areas
        )
    }
}
