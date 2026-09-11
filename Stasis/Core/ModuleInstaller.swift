import CryptoKit
import Foundation
import Security

@MainActor
final class ModuleInstaller {
    private static let maximumArchiveBytes: Int64 = 128 * 1024 * 1024
    private static let maximumExpandedBytes: Int64 = 256 * 1024 * 1024
    struct Transaction {
        let descriptor: ModuleDescriptor
        let settingsSchema: ModuleSettingsSchema
        let localizations: ModuleLocalizationTable
        let previous: InstalledModule?
        fileprivate let destination: URL
        fileprivate let backup: URL?
    }

    private let registry: ModuleRegistry
    private let modulesRoot: URL

    init(registry: ModuleRegistry, fileManager: FileManager = .default) {
        self.registry = registry
        modulesRoot = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Stasis/Modules", isDirectory: true)
    }

    @discardableResult
    func install(from packageURL: URL, origin: ModuleOrigin = .local) throws -> ModuleDescriptor {
        let transaction = try beginInstall(from: packageURL, origin: origin)
        commit(transaction)
        return transaction.descriptor
    }

    func beginInstall(from packageURL: URL, origin: ModuleOrigin = .local) throws -> Transaction {
        let fileManager = FileManager.default
        let stagingRoot = fileManager.temporaryDirectory
            .appendingPathComponent("Stasis-Module-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingRoot) }

        if packageURL.hasDirectoryPath {
            try fileManager.copyItem(at: packageURL, to: stagingRoot.appendingPathComponent("payload"))
        } else {
            try preflightArchive(packageURL)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", packageURL.path, stagingRoot.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw ModuleInstallerError.cannotExpand }
        }

        let payload = try packageRoot(in: stagingRoot)
        try validateTree(payload)
        let descriptorURL = payload.appendingPathComponent("module.json")
        let descriptor = try JSONDecoder().decode(
            ModuleDescriptor.self,
            from: Data(contentsOf: descriptorURL)
        )
        if registry.module(id: descriptor.id)?.origin == .builtIn {
            throw ModuleInstallerError.cannotReplaceBuiltIn
        }
        try validate(descriptor)
        try validateEntrypoint(descriptor.entrypoint, in: payload, origin: origin)
        try registry.validateDependencies(for: descriptor)
        try validateChecksums(in: payload)
        let presentationURL = payload.appendingPathComponent("presentation.json")
        let presentation: PresentationDescriptor
        let settingsURL = payload.appendingPathComponent("settings.schema.json")
        let settingsSchema: ModuleSettingsSchema
        do {
            presentation = try JSONDecoder().decode(
                PresentationDescriptor.self,
                from: Data(contentsOf: presentationURL)
            )
        } catch {
            throw ModuleInstallerError.invalidPresentation
        }
        do {
            settingsSchema = try JSONDecoder().decode(
                ModuleSettingsSchema.self,
                from: Data(contentsOf: settingsURL)
            )
        } catch {
            throw ModuleInstallerError.invalidSettingsSchema
        }
        guard settingsSchema.version == descriptor.settingsVersion else {
            throw ModuleInstallerError.settingsVersionMismatch
        }
        try validatePresentation(presentation)
        try validateSettings(settingsSchema)
        let localizationURL = payload.appendingPathComponent("Resources/localizations.json")
        let localizations: ModuleLocalizationTable
        if fileManager.fileExists(atPath: localizationURL.path) {
            do {
                localizations = try JSONDecoder().decode(
                    ModuleLocalizationTable.self,
                    from: Data(contentsOf: localizationURL)
                )
                try validateLocalizations(localizations)
            } catch {
                throw ModuleInstallerError.invalidLocalizations
            }
        } else {
            localizations = .init()
        }

        let moduleRoot = modulesRoot.appendingPathComponent(descriptor.id, isDirectory: true)
        let destination = moduleRoot.appendingPathComponent(descriptor.version, isDirectory: true)
        let replacement = moduleRoot.appendingPathComponent(".incoming-\(UUID().uuidString)", isDirectory: true)
        let backup = moduleRoot.appendingPathComponent(".backup-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: moduleRoot, withIntermediateDirectories: true)
        try fileManager.copyItem(at: payload, to: replacement)
        let previous = registry.module(id: descriptor.id)
        var movedExistingVersion = false
        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.moveItem(at: destination, to: backup)
                movedExistingVersion = true
            }
            try fileManager.moveItem(at: replacement, to: destination)
            registry.register(
                descriptor,
                presentation: presentation,
                settingsSchema: settingsSchema,
                localizations: localizations,
                origin: origin
            )
        } catch {
            try? fileManager.removeItem(at: replacement)
            try? fileManager.removeItem(at: destination)
            if movedExistingVersion { try? fileManager.moveItem(at: backup, to: destination) }
            throw error
        }
        return Transaction(
            descriptor: descriptor,
            settingsSchema: settingsSchema,
            localizations: localizations,
            previous: previous,
            destination: destination,
            backup: movedExistingVersion ? backup : nil
        )
    }

    func commit(_ transaction: Transaction) {
        if let backup = transaction.backup { try? FileManager.default.removeItem(at: backup) }
    }

    func rollback(_ transaction: Transaction) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: transaction.destination)
        if let backup = transaction.backup {
            try? fileManager.moveItem(at: backup, to: transaction.destination)
        }
        registry.restoreInstallation(transaction.previous, replacing: transaction.descriptor.id)
    }

    func uninstall(moduleID: String) throws {
        let fileManager = FileManager.default
        let moduleRoot = modulesRoot.appendingPathComponent(moduleID, isDirectory: true)
        try registry.remove(moduleID: moduleID)
        guard fileManager.fileExists(atPath: moduleRoot.path) else { return }
        do {
            try fileManager.trashItem(at: moduleRoot, resultingItemURL: nil)
        } catch {
            // Registration is already gone, so stale program files cannot be
            // activated. Surface the cleanup error for manual recovery.
            throw ModuleInstallerError.cannotRemoveFiles
        }
    }

    func validate(_ descriptor: ModuleDescriptor) throws {
        guard !descriptor.id.isEmpty,
              descriptor.id.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]+$"#, options: .regularExpression) != nil
        else { throw ModuleInstallerError.invalidIdentifier }
        guard descriptor.protocolVersion.hasPrefix("1.") else {
            throw ModuleInstallerError.incompatibleProtocol
        }
        guard descriptor.version.range(
            of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$"#,
            options: .regularExpression
        ) != nil else { throw ModuleInstallerError.invalidVersion }
        guard !descriptor.architectures.isEmpty,
              descriptor.architectures.allSatisfy({ $0 == "arm64" || $0 == "x86_64" })
        else { throw ModuleInstallerError.invalidArchitectures }
        let supportedCapabilities = Set([
            "native.rows.v1", "native.settings.v1", "settings.validation.v1",
        ])
        guard Set(descriptor.uiCapabilities).isSubset(of: supportedCapabilities) else {
            throw ModuleInstallerError.unsupportedUICapability
        }
        let supportedPermissions = Set(["hardware.control", "notifications"])
        guard Set(descriptor.permissions).isSubset(of: supportedPermissions) else {
            throw ModuleInstallerError.unsupportedPermission
        }
        if descriptor.roles.contains(.control), !descriptor.permissions.contains("hardware.control") {
            throw ModuleInstallerError.missingControlPermission
        }
        if !descriptor.roles.isDisjoint(with: [.data, .business, .control]), descriptor.entrypoint == nil {
            throw ModuleInstallerError.missingWorker
        }
        guard Set(descriptor.provides.map(\.id)).count == descriptor.provides.count,
              Set(descriptor.requires.map(\.serviceID)).count == descriptor.requires.count
        else { throw ModuleInstallerError.duplicateServiceDeclaration }
        guard descriptor.provides.allSatisfy({ service in
            !service.id.isEmpty
                && !service.version.isEmpty
                && service.fields?.allSatisfy({ !$0.isEmpty }) != false
                && service.minimumInterval.map({ $0.isFinite && $0 > 0 }) != false
                && service.maximumInterval.map({ $0.isFinite && $0 > 0 }) != false
                && !(service.minimumInterval != nil && service.maximumInterval != nil
                    && service.minimumInterval! > service.maximumInterval!)
        }) else { throw ModuleInstallerError.invalidServiceDeclaration }
        guard version(BuiltInModuleCatalog.releaseVersion, meetsMinimum: descriptor.minHostVersion) else {
            throw ModuleInstallerError.incompatibleHost(descriptor.minHostVersion)
        }
        guard version(ProcessInfo.processInfo.operatingSystemVersionString.numericVersion, meetsMinimum: descriptor.minOSVersion) else {
            throw ModuleInstallerError.unsupportedOS(descriptor.minOSVersion)
        }
        let architecture = ProcessInfo.processInfo.machineArchitecture
        guard descriptor.architectures.contains(architecture) else {
            throw ModuleInstallerError.unsupportedArchitecture(architecture)
        }
    }

    private func version(_ current: String, meetsMinimum minimum: String) -> Bool {
        let lhs = current.split(separator: ".").prefix(3).map { Int($0) ?? 0 }
        let rhs = minimum.split(separator: ".").prefix(3).map { Int($0) ?? 0 }
        for index in 0..<max(lhs.count, rhs.count) {
            let l = index < lhs.count ? lhs[index] : 0
            let r = index < rhs.count ? rhs[index] : 0
            if l != r { return l > r }
        }
        return true
    }

    private func packageRoot(in stagingRoot: URL) throws -> URL {
        if FileManager.default.fileExists(
            atPath: stagingRoot.appendingPathComponent("module.json").path
        ) { return stagingRoot }
        let children = try FileManager.default.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        guard children.count == 1,
              FileManager.default.fileExists(
                atPath: children[0].appendingPathComponent("module.json").path
              )
        else { throw ModuleInstallerError.missingDescriptor }
        return children[0]
    }

    private func validateTree(_ root: URL) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey],
            options: []
        ) else { throw ModuleInstallerError.invalidPackage }
        let rootPath = root.standardizedFileURL.path + "/"
        var expandedBytes: Int64 = 0
        for case let url as URL in enumerator {
            guard url.standardizedFileURL.path.hasPrefix(rootPath) else {
                throw ModuleInstallerError.pathTraversal
            }
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            if values.isSymbolicLink == true {
                throw ModuleInstallerError.symbolicLinksNotAllowed
            }
            if values.isRegularFile == true {
                expandedBytes += Int64(values.fileSize ?? 0)
                guard expandedBytes <= Self.maximumExpandedBytes else {
                    throw ModuleInstallerError.packageTooLarge
                }
            }
        }
    }

    private func preflightArchive(_ archive: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: archive.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0, size <= Self.maximumArchiveBytes else {
            throw ModuleInstallerError.packageTooLarge
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        process.arguments = ["-1", archive.path]
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ModuleInstallerError.invalidPackage }
        let entries = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
        guard !entries.isEmpty else { throw ModuleInstallerError.invalidPackage }
        for entry in entries {
            let path = String(entry)
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            let pathComponents = path.hasSuffix("/") ? components.dropLast() : components[...]
            guard !path.hasPrefix("/"), !path.contains("\\"), !pathComponents.isEmpty,
                  pathComponents.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
            else { throw ModuleInstallerError.pathTraversal }
        }
    }

    private func validateChecksums(in root: URL) throws {
        let manifestURL = root.appendingPathComponent("checksums.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw ModuleInstallerError.missingChecksums
        }
        let checksums = try JSONDecoder().decode([String: String].self, from: data)
        let actualFiles = try regularFiles(in: root)
        guard Set(checksums.keys) == actualFiles else {
            throw ModuleInstallerError.incompleteChecksums
        }
        for (relativePath, expected) in checksums {
            guard !relativePath.hasPrefix("/"), !relativePath.contains("..") else {
                throw ModuleInstallerError.pathTraversal
            }
            let fileURL = root.appendingPathComponent(relativePath)
            let digest = SHA256.hash(data: try Data(contentsOf: fileURL))
                .map { String(format: "%02x", $0) }
                .joined()
            guard digest.caseInsensitiveCompare(expected) == .orderedSame else {
                throw ModuleInstallerError.checksumMismatch(relativePath)
            }
        }
    }

    private func validateEntrypoint(
        _ entrypoint: String?,
        in root: URL,
        origin: ModuleOrigin
    ) throws {
        guard let entrypoint else { return }
        guard !entrypoint.hasPrefix("/"), !entrypoint.contains("..") else {
            throw ModuleInstallerError.pathTraversal
        }
        let executable = root.appendingPathComponent(entrypoint).standardizedFileURL
        let prefix = root.standardizedFileURL.path + "/"
        guard executable.path.hasPrefix(prefix),
              FileManager.default.fileExists(atPath: executable.path),
              FileManager.default.isExecutableFile(atPath: executable.path)
        else { throw ModuleInstallerError.invalidEntrypoint }
        try validateCodeTrust(executable, origin: origin)
    }

    private func validateCodeTrust(_ executable: URL, origin: ModuleOrigin) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executable as CFURL, SecCSFlags(), &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil) == errSecSuccess
        else { throw ModuleInstallerError.invalidCodeSignature }

        guard origin == .catalog else { return }
        var requirement: SecRequirement?
        let source = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists" as CFString
        guard SecRequirementCreateWithString(source, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess
        else { throw ModuleInstallerError.catalogRequiresDeveloperID }
    }

    private func validatePresentation(_ presentation: PresentationDescriptor) throws {
        var identifiers = Set<String>()
        func visit(_ component: PresentationComponent) throws {
            guard !component.id.isEmpty, identifiers.insert(component.id).inserted else {
                throw ModuleInstallerError.invalidPresentation
            }
            if let symbol = component.systemImage,
               symbol.range(of: #"^[A-Za-z0-9.]+$"#, options: .regularExpression) == nil {
                throw ModuleInstallerError.invalidPresentation
            }
            try component.children.forEach(visit)
        }
        try (presentation.panel + presentation.menuBar).forEach(visit)
    }

    private func validateSettings(_ schema: ModuleSettingsSchema) throws {
        guard schema.version >= 1,
              schema.settings.allSatisfy({ !$0.id.isEmpty }),
              Set(schema.settings.map(\.id)).count == schema.settings.count
        else {
            throw ModuleInstallerError.invalidSettingsSchema
        }
        let definitions = Dictionary(uniqueKeysWithValues: schema.settings.map { ($0.id, $0) })
        for setting in schema.settings {
            if let condition = setting.visibleWhen {
                guard condition.settingID != setting.id,
                      let source = definitions[condition.settingID],
                      settingValue(condition.equals, matches: source)
                else { throw ModuleInstallerError.invalidSettingsSchema }
            }
            if let minimum = setting.minimum, let maximum = setting.maximum, minimum > maximum {
                throw ModuleInstallerError.invalidSettingsSchema
            }
            if let step = setting.step, step <= 0 {
                throw ModuleInstallerError.invalidSettingsSchema
            }
            if case .choice = setting.type {
                guard !setting.options.isEmpty,
                      Set(setting.options.map(\.value)).count == setting.options.count
                else { throw ModuleInstallerError.invalidSettingsSchema }
            } else if !setting.options.isEmpty {
                throw ModuleInstallerError.invalidSettingsSchema
            }
            switch (setting.type, setting.defaultValue) {
            case (.boolean, .bool), (.string, .string): break
            case (.integer, .number(let value)) where
                value.rounded() == value && valueIsInRange(value, setting): break
            case (.number, .number(let value)) where valueIsInRange(value, setting): break
            case (.choice, .string(let value)) where setting.options.contains(where: { $0.value == value }): break
            default: throw ModuleInstallerError.invalidSettingsSchema
            }
        }
    }

    private func settingValue(_ value: JSONValue, matches definition: SettingDefinition) -> Bool {
        switch (definition.type, value) {
        case (.boolean, .bool), (.string, .string): return true
        case (.integer, .number(let number)): return number.isFinite && number.rounded() == number
        case (.number, .number(let number)): return number.isFinite
        case (.choice, .string(let selected)):
            return definition.options.contains { $0.value == selected }
        default: return false
        }
    }

    private func validateLocalizations(_ table: ModuleLocalizationTable) throws {
        guard table.values.keys.allSatisfy({ !$0.isEmpty && $0.count <= 64 }),
              table.values.values.allSatisfy({ dictionary in
                  dictionary.keys.allSatisfy { !$0.isEmpty && $0.count <= 256 }
                      && dictionary.values.allSatisfy { $0.count <= 4_096 }
              })
        else { throw ModuleInstallerError.invalidLocalizations }
    }

    private func valueIsInRange(_ value: Double, _ setting: SettingDefinition) -> Bool {
        if let minimum = setting.minimum, value < minimum { return false }
        if let maximum = setting.maximum, value > maximum { return false }
        return value.isFinite
    }

    private func regularFiles(in root: URL) throws -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { throw ModuleInstallerError.invalidPackage }
        let prefix = root.standardizedFileURL.path + "/"
        var files = Set<String>()
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                  url.lastPathComponent != "checksums.json"
            else { continue }
            files.insert(String(url.standardizedFileURL.path.dropFirst(prefix.count)))
        }
        return files
    }
}

enum ModuleInstallerError: LocalizedError {
    case cannotExpand
    case missingDescriptor
    case invalidPackage
    case invalidIdentifier
    case invalidVersion
    case invalidArchitectures
    case incompatibleProtocol
    case incompatibleHost(String)
    case unsupportedOS(String)
    case unsupportedArchitecture(String)
    case pathTraversal
    case symbolicLinksNotAllowed
    case checksumMismatch(String)
    case invalidPresentation
    case invalidSettingsSchema
    case settingsVersionMismatch
    case missingChecksums
    case incompleteChecksums
    case invalidEntrypoint
    case cannotRemoveFiles
    case cannotReplaceBuiltIn
    case unsupportedUICapability
    case unsupportedPermission
    case missingControlPermission
    case missingWorker
    case duplicateServiceDeclaration
    case invalidServiceDeclaration
    case invalidLocalizations
    case invalidCodeSignature
    case catalogRequiresDeveloperID
    case packageTooLarge

    var errorDescription: String? {
        switch self {
        case .cannotExpand: return "The module package could not be expanded."
        case .missingDescriptor: return "The package does not contain module.json."
        case .invalidPackage: return "The module package is invalid."
        case .invalidIdentifier: return "The module identifier is invalid."
        case .invalidVersion: return "The module version is not valid semantic versioning."
        case .invalidArchitectures: return "The module contains an unsupported architecture declaration."
        case .incompatibleProtocol: return "The module protocol is not compatible with this state version."
        case .incompatibleHost(let version): return "The module requires state \(version) or later."
        case .unsupportedOS(let version): return "The module requires macOS \(version) or later."
        case .unsupportedArchitecture(let architecture): return "The module does not support \(architecture)."
        case .pathTraversal: return "The package contains an unsafe path."
        case .symbolicLinksNotAllowed: return "Symbolic links are not allowed in module packages."
        case .checksumMismatch(let path): return "Checksum verification failed for \(path)."
        case .invalidPresentation: return "presentation.json is missing or invalid."
        case .invalidSettingsSchema: return "settings.schema.json is missing or invalid."
        case .settingsVersionMismatch: return "The settings schema version does not match module.json."
        case .missingChecksums: return "The module package does not contain checksums.json."
        case .incompleteChecksums: return "The checksum manifest does not cover exactly the packaged files."
        case .invalidEntrypoint: return "The module worker entrypoint is missing or is not executable."
        case .cannotRemoveFiles: return "The module was unregistered, but its files could not be moved to the Trash."
        case .cannotReplaceBuiltIn: return "A local package cannot replace a built-in compatibility module."
        case .unsupportedUICapability: return "The module requests a native UI capability this state version does not support."
        case .unsupportedPermission: return "The module requests a core permission this state version does not support."
        case .missingControlPermission: return "A control module must declare the hardware.control permission."
        case .missingWorker: return "Data, business and control modules require a worker entrypoint."
        case .duplicateServiceDeclaration: return "The module declares the same service more than once."
        case .invalidServiceDeclaration: return "The module contains an invalid service capability declaration."
        case .invalidLocalizations: return "The module localization resources are invalid."
        case .invalidCodeSignature: return "The module worker does not have a valid code signature."
        case .catalogRequiresDeveloperID: return "Official catalog workers require a valid Developer ID signature."
        case .packageTooLarge: return "The module package exceeds the allowed size."
        }
    }
}

private extension ProcessInfo {
    var machineArchitecture: String {
        var system = utsname()
        uname(&system)
        return withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}

private extension String {
    var numericVersion: String {
        split(whereSeparator: { !$0.isNumber && $0 != "." }).first.map(String.init) ?? self
    }
}
