// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StasisModuleCLI",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "stasis-module", targets: ["stasis-module"])],
    dependencies: [
        .package(path: "../../Packages"),
    ],
    targets: [
        .executableTarget(
            name: "stasis-module",
            dependencies: [.product(name: "StasisContracts", package: "Packages")]
        ),
        .testTarget(name: "StasisModuleCLITests", dependencies: ["stasis-module"]),
    ]
)
