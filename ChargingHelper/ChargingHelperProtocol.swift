import Foundation

@objc protocol ChargingHelperProtocol {
    func checkAvailability(reply: @escaping @Sendable (Bool, String?) -> Void)
    func manageBatteryCharging(enabled: Bool, reply: @escaping @Sendable (Bool, String?) -> Void)
    func manageExternalPower(enabled: Bool, reply: @escaping @Sendable (Bool, String?) -> Void)
    func manageMagsafeLED(target: UInt8, reply: @escaping @Sendable (Bool, String?) -> Void)
    func applyPowerState(
        chargingEnabled: Bool,
        controlsCharging: Bool,
        externalPowerEnabled: Bool,
        controlsExternalPower: Bool,
        magSafeLEDTarget: UInt8,
        controlsMagSafeLED: Bool,
        reply: @escaping @Sendable (Bool, String?) -> Void
    )
    func readChipPower(reply: @escaping @Sendable (Double) -> Void)
}
