// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StasisPackages",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StasisContracts", targets: ["StasisContracts"]),
        .library(name: "StasisModuleSDK", targets: ["StasisModuleSDK"]),
        .library(name: "StasisCore", targets: ["StasisCore"]),
        .library(name: "StasisNativeUI", targets: ["StasisNativeUI"]),
    ],
    targets: [
        .target(name: "StasisContracts"),
        .target(name: "StasisModuleSDK", dependencies: ["StasisContracts"]),
        .target(name: "StasisCore", dependencies: ["StasisContracts"]),
        .target(name: "StasisNativeUI", dependencies: ["StasisContracts"]),
        .testTarget(name: "StasisContractsTests", dependencies: ["StasisContracts"]),
        .testTarget(name: "StasisCoreTests", dependencies: ["StasisCore", "StasisContracts"]),
        .testTarget(name: "StasisModuleSDKTests", dependencies: ["StasisModuleSDK", "StasisContracts"]),
    ]
)
