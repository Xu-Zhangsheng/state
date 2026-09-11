import StasisNativeUI
import SwiftUI

struct ModuleLayoutSettingsView: View {
    let runtime: StasisRuntime
    @State private var livePreview = false

    private var registry: ModuleRegistry { runtime.registry }

    var body: some View {
        Form {
            Section {
                Picker(
                    "Menu Bar Provider",
                    selection: Binding(
                        get: { registry.menuBarProviderID ?? "" },
                        set: { registry.setMenuBarProvider($0.isEmpty ? nil : $0) }
                    )
                ) {
                    Label("state", systemImage: "circle.grid.2x2").tag("")
                    ForEach(registry.menuBarProviderCandidates) { module in
                        Label(module.displayName, systemImage: module.descriptor.systemImage)
                            .tag(module.id)
                    }
                }
            } header: {
                Text("Menu Bar")
            } footer: {
                Text("Choose which module supplies the menu bar icon and text. state uses its app icon without collecting telemetry.")
            }

            Section {
                ForEach(Array(registry.orderedModules.enumerated()), id: \.element.id) { index, module in
                    HStack(spacing: 10) {
                        Image(systemName: module.descriptor.systemImage)
                            .frame(width: 20)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(module.displayName)
                            Text(module.isEnabled ? "Available" : "Module disabled")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if module.descriptor.roles.contains(.presentation) {
                            Toggle(
                                "Shown",
                                isOn: Binding(
                                    get: { module.isVisible },
                                    set: { registry.setVisible($0, moduleID: module.id) }
                                )
                            )
                            .labelsHidden()
                            .disabled(!module.isEnabled)
                        }
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.tertiary)
                            .draggable(module.id)
                    }
                    .dropDestination(for: String.self) { ids, _ in
                        guard let sourceID = ids.first,
                              let source = registry.orderedModules.firstIndex(where: { $0.id == sourceID })
                        else { return false }
                        registry.move(from: IndexSet(integer: source), to: index)
                        return true
                    }
                    .padding(.vertical, 3)
                }
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Panel Modules")
                    Text("Drag modules to change panel order. Hidden display modules stop display-only sampling.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Preview") {
                Toggle("Live Preview", isOn: $livePreview)
                Text(livePreview
                    ? "Visible modules may collect data while this preview is open."
                    : "Static sample values are shown without starting module sampling.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ModulePanelPreview(
                    modules: registry.visibleModules.filter { $0.descriptor.roles.contains(.presentation) },
                    stateStore: runtime.presentationState,
                    livePreview: livePreview
                )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 0)
        .transaction { $0.animation = nil }
        .onChange(of: livePreview, initial: true) { _, enabled in
            runtime.setLivePreviewEnabled(enabled)
        }
        .onDisappear {
            livePreview = false
            runtime.setLivePreviewEnabled(false)
        }
    }
}

private struct ModulePanelPreview: View {
    let modules: [InstalledModule]
    let stateStore: ModulePresentationStateStore
    let livePreview: Bool

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(modules.enumerated()), id: \.element.id) { index, module in
                if let presentation = module.localizedPresentation, !presentation.panel.isEmpty {
                    StasisDeclarativePanelView(
                        components: presentation.panel,
                        state: stateStore.states[module.id] ?? [:],
                        resolvesPublishedState: livePreview,
                        action: { _, _ in }
                    )
                } else {
                    HStack {
                        Label(module.displayName, systemImage: module.descriptor.systemImage)
                        Spacer()
                        Text("—").foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
                if index < modules.count - 1 { Divider().padding(.horizontal, 12) }
            }
        }
        .frame(width: StasisMenuMetrics.width)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }
}
