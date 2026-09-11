import AppKit
import Defaults
import Foundation
import Observation

@MainActor
final class StasisRuntime {
    let registry: ModuleRegistry
    let settingsStore: ModuleSettingsStore
    let scheduler: DemandScheduler
    let serviceBroker: ServiceBroker
    let supervisor: RuntimeSupervisor
    let installer: ModuleInstaller
    let permissionBroker: PermissionBroker
    let controlLeases: ControlLeaseManager
    let presentationState: ModulePresentationStateStore
    let taskStore: ModuleTaskStore

    private(set) var batteryService: BatteryService!
    private(set) var chargeManager: ChargeManager!
    private(set) var calibrationManager: BatteryCalibrationManager!
    private(set) var menuViewModel: MenuViewModel!
    private(set) var settingsWindowController: SettingsWindowController!
    private(set) var menuBuilder: MenuBuilder!
    private(set) var statusBarManager: StatusBarManager!
    private var moduleLifecycleObservation: Task<Void, Never>?
    private var demandObservation: Task<Void, Never>?
    private var legacySettingsObservation: Task<Void, Never>?
    private var calibrationObservation: Task<Void, Never>?
    private var demandedServiceIDs = Set<String>()
    private var effectiveServiceDemands: [String: DemandScheduler.EffectiveDemand] = [:]
    private var panelOpen = false
    private var livePreviewEnabled = false
    private var calibrationSettingsVisible = false
    private var healthCheckModuleID: String?
    private var lastPresentationDemands: [String: JSONValue] = [:]
    private var restartBlockedModuleIDs = Set<String>()
    private var intentionalStopModuleIDs = Set<String>()
    private var hostBridge: ModuleHostBridge!
    private var configurationObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    init() {
        let registry = ModuleRegistry()
        let scheduler = DemandScheduler()
        self.registry = registry
        self.settingsStore = ModuleSettingsStore()
        self.scheduler = scheduler
        self.serviceBroker = ServiceBroker(scheduler: scheduler)
        self.supervisor = RuntimeSupervisor()
        self.installer = ModuleInstaller(registry: registry)
        self.permissionBroker = PermissionBroker()
        self.controlLeases = ControlLeaseManager()
        self.presentationState = ModulePresentationStateStore()
        self.taskStore = ModuleTaskStore()
    }

    /// Applies a settings change as one optimistic transaction. A running
    /// business module may reject a semantically invalid combination before
    /// the core persists it. Revision checking still protects against a
    /// concurrent settings change while the module is validating.
    @discardableResult
    func applyModuleSettings(
        moduleID: String,
        expectedRevision: UInt64,
        schemaVersion: Int,
        patch: [String: JSONValue]
    ) async throws -> UInt64 {
        guard let module = registry.module(id: moduleID) else {
            throw ModuleSettingsTransactionError.moduleUnavailable
        }
        if supervisor.isRunning(moduleID: moduleID),
           module.descriptor.roles.contains(.business),
           module.descriptor.uiCapabilities.contains("settings.validation.v1") {
            let current = settingsStore.snapshot(moduleID: moduleID, schemaVersion: schemaVersion)
            let response = try await supervisor.request(
                moduleID: moduleID,
                method: "validateConfigurationPatch",
                params: .object([
                    "expectedRevision": .number(Double(expectedRevision)),
                    "schemaVersion": .number(Double(schemaVersion)),
                    "currentValues": .object(current.values),
                    "patch": .object(patch),
                ])
            )
            if case .object(let result) = response.result,
               case .bool(false) = result["accepted"] {
                let message: String
                if case .string(let reason) = result["message"] { message = reason }
                else { message = String(localized: "The module rejected this setting.") }
                throw ModuleSettingsTransactionError.rejected(message)
            }
        }
        return try settingsStore.apply(
            moduleID: moduleID,
            expectedRevision: expectedRevision,
            schemaVersion: schemaVersion,
            patch: patch
        )
    }

    func bootstrap(contentHeightDidChange: @escaping @MainActor () -> Void) async {
        batteryService = BatteryService()
        if legacyTelemetryNeeded {
            batteryService.start()
            await batteryService.loadCapabilities()
        }
        chargeManager = ChargeManager(batteryService: batteryService)
        calibrationManager = BatteryCalibrationManager(
            batteryService: batteryService,
            chargeManager: chargeManager
        )
        chargeManager.setModuleEnabled(
            registry.module(id: BuiltInModuleCatalog.chargingControlID)?.isEnabled == true
                || calibrationManager.isActive
        )
        await controlLeases.setRestoreHandler { @MainActor [weak chargeManager] resourceID in
            guard resourceID == "battery.charging" || resourceID == "battery.external-power" else {
                return
            }
            chargeManager?.restoreSystemDefaults()
        }
        hostBridge = ModuleHostBridge(
            registry: registry,
            settings: settingsStore,
            services: serviceBroker,
            permissions: permissionBroker,
            leases: controlLeases,
            presentation: presentationState,
            tasks: taskStore,
            supervisor: supervisor,
            batteryService: batteryService
        )
        supervisor.setHostRequestHandler { [weak hostBridge] moduleID, method, params in
            guard let hostBridge else { throw RuntimeSupervisorError.terminated }
            return try await hostBridge.handle(moduleID: moduleID, method: method, params: params)
        }
        supervisor.setTerminationHandler { @MainActor [weak self] moduleID in
            guard let self else { return }
            await self.hostBridge.disconnect(moduleID: moduleID)
            await self.serviceBroker.unregister(providerID: moduleID)
            self.lastPresentationDemands[moduleID] = nil
            if self.intentionalStopModuleIDs.remove(moduleID) != nil {
                return
            }
            if self.registry.module(id: moduleID)?.isEnabled == true {
                self.restartBlockedModuleIDs.insert(moduleID)
                self.registry.setRuntimeState(
                    .failed,
                    error: String(localized: "The module process exited unexpectedly."),
                    moduleID: moduleID
                )
            }
        }
        menuViewModel = MenuViewModel(
            batteryService: batteryService,
            chargeManager: chargeManager
        )
        menuViewModel.updateModuleDemand(visibleModuleIDs: Set(registry.visibleModules.map(\.id)))
        settingsWindowController = SettingsWindowController(
            runtime: self,
            batteryService: batteryService
        )
        menuBuilder = MenuBuilder(
            viewModel: menuViewModel,
            registry: registry,
            supervisor: supervisor,
            presentationState: presentationState,
            settingsWindowController: settingsWindowController,
            contentHeightDidChange: contentHeightDidChange
        )
        statusBarManager = StatusBarManager(
            viewModel: menuViewModel,
            registry: registry,
            presentationState: presentationState
        )
        await registerBuiltInServices()
        registerModuleSchemas()
        observeModuleLifecycle()
        observeDemand()
        observeConfigurationChanges()
        observeSystemSleep()
        observeLegacySettings()
        observeCalibrationState()
    }

    func menuWillOpen() {
        panelOpen = true
        let visible = Set(registry.visibleModules.map(\.id))
        menuViewModel.updateModuleDemand(visibleModuleIDs: visible)
        reconcileLegacyTelemetry()
        if batteryService.isRunning { menuViewModel.menuWillOpen() }
        Task { await reconcileExternalWorkers() }
    }

    func menuDidClose() {
        panelOpen = false
        menuViewModel.menuDidClose()
        reconcileLegacyTelemetry()
        Task { await reconcileExternalWorkers() }
    }

    func setLivePreviewEnabled(_ enabled: Bool) {
        guard livePreviewEnabled != enabled else { return }
        livePreviewEnabled = enabled
        reconcileLegacyTelemetry()
        Task { await reconcileExternalWorkers() }
    }

    func setCalibrationSettingsVisible(_ visible: Bool) {
        calibrationSettingsVisible = visible
        calibrationManager.setInterfaceVisible(visible)
        reconcileLegacyTelemetry()
        if visible {
            batteryService.scheduleSinglePoll()
            Task { await batteryService.loadCapabilities() }
        }
    }

    func setModuleEnabled(_ enabled: Bool, moduleID: String) throws {
        if !enabled, calibrationManager.isActive,
           let module = registry.module(id: moduleID),
           participatesInCalibration(module.descriptor) {
            throw ModuleInstallationHealthError.calibrationInProgress
        }
        registry.setEnabled(enabled, moduleID: moduleID)
    }

    func uninstallModule(_ moduleID: String) async throws {
        if calibrationManager.isActive,
           let module = registry.module(id: moduleID),
           participatesInCalibration(module.descriptor) {
            throw ModuleInstallationHealthError.calibrationInProgress
        }
        intentionalStopModuleIDs.insert(moduleID)
        defer { intentionalStopModuleIDs.remove(moduleID) }
        if supervisor.isRunning(moduleID: moduleID) {
            _ = try? await supervisor.request(moduleID: moduleID, method: "shutdown", params: nil)
            supervisor.stop(moduleID: moduleID)
        }
        await hostBridge.disconnect(moduleID: moduleID)
        lastPresentationDemands[moduleID] = nil
        await serviceBroker.unregister(providerID: moduleID)
        try? await permissionBroker.revokeAll(from: moduleID)
        try installer.uninstall(moduleID: moduleID)
        restartBlockedModuleIDs.remove(moduleID)
    }

    func installModule(from packageURL: URL, origin: ModuleOrigin) async throws -> ModuleDescriptor {
        let transaction = try installer.beginInstall(from: packageURL, origin: origin)
        let moduleID = transaction.descriptor.id
        if calibrationManager.isActive, participatesInCalibration(transaction.descriptor) {
            installer.rollback(transaction)
            throw ModuleInstallationHealthError.calibrationInProgress
        }
        let settingsBackup = settingsStore.backup(moduleID: moduleID)
        do {
            try settingsStore.prepare(schema: transaction.settingsSchema, moduleID: moduleID)
        } catch {
            installer.rollback(transaction)
            try? settingsStore.restore(settingsBackup, moduleID: moduleID)
            if let previousSchema = transaction.previous?.settingsSchema {
                settingsStore.register(schema: previousSchema, moduleID: moduleID)
            }
            throw error
        }
        restartBlockedModuleIDs.remove(moduleID)
        intentionalStopModuleIDs.insert(moduleID)
        if supervisor.isRunning(moduleID: moduleID) {
            _ = try? await supervisor.request(moduleID: moduleID, method: "shutdown", params: nil)
            supervisor.stop(moduleID: moduleID)
        }
        await hostBridge.disconnect(moduleID: moduleID)
        await serviceBroker.unregister(providerID: moduleID)
        intentionalStopModuleIDs.remove(moduleID)

        do {
            healthCheckModuleID = moduleID
            await reconcileExternalWorkers()
            if transaction.descriptor.entrypoint != nil,
               registry.module(id: moduleID)?.runtimeState != .active {
                throw ModuleInstallationHealthError.workerDidNotActivate
            }
            installer.commit(transaction)
            healthCheckModuleID = nil
            await reconcileExternalWorkers()
            return transaction.descriptor
        } catch {
            healthCheckModuleID = nil
            supervisor.stop(moduleID: moduleID)
            await hostBridge.disconnect(moduleID: moduleID)
            lastPresentationDemands[moduleID] = nil
            await serviceBroker.unregister(providerID: moduleID)
            installer.rollback(transaction)
            try? settingsStore.restore(settingsBackup, moduleID: moduleID)
            if let previousSchema = transaction.previous?.settingsSchema {
                settingsStore.register(schema: previousSchema, moduleID: moduleID)
            }
            restartBlockedModuleIDs.remove(moduleID)
            await reconcileExternalWorkers()
            throw error
        }
    }

    func shutdown() async {
        moduleLifecycleObservation?.cancel()
        demandObservation?.cancel()
        legacySettingsObservation?.cancel()
        calibrationObservation?.cancel()
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        if let sleepObserver { workspaceNotifications.removeObserver(sleepObserver) }
        if let wakeObserver { workspaceNotifications.removeObserver(wakeObserver) }

        for module in registry.modules where module.origin != .builtIn {
            intentionalStopModuleIDs.insert(module.id)
            if supervisor.isRunning(moduleID: module.id) {
                _ = try? await supervisor.request(moduleID: module.id, method: "shutdown", params: nil)
            }
            await hostBridge.disconnect(moduleID: module.id)
            await serviceBroker.unregister(providerID: module.id)
        }
        await controlLeases.releaseAll()
        supervisor.stopAll()
        lastPresentationDemands.removeAll()
        restartBlockedModuleIDs.removeAll()
        intentionalStopModuleIDs.removeAll()
        await chargeManager?.restoreSystemDefaultsAndWait()
        calibrationManager?.stopMonitoring()
        chargeManager?.stop()
        batteryService?.stop()
    }

    private func observeSystemSleep() {
        let notifications = NSWorkspace.shared.notificationCenter
        sleepObserver = notifications.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.controlLeases.suspendExpirations() }
        }
        wakeObserver = notifications.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.controlLeases.resumeExpirations()
                self.batteryService.scheduleSinglePoll()
                await self.reconcileExternalWorkers()
            }
        }
    }

    private func observeDemand() {
        demandObservation = Task { [weak self] in
            guard let self else { return }
            let updates = await scheduler.updates()
            for await effective in updates {
                let previousServiceIDs = Set(effectiveServiceDemands.keys)
                demandedServiceIDs = Set(effective.map(\.serviceID))
                effectiveServiceDemands = Dictionary(
                    effective.map { ($0.serviceID, $0) },
                    uniquingKeysWith: { _, newest in newest }
                )
                let cancelledServiceIDs = previousServiceIDs.subtracting(demandedServiceIDs)
                await reconcileExternalWorkers()
                for demand in effective {
                    guard let providerID = registry.selectedProviderID(for: demand.serviceID),
                          supervisor.isRunning(moduleID: providerID)
                    else { continue }
                    do {
                        _ = try await supervisor.request(
                            moduleID: providerID,
                            method: "updateDemand",
                            params: serviceDemandPayload(demand)
                        )
                    } catch {
                        await failExternalModule(providerID, error: error, blockRestart: true)
                    }
                }
                for serviceID in cancelledServiceIDs {
                    guard let providerID = registry.selectedProviderID(for: serviceID),
                          supervisor.isRunning(moduleID: providerID)
                    else { continue }
                    do {
                        _ = try await supervisor.request(
                            moduleID: providerID,
                            method: "updateDemand",
                            params: serviceDemandCancellationPayload(serviceID)
                        )
                    } catch {
                        await failExternalModule(providerID, error: error, blockRestart: true)
                    }
                }
            }
        }
    }

    private func observeModuleLifecycle() {
        moduleLifecycleObservation = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.registerModuleSchemas()
                self.reconcileLegacyTelemetry()
                await self.reconcileExternalWorkers()
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.registry.modules
                        _ = self.registry.serviceProviders
                    } onChange: {
                        Task { @MainActor in continuation.resume() }
                    }
                }
            }
        }
    }

    private func registerModuleSchemas() {
        for module in registry.modules {
            if let schema = module.settingsSchema {
                settingsStore.register(schema: schema, moduleID: module.id)
            }
        }
    }

    private func reconcileExternalWorkers() async {
        await serviceBroker.synchronizeProviders(registry.serviceProviders)
        for module in registry.modules where module.origin != .builtIn {
            if !module.isEnabled {
                restartBlockedModuleIDs.remove(module.id)
            }
            if let issue = registry.dependencyIssue(for: module), module.isEnabled {
                if supervisor.isRunning(moduleID: module.id) {
                    supervisor.stop(moduleID: module.id)
                    await hostBridge.disconnect(moduleID: module.id)
                    await serviceBroker.unregister(providerID: module.id)
                }
                lastPresentationDemands[module.id] = nil
                registry.setRuntimeState(.failed, error: issue, moduleID: module.id)
                continue
            }
            let providesSelectedDemand = module.descriptor.provides.contains { service in
                registry.selectedProviderID(for: service.id) == module.id
                    && demandedServiceIDs.contains(service.id)
            }
            let requestedWorker = (
                module.isEnabled && (
                    (module.isVisible && panelOpen)
                    || (module.isVisible && livePreviewEnabled)
                    || registry.menuBarProviderID == module.id
                    || module.descriptor.roles.contains(.control)
                    || providesSelectedDemand
                )
            ) || healthCheckModuleID == module.id
            let needsWorker = requestedWorker
                && (!restartBlockedModuleIDs.contains(module.id) || healthCheckModuleID == module.id)
            guard let entrypoint = module.descriptor.entrypoint else { continue }
            if needsWorker, !supervisor.isRunning(moduleID: module.id) {
                let executable = registry.installedURL(for: module).appendingPathComponent(entrypoint)
                do {
                    registry.setRuntimeState(.starting, moduleID: module.id)
                    for service in module.descriptor.provides where
                        registry.selectedProviderID(for: service.id) == module.id {
                        try await serviceBroker.register(service: service, providerID: module.id)
                    }
                    try supervisor.start(module: module, executableURL: executable)
                    let configuration = settingsStore.snapshot(
                        moduleID: module.id,
                        schemaVersion: module.descriptor.settingsVersion
                    )
                    _ = try await supervisor.request(
                        moduleID: module.id,
                        method: "initialize",
                        params: .object([
                            "locale": .string(Locale.current.identifier),
                            "protocolVersion": .string("1.0"),
                            "sessionID": .string(UUID().uuidString),
                            "configuration": (try? Self.jsonValue(configuration)) ?? .null,
                            "hostCapabilities": .array([
                                .string("services.v1"),
                                .string("settings.v1"),
                                .string("presentation.v1"),
                                .string("control-leases.v1"),
                            ]),
                        ])
                    )
                    _ = try await supervisor.request(moduleID: module.id, method: "activate", params: nil)
                    for service in module.descriptor.provides where
                        registry.selectedProviderID(for: service.id) == module.id {
                        if let demand = effectiveServiceDemands[service.id] {
                            _ = try await supervisor.request(
                                moduleID: module.id,
                                method: "updateDemand",
                                params: serviceDemandPayload(demand)
                            )
                        }
                    }
                    registry.setRuntimeState(.active, moduleID: module.id)
                } catch {
                    await failExternalModule(
                        module.id,
                        error: error,
                        blockRestart: healthCheckModuleID != module.id
                    )
                }
            } else if !needsWorker, supervisor.isRunning(moduleID: module.id) {
                intentionalStopModuleIDs.insert(module.id)
                _ = try? await supervisor.request(moduleID: module.id, method: "deactivate", params: nil)
                supervisor.stop(moduleID: module.id)
                await hostBridge.disconnect(moduleID: module.id)
                await serviceBroker.unregister(providerID: module.id)
                lastPresentationDemands[module.id] = nil
                registry.setRuntimeState(.inactive, moduleID: module.id)
                intentionalStopModuleIDs.remove(module.id)
            } else if !requestedWorker, module.runtimeState == .failed,
                      !restartBlockedModuleIDs.contains(module.id) {
                registry.setRuntimeState(.inactive, moduleID: module.id)
            }

            if supervisor.isRunning(moduleID: module.id),
               module.descriptor.roles.contains(.presentation) {
                let demand = presentationDemand(for: module)
                if lastPresentationDemands[module.id] != demand {
                    do {
                        _ = try await supervisor.request(
                            moduleID: module.id,
                            method: "updateDemand",
                            params: demand
                        )
                        lastPresentationDemands[module.id] = demand
                    } catch {
                        await failExternalModule(module.id, error: error, blockRestart: true)
                    }
                }
            }
        }
    }

    private func failExternalModule(
        _ moduleID: String,
        error: Error,
        blockRestart: Bool
    ) async {
        supervisor.stop(moduleID: moduleID)
        await hostBridge.disconnect(moduleID: moduleID)
        await serviceBroker.unregister(providerID: moduleID)
        lastPresentationDemands[moduleID] = nil
        if blockRestart { restartBlockedModuleIDs.insert(moduleID) }
        registry.setRuntimeState(.failed, error: error.localizedDescription, moduleID: moduleID)
    }

    private func serviceDemandPayload(_ demand: DemandScheduler.EffectiveDemand) -> JSONValue {
        .object([
            "kind": .string("service"),
            "active": .bool(true),
            "serviceID": .string(demand.serviceID),
            "fields": .array(demand.fields.sorted().map(JSONValue.string)),
            "interval": .number(demand.interval),
        ])
    }

    private func serviceDemandCancellationPayload(_ serviceID: String) -> JSONValue {
        .object([
            "kind": .string("service"),
            "active": .bool(false),
            "serviceID": .string(serviceID),
            "fields": .array([]),
        ])
    }

    private func presentationDemand(for module: InstalledModule) -> JSONValue {
        let panelVisible = module.isVisible && panelOpen
        let previewVisible = module.isVisible && livePreviewEnabled
        let menuBarVisible = registry.menuBarProviderID == module.id
        var purposes: [JSONValue] = []
        if panelVisible { purposes.append(.string("visiblePanel")) }
        if previewVisible { purposes.append(.string("preview")) }
        if menuBarVisible { purposes.append(.string("menuBar")) }

        var componentIDs: [String] = []
        if panelVisible || previewVisible {
            componentIDs += flattenedComponentIDs(module.presentation?.panel ?? [])
        }
        if menuBarVisible {
            componentIDs += flattenedComponentIDs(module.presentation?.menuBar ?? [])
        }
        return .object([
            "kind": .string("presentation"),
            "purposes": .array(purposes),
            "visibleComponentIDs": .array(Array(Set(componentIDs)).sorted().map(JSONValue.string)),
        ])
    }

    private func flattenedComponentIDs(_ components: [PresentationComponent]) -> [String] {
        components.flatMap { [$0.id] + flattenedComponentIDs($0.children) }
    }

    private var legacyTelemetryNeeded: Bool {
        if calibrationSettingsVisible || calibrationManager?.isActive == true { return true }
        if registry.menuBarProviderID == BuiltInModuleCatalog.batteryStatusID { return true }
        if registry.module(id: BuiltInModuleCatalog.chargingControlID)?.isEnabled == true,
           Defaults[.manageCharging] { return true }
        guard panelOpen else { return false }
        return registry.visibleModules.contains { module in
            module.origin == .builtIn && !ModuleDashboardBridge.items(for: module.id).isEmpty
        }
    }

    private func reconcileLegacyTelemetry() {
        let chargingEnabled = registry.module(id: BuiltInModuleCatalog.chargingControlID)?.isEnabled == true
        chargeManager?.setModuleEnabled(chargingEnabled || calibrationManager?.isActive == true)
        if legacyTelemetryNeeded {
            if !batteryService.isRunning {
                batteryService.start()
                Task { await batteryService.loadCapabilities() }
            }
        } else {
            menuViewModel?.menuDidClose()
            batteryService.stop()
        }
    }

    private func observeLegacySettings() {
        legacySettingsObservation = Task { [weak self] in
            for await _ in Defaults.updates([.manageCharging], initial: false) {
                guard let self else { return }
                self.reconcileLegacyTelemetry()
            }
        }
    }

    private func observeCalibrationState() {
        calibrationObservation = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.reconcileLegacyTelemetry()
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.calibrationManager.phase
                    } onChange: {
                        Task { @MainActor in continuation.resume() }
                    }
                }
            }
        }
    }

    private func observeConfigurationChanges() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .stasisModuleConfigurationChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let moduleID = notification.object as? String else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      self.supervisor.isRunning(moduleID: moduleID),
                      let module = self.registry.module(id: moduleID)
                else { return }
                let snapshot = self.settingsStore.snapshot(
                    moduleID: moduleID,
                    schemaVersion: module.descriptor.settingsVersion
                )
                let params = try? Self.jsonValue(snapshot)
                _ = try? await self.supervisor.request(
                    moduleID: moduleID,
                    method: "configurationChanged",
                    params: params
                )
            }
        }
    }

    private static func jsonValue<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    private func participatesInCalibration(_ descriptor: ModuleDescriptor) -> Bool {
        let calibrationServices = Set(["battery.status", "charging.policy"])
        return descriptor.id == BuiltInModuleCatalog.calibrationID
            || !Set(descriptor.provides.map(\.id)).isDisjoint(with: calibrationServices)
            || !Set(descriptor.requires.map(\.serviceID)).isDisjoint(with: calibrationServices)
    }

    private func registerBuiltInServices() async {
        await serviceBroker.synchronizeProviders(registry.serviceProviders)
    }
}

enum ModuleSettingsTransactionError: LocalizedError {
    case moduleUnavailable
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .moduleUnavailable: String(localized: "The module is no longer installed.")
        case .rejected(let message): message
        }
    }
}

enum ModuleInstallationHealthError: LocalizedError {
    case workerDidNotActivate
    case calibrationInProgress
    var errorDescription: String? {
        switch self {
        case .workerDidNotActivate:
            "The module worker did not pass its activation health check. The previous version was restored."
        case .calibrationInProgress:
            "Finish or cancel battery calibration before changing a required module."
        }
    }
}
