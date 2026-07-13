import Foundation

/// Compatibility entry point for the historical `swift run` workflow.
/// The old standalone executable compiled copied app implementations, so it
/// could pass even when production code was broken. This runner delegates to
/// the hosted XCTest target, whose tests use `@testable import TextMouth`.
let runnerFile = URL(fileURLWithPath: #filePath)
let repositoryRoot = runnerFile
    .deletingLastPathComponent() // main.swift -> ProductionTestRunner
    .deletingLastPathComponent() // ProductionTestRunner -> TextMouthTests
    .deletingLastPathComponent() // TextMouthTests -> repository root

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
process.currentDirectoryURL = repositoryRoot
process.arguments = [
    "xcodebuild",
    "test",
    "-project", "TextMouth.xcodeproj",
    "-scheme", "TextMouth",
    "-destination", "platform=macOS",
    "CODE_SIGNING_ALLOWED=NO"
]
process.standardOutput = FileHandle.standardOutput
process.standardError = FileHandle.standardError

do {
    try process.run()
    process.waitUntilExit()
    exit(process.terminationStatus)
} catch {
    FileHandle.standardError.write(
        Data("Unable to launch production tests: \(error)\n".utf8)
    )
    exit(1)
}
