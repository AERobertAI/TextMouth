import XCTest
@testable import TextMouth

/// Moving skipped headings from a book's old text to its new one (T06,
/// `PlaceRelocator.relocate(_:)` for a `SkippedHeading`): a skip follows its
/// heading and takes its new label, keeps it through a heading relabelled or
/// renumbered in place, is found by its label when its saved words hold
/// none, and waits, applying to no heading, rather than skip another
/// section when its own section is gone. Pure: no window, no file.
final class PlaceRelocatorHeadingTests: XCTestCase {

    // MARK: - Reading the Headings

    /// A relocator reads a loaded book's new headings, which skipped headings
    /// are moved among.
    func testARelocatorReadsALoadedBooksHeadings() {
        let loaded = { (texts: [String]) in
            DocumentContent(title: "The Mill", author: "The Mill Society", chapters: texts.enumerated().map { index, text in
                Chapter(title: "", text: text, headings: MillBook.headings(of: texts).filter { $0.chapterIndex == index })
            })
        }
        let relocator = PlaceRelocator(old: loaded(MillBook.chapters), new: loaded([MillBook.millrace, MillBook.flour]))
        XCTAssertEqual(relocator.newHeadings.map(\.text), ["CHAPTER I. The Millrace", "CHAPTER IV. First Flour"])
    }

    // MARK: - Following a Heading

    /// A skipped heading follows its heading and takes the label the new text
    /// gives it: alice.epub's "[]CHAPTER II." as 3.0.4 read it became
    /// "CHAPTER II. The Pool of Tears" on October 3.
    func testASkippedHeadingFollowsItsHeadingAndTakesItsNewLabel() throws {
        let old = [TextAnchorRealReadings.chapterOneOpening304, TextAnchorRealReadings.chapterTwoOpening304]
        let new = [TextAnchorRealReadings.chapterOneOpening307, TextAnchorRealReadings.chapterTwoOpening307]
        let chapterOne = Heading(level: 2, text: "CHAPTER I. Down the Rabbit-Hole", chapterIndex: 0, characterOffset: 0)
        let chapterTwo = Heading(level: 2, text: "CHAPTER II. The Pool of Tears", chapterIndex: 1, characterOffset: 0)
        let skipped = try SavedPlace.skip(of: Heading(level: 2, text: "[]CHAPTER II.", chapterIndex: 1, characterOffset: 0), in: old)
        let result = PlaceRelocator(oldTexts: old, newTexts: new, newHeadings: [chapterOne, chapterTwo]).relocate(skipped)
        XCTAssertEqual(result, PlaceRelocator.HeadingResult(heading: chapterTwo, finding: .movedByTheDiff(.linedUp)))
    }

    /// A heading whose first word the new text replaced, the rest standing,
    /// is the same heading relabelled, and keeps its skip.
    func testARelabelledHeadingKeepsItsSkip() throws {
        let old = MillBook.chapters
        let new = [MillBook.millrace, MillBook.wheel, MillBook.stones.replacingOccurrences(of: "CHAPTER III.", with: "PART III."), MillBook.flour]
        let relabelled = Heading(level: 1, text: "PART III. The Stones", chapterIndex: 2, characterOffset: 0)
        let skipped = try SavedPlace.skip(of: try MillBook.heading(ofChapter: 2, in: old), in: old)
        let result = PlaceRelocator(oldTexts: old, newTexts: new, newHeadings: MillBook.headings(of: new) + [relabelled]).relocate(skipped)
        XCTAssertEqual(result, PlaceRelocator.HeadingResult(heading: relabelled, finding: .movedByTheDiff(.wordReplaced)))
    }

    /// A heading renumbered in place ("CHAPTER III." became "CHAPTER 3."):
    /// its first word lines up, the word after it was replaced in place, and
    /// the rest stands, so it is the same heading and keeps its skip.
    func testAHeadingRenumberedInPlaceKeepsItsSkip() throws {
        let old = MillBook.chapters
        let new = [MillBook.millrace, MillBook.wheel, MillBook.stones.replacingOccurrences(of: "CHAPTER III.", with: "CHAPTER 3."), MillBook.flour]
        let renumbered = try MillBook.heading(ofChapter: 2, in: new)
        XCTAssertEqual(renumbered.text, "CHAPTER 3. The Stones")
        let skipped = try SavedPlace.skip(of: try MillBook.heading(ofChapter: 2, in: old), in: old)
        let result = PlaceRelocator(oldTexts: old, newTexts: new, newHeadings: MillBook.headings(of: new)).relocate(skipped)
        XCTAssertEqual(result, PlaceRelocator.HeadingResult(heading: renumbered, finding: .movedByTheDiff(.linedUp)))
    }

    // MARK: - Never Another Section

    /// A skipped chapter the new text leaves out is not carried to the next
    /// chapter, whose "CHAPTER" the diff lines up with the skipped one's:
    /// nothing names it, so the skip waits, and chapter IV plays.
    func testASkippedChapterLeftOutWaitsRatherThanSkipTheNext() throws {
        let old = MillBook.chapters
        let new = [MillBook.millrace, MillBook.wheel, MillBook.flour]
        let skipped = try SavedPlace.skip(of: try MillBook.heading(ofChapter: 2, in: old), in: old)
        XCTAssertNil(PlaceRelocator(oldTexts: old, newTexts: new, newHeadings: MillBook.headings(of: new)).relocate(skipped))
    }

    /// A skipped section the new text leaves out is not carried to the next
    /// section of its level, whose first word ("The") the diff lines up with
    /// the skipped heading's, though the words before the two now agree: only
    /// a heading with the skipped one's label could still be it, and none is,
    /// so the skip waits.
    func testASkippedSectionLeftOutWaitsRatherThanSkipTheNext() throws {
        let opening = "CHAPTER I. The Millrace\n\nThe volunteers met at the mill on the first dry Saturday of March, with spades and a flask.\n\n"
        let pump = "The Pump\n\nThe borrowed pump ran on paraffin and had to be primed with a kettle of water every half hour.\n\n"
        let soup = "The Soup\n\nThe flask held leek and potato, poured into enamel mugs with the solemnity of a verger."
        let old = [opening + pump + soup]
        let new = [opening + soup]
        let pumpHeading = Heading(level: 2, text: "The Pump", chapterIndex: 0, characterOffset: opening.utf16.count)
        let soupHeading = Heading(level: 2, text: "The Soup", chapterIndex: 0, characterOffset: opening.utf16.count)
        let skipped = try SavedPlace.skip(of: pumpHeading, in: old)
        // The saved words alone would name the soup's heading, by the words
        // before both; with the old text, the pump's section is known gone.
        let anchor = try XCTUnwrap(skipped.anchor)
        let saved = TextPlace(chapter: 0, offset: pumpHeading.characterOffset)
        XCTAssertNotNil(TextAnchorFinder(texts: new, headings: [soupHeading]).findHeading(level: 2, label: "The Pump", anchor: anchor, savedAt: saved))
        XCTAssertNil(PlaceRelocator(oldTexts: old, newTexts: new, newHeadings: [soupHeading]).relocate(skipped))
    }

    /// A skipped section whose heading went with it, its first word paired
    /// with nothing, is not carried to the section that now begins where it
    /// was: the skip waits.
    func testASkippedSectionWhoseHeadingWentWithItWaits() throws {
        let notes = "\n\nNotes\n\nThe pump belonged to the angling club and went back with a new washer."
        let sources = "\n\nSources\n\nThe parish magazine for April, and the notebook Nell kept in her apron pocket."
        let old = [MillBook.millrace + notes + sources, MillBook.wheel]
        let new = [MillBook.millrace + sources, MillBook.wheel]
        let notesHeading = Heading(level: 2, text: "Notes", chapterIndex: 0, characterOffset: MillBook.millrace.utf16.count + 2)
        let sourcesHeading = Heading(level: 2, text: "Sources", chapterIndex: 0, characterOffset: MillBook.millrace.utf16.count + 2)
        let skipped = try SavedPlace.skip(of: notesHeading, in: old)
        let anchor = try XCTUnwrap(skipped.anchor)
        let saved = TextPlace(chapter: 0, offset: notesHeading.characterOffset)
        XCTAssertNotNil(TextAnchorFinder(texts: new, headings: [sourcesHeading]).findHeading(level: 2, label: "Notes", anchor: anchor, savedAt: saved),
                        "the saved words alone would name the sources")
        XCTAssertNil(PlaceRelocator(oldTexts: old, newTexts: new, newHeadings: MillBook.headings(of: new) + [sourcesHeading]).relocate(skipped))
    }

    // MARK: - Headings Without Words After Them

    /// A cover's skipped heading (a chapter without words, whose saved words
    /// hold none) is found by its label, not given to a title page put in
    /// where the cover was, nor to the next chapter's heading.
    func testACoversSkippedHeadingIsFoundByItsLabel() throws {
        let old = ["", MillBook.millrace]
        let new = ["The Mill at Hollins Ford\n\nA restoration diary", "", MillBook.millrace]
        let cover = Heading(level: 1, text: "Cover", chapterIndex: 1, characterOffset: 0)
        let headings = [Heading(level: 1, text: "Title Page", chapterIndex: 0, characterOffset: 0), cover] + MillBook.headings(of: new)
        let skipped = try SavedPlace.skip(of: Heading(level: 1, text: "Cover", chapterIndex: 0, characterOffset: 0), in: old)
        let result = PlaceRelocator(oldTexts: old, newTexts: new, newHeadings: headings).relocate(skipped)
        XCTAssertEqual(result, PlaceRelocator.HeadingResult(heading: cover, finding: .foundBySavedWords(.onlyHeadingWithItsLabel)))
    }

    /// A heading with no word after its start in its chapter (one whose
    /// label is not read, at the chapter's end) is not carried into the next
    /// chapter, whose heading of the same level the diff would land on: its
    /// label finds it.
    func testAHeadingWithNoWordAfterItInItsChapterStaysInItsChapter() throws {
        let edited = MillBook.millrace.replacingOccurrences(of: "lost by teatime", with: "lost before teatime")
        let old = [MillBook.millrace, MillBook.wheel]
        let new = [edited, MillBook.wheel]
        let appendix = Heading(level: 1, text: "Appendix", chapterIndex: 0, characterOffset: edited.utf16.count)
        let skipped = try SavedPlace.skip(of: Heading(level: 1, text: "Appendix", chapterIndex: 0, characterOffset: MillBook.millrace.utf16.count), in: old)
        let result = PlaceRelocator(oldTexts: old, newTexts: new, newHeadings: MillBook.headings(of: new) + [appendix]).relocate(skipped)
        XCTAssertEqual(result, PlaceRelocator.HeadingResult(heading: appendix, finding: .foundBySavedWords(.onlyHeadingWithItsLabel)))
    }
}
