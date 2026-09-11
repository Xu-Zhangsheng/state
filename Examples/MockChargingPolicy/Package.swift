// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MockChargingPolicyExample",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../Packages")],
    targets: [.executableTarget(
        name: "MockChargingPolicyWorker",
        dependencies: [.product(name: "StasisModuleSDK", package: "Packages")]
    )]
)
