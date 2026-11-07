import XCTest
@testable import TextMouth

/// What Slice 1's iOS branches rest on. Nothing can run on iOS tonight, and the
/// Mac compiles neither `TextMouth/Platform/iOS/` nor an `#if os(iOS)` block. So
/// the shared path each relies on runs here on the Mac, where it can, and the
/// branch itself is pinned by reading its source, since a slip in these is
/// costly: the first would have the Simulator write into the live library.
final class IOSBranchTests: XCTestCase {
    // MARK: - An M4B With No Helper

    /// What an M4B, M4A, or MP4 does on iOS, where afinfo cannot start: `read`
    /// has no answer, so the file is not listed for conversion, and imports as
    /// it is. Run here with a tool whose program does not exist, which on the
    /// Mac too comes back as `.couldNotStart`.
    func testAnMPEG4FileIsLeftAsItIsWhenItsHelperCannotStart() async throws {
        let folder = try makeSandboxDirectory("IOSBranchMPEG4")
        for (name, brand) in [("book.m4b", "M4B "), ("track.m4a", "M4A "), ("film.mp4", "isom")] {
            let file = folder.appendingPathComponent(name)
            // An MPEG-4 file's first box: its length, then "ftyp", then its
            // brand, which the sniffer reads as MPEG-4 and leaves to afinfo.
            var bytes: [UInt8] = [0, 0, 0, 0x14]
            bytes += Array("ftyp\(brand)".utf8)
            bytes += [UInt8](repeating: 0, count: 65_536)
            try Data(bytes).write(to: file)
            let tool = AudioFileInfo.Tool(
                command: { _ in (URL(fileURLWithPath: "/nonexistent/afinfo"), []) },
                limits: AudioFileInfo.Tool.afinfo.limits,
                residentMemory: AudioFileInfo.Tool.afinfo.residentMemory
            )

            let facts = try await AudioFileInfo.read(file, using: tool)
            XCTAssertNil(facts, "\(name): a helper that cannot start has no answer")
            let converted = try await ImportAudioConverter.needsConversion(among: [file], using: tool)
            XCTAssertEqual(converted, [], "\(name) would stop the import at Converting its audio")
        }
    }

    /// The stand-in answers for the question and throws for the conversion.
    func testTheStandInAnswersTheQuestionAndRefusesTheConversion() throws {
        let source = try Self.source("Platform/iOS/Services/WatchedProcess+iOS.swift")
        let question = try XCTUnwrap(source.range(of: "static func runCapturingOutput("), "runCapturingOutput moved")

        let afterQuestion = String(source[question.lowerBound...])
        XCTAssertTrue(afterQuestion.contains("(outcome: .couldNotStart, output: Data())"))
        XCTAssertFalse(afterQuestion.contains("throw "), "A throw stops every M4B at Converting its audio")

        let beforeQuestion = String(source[..<question.lowerBound])
        XCTAssertTrue(beforeQuestion.contains("throw IOSUnavailable.feature(\"Converting this kind of file\")"))
    }

    /// With no answer from afinfo, a file the import converts says the spec's
    /// sentence on iOS, while the Mac keeps calling it unreadable.
    func testAConversionWithNoAnswerSaysThePhonesSentence() throws {
        let source = try Self.source("Services/ImportAudioConverter.swift")
        let guardStart = try XCTUnwrap(
            source.range(of: "guard let info = try await inspect(source, using: tool.info) else {"),
            "convert's first step moved"
        )
        let guardEnd = try XCTUnwrap(
            source.range(of: "#endif", range: guardStart.upperBound..<source.endIndex),
            "convert's first step has no #if"
        )
        let branch = String(source[guardStart.upperBound..<guardEnd.lowerBound])

        let iOSBranch = try XCTUnwrap(branch.range(of: "#if os(iOS)"), "No iOS branch")
        let macBranch = try XCTUnwrap(branch.range(of: "#else"), "No Mac branch")
        XCTAssertLessThan(iOSBranch.lowerBound, macBranch.lowerBound)
        XCTAssertTrue(branch[iOSBranch.upperBound..<macBranch.lowerBound].contains(
            "throw IOSUnavailable.feature(\"Converting this kind of file\")"
        ))
        XCTAssertTrue(branch[macBranch.upperBound...].contains("throw Failure.unreadable(fileName: name)"))
    }

    // MARK: - The Library's Place

    /// On iOS the home is the app's own container. The user database, which the
    /// Mac reads, names the Mac user's real home in the Simulator, whose
    /// ~/.TextMouth is the live library.
    func testTheIPhonesHomeIsItsContainer() throws {
        let source = try Self.source("App/TextMouthRuntime.swift")
        let body = try Self.text(from: "static var realHomeDirectory: URL {", upTo: "#endif", in: source)

        let iOSBranch = try XCTUnwrap(body.range(of: "#if os(iOS)"), "No iOS branch")
        let macBranch = try XCTUnwrap(body.range(of: "#else"), "No Mac branch")
        let iOSCode = body[iOSBranch.upperBound..<macBranch.lowerBound]
        // Each of these three only looks for words in the source's text.
        let iOSHome = "return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)" // lint-ok: words to look for, never run
        XCTAssertTrue(iOSCode.contains(iOSHome))
        XCTAssertFalse(iOSCode.contains("getpwuid("), "The user database names a real home") // lint-ok: words to look for, never run
        XCTAssertTrue(body[macBranch.upperBound...].contains("getpwuid(getuid())"), "The Mac reads the user database") // lint-ok: words to look for, never run
    }

    /// On iOS the library is in Application Support, with the dot, and so is
    /// not what the legacy migration reads as an old library. Its name there
    /// is told apart here too, on the Mac's own functions.
    func testTheIPhonesLibraryIsNotTheLegacyFolder() throws {
        let source = try Self.source("Services/TextMouthPaths.swift")
        let body = try Self.text(from: "static func defaultRoot(in home: URL) -> URL {", upTo: "#endif", in: source)

        let iOSBranch = try XCTUnwrap(body.range(of: "#if os(iOS)"), "No iOS branch")
        let macBranch = try XCTUnwrap(body.range(of: "#else"), "No Mac branch")
        let iOSCode = body[iOSBranch.upperBound..<macBranch.lowerBound]
        XCTAssertTrue(iOSCode.contains("home.appendingPathComponent(\"Library/Application Support\", isDirectory: true)"))
        XCTAssertTrue(iOSCode.contains(".appendingPathComponent(dataDirectoryName, isDirectory: true)"))

        let home = URL(fileURLWithPath: "/home", isDirectory: true)
        XCTAssertEqual(
            TextMouthPaths.legacyApplicationSupportDirectory(in: home).path,
            "/home/Library/Application Support/TextMouth",
            "The iOS branch's comment says why the dot matters: this is the folder it must not be"
        )
        XCTAssertEqual(TextMouthPaths.dataDirectoryName, ".TextMouth") // lint-ok: compares a constant, and reaches no folder
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
