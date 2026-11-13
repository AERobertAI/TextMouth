import XCTest
@testable import TextMouth

/// The reader's side of Search Library: when the Search Library window opens
/// a match, the book's reader moves its cursor there. The window leaves a
/// `LibrarySearchJumpRequest` and asks for the book's window; the reader
/// claims the request, once, as its load ends or, when open already, as the
/// request is made, searches its text for the match, and goes there through
/// the same move a Search in Book pick makes, so Go Back returns.
///
/// Books are fixture EPUBs and a transcribed audiobook of silent tracks
/// made in the integration world's folder; no test plays or speaks, nothing
/// reads the user's library, and each reader shares a private request store
/// and notification center with its test alone. Announcements are read
/// from the reader's `lastAnnouncement`.
@MainActor
final class LibrarySearchJumpTests: XCTestCase {

    // MARK: - Fixtures

    /// The chapters of the river book, in reading order. "lanyard" is in the
    /// second and the fourth; "winch", "bollard" and "quay" in one chapter
    /// each, the last in lowercase only.
    private static let chapterBodies = [
        "<p>The boiler held at forty pounds while the stoker banked the fire.</p>",
        "<p>The deckhand coiled the lanyard beside the winch. Nothing else moved on the quay.</p>",
        "<p>A long quiet stretch of river passed under the hull.</p>",
        "<p>At the last landing the mate tied the lanyard to the bollard.</p>",
    ]

    /// The words the first search a test makes returns: the match for
    /// `query` found in `reader`, the `occurrence`th in reading order, as
    /// Search Library would list it.
    private func match(
        _ query: String,
        options: TextSearchOptions = TextSearchOptions(),
        occurrence: Int = 0,
        in reader: ReaderViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> BookSearchResult {
        let corpus = try XCTUnwrap(reader.searchCorpus, "\(reader.book.title) has no text to search", file: file, line: line)
        guard case let .matches(results, _) = try BookSearchEngine.search(
            query: query, options: options, in: corpus, limit: 1_000, isCancelled: { false }
        ) else {
            XCTFail("the search for \(query) was not a search", file: file, line: line)
            throw XCTSkip("no search outcome")
        }
        return try XCTUnwrap(
            results[safe: occurrence],
            "\(query) has \(results.count) matches in \(reader.book.title); wanted number \(occurrence + 1)",
            file: file,
            line: line
        )
    }

    /// The river book as an EPUB, imported into `world`: four chapters
    /// (`chapterBodies`), each led to by the contents.
    private func makeRiverBook(_ title: String, in world: IntegrationWorld) throws -> Book {
        let epub = try makeSandboxDirectory("LibrarySearchJumpSources").appendingPathComponent("\(title).epub")
        let chapters = Self.chapterBodies.enumerated().map {
            IntegrationEPUBChapter(fileName: "ch0\($0.offset + 1).xhtml", body: $0.element)
        }
        try IntegrationEPUB.write(
            title: title,
            chapters: chapters,
            contents: chapters.indices.map { IntegrationTOCEntry(label: "Chapter \($0 + 1)", target: "ch0\($0 + 1).xhtml") },
            to: epub
        )
        return try world.importBook(from: epub)
    }

    /// A reader for `book` in `world` that claims what `requests` holds for
    /// its book, as a reader window's model does, and starts loading at
    /// once. Auto-play on navigate is off, so a move is never heard. It is
    /// closed when the test ends, before the world is taken apart.
    private func makeReader(
        for book: Book,
        in world: IntegrationWorld,
        requests: LibrarySearchJumpRequests
    ) -> ReaderViewModel {
        world.settings.autoPlayOnNavigate = false
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: world.library,
            settingsViewModel: world.settings,
            substitutionService: TextSubstitutionService(rules: []),
            autoplayRequests: world.autoplayRequests,
            readingListRequests: ReadingListOpenRequests(),
            notificationCenter: world.notifications,
            libraryJumpRequests: requests
        )
        addTeardownBlock { reader.close() }
        return reader
    }

    /// A loaded reader for `book` that has no request to claim.
    private func makeLoadedReader(for book: Book, in world: IntegrationWorld) -> ReaderViewModel {
        let reader = makeReader(for: book, in: world, requests: LibrarySearchJumpRequests())
        waitForReaderToLoad(reader)
        return reader
    }

    /// The words the reader says for a move to `result`.
    private func movedWords(to result: BookSearchResult) -> String {
        LibrarySearchWording.movedToMatch(location: result.locationTitle)
    }

    // MARK: - Claimed as the Load Ends

    /// A request made before the reader exists, as the Search Library window
    /// does before the book's window opens, is claimed as the load ends: the
    /// cursor is at the match, in a later chapter, the request is used up,
    /// and the move is said.
    func testARequestMadeBeforeTheReaderExistsIsClaimedAsTheLoadEnds() throws {
        let world = try makeIntegrationWorld("Library Jump Before")
        let book = try makeRiverBook("River Before", in: world)
        let probe = makeLoadedReader(for: book, in: world)
        let target = try match("bollard", in: probe)
        probe.close()
        XCTAssertGreaterThan(target.chapterIndex, 0, "the fixture's match is not in a later chapter")

        let requests = LibrarySearchJumpRequests()
        requests.request(bookID: book.id, match: target, query: "bollard", options: TextSearchOptions())
        let reader = makeReader(for: book, in: world, requests: requests)
        waitForReaderToLoad(reader)

        XCTAssertEqual(reader.currentChapterIndex, target.chapterIndex, "chapter of the cursor")
        XCTAssertEqual(reader.currentCharacterOffset, target.characterOffset, "offset of the cursor")
        XCTAssertFalse(requests.hasRequest(for: book.id), "the request was not used up")
        XCTAssertEqual(reader.lastAnnouncement, movedWords(to: target), "what VoiceOver was told")
        XCTAssertTrue(reader.hasSavedPosition, "the place before the move was not saved for Go Back")
    }

    /// Nothing is claimed while the book loads: a request is left waiting
    /// until the text is known, and a reader with no request moves nowhere.
    func testAReaderStillLoadingLeavesTheRequestWaiting() throws {
        let world = try makeIntegrationWorld("Library Jump Loading")
        let book = try makeRiverBook("River Loading", in: world)
        let probe = makeLoadedReader(for: book, in: world)
        let target = try match("bollard", in: probe)
        probe.close()

        let requests = LibrarySearchJumpRequests()
        let reader = makeReader(for: book, in: world, requests: requests)
        XCTAssertTrue(reader.isLoading, "the fixture book loaded before it could be tested")
        requests.request(bookID: book.id, match: target, query: "bollard", options: TextSearchOptions())

        XCTAssertTrue(requests.hasRequest(for: book.id), "a reader still loading claimed the request")
        XCTAssertEqual(reader.currentChapterIndex, 0, "chapter of the cursor while loading")

        waitForReaderToLoad(reader)
        XCTAssertEqual(reader.currentChapterIndex, target.chapterIndex, "chapter of the cursor once loaded")
        XCTAssertFalse(requests.hasRequest(for: book.id), "the request was not used up")
    }

    // MARK: - Claimed at Once

    /// A request made while the reader is open and loaded, as the window
    /// router brings its window forward, is claimed there and then.
    func testARequestMadeWhileTheReaderIsOpenIsClaimedAtOnce() throws {
        let world = try makeIntegrationWorld("Library Jump Open")
        let book = try makeRiverBook("River Open", in: world)
        let requests = LibrarySearchJumpRequests()
        let reader = makeReader(for: book, in: world, requests: requests)
        waitForReaderToLoad(reader)
        let target = try match("winch", in: reader)
        XCTAssertEqual(reader.currentChapterIndex, 0, "chapter of the cursor before the request")

        requests.request(bookID: book.id, match: target, query: "winch", options: TextSearchOptions())

        XCTAssertEqual(reader.currentChapterIndex, target.chapterIndex, "chapter of the cursor")
        XCTAssertEqual(reader.currentCharacterOffset, target.characterOffset, "offset of the cursor")
        XCTAssertFalse(requests.hasRequest(for: book.id), "the request was not used up")
        XCTAssertEqual(reader.lastAnnouncement, movedWords(to: target), "what VoiceOver was told")
    }

    /// The request is used once: asking again for the same place after Go
    /// Back moves again only because a new request was made.
    func testARequestIsUsedOnce() throws {
        let world = try makeIntegrationWorld("Library Jump Once")
        let book = try makeRiverBook("River Once", in: world)
        let requests = LibrarySearchJumpRequests()
        let reader = makeReader(for: book, in: world, requests: requests)
        waitForReaderToLoad(reader)
        let target = try match("winch", in: reader)
        requests.request(bookID: book.id, match: target, query: "winch", options: TextSearchOptions())
        reader.goBack()
        XCTAssertEqual(reader.currentChapterIndex, 0, "chapter after Go Back")

        // Claiming again finds nothing waiting, so the cursor stays.
        reader.claimLibrarySearchJump()

        XCTAssertEqual(reader.currentChapterIndex, 0, "chapter after a second claim with no request")
        XCTAssertFalse(reader.hasSavedPosition, "a second claim saved a place")
    }

    // MARK: - Go Back

    /// The move saves the place the reader was at, so Go Back returns to it,
    /// and says so.
    func testGoBackReturnsToThePlaceBeforeTheJump() throws {
        let world = try makeIntegrationWorld("Library Jump Go Back")
        let book = try makeRiverBook("River Go Back", in: world)
        let requests = LibrarySearchJumpRequests()
        let reader = makeReader(for: book, in: world, requests: requests)
        waitForReaderToLoad(reader)
        reader.navigateTo(chapterIndex: 0, characterOffset: 12)
        let beforeChapter = reader.currentChapterIndex
        let beforeOffset = reader.currentCharacterOffset
        let target = try match("bollard", in: reader)
        XCTAssertFalse(reader.hasSavedPosition, "a place was saved before the jump")

        requests.request(bookID: book.id, match: target, query: "bollard", options: TextSearchOptions())
        XCTAssertEqual(reader.currentChapterIndex, target.chapterIndex, "chapter after the jump")
        XCTAssertTrue(reader.hasSavedPosition, "the jump saved no place")

        reader.goBack()

        XCTAssertEqual(reader.currentChapterIndex, beforeChapter, "chapter after Go Back")
        XCTAssertEqual(reader.currentCharacterOffset, beforeOffset, "offset after Go Back")
        XCTAssertFalse(reader.hasSavedPosition, "Go Back kept the place")
        XCTAssertEqual(reader.lastAnnouncement, "Returned to previous position", "what VoiceOver was told")
    }

    // MARK: - A Match That Moved

    /// When the text no longer has the match where the search found it, the
    /// reader goes to the match nearest the old place, and says the text
    /// changed: here the request names a place in the second chapter that
    /// holds no "lanyard", from near the fourth chapter's, so the fourth's
    /// is the nearest.
    func testAMatchThatMovedIsFoundAgainNearTheOldPlace() throws {
        let world = try makeIntegrationWorld("Library Jump Moved")
        let book = try makeRiverBook("River Moved", in: world)
        let requests = LibrarySearchJumpRequests()
        let reader = makeReader(for: book, in: world, requests: requests)
        waitForReaderToLoad(reader)
        let earlier = try match("lanyard", occurrence: 0, in: reader)
        let later = try match("lanyard", occurrence: 1, in: reader)
        XCTAssertNotEqual(earlier.chapterIndex, later.chapterIndex, "the fixture's matches share a chapter")
        // The text changed since the search: the match was three characters
        // further on, in a place that now holds other words, near the
        // second match.
        let stale = LibrarySearchJumpRequest(
            bookID: book.id,
            createdAt: requests.currentDate,
            query: "lanyard",
            options: TextSearchOptions(),
            chapterIndex: earlier.chapterIndex,
            characterOffset: earlier.characterOffset + 3,
            globalOffset: later.globalOffset - 2,
            matchedText: "lanyard"
        )

        requests.add(stale)

        XCTAssertEqual(reader.currentChapterIndex, later.chapterIndex, "chapter of the nearest match")
        XCTAssertEqual(reader.currentCharacterOffset, later.characterOffset, "offset of the nearest match")
        XCTAssertEqual(reader.lastAnnouncement, LibrarySearchWording.movedToMatchFoundAgain, "what VoiceOver was told")
        XCTAssertTrue(reader.hasSavedPosition, "the move saved no place for Go Back")
    }

    /// The choice of the match: the one at the place when the text there is
    /// still the match, the nearest when not, the earlier of two as near,
    /// and none when the book holds no match.
    func testTheChoiceOfAMatch() {
        func result(chapter: Int, offset: Int, global: Int, text: String = "word") -> BookSearchResult {
            BookSearchResult(
                chapterIndex: chapter,
                characterOffset: offset,
                matchedText: text,
                contextSnippet: text,
                globalOffset: global
            )
        }
        func request(chapter: Int, offset: Int, global: Int, text: String = "word") -> LibrarySearchJumpRequest {
            LibrarySearchJumpRequest(
                bookID: UUID(),
                createdAt: Date(),
                query: "word",
                options: TextSearchOptions(),
                chapterIndex: chapter,
                characterOffset: offset,
                globalOffset: global,
                matchedText: text
            )
        }
        let matches = [
            result(chapter: 0, offset: 10, global: 10),
            result(chapter: 1, offset: 5, global: 105),
            result(chapter: 2, offset: 5, global: 205),
        ]

        // At its place: exact, not found again.
        let exact = LibrarySearchJumpPlace.choose(for: request(chapter: 1, offset: 5, global: 105), among: matches)
        XCTAssertEqual(exact?.match, matches[1], "match at its own place")
        XCTAssertEqual(exact?.isFoundAgain, false, "found again at its own place")

        // Nearest by the offset from the book's start.
        let nearest = LibrarySearchJumpPlace.choose(for: request(chapter: 1, offset: 6, global: 190), among: matches)
        XCTAssertEqual(nearest?.match, matches[2], "nearest match to offset 190")
        XCTAssertEqual(nearest?.isFoundAgain, true, "nearest match not told as found again")

        // The same place with other text there is a changed text too.
        let changed = LibrarySearchJumpPlace.choose(for: request(chapter: 1, offset: 5, global: 105, text: "WORD"), among: matches)
        XCTAssertEqual(changed?.isFoundAgain, true, "other text at the place was taken as the match")
        XCTAssertEqual(changed?.match, matches[1], "nearest match with other text at the place")

        // A tie goes to the earlier match.
        let tie = LibrarySearchJumpPlace.choose(for: request(chapter: 9, offset: 0, global: 155), among: matches)
        XCTAssertEqual(tie?.match, matches[1], "tie between offsets 105 and 205")

        XCTAssertNil(LibrarySearchJumpPlace.choose(for: request(chapter: 0, offset: 0, global: 0), among: []), "a match in no matches")
    }

    // MARK: - A Match That Is Gone

    /// A request for words the book no longer holds leaves the cursor
    /// where it is, saves no place, and says the match is gone.
    func testAMatchThatIsGoneLeavesTheCursorAndSaysSo() throws {
        let world = try makeIntegrationWorld("Library Jump Gone")
        let book = try makeRiverBook("River Gone", in: world)
        let requests = LibrarySearchJumpRequests()
        let reader = makeReader(for: book, in: world, requests: requests)
        waitForReaderToLoad(reader)
        reader.navigateTo(chapterIndex: 1, characterOffset: 4)
        let beforeChapter = reader.currentChapterIndex
        let beforeOffset = reader.currentCharacterOffset

        requests.add(LibrarySearchJumpRequest(
            bookID: book.id,
            createdAt: requests.currentDate,
            query: "zeppelin",
            options: TextSearchOptions(),
            chapterIndex: 2,
            characterOffset: 3,
            globalOffset: 150,
            matchedText: "zeppelin"
        ))

        XCTAssertEqual(reader.currentChapterIndex, beforeChapter, "chapter of the cursor")
        XCTAssertEqual(reader.currentCharacterOffset, beforeOffset, "offset of the cursor")
        XCTAssertFalse(reader.hasSavedPosition, "a place was saved for a move that did not happen")
        XCTAssertEqual(reader.lastAnnouncement, LibrarySearchWording.matchGone, "what VoiceOver was told")
        XCTAssertFalse(requests.hasRequest(for: book.id), "the request was not used up")
    }

    /// Match Case is honoured: the only "quay" is in lowercase, so a request
    /// for "QUAY" with Match Case finds it gone, where the same words
    /// without Match Case find it.
    func testMatchCaseIsHonoured() throws {
        let world = try makeIntegrationWorld("Library Jump Case")
        let book = try makeRiverBook("River Case", in: world)
        let requests = LibrarySearchJumpRequests()
        let reader = makeReader(for: book, in: world, requests: requests)
        waitForReaderToLoad(reader)
        let target = try match("QUAY", in: reader)
        XCTAssertEqual(target.matchedText, "quay", "the fixture's only quay is not in lowercase")
        let matchingCase = TextSearchOptions(matchCase: true, isRegularExpression: false)

        // With Match Case, "QUAY" is not in the text.
        requests.request(bookID: book.id, match: target, query: "QUAY", options: matchingCase)
        XCTAssertEqual(reader.currentChapterIndex, 0, "chapter of the cursor after a Match Case request")
        XCTAssertEqual(reader.lastAnnouncement, LibrarySearchWording.matchGone, "what VoiceOver was told with Match Case")

        // Without it, the same words are found where they were.
        requests.request(bookID: book.id, match: target, query: "QUAY", options: TextSearchOptions())
        XCTAssertEqual(reader.currentChapterIndex, target.chapterIndex, "chapter of the cursor without Match Case")
        XCTAssertEqual(reader.currentCharacterOffset, target.characterOffset, "offset of the cursor without Match Case")
        XCTAssertEqual(reader.lastAnnouncement, movedWords(to: target), "what VoiceOver was told without Match Case")
    }

    /// A regular expression request finds its match by the pattern, as the
    /// window's search did.
    func testARegularExpressionRequestIsFound() throws {
        let world = try makeIntegrationWorld("Library Jump Regex")
        let book = try makeRiverBook("River Regex", in: world)
        let requests = LibrarySearchJumpRequests()
        let reader = makeReader(for: book, in: world, requests: requests)
        waitForReaderToLoad(reader)
        let pattern = TextSearchOptions(matchCase: false, isRegularExpression: true)
        let target = try match("boll?ard", options: pattern, in: reader)

        requests.request(bookID: book.id, match: target, query: "boll?ard", options: pattern)

        XCTAssertEqual(reader.currentChapterIndex, target.chapterIndex, "chapter of the cursor")
        XCTAssertEqual(reader.currentCharacterOffset, target.characterOffset, "offset of the cursor")
        XCTAssertEqual(reader.lastAnnouncement, movedWords(to: target), "what VoiceOver was told")
    }

    // MARK: - Another Book's Request

    /// A reader claims only its own book's request: another book's waits for
    /// that book's reader, which finds it.
    func testAnotherBooksRequestIsNotClaimed() throws {
        let world = try makeIntegrationWorld("Library Jump Other")
        let book = try makeRiverBook("River Mine", in: world)
        let other = try makeRiverBook("River Other", in: world)
        let requests = LibrarySearchJumpRequests()
        let reader = makeReader(for: book, in: world, requests: requests)
        waitForReaderToLoad(reader)
        let probe = makeLoadedReader(for: other, in: world)
        let target = try match("bollard", in: probe)
        probe.close()

        requests.request(bookID: other.id, match: target, query: "bollard", options: TextSearchOptions())

        XCTAssertEqual(reader.currentChapterIndex, 0, "chapter of the other book's reader")
        XCTAssertNotEqual(reader.lastAnnouncement, movedWords(to: target), "the other book's reader announced the move")
        XCTAssertTrue(requests.hasRequest(for: other.id), "the other book's request was used")
        XCTAssertFalse(requests.hasRequest(for: book.id), "a request appeared for this book")

        reader.claimLibrarySearchJump()
        XCTAssertTrue(requests.hasRequest(for: other.id), "a claim by this reader took the other book's request")

        // Its own reader finds it.
        let otherReader = makeReader(for: other, in: world, requests: requests)
        waitForReaderToLoad(otherReader)
        XCTAssertEqual(otherReader.currentChapterIndex, target.chapterIndex, "chapter of the book's own reader")
        XCTAssertFalse(requests.hasRequest(for: other.id), "the book's own reader left the request")
    }

    // MARK: - Books Without Their Text

    /// An audiobook with no transcript has no text to find the match in:
    /// the reader says why, as Search in Book does, and stays where it is.
    func testAnAudiobookWithoutATranscriptSaysItHasNoText() throws {
        let world = try makeIntegrationWorld("Library Jump Untranscribed")
        let book = try world.makeSilentAudioBook(
            title: "Plain Tracks \(UUID().uuidString.prefix(8))",
            trackDurations: [3, 2]
        )
        let requests = LibrarySearchJumpRequests()
        let reader = makeReader(for: book, in: world, requests: requests)
        waitForReaderToLoad(reader)

        requests.add(LibrarySearchJumpRequest(
            bookID: book.id,
            createdAt: requests.currentDate,
            query: "ferry",
            options: TextSearchOptions(),
            chapterIndex: 1,
            characterOffset: 4,
            globalOffset: 40,
            matchedText: "ferry"
        ))

        XCTAssertEqual(reader.currentChapterIndex, 0, "chapter of the cursor")
        XCTAssertFalse(reader.hasSavedPosition, "a place was saved for a move that did not happen")
        XCTAssertEqual(
            reader.lastAnnouncement,
            BookSearchWording.noTranscript(bookTitle: book.title),
            "what VoiceOver was told"
        )
        XCTAssertFalse(requests.hasRequest(for: book.id), "the request was not used up")
    }

    /// A match in a transcribed audiobook's transcript moves the audio to
    /// the start of its sentence, and the reader speaks where it moved to
    /// at once, with the time, since no sheet closes to speak it.
    func testATranscriptMatchMovesTheAudioAndSpeaksTheTime() throws {
        let world = try makeIntegrationWorld("Library Jump Transcript")
        let book = try world.makeSilentAudioBook(
            title: "Breakwater Notes \(UUID().uuidString.prefix(8))",
            trackDurations: [3, 2]
        )
        try TranscriptStore.install(
            try TranscriptFixtures.transcript(of: book, sentences: TranscriptionUIScripts.twoTracks),
            for: book
        )
        let requests = LibrarySearchJumpRequests()
        let reader = makeReader(for: book, in: world, requests: requests)
        waitForReaderToLoad(reader)
        let transcript = try XCTUnwrap(reader.content?.transcript, "the transcript was not shown")
        let target = try match("ferry", in: reader)
        XCTAssertEqual(target.chapterIndex, 1, "the fixture's ferry is not in the second track")
        let timing = try XCTUnwrap(reader.searchCorpus?.timing, "a transcript's corpus has no timing")

        requests.request(bookID: book.id, match: target, query: "ferry", options: TextSearchOptions())

        XCTAssertEqual(reader.currentChapterIndex, 1, "chapter of the audio")
        XCTAssertEqual(
            reader.currentCharacterOffset,
            transcript.audioOffset(atTextOffset: target.characterOffset, inChapter: 1),
            "audio offset of the cursor"
        )
        XCTAssertTrue(reader.hasSavedPosition, "the move saved no place for Go Back")
        XCTAssertNil(reader.pendingJumpAnnouncement, "the words were left for a sheet that will not close")
        let said = try XCTUnwrap(reader.lastAnnouncement, "nothing was said")
        // The place is named as a Search in Book pick of a transcript names
        // it: by its chapter's title, unless that says nothing.
        let location = BookSearchView.locationTitles(
            of: [(chapterIndex: 1, characterOffset: target.characterOffset)],
            headings: [],
            chapterTitles: reader.content?.chapters.map(\.title) ?? [],
            bookTitle: book.title
        ).first ?? nil
        XCTAssertEqual(
            said,
            BookSearchWording.movedTo(
                time: timing.time(chapterIndex: 1, characterOffset: target.characterOffset),
                location: location
            ),
            "what VoiceOver was told"
        )
    }

    // MARK: - The Cost of Finding the Place

    /// The reader finds the place by searching its whole book on the main
    /// actor, once. A synthetic book of two megabytes, a match in about
    /// every thousand characters, takes well under a second to search for a
    /// request's place; the limit here is generous so a busy machine does
    /// not fail the test, and the measured time is in the failure message
    /// and the test's log.
    func testSearchingOneLargeBookForThePlaceIsFast() throws {
        // 20 chapters of about 105 KB each: a sentence of ~100 characters
        // repeated, with the word "lanyard" in every tenth.
        let sentence = "The deckhand coiled the rope beside the winch and counted the crates. "
        let withWord = "The deckhand coiled the lanyard beside the winch and counted the crates. "
        var chapter = ""
        for index in 0..<1_500 {
            chapter += index % 10 == 0 ? withWord : sentence
        }
        let chapters = Array(repeating: chapter, count: 20)
        let totalCharacters = chapters.reduce(0) { $0 + $1.utf16.count }
        XCTAssertGreaterThan(totalCharacters, 2_000_000, "the synthetic book is under 2 MB")
        let corpus = BookSearchCorpus(
            chapterTexts: chapters,
            chapterTitles: chapters.indices.map { "Chapter \($0 + 1)" },
            headings: [],
            bookTitle: "Synthetic"
        )

        let started = Date()
        let outcome = try BookSearchEngine.search(
            query: "lanyard",
            options: TextSearchOptions(),
            in: corpus,
            limit: ReaderViewModel.libraryJumpMatchLimit,
            isCancelled: { false }
        )
        let elapsed = Date().timeIntervalSince(started)

        guard case let .matches(results, isTruncated) = outcome else {
            return XCTFail("the search was not a search")
        }
        XCTAssertEqual(results.count, 20 * 150, "number of matches")
        XCTAssertFalse(isTruncated, "the search stopped at its limit")
        print("LibrarySearchJumpTests: searched \(totalCharacters) characters for \(results.count) matches in \(elapsed) seconds")
        XCTAssertLessThan(elapsed, 5, "searching \(totalCharacters) characters took \(elapsed) seconds")
    }
}
