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
        let outcome = PlaceRelocator(oldTexts: book, newTexts: book, oldHeadings: MillBook.headings(of: book), newHeadings: MillBook.headings(of: book)).relocate(places, movedAt: SavedPlace.moveDate)
        XCTAssertEqual(outcome.places, places)
        XCTAssertEqual(outcome.positionFinding, .unchanged)
        XCTAssertEqual(outcome.bookmarkFindings, [.unchanged, .unchanged])
        XCTAssertEqual(outcome.skippedHeadingFindings, [.unchanged])
        XCTAssertEqual(outcome.counts, PlaceRelocator.Counts(unchanged: 4))
        XCTAssertFalse(outcome.counts.anythingMoved)
    }

    // MARK: - What a Moved Place Keeps

    /// A moved position takes its new chapter and offset, its offset across
    /// the whole book, and its words captured anew where it now is, and is
    /// dated at the move, so it wins over an older copy elsewhere (REV15,
    /// V22); its heading index stays. A position that stays where it was
    /// keeps its time, and still takes its new offset across the book when
    /// text before its chapter changed length.
    func testAMovedPositionTakesItsNewPlaceAndWordsAndIsDatedAtTheMove() throws {
        let old = MillBook.chapters
        let new = rained
        let oldWords = BookWords(texts: old)
        let newWords = BookWords(texts: new)
        let relocator = PlaceRelocator(old: oldWords, new: newWords)

        let saved = try Phrase.place(of: "spirit level", inChapter: 0, of: old)
        var position = ReadingPosition(chapterIndex: 0, headingIndex: 3, characterOffset: saved.offset, globalCharacterOffset: saved.offset,
                                       anchor: try SavedPlace.anchor(at: saved, in: old))
        position.lastUpdated = Date(timeIntervalSince1970: 1_000_000)
        let outcome = relocator.relocate(PlaceRelocator.Places(position: position), movedAt: SavedPlace.moveDate)
        let moved = try XCTUnwrap(outcome.places.position)
        let now = try Phrase.place(of: "spirit level", inChapter: 0, of: new)
        XCTAssertEqual(outcome.positionFinding, .movedByTheDiff(.linedUp))
        XCTAssertEqual(TextPlace(chapter: moved.chapterIndex, offset: moved.characterOffset), now)
        XCTAssertEqual(moved.globalCharacterOffset, now.offset)
        XCTAssertEqual(moved.anchor, TextAnchor(capturingAt: now, in: newWords))
        XCTAssertEqual(moved.lastUpdated, SavedPlace.moveDate)
        XCTAssertEqual(moved.headingIndex, 3)

        // A position in a later chapter keeps its numbers, and its offset
        // across the book grows with the text put in before its chapter.
        let later = try Phrase.place(of: "French burrs", inChapter: 2, of: old)
        var laterPosition = ReadingPosition(chapterIndex: 2, characterOffset: later.offset, globalCharacterOffset: oldWords.globalOffset(of: later),
                                            anchor: try SavedPlace.anchor(at: later, in: old))
        laterPosition.lastUpdated = Date(timeIntervalSince1970: 1_000_000)
        let stayed = relocator.relocate(PlaceRelocator.Places(position: laterPosition), movedAt: SavedPlace.moveDate)
        XCTAssertEqual(stayed.positionFinding, .unchanged)
        XCTAssertEqual(stayed.places.position?.lastUpdated, laterPosition.lastUpdated)
        XCTAssertEqual(stayed.places.position?.characterOffset, later.offset)
        XCTAssertEqual(stayed.places.position?.globalCharacterOffset, newWords.globalOffset(of: later))
        XCTAssertNotEqual(newWords.globalOffset(of: later), oldWords.globalOffset(of: later))
    }

    /// A position saved without an offset across the whole book gets none.
    func testAPositionWithoutAnOffsetAcrossTheBookGetsNone() throws {
        let saved = try Phrase.place(of: "spirit level", inChapter: 0, of: MillBook.chapters)
        let outcome = PlaceRelocator(oldTexts: MillBook.chapters, newTexts: rained)
            .relocate(PlaceRelocator.Places(position: ReadingPosition(chapterIndex: 0, characterOffset: saved.offset)), movedAt: SavedPlace.moveDate)
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
        let outcome = PlaceRelocator(oldTexts: old, newTexts: new).relocate(PlaceRelocator.Places(bookmarks: [bookmark]), movedAt: SavedPlace.moveDate)
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
            .relocate(PlaceRelocator.Places(skippedHeadings: [skipped]), movedAt: SavedPlace.moveDate)
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
        let outcome = PlaceRelocator(oldTexts: old, newTexts: new, oldHeadings: MillBook.headings(of: old), newHeadings: MillBook.headings(of: new))
            .relocate(PlaceRelocator.Places(skippedHeadings: [skipped]), movedAt: SavedPlace.moveDate)
        XCTAssertEqual(outcome.places.waitingSkippedHeadings, [skipped])
        XCTAssertEqual(outcome.places.skippedHeadings, [])
        XCTAssertEqual(outcome.skippedHeadingFindings, [])
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
            .relocate(PlaceRelocator.Places(skippedHeadings: [skipped]), movedAt: SavedPlace.moveDate)
        XCTAssertEqual(outcome.places.waitingSkippedHeadings, [skipped])
        XCTAssertEqual(outcome.places.skippedHeadings, [])
        XCTAssertEqual(outcome.skippedHeadingFindings, [])
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
        ), movedAt: SavedPlace.moveDate)
        XCTAssertEqual(outcome.skippedHeadingFindings, [.unchanged])
        XCTAssertEqual(outcome.places.skippedHeadings.map(\.id), [secondHeading.id])
        XCTAssertEqual(outcome.places.waitingSkippedHeadings.map(\.id), [firstHeading.id])
        XCTAssertEqual(outcome.counts, PlaceRelocator.Counts(unchanged: 1, waiting: 1))
    }

    /// A skip that names a heading wins over one that waits whose saved ID
    /// that heading now has, in either order (REV15, V21): the first "Notes"
    /// section is removed, its skip waits with its ID, and the second
    /// "Notes", skipped too, slides into the first one's numbers. Only the
    /// second skip is kept, and the findings and counts are those of the
    /// skips kept. Two skips that now name one heading are one.
    func testASkipThatNamesAHeadingWinsOverOneThatWaits() throws {
        let opening = "CHAPTER I. The Millrace\n\nThe volunteers met at the mill on the first dry Saturday of March, with spades and a flask.\n\n"
        let first = "Notes\n\nThe pump belonged to the angling club and went back with a new washer.\n\n"
        let second = "Notes\n\nA carpenter in the next village turned the offcuts into spoons for the market."
        let old = [opening + first + second]
        let new = [opening + second]
        let firstNotes = Heading(level: 2, text: "Notes", chapterIndex: 0, characterOffset: opening.utf16.count)
        let secondNotes = Heading(level: 2, text: "Notes", chapterIndex: 0, characterOffset: opening.utf16.count + first.utf16.count)
        let newNotes = Heading(level: 2, text: "Notes", chapterIndex: 0, characterOffset: opening.utf16.count)
        XCTAssertEqual(firstNotes.id, newNotes.id, "the second section slid into the first one's numbers")
        let relocator = PlaceRelocator(oldTexts: old, newTexts: new, oldHeadings: [firstNotes, secondNotes], newHeadings: [newNotes])
        let skips = [try SavedPlace.skip(of: firstNotes, in: old), try SavedPlace.skip(of: secondNotes, in: old)]
        XCTAssertNil(relocator.relocate(try XCTUnwrap(skips.first)), "the first section's skip waits")
        for order in [skips, skips.reversed()] {
            let outcome = relocator.relocate(PlaceRelocator.Places(skippedHeadings: order), movedAt: SavedPlace.moveDate)
            XCTAssertEqual(outcome.places.skippedHeadings, [try SavedPlace.skip(of: newNotes, in: new)])
            XCTAssertEqual(outcome.skippedHeadingFindings.count, 1)
            XCTAssertEqual(outcome.places.waitingSkippedHeadings, [])
            XCTAssertEqual(outcome.counts.total, 1)
            XCTAssertEqual(outcome.counts.waiting, 0)
        }
        // Two skips of one heading (saved under two readings' numbers) are one.
        let stale = SkippedHeading(level: 1, label: "CHAPTER IV. First Flour", chapterIndex: 2, characterOffset: 0)
        let mill = MillBook.chapters
        let current = try SavedPlace.skip(of: try MillBook.heading(ofChapter: 3, in: mill), in: mill)
        let headings = MillBook.headings(of: mill)
        let twice = PlaceRelocator(oldTexts: mill, newTexts: mill, oldHeadings: headings, newHeadings: headings)
            .relocate(PlaceRelocator.Places(skippedHeadings: [current, stale]), movedAt: SavedPlace.moveDate)
        XCTAssertEqual(twice.places.skippedHeadings, [current])
        XCTAssertEqual(twice.skippedHeadingFindings, [.unchanged])
        XCTAssertEqual(twice.counts, PlaceRelocator.Counts(unchanged: 1))
    }

    // MARK: - Skips That Wait

    /// One chapter with two "Notes" sections, as `testASkipThatNamesAHeadingWinsOverOneThatWaits`
    /// builds them: with the first removed, the second slides into its
    /// numbers, so the new heading has the first one's ID.
    private struct NotesBook {
        /// The chapter's opening, before the first "Notes".
        let opening = "CHAPTER I. The Millrace\n\nThe volunteers met at the mill on the first dry Saturday of March, with spades and a flask.\n\n"
        /// The first "Notes" section.
        let first = "Notes\n\nThe pump belonged to the angling club and went back with a new washer.\n\n"
        /// The second "Notes" section.
        let second = "Notes\n\nA carpenter in the next village turned the offcuts into spoons for the market."
        /// A sentence put in at the chapter's end, an edit elsewhere.
        let ending = " The spoons sold out by the autumn fair."

        /// The text with both sections.
        var both: [String] { [opening + first + second] }
        /// The text without the first section.
        var withoutFirst: [String] { [opening + second] }
        /// The text without the first section, with a sentence added at its end.
        var edited: [String] { [opening + second + ending] }
        /// The first "Notes" heading, in the text with both.
        var firstHeading: Heading { Heading(level: 2, text: "Notes", chapterIndex: 0, characterOffset: opening.utf16.count) }
        /// The second "Notes" heading, in the text with both.
        var secondHeading: Heading { Heading(level: 2, text: "Notes", chapterIndex: 0, characterOffset: opening.utf16.count + first.utf16.count) }
        /// The only "Notes" heading of the texts without the first section;
        /// it has the first heading's ID.
        var slidHeading: Heading { Heading(level: 2, text: "Notes", chapterIndex: 0, characterOffset: opening.utf16.count) }
    }

    /// A skip of the first "Notes" whose section is removed waits, naming no
    /// heading, though the second section slides into its numbers and so has
    /// its ID; and on the next move, from that text to one edited elsewhere,
    /// it still waits, unchanged, and still names nothing.
    func testASkipThatWaitsKeepsWaitingWhileTheNextSectionHasItsID() throws {
        let book = NotesBook()
        XCTAssertEqual(book.firstHeading.id, book.slidHeading.id, "the second section slid into the first one's numbers")
        let skip = try SavedPlace.skip(of: book.firstHeading, in: book.both)
        let first = PlaceRelocator(oldTexts: book.both, newTexts: book.withoutFirst, oldHeadings: [book.firstHeading, book.secondHeading], newHeadings: [book.slidHeading])
            .relocate(PlaceRelocator.Places(skippedHeadings: [skip]), movedAt: SavedPlace.moveDate)
        XCTAssertEqual(first.places.skippedHeadings, [])
        XCTAssertEqual(first.places.waitingSkippedHeadings, [skip])
        XCTAssertEqual(first.skippedHeadingFindings, [])
        XCTAssertEqual(first.counts, PlaceRelocator.Counts(waiting: 1))

        let second = PlaceRelocator(oldTexts: book.withoutFirst, newTexts: book.edited, oldHeadings: [book.slidHeading], newHeadings: [book.slidHeading])
            .relocate(first.places, movedAt: SavedPlace.moveDate)
        XCTAssertEqual(second.places.skippedHeadings, [])
        XCTAssertEqual(second.places.waitingSkippedHeadings, [skip])
        XCTAssertEqual(second.skippedHeadingFindings, [])
        XCTAssertEqual(second.counts, PlaceRelocator.Counts(waiting: 1))
    }

    /// A waiting skip names its heading again when the section comes back
    /// where it was, its words standing as they were skipped: unchanged, with
    /// the heading's ID, and nothing waits.
    func testAWaitingSkipNamesItsHeadingWhenTheSectionComesBack() throws {
        let book = NotesBook()
        let skip = try SavedPlace.skip(of: book.firstHeading, in: book.both)
        let outcome = PlaceRelocator(oldTexts: book.withoutFirst, newTexts: book.both, oldHeadings: [book.slidHeading], newHeadings: [book.firstHeading, book.secondHeading])
            .relocate(PlaceRelocator.Places(waitingSkippedHeadings: [skip]), movedAt: SavedPlace.moveDate)
        XCTAssertEqual(outcome.places.skippedHeadings, [skip])
        XCTAssertEqual(outcome.places.skippedHeadings.first?.id, book.firstHeading.id)
        XCTAssertEqual(outcome.places.waitingSkippedHeadings, [])
        XCTAssertEqual(outcome.skippedHeadingFindings, [.unchanged])
        XCTAssertEqual(outcome.counts, PlaceRelocator.Counts(unchanged: 1))
    }

    /// A waiting skip without saved words never names a heading, though a new
    /// heading has its ID: nothing proves it is the same section. Nor does
    /// one whose saved words hold no word, which stand anywhere.
    func testAWaitingSkipWithoutSavedWordsKeepsWaiting() {
        let book = NotesBook()
        let heading = book.slidHeading
        let bare = SkippedHeading(level: heading.level, label: heading.text, chapterIndex: heading.chapterIndex, characterOffset: heading.characterOffset)
        var empty = bare
        empty.anchor = TextAnchor(before: "", after: "", fraction: 0)
        let relocator = PlaceRelocator(oldTexts: book.withoutFirst, newTexts: book.edited, oldHeadings: [heading], newHeadings: [heading])
        for waiting in [bare, empty] {
            XCTAssertEqual(waiting.id, heading.id)
            let outcome = relocator.relocate(PlaceRelocator.Places(waitingSkippedHeadings: [waiting]), movedAt: SavedPlace.moveDate)
            XCTAssertEqual(outcome.places.skippedHeadings, [])
            XCTAssertEqual(outcome.places.waitingSkippedHeadings, [waiting])
            XCTAssertEqual(outcome.counts, PlaceRelocator.Counts(waiting: 1))
        }
    }

    /// A waiting skip whose heading stands again and a named skip of the same
    /// heading are one skip, the named one, and nothing waits.
    func testANamedSkipWinsOverAWaitingSkipOfTheSameHeading() throws {
        let book = NotesBook()
        let skip = try SavedPlace.skip(of: book.firstHeading, in: book.both)
        let headings = [book.firstHeading, book.secondHeading]
        let outcome = PlaceRelocator(oldTexts: book.both, newTexts: book.both, oldHeadings: headings, newHeadings: headings)
            .relocate(PlaceRelocator.Places(skippedHeadings: [skip], waitingSkippedHeadings: [skip]), movedAt: SavedPlace.moveDate)
        XCTAssertEqual(outcome.places.skippedHeadings, [skip])
        XCTAssertEqual(outcome.places.waitingSkippedHeadings, [])
        XCTAssertEqual(outcome.skippedHeadingFindings, [.unchanged])
        XCTAssertEqual(outcome.counts, PlaceRelocator.Counts(unchanged: 1))
    }

    /// The places, the skips that wait among them, survive being saved and
    /// read back.
    func testPlacesSurviveEncodingAndDecoding() throws {
        let book = NotesBook()
        let texts = book.both
        let place = try Phrase.place(of: "spades", inChapter: 0, of: texts)
        var position = ReadingPosition(chapterIndex: 0, characterOffset: place.offset, globalCharacterOffset: place.offset, anchor: try SavedPlace.anchor(at: place, in: texts))
        position.lastUpdated = Date(timeIntervalSince1970: 1_000_000)
        let places = PlaceRelocator.Places(
            position: position,
            bookmarks: [
                Bookmark(number: 1, chapterIndex: 0, characterOffset: place.offset, label: "the spades", dateCreated: Date(timeIntervalSince1970: 2_000_000),
                         anchor: try SavedPlace.anchor(at: place, in: texts)),
                Bookmark(number: 2, chapterIndex: 0, characterOffset: 0, dateCreated: Date(timeIntervalSince1970: 2_000_000)),
            ],
            skippedHeadings: [try SavedPlace.skip(of: book.secondHeading, in: texts)],
            waitingSkippedHeadings: [try SavedPlace.skip(of: book.firstHeading, in: texts)]
        )
        let decoded = try JSONDecoder().decode(PlaceRelocator.Places.self, from: try JSONEncoder().encode(places))
        XCTAssertEqual(decoded, places)
    }

    // MARK: - Building a Relocator Only When a Place Moved

    /// A loaded book whose chapters' reading texts are `texts`, with
    /// `headings` (the mill book's by default).
    private func loaded(_ texts: [String], headings: [Heading]? = nil) -> DocumentContent {
        let all = headings ?? MillBook.headings(of: texts)
        return DocumentContent(title: "The Mill", author: "The Mill Society", chapters: texts.enumerated().map { index, text in
            Chapter(title: "", text: text, headings: all.filter { $0.chapterIndex == index })
        })
    }

    /// What moving `places` from the book `old` to the book `new` comes to by
    /// the static entry point, whether it read the old text, and what the
    /// full relocator makes of the same places.
    private func moving(_ places: PlaceRelocator.Places, from old: [String], to new: [String]) -> (outcome: PlaceRelocator.Outcome, oldWasRead: Bool, full: PlaceRelocator.Outcome) {
        var oldWasRead = false
        let outcome = PlaceRelocator.relocate(places, from: { oldWasRead = true; return loaded(old) }, to: loaded(new), movedAt: SavedPlace.moveDate)
        let full = PlaceRelocator(old: loaded(old), new: loaded(new)).relocate(places, movedAt: SavedPlace.moveDate)
        return (outcome, oldWasRead, full)
    }

    /// A position in chapter I (with its offset across the book), two
    /// bookmarks in chapters II and III, and a skip of chapter II's heading,
    /// each with its words from the mill book.
    private func placesInTheFirstThreeChapters() throws -> PlaceRelocator.Places {
        let book = MillBook.chapters
        let reading = try Phrase.place(of: "spirit level", inChapter: 0, of: book)
        let carpenter = try Phrase.place(of: "steaming each plank", inChapter: 1, of: book)
        let marked = try Phrase.place(of: "French burrs", inChapter: 2, of: book)
        var position = ReadingPosition(chapterIndex: 0, headingIndex: 1, characterOffset: reading.offset,
                                       globalCharacterOffset: BookWords(texts: book).globalOffset(of: reading), anchor: try SavedPlace.anchor(at: reading, in: book))
        position.lastUpdated = Date(timeIntervalSince1970: 1_000_000)
        return PlaceRelocator.Places(
            position: position,
            bookmarks: [
                Bookmark(number: 1, chapterIndex: 1, characterOffset: carpenter.offset, label: "the planks", anchor: try SavedPlace.anchor(at: carpenter, in: book)),
                Bookmark(number: 2, chapterIndex: 2, characterOffset: marked.offset, label: "the burrs", anchor: try SavedPlace.anchor(at: marked, in: book)),
            ],
            skippedHeadings: [try SavedPlace.skip(of: try MillBook.heading(ofChapter: 1, in: book), in: book)]
        )
    }

    /// When every place stands, the old text is not read, and the outcome is
    /// the full relocator's: a sentence added at the end of the last chapter
    /// moves nothing in the first three.
    func testWhenEveryPlaceStandsTheOldTextIsNotRead() throws {
        let places = try placesInTheFirstThreeChapters()
        let new = Array(MillBook.chapters.dropLast()) + [MillBook.flour + " The grandson was right, and they said so."]
        let result = moving(places, from: MillBook.chapters, to: new)
        XCTAssertFalse(result.oldWasRead)
        XCTAssertEqual(result.outcome, result.full)
        // Every place keeps its numbers (its words are captured anew, since
        // the book around them grew by a sentence).
        XCTAssertEqual(result.outcome.places.position?.characterOffset, places.position?.characterOffset)
        XCTAssertEqual(result.outcome.places.bookmarks.map(\.characterOffset), places.bookmarks.map(\.characterOffset))
        XCTAssertEqual(result.outcome.places.skippedHeadings.map(\.id), places.skippedHeadings.map(\.id))
        XCTAssertEqual(result.outcome.positionFinding, .unchanged)
        XCTAssertEqual(result.outcome.bookmarkFindings, [.unchanged, .unchanged])
        XCTAssertEqual(result.outcome.skippedHeadingFindings, [.unchanged])
        XCTAssertEqual(result.outcome.counts, PlaceRelocator.Counts(unchanged: 4))
    }

    /// A sentence added to an earlier chapter moves a position in a later
    /// one, which stands: its offset across the book is the new text's, grown
    /// by the sentence, and its date is unchanged.
    func testAPositionStandsWhenAnEarlierChapterGrew() throws {
        let sentence = " Rain stopped work on the second Tuesday."
        let old = MillBook.chapters
        let new = [MillBook.millrace + sentence] + Array(old.dropFirst())
        let saved = try Phrase.place(of: "French burrs", inChapter: 2, of: old)
        var position = ReadingPosition(chapterIndex: 2, characterOffset: saved.offset, globalCharacterOffset: BookWords(texts: old).globalOffset(of: saved),
                                       anchor: try SavedPlace.anchor(at: saved, in: old))
        position.lastUpdated = Date(timeIntervalSince1970: 1_000_000)
        let result = moving(PlaceRelocator.Places(position: position), from: old, to: new)
        let moved = try XCTUnwrap(result.outcome.places.position)
        XCTAssertFalse(result.oldWasRead)
        XCTAssertEqual(result.outcome.positionFinding, .unchanged)
        XCTAssertEqual(TextPlace(chapter: moved.chapterIndex, offset: moved.characterOffset), saved)
        XCTAssertEqual(moved.globalCharacterOffset, try XCTUnwrap(position.globalCharacterOffset) + sentence.utf16.count)
        XCTAssertEqual(moved.lastUpdated, position.lastUpdated)
        XCTAssertEqual(result.outcome, result.full)
    }

    /// A position at the end of the book stands while the text is unchanged,
    /// without the old text; with a sentence appended, the end is somewhere
    /// else, so the old text is read and the position goes to the new end.
    func testAPositionAtTheEndStandsOnlyWhileTheEndIsTheSame() throws {
        let old = MillBook.chapters
        let end = BookWords(texts: old).endPlace
        let position = ReadingPosition(chapterIndex: end.chapter, characterOffset: end.offset, globalCharacterOffset: BookWords(texts: old).totalLength,
                                       anchor: try SavedPlace.anchor(at: end, in: old))
        XCTAssertTrue(try XCTUnwrap(position.anchor).marksEndOfBook)
        let places = PlaceRelocator.Places(position: position)

        let same = moving(places, from: old, to: old)
        XCTAssertFalse(same.oldWasRead)
        XCTAssertEqual(same.outcome.positionFinding, .unchanged)
        XCTAssertEqual(same.outcome, same.full)

        let appended = Array(old.dropLast()) + [MillBook.flour + " The grandson was right, and they said so."]
        let grown = moving(places, from: old, to: appended)
        let newEnd = BookWords(texts: appended).endPlace
        let moved = try XCTUnwrap(grown.outcome.places.position)
        XCTAssertTrue(grown.oldWasRead)
        XCTAssertEqual(TextPlace(chapter: moved.chapterIndex, offset: moved.characterOffset), newEnd)
        XCTAssertEqual(grown.outcome.positionFinding, .movedByTheDiff(.endOfBook))
        XCTAssertEqual(grown.outcome, grown.full)
    }

    /// When one place does not stand (text put in before a bookmark), the old
    /// text is read, and the outcome is the full relocator's for all the
    /// places, those that stand among them.
    func testOnePlaceThatMovedReadsTheOldTextOnce() throws {
        let places = try placesInTheFirstThreeChapters()
        let old = MillBook.chapters
        let new = [old[0], old[1].replacingOccurrences(of: "steaming each plank", with: "Rain stopped that on the second Tuesday, steaming each plank")] + Array(old.dropFirst(2))
        var reads = 0
        let outcome = PlaceRelocator.relocate(places, from: { reads += 1; return loaded(old) }, to: loaded(new), movedAt: SavedPlace.moveDate)
        let full = PlaceRelocator(old: loaded(old), new: loaded(new)).relocate(places, movedAt: SavedPlace.moveDate)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(outcome, full)
        XCTAssertEqual(outcome.bookmarkFindings.first, .movedByTheDiff(.linedUp))
        XCTAssertEqual(outcome.positionFinding, .unchanged)
    }

    /// A place saved without words needs the old text to be read, so it does
    /// not stand; and a book with no places reads nothing.
    func testAPlaceWithoutWordsReadsTheOldTextAndNoPlacesReadNothing() throws {
        let old = MillBook.chapters
        let bare = PlaceRelocator.Places(bookmarks: [Bookmark(number: 1, chapterIndex: 0, characterOffset: 0)])
        let result = moving(bare, from: old, to: old)
        XCTAssertTrue(result.oldWasRead)
        XCTAssertEqual(result.outcome, result.full)

        let none = moving(PlaceRelocator.Places(), from: old, to: old)
        XCTAssertFalse(none.oldWasRead)
        XCTAssertEqual(none.outcome.places, PlaceRelocator.Places())
        XCTAssertEqual(none.outcome.counts, PlaceRelocator.Counts())
    }

    /// A waiting skip never stops the shortcut, and is named again by the
    /// waiting rule when its heading stands; a named skip whose heading does
    /// not stand reads the old text.
    func testWaitingSkipsNeverReadTheOldTextButNamedSkipsThatMovedDo() throws {
        let book = NotesBook()
        let skip = try SavedPlace.skip(of: book.firstHeading, in: book.both)
        var reads = 0
        let back = PlaceRelocator.relocate(
            PlaceRelocator.Places(waitingSkippedHeadings: [skip]),
            from: { reads += 1; return loaded(book.withoutFirst, headings: [book.slidHeading]) },
            to: loaded(book.both, headings: [book.firstHeading, book.secondHeading]),
            movedAt: SavedPlace.moveDate
        )
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(back.places.skippedHeadings, [skip])
        XCTAssertEqual(back.places.waitingSkippedHeadings, [])
        XCTAssertEqual(back.skippedHeadingFindings, [.unchanged])

        let named = PlaceRelocator.Places(skippedHeadings: [try SavedPlace.skip(of: try MillBook.heading(ofChapter: 2, in: MillBook.chapters), in: MillBook.chapters)])
        let result = moving(named, from: MillBook.chapters, to: [MillBook.millrace, MillBook.wheel, MillBook.flour])
        XCTAssertTrue(result.oldWasRead)
        XCTAssertEqual(result.outcome, result.full)
        XCTAssertEqual(result.outcome.places.waitingSkippedHeadings, named.skippedHeadings)
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
            let outcome = PlaceRelocator(oldTexts: old, newTexts: new).relocate(places, movedAt: SavedPlace.moveDate)
            let position = try XCTUnwrap(outcome.places.position)
            XCTAssertEqual(TextPlace(chapter: position.chapterIndex, offset: position.characterOffset), start)
            XCTAssertEqual(position.globalCharacterOffset, 0)
            XCTAssertEqual(outcome.positionFinding, .movedByTheDiff(.startOfBook))
            let bookmark = try XCTUnwrap(outcome.places.bookmarks.first)
            XCTAssertEqual(TextPlace(chapter: bookmark.chapterIndex, offset: bookmark.characterOffset),
                           try Phrase.place(of: "CHAPTER I.", inChapter: new.count - old.count, of: new))
        }
        let unchanged = PlaceRelocator(oldTexts: old, newTexts: old).relocate(places, movedAt: SavedPlace.moveDate)
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
        let outcome = PlaceRelocator(oldTexts: old, newTexts: new, oldHeadings: MillBook.headings(of: old), newHeadings: MillBook.headings(of: new)).relocate(PlaceRelocator.Places(
            position: ReadingPosition(chapterIndex: 3, characterOffset: late.offset, anchor: try SavedPlace.anchor(at: late, in: old)),
            bookmarks: [
                Bookmark(number: 1, chapterIndex: 0, characterOffset: early.offset, anchor: try SavedPlace.anchor(at: early, in: old)),
                Bookmark(number: 2, chapterIndex: 2, characterOffset: removed.offset, anchor: try SavedPlace.anchor(at: removed, in: old)),
            ],
            skippedHeadings: [try SavedPlace.skip(of: try MillBook.heading(ofChapter: 2, in: old), in: old)]
        ), movedAt: SavedPlace.moveDate)
        XCTAssertEqual(outcome.positionFinding, .movedByTheDiff(.linedUp))
        XCTAssertEqual(outcome.bookmarkFindings, [.unchanged, .movedByTheDiff(.passageRemoved)])
        XCTAssertEqual(outcome.skippedHeadingFindings, [])
        XCTAssertEqual(outcome.places.waitingSkippedHeadings.count, 1)
        XCTAssertEqual(outcome.counts, PlaceRelocator.Counts(unchanged: 1, movedByTheDiff: 2, waiting: 1))
        XCTAssertEqual(outcome.places.position?.chapterIndex, 2, "chapter IV is the third chapter now")
        XCTAssertEqual(outcome.places.bookmarks.last.map { TextPlace(chapter: $0.chapterIndex, offset: $0.characterOffset) }, TextPlace(chapter: 2, offset: 0))
    }
}
