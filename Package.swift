// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BudSwitch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "BudSwitch")
    ]
)
