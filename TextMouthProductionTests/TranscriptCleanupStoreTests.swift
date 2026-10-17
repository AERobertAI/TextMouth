import XCTest
@testable import TextMouth

/// Saving and undoing a transcript cleanup in a book's package (FR05,
/// `TranscriptStore.cleanUp`, `TranscriptStore.undoCleanup`): the
/// transcript rewritten and recorded as cleaned up, the transcript from
/// before kept beside it and put back, and the book left as it was when the
/// cleanup can't be made. Every book is a silent audiobook of the test's
/// own, transcribed with invented narration; nothing reaches the system's
/// recognizer.
@MainActor
final class TranscriptCleanupStoreTests: XCTestCase {

    // MARK: - Cleaning Up

    /// A cleanup rewrites transcript.json's sentences and records itself in
    /// it, keeps the transcript from before beside it byte for byte, writes
    /// content.md and the index's transcript layer again, and leaves the
    /// position as it was.
    func testACleanupRewritesTheTranscriptAndKeepsTheOneBefore() throws {
        let world = try makeIntegrationWorld("Transcript Cleanup")
        let (book, transcript) = try TranscriptCleanupFixtures.transcribedBook(in: world, savedPosition: ReadingPosition(chapterIndex: 1, characterOffset: 12))
        let original = try Data(contentsOf: TextMouthPaths.transcriptPath(in: book.tmbDirectory))

        let result = try TranscriptStore.cleanUp(book, expecting: transcript, with: Self.rules, from: .user, now: TranscriptFixtures.date)

        XCTAssertEqual(result.corrections, 2)
        XCTAssertEqual(result.changedSentences, 2)
        guard case .found(let saved) = TranscriptStore.read(from: book.tmbDirectory) else {
            return XCTFail("the cleaned transcript could not be read")
        }
        XCTAssertEqual(saved.cleanedUp, TranscriptCleanupNote(
            cleanedAt: TranscriptFixtures.date, rulesVersion: 4, rulesDate: "2026-10-04", rules: "user", corrections: 2
        ))
        // Two files are read below; stop here, not in a trap, if one is missing.
        _ = try XCTUnwrap(saved.files[safe: 1], "the cleaned transcript has no second file")
        _ = try XCTUnwrap(transcript.files[safe: 1], "the transcribed book has no second file")
        XCTAssertEqual(saved.files[0].sentences.map(\.text), ["Gannet wings fold over the break-water.", "Rope coils dry on the jetty."])
        XCTAssertEqual(saved.files[0].sentences.map(\.words.isEmpty), [true, true])
        XCTAssertEqual(saved.files[1], transcript.files[1], "a file the rules did not change changed")
        XCTAssertEqual(try Data(contentsOf: copyURL(of: book)), original, "the transcript from before was not kept as it was")
        XCTAssertTrue(TranscriptStore.hasTranscriptBeforeCleanup(of: book))

        let markdown = try String(contentsOf: MarkdownCacheService.cacheURL(for: book), encoding: .utf8)
        // content.md is Markdown, its punctuation escaped (break\-water), so
        // a word without punctuation is looked for.
        XCTAssertTrue(markdown.contains("jetty") && !markdown.contains("pier"), markdown)
        XCTAssertTrue(result.installation.text.chapterText(0)?.contains("jetty") == true)
        let record = try BookInfo.load(from: book.tmbDirectory)
        XCTAssertNotNil(record.contentIndex?.transcript)
        XCTAssertEqual(record.state.readingPosition?.characterOffset, 12)
        let loaded = TranscriptTextLoader.load(for: book, audioIndex: try XCTUnwrap(record.contentIndex))
        XCTAssertEqual(loaded.text?.chapterText(0)?.contains("break-water"), true, "the book does not read the cleaned text")
        XCTAssertFalse(loaded.indexChanged, "the saved text was not taken as it was")
    }

    /// A transcript changed since the sheet showed its changes, or one the
    /// rules change nothing in, is not cleaned up, and nothing is kept.
    func testACleanupRefusesAChangedTranscriptAndOneWithNothingToChange() throws {
        let world = try makeIntegrationWorld("Transcript Cleanup Refused")
        let (book, transcript) = try TranscriptCleanupFixtures.transcribedBook(in: world)
        let original = try Data(contentsOf: TextMouthPaths.transcriptPath(in: book.tmbDirectory))
        _ = try XCTUnwrap(transcript.files[safe: 0]?.sentences[safe: 0], "the transcribed book has no first sentence")
        var shown = transcript
        shown.files[0].sentences[0].rewrite(as: "Gannet wings fold.")
        let nothing = TranscriptCleanupRuleSet(version: 1, date: "2026-10-04", rules: [rule("quillwort", "quill-wort")])

        XCTAssertThrowsError(try TranscriptStore.cleanUp(book, expecting: shown, with: Self.rules, from: .builtIn)) {
            XCTAssertEqual($0 as? TranscriptCleanupError, .transcriptChanged)
        }
        XCTAssertThrowsError(try TranscriptStore.cleanUp(book, expecting: transcript, with: nothing, from: .builtIn)) {
            XCTAssertEqual($0 as? TranscriptCleanupError, .nothingToChange)
        }
        XCTAssertEqual(try Data(contentsOf: TextMouthPaths.transcriptPath(in: book.tmbDirectory)), original)
        XCTAssertFalse(TranscriptStore.hasTranscriptBeforeCleanup(of: book))
    }

    /// A cleanup that can't be saved, as when the book's audio changed since
    /// it was transcribed, leaves transcript.json and the copy beside it as
    /// they were.
    func testAFailedCleanupLeavesTheBookAsItWas() throws {
        let world = try makeIntegrationWorld("Transcript Cleanup Failed")
        let (book, transcript) = try TranscriptCleanupFixtures.transcribedBook(in: world)
        let original = try Data(contentsOf: TextMouthPaths.transcriptPath(in: book.tmbDirectory))
        let track = URL(fileURLWithPath: book.filePath).appendingPathComponent("02.wav")
        try AudioTestFixtures.writeSilence(to: track, duration: 4)

        XCTAssertThrowsError(try TranscriptStore.cleanUp(book, expecting: transcript, with: Self.rules, from: .builtIn)) { error in
            guard case .audioChanged = error as? TranscriptCleanupError else {
                return XCTFail("refused for \(error), not the changed audio")
            }
        }
        XCTAssertEqual(try Data(contentsOf: TextMouthPaths.transcriptPath(in: book.tmbDirectory)), original)
        XCTAssertFalse(TranscriptStore.hasTranscriptBeforeCleanup(of: book), "a copy was left behind")
    }

    // MARK: - Undoing

    /// Undo Cleanup puts back the transcript from before, its text and its
    /// layer, and removes the copy; there is then nothing more to undo.
    func testUndoPutsBackTheTranscriptFromBefore() throws {
        let world = try makeIntegrationWorld("Transcript Cleanup Undone")
        let (book, transcript) = try TranscriptCleanupFixtures.transcribedBook(in: world)
        try TranscriptStore.cleanUp(book, expecting: transcript, with: Self.rules, from: .builtIn)

        let installation = try TranscriptStore.undoCleanup(of: book)

        XCTAssertEqual(TranscriptStore.read(from: book.tmbDirectory), .found(transcript))
        XCTAssertFalse(TranscriptStore.hasTranscriptBeforeCleanup(of: book))
        let markdown = try String(contentsOf: MarkdownCacheService.cacheURL(for: book), encoding: .utf8)
        XCTAssertTrue(markdown.contains("pier") && !markdown.contains("jetty"), markdown)
        XCTAssertTrue(installation.text.chapterText(0)?.contains("pier") == true)
        XCTAssertThrowsError(try TranscriptStore.undoCleanup(of: book)) {
            XCTAssertEqual($0 as? TranscriptCleanupError, .nothingToUndo)
        }
    }

    /// Undo Cleanup refuses a transcript never cleaned up, a cleaned one
    /// whose copy from before is gone, and a copy that can't be used,
    /// leaving the transcript as it is.
    func testUndoRefusesWithoutAUsableTranscriptFromBefore() throws {
        let world = try makeIntegrationWorld("Transcript Cleanup Undo Refused")
        let (book, transcript) = try TranscriptCleanupFixtures.transcribedBook(in: world)

        XCTAssertThrowsError(try TranscriptStore.undoCleanup(of: book)) {
            XCTAssertEqual($0 as? TranscriptCleanupError, .nothingToUndo)
        }
        try TranscriptStore.cleanUp(book, expecting: transcript, with: Self.rules, from: .builtIn)
        let cleaned = try Data(contentsOf: TextMouthPaths.transcriptPath(in: book.tmbDirectory))
        try Data("{\"version\": 1".utf8).write(to: copyURL(of: book))
        XCTAssertThrowsError(try TranscriptStore.undoCleanup(of: book)) {
            XCTAssertEqual($0 as? TranscriptCleanupError, .previousUnusable("it is not valid JSON"))
        }
        try FileManager.default.removeItem(at: copyURL(of: book))
        XCTAssertThrowsError(try TranscriptStore.undoCleanup(of: book)) {
            XCTAssertEqual($0 as? TranscriptCleanupError, .nothingToUndo)
        }
        XCTAssertEqual(try Data(contentsOf: TextMouthPaths.transcriptPath(in: book.tmbDirectory)), cleaned)
    }

    /// Deleting a transcript deletes the copy kept before its cleanup, which
    /// is TextMouth's own file, never part of the book.
    func testTheCopyBeforeCleanupGoesWithTheTranscript() throws {
        let world = try makeIntegrationWorld("Transcript Cleanup Deleted")
        let (book, transcript) = try TranscriptCleanupFixtures.transcribedBook(in: world)
        try TranscriptStore.cleanUp(book, expecting: transcript, with: Self.rules, from: .builtIn)
        let name = copyURL(of: book).lastPathComponent

        XCTAssertEqual(name, "transcript.json.before-cleanup")
        XCTAssertTrue(TextMouthPaths.isTranscriptFile(name))
        XCTAssertFalse(FileImportService.isPackageContentName(name))

        try TranscriptStore.delete(for: book)

        XCTAssertFalse(FileManager.default.fileExists(atPath: copyURL(of: book).path))
    }

    // MARK: - Fixtures

    /// Rules that change two sentences of the scripted narration.
    static let rules = TranscriptCleanupFixtures.narrationRules

    /// A whole-word rule writing its replacement for its pattern.
    private let rule = TranscriptCleanupFixtures.rule

    /// Where `book`'s package keeps the transcript from before a cleanup.
    private func copyURL(of book: Book) -> URL {
        TextMouthPaths.transcriptBeforeCleanupPath(in: book.tmbDirectory)
    }
}
