import XCTest
import os
@testable import TextMouth

// MARK: - A Book Whose Text Was Written by an Older Extraction

/// A book whose saved places were made in the text an older extraction
/// wrote, with the text this build writes for it (T06's branch D). A rebuild
/// of the book's text should move each place from the older text to the new
/// one, onto the same words.
struct BookInAnOlderText {
    /// The book as its library row and package record hold it: with the
    /// places saved in the older text.
    let book: Book
    /// The reading text this build's extraction makes for the book.
    let newText: DocumentContent
    /// The content.md bytes that extraction writes.
    let newBytes: Data
    /// Where the reading position belongs in `newText`: at "Sacks of barley".
    let position: TextPlace
    /// Where the bookmark belongs in `newText`: at "counted twice".
    let bookmark: TextPlace
    /// The "Notes" heading of `newText`, which the book skips.
    let notes: Heading
}

extension CloudMaintenanceTestCase {
    /// The sentence an older extraction put into the book's text, ahead of
    /// every place the fixture saves.
    private static let olderSentence = "An older reading kept this sentence about the weir and its eels.\n\n"

    /// A packaged book (titled `title`) whose content.md is the text an
    /// older extraction wrote, and whose position, bookmark, and skipped
    /// heading were saved in that text with their words. This build's
    /// extraction of the same source lacks the older sentence, so every place
    /// is past text that is no longer there.
    ///
    /// The book's record keeps no fingerprints, and the fixture commits no
    /// cache: a content.md whose record keeps fingerprints and holds other
    /// bytes is taken by the batch as an edit saved while TextMouth was
    /// closed (FR05) and never rebuilt, while an older build's cache, written
    /// before fingerprints, is rebuilt.
    func makeBookInAnOlderText(title: String) throws -> BookInAnOlderText {
        let source = "# The Millrace\n\nWater came down the leat at dawn and turned the wheel before anyone woke.\n\n"
            + "# The Granary\n\nSacks of barley stood against the north wall, counted twice each evening.\n\n"
            + "## Notes\n\nThe miller kept a ledger of every sack that left by cart.\n"
        let book = try makePackagedBook(title: title, text: source)
        // The older extraction's text: one more sentence, ahead of every
        // place below.
        return try makeFixture(of: book) { newMarkdown in
            newMarkdown.replacingOccurrences(of: Self.positionPhrase, with: Self.olderSentence + Self.positionPhrase)
        }
    }

    /// `makeBookInAnOlderText`'s book as it is when its text changed without
    /// a rebuild since its places were saved, as when another Mac or an
    /// editor changed it: its content.md holds the text this build writes
    /// (`newBytes`), its record describes that content.md as current (this
    /// cache version, with fingerprints and index), and its places are still
    /// at the older text's numbers, with their saved words. No load and no
    /// batch rebuilds it, and the reader's check at load finds its places.
    func makeBookWhoseTextChangedSinceItsPlaces(title: String) throws -> BookInAnOlderText {
        try recordingTheCurrentText(of: try makeBookInAnOlderText(title: title))
    }

    /// A book of about a million UTF-16 units of distinct sentences in
    /// twenty chapters, packaged as `makeBookInAnOlderText`'s is. The last
    /// chapter holds, after its sentences, a paragraph and then the
    /// fixture's phrases and its Notes heading. The position, bookmark, and
    /// skip were saved with their words in the text without the paragraph,
    /// and the record describes the text with it (as
    /// `makeBookWhoseTextChangedSinceItsPlaces` does).
    func makeLargeBookWhoseTextChangedSinceItsPlaces(title: String) throws -> BookInAnOlderText {
        let chapterCount = 20
        let sentencesPerChapter = 1000
        // Distinct sentences of letters only, so no two of them share words.
        var chapters: [String] = []
        for chapter in 0..<chapterCount {
            var body = "# Chapter \(Self.letters(chapter))\n\n"
            for sentence in 0..<sentencesPerChapter {
                let key = chapter * sentencesPerChapter + sentence
                body += "The barge \(Self.letters(key)) carried \(Self.letters(key * 7 + 3)) crates to the \(Self.letters(key * 13 + 5)) mill.\n\n"
            }
            chapters.append(body)
        }
        // The last chapter goes on with the new paragraph, the phrases, and Notes.
        chapters[chapterCount - 1] += Self.largeBookParagraph + "\n\n"
            + "Sacks of barley stood against the north wall, counted twice each evening.\n\n"
            + "## Notes\n\nThe miller kept a ledger of every sack that left by cart.\n"
        let book = try makePackagedBook(title: title, text: chapters.joined())
        // The text the places were saved in lacks the paragraph.
        let fixture = try makeFixture(of: book) { newMarkdown in
            newMarkdown.replacingOccurrences(of: Self.largeBookParagraph + "\n\n", with: "")
        }
        // The text is as large as the test claims.
        XCTAssertGreaterThan(fixture.newText.chapters.reduce(0) { $0 + $1.text.utf16.count }, 900_000)
        return try recordingTheCurrentText(of: fixture)
    }

    /// The phrase the fixture's reading position is saved at.
    private static let positionPhrase = "Sacks of barley"

    /// The phrase the fixture's bookmark is saved at.
    private static let bookmarkPhrase = "counted twice"

    /// The paragraph that the large book's text holds and its places were
    /// saved without, ahead of all of them.
    private static let largeBookParagraph = "A paragraph was put in ahead of the sacks, about the dam and its keepers."

    /// A word of lowercase letters that is different for every `number`.
    private static func letters(_ number: Int) -> String {
        var rest = number
        var word = ""
        repeat {
            word.append(Character(UnicodeScalar(UInt8(97 + rest % 26))))
            rest /= 26
        } while rest > 0
        return word
    }

    /// Makes the fixture of `book`, a packaged book whose source this build
    /// extracts to the text the fixture calls new: writes that text, makes
    /// the older text from its Markdown by `makeOlder`, saves the position,
    /// bookmark, and skipped heading in the older text with their words, and
    /// leaves the older text as content.md, with a record that is outdated
    /// and keeps no fingerprints.
    private func makeFixture(of book: Book, makeOlder: (String) -> String) throws -> BookInAnOlderText {
        var book = book

        // This build's extraction, written as content.md. The book holds no
        // place yet, so nothing is copied aside.
        let written = try XCTUnwrap(MarkdownCacheService.generateCacheContent(for: book))
        XCTAssertNil(written.movedPlaces)
        let cacheURL = MarkdownCacheService.cacheURL(for: book)
        let newBytes = try Data(contentsOf: cacheURL)
        let newText = try MarkdownCacheService.loadFromCache(for: book)

        // The same text as an older extraction wrote it.
        let newMarkdown = try XCTUnwrap(String(data: newBytes, encoding: .utf8))
        XCTAssertEqual(newMarkdown.components(separatedBy: Self.positionPhrase).count, 2, "the marker should stand once")
        let olderMarkdown = makeOlder(newMarkdown)
        XCTAssertNotEqual(olderMarkdown, newMarkdown, "the older text should differ")
        try Data(olderMarkdown.utf8).write(to: cacheURL, options: .atomic)
        let olderText = try MarkdownCacheService.loadFromCache(for: book)

        // The places, saved in the older text with their words.
        let olderChapters = olderText.chapters.map(\.text)
        let measure = TextAnchor.measure(ofTextCachedBy: "3.0.3")
        let olderPosition = try Self.place(of: Self.positionPhrase, in: olderChapters)
        let olderBookmark = try Self.place(of: Self.bookmarkPhrase, in: olderChapters)
        book.readingPosition = ReadingPosition(
            chapterIndex: olderPosition.chapter,
            characterOffset: olderPosition.offset,
            globalCharacterOffset: olderText.globalOffset(chapterIndex: olderPosition.chapter, localOffset: olderPosition.offset),
            anchor: olderText.anchor(at: olderPosition, measuredIn: measure)
        )
        book.bookmarks = [Bookmark(
            number: 1,
            chapterIndex: olderBookmark.chapter,
            characterOffset: olderBookmark.offset,
            label: "Counted",
            anchor: olderText.anchor(at: olderBookmark, measuredIn: measure)
        )]
        let olderNotes = try Self.notes(of: olderText)
        let notesStart = TextPlace(chapter: olderNotes.chapterIndex, offset: olderNotes.characterOffset)
        book.setSkippedHeadings([SkippedHeading(olderNotes, anchor: olderText.anchor(at: notesStart, measuredIn: measure))])

        // The record is written to match, still the older cache version
        // and without fingerprints.
        book.cacheFormatVersion = "3.0.3"
        book.textCacheFingerprint = nil
        try book.saveBookInfoThrowing()
        let record = try BookInfo.load(from: book.tmbDirectory)
        XCTAssertNil(record.state.textCacheFingerprint, "the fixture's record should keep no fingerprints")
        XCTAssertEqual(record.state.cacheFormatVersion, "3.0.3")

        // The book as the record holds it, which a library row loaded from
        // disk equals: the record keeps dates to the second, so the places
        // compare equal to the record's only after that rounding.
        let recorded = Book(
            record: record,
            filePath: book.filePath,
            folderPath: book.folderPath,
            tmbDirectoryName: book.tmbDirectoryName
        )

        return BookInAnOlderText(
            book: recorded,
            newText: newText,
            newBytes: newBytes,
            position: try Self.place(of: Self.positionPhrase, in: newText.chapters.map(\.text)),
            bookmark: try Self.place(of: Self.bookmarkPhrase, in: newText.chapters.map(\.text)),
            notes: try Self.notes(of: newText)
        )
    }

    /// `fixture` with its content.md replaced by the text this build writes
    /// (`newBytes`) and its record describing that content.md as current:
    /// this build's cache version, the fingerprints of the source and the
    /// content.md, and the text's index. The places stay as the fixture
    /// saved them. Asserts that no rebuild will happen: the cache is not
    /// outdated, and a load of the book reads content.md as it is, moving
    /// nothing.
    private func recordingTheCurrentText(of fixture: BookInAnOlderText) throws -> BookInAnOlderText {
        // The analysis is made from a copy without places, so writing the
        // text copies nothing aside (the book's record keeps its places).
        var bare = fixture.book
        bare.readingPosition = nil
        bare.bookmarks = []
        bare.setSkippedHeadings([])
        let index = try XCTUnwrap(MarkdownCacheService.generateCacheAnalyzeAndStamp(for: &bare))
        let cacheURL = MarkdownCacheService.cacheURL(for: bare)
        XCTAssertEqual(try Data(contentsOf: cacheURL), fixture.newBytes, "the text should be what this build writes")
        _ = try XCTUnwrap(LibraryPersistenceService.saveContentAnalysis(
            for: bare,
            index: index,
            cacheFormatVersion: bare.cacheFormatVersion
        ))
        let recorded = try recordedBook(like: fixture.book)
        XCTAssertEqual(recorded.cacheFormatVersion, MarkdownCacheService.currentCacheVersion)

        // No rebuild: the cache is current, and a load reads it as it is.
        XCTAssertFalse(MarkdownCacheService.isCacheOutdated(stored: recorded.cacheFormatVersion))
        let loaded = try BookContentAnalysisService.load(book: recorded, regenerateTextCache: false)
        XCTAssertNil(loaded.movedPlaces, "a load should not rebuild the text")
        XCTAssertEqual(try Data(contentsOf: cacheURL), fixture.newBytes, "a load should leave content.md as it is")

        return BookInAnOlderText(
            book: recorded,
            newText: fixture.newText,
            newBytes: fixture.newBytes,
            position: fixture.position,
            bookmark: fixture.bookmark,
            notes: fixture.notes
        )
    }

    /// Where `phrase` begins in the chapter of `chapters` that holds it,
    /// found without a fixed chapter index or a subscript that could trap.
    private static func place(of phrase: String, in chapters: [String]) throws -> TextPlace {
        let chapter = try XCTUnwrap(chapters.firstIndex { $0.contains(phrase) }, "no chapter holds \"\(phrase)\"")
        return try Phrase.place(of: phrase, inChapter: chapter, of: chapters)
    }

    /// The "Notes" heading of `text`.
    private static func notes(of text: DocumentContent) throws -> Heading {
        try XCTUnwrap(text.allHeadings.first { $0.text == "Notes" }, "no Notes heading")
    }

    /// Asserts that `book` holds the places of `fixture` as they belong in
    /// its new text: the position and the bookmark at their chapter and
    /// offset there, and the Notes heading skipped.
    func assertPlaces(
        of book: Book,
        areThoseOf fixture: BookInAnOlderText,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(book.readingPosition?.chapterIndex, fixture.position.chapter, "position's chapter", file: file, line: line)
        XCTAssertEqual(book.readingPosition?.characterOffset, fixture.position.offset, "position's offset", file: file, line: line)
        XCTAssertEqual(book.bookmarks.count, 1, "bookmarks", file: file, line: line)
        XCTAssertEqual(book.bookmarks.first?.chapterIndex, fixture.bookmark.chapter, "bookmark's chapter", file: file, line: line)
        XCTAssertEqual(book.bookmarks.first?.characterOffset, fixture.bookmark.offset, "bookmark's offset", file: file, line: line)
        XCTAssertEqual(book.skippedHeadingIDs, [fixture.notes.id], "skipped headings", file: file, line: line)
    }

    /// The book as its package record holds it, read from disk after every
    /// queued library write has landed.
    func recordedBook(like book: Book) throws -> Book {
        LibraryPersistenceService.flushPendingSave()
        let record = try BookInfo.load(from: book.tmbDirectory)
        return Book(
            record: record,
            filePath: book.filePath,
            folderPath: book.folderPath,
            tmbDirectoryName: book.tmbDirectoryName
        )
    }

    /// Runs the launch's cache batch over `model` until its completion.
    @MainActor
    func runCacheBatch(on model: LibraryViewModel, access: MaintenanceFileAccess = .live) async {
        let finished = expectation(description: "The cache batch finished")
        model.extractMissingContentCaches(access: access) { finished.fulfill() }
        await fulfillment(of: [finished], timeout: 20)
    }

    /// Opens a reader on `book` in `model`, with a render queue that renders
    /// nothing and no notifications or requests shared with other tests, and
    /// closes it when the test ends.
    @MainActor
    func openReader(on book: Book, in model: LibraryViewModel) -> ReaderViewModel {
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: model,
            settingsViewModel: SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false),
            substitutionService: TextSubstitutionService(rules: []),
            autoplayRequests: ReaderAutoplayRequests(),
            notificationCenter: NotificationCenter(),
            renderScheduler: SilentRenderQueue()
        )
        addTeardownBlock { @MainActor in reader.close() }
        return reader
    }

    /// Whether the snapshots folder holds a copy of the book `book`: a
    /// folder whose name begins with "<book ID> ". Read from the folder
    /// itself, not through `PlaceSnapshot.leftovers()`, which neither lists
    /// nor removes the copies this run still uses, and so would miss exactly
    /// the copies a rebuild between its copy and its commit leaves.
    func snapshotsHoldACopy(of book: Book) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: MachineLocalPaths.placeSnapshots.path)) ?? []
        return names.contains { $0.hasPrefix("\(book.id.uuidString) ") }
    }
}

// MARK: - Shared Test Helpers

extension XCTestCase {
    /// Holds `book`'s text in an Edit Text session, as the user's editor
    /// holds it, until the test ends.
    func holdInAnEditSession(_ book: Book) {
        let baseline = BookTextBaseline(
            source: nil,
            cache: FileFingerprint(stamp: FileStamp(byteCount: 0, modificationTimeNanoseconds: 0), digest: "")
        )
        BookTextEditSessions.shared.begin(book.id, BookTextEditSessions.Session(baseline: baseline, report: { _, _ in }))
        addTeardownBlock { BookTextEditSessions.shared.end(book.id) }
    }

    /// Holds the first cache generation of `book` on the thread doing it,
    /// once it has chosen where its content.md goes and before it commits
    /// anything: `reached` is fulfilled there, and the generation goes on
    /// once `gate` is signaled. The hold ends with the test at the latest.
    func holdCacheGeneration(of book: Book) -> (reached: XCTestExpectation, gate: DispatchSemaphore) {
        let reached = expectation(description: "The batch is at work on the book")
        let gate = DispatchSemaphore(value: 0)
        let isClaimed = OSAllocatedUnfairLock(initialState: false)
        let bookID = book.id
        MarkdownCacheService.extractionObserver = { generated in
            guard generated.id == bookID else { return }
            // Only the first generation is held, so `reached` is fulfilled once.
            let isFirst = isClaimed.withLock { claimed in
                defer { claimed = true }
                return !claimed
            }
            guard isFirst else { return }
            reached.fulfill()
            gate.wait()
        }
        addTeardownBlock {
            MarkdownCacheService.extractionObserver = nil
            gate.signal()
        }
        return (reached, gate)
    }
}
