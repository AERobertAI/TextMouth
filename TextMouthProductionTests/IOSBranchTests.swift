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
    /// Mac too comes back as `.couldNotStart`. On the main actor only so that
    /// the sandbox folder's tear-down block is added there.
    @MainActor
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

    // MARK: - The Boundary

    /// No file outside the iPhone's folders names one of the iPhone's types
    /// outside an iOS branch: the Mac compiles TextMouth/Phone/ but must never
    /// reach it, which is what lets the Mac projection pass over that folder.
    func testOnlyTheIPhonesFoldersNameItsTypesOutsideAnIOSBranch() throws {
        let name = try NSRegularExpression(pattern: #"\bPhone[A-Z]\w*"#)
        let files = try AppSourceFile.all().filter {
            !$0.path.hasPrefix("Phone/") && !$0.path.hasPrefix("Platform/iOS/")
        }
        for file in files {
            for (number, line) in Self.codeOutsideIOSBranches(of: file.text) {
                let range = NSRange(line.startIndex..., in: line)
                guard let match = name.firstMatch(in: line, range: range), let found = Range(match.range, in: line) else {
                    continue
                }
                XCTFail("\(file.path):\(number) names \(line[found]) outside #if os(iOS)")
            }
        }
    }

    /// The scanner itself: the iOS branch of `#if os(iOS)` and the `#else` of
    /// `#if os(macOS)` are left out, comments are taken off, and everything
    /// else is kept, numbered from one.
    func testTheBoundaryScannerReadsBranchesAndComments() {
        let sample = """
        let a = PhoneSession()
        #if os(iOS)
        let b = PhoneSession()
        #else
        let c = 1 // PhoneSession
        #endif
        #if os(macOS)
        let d = 2
        #else
        let e = PhoneAppModel()
        #endif
        """
        let kept = Self.codeOutsideIOSBranches(of: sample)
        XCTAssertEqual(kept.map { $0.number }, [1, 5, 8])
        XCTAssertEqual(kept.map { $0.line.trimmingCharacters(in: .whitespaces) }, ["let a = PhoneSession()", "let c = 1", "let d = 2"])
    }

    // MARK: - The Reader's Hooks

    /// On iOS the reader's skips call the phone's moves when set, and otherwise
    /// the reader's own; the Mac runs `skipForward()` and `skipBackward()` as
    /// before.
    func testTheReadersSkipsCallThePhonesMovesWhenSet() throws {
        let source = try Self.source("ViewModels/ReaderViewModel.swift")
        for (callback, hook, own) in [
            ("onSkipForward: { [weak self] in", "self?.phoneHooks.moveForward", "self?.skipForward()"),
            ("onSkipBackward: { [weak self] in", "self?.phoneHooks.moveBackward", "self?.skipBackward()"),
        ] {
            let body = try Self.text(from: callback, upTo: "},", in: source)
            let iOSBranch = try XCTUnwrap(body.range(of: "#if os(iOS)"), "\(callback) has no iOS branch")
            let branchEnd = try XCTUnwrap(body.range(of: "#endif"), "\(callback) has no #endif")
            XCTAssertTrue(body[iOSBranch.upperBound..<branchEnd.lowerBound].contains(hook))
            XCTAssertTrue(body[branchEnd.upperBound...].contains(own), "\(callback) lost its own skip")
        }
        XCTAssertTrue(source.contains("#if os(iOS)\n    /// The iPhone's hooks into this reader"), "phoneHooks is not iOS's alone")
    }

    // MARK: - Reading the Source

    /// The lines of `text` the Mac's code holds outside every iOS branch, each
    /// with its number, comments taken off: the branch of `#if os(iOS)` and
    /// the `#else` of `#if os(macOS)` are left out, and a branch of any other
    /// condition is kept.
    static func codeOutsideIOSBranches(of text: String) -> [(number: Int, line: String)] {
        // For each open #if: whether its branch now is iOS's alone, and
        // whether its #else would be.
        var frames: [(isIOS: Bool, elseIsIOS: Bool)] = []
        var kept: [(number: Int, line: String)] = []
        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if ") {
                let condition = trimmed.dropFirst(4).trimmingCharacters(in: .whitespaces)
                frames.append((condition == "os(iOS)", condition == "os(macOS)" || condition == "!os(iOS)"))
                continue
            }
            if trimmed.hasPrefix("#elseif ") {
                _ = frames.popLast()
                frames.append((trimmed.dropFirst(8).trimmingCharacters(in: .whitespaces) == "os(iOS)", false))
                continue
            }
            if trimmed == "#else", let last = frames.popLast() {
                frames.append((last.elseIsIOS, false))
                continue
            }
            if trimmed == "#endif" {
                _ = frames.popLast()
                continue
            }
            guard !frames.contains(where: { $0.isIOS }) else { continue }
            let code = raw.components(separatedBy: "//").first ?? raw
            if !code.trimmingCharacters(in: .whitespaces).isEmpty {
                kept.append((index + 1, code))
            }
        }
        return kept
    }


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
