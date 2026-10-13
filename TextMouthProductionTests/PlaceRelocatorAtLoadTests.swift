import XCTest
@testable import TextMouth

/// Moving a book's places when its text is loaded, with no old text to diff
/// with (T06's branch E, `PlaceRelocator.relocate(_:within:movedAt:)`): the
/// places that stand cost only direct checks, the ones that do not are found
/// by their saved words or guessed, and a reader's cursor is carried into an
/// edited text as a reading position would be
/// (`PlaceRelocator.relocate(_:from:to:)`). Pure: no window, no file.
final class PlaceRelocatorAtLoadTests: XCTestCase {

    // MARK: - Helpers

    /// A loaded book whose chapters' reading texts are `texts`, with
    /// `headings` (the mill book's by default).
    private func loaded(_ texts: [String], headings: [Heading]? = nil) -> DocumentContent {
        let all = headings ?? MillBook.headings(of: texts)
        return DocumentContent(title: "The Mill", author: "The Mill Society", chapters: texts.enumerated().map { index, text in
            Chapter(title: "", text: text, headings: all.filter { $0.chapterIndex == index })
        })
    }

    /// The mill book with a paragraph put in before chapter I's second one.
    private var rained: [String] {
        [MillBook.millrace.replacingOccurrences(of: "By noon", with: "It had rained all February. By noon")] + MillBook.chapters.dropFirst()
    }

    /// The text put in before chapter III, ahead of its heading.
    private static let editorsNote = "Editor's note: the stones are described as the volunteers found them.\n\n"

    /// The mill book with an editor's note put in before chapter III's
    /// heading, and the headings of the book as that text has them.
    private var notedStones: (texts: [String], headings: [Heading]) {
        let texts = [MillBook.millrace, MillBook.wheel, Self.editorsNote + MillBook.stones, MillBook.flour]
        let moved = Heading(level: 1, text: "CHAPTER III. The Stones", chapterIndex: 2, characterOffset: Self.editorsNote.utf16.count)
        return (texts, MillBook.headings(of: texts).filter { $0.chapterIndex != 2 } + [moved])
    }

    /// A reading position at `place` in the book `texts` (with its offset
    /// across the book, and a time long before the tests' move date), with
    /// its words captured there.
    private func position(at place: TextPlace, in texts: [String]) throws -> ReadingPosition {
        var position = ReadingPosition(
            chapterIndex: place.chapter,
            headingIndex: 2,
            characterOffset: place.offset,
            globalCharacterOffset: BookWords(texts: texts).globalOffset(of: place),
            anchor: try SavedPlace.anchor(at: place, in: texts)
        )
        position.lastUpdated = Date(timeIntervalSince1970: 1_000_000)
        return position
    }

    /// A bookmark at `place` in the book `texts`, with its words captured
    /// there and a note and a date of its own.
    private func bookmark(at place: TextPlace, in texts: [String], number: Int = 1) throws -> Bookmark {
        Bookmark(number: number, chapterIndex: place.chapter, characterOffset: place.offset, label: "ask the archive",
                 dateCreated: Date(timeIntervalSince1970: 2_000_000), anchor: try SavedPlace.anchor(at: place, in: texts))
    }

    /// The place of the numbers a position or a bookmark holds.
    private func place(of position: ReadingPosition?) throws -> TextPlace {
        let held = try XCTUnwrap(position)
        return TextPlace(chapter: held.chapterIndex, offset: held.characterOffset)
    }

    /// The place of the numbers a bookmark holds.
    private func place(of bookmark: Bookmark) -> TextPlace {
        TextPlace(chapter: bookmark.chapterIndex, offset: bookmark.characterOffset)
    }

    /// Asserts that `finding` is `.foundBySavedWords` with the evidence of a
    /// score (the score itself is the finder's business).
    private func assertFoundBySavedWords(_ finding: PlaceRelocator.Finding?, file: StaticString = #filePath, line: UInt = #line) {
        guard case .foundBySavedWords(.savedWords)? = finding else {
            return XCTFail("expected a place found by its saved words, got \(String(describing: finding))", file: file, line: line)
        }
    }

    // MARK: - Places That Stand

    /// An unchanged book gives nil whatever its places: a position, a
    /// bookmark, a named skip, and a waiting skip whose heading is still
    /// gone, all with words that stand.
    func testAnUnchangedBookGivesNil() throws {
        let book = MillBook.chapters
        let waiting = SkippedHeading(level: 1, label: "CHAPTER IX. The Weir", chapterIndex: 4, characterOffset: 0)
        let places = PlaceRelocator.Places(
            position: try position(at: try Phrase.place(of: "spirit level", inChapter: 0, of: book), in: book),
            bookmarks: [try bookmark(at: try Phrase.place(of: "French burrs", inChapter: 2, of: book), in: book)],
            skippedHeadings: [try SavedPlace.skip(of: try MillBook.heading(ofChapter: 2, in: book), in: book)],
            waitingSkippedHeadings: [waiting]
        )
        XCTAssertNil(PlaceRelocator.relocate(places, within: loaded(book), movedAt: SavedPlace.moveDate))
    }

    /// A book with no places gives nil, and so does a place saved without
    /// words, which nothing finds without the old text (the reader's clamp
    /// and its capture of missing words take it), even past its chapter's
    /// end; so do words that hold no word, which stand anywhere.
    func testPlacesWithNothingToFindThemByStayWhereTheyAre() throws {
        let content = loaded(MillBook.chapters)
        XCTAssertNil(PlaceRelocator.relocate(PlaceRelocator.Places(), within: content, movedAt: SavedPlace.moveDate))
        let places = PlaceRelocator.Places(
            position: ReadingPosition(chapterIndex: 9, characterOffset: 4),
            bookmarks: [
                Bookmark(number: 1, chapterIndex: 1, characterOffset: 99_999),
                Bookmark(number: 2, chapterIndex: 1, characterOffset: 7, anchor: TextAnchor(before: "", after: "", fraction: 0.5)),
            ]
        )
        XCTAssertNil(PlaceRelocator.relocate(places, within: content, movedAt: SavedPlace.moveDate))
    }

    /// A position at the end of the book stands at the end, a position at
    /// the very start of the book stands at the start even when its words
    /// are no longer there (a book never begun), and both are judged by the
    /// numbers they hold.
    func testThePlacesAtTheEndAndTheStartStand() throws {
        let book = MillBook.chapters
        let end = BookWords(texts: book).endPlace
        let atTheEnd = try position(at: end, in: book)
        XCTAssertNil(PlaceRelocator.relocate(PlaceRelocator.Places(position: atTheEnd), within: loaded(book), movedAt: SavedPlace.moveDate))

        // The words saved at the start belong to another text.
        var atTheStart = try position(at: TextPlace(chapter: 0, offset: 0), in: ["Another title page\n\nAnother book entirely."])
        atTheStart.globalCharacterOffset = 0
        XCTAssertNil(PlaceRelocator.relocate(PlaceRelocator.Places(position: atTheStart), within: loaded(book), movedAt: SavedPlace.moveDate))
    }

    /// A place that marks the end of the book but is not exactly at the end
    /// of the text it is loaded with (the book grew after it) goes to the new
    /// end, whatever the numbers it saved.
    func testAPlaceMarkingTheEndGoesToTheEndWhenItIsNotThere() throws {
        let old = MillBook.chapters
        let atTheEnd = try position(at: BookWords(texts: old).endPlace, in: old)
        let new = Array(old.dropLast()) + [MillBook.flour + " The mill ground flour for the whole parish by October."]
        let outcome = try XCTUnwrap(PlaceRelocator.relocate(PlaceRelocator.Places(position: atTheEnd), within: loaded(new), movedAt: SavedPlace.moveDate))
        let end = BookWords(texts: new).endPlace
        XCTAssertEqual(try place(of: outcome.places.position), end)
        XCTAssertEqual(outcome.positionFinding, .movedByTheDiff(.endOfBook))
        XCTAssertEqual(outcome.places.position?.lastUpdated, SavedPlace.moveDate)
        XCTAssertEqual(outcome.places.position?.globalCharacterOffset, BookWords(texts: new).totalLength)
        XCTAssertEqual(outcome.counts, PlaceRelocator.Counts(movedByTheDiff: 1))
    }

    // MARK: - Places Found by Their Saved Words

    /// A paragraph put in before every place: the position and the bookmark
    /// are found by their saved words, and the skip's heading by its saved
    /// words too. The moved position is dated at the move and takes its new
    /// offset across the book; the bookmark keeps its id, number, note, and
    /// date; the counts and the log line say three places were found by their
    /// words.
    func testAParagraphPutInBeforeEveryPlaceFindsThemBySavedWords() throws {
        let old = MillBook.chapters
        let readingOld = try Phrase.place(of: "spirit level", inChapter: 0, of: old)
        let markedOld = try Phrase.place(of: "French burrs", inChapter: 2, of: old)
        let oldPosition = try position(at: readingOld, in: old)
        let oldBookmark = try bookmark(at: markedOld, in: old)
        let skipped = try SavedPlace.skip(of: try MillBook.heading(ofChapter: 2, in: old), in: old)
        let places = PlaceRelocator.Places(position: oldPosition, bookmarks: [oldBookmark], skippedHeadings: [skipped])

        // The paragraph in chapter I, and the editor's note before chapter
        // III's heading, so that every place has text put in before it.
        let noted = notedStones
        let new = [rained[0], noted.texts[1], noted.texts[2], noted.texts[3]]
        let outcome = try XCTUnwrap(PlaceRelocator.relocate(places, within: loaded(new, headings: noted.headings), movedAt: SavedPlace.moveDate))
        let words = BookWords(texts: new)

        let reading = try Phrase.place(of: "spirit level", inChapter: 0, of: new)
        let moved = try XCTUnwrap(outcome.places.position)
        assertFoundBySavedWords(outcome.positionFinding)
        XCTAssertEqual(try place(of: moved), reading)
        XCTAssertEqual(moved.anchor, TextAnchor(capturingAt: reading, in: words))
        XCTAssertEqual(moved.globalCharacterOffset, words.globalOffset(of: reading))
        XCTAssertEqual(moved.lastUpdated, SavedPlace.moveDate)
        XCTAssertEqual(moved.headingIndex, 2)

        let marked = try Phrase.place(of: "French burrs", inChapter: 2, of: new)
        let movedBookmark = try XCTUnwrap(outcome.places.bookmarks.first)
        assertFoundBySavedWords(outcome.bookmarkFindings.first)
        XCTAssertEqual(place(of: movedBookmark), marked)
        XCTAssertEqual(movedBookmark.id, oldBookmark.id)
        XCTAssertEqual(movedBookmark.number, 1)
        XCTAssertEqual(movedBookmark.label, "ask the archive")
        XCTAssertEqual(movedBookmark.dateCreated, oldBookmark.dateCreated)
        XCTAssertEqual(movedBookmark.anchor, TextAnchor(capturingAt: marked, in: words))

        let heading = try XCTUnwrap(noted.headings.first { $0.chapterIndex == 2 })
        XCTAssertEqual(outcome.places.skippedHeadings, [try SavedPlace.skip(of: heading, in: new)])
        XCTAssertEqual(outcome.places.skippedHeadings.first?.id, heading.id)
        assertFoundBySavedWords(outcome.skippedHeadingFindings.first)
        XCTAssertTrue(outcome.places.waitingSkippedHeadings.isEmpty)

        XCTAssertEqual(outcome.counts, PlaceRelocator.Counts(foundBySavedWords: 3))
        XCTAssertEqual(outcome.counts.logLine(title: "The Mill"), "PLACES_RELOCATED: The Mill: unchanged 0, moved by the diff 0, by the saved words 3, guessed 0")
    }

    /// A place whose words were rewritten, stretch and all, is found nowhere:
    /// it stays exactly as it was saved, numbers and words, so that a later
    /// text that holds those words again can still find it (T06's branch E).
    /// The outcome still counts it as a best guess.
    func testAPlaceWhoseWordsWereRewrittenStaysAsSaved() throws {
        let old = MillBook.chapters
        let saved = try Phrase.place(of: "and wrote the figures", inChapter: 0, of: old)
        let rewritten = MillBook.millrace.replacingOccurrences(
            of: "Nell measured the fall with a spirit level and a length of string, and wrote the figures on the back of a seed packet, which she lost by teatime.",
            with: "Rain drummed on the corrugated shed until dusk, so conversation turned to whether anybody had remembered a kettle."
        )
        XCTAssertNotEqual(rewritten, MillBook.millrace)
        let new = [rewritten] + old.dropFirst()
        let savedBookmark = try bookmark(at: saved, in: old)
        let outcome = try XCTUnwrap(PlaceRelocator.relocate(
            PlaceRelocator.Places(bookmarks: [savedBookmark]),
            within: loaded(new),
            movedAt: SavedPlace.moveDate
        ))
        XCTAssertEqual(outcome.bookmarkFindings, [.guessed(.savedWords(.sameShare))])
        XCTAssertEqual(outcome.places.bookmarks, [savedBookmark], "numbers, words, and date as saved")
        XCTAssertEqual(outcome.counts, PlaceRelocator.Counts(guessed: 1))
        XCTAssertTrue(outcome.counts.anythingMoved)
    }

    /// A place whose words are found nowhere stays as saved, with its words,
    /// while another place, found by its words, moves.
    func testAPlaceFoundNowhereKeepsItsWordsWhileAnotherMoves() throws {
        let old = MillBook.chapters
        let movingBookmark = try bookmark(at: try Phrase.place(of: "spirit level", inChapter: 0, of: old), in: old, number: 1)
        // Words no text holds, at numbers inside chapter II.
        let lost = Bookmark(
            number: 2, chapterIndex: 1, characterOffset: 40,
            anchor: TextAnchor(before: "words that no text holds ", after: "nor these either", fraction: 0.4, measuredIn: "3.0.4/1.0.0")
        )
        let outcome = try XCTUnwrap(PlaceRelocator.relocate(
            PlaceRelocator.Places(bookmarks: [movingBookmark, lost]), within: loaded(rained), movedAt: SavedPlace.moveDate
        ))
        assertFoundBySavedWords(outcome.bookmarkFindings.first)
        XCTAssertEqual(outcome.bookmarkFindings.dropFirst().map { $0 }, [.guessed(.savedWords(.sameShare))])
        XCTAssertEqual(
            outcome.places.bookmarks.first.map { place(of: $0) },
            try Phrase.place(of: "spirit level", inChapter: 0, of: rained)
        )
        XCTAssertEqual(outcome.places.bookmarks.dropFirst().map { $0 }, [lost], "numbers, words, and date as saved")
    }

    /// A position at the end of the book stays at the new end when text is
    /// added after it, and is dated at the move.
    func testAPositionAtTheEndStaysAtTheEndWhenTextIsAddedAfterIt() throws {
        let old = MillBook.chapters
        let atTheEnd = try position(at: BookWords(texts: old).endPlace, in: old)
        let new = old + ["CHAPTER V. The Granary\n\nThe bats left in November."]
        let outcome = try XCTUnwrap(PlaceRelocator.relocate(PlaceRelocator.Places(position: atTheEnd), within: loaded(new), movedAt: SavedPlace.moveDate))
        XCTAssertEqual(try place(of: outcome.places.position), BookWords(texts: new).endPlace)
        XCTAssertEqual(outcome.positionFinding, .movedByTheDiff(.endOfBook))
        XCTAssertEqual(outcome.places.position?.lastUpdated, SavedPlace.moveDate)
    }

    /// A position at chapter 0, offset 0 stays there when a title page is put
    /// in before the old first words, while a bookmark elsewhere in the
    /// chapter does move: the book is still never begun.
    func testAPositionAtTheStartStaysWhenATitlePageIsPutInBeforeIt() throws {
        let old = MillBook.chapters
        let atTheStart = try position(at: TextPlace(chapter: 0, offset: 0), in: old)
        let marked = try bookmark(at: try Phrase.place(of: "spirit level", inChapter: 0, of: old), in: old)
        let titlePage = "THE MILL\n\nA record of one year's restoration.\n\n"
        let new = [titlePage + MillBook.millrace] + old.dropFirst()
        let outcome = try XCTUnwrap(PlaceRelocator.relocate(
            PlaceRelocator.Places(position: atTheStart, bookmarks: [marked]), within: loaded(new), movedAt: SavedPlace.moveDate
        ))
        let moved = try XCTUnwrap(outcome.places.position)
        XCTAssertEqual(try place(of: moved), TextPlace(chapter: 0, offset: 0))
        XCTAssertEqual(outcome.positionFinding, .movedByTheDiff(.startOfBook))
        XCTAssertEqual(moved.lastUpdated, atTheStart.lastUpdated, "it did not move")
        XCTAssertEqual(moved.anchor, TextAnchor(capturingAt: TextPlace(chapter: 0, offset: 0), in: BookWords(texts: new)), "its words are those of the title page")
        XCTAssertEqual(place(of: try XCTUnwrap(outcome.places.bookmarks.first)), try Phrase.place(of: "spirit level", inChapter: 0, of: new))
        assertFoundBySavedWords(outcome.bookmarkFindings.first)
        XCTAssertEqual(outcome.counts, PlaceRelocator.Counts(movedByTheDiff: 1, foundBySavedWords: 1))
    }

    /// A place without saved words, past its chapter's end, beside a place
    /// that moves: it stays exactly as saved, as does a place without words
    /// that the text holds (nothing finds either without the old text; the
    /// reader's clamp and its capture of missing words take them).
    func testAPlaceWithoutWordsStaysAsSavedBesideAPlaceThatMoves() throws {
        let old = MillBook.chapters
        let moving = try bookmark(at: try Phrase.place(of: "spirit level", inChapter: 0, of: old), in: old, number: 1)
        let past = Bookmark(number: 2, chapterIndex: 1, characterOffset: 99_999)
        let held = Bookmark(number: 3, chapterIndex: 3, characterOffset: 5)
        let outcome = try XCTUnwrap(PlaceRelocator.relocate(
            PlaceRelocator.Places(bookmarks: [moving, past, held]), within: loaded(rained), movedAt: SavedPlace.moveDate
        ))
        XCTAssertEqual(outcome.bookmarkFindings.count, 3)
        assertFoundBySavedWords(outcome.bookmarkFindings.first)
        XCTAssertEqual(outcome.bookmarkFindings.dropFirst().map { $0 }, [.guessed(.savedWords(.sameShare)), .unchanged])
        // Read through `dropFirst()`, never by index: a short outcome fails
        // the assertion instead of trapping the test host.
        XCTAssertEqual(outcome.places.bookmarks.dropFirst().map { $0 }, [past, held], "numbers and no words, as saved")
        XCTAssertEqual(outcome.counts, PlaceRelocator.Counts(unchanged: 1, foundBySavedWords: 1, guessed: 1))
    }

    /// A reading position without saved words stays exactly as saved, past
    /// the last chapter or not: the reader's clamp opens its cursor, not the
    /// saved place.
    func testAPositionWithoutWordsStaysAsSaved() throws {
        let book = MillBook.chapters
        let moving = try bookmark(at: try Phrase.place(of: "spirit level", inChapter: 0, of: book), in: book)
        // The book as loaded: the paragraph put in lengthens it.
        let length = BookWords(texts: rained).totalLength
        let unfinished = ReadingPosition(chapterIndex: 9, characterOffset: 4, globalCharacterOffset: 10)
        let finished = ReadingPosition(chapterIndex: 9, characterOffset: 4, globalCharacterOffset: length)
        let content = loaded(rained)
        for position in [unfinished, finished] {
            let outcome = try XCTUnwrap(PlaceRelocator.relocate(
                PlaceRelocator.Places(position: position, bookmarks: [moving]), within: content, movedAt: SavedPlace.moveDate
            ))
            XCTAssertEqual(outcome.places.position, position)
            XCTAssertEqual(outcome.positionFinding, .guessed(.savedWords(.sameShare)))
        }
    }

    // MARK: - Skipped Headings

    /// A waiting skip whose heading stands again exactly as it was skipped is
    /// no shortcut: the outcome names the heading again, unchanged.
    func testAWaitingSkipWhoseHeadingStandsAgainNamesItAgain() throws {
        let book = MillBook.chapters
        let skip = try SavedPlace.skip(of: try MillBook.heading(ofChapter: 2, in: book), in: book)
        let places = PlaceRelocator.Places(waitingSkippedHeadings: [skip])
        let outcome = try XCTUnwrap(PlaceRelocator.relocate(places, within: loaded(book), movedAt: SavedPlace.moveDate))
        XCTAssertEqual(outcome.places.skippedHeadings, [skip])
        XCTAssertTrue(outcome.places.waitingSkippedHeadings.isEmpty)
        XCTAssertEqual(outcome.skippedHeadingFindings, [.unchanged])
        XCTAssertEqual(outcome.counts, PlaceRelocator.Counts(unchanged: 1))
    }

    /// A waiting skip with no saved words never names its heading again: it
    /// needs proof it is the same heading, so it is no reason to move
    /// anything.
    func testAWaitingSkipWithoutWordsStaysWaiting() throws {
        let book = MillBook.chapters
        let heading = try MillBook.heading(ofChapter: 2, in: book)
        let places = PlaceRelocator.Places(waitingSkippedHeadings: [SkippedHeading(heading)])
        XCTAssertNil(PlaceRelocator.relocate(places, within: loaded(book), movedAt: SavedPlace.moveDate))
    }

    /// A named skip whose heading was removed now waits: kept as it was, in
    /// the waiting list, counted as waiting.
    func testANamedSkipWhoseHeadingWasRemovedNowWaits() throws {
        let old = MillBook.chapters
        let skip = try SavedPlace.skip(of: try MillBook.heading(ofChapter: 2, in: old), in: old)
        let new = [MillBook.millrace, MillBook.wheel, MillBook.flour]
        let outcome = try XCTUnwrap(PlaceRelocator.relocate(PlaceRelocator.Places(skippedHeadings: [skip]), within: loaded(new), movedAt: SavedPlace.moveDate))
        XCTAssertTrue(outcome.places.skippedHeadings.isEmpty)
        XCTAssertEqual(outcome.places.waitingSkippedHeadings, [skip])
        XCTAssertTrue(outcome.skippedHeadingFindings.isEmpty)
        XCTAssertEqual(outcome.counts, PlaceRelocator.Counts(waiting: 1))
        XCTAssertEqual(outcome.counts.logLine(title: "The Mill"), "PLACES_RELOCATED: The Mill: unchanged 0, moved by the diff 0, by the saved words 0, guessed 0, waiting 1")
    }

    /// A skip whose words find only a best guess among several headings of
    /// its label waits rather than skip a section the listener may want to
    /// hear: a guess never moves a skip onto a heading.
    func testASkipOnlyAGuessFindsWaits() throws {
        let book = NotesBook()
        // The skip was made in a text whose "Notes" had other words around
        // it, before and after: of the two "Notes" in the text now, neither
        // is the one its words name, and each scores below the rule's 8.
        let before = "CHAPTER I. Another Opening\n\nSomething unrelated happened at the gate.\n\n"
        let oldText = [before + "Notes\n\nAn old paragraph about hinges, quite unlike the new ones."]
        let oldHeading = Heading(level: 2, text: "Notes", chapterIndex: 0, characterOffset: before.utf16.count)
        let skip = try SavedPlace.skip(of: oldHeading, in: oldText)
        let content = loaded(book.both, headings: [book.firstHeading, book.secondHeading])
        let outcome = try XCTUnwrap(PlaceRelocator.relocate(PlaceRelocator.Places(skippedHeadings: [skip]), within: content, movedAt: SavedPlace.moveDate))
        XCTAssertEqual(outcome.places.waitingSkippedHeadings, [skip])
        XCTAssertEqual(outcome.counts, PlaceRelocator.Counts(waiting: 1))
    }

    // MARK: - A Text Holding Nothing

    /// A text that holds nothing moves nothing, so a book whose text is not
    /// there yet does not lose its places to its start.
    func testATextHoldingNothingMovesNothing() throws {
        let old = MillBook.chapters
        let places = PlaceRelocator.Places(
            position: try position(at: try Phrase.place(of: "spirit level", inChapter: 0, of: old), in: old),
            bookmarks: [try bookmark(at: try Phrase.place(of: "French burrs", inChapter: 2, of: old), in: old)]
        )
        XCTAssertNil(PlaceRelocator.relocate(places, within: loaded([]), movedAt: SavedPlace.moveDate))
        XCTAssertNil(PlaceRelocator.relocate(places, within: loaded(["", ""]), movedAt: SavedPlace.moveDate))
    }

    // MARK: - A Cursor Carried Into Edited Text

    /// The harbour book: two short chapters.
    private static let harbour = ["Alpha beta gamma delta epsilon zeta.", "The harbour lights came on one by one along the quay."]

    /// Where the cursor at `chapter`, `offset` of the harbour book goes in
    /// the book `new`.
    private func carried(_ chapter: Int, _ offset: Int, to new: [String]) -> TextPlace {
        PlaceRelocator.relocate(TextPlace(chapter: chapter, offset: offset), from: loaded(Self.harbour), to: loaded(new))
    }

    /// The offset of the harbour book's "one by one" in `text`, its second
    /// chapter's by default: where the cursor of these tests stands.
    private func quayOffset(in text: String = PlaceRelocatorAtLoadTests.harbour[1]) throws -> Int {
        try Phrase.offset(of: "one by one", in: text)
    }

    /// The cursor keeps its place in an unchanged chapter.
    func testTheCursorStaysInAnUnchangedChapter() throws {
        let quay = try quayOffset()
        XCTAssertEqual(carried(1, quay, to: Self.harbour), TextPlace(chapter: 1, offset: quay))
    }

    /// The cursor follows its words when text is added before them.
    func testTheCursorFollowsItsWordsWhenTextIsAddedBefore() throws {
        let quay = try quayOffset()
        let added = [Self.harbour[0], "Night fell early. " + Self.harbour[1]]
        XCTAssertEqual(carried(1, quay, to: added), TextPlace(chapter: 1, offset: quay + "Night fell early. ".utf16.count))
    }

    /// The cursor whose own words were rewritten stands after the words
    /// before it that were kept: the relocator's rule for a word replaced in
    /// local editing.
    func testTheCursorWhoseWordsWereRewrittenStandsAfterTheWordsBeforeIt() throws {
        let quay = try quayOffset()
        let rewritten = [Self.harbour[0], "The harbour lights came on all at once."]
        XCTAssertEqual(carried(1, quay, to: rewritten), TextPlace(chapter: 1, offset: "The harbour lights came on ".utf16.count))
    }

    /// A chapter split, with an interlude put in before it: the cursor goes
    /// to the chapter that holds its words (the relocator reads no titles).
    func testTheCursorFollowsItsWordsToAChapterAfterAnInterlude() throws {
        let quay = try quayOffset()
        let split = [Self.harbour[0], "Gulls.", Self.harbour[1]]
        XCTAssertEqual(carried(1, quay, to: split), TextPlace(chapter: 2, offset: quay))
    }

    /// Two chapters merged into one: the cursor follows its words into it.
    func testTheCursorFollowsItsWordsIntoAMergedChapter() throws {
        let quay = try quayOffset()
        let merged = [Self.harbour[0] + " " + Self.harbour[1]]
        XCTAssertEqual(carried(1, quay, to: merged), TextPlace(chapter: 0, offset: try quayOffset(in: merged[0])))
    }

    /// A chapter replaced by unrelated text: the cursor stays in its chapter
    /// at a word's start, a best guess.
    func testTheCursorInUnrelatedTextStaysInItsChapterAtAWordStart() throws {
        let quay = try quayOffset()
        let unrelated = [Self.harbour[0], "Completely different words fill this chapter now, end to end."]
        let found = carried(1, quay, to: unrelated)
        XCTAssertEqual(found.chapter, 1)
        XCTAssertEqual(found.offset, ReaderViewModel.snappedWordStart(in: unrelated[1], at: found.offset))
    }

    /// A cursor in a chapter past the end opens where the reader would open
    /// it, the last chapter's start (`TextPlace.opening`), and moves from
    /// there, as the reader's clamp holds it.
    func testACursorInAChapterPastTheEndIsHeldAsTheReaderHoldsIt() {
        XCTAssertEqual(carried(9, 4, to: Self.harbour), TextPlace(chapter: 1, offset: 0))
        // A last chapter that moved takes the held place with it.
        XCTAssertEqual(carried(9, 4, to: [Self.harbour[0], "Gulls.", Self.harbour[1]]), TextPlace(chapter: 2, offset: 0))
    }

    /// A new text with no chapters gives chapter 0, offset 0.
    func testAnEmptyNewTextGivesTheStart() throws {
        let quay = try quayOffset()
        XCTAssertEqual(carried(1, quay, to: []), TextPlace(chapter: 0, offset: 0))
        XCTAssertEqual(carried(0, 0, to: []), TextPlace(chapter: 0, offset: 0))
    }

    /// The start and the end of the book are kept as for a position: a
    /// cursor at the start stays at the start when a title is put in before
    /// the first words, and a cursor at the end stays at the end when text is
    /// added after it.
    func testTheCursorKeepsTheStartAndTheEndOfTheBook() throws {
        let titled = ["A Harbour Diary\n\n" + Self.harbour[0], Self.harbour[1]]
        XCTAssertEqual(carried(0, 0, to: titled), TextPlace(chapter: 0, offset: 0))
        let endOffset = Self.harbour[1].utf16.count
        let longer = [Self.harbour[0], Self.harbour[1] + " Then the fog came in."]
        XCTAssertEqual(carried(1, endOffset, to: longer), TextPlace(chapter: 1, offset: longer[1].utf16.count))
    }

    /// An old text with no chapters holds no words to follow: the cursor is
    /// clamped in the new text, as a place saved without words is.
    func testACursorFromAnEmptyOldTextIsClampedInTheNewText() {
        let found = PlaceRelocator.relocate(TextPlace(chapter: 1, offset: 99_999), from: loaded([]), to: loaded(Self.harbour))
        XCTAssertEqual(found, TextPlace(chapter: 1, offset: Self.harbour[1].utf16.count), "held within its chapter, at the end")
    }
}
