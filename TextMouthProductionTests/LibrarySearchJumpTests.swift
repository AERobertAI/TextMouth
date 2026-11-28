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
            libraryJumpRequests: requests,
            notificationCenter: world.notifications
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

    /// Whether `reader` says `words` within a few seconds, the main run loop
    /// spinning meanwhile: a reader says what a Search Library request did
    /// once its window is in front, a moment after the move
    /// (`VoiceOverAnnouncer.afterSheetDelay`), not at once.
    private func hears(_ words: String, from reader: ReaderViewModel) -> Bool {
        waitUntil(timeout: 5) { reader.lastAnnouncement == words }
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
        XCTAssertTrue(hears(movedWords(to: target), from: reader), "what VoiceOver was told: \(reader.lastAnnouncement ?? "nothing")")
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
        XCTAssertTrue(hears(movedWords(to: target), from: reader), "what VoiceOver was told: \(reader.lastAnnouncement ?? "nothing")")
    }

    /// The move to a match is said once the reader's window is in front, a
    /// moment after the request, and not at once: the Search Library window
    /// asks for the move just before it brings the reader's window forward,
    /// and words said at once were cut off by the window change (the review
    /// of November 13; REV11 F6's wait after a sheet closes). The words
    /// come no sooner than that moment.
    func testTheMoveIsSaidOnceTheReadersWindowIsInFront() throws {
        let world = try makeIntegrationWorld("Library Jump Said Later")
        let book = try makeRiverBook("River Said Later", in: world)
        let requests = LibrarySearchJumpRequests()
        let reader = makeReader(for: book, in: world, requests: requests)
        waitForReaderToLoad(reader)
        let target = try match("winch", in: reader)
        let saidBefore = reader.lastAnnouncement

        let requested = Date()
        requests.request(bookID: book.id, match: target, query: "winch", options: TextSearchOptions())

        XCTAssertEqual(reader.currentChapterIndex, target.chapterIndex, "the move itself is made at once")
        XCTAssertEqual(reader.lastAnnouncement, saidBefore, "the move was said at once, as the window changed")
        XCTAssertTrue(hears(movedWords(to: target), from: reader), "the move was never said: \(reader.lastAnnouncement ?? "nothing")")
        let delay = Date().timeIntervalSince(requested)
        XCTAssertGreaterThanOrEqual(
            delay, VoiceOverAnnouncer.afterSheetDelay - 0.05,
            "the move was said \(delay) seconds after the request, before the window could come forward"
        )
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

        // The move's words, due once the window was in front, are not said
        // over Go Back's after Go Back undid the move.
        XCTAssertFalse(
            waitUntil(timeout: VoiceOverAnnouncer.afterSheetDelay + 0.5) { reader.lastAnnouncement != "Returned to previous position" },
            "after Go Back, VoiceOver was told \(reader.lastAnnouncement ?? "nothing")"
        )
    }

    // MARK: - A Match That Moved

    /// When the text no longer has the match where the search found it, the
    /// reader searches the book and goes to the match nearest the old
    /// place, and says the text changed: here the request names a place in the second chapter that
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

        // The whole book is searched off the main actor for the new place,
        // so the move comes a moment after the request: not at once.
        XCTAssertEqual(reader.currentChapterIndex, 0, "the cursor moved before the search for the new place ended")
        XCTAssertTrue(
            waitUntil(timeout: 10) { reader.lastAnnouncement == LibrarySearchWording.movedToMatchFoundAgain },
            "the reader never said it moved to the nearest match: \(reader.lastAnnouncement ?? "nothing")"
        )
        XCTAssertEqual(reader.currentChapterIndex, later.chapterIndex, "chapter of the nearest match")
        XCTAssertEqual(reader.currentCharacterOffset, later.characterOffset, "offset of the nearest match")
        XCTAssertTrue(reader.hasSavedPosition, "the move saved no place for Go Back")
    }

    /// A later request supersedes the search for an earlier one: a request
    /// whose place still holds its match, made while the search for another
    /// request's new place runs, is the one the reader ends at.
    func testALaterRequestSupersedesAnEarlierSearch() throws {
        let world = try makeIntegrationWorld("Library Jump Superseded")
        let book = try makeRiverBook("River Superseded", in: world)
        let requests = LibrarySearchJumpRequests()
        let reader = makeReader(for: book, in: world, requests: requests)
        waitForReaderToLoad(reader)
        let winch = try match("winch", in: reader)
        let bollard = try match("bollard", in: reader)
        XCTAssertNotEqual(winch.chapterIndex, bollard.chapterIndex, "the fixture's matches share a chapter")
        // A request for a place that holds nothing, which needs a search...
        requests.add(LibrarySearchJumpRequest(
            bookID: book.id,
            createdAt: requests.currentDate,
            query: "winch",
            options: TextSearchOptions(),
            chapterIndex: 0,
            characterOffset: 2,
            globalOffset: 0,
            matchedText: "winch"
        ))
        let earlierSearch = try XCTUnwrap(reader.libraryJumpSearch, "no search began for the place that holds nothing")
        // ...then one whose place holds its match, moved to at once.
        requests.request(bookID: book.id, match: bollard, query: "bollard", options: TextSearchOptions())
        XCTAssertEqual(reader.currentChapterIndex, bollard.chapterIndex, "chapter after the later request")
        XCTAssertTrue(earlierSearch.isCancelled, "the later request left the earlier search running")
        XCTAssertNil(reader.libraryJumpSearch, "the reader kept a search for a request it no longer serves")

        // Give the earlier search time to end: it must not move the cursor.
        _ = waitUntil(timeout: 1) { reader.currentChapterIndex != bollard.chapterIndex }

        XCTAssertEqual(reader.currentChapterIndex, bollard.chapterIndex, "chapter after the earlier search ended")
        XCTAssertEqual(reader.currentCharacterOffset, bollard.characterOffset, "offset after the earlier search ended")
    }

    /// Closing the reader stops its search for a moved match, which ran to
    /// its end in Swift's pool after the reader had gone until November 13
    /// (the review's finding 8).
    func testClosingTheReaderStopsTheSearchForAMovedMatch() throws {
        let world = try makeIntegrationWorld("Library Jump Closed")
        let book = try makeRiverBook("River Closed", in: world)
        let requests = LibrarySearchJumpRequests()
        let reader = makeReader(for: book, in: world, requests: requests)
        waitForReaderToLoad(reader)
        // A place that holds no "winch", so the reader searches the book.
        requests.add(LibrarySearchJumpRequest(
            bookID: book.id,
            createdAt: requests.currentDate,
            query: "winch",
            options: TextSearchOptions(),
            chapterIndex: 0,
            characterOffset: 2,
            globalOffset: 0,
            matchedText: "winch"
        ))
        let search = try XCTUnwrap(reader.libraryJumpSearch, "no search began for the place that holds nothing")

        reader.close()

        XCTAssertTrue(search.isCancelled, "closing the reader left its search running")
        XCTAssertNil(reader.libraryJumpSearch, "a closed reader kept its search")
    }

    /// The search of the whole book for a moved match stops when its task is
    /// cancelled, and gives nothing: over a book of about 8 MB, which takes
    /// far longer to search than the cancel takes to come, a cancelled search
    /// ends with no outcome, where it ran to the end until November 13.
    func testTheWholeBookSearchForAMovedMatchStopsWhenCancelled() async throws {
        // 40 chapters of about 205 KB, "lanyard" in one sentence of ten.
        let plain = "The deckhand coiled the rope beside the winch and counted the crates. "
        let withWord = "The deckhand coiled the lanyard beside the winch and counted the crates. "
        let chapter = String(repeating: String(repeating: plain, count: 9) + withWord, count: 280)
        let chapters = Array(repeating: chapter, count: 40)
        let corpus = BookSearchCorpus(
            chapterTexts: chapters,
            chapterTitles: chapters.indices.map { "Chapter \($0 + 1)" },
            headings: [],
            bookTitle: "Synthetic"
        )
        let moved = request(chapter: 0, offset: 1, query: "lanyard", text: "lanyard")

        let search = ReaderViewModel.searchWholeBook(for: moved, in: corpus, limit: ReaderViewModel.libraryJumpMatchLimit)
        search.cancel()
        let outcome = await search.value

        XCTAssertNil(outcome, "a cancelled search gave an outcome: \(String(describing: outcome).prefix(200))")

        // Uncancelled, the same search finds every match, so the nil above
        // is the cancel's doing.
        let whole = await ReaderViewModel.searchWholeBook(for: moved, in: corpus, limit: ReaderViewModel.libraryJumpMatchLimit).value
        guard case let .matches(matches, isTruncated)? = whole else {
            return XCTFail("the uncancelled search gave \(String(describing: whole).prefix(200))")
        }
        XCTAssertEqual(matches.count, 280 * 40, "matches in the book")
        XCTAssertFalse(isTruncated, "the search stopped at its limit")
    }

    /// The choice of the nearest match: the nearest by offset from the
    /// book's start, the earlier of two as near, and none when the book
    /// holds no match; the match found again says so.
    func testTheNearestMatchIsChosen() {
        func result(chapter: Int, offset: Int, global: Int) -> BookSearchResult {
            BookSearchResult(
                chapterIndex: chapter,
                characterOffset: offset,
                matchedText: "word",
                contextSnippet: "word",
                globalOffset: global,
                locationTitle: "Chapter \(chapter + 1)"
            )
        }
        let matches = [
            result(chapter: 0, offset: 10, global: 10),
            result(chapter: 1, offset: 5, global: 105),
            result(chapter: 2, offset: 5, global: 205),
        ]

        let nearest = LibrarySearchJumpPlace.nearest(to: request(chapter: 1, offset: 6, global: 190), among: matches)
        XCTAssertEqual(nearest?.chapterIndex, 2, "chapter of the nearest match to offset 190")
        XCTAssertEqual(nearest?.characterOffset, 5, "offset of the nearest match to offset 190")
        XCTAssertEqual(nearest?.locationTitle, "Chapter 3", "title of the nearest match to offset 190")
        XCTAssertEqual(nearest?.isFoundAgain, true, "nearest match not told as found again")

        // A tie goes to the earlier match.
        let tie = LibrarySearchJumpPlace.nearest(to: request(chapter: 9, offset: 0, global: 155), among: matches)
        XCTAssertEqual(tie?.chapterIndex, 1, "chapter of the match for a tie between offsets 105 and 205")

        XCTAssertNil(LibrarySearchJumpPlace.nearest(to: request(chapter: 0, offset: 0, global: 0), among: []), "a match among no matches")
    }

    /// A request for the tests that need only its place and text.
    private func request(
        chapter: Int,
        offset: Int,
        global: Int = 0,
        query: String = "word",
        text: String = "word",
        options: TextSearchOptions = TextSearchOptions()
    ) -> LibrarySearchJumpRequest {
        LibrarySearchJumpRequest(
            bookID: UUID(),
            createdAt: Date(),
            query: query,
            options: options,
            chapterIndex: chapter,
            characterOffset: offset,
            globalOffset: global,
            matchedText: text
        )
    }

    /// The place check: the match is still at its place when the chapter's
    /// text there is the text that matched, and not when the text moved, was
    /// edited, differs in case under Match Case, or the chapter or offset is
    /// outside the text. A regular expression is checked by one attempt at
    /// the place, which sees the chapter's text around it.
    func testThePlaceCheck() {
        let chapters = ["The word is here. A second word.", "Nothing at all.", "Wörd wörd 🙂 word"]
        func holds(_ request: LibrarySearchJumpRequest, _ texts: [String]? = nil) -> Bool {
            LibrarySearchJumpPlace.holds(for: request, in: texts ?? chapters)
        }

        XCTAssertTrue(holds(request(chapter: 0, offset: 4)), "match at its place")
        XCTAssertTrue(holds(request(chapter: 0, offset: 27)), "second match at its place")
        XCTAssertFalse(holds(request(chapter: 0, offset: 5)), "match one character on")
        XCTAssertFalse(holds(request(chapter: 0, offset: 3)), "match one character back")
        XCTAssertFalse(holds(request(chapter: 1, offset: 4)), "match in a chapter without it")
        XCTAssertFalse(holds(request(chapter: 0, offset: 4, text: "WORD")), "other text than matched")

        // Offsets are UTF-16 units: the emoji counts two.
        XCTAssertTrue(holds(request(chapter: 2, offset: 13)), "match after an emoji")

        // Match Case: "Word" is not "word".
        let matchCase = TextSearchOptions(matchCase: true, isRegularExpression: false)
        XCTAssertFalse(
            holds(request(chapter: 0, offset: 4, query: "Word", text: "Word", options: matchCase)),
            "Word under Match Case at a lowercase word"
        )
        XCTAssertTrue(holds(request(chapter: 0, offset: 4, query: "WORD", text: "word")), "WORD ignoring case")

        // Out of range, and an empty query or an empty match, are all "no".
        XCTAssertFalse(holds(request(chapter: 3, offset: 0)), "chapter past the end")
        XCTAssertFalse(holds(request(chapter: -1, offset: 0)), "negative chapter")
        XCTAssertFalse(holds(request(chapter: 0, offset: -4)), "negative offset")
        XCTAssertFalse(holds(request(chapter: 0, offset: 500)), "offset past the chapter")
        XCTAssertFalse(holds(request(chapter: 0, offset: 30)), "match running past the chapter's end")
        XCTAssertFalse(holds(request(chapter: 0, offset: 4, query: "", text: "word")), "empty query")
        XCTAssertFalse(holds(request(chapter: 0, offset: 4, text: "")), "empty matched text")
        XCTAssertFalse(holds(request(chapter: 0, offset: 4), []), "no chapters")

        // A regular expression sees the chapter's text around the place.
        let pattern = TextSearchOptions(matchCase: false, isRegularExpression: true)
        XCTAssertTrue(
            holds(request(chapter: 0, offset: 0, query: "^The", text: "The", options: pattern)),
            "anchored pattern at the chapter's start"
        )
        XCTAssertFalse(
            holds(request(chapter: 0, offset: 27, query: "^word", text: "word", options: pattern)),
            "anchored pattern at a place it does not match"
        )
        XCTAssertFalse(
            holds(request(chapter: 0, offset: 4, query: "wo(rd", text: "word", options: pattern)),
            "invalid pattern"
        )
        XCTAssertTrue(
            holds(request(chapter: 0, offset: 4, query: "(?<=The )word", text: "word", options: pattern)),
            "look-behind pattern"
        )
    }

    /// A regular expression's place is checked by one attempt anchored
    /// there, never by running the expression over the chapter from its
    /// start, which on the main actor cost about 0.4 seconds for a match 20
    /// MB into a chapter (the review of November 13, finding 1). So a match
    /// at the place is seen even behind an earlier match that overlaps it,
    /// which a run from the start would have taken instead ("aba" at 2 in
    /// "ababa"); look-behind and word boundaries read the text before the
    /// place; and `^` and `$` match only at the chapter's own start and end,
    /// never at the place itself.
    func testARegularExpressionIsCheckedByOneAttemptAtItsPlace() {
        let pattern = TextSearchOptions(matchCase: false, isRegularExpression: true)
        // "line" at 6 and at 18; "second" at 11, just after a line feed.
        let chapters = ["ababa", "first line\nsecond line"]
        func holds(_ query: String, chapter: Int = 0, at offset: Int, text: String) -> Bool {
            LibrarySearchJumpPlace.holds(
                for: request(chapter: chapter, offset: offset, query: query, text: text, options: pattern),
                in: chapters
            )
        }

        XCTAssertTrue(holds("aba", at: 2, text: "aba"), "a match at the place, behind an earlier match overlapping it")
        XCTAssertTrue(holds("(?<=b)aba", at: 2, text: "aba"), "look-behind that the text before the place passes")
        XCTAssertFalse(holds("(?<=a)aba", at: 2, text: "aba"), "look-behind that the text before the place fails")
        XCTAssertFalse(holds("\\baba", at: 2, text: "aba"), "a word boundary inside a word")
        XCTAssertFalse(holds("^aba", at: 2, text: "aba"), "^ at the place, which is not the chapter's start")
        XCTAssertTrue(holds("aba$", at: 2, text: "aba"), "$ at the chapter's end")
        XCTAssertFalse(holds("ab", at: 1, text: "ab"), "a place where no match begins")
        XCTAssertFalse(holds("ab.*", at: 2, text: "ab"), "a match at the place longer than the text that matched")
        XCTAssertTrue(holds("^first", chapter: 1, at: 0, text: "first"), "^ at the chapter's start")
        XCTAssertFalse(holds("^second", chapter: 1, at: 11, text: "second"), "^ after a line feed, without multiline anchors")
        XCTAssertFalse(holds("line$", chapter: 1, at: 6, text: "line"), "$ before a line feed in the middle of the chapter")
        XCTAssertTrue(holds("line$", chapter: 1, at: 18, text: "line"), "$ at the chapter's end, after a line feed")
    }

    /// A regular expression's place is checked in the time of one match
    /// attempt, however far into its chapter the match is: for the last
    /// match of a chapter of about 7.7 MB, the check takes a small fraction
    /// of a scan of the chapter by the same expression, which is what the
    /// check was until November 13 (a probe on the development Mac: under a
    /// tenth of a millisecond, against 0.1 seconds for a 19 MB chapter). Both
    /// are timed on the machine running the test, the check at its best of
    /// three, so the comparison holds on a slow or busy machine too.
    func testARegularExpressionsPlaceIsCheckedInAFractionOfAScanOfItsChapter() throws {
        let sentence = "The deckhand coiled the rope beside the winch and counted the crates. "
        let withWord = "The deckhand coiled the lanyard beside the winch and counted the crates. "
        var chapter = ""
        for index in 0..<110_000 {
            chapter += index % 10 == 0 ? withWord : sentence
        }
        let pattern = TextSearchOptions(matchCase: false, isRegularExpression: true)
        let last = (chapter as NSString).range(of: "lanyard", options: .backwards).location
        let atPlace = request(chapter: 0, offset: last, query: "lan.?yard", text: "lanyard", options: pattern)

        var bestCheck = Double.infinity
        for attempt in 1...3 {
            let started = Date()
            let held = LibrarySearchJumpPlace.holds(for: atPlace, in: [chapter])
            bestCheck = min(bestCheck, Date().timeIntervalSince(started))
            XCTAssertTrue(held, "attempt \(attempt): the last match was not found at its place")
        }
        let matcher = try XCTUnwrap(try BookTextSearch.Matcher(query: "lan.?yard", options: pattern))
        let scanStarted = Date()
        var count = 0
        matcher.enumerateRanges(in: chapter) { _ in
            count += 1
            return true
        }
        let scan = Date().timeIntervalSince(scanStarted)

        print("LibrarySearchJumpTests: checked a regular expression's place in \(bestCheck) seconds; scanned its chapter of \(chapter.utf16.count) characters in \(scan) seconds")
        XCTAssertEqual(count, 11_000, "matches in the chapter")
        XCTAssertLessThan(
            bestCheck * 10, scan,
            "checking the place took \(bestCheck) seconds, a tenth or more of the \(scan) a scan of the chapter takes"
        )
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

        // The book is searched in the background before the match is told
        // gone.
        XCTAssertTrue(
            waitUntil(timeout: 10) { reader.lastAnnouncement == LibrarySearchWording.matchGone },
            "the reader never said the match is gone: \(reader.lastAnnouncement ?? "nothing")"
        )
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
        XCTAssertTrue(
            waitUntil(timeout: 10) { reader.lastAnnouncement == LibrarySearchWording.matchGone },
            "the reader never said the match is gone with Match Case: \(reader.lastAnnouncement ?? "nothing")"
        )
        XCTAssertEqual(reader.currentChapterIndex, 0, "chapter of the cursor after a Match Case request")

        // Without it, the same words are found where they were.
        requests.request(bookID: book.id, match: target, query: "QUAY", options: TextSearchOptions())
        XCTAssertEqual(reader.currentChapterIndex, target.chapterIndex, "chapter of the cursor without Match Case")
        XCTAssertEqual(reader.currentCharacterOffset, target.characterOffset, "offset of the cursor without Match Case")
        XCTAssertTrue(
            hears(movedWords(to: target), from: reader),
            "what VoiceOver was told without Match Case: \(reader.lastAnnouncement ?? "nothing")"
        )
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
        XCTAssertTrue(hears(movedWords(to: target), from: reader), "what VoiceOver was told: \(reader.lastAnnouncement ?? "nothing")")
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
        // Past the moment a move's words would come.
        XCTAssertFalse(
            waitUntil(timeout: VoiceOverAnnouncer.afterSheetDelay + 0.3) { reader.lastAnnouncement == movedWords(to: target) },
            "the other book's reader announced the move"
        )
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

    // MARK: - An Open Refused

    /// An open the Library refuses, while the library moves or is
    /// unavailable, drops the request to move to a match waiting for its
    /// book, so opening the book another way within the request's lifetime
    /// never jumps to an old match (the review of November 13, finding 9);
    /// another book's request stays, and an action that opens no book drops
    /// nothing.
    func testARefusedOpenDropsTheMatchRequestWaitingForItsBook() {
        let requests = LibrarySearchJumpRequests()
        let refused = UUID()
        let other = UUID()
        let found = BookSearchResult(
            chapterIndex: 1, characterOffset: 4, matchedText: "word", contextSnippet: "a word here", globalOffset: 40
        )
        for bookID in [refused, other] {
            requests.request(bookID: bookID, match: found, query: "word", options: TextSearchOptions())
        }

        ReaderOpenRefusal.dropRequests(
            for: .openBookWindow(refused),
            autoplay: ReaderAutoplayRequests(),
            readingList: ReadingListOpenRequests(),
            librarySearch: requests
        )
        XCTAssertFalse(requests.hasRequest(for: refused), "the refused book's match request was kept")
        XCTAssertTrue(requests.hasRequest(for: other), "another book's match request was dropped")

        ReaderOpenRefusal.dropRequests(
            for: .goToLibrary,
            autoplay: ReaderAutoplayRequests(),
            readingList: ReadingListOpenRequests(),
            librarySearch: requests
        )
        XCTAssertTrue(requests.hasRequest(for: other), "an action that opens no book dropped a match request")
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
        XCTAssertTrue(
            hears(BookSearchWording.noTranscript(bookTitle: book.title), from: reader),
            "what VoiceOver was told: \(reader.lastAnnouncement ?? "nothing")"
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
        // The place is named as a Search in Book pick of a transcript names
        // it: by its chapter's title, unless that says nothing.
        let location = BookSearchView.locationTitles(
            of: [(chapterIndex: 1, characterOffset: target.characterOffset)],
            headings: [],
            chapterTitles: reader.content?.chapters.map(\.title) ?? [],
            bookTitle: book.title
        ).first ?? nil
        let words = BookSearchWording.movedTo(
            time: timing.time(chapterIndex: 1, characterOffset: target.characterOffset),
            location: location
        )
        XCTAssertTrue(hears(words, from: reader), "what VoiceOver was told: \(reader.lastAnnouncement ?? "nothing")")
    }

    // MARK: - The Cost of Finding the Place

    /// The reader checks the place itself on the main actor, which reads a
    /// few characters, and searches the whole book only off the main actor,
    /// when the text changed. Over a synthetic book of two megabytes, a match
    /// in about every ten sentences, the place check takes a fraction of a
    /// millisecond and the whole-book search well under a second; the
    /// limits are generous so a busy machine does not fail the test, and the
    /// measured times are in the failure messages and the test's log.
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

        // The place check: the last match of the last chapter, which a
        // search from the start would reach last.
        let lastChapter = chapters.count - 1
        let lastOffset = (chapters[lastChapter] as NSString).range(of: "lanyard", options: .backwards).location
        let atPlace = request(chapter: lastChapter, offset: lastOffset, query: "lanyard", text: "lanyard")
        let placeStarted = Date()
        let held = LibrarySearchJumpPlace.holds(for: atPlace, in: chapters)
        let placeElapsed = Date().timeIntervalSince(placeStarted)
        XCTAssertTrue(held, "the last match was not found at its place")
        XCTAssertLessThan(placeElapsed, 0.5, "checking the place took \(placeElapsed) seconds")

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
        print("LibrarySearchJumpTests: checked the place in \(placeElapsed) seconds; searched \(totalCharacters) characters for \(results.count) matches in \(elapsed) seconds")
        XCTAssertLessThan(elapsed, 5, "searching \(totalCharacters) characters took \(elapsed) seconds")
    }
}
