import Foundation
import os.log
import Security
import smc_power

let logger = Logger(
    subsystem: "com.srimanachanta.stasis.charging-helper",
    category: "ServiceDelegate"
)

let battery: SMCBattery
let adapter: SMCAdapter
do {
    battery = try SMCBattery.probe()
    adapter = try SMCAdapter.probe()
} catch {
    logger.fault("Failed to probe SMC capabilities: \(error.localizedDescription)")
    exit(1)
}

class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    let helper: ChargingHelper

    init(helper: ChargingHelper) {
        self.helper = helper
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        guard ClientAuthenticator.accepts(newConnection) else {
            logger.error("Rejected XPC connection from an untrusted client")
            return false
        }
        newConnection.exportedInterface = NSXPCInterface(
            with: (any ChargingHelperProtocol).self
        )
        newConnection.exportedObject = helper

        logger.info("XPC connection accepted")

        newConnection.invalidationHandler = { [weak self] in
            guard let self else { return }
            logger.info("XPC connection invalidated, resetting SMC keys to defaults")
            self.helper.resetToDefaults()
            exit(0)
        }

        newConnection.resume()
        return true
    }
}

private enum ClientAuthenticator {
    private static let expectedIdentifier = "com.srimanachanta.stasis"
    private static let expectedTeamIdentifier = "447GJ83BJ5"

    static func accepts(_ connection: NSXPCConnection) -> Bool {
        let attributes = [kSecGuestAttributePid: NSNumber(value: connection.processIdentifier)] as CFDictionary
        var guestCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &guestCode) == errSecSuccess,
              let guestCode
        else { return false }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(guestCode, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else { return false }

        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        ) == errSecSuccess,
              let info = signingInformation as? [CFString: Any],
              let identifier = info[kSecCodeInfoIdentifier] as? String,
              identifier == expectedIdentifier
        else { return false }

        if let team = info[kSecCodeInfoTeamIdentifier] as? String {
            return team == expectedTeamIdentifier
        }

        // Legacy package installs were ad-hoc signed before a Developer ID was
        // available. Keep that migration path narrow: exact identifier and an
        // application installed in the system Applications directory.
        guard let executable = info[kSecCodeInfoMainExecutable] as? URL else { return false }
        let path = executable.standardizedFileURL.path
#if DEBUG
        if path.contains("/DerivedData/") { return true }
#endif
        return path == "/Applications/Stasis.app/Contents/MacOS/Stasis"
            || path == "/Applications/stasis.app/Contents/MacOS/stasis"
            || path == "/Applications/state.app/Contents/MacOS/stasis"
    }
}

let helper = ChargingHelper(battery: battery, adapter: adapter)
let delegate = ServiceDelegate(helper: helper)
let legacyServiceName = "com.srimanachanta.stasis.charging-helper.legacy"
let serviceName: String
if let argumentIndex = CommandLine.arguments.firstIndex(of: "--mach-service"),
    CommandLine.arguments.indices.contains(argumentIndex + 1)
{
    serviceName = CommandLine.arguments[argumentIndex + 1]
} else {
    serviceName = "com.srimanachanta.stasis.charging-helper"
}

guard serviceName == "com.srimanachanta.stasis.charging-helper"
    || serviceName == legacyServiceName
else {
    logger.fault("Refusing unexpected Mach service name: \(serviceName, privacy: .public)")
    exit(2)
}

let listener = NSXPCListener(machServiceName: serviceName)
listener.delegate = delegate
listener.resume()

dispatchMain()
