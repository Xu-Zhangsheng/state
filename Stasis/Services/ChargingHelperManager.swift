import Foundation
import Security
import ServiceManagement
import os.log

enum ChargingHelperStatus: Equatable {
    case notInstalled
    case requiresApproval
    case installed
    case unavailable(String)
}

enum ChargingHelperError: LocalizedError {
    case installerRequired

    var errorDescription: String? {
        switch self {
        case .installerRequired:
            String(localized: "The charging helper is not installed. Reinstall state using the installer package.")
        }
    }
}

@MainActor
private final class AvailabilityAttempt {
    private var didFinish = false
    private let continuation: CheckedContinuation<Bool, Never>

    init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func finish(success: Bool, message: String?, manager: ChargingHelperManager) {
        guard !didFinish else { return }
        didFinish = true
        if success {
            manager.markOperational()
        } else {
            manager.markUnavailable(message ?? "Unknown helper error")
        }
        continuation.resume(returning: success)
    }
}

@MainActor
@Observable
class ChargingHelperManager {
    static let shared = ChargingHelperManager()

    private enum Deployment {
        case bundled
        case legacy
    }

    private static let bundledMachServiceName = "com.srimanachanta.stasis.charging-helper"
    private static let bundledPlistName = "com.srimanachanta.stasis.charging-helper.plist"
    private static let legacyMachServiceName = "com.srimanachanta.stasis.charging-helper.legacy"
    private static let legacyPlistURL = URL(
        fileURLWithPath: "/Library/LaunchDaemons/com.srimanachanta.stasis.charging-helper.legacy.plist"
    )

    private let service = SMAppService.daemon(plistName: bundledPlistName)
    private let deployment: Deployment
    private var connection: NSXPCConnection?
    private var retryAfter = Date.distantPast
    private var lastLoggedError: String?
    private let logger = Logger(
        subsystem: "com.srimanachanta.stasis",
        category: "ChargingHelperManager"
    )

    private(set) var helperStatus: ChargingHelperStatus = .notInstalled
    private(set) var isOperational = false

    var isInstalled: Bool {
        switch deployment {
        case .bundled:
            service.status == .enabled
        case .legacy:
            SMAppService.statusForLegacyPlist(at: Self.legacyPlistURL) == .enabled
        }
    }

    /// The grouped operation was added with the bundled helper protocol. An
    /// ad-hoc local install may still be paired with the older privileged
    /// legacy helper, so callers must use the legacy command set there.
    var supportsGroupedPowerState: Bool {
        if case .bundled = deployment { return true }
        return false
    }

    private var machServiceName: String {
        switch deployment {
        case .bundled: Self.bundledMachServiceName
        case .legacy: Self.legacyMachServiceName
        }
    }

    private init() {
        deployment = Self.hasTeamIdentifier ? .bundled : .legacy
        refreshStatus()
        logger.info("Charging helper deployment: \(self.deploymentName, privacy: .public)")
    }

    private var deploymentName: String {
        switch deployment {
        case .bundled: "signed bundle"
        case .legacy: "installer"
        }
    }

    private static var hasTeamIdentifier: Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            Bundle.main.bundleURL as CFURL,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess, let staticCode else {
            return false
        }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
            let dictionary = information as? [CFString: Any],
            let teamIdentifier = dictionary[kSecCodeInfoTeamIdentifier] as? String
        else {
            return false
        }
        return !teamIdentifier.isEmpty
    }

    func install() throws {
        logger.info("Enabling charging helper using \(self.deploymentName, privacy: .public)")

        switch deployment {
        case .bundled:
            do {
                try service.register()
            } catch {
                if service.status != .enabled && service.status != .requiresApproval {
                    throw error
                }
            }
        case .legacy:
            guard isInstalled else {
                throw ChargingHelperError.installerRequired
            }
        }

        refreshStatus()
    }

    func uninstall() throws {
        logger.info("Disabling charging management")
        disconnect()
        isOperational = false

        switch deployment {
        case .bundled:
            try service.unregister()
            helperStatus = .notInstalled
        case .legacy:
            // The package-installed daemon remains dormant and is launched on demand.
            // Removing it would require another administrator password prompt.
            refreshStatus()
        }
    }

    func refreshStatus() {
        let status: SMAppService.Status
        switch deployment {
        case .bundled:
            status = service.status
        case .legacy:
            status = SMAppService.statusForLegacyPlist(at: Self.legacyPlistURL)
        }

        switch status {
        case .enabled:
            if !isOperational {
                helperStatus = .installed
            }
        case .requiresApproval:
            helperStatus = .requiresApproval
            isOperational = false
        default:
            helperStatus = .notInstalled
            isOperational = false
        }
    }

    @discardableResult
    func verifyAvailability() async -> Bool {
        refreshStatus()
        guard isInstalled else { return false }

        return await withCheckedContinuation { continuation in
            let attempt = AvailabilityAttempt(continuation: continuation)
            let finish: @Sendable (Bool, String?) -> Void = { [weak self] success, message in
                Task { @MainActor in
                    guard let self else { return }
                    attempt.finish(success: success, message: message, manager: self)
                }
            }

            guard let helper = getHelper(errorHandler: { error in
                finish(false, error.localizedDescription)
            }) else {
                finish(false, "The helper service could not be reached")
                return
            }

            helper.checkAvailability(reply: finish)
            Task {
                try? await Task.sleep(for: .seconds(3))
                finish(false, "The helper did not respond")
            }
        }
    }

    func getHelper(errorHandler: @escaping @Sendable (Error) -> Void) -> ChargingHelperProtocol? {
        guard isInstalled, Date() >= retryAfter else { return nil }
        if connection == nil {
            connect()
        }
        guard let connection else { return nil }
        return connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            Task { @MainActor in
                self?.markUnavailable(error.localizedDescription)
            }
            errorHandler(error)
        } as? ChargingHelperProtocol
    }

    func markOperational() {
        retryAfter = .distantPast
        lastLoggedError = nil
        isOperational = true
        helperStatus = .installed
        NotificationCenter.default.post(
            name: .chargingHelperBecameOperational,
            object: nil
        )
    }

    func markUnavailable(_ message: String) {
        isOperational = false
        helperStatus = .unavailable(message)
        retryAfter = Date().addingTimeInterval(5)
        connection?.invalidate()
        connection = nil
        if lastLoggedError != message {
            logger.error("Charging helper unavailable: \(message, privacy: .public)")
            lastLoggedError = message
        }
    }

    private func connect() {
        logger.info("Connecting to charging helper: \(self.machServiceName, privacy: .public)")
        let newConnection = NSXPCConnection(machServiceName: machServiceName)
        newConnection.remoteObjectInterface = NSXPCInterface(with: ChargingHelperProtocol.self)

        newConnection.invalidationHandler = { [weak self] in
            Task { @MainActor in
                guard let self, self.connection === newConnection else { return }
                self.connection = nil
                self.isOperational = false
            }
        }
        newConnection.interruptionHandler = { [weak self] in
            Task { @MainActor in
                guard let self, self.connection === newConnection else { return }
                self.connection = nil
                self.isOperational = false
            }
        }

        newConnection.resume()
        connection = newConnection
    }

    func disconnect() {
        connection?.invalidate()
        connection = nil
        isOperational = false
    }
}
