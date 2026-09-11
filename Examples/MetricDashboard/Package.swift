// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MetricDashboardExample",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../Packages")],
    targets: [.executableTarget(
        name: "MetricDashboardWorker",
        dependencies: [.product(name: "StasisModuleSDK", package: "Packages")]
    )]
)
