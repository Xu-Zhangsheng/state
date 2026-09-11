// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MetricProviderExample",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../Packages")],
    targets: [.executableTarget(
        name: "MetricProviderWorker",
        dependencies: [.product(name: "StasisModuleSDK", package: "Packages")]
    )]
)
