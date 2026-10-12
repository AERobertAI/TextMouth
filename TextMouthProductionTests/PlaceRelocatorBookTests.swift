import XCTest
@testable import TextMouth

/// Moving a book's saved places together (T06, `PlaceRelocator.relocate(_:)`
/// for `PlaceRelocator.Places`): the reading position, the bookmarks, and
/// the skipped headings, what each keeps and what it takes from the new
/// text, a skip that waits or that now names the same heading as another,
/// and the counts and the debug log's line. Pure: no window, no file.
final class PlaceRelocatorBookTests: XCTestCase {

    /// The mill book with a paragraph put in before chapter I's second one.
    private var rained: [String] {
        [MillBook.millrace.replacingOccurrences(of: "By noon", with: "It had rained all February. By noon"), MillBook.wheel, MillBook.stones, MillBook.flour]
    }

    // MARK: - An Unchanged Book

    /// A book whose text is unchanged moves nothing: its places come back
    /// exactly as they went in, each found unchanged, and nothing is logged.
    func testAnUnchangedBookMovesNothing() throws {
        let book = MillBook.chapters
        let words = BookWords(texts: book)
        let reading = try Phrase.place(of: "spirit level", inChapter: 0, of: book)
        let marked = try Phrase.place(of: "French burrs", inChapter: 2, of: book)
        let places = PlaceRelocator.Places(
            position: ReadingPosition(chapterIndex: 0, characterOffset: reading.offset, globalCharacterOffset: words.globalOffset(of: reading),
                                      anchor: try SavedPlace.anchor(at: reading, in: book)),
            bookmarks: [
                Bookmark(number: 1, chapterIndex: 2, characterOffset: marked.offset, label: "the burrs", anchor: try SavedPlace.anchor(at: marked, in: book)),
                Bookmark(number: 2, chapterIndex: 3, characterOffset: 0, anchor: try SavedPlace.anchor(at: TextPlace(chapter: 3, offset: 0), in: book)),
            ],
            skippedHeadings: [try SavedPlace.skip(of: try MillBook.heading(ofChapter: 2, in: book), in: book)]
        )
        let outcome = PlaceRelocator(oldTexts: book, newTexts: book, newHeadings: MillBook.headings(of: book)).relocate(places)
        XCTAssertEqual(outcome.places, places)
        XCTAssertEqual(outcome.positionFinding, .unchanged)
        XCTAssertEqual(outcome.bookmarkFindings, [.unchanged, .unchanged])
        XCTAssertEqual(outcome.skippedHeadingFindings, [.unchanged])
        XCTAssertEqual(outcome.counts, PlaceRelocator.Counts(unchanged: 4))
        XCTAssertFalse(outcome.counts.anythingMoved)
    }

    // MARK: - What a Moved Place Keeps

    /// A moved position takes its new chapter and offset, its offset across
    /// the whole book, and its words captured anew where it now is; its time
    /// and heading index stay, since a move is not a read. A position that
    /// stays where it was still takes its new offset across the book when
    /// text before its chapter changed length.
    func testAMovedPositionTakesItsNewPlaceAndWordsAndKeepsItsTime() throws {
        let old = MillBook.chapters
        let new = rained
        let oldWords = BookWords(texts: old)
        let newWords = BookWords(texts: new)
        let relocator = PlaceRelocator(old: oldWords, new: newWords)

        let saved = try Phrase.place(of: "spirit level", inChapter: 0, of: old)
        var position = ReadingPosition(chapterIndex: 0, headingIndex: 3, characterOffset: saved.offset, globalCharacterOffset: saved.offset,
                                       anchor: try SavedPlace.anchor(at: saved, in: old))
        position.lastUpdated = Date(timeIntervalSince1970: 1_000_000)
        let outcome = relocator.relocate(PlaceRelocator.Places(position: position))
        let moved = try XCTUnwrap(outcome.places.position)
        let now = try Phrase.place(of: "spirit level", inChapter: 0, of: new)
        XCTAssertEqual(outcome.positionFinding, .movedByTheDiff(.linedUp))
        XCTAssertEqual(TextPlace(chapter: moved.chapterIndex, offset: moved.characterOffset), now)
        XCTAssertEqual(moved.globalCharacterOffset, now.offset)
        XCTAssertEqual(moved.anchor, TextAnchor(capturingAt: now, in: newWords))
        XCTAssertEqual(moved.lastUpdated, position.lastUpdated)
        XCTAssertEqual(moved.headingIndex, 3)

        // A position in a later chapter keeps its numbers, and its offset
        // across the book grows with the text put in before its chapter.
        let later = try Phrase.place(of: "French burrs", inChapter: 2, of: old)
        let stayed = relocator.relocate(PlaceRelocator.Places(position: ReadingPosition(
            chapterIndex: 2, characterOffset: later.offset, globalCharacterOffset: oldWords.globalOffset(of: later),
            anchor: try SavedPlace.anchor(at: later, in: old)
        )))
        XCTAssertEqual(stayed.positionFinding, .unchanged)
        XCTAssertEqual(stayed.places.position?.characterOffset, later.offset)
        XCTAssertEqual(stayed.places.position?.globalCharacterOffset, newWords.globalOffset(of: later))
        XCTAssertNotEqual(newWords.globalOffset(of: later), oldWords.globalOffset(of: later))
    }

    /// A position saved without an offset across the whole book gets none.
    func testAPositionWithoutAnOffsetAcrossTheBookGetsNone() throws {
        let saved = try Phrase.place(of: "spirit level", inChapter: 0, of: MillBook.chapters)
        let outcome = PlaceRelocator(oldTexts: MillBook.chapters, newTexts: rained)
            .relocate(PlaceRelocator.Places(position: ReadingPosition(chapterIndex: 0, characterOffset: saved.offset)))
        XCTAssertEqual(outcome.positionFinding, .movedByTheDiff(.linedUp))
        XCTAssertNil(try XCTUnwrap(outcome.places.position).globalCharacterOffset)
    }

    /// A moved bookmark takes its new place and its words captured there,
    /// and keeps its identity, number, note, and date.
    func testAMovedBookmarkKeepsItsIdentityNumberNoteAndDate() throws {
        let old = MillBook.chapters
        let new = [MillBook.millrace, MillBook.wheel, MillBook.stones.replacingOccurrences(of: "Nobody knew", with: "For a whole season nobody knew"), MillBook.flour]
        let saved = try Phrase.place(of: "French burrs", inChapter: 2, of: old)
        let bookmark = Bookmark(number: 7, chapterIndex: 2, characterOffset: saved.offset, label: "ask the archive",
                                dateCreated: Date(timeIntervalSince1970: 2_000_000), anchor: try SavedPlace.anchor(at: saved, in: old))
        let outcome = PlaceRelocator(oldTexts: old, newTexts: new).relocate(PlaceRelocator.Places(bookmarks: [bookmark]))
        let moved = try XCTUnwrap(outcome.places.bookmarks.first)
        let now = try Phrase.place(of: "French burrs", inChapter: 2, of: new)
        XCTAssertEqual(outcome.bookmarkFindings, [.movedByTheDiff(.linedUp)])
        XCTAssertEqual(moved.id, bookmark.id)
        XCTAssertEqual(moved.number, 7)
        XCTAssertEqual(moved.label, "ask the archive")
        XCTAssertEqual(moved.dateCreated, bookmark.dateCreated)
        XCTAssertEqual(TextPlace(chapter: moved.chapterIndex, offset: moved.characterOffset), now)
        XCTAssertEqual(moved.anchor, try SavedPlace.anchor(at: now, in: new))
    }

    // MARK: - Skipped Headings

    /// A moved skip takes its heading's place and new label, and the words
    /// at the heading's start in the new text.
    func testAMovedSkipTakesItsHeadingsPlaceLabelAndWords() throws {
        let old = [TextAnchorRealReadings.chapterOneOpening304, TextAnchorRealReadings.chapterTwoOpening304]
        let new = [TextAnchorRealReadings.chapterOneOpening307, TextAnchorRealReadings.chapterTwoOpening307]
        let chapterTwo = Heading(level: 2, text: "CHAPTER II. The Pool of Tears", chapterIndex: 1, characterOffset: 0)
        let oldChapterTwo = Heading(level: 2, text: "[]CHAPTER II.", chapterIndex: 1, characterOffset: 0)
        let skipped = try SavedPlace.skip(of: oldChapterTwo, in: old)
        let outcome = PlaceRelocator(oldTexts: old, newTexts: new, oldHeadings: [oldChapterTwo], newHeadings: [chapterTwo])
            .relocate(PlaceRelocator.Places(skippedHeadings: [skipped]))
        XCTAssertEqual(outcome.places.skippedHeadings, [try SavedPlace.skip(of: chapterTwo, in: new)])
        XCTAssertEqual(outcome.places.skippedHeadings.first?.id, chapterTwo.id)
        XCTAssertEqual(outcome.counts, PlaceRelocator.Counts(movedByTheDiff: 1))
    }

    /// A skip that waits is kept as it was, counted as waiting, which the
    /// debug log reports.
    func testAWaitingSkipIsKeptAsItWas() throws {
        let old = MillBook.chapters
        let new = [MillBook.millrace, MillBook.wheel, MillBook.flour]
        let skipped = try SavedPlace.skip(of: try MillBook.heading(ofChapter: 2, in: old), in: old)
        let outcome = PlaceRelocator(oldTexts: old, newTexts: new, newHeadings: MillBook.headings(of: new))
            .relocate(PlaceRelocator.Places(skippedHeadings: [skipped]))
        XCTAssertEqual(outcome.places.skippedHeadings, [skipped])
        XCTAssertEqual(outcome.skippedHeadingFindings, [nil])
        XCTAssertEqual(outcome.counts, PlaceRelocator.Counts(waiting: 1))
        XCTAssertTrue(outcome.counts.anythingMoved)
    }

    /// A skip saved before skipped headings kept words, whose heading nothing
    /// names now, waits exactly as it was, gaining no words: words read in
    /// the old text at its numbers would be the words of whatever stands
    /// there now, which a skip never goes by (REV15, finding 3).
    func testASkipThatWaitsWithoutWordsStaysAsItWas() throws {
        let old = MillBook.chapters
        let new = [MillBook.millrace, MillBook.wheel, MillBook.flour]
        let skipped = SkippedHeading(level: 1, label: "CHAPTER III. The Stones", chapterIndex: 2, characterOffset: 0)
        let outcome = PlaceRelocator(oldTexts: old, newTexts: new, oldHeadings: MillBook.headings(of: old), newHeadings: MillBook.headings(of: new))
            .relocate(PlaceRelocator.Places(skippedHeadings: [skipped]))
        XCTAssertEqual(outcome.places.skippedHeadings, [skipped])
        XCTAssertEqual(outcome.skippedHeadingFindings, [nil])
    }

    /// A "Notes" section the new text leaves out does not pass its skip to
    /// another chapter's "Notes", though that one was skipped too (REV15,
    /// finding 4): the first skip waits, the second stays.
    func testASkipOfASectionLeftOutWaitsBesideAnotherChaptersSkip() throws {
        let firstNotes = "\n\nNotes\n\nThe pump belonged to the angling club and went back with a new washer."
        let secondNotes = "\n\nNotes\n\nThe carpenter's spoons are now in the county museum, in a case by the door."
        let old = [MillBook.millrace + firstNotes, MillBook.wheel + secondNotes]
        let new = [MillBook.millrace, MillBook.wheel + secondNotes]
        let firstHeading = Heading(level: 2, text: "Notes", chapterIndex: 0, characterOffset: MillBook.millrace.utf16.count + 2)
        let secondHeading = Heading(level: 2, text: "Notes", chapterIndex: 1, characterOffset: MillBook.wheel.utf16.count + 2)
        let relocator = PlaceRelocator(oldTexts: old, newTexts: new, oldHeadings: MillBook.headings(of: old) + [firstHeading, secondHeading],
                                       newHeadings: MillBook.headings(of: new) + [secondHeading])
        let outcome = relocator.relocate(PlaceRelocator.Places(
            skippedHeadings: [try SavedPlace.skip(of: firstHeading, in: old), try SavedPlace.skip(of: secondHeading, in: old)]
        ))
        XCTAssertEqual(outcome.skippedHeadingFindings, [nil, .unchanged])
        XCTAssertEqual(outcome.places.skippedHeadings.map(\.id), [firstHeading.id, secondHeading.id])
        XCTAssertEqual(outcome.counts, PlaceRelocator.Counts(unchanged: 1, waiting: 1))
    }

    // MARK: - The Start of the Book

    /// A position at the very start of the book (never begun, or begun
    /// over) stays at the start of the new text (REV15, finding 14): a
    /// preface restored as a chapter of its own before chapter I, or a title
    /// line put in at the start of chapter I, was not heard either, so the
    /// book starts there and its row does not read begun. A bookmark at the
    /// start follows its words, which the listener marked. With the text
    /// unchanged, the position is unchanged.
    func testAPositionAtTheStartOfTheBookStaysAtTheStart() throws {
        let old = MillBook.chapters
        let start = TextPlace(chapter: 0, offset: 0)
        let places = PlaceRelocator.Places(
            position: ReadingPosition(chapterIndex: 0, characterOffset: 0, globalCharacterOffset: 0, anchor: try SavedPlace.anchor(at: start, in: old)),
            bookmarks: [Bookmark(number: 1, chapterIndex: 0, characterOffset: 0, anchor: try SavedPlace.anchor(at: start, in: old))]
        )
        let preface = "PREFACE\n\nThis diary was kept by the volunteers of the Hollins Ford mill between March and November."
        let titled = ["The Mill at Hollins Ford\n\nA restoration diary\n\n" + MillBook.millrace] + Array(old.dropFirst())
        for new in [[preface] + old, titled] {
            let outcome = PlaceRelocator(oldTexts: old, newTexts: new).relocate(places)
            let position = try XCTUnwrap(outcome.places.position)
            XCTAssertEqual(TextPlace(chapter: position.chapterIndex, offset: position.characterOffset), start)
            XCTAssertEqual(position.globalCharacterOffset, 0)
            XCTAssertEqual(outcome.positionFinding, .movedByTheDiff(.startOfBook))
            let bookmark = try XCTUnwrap(outcome.places.bookmarks.first)
            XCTAssertEqual(TextPlace(chapter: bookmark.chapterIndex, offset: bookmark.characterOffset),
                           try Phrase.place(of: "CHAPTER I.", inChapter: new.count - old.count, of: new))
        }
        let unchanged = PlaceRelocator(oldTexts: old, newTexts: old).relocate(places)
        XCTAssertEqual(unchanged.positionFinding, .unchanged)
        XCTAssertEqual(unchanged.places, places)
    }

    // MARK: - The Counts and the Log Line

    /// Each finding counts once in its kind; the debug log's line says the
    /// counts, and a waiting skip only when there is one.
    func testTheCountsAndTheLogLine() {
        var counts = PlaceRelocator.Counts()
        for finding: PlaceRelocator.Finding in [
            .unchanged, .movedByTheDiff(.linedUp), .movedByTheDiff(.endOfBook), .movedByTheDiff(.followedMovedText),
            .foundBySavedWords(.savedWords(score: 12)), .guessed(.diffUnsure), .guessed(.savedWords(.sameShare)),
        ] {
            counts.count(finding)
        }
        XCTAssertEqual(counts, PlaceRelocator.Counts(unchanged: 1, movedByTheDiff: 3, foundBySavedWords: 1, guessed: 2))
        XCTAssertEqual(counts.total, 7)
        XCTAssertTrue(counts.anythingMoved)
        XCTAssertEqual(counts.logLine(title: "The Mill at Hollins Ford"),
                       "PLACES_RELOCATED: The Mill at Hollins Ford: unchanged 1, moved by the diff 3, by the saved words 1, guessed 2")
        counts.count(nil)
        XCTAssertEqual(counts.logLine(title: "The Mill at Hollins Ford"),
                       "PLACES_RELOCATED: The Mill at Hollins Ford: unchanged 1, moved by the diff 3, by the saved words 1, guessed 2, waiting 1")
        XCTAssertFalse(PlaceRelocator.Counts(unchanged: 3).anythingMoved)
        XCTAssertFalse(PlaceRelocator.Counts().anythingMoved)
    }

    /// A book's places are counted as each was found.
    func testABooksPlacesAreCountedAsTheyWereFound() throws {
        let old = MillBook.chapters
        let new = [MillBook.millrace, MillBook.wheel, MillBook.flour]
        let early = try Phrase.place(of: "spirit level", inChapter: 0, of: old)
        let removed = try Phrase.place(of: "photograph", inChapter: 2, of: old)
        let late = try Phrase.place(of: "paving slabs", inChapter: 3, of: old)
        let outcome = PlaceRelocator(oldTexts: old, newTexts: new, newHeadings: MillBook.headings(of: new)).relocate(PlaceRelocator.Places(
            position: ReadingPosition(chapterIndex: 3, characterOffset: late.offset, anchor: try SavedPlace.anchor(at: late, in: old)),
            bookmarks: [
                Bookmark(number: 1, chapterIndex: 0, characterOffset: early.offset, anchor: try SavedPlace.anchor(at: early, in: old)),
                Bookmark(number: 2, chapterIndex: 2, characterOffset: removed.offset, anchor: try SavedPlace.anchor(at: removed, in: old)),
            ],
            skippedHeadings: [try SavedPlace.skip(of: try MillBook.heading(ofChapter: 2, in: old), in: old)]
        ))
        XCTAssertEqual(outcome.positionFinding, .movedByTheDiff(.linedUp))
        XCTAssertEqual(outcome.bookmarkFindings, [.unchanged, .movedByTheDiff(.passageRemoved)])
        XCTAssertEqual(outcome.skippedHeadingFindings, [nil])
        XCTAssertEqual(outcome.counts, PlaceRelocator.Counts(unchanged: 1, movedByTheDiff: 2, waiting: 1))
        XCTAssertEqual(outcome.places.position?.chapterIndex, 2, "chapter IV is the third chapter now")
        XCTAssertEqual(outcome.places.bookmarks.last.map { TextPlace(chapter: $0.chapterIndex, offset: $0.characterOffset) }, TextPlace(chapter: 2, offset: 0))
    }
}
