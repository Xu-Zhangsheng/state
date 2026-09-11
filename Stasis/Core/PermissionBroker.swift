import Foundation

actor PermissionBroker {
    private var grants: [String: Set<String>] = [:]
    private let storageURL: URL

    init(fileManager: FileManager = .default) {
        storageURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Stasis/module-permissions.json")
        if let data = try? Data(contentsOf: storageURL),
           let saved = try? JSONDecoder().decode([String: Set<String>].self, from: data) {
            grants = saved
        }
    }

    func grant(_ permission: String, to moduleID: String) throws {
        var proposed = grants
        proposed[moduleID, default: []].insert(permission)
        try persist(proposed)
        grants = proposed
    }

    func revoke(_ permission: String, from moduleID: String) throws {
        var proposed = grants
        proposed[moduleID]?.remove(permission)
        try persist(proposed)
        grants = proposed
    }

    func revokeAll(from moduleID: String) throws {
        var proposed = grants
        proposed[moduleID] = nil
        try persist(proposed)
        grants = proposed
    }

    func isGranted(_ permission: String, to moduleID: String) -> Bool {
        grants[moduleID]?.contains(permission) == true
    }

    func authorize(moduleID: String, permission: String) throws {
        guard grants[moduleID]?.contains(permission) == true else {
            throw PermissionBrokerError.denied(permission)
        }
    }

    private func persist(_ proposed: [String: Set<String>]) throws {
        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(proposed).write(to: storageURL, options: .atomic)
    }
}

enum PermissionBrokerError: LocalizedError {
    case denied(String)
    var errorDescription: String? {
        switch self {
        case .denied(let permission): "The module is not authorized for \(permission)."
        }
    }
}
