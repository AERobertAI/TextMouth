import XCTest
@testable import TextMouth

// `PhoneLaunchRequest` exists in debug builds only, and so do these tests of it.
#if DEBUG

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

    // MARK: - The Search Filled In

    /// A non-empty value is the text the Search in Book field starts with;
    /// a missing or empty one leaves the field empty.
    func testTheSearchTextIsWhatTheVariableHolds() {
        XCTAssertEqual(PhoneLaunchRequest.searchText(["TEXTMOUTH_SEARCH_IN_BOOK": "Cheshire"]), "Cheshire")
        XCTAssertEqual(PhoneLaunchRequest.searchText(["TEXTMOUTH_SEARCH_IN_BOOK": "two words"]), "two words")
        XCTAssertNil(PhoneLaunchRequest.searchText(["TEXTMOUTH_SEARCH_IN_BOOK": ""]))
        XCTAssertNil(PhoneLaunchRequest.searchText([:]))
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

    /// The type itself is compiled into debug builds only: its file opens
    /// `#if DEBUG` before the enum and closes it after the enum's last brace,
    /// so a release build holds neither the type nor its variable names.
    func testTheTypeIsCompiledIntoDebugBuildsOnly() throws {
        let type = try Self.source("Phone/PhoneLaunchRequest.swift")
        let guardStart = try XCTUnwrap(type.range(of: "\n#if DEBUG\n"), "PhoneLaunchRequest.swift has no #if DEBUG line")
        let enumStart = try XCTUnwrap(type.range(of: "enum PhoneLaunchRequest {"), "The enum moved")
        XCTAssertLessThan(guardStart.lowerBound, enumStart.lowerBound, "#if DEBUG comes after the enum")
        // Counted as whole lines: the file's comment names the condition too.
        XCTAssertEqual(type.split(separator: "\n").filter { $0 == "#if DEBUG" }.count, 1, "Not exactly one #if DEBUG line in PhoneLaunchRequest.swift")
        XCTAssertTrue(type.hasSuffix("}\n\n#endif\n"), "The enum is not the last thing inside the #if DEBUG")
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

#endif
