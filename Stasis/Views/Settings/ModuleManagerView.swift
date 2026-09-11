import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ModuleManagerView: View {
    let runtime: StasisRuntime
    @State private var message: String?
    @State private var catalog = ModuleCatalogClient()
    @State private var pendingRemoval: InstalledModule?
    @State private var pendingDisable: InstalledModule?

    var body: some View {
        Form {
            Section {
                ForEach(runtime.registry.orderedModules) { module in
                    HStack(spacing: 10) {
                        Image(systemName: module.descriptor.systemImage)
                            .frame(width: 22)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(module.displayName).fontWeight(.medium)
                            Text("v\(module.descriptor.version) · \(module.origin.title)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(module.summary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle(
                            "Enabled",
                            isOn: Binding(
                                get: { module.isEnabled },
                                set: { setEnabled($0, module: module) }
                            )
                        )
                        .labelsHidden()
                        if module.origin != .builtIn {
                            Button {
                                pendingRemoval = module
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove Module")
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Installed Modules")
                    Text("Enabled modules may provide data or background behavior. Panel visibility is configured separately.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if !runtime.registry.providedServiceIDs.isEmpty {
                Section("Service Providers") {
                    ForEach(runtime.registry.providedServiceIDs, id: \.self) { serviceID in
                        let candidates = runtime.registry.providerCandidates(for: serviceID)
                        if candidates.count > 1 {
                            Picker(
                                serviceID,
                                selection: Binding(
                                    get: { runtime.registry.selectedProviderID(for: serviceID) ?? "" },
                                    set: { runtime.registry.setServiceProvider($0, for: serviceID) }
                                )
                            ) {
                                ForEach(candidates) { module in
                                    Text(module.displayName).tag(module.id)
                                }
                            }
                        } else if let provider = candidates.first {
                            LabeledContent(serviceID, value: provider.displayName)
                        }
                    }
                }
            }

            Section {
                Button("Install Local Module…") { chooseModule() }
            } footer: {
                Text("Packages are checked for protocol, architecture, unsafe paths and checksums before activation.")
            }

            Section("Official Catalog") {
                if catalog.isLoading {
                    ProgressView().controlSize(.small)
                } else if catalog.entries.isEmpty {
                    Text(catalog.errorMessage ?? "The recommended suite is already included in this preview.")
                        .foregroundStyle(.secondary)
                    Button("Check for Modules") { Task { await catalog.refresh() } }
                } else {
                    ForEach(catalog.entries) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.displayName)
                                Text(entry.summary).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Install") { install(entry) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 0)
        .alert("Modules", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
        .confirmationDialog(
            "Remove Module?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            )
        ) {
            Button("Remove Module", role: .destructive) {
                guard let module = pendingRemoval else { return }
                pendingRemoval = nil
                Task {
                    do { try await runtime.uninstallModule(module.id) }
                    catch { message = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("The module program will be moved to the Trash. Its settings are kept for a later reinstall.")
        }
        .confirmationDialog(
            "Disable Required Module?",
            isPresented: Binding(
                get: { pendingDisable != nil },
                set: { if !$0 { pendingDisable = nil } }
            )
        ) {
            Button("Disable Module", role: .destructive) {
                guard let module = pendingDisable else { return }
                pendingDisable = nil
                do { try runtime.setModuleEnabled(false, moduleID: module.id) }
                catch { message = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) { pendingDisable = nil }
        } message: {
            if let module = pendingDisable {
                let names = runtime.registry.blockingDependents(ifUnavailable: module.id)
                    .map(\.displayName)
                    .joined(separator: ", ")
                Text("These modules will stop until another compatible provider is selected: ")
                    + Text(names)
            }
        }
    }

    private func install(_ entry: ModuleCatalogEntry) {
        Task {
            do {
                let url = try await catalog.download(entry)
                defer { try? FileManager.default.removeItem(at: url) }
                let descriptor = try await runtime.installModule(from: url, origin: .catalog)
                message = String(localized: "Installed \(runtime.registry.module(id: descriptor.id)?.displayName ?? descriptor.displayName).")
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func setEnabled(_ enabled: Bool, module: InstalledModule) {
        if !enabled, !runtime.registry.blockingDependents(ifUnavailable: module.id).isEmpty {
            pendingDisable = module
            return
        }
        do { try runtime.setModuleEnabled(enabled, moduleID: module.id) }
        catch { message = error.localizedDescription }
    }

    private func chooseModule() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "stasismodule") ?? .zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let descriptor = try await runtime.installModule(from: url, origin: .local)
                message = String(localized: "Installed \(runtime.registry.module(id: descriptor.id)?.displayName ?? descriptor.displayName).")
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

private extension ModuleOrigin {
    var title: String {
        switch self {
        case .builtIn: "Built-in"
        case .catalog: "Official catalog"
        case .local: "Local"
        }
    }
}
