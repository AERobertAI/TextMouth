import XCTest
@testable import TextMouth

/// `PhoneLaunchRequest`: what a UI test, or a run in the iOS simulator, asks
/// of the iPhone app through its environment. The words are read here, on the
/// Mac; the two places that act on them are iOS's alone and debug builds'
/// alone, which is pinned by reading their source.
final class PhoneLaunchRequestTests: XCTestCase {

    // MARK: - The Sandbox

    /// Only the exact value "1" asks for a sandbox: an empty, mistyped, or
    /// missing value leaves the app's own library in use.
    func testOnlyOneAsksForASandbox() {
        XCTAssertTrue(PhoneLaunchRequest.runsInSandbox(["TEXTMOUTH_UI_TEST": "1"]))
        for value in ["", "0", "true", "yes", " 1"] {
            XCTAssertFalse(PhoneLaunchRequest.runsInSandbox(["TEXTMOUTH_UI_TEST": value]), value)
        }
        XCTAssertFalse(PhoneLaunchRequest.runsInSandbox([:]))
        XCTAssertFalse(PhoneLaunchRequest.runsInSandbox(["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]))
    }

    /// The Mac's process never asks: its detection is the one it was, keyed on
    /// XCTest's own variable, whatever the environment holds.
    func testTheMacsRuntimeIgnoresTheRequest() {
        let runtime = TextMouthRuntime.detect(
            environment: ["TEXTMOUTH_UI_TEST": "1"],
            processIdentifier: 4242,
            temporaryDirectory: FileManager.default.temporaryDirectory
        )
        XCTAssertFalse(runtime.isHostedTest, "Only the iPhone app's debug build reads the request")
    }

    // MARK: - The File Sent

    /// An absolute path is sent as a file URL; anything else sends nothing.
    func testOnlyAnAbsolutePathIsSent() {
        XCTAssertEqual(
            PhoneLaunchRequest.filesToOpen(["TEXTMOUTH_OPEN_AT_LAUNCH": "/tmp/books/Persuasion.epub"]),
            [URL(fileURLWithPath: "/tmp/books/Persuasion.epub")]
        )
        XCTAssertEqual(PhoneLaunchRequest.filesToOpen(["TEXTMOUTH_OPEN_AT_LAUNCH": "books/Persuasion.epub"]), [])
        XCTAssertEqual(PhoneLaunchRequest.filesToOpen(["TEXTMOUTH_OPEN_AT_LAUNCH": ""]), [])
        XCTAssertEqual(PhoneLaunchRequest.filesToOpen([:]), [])
        XCTAssertEqual(PhoneLaunchRequest.filesToOpen(["TEXTMOUTH_OPEN_AT_LAUNCH": "/tmp/a.epub"]).first?.isFileURL, true)
    }

    // MARK: - Where It Is Read

    /// Each place that reads the request does so in a debug build of the
    /// iPhone app only: the runtime's sandbox inside `#if os(iOS)` and
    /// `#if DEBUG`, and the scene delegate's file, an iOS file, inside
    /// `#if DEBUG`.
    func testTheRequestIsReadOnlyInTheIPhonesDebugBuild() throws {
        let runtime = try Self.source("App/TextMouthRuntime.swift")
        let detect = try Self.text(from: "static func detect(", upTo: "guard environment[testConfigurationVariable]", in: runtime)
        XCTAssertTrue(detect.contains("#if os(iOS)\n        #if DEBUG\n"), "The sandbox switch is not iOS's and debug's alone")
        XCTAssertTrue(detect.contains("PhoneLaunchRequest.runsInSandbox(environment)"))
        XCTAssertEqual(runtime.components(separatedBy: "PhoneLaunchRequest.").count - 1, 2, "PhoneLaunchRequest is read elsewhere")

        let scene = try Self.source("Platform/iOS/App/TextMouthSceneDelegate.swift")
        let opening = try Self.text(from: "#if DEBUG", upTo: "#endif", in: scene)
        XCTAssertTrue(opening.contains("PhoneLaunchRequest.filesToOpen(ProcessInfo.processInfo.environment)"))
        XCTAssertEqual(scene.components(separatedBy: "PhoneLaunchRequest.").count - 1, 1, "PhoneLaunchRequest is read outside #if DEBUG")
    }

    // MARK: - Reading the Source

    /// The text of the source file at `path` in the app's source folder.
    private static func source(_ path: String) throws -> String {
        try String(contentsOf: AppSourceFile.folder.appendingPathComponent(path), encoding: .utf8)
    }

    /// The part of `source` from `start` to the next `end`.
    private static func text(from start: String, upTo end: String, in source: String) throws -> String {
        let first = try XCTUnwrap(source.range(of: start), "\(start) moved")
        let last = try XCTUnwrap(source.range(of: end, range: first.upperBound..<source.endIndex), "No \(end)")
        return String(source[first.lowerBound..<last.lowerBound])
    }
}
