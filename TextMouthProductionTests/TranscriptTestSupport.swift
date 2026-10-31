import XCTest
@testable import TextMouth

/// Transcripts for the transcription tests (FR05), built from text, so each
/// test states the sentences it needs and nothing else. The words are
/// invented, so a line of the debug log that quoted them would stand out.
enum TranscriptFixtures {
    /// A date in whole seconds, as transcript.json keeps dates (ISO 8601),
    /// so a transcript read back equals the one written.
    static let date = Date(timeIntervalSince1970: 1_790_000_000)

    /// A transcription language other than the one this Mac's region makes
    /// the default (`TranscriptionLanguage.defaultIdentifier`), so a test
    /// that sets it always changes the setting, wherever it runs.
    static var languageOtherThanTheDefault: String {
        TranscriptionLanguage.defaultIdentifier == "en-NZ" ? "en-IE" : "en-NZ"
    }

    /// A sentence of `text` spoken from `start` to `end` milliseconds into
    /// its file: one word per run of non-space characters, each lasting an
    /// equal share of the sentence and starting where the one before it
    /// ended, as SpeechTranscriber times them, each with a confidence of
    /// 0.9.
    static func sentence(_ text: String, from start: Int, to end: Int) -> TranscriptSentence {
        let utf16 = Array(text.utf16)
        var ranges: [(offset: Int, count: Int)] = []
        var index = 0
        while index < utf16.count {
            if utf16[index] == UInt16(UInt8(ascii: " ")) {
                index += 1
                continue
            }
            let wordStart = index
            while index < utf16.count, utf16[index] != UInt16(UInt8(ascii: " ")) {
                index += 1
            }
            ranges.append((wordStart, index - wordStart))
        }
        let step = ranges.isEmpty ? 0 : (end - start) / ranges.count
        let words = ranges.enumerated().map { number, range in
            TranscriptWord(
                characterOffset: range.offset,
                characterCount: range.count,
                startMilliseconds: start + number * step,
                endMilliseconds: number == ranges.count - 1 ? end : start + (number + 1) * step,
                confidence: 0.9
            )
        }
        return TranscriptSentence(text: text, startMilliseconds: start, endMilliseconds: end, words: words)
    }

    /// A fingerprint for a file that was never on disk, of `byteCount`
    /// bytes, for tests that never compare it with a file.
    static func fingerprint(byteCount: Int64 = 4_096) -> FileFingerprint {
        FileFingerprint(
            stamp: FileStamp(byteCount: byteCount, modificationTimeNanoseconds: 1_790_000_000_000_000_000),
            digest: "0123456789abcdef0123456789abcdef"
        )
    }

    /// A transcript in English of `files`, each a path, how long the file
    /// plays in milliseconds, and its sentences, made by a fixed build on a
    /// fixed date.
    static func transcript(
        _ files: [(path: String, duration: Int, sentences: [TranscriptSentence])],
        locale: String = "en-US"
    ) -> Transcript {
        Transcript(
            version: Transcript.currentVersion,
            locale: locale,
            model: TranscriptSpeechModel(
                engine: "SpeechTranscriber",
                assetStatus: "installed",
                systemVersion: "Version 26.3.1 (Build 25D2128)"
            ),
            app: TranscriptAppBuild(version: "1.0", build: "42", commit: "abc1234"),
            createdAt: date,
            files: files.map { file in
                TranscriptFile(
                    path: file.path,
                    fingerprint: fingerprint(),
                    durationMilliseconds: file.duration,
                    sentences: file.sentences
                )
            }
        )
    }

    /// A transcript of `book`'s audio as the transcription service makes
    /// one: each of the book's files, in the order it plays them, measured
    /// and fingerprinted as it is now, with `sentences`, by the file's path
    /// in the book, as what was heard in it.
    static func transcript(of book: Book, sentences: [String: [TranscriptSentence]]) throws -> Transcript {
        var transcript = transcript([])
        transcript.files = try TranscriptionPlan.make(for: book).files.map { file in
            TranscriptFile(
                path: file.path,
                fingerprint: try XCTUnwrap(FileFingerprint(of: file.url, hasher: .md5)),
                durationMilliseconds: Transcript.milliseconds(file.duration),
                sentences: sentences[file.path] ?? []
            )
        }
        return transcript
    }

    /// Two files of invented narration: three sentences in the first and
    /// two in the second, every word timed.
    static var twoFiles: Transcript {
        transcript([
            (path: "01.wav", duration: 9_000, sentences: [
                sentence("Quillwort grows by the ferry slip.", from: 0, to: 2_400),
                sentence("Tide tables hang in the harbor office.", from: 2_400, to: 5_100),
                sentence("Nobody reads them twice.", from: 5_100, to: 6_960),
            ]),
            (path: "Disc 2/02.wav", duration: 6_000, sentences: [
                sentence("The salt road bends east.", from: 0, to: 1_980),
                sentence("Carts wait at the toll.", from: 1_980, to: 3_900),
            ]),
        ])
    }
}

// MARK: - This Mac's Recognizer

extension XCTestCase {
    /// The English model's locale, skipping the test unless this Mac can
    /// transcribe English now: macOS 26, a Mac that runs the recognizer,
    /// and the English model installed. Nothing is downloaded to get it.
    /// On the main actor, as the tests that transcribe run.
    @MainActor
    func requireInstalledEnglishModel() async throws -> Locale {
        try XCTSkipUnless(
            TranscriptionAvailability.systemSupport == .available,
            "transcription needs macOS 26 on a Mac that runs its model"
        )
        guard case .installed(let locale) = await TranscriptionAvailability.modelStatus(for: Locale(identifier: "en-US")) else {
            throw XCTSkip("the English speech model is not installed on this Mac, and the tests never download it")
        }
        return locale
    }

    /// The TestData archive `name`, found in this checkout's TestData or,
    /// from a linked worktree, in the main checkout's
    /// (`testDataArchiveIfPresent(_:)`). The test is skipped only when
    /// neither has it. The tests extract what they need into their own
    /// sandbox.
    func optionalTestDataArchive(_ name: String) throws -> URL {
        guard let url = testDataArchiveIfPresent(name) else {
            throw XCTSkip("\(name) is not in this checkout's TestData")
        }
        return url
    }
}

// MARK: - TestData from a Linked Worktree

/// The TestData archive `name`, from this checkout's TestData or, from a
/// linked worktree, the main checkout's, which keeps the archives git
/// ignores (the DAISY audio books, downloaded separately); nil when
/// neither has it. The archive is only ever read.
func testDataArchiveIfPresent(_ name: String) -> URL? {
    let ownCopy = URL(fileURLWithPath: testFilePath(name))
    let mainCheckoutCopy = mainCheckoutRoot(of: thisCheckoutRoot).map {
        $0.appendingPathComponent("TestData", isDirectory: true).appendingPathComponent(name)
    }
    // This checkout's own copy first, so a checkout that keeps the archive
    // always reads its own.
    return [ownCopy, mainCheckoutCopy].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
}

/// The root of the checkout this file was compiled in: the folder two
/// levels above this source file, where `testFileURL` in
/// LegacyScenarioHarness.swift finds TestData.
private let thisCheckoutRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()

/// The repository's main checkout, when the checkout at `root` is a linked
/// worktree: its `.git` is a file whose `gitdir:` line names
/// `<main>/.git/worktrees/<name>`. Nil for the main checkout itself, or for
/// anything else.
///
/// Git writes the line as `gitdir: ` and the path, ending in a newline. The
/// path is absolute unless the worktree was made with relative paths (Git
/// 2.48's `worktree.useRelativePaths`), when it is relative to `root`. Only
/// a path whose last component's two parents are `worktrees` and `.git`
/// counts: a submodule's `.git` file names `.git/modules/<name>`, which is
/// not another checkout of this repository.
fileprivate func mainCheckoutRoot(of root: URL) -> URL? {
    // A `.git` folder, as the main checkout has, or a missing or unreadable
    // file, reads as no text.
    let prefix = "gitdir: "
    guard let text = try? String(contentsOf: root.appendingPathComponent(".git"), encoding: .utf8),
          text.hasPrefix(prefix) else { return nil }
    let path = text.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else { return nil }
    let gitDirectory = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path))
        .standardizedFileURL
    let worktrees = gitDirectory.deletingLastPathComponent()
    let repository = worktrees.deletingLastPathComponent()
    guard worktrees.lastPathComponent == "worktrees", repository.lastPathComponent == ".git" else { return nil }
    return repository.deletingLastPathComponent()
}

// MARK: - Finding the Main Checkout, Tested

/// `mainCheckoutRoot(of:)` on checkouts made in each test's own sandbox:
/// a linked worktree's `.git` file, as git writes it, leads to the main
/// checkout, and nothing else does.
final class TranscriptFixtureLookupTests: XCTestCase {

    /// A linked worktree's `.git` file names the main checkout: the folder
    /// holding the `.git` whose `worktrees` folder the line names.
    func testAWorktreesGitFileGivesTheMainCheckout() throws {
        let sandbox = try makeSandboxDirectory("fixture-lookup")
        let worktree = try makeCheckout(in: sandbox, gitFile: "gitdir: \(mainCheckout(in: sandbox).path)/.git/worktrees/agent-feature")

        XCTAssertEqual(mainCheckoutRoot(of: worktree)?.path, mainCheckout(in: sandbox).path)
    }

    /// The newline that ends git's line is trimmed, and so is any other
    /// white space after the path.
    func testATrailingNewlineIsTrimmed() throws {
        let sandbox = try makeSandboxDirectory("fixture-lookup")
        let line = "gitdir: \(mainCheckout(in: sandbox).path)/.git/worktrees/agent-feature"

        for ending in ["\n", "\r\n", " \t\n\n"] {
            let worktree = try makeCheckout(in: sandbox, gitFile: line + ending)
            XCTAssertEqual(mainCheckoutRoot(of: worktree)?.path, mainCheckout(in: sandbox).path, "ending \(ending.debugDescription)")
        }
    }

    /// A worktree made with relative paths (Git 2.48's
    /// `worktree.useRelativePaths`) names its gitdir from its own folder.
    func testARelativeGitdirIsReadFromTheWorktreesOwnFolder() throws {
        let sandbox = try makeSandboxDirectory("fixture-lookup")
        let worktree = try makeCheckout(in: sandbox, gitFile: "gitdir: ../Main Checkout/.git/worktrees/agent-feature\n")

        XCTAssertEqual(mainCheckoutRoot(of: worktree)?.path, mainCheckout(in: sandbox).path)
    }

    /// The main checkout's `.git` is a folder, worktrees and all, and a
    /// folder with no `.git` is no checkout: neither leads anywhere.
    func testAGitFolderOrNoGitGivesNothing() throws {
        let sandbox = try makeSandboxDirectory("fixture-lookup")
        let main = mainCheckout(in: sandbox)
        try FileManager.default.createDirectory(
            at: main.appendingPathComponent(".git/worktrees/agent-feature", isDirectory: true),
            withIntermediateDirectories: true
        )
        let plainFolder = sandbox.appendingPathComponent("Plain Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: plainFolder, withIntermediateDirectories: true)

        XCTAssertNil(mainCheckoutRoot(of: main))
        XCTAssertNil(mainCheckoutRoot(of: plainFolder))
    }

    /// A `.git` file whose text does not start with `gitdir: ` exactly
    /// gives nothing.
    func testAGitFileWithoutGitdirGivesNothing() throws {
        let sandbox = try makeSandboxDirectory("fixture-lookup")
        let gitDirectory = "\(mainCheckout(in: sandbox).path)/.git/worktrees/agent-feature"

        for text in ["", "gitdir: \n", gitDirectory, "gitdir:\(gitDirectory)", " gitdir: \(gitDirectory)", "GITDIR: \(gitDirectory)"] {
            let worktree = try makeCheckout(in: sandbox, gitFile: text + "\n")
            XCTAssertNil(mainCheckoutRoot(of: worktree), text.debugDescription)
        }
    }

    /// A gitdir that does not end in `.git/worktrees/<name>` names no main
    /// checkout: a submodule's, the repository itself, `worktrees` with no
    /// name after it, folders named otherwise, or a name of two components.
    func testAGitdirOutsideGitWorktreesGivesNothing() throws {
        let sandbox = try makeSandboxDirectory("fixture-lookup")
        let main = mainCheckout(in: sandbox).path

        for gitDirectory in [
            "\(main)/.git/modules/library",
            "\(main)/.git",
            "\(main)/.git/worktrees",
            "\(main)/git/worktrees/agent-feature",
            "\(main)/.git/trees/agent-feature",
            "\(main)/.git/worktrees/agent-feature/extra",
        ] {
            let worktree = try makeCheckout(in: sandbox, gitFile: "gitdir: \(gitDirectory)\n")
            XCTAssertNil(mainCheckoutRoot(of: worktree), gitDirectory)
        }
    }

    // MARK: - Helpers

    /// Where the main checkout lies in `sandbox` for these tests. Nothing
    /// is made there unless a test makes it.
    private func mainCheckout(in sandbox: URL) -> URL {
        sandbox.appendingPathComponent("Main Checkout", isDirectory: true)
    }

    /// A checkout folder in `sandbox`, made on first use, whose `.git` is a
    /// file holding `gitFile`, replacing the one a test wrote before.
    private func makeCheckout(in sandbox: URL, gitFile: String) throws -> URL {
        let checkout = sandbox.appendingPathComponent("Linked Worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try Data(gitFile.utf8).write(to: checkout.appendingPathComponent(".git"))
        return checkout
    }
}
