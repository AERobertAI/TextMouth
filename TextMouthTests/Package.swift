// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TextMouthTests",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TextMouthTests",
            path: "ProductionTestRunner"
        ),
    ]
)
