// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TextMouthTests",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TextMouthTests",
            path: "ProductionTestRunner"
        ),
    ],
    // The Swift 6 language mode, as every target of the Xcode project has
    // (project.yml): complete concurrency checking, with data races as errors.
    swiftLanguageModes: [.v6]
)
