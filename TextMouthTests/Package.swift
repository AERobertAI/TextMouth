// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TextMouthTests",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TextMouthTests",
            path: "ProductionTestRunner",
            // Complete concurrency checking, as every target of the Xcode
            // project has (project.yml): this is the flag Xcode passes for
            // SWIFT_STRICT_CONCURRENCY = complete in the Swift 5 mode.
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
    ]
)
