import SwiftUI
import smc_power

enum SettingsRoute: Hashable {
    case application
    case modules
    case panelLayout
    case module(ModuleSettingsArea, String)

    var title: String {
        switch self {
        case .application: String(localized: "Application")
        case .modules: String(localized: "Modules")
        case .panelLayout: String(localized: "Layout & Preview")
        case .module: ""
        }
    }
}

struct SettingsView: View {
    @State private var selectedRoute: SettingsRoute? = .application

    let runtime: StasisRuntime
    let batteryService: BatteryService

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedRoute) {
                Section("General Settings") {
                    routeLabel("Application", icon: "gearshape", route: .application)
                    routeLabel("Modules", icon: "shippingbox", route: .modules)
                    moduleRoutes(area: .general)
                }

                Section("Panel Settings") {
                    routeLabel("Layout & Preview", icon: "rectangle.3.group", route: .panelLayout)
                    moduleRoutes(area: .panel)
                }

                Section("Feature Settings") {
                    moduleRoutes(area: .feature)
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 270)
            .listStyle(.sidebar)
        } detail: {
            detail.navigationTitle(routeTitle)
        }
        .frame(minWidth: 820, minHeight: 560)
    }

    @ViewBuilder
    private func moduleRoutes(area: ModuleSettingsArea) -> some View {
        ForEach(runtime.registry.orderedModules.filter { $0.descriptor.settingsAreas.contains(area) }) { module in
            Label(module.displayName, systemImage: module.descriptor.systemImage)
                .tag(SettingsRoute.module(area, module.id))
                .opacity(module.isEnabled ? 1 : 0.55)
        }
    }

    private func routeLabel(_ title: LocalizedStringKey, icon: String, route: SettingsRoute) -> some View {
        Label(title, systemImage: icon).tag(route)
    }

    @ViewBuilder
    private var detail: some View {
        switch selectedRoute ?? .application {
        case .application:
            GeneralSettingsView()
        case .modules:
            ModuleManagerView(runtime: runtime)
        case .panelLayout:
            ModuleLayoutSettingsView(runtime: runtime)
        case .module(let area, let moduleID):
            switch area {
            case .general:
                ModuleGeneralSettingsView(
                    runtime: runtime,
                    registry: runtime.registry,
                    settingsStore: runtime.settingsStore,
                    permissionBroker: runtime.permissionBroker,
                    controlLeases: runtime.controlLeases,
                    taskStore: runtime.taskStore,
                    moduleID: moduleID
                )
            case .panel:
                ModulePanelSettingsView(
                    runtime: runtime,
                    registry: runtime.registry,
                    settingsStore: runtime.settingsStore,
                    moduleID: moduleID
                )
            case .feature:
                ModuleFeatureSettingsView(
                    moduleID: moduleID,
                    registry: runtime.registry,
                    settingsStore: runtime.settingsStore,
                    capabilities: batteryService.deviceCapabilities,
                    runtime: runtime
                )
            }
        }
    }

    private var routeTitle: String {
        switch selectedRoute ?? .application {
        case .module(_, let moduleID):
            runtime.registry.module(id: moduleID)?.displayName ?? "state"
        case let route:
            route.title
        }
    }
}
