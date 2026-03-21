// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TextMouthTests",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.5"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "TextMouthTests",
            dependencies: [
                "ZIPFoundation",
                "SwiftSoup",
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            path: "Sources"
        ),
    ]
)
