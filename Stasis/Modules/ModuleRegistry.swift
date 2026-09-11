import Defaults
import Foundation
import Observation
import SwiftUI
import os

@MainActor
@Observable
final class ModuleRegistry {
    private(set) var modules: [InstalledModule] = []
    private(set) var layout: [String] = []
    private(set) var menuBarProviderID: String?
    private(set) var serviceProviders: [String: String] = [:]
    private(set) var lastInstallerError: String?
    private(set) var needsInitialModuleChoice = false

    private let logger = Logger(subsystem: "com.srimanachanta.stasis", category: "ModuleRegistry")
    private let stateURL: URL
    private let modulesURL: URL

    init(fileManager: FileManager = .default) {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Stasis", isDirectory: true)
        stateURL = support.appendingPathComponent("module-registry.json")
        modulesURL = support.appendingPathComponent("Modules", isDirectory: true)
        try? fileManager.createDirectory(at: modulesURL, withIntermediateDirectories: true)
        load()
    }

    var enabledModules: [InstalledModule] {
        orderedModules.filter(\.isEnabled)
    }

    var visibleModules: [InstalledModule] {
        enabledModules.filter(\.isVisible)
    }

    var orderedModules: [InstalledModule] {
        let byID = Dictionary(uniqueKeysWithValues: modules.map { ($0.id, $0) })
        return layout.compactMap { byID[$0] } + modules.filter { !layout.contains($0.id) }
    }

    var menuBarProviderCandidates: [InstalledModule] {
        orderedModules.filter { module in
            module.isEnabled && (
                module.id == BuiltInModuleCatalog.batteryStatusID
                    || module.presentation?.menuBar.isEmpty == false
            )
        }
    }

    var providedServiceIDs: [String] {
        Array(Set(modules.flatMap { $0.descriptor.provides.map(\.id) })).sorted()
    }

    func providerCandidates(for serviceID: String) -> [InstalledModule] {
        let requirements = enabledModules.flatMap { module in
            module.descriptor.requires.filter {
                !$0.optional && $0.serviceID == serviceID
            }
        }
        return orderedModules.filter { module in
            guard module.isEnabled,
                  let service = module.descriptor.provides.first(where: { $0.id == serviceID })
            else { return false }
            return requirements.allSatisfy { version(service.version, meetsMinimum: $0.version) }
        }
    }

    func selectedProviderID(for serviceID: String) -> String? {
        serviceProviders[serviceID]
    }

    func dependencyIssue(for module: InstalledModule) -> String? {
        for requirement in module.descriptor.requires where !requirement.optional {
            guard let providerID = serviceProviders[requirement.serviceID],
                  let provider = self.module(id: providerID), provider.isEnabled,
                  let service = provider.descriptor.provides.first(where: { $0.id == requirement.serviceID }),
                  version(service.version, meetsMinimum: requirement.version)
            else {
                return String(localized: "Required service is unavailable: \(requirement.serviceID)")
            }
        }
        return nil
    }

    func module(id: String) -> InstalledModule? {
        modules.first { $0.id == id }
    }

    func setEnabled(_ enabled: Bool, moduleID: String) {
        update(moduleID) { module in
            module.isEnabled = enabled
            module.runtimeState = .inactive
        }
        normalizeServiceProviders()
        normalizeMenuBarProvider()
        save()
    }

    func setVisible(_ visible: Bool, moduleID: String) {
        update(moduleID) { $0.isVisible = visible }
    }

    func setNotificationsEnabled(_ enabled: Bool, moduleID: String) {
        update(moduleID) { $0.notificationsEnabled = enabled }
    }

    func completeInitialModuleChoice(useRecommendedSuite: Bool) {
        guard needsInitialModuleChoice else { return }
        needsInitialModuleChoice = false
        if !useRecommendedSuite {
            for index in modules.indices {
                modules[index].isEnabled = false
                modules[index].isVisible = false
                modules[index].runtimeState = .inactive
            }
            menuBarProviderID = nil
        }
        normalizeServiceProviders()
        normalizeMenuBarProvider()
        if !useRecommendedSuite { menuBarProviderID = nil }
        save()
    }

    func setMenuBarProvider(_ moduleID: String?) {
        guard moduleID == nil || menuBarProviderCandidates.contains(where: { $0.id == moduleID }) else {
            return
        }
        menuBarProviderID = moduleID
        save()
    }

    func setServiceProvider(_ moduleID: String, for serviceID: String) {
        guard providerCandidates(for: serviceID).contains(where: { $0.id == moduleID }) else {
            return
        }
        serviceProviders[serviceID] = moduleID
        save()
    }

    func setRuntimeState(_ state: ModuleRuntimeState, error: String? = nil, moduleID: String) {
        guard let module = module(id: moduleID),
              module.runtimeState != state || module.lastError != error
        else { return }
        update(moduleID) {
            $0.runtimeState = state
            $0.lastError = error
        }
    }

    func move(from source: IndexSet, to destination: Int) {
        var ordered = orderedModules.map(\.id)
        ordered.move(fromOffsets: source, toOffset: destination)
        layout = ordered
        save()
    }

    func register(
        _ descriptor: ModuleDescriptor,
        presentation: PresentationDescriptor? = nil,
        settingsSchema: ModuleSettingsSchema? = nil,
        localizations: ModuleLocalizationTable = .init(),
        origin: ModuleOrigin,
        enabled: Bool = true
    ) {
        if let index = modules.firstIndex(where: { $0.id == descriptor.id }) {
            modules[index].descriptor = descriptor
            modules[index].origin = origin
            if let presentation { modules[index].presentation = presentation }
            if let settingsSchema { modules[index].settingsSchema = settingsSchema }
            modules[index].localizations = localizations
            normalizeServiceProviders()
            save()
            return
        }
        modules.append(
            InstalledModule(
                descriptor: descriptor,
                presentation: presentation,
                settingsSchema: settingsSchema,
                localizations: localizations,
                isEnabled: enabled,
                isVisible: descriptor.roles.contains(.presentation),
                notificationsEnabled: true,
                origin: origin,
                runtimeState: .inactive,
                lastError: nil
            )
        )
        layout.append(descriptor.id)
        normalizeServiceProviders()
        save()
    }

    func installedURL(for module: InstalledModule) -> URL {
        modulesURL
            .appendingPathComponent(module.id, isDirectory: true)
            .appendingPathComponent(module.descriptor.version, isDirectory: true)
    }

    func validateDependencies(for descriptor: ModuleDescriptor) throws {
        let candidates = modules.filter { $0.id != descriptor.id }.map(\.descriptor) + [descriptor]
        let declarations = candidates.flatMap { module in
            module.provides.map { (module.id, $0) }
        }
        let groupedProviders = Dictionary(grouping: declarations, by: { $0.1.id })
        let requirementsByService = Dictionary(grouping: candidates.flatMap { module in
            module.requires.filter { !$0.optional }
        }, by: \.serviceID)
        let compatibleProviders = groupedProviders.mapValues { providers in
            providers.filter { _, service in
                (requirementsByService[service.id] ?? []).allSatisfy {
                    version(service.version, meetsMinimum: $0.version)
                }
            }
        }
        let missing: [String] = requirementsByService.compactMap { serviceID, requirements in
            guard !requirements.isEmpty,
                  compatibleProviders[serviceID]?.isEmpty != false
            else { return nil }
            return serviceID
        }.sorted()
        guard missing.isEmpty else { throw RegistryError.missingDependencies(missing) }

        let providerByService = Dictionary(uniqueKeysWithValues: compatibleProviders.compactMap { serviceID, providers in
            let selected = serviceProviders[serviceID]
            let provider = providers.first(where: { $0.0 == selected }) ?? providers.first
            return provider.map { (serviceID, $0.0) }
        })
        let edges = Dictionary(uniqueKeysWithValues: candidates.map { module in
            (
                module.id,
                Set(module.requires.compactMap { requirement in
                    requirement.optional ? nil : providerByService[requirement.serviceID]
                })
            )
        })
        var visiting = Set<String>()
        var visited = Set<String>()
        func visit(_ moduleID: String) throws {
            if visiting.contains(moduleID) { throw RegistryError.circularDependency(moduleID) }
            guard !visited.contains(moduleID) else { return }
            visiting.insert(moduleID)
            for dependency in edges[moduleID] ?? [] where dependency != moduleID {
                try visit(dependency)
            }
            visiting.remove(moduleID)
            visited.insert(moduleID)
        }
        try candidates.forEach { try visit($0.id) }
    }

    private func version(_ current: String, meetsMinimum minimum: String) -> Bool {
        let lhs = current.split(separator: ".").prefix(3).map { Int($0) ?? 0 }
        let rhs = minimum.split(separator: ".").prefix(3).map { Int($0) ?? 0 }
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return true
    }

    func remove(moduleID: String) throws {
        guard let module = module(id: moduleID), module.origin != .builtIn else {
            throw RegistryError.cannotRemoveBuiltIn
        }
        let dependents = blockingDependents(ifUnavailable: moduleID)
        guard dependents.isEmpty else {
            throw RegistryError.requiredBy(dependents.map(\.displayName))
        }
        modules.removeAll { $0.id == moduleID }
        layout.removeAll { $0 == moduleID }
        serviceProviders = serviceProviders.filter { $0.value != moduleID }
        normalizeServiceProviders()
        normalizeMenuBarProvider()
        save()
    }

    func blockingDependents(ifUnavailable moduleID: String) -> [InstalledModule] {
        guard let module = module(id: moduleID) else { return [] }
        return modules.filter { candidate in
            candidate.id != moduleID && candidate.isEnabled
                && candidate.descriptor.requires.contains { requirement in
                    guard !requirement.optional,
                          serviceProviders[requirement.serviceID] == moduleID,
                          module.descriptor.provides.contains(where: {
                              $0.id == requirement.serviceID
                          })
                    else { return false }
                    return !modules.contains { alternative in
                        alternative.id != moduleID
                            && alternative.isEnabled
                            && alternative.descriptor.provides.contains(where: {
                                $0.id == requirement.serviceID
                                    && version($0.version, meetsMinimum: requirement.version)
                            })
                    }
                }
        }
    }

    func reportInstallerError(_ error: Error?) {
        lastInstallerError = error?.localizedDescription
    }

    func restoreInstallation(_ previous: InstalledModule?, replacing moduleID: String) {
        if let previous {
            if let index = modules.firstIndex(where: { $0.id == moduleID }) {
                modules[index] = previous
            } else {
                modules.append(previous)
            }
            if !layout.contains(moduleID) { layout.append(moduleID) }
        } else {
            modules.removeAll { $0.id == moduleID }
            layout.removeAll { $0 == moduleID }
        }
        normalizeServiceProviders()
        normalizeMenuBarProvider()
        save()
    }

    private func update(_ moduleID: String, mutation: (inout InstalledModule) -> Void) {
        guard let index = modules.firstIndex(where: { $0.id == moduleID }) else { return }
        mutation(&modules[index])
        save()
    }

    private struct PersistedState: Codable {
        var modules: [InstalledModule]
        var layout: [String]
        var menuBarProviderID: String?
        var serviceProviders: [String: String]?
        var initialModuleChoiceCompleted: Bool?
    }

    private func load() {
        let hadPersistedState: Bool
        if let data = try? Data(contentsOf: stateURL),
           let state = try? JSONDecoder().decode(PersistedState.self, from: data) {
            modules = state.modules
            layout = state.layout
            menuBarProviderID = state.menuBarProviderID
            serviceProviders = state.serviceProviders ?? [:]
            needsInitialModuleChoice = !(state.initialModuleChoiceCompleted ?? true)
            hadPersistedState = true
        } else {
            needsInitialModuleChoice = true
            hadPersistedState = false
        }
        for descriptor in BuiltInModuleCatalog.recommended {
            register(
                descriptor,
                localizations: BuiltInModuleCatalog.localizations,
                origin: .builtIn
            )
        }
        if !hadPersistedState { migrateLegacyLayout() }
        layout = normalizedLayout(layout)
        normalizeServiceProviders()
        normalizeMenuBarProvider()
        save()
    }

    /// One-time 0.2.4 compatibility conversion. It deliberately translates
    /// the old "hidden module" state to presentation visibility, never to the
    /// enabled state, so charging and calibration work are not stopped.
    private func migrateLegacyLayout() {
        let legacyOrder = DashboardLayoutStore.orderedModules.map(\.moduleID)
        layout = [BuiltInModuleCatalog.telemetryID]
            + legacyOrder.flatMap { id in
                id == BuiltInModuleCatalog.batteryStatusID
                    ? [id, BuiltInModuleCatalog.systemInfoID]
                    : [id]
            }
            + [BuiltInModuleCatalog.calibrationID]

        let legacyVisibility: [String: Bool] = [
            BuiltInModuleCatalog.batteryStatusID: DashboardLayoutStore.isModuleVisible(.batteryStatus),
            BuiltInModuleCatalog.systemInfoID: DashboardLayoutStore.isModuleVisible(.batteryStatus)
                && Defaults[.showUptime],
            BuiltInModuleCatalog.powerMonitoringID: DashboardLayoutStore.isModuleVisible(.powerMonitoring),
            BuiltInModuleCatalog.batteryHealthID: DashboardLayoutStore.isModuleVisible(.batteryHealth),
            BuiltInModuleCatalog.energyAppsID: DashboardLayoutStore.isModuleVisible(.energyApps),
            BuiltInModuleCatalog.chargingControlID: DashboardLayoutStore.isModuleVisible(.chargingControls),
        ]
        for index in modules.indices {
            if let visible = legacyVisibility[modules[index].id] {
                modules[index].isVisible = visible
            }
        }
    }

    private func normalizedLayout(_ proposed: [String]) -> [String] {
        let installed = Set(modules.map(\.id))
        let valid = proposed.filter(installed.contains)
        return valid.reduce(into: [String]()) { result, id in
            if !result.contains(id) { result.append(id) }
        } + modules.map(\.id).filter { !valid.contains($0) }
    }

    private func normalizeMenuBarProvider() {
        if let menuBarProviderID,
           menuBarProviderCandidates.contains(where: { $0.id == menuBarProviderID }) {
            return
        }
        menuBarProviderID = menuBarProviderCandidates.first(where: {
            $0.id == BuiltInModuleCatalog.batteryStatusID
        })?.id ?? menuBarProviderCandidates.first?.id
    }

    private func normalizeServiceProviders() {
        let serviceIDs = Set(providedServiceIDs)
        serviceProviders = serviceProviders.filter { serviceID, moduleID in
            serviceIDs.contains(serviceID)
                && providerCandidates(for: serviceID).contains(where: { $0.id == moduleID })
        }
        for serviceID in providedServiceIDs where serviceProviders[serviceID] == nil {
            serviceProviders[serviceID] = providerCandidates(for: serviceID).first?.id
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(PersistedState(
                modules: modules,
                layout: layout,
                menuBarProviderID: menuBarProviderID,
                serviceProviders: serviceProviders,
                initialModuleChoiceCompleted: !needsInitialModuleChoice
            ))
            try data.write(to: stateURL, options: .atomic)
        } catch {
            logger.error("Failed to save module registry: \(error.localizedDescription)")
        }
    }
}

enum RegistryError: LocalizedError {
    case cannotRemoveBuiltIn
    case requiredBy([String])
    case missingDependencies([String])
    case circularDependency(String)
    case providerConflict(String)

    var errorDescription: String? {
        switch self {
        case .cannotRemoveBuiltIn:
            return String(localized: "Built-in compatibility modules cannot be removed in this preview.")
        case .requiredBy(let names):
            return String(localized: "This module is required by: \(names.joined(separator: ", "))")
        case .missingDependencies(let services):
            return String(localized: "Required services are not installed: \(services.joined(separator: ", "))")
        case .circularDependency(let moduleID):
            return String(localized: "The module creates a dependency cycle with \(moduleID).")
        case .providerConflict(let serviceID):
            return String(localized: "More than one module provides \(serviceID). Choose one provider before installing this module.")
        }
    }
}
