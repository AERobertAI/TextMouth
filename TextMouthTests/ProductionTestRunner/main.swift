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

/// The folder xcodebuild builds in, from TEXTMOUTH_TEST_DERIVED_DATA, a path
/// relative to the repository root or absolute, which `make test
/// TEST_DERIVED_DATA=<folder>` sets. Unset or empty, xcodebuild uses Xcode's
/// default DerivedData folder. The reproducibility gate (Scripts/check.sh)
/// names a folder it empties first, so every source is compiled, and reports
/// its warnings, in the gate's own run.
let derivedDataArguments: [String] = {
    guard let folder = ProcessInfo.processInfo.environment["TEXTMOUTH_TEST_DERIVED_DATA"],
          !folder.isEmpty else {
        return []
    }
    return ["-derivedDataPath", URL(fileURLWithPath: folder, relativeTo: repositoryRoot).path]
}()

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
] + derivedDataArguments
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
