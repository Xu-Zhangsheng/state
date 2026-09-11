import Defaults
import StasisNativeUI
import SwiftUI
import UserNotifications
import smc_power

struct ModuleGeneralSettingsView: View {
    let runtime: StasisRuntime
    let registry: ModuleRegistry
    let settingsStore: ModuleSettingsStore
    let permissionBroker: PermissionBroker
    let controlLeases: ControlLeaseManager
    let taskStore: ModuleTaskStore
    let moduleID: String
    @Default(.showChargingStatusChangedNotification) private var chargingNotification
    @State private var grantedPermissions = Set<String>()
    @State private var permissionError: String?

    var body: some View {
        Form {
            if let module = registry.module(id: moduleID) {
                Section {
                    LabeledContent("Version", value: module.descriptor.version)
                    LabeledContent("Author", value: module.descriptor.author)
                    LabeledContent("License", value: module.descriptor.license)
                    LabeledContent("Runtime", value: module.runtimeState.title)
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(module.displayName)
                        Text(module.summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if moduleID == BuiltInModuleCatalog.chargingControlID {
                    Section("Notifications") {
                        Toggle("Charging status changed", isOn: $chargingNotification)
                    }
                }

                if module.descriptor.permissions.contains("notifications") {
                    Section("Notifications") {
                        Toggle(
                            "Allow module notifications",
                            isOn: Binding(
                                get: { module.notificationsEnabled },
                                set: { registry.setNotificationsEnabled($0, moduleID: moduleID) }
                            )
                        )
                    }
                }

                if module.origin != .builtIn, !module.descriptor.permissions.isEmpty {
                    Section("Permissions") {
                        ForEach(module.descriptor.permissions, id: \.self) { permission in
                            Toggle(
                                permission,
                                isOn: Binding(
                                    get: { grantedPermissions.contains(permission) },
                                    set: { setPermission(permission, granted: $0) }
                                )
                            )
                        }
                    }
                }

                let moduleTasks = taskStore.records(for: moduleID)
                if !moduleTasks.isEmpty {
                    Section("Tasks") {
                        ForEach(moduleTasks) { task in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(task.title)
                                    Spacer()
                                    Label(task.state.title, systemImage: task.state.systemImage)
                                        .font(.caption)
                                        .foregroundStyle(task.state == .failed ? .red : .secondary)
                                }
                                if task.state == .running, let progress = task.progress {
                                    ProgressView(value: progress)
                                }
                                if let detail = task.detail {
                                    Text(detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                GenericModuleSettingsSection(
                    module: module,
                    area: .general,
                    runtime: runtime
                )
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 0)
        .task(id: moduleID) { await reloadPermissions() }
        .alert("Could Not Save Permission", isPresented: Binding(
            get: { permissionError != nil },
            set: { if !$0 { permissionError = nil } }
        )) {
            Button("OK") { permissionError = nil }
        } message: {
            Text(permissionError ?? "")
        }
    }

    private func reloadPermissions() async {
        guard let module = registry.module(id: moduleID) else { return }
        var granted = Set<String>()
        for permission in module.descriptor.permissions {
            if await permissionBroker.isGranted(permission, to: moduleID) {
                granted.insert(permission)
            }
        }
        grantedPermissions = granted
    }

    private func setPermission(_ permission: String, granted: Bool) {
        Task {
            do {
                if granted {
                    try await permissionBroker.grant(permission, to: moduleID)
                    if permission == "notifications" {
                        _ = try? await UNUserNotificationCenter.current().requestAuthorization(
                            options: [.alert, .sound]
                        )
                    }
                } else {
                    try await permissionBroker.revoke(permission, from: moduleID)
                    if permission == "hardware.control" {
                        await controlLeases.releaseAll(moduleID: moduleID)
                    }
                }
            } catch {
                permissionError = error.localizedDescription
            }
            await reloadPermissions()
        }
    }
}

struct ModulePanelSettingsView: View {
    let runtime: StasisRuntime
    let registry: ModuleRegistry
    let settingsStore: ModuleSettingsStore
    let moduleID: String
    @Default(.batteryPercentageDisplayLocation) private var percentageLocation
    @Default(.showBatteryStateInStatusIcon) private var showBatteryState
    @Default(.powerFlowDetailLevel) private var powerLevel
    @Default(.highEnergyAppLimit) private var appLimit

    private var items: [DashboardItemID] { ModuleDashboardBridge.items(for: moduleID) }

    var body: some View {
        Form {
            if moduleID == BuiltInModuleCatalog.batteryStatusID {
                Section("Menu Bar") {
                    Picker("Show percentage", selection: $percentageLocation) {
                        Text("Hidden").tag(PercentageDisplayLocation.hidden)
                        Text("Next to icon").tag(PercentageDisplayLocation.nextToIcon)
                    }
                    Toggle("Show battery state", isOn: $showBatteryState)
                }
            }

            if let module = registry.module(id: moduleID), module.descriptor.roles.contains(.presentation) {
                Section {
                    Toggle(
                        "Show module in panel",
                        isOn: Binding(
                            get: { module.isVisible },
                            set: { registry.setVisible($0, moduleID: moduleID) }
                        )
                    )
                }
            }

            if !items.isEmpty {
                Section("Panel Items") {
                    ForEach(items) { item in
                        Toggle(
                            item.title,
                            isOn: Binding(
                                get: { DashboardLayoutStore.isVisible(item) },
                                set: { DashboardLayoutStore.setVisible($0, for: item) }
                            )
                        )
                    }
                }
            }

            if moduleID == BuiltInModuleCatalog.powerMonitoringID {
                Section("Power Flow") {
                    Picker("Display level", selection: $powerLevel) {
                        ForEach(PowerFlowDetailLevel.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }

            if moduleID == BuiltInModuleCatalog.energyAppsID {
                Section("List") {
                    Stepper("Applications shown: \(appLimit)", value: $appLimit, in: 0...10)
                }
            }


            if let module = registry.module(id: moduleID) {
                GenericModuleSettingsSection(module: module, area: .panel, runtime: runtime)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 0)
    }
}

struct ModuleFeatureSettingsView: View {
    let moduleID: String
    let registry: ModuleRegistry
    let settingsStore: ModuleSettingsStore
    let capabilities: DeviceCapabilities
    let runtime: StasisRuntime

    var body: some View {
        switch moduleID {
        case BuiltInModuleCatalog.chargingControlID:
            ChargingSettingsView(capabilities: capabilities)
        case BuiltInModuleCatalog.calibrationID:
            CalibrationSettingsView(runtime: runtime)
        case BuiltInModuleCatalog.telemetryID:
            TelemetrySettingsView()
        case BuiltInModuleCatalog.powerMonitoringID:
            SamplingPolicyExplanationView(
                title: "Power Sampling",
                text: "Battery and adapter power refresh once per second while visible. Chip and external-device sampling runs only for visible third-level power flow."
            )
        case BuiltInModuleCatalog.energyAppsID:
            SamplingPolicyExplanationView(
                title: "Application Energy Sampling",
                text: "A fresh baseline is created when the panel opens. Results appear after about one second and refresh once per second until the panel closes."
            )
        default:
            if let module = registry.module(id: moduleID),
               module.settingsSchema?.settings.contains(where: { $0.area == .feature }) == true {
                Form {
                    GenericModuleSettingsSection(module: module, area: .feature, runtime: runtime)
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .contentMargins(.top, 0)
            } else {
                ContentUnavailableView("No Feature Settings", systemImage: "slider.horizontal.3")
            }
        }
    }
}

private struct GenericModuleSettingsSection: View {
    let module: InstalledModule
    let area: ModuleSettingsArea
    let runtime: StasisRuntime
    @State private var values: [String: JSONValue] = [:]
    @State private var errorMessage: String?

    private var definitions: [SettingDefinition] {
        module.localizedSettingsSchema?.settings.filter { $0.area == area } ?? []
    }

    var body: some View {
        if !definitions.isEmpty {
            Section("Module Options") {
                StasisModuleSettingsFields(definitions: definitions, values: values) { definition, value in
                    commit(value, for: definition)
                }
            }
            .onAppear(perform: reload)
            .alert("Could Not Save Setting", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func reload() {
        values = runtime.settingsStore.snapshot(
            moduleID: module.id,
            schemaVersion: module.settingsSchema?.version ?? 1
        ).values
    }

    private func commit(_ value: JSONValue, for definition: SettingDefinition) {
        let snapshot = runtime.settingsStore.snapshot(
            moduleID: module.id,
            schemaVersion: module.settingsSchema?.version ?? 1
        )
        values[definition.id] = value
        Task {
            do {
                _ = try await runtime.applyModuleSettings(
                    moduleID: module.id,
                    expectedRevision: snapshot.revision,
                    schemaVersion: module.settingsSchema?.version ?? 1,
                    patch: [definition.id: value]
                )
            } catch {
                reload()
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct TelemetrySettingsView: View {
    @Default(.useHardwarePercentage) private var useHardwarePercentage

    var body: some View {
        Form {
            Section {
                Toggle("Use hardware percentage", isOn: $useHardwarePercentage)
            } header: {
                Text("Battery Reading")
            } footer: {
                Text("Choose between the raw battery reading and the macOS calibrated value. All consuming modules use the selected source.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 0)
    }
}

struct CalibrationSettingsView: View {
    let runtime: StasisRuntime
    private var calibration: BatteryCalibrationManager { runtime.calibrationManager }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "battery.100.bolt").foregroundStyle(.secondary)
                        Text(calibration.statusTitle).font(.headline)
                        Spacer()
                        Text("\(calibration.currentPercentage)%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Text(calibration.statusDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if calibration.isActive {
                        ProgressView(value: calibration.progress)
                        Button("Cancel Calibration", role: .cancel) { calibration.cancel() }
                    } else {
                        Button(calibration.phase == .completed ? "Start Calibration Again" : "Start Battery Calibration") {
                            calibration.start()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Battery Calibration")
            } footer: {
                Text("The workflow uses a temporary charging-policy override and restores your persistent charging settings when it ends.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 0)
        .onAppear { runtime.setCalibrationSettingsVisible(true) }
        .onDisappear { runtime.setCalibrationSettingsVisible(false) }
        .alert("Battery Calibration", isPresented: Binding(
            get: { calibration.errorMessage != nil },
            set: { if !$0 { calibration.dismissError() } }
        )) {
            Button("OK") { calibration.dismissError() }
        } message: {
            Text(calibration.errorMessage ?? "")
        }
    }
}

private struct SamplingPolicyExplanationView: View {
    let title: LocalizedStringKey
    let text: LocalizedStringKey
    var body: some View {
        Form { Section(title) { Text(text).foregroundStyle(.secondary) } }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 0)
    }
}

private extension ModuleRuntimeState {
    var title: String {
        switch self {
        case .inactive: "Inactive"
        case .starting: "Starting"
        case .active: "Active"
        case .failed: "Failed"
        case .incompatible: "Incompatible"
        }
    }
}

private extension ModuleTaskStore.State {
    var title: String {
        switch self {
        case .running: String(localized: "Running")
        case .succeeded: String(localized: "Completed")
        case .failed: String(localized: "Failed")
        case .cancelled: String(localized: "Cancelled")
        }
    }

    var systemImage: String {
        switch self {
        case .running: "clock"
        case .succeeded: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .cancelled: "xmark.circle"
        }
    }
}
