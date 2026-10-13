import XCTest
@testable import TextMouth

/// Moving skipped headings from a book's old text to its new one (T06,
/// `PlaceRelocator.relocate(_:)` for a `SkippedHeading`): a skip is found in
/// the old text by its ID or its label, never by words read at stale
/// numbers; it follows its heading and takes its new label or level when
/// the diff's account of the new heading's own words proves it the same
/// section; and it waits, applying to no heading, rather than skip another
/// section when its own is gone, replaced, or only another section's
/// words remain where it was. Pure: no window, no file.
final class PlaceRelocatorHeadingTests: XCTestCase {

    // MARK: - Helpers

    /// Where a skip of `heading`, saved in the book `old` with its words
    /// captured there, goes in the book `new`, by a relocator that has both
    /// texts' headings.
    private func relocate(
        _ heading: Heading,
        from old: [String], oldHeadings: [Heading],
        to new: [String], newHeadings: [Heading],
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> PlaceRelocator.HeadingResult? {
        let skipped = try SavedPlace.skip(of: heading, in: old, file: file, line: line)
        return PlaceRelocator(oldTexts: old, newTexts: new, oldHeadings: oldHeadings, newHeadings: newHeadings).relocate(skipped)
    }

    /// The item at `index` of `items`, or a test failure: a subscript that
    /// cannot trap.
    private func item<Item>(_ items: [Item], _ index: Int, file: StaticString = #filePath, line: UInt = #line) throws -> Item {
        try XCTUnwrap(items.indices.contains(index) ? items[index] : nil, "no item \(index)", file: file, line: line)
    }

    /// A level-2 heading labelled `label` starting at `phrase` in chapter
    /// `chapter` of `texts`.
    private func section(_ label: String, at phrase: String, inChapter chapter: Int = 0, of texts: [String], occurrence: Int = 0,
                         file: StaticString = #filePath, line: UInt = #line) throws -> Heading {
        let place = try Phrase.place(of: phrase, inChapter: chapter, of: texts, occurrence: occurrence, file: file, line: line)
        return Heading(level: 2, text: label, chapterIndex: chapter, characterOffset: place.offset)
    }

    // MARK: - Reading the Headings

    /// A relocator reads a loaded book's old and new headings: skipped
    /// headings are found among the old and moved among the new.
    func testARelocatorReadsALoadedBooksHeadings() {
        let loaded = { (texts: [String]) in
            DocumentContent(title: "The Mill", author: "The Mill Society", chapters: texts.enumerated().map { index, text in
                Chapter(title: "", text: text, headings: MillBook.headings(of: texts).filter { $0.chapterIndex == index })
            })
        }
        let relocator = PlaceRelocator(old: loaded(MillBook.chapters), new: loaded([MillBook.millrace, MillBook.flour]))
        XCTAssertEqual(relocator.oldHeadings.map(\.text), MillBook.headings(of: MillBook.chapters).map(\.text))
        XCTAssertEqual(relocator.newHeadings.map(\.text), ["CHAPTER I. The Millrace", "CHAPTER IV. First Flour"])
    }

    /// A relocator built for places alone, with neither text's headings,
    /// lets every skip wait: without the old text's headings it could not
    /// tell another section from the skipped one, so it names none.
    func testARelocatorForPlacesAloneLetsEverySkipWait() throws {
        let mill = MillBook.chapters
        let skipped = try SavedPlace.skip(of: try MillBook.heading(ofChapter: 2, in: mill), in: mill)
        XCTAssertNil(PlaceRelocator(oldTexts: mill, newTexts: mill).relocate(skipped))
        let outcome = PlaceRelocator(old: BookWords(texts: mill), new: BookWords(texts: mill))
            .relocate(PlaceRelocator.Places(skippedHeadings: [skipped]), movedAt: SavedPlace.moveDate)
        XCTAssertEqual(outcome.places.waitingSkippedHeadings, [skipped])
        XCTAssertEqual(outcome.places.skippedHeadings, [])
        XCTAssertEqual(outcome.skippedHeadingFindings, [])
    }

    // MARK: - Following a Heading

    /// A skipped heading follows its heading and takes the label the new text
    /// gives it: alice.epub's "[]CHAPTER II." as 3.0.4 read it became
    /// "CHAPTER II. The Pool of Tears" on October 3.
    func testASkippedHeadingFollowsItsHeadingAndTakesItsNewLabel() throws {
        let old = [TextAnchorRealReadings.chapterOneOpening304, TextAnchorRealReadings.chapterTwoOpening304]
        let new = [TextAnchorRealReadings.chapterOneOpening307, TextAnchorRealReadings.chapterTwoOpening307]
        let oldHeadings = [Heading(level: 2, text: "[]CHAPTER I.", chapterIndex: 0, characterOffset: 0),
                           Heading(level: 2, text: "[]CHAPTER II.", chapterIndex: 1, characterOffset: 0)]
        let chapterOne = Heading(level: 2, text: "CHAPTER I. Down the Rabbit-Hole", chapterIndex: 0, characterOffset: 0)
        let chapterTwo = Heading(level: 2, text: "CHAPTER II. The Pool of Tears", chapterIndex: 1, characterOffset: 0)
        let result = try relocate(oldHeadings[1], from: old, oldHeadings: oldHeadings, to: new, newHeadings: [chapterOne, chapterTwo])
        XCTAssertEqual(result, PlaceRelocator.HeadingResult(heading: chapterTwo, finding: .movedByTheDiff(.linedUp)))
    }

    /// A heading whose first word the new text replaced, the rest standing,
    /// is the same heading relabelled, and keeps its skip.
    func testARelabelledHeadingKeepsItsSkip() throws {
        let old = MillBook.chapters
        let new = [MillBook.millrace, MillBook.wheel, MillBook.stones.replacingOccurrences(of: "CHAPTER III.", with: "PART III."), MillBook.flour]
        let relabelled = Heading(level: 1, text: "PART III. The Stones", chapterIndex: 2, characterOffset: 0)
        let result = try relocate(try MillBook.heading(ofChapter: 2, in: old), from: old, oldHeadings: MillBook.headings(of: old),
                                  to: new, newHeadings: MillBook.headings(of: new) + [relabelled])
        XCTAssertEqual(result, PlaceRelocator.HeadingResult(heading: relabelled, finding: .movedByTheDiff(.wordReplaced)))
    }

    /// A heading renumbered in place ("CHAPTER III." became "CHAPTER 3.")
    /// is the same heading, and keeps its skip.
    func testAHeadingRenumberedInPlaceKeepsItsSkip() throws {
        let old = MillBook.chapters
        let new = [MillBook.millrace, MillBook.wheel, MillBook.stones.replacingOccurrences(of: "CHAPTER III.", with: "CHAPTER 3."), MillBook.flour]
        let renumbered = try MillBook.heading(ofChapter: 2, in: new)
        XCTAssertEqual(renumbered.text, "CHAPTER 3. The Stones")
        let result = try relocate(try MillBook.heading(ofChapter: 2, in: old), from: old, oldHeadings: MillBook.headings(of: old),
                                  to: new, newHeadings: MillBook.headings(of: new))
        XCTAssertEqual(result, PlaceRelocator.HeadingResult(heading: renumbered, finding: .movedByTheDiff(.linedUp)))
    }

    /// A heading whose label gained words after it, or lost its first word,
    /// is the same section: most of its words went into the new label
    /// (REV15, finding 6). "Prologue" became "Prologue: Before the Spring
    /// Flood", and "CHAPTER III. The Stones" became "III. The Stones".
    func testAHeadingWhoseLabelGainedOrLostWordsKeepsItsSkip() throws {
        let opening = "CHAPTER I. The Millrace\n\nThe volunteers met at the mill on the first dry Saturday of March, with spades and a flask.\n\n"
        let body = "\n\nThe river rose in the night, and by morning the lower meadow was a lake with fence posts standing in it like herons."
        let old = [opening + "Prologue" + body]
        let new = [opening + "Prologue: Before the Spring Flood" + body]
        let prologue = try section("Prologue", at: "Prologue", of: old)
        let longer = try section("Prologue: Before the Spring Flood", at: "Prologue", of: new)
        XCTAssertEqual(try relocate(prologue, from: old, oldHeadings: [prologue], to: new, newHeadings: [longer]),
                       PlaceRelocator.HeadingResult(heading: longer, finding: .movedByTheDiff(.linedUp)))

        let mill = MillBook.chapters
        let dropped = [MillBook.millrace, MillBook.wheel, String(MillBook.stones.dropFirst("CHAPTER ".count)), MillBook.flour]
        let shorter = Heading(level: 1, text: "III. The Stones", chapterIndex: 2, characterOffset: 0)
        let result = try relocate(try MillBook.heading(ofChapter: 2, in: mill), from: mill, oldHeadings: MillBook.headings(of: mill),
                                  to: dropped, newHeadings: MillBook.headings(of: dropped) + [shorter])
        XCTAssertEqual(result?.heading, shorter)
        XCTAssertFalse(result?.finding.isGuess ?? true)
    }

    /// A heading relabelled outright ("Notes" became "Endnotes") over the
    /// same text keeps its skip: no word of its label stands, but its
    /// section goes on in the new heading.
    func testAHeadingRelabelledOutrightOverTheSameTextKeepsItsSkip() throws {
        let notes = "\n\nNotes\n\nThe pump belonged to the angling club and went back with a new washer."
        let old = [MillBook.millrace + notes, MillBook.wheel]
        let new = [MillBook.millrace + notes.replacingOccurrences(of: "Notes", with: "Endnotes"), MillBook.wheel]
        let oldNotes = try section("Notes", at: "Notes", of: old)
        let endnotes = try section("Endnotes", at: "Endnotes", of: new)
        let result = try relocate(oldNotes, from: old, oldHeadings: MillBook.headings(of: old) + [oldNotes], to: new, newHeadings: MillBook.headings(of: new) + [endnotes])
        XCTAssertEqual(result?.heading, endnotes)
        XCTAssertFalse(result?.finding.isGuess ?? true)
    }

    /// A heading re-levelled by a new reading (Edit Text's "##" became
    /// "###") keeps its skip at its new level (REV15, finding 10): the diff
    /// proves its text stands where its start lands. The skip never goes to
    /// another chapter's section of the same label and its old level; and
    /// when the new reading makes the heading plain text, the skip waits.
    func testAReLevelledHeadingKeepsItsSkipAtItsNewLevel() throws {
        let chain = "CHAPTER I. Chain and Offset\n\nA surveyor's chain is sixty-six feet long and divided into one hundred links, so that ten square chains make an acre.\n\n"
        let exercisesOne = "Exercises\n\nA hedge is chained at 12.40 chains; give its length in feet and in links."
        let level = "CHAPTER II. The Level and Staff\n\nThe dumpy level is set up on its tripod roughly midway between the two staff positions.\n\n"
        let exercisesTwo = "Exercises\n\nTake a backsight of 1.425 and a foresight of 2.110 and state whether the ground rises or falls."
        let old = [chain + exercisesOne, level + exercisesTwo]
        let new = [chain.replacingOccurrences(of: "sixty-six feet long", with: "sixty-six feet (about twenty metres) long") + exercisesOne, level + exercisesTwo]
        let oldOne = try section("Exercises", at: "Exercises", inChapter: 0, of: old)
        let oldTwo = try section("Exercises", at: "Exercises", inChapter: 1, of: old)
        let newOne = try section("Exercises", at: "Exercises", inChapter: 0, of: new)
        let newTwo = try section("Exercises", at: "Exercises", inChapter: 1, of: new)
        let levelThree = Heading(level: 3, text: newOne.text, chapterIndex: newOne.chapterIndex, characterOffset: newOne.characterOffset)
        let relevelled = try relocate(oldOne, from: old, oldHeadings: [oldOne, oldTwo], to: new, newHeadings: [levelThree, newTwo])
        XCTAssertEqual(relevelled, PlaceRelocator.HeadingResult(heading: levelThree, finding: .movedByTheDiff(.linedUp)))
        XCTAssertNil(try relocate(oldOne, from: old, oldHeadings: [oldOne, oldTwo], to: new, newHeadings: [newTwo]),
                     "made plain text, it waits rather than skip chapter II's exercises")
    }

    // MARK: - Found in the Old Text

    /// A skip saved without words (as every skip saved before T06 is,
    /// rebuilt from its ID) is found in the old text by the heading its
    /// label names there, never by the words read at its stale numbers
    /// (REV15, finding 3): with chapter III restored since "2-0-1-CHAPTER IV."
    /// was saved, the skip stays on chapter IV, not chapter III, which now
    /// has its numbers; "1-0-1-Contents", saved before a cover was dropped,
    /// stays on the contents. A stale skip whose label names nothing waits.
    func testASkipSavedWithoutWordsIsFoundByItsHeadingNotAtItsNumbers() throws {
        let mill = MillBook.chapters
        let headings = MillBook.headings(of: mill)
        let relocator = PlaceRelocator(oldTexts: mill, newTexts: mill, oldHeadings: headings, newHeadings: headings)
        let stale = SkippedHeading(level: 1, label: "CHAPTER IV. First Flour", chapterIndex: 2, characterOffset: 0)
        XCTAssertEqual(relocator.relocate(stale), PlaceRelocator.HeadingResult(heading: try MillBook.heading(ofChapter: 3, in: mill), finding: .movedByTheDiff(.linedUp)))
        XCTAssertNil(relocator.relocate(SkippedHeading(level: 1, label: "CHAPTER IX. The Fire", chapterIndex: 2, characterOffset: 0)))

        let contents = "Contents\n\nThe Millrace. The Wheel. The Stones. First Flour."
        let book = [contents] + mill
        let contentsHeading = Heading(level: 1, text: "Contents", chapterIndex: 0, characterOffset: 0)
        let bookHeadings = [contentsHeading] + MillBook.headings(of: book)
        let edited = [contents] + [MillBook.millrace.replacingOccurrences(of: "By noon", with: "By one o'clock")] + Array(mill.dropFirst())
        let contentsRelocator = PlaceRelocator(oldTexts: book, newTexts: edited, oldHeadings: bookHeadings, newHeadings: [contentsHeading] + MillBook.headings(of: edited))
        let result = contentsRelocator.relocate(SkippedHeading(level: 1, label: "Contents", chapterIndex: 1, characterOffset: 0))
        XCTAssertEqual(result?.heading, contentsHeading)
    }

    /// Of several old headings with a skip's level and label (a title page's
    /// lines printed again at the book's end), the one its saved words find
    /// for certain in the old text is its heading, though an older reading
    /// gave it other numbers.
    func testOfSeveralOldHeadingsWithItsLabelItsSavedWordsChoose() throws {
        let body = "It is a truth universally acknowledged that a mill in want of a wheel must be in want of a carpenter, and the volunteers found one."
        let older = ["PRIDE.\n\nCHISWICK PRESS.\n\n" + body + "\n\nTHE END\n\nCHISWICK PRESS."]
        let reading = ["PRIDE AND PREJUDICE\n\nCHISWICK PRESS.\n\n" + body + "\n\nTHE END\n\nCHISWICK PRESS."]
        let new = [reading[0].replacingOccurrences(of: "found one.", with: "found one in the valley.")]
        let presses = { (texts: [String]) throws -> [Heading] in
            let text = texts.first ?? ""
            return [Heading(level: 2, text: "CHISWICK PRESS.", chapterIndex: 0, characterOffset: try Phrase.offset(of: "CHISWICK", in: text)),
                    Heading(level: 2, text: "CHISWICK PRESS.", chapterIndex: 0, characterOffset: try Phrase.offset(of: "CHISWICK", in: text, occurrence: 1))]
        }
        let skipped = try SavedPlace.skip(of: try item(presses(older), 0), in: older)
        let relocator = PlaceRelocator(oldTexts: reading, newTexts: new, oldHeadings: try presses(reading), newHeadings: try presses(new))
        XCTAssertEqual(relocator.relocate(skipped)?.heading, try item(presses(new), 0))
    }

    // MARK: - Never Another Section

    /// A heading that lost a word to a heading left out before it keeps its
    /// skip: with chapter III left out, the diff lines its "CHAPTER" up with
    /// chapter IV's, but chapter IV's heading is still more like its own
    /// label than chapter III's.
    func testAHeadingThatLentAWordToOneLeftOutKeepsItsSkip() throws {
        let old = MillBook.chapters
        let new = [MillBook.millrace, MillBook.wheel, MillBook.flour]
        let result = try relocate(try MillBook.heading(ofChapter: 3, in: old), from: old, oldHeadings: MillBook.headings(of: old),
                                  to: new, newHeadings: MillBook.headings(of: new))
        XCTAssertEqual(result?.heading, try MillBook.heading(ofChapter: 2, in: new))
        XCTAssertFalse(result?.finding.isGuess ?? true)
    }

    /// A skipped chapter the new text leaves out is not carried to the next
    /// chapter, whose "CHAPTER" the diff lines up with the skipped one's:
    /// nothing names it, so the skip waits, and chapter IV plays.
    func testASkippedChapterLeftOutWaitsRatherThanSkipTheNext() throws {
        let old = MillBook.chapters
        let new = [MillBook.millrace, MillBook.wheel, MillBook.flour]
        XCTAssertNil(try relocate(try MillBook.heading(ofChapter: 2, in: old), from: old, oldHeadings: MillBook.headings(of: old),
                                  to: new, newHeadings: MillBook.headings(of: new)))
    }

    /// A skipped section the new text leaves out is not carried to the next
    /// section of its level, whose first word ("The") the diff lines up with
    /// the skipped heading's, though the words before the two now agree; and
    /// the skip still waits on the next rebuild, with the text unchanged or
    /// edited elsewhere (REV15, finding 1), when the old text no longer has
    /// its heading.
    func testASkippedSectionLeftOutWaitsOnEveryRebuild() throws {
        let opening = "CHAPTER I. The Millrace\n\nThe volunteers met at the mill on the first dry Saturday of March, with spades and a flask.\n\n"
        let pump = "The Pump\n\nThe borrowed pump ran on paraffin and had to be primed with a kettle of water every half hour.\n\n"
        let soup = "The Soup\n\nThe flask held leek and potato, poured into enamel mugs with the solemnity of a verger."
        let first = [opening + pump + soup]
        let second = [opening + soup]
        let third = [opening.replacingOccurrences(of: "dry Saturday", with: "dry, cold Saturday") + soup]
        let pumpHeading = try section("The Pump", at: "The Pump", of: first)
        let soupHeadings = { (texts: [String]) throws -> [Heading] in [try self.section("The Soup", at: "The Soup", of: texts)] }
        let skipped = try SavedPlace.skip(of: pumpHeading, in: first)
        let rebuilt = PlaceRelocator(oldTexts: first, newTexts: second, oldHeadings: [pumpHeading] + (try soupHeadings(first)), newHeadings: try soupHeadings(second))
            .relocate(PlaceRelocator.Places(skippedHeadings: [skipped]), movedAt: SavedPlace.moveDate)
        XCTAssertEqual(rebuilt.places.waitingSkippedHeadings, [skipped])
        XCTAssertEqual(rebuilt.places.skippedHeadings, [])
        XCTAssertEqual(rebuilt.skippedHeadingFindings, [])
        for (old, new) in [(second, second), (second, third)] {
            let again = PlaceRelocator(oldTexts: old, newTexts: new, oldHeadings: try soupHeadings(old), newHeadings: try soupHeadings(new))
            XCTAssertNil(again.relocate(skipped), "a later rebuild")
        }
    }

    /// A skipped section whose heading went with it, its first word paired
    /// with nothing, is not carried to the section that now begins where it
    /// was: the skip waits.
    func testASkippedSectionWhoseHeadingWentWithItWaits() throws {
        let notes = "\n\nNotes\n\nThe pump belonged to the angling club and went back with a new washer."
        let sources = "\n\nSources\n\nThe parish magazine for April, and the notebook Nell kept in her apron pocket."
        let old = [MillBook.millrace + notes + sources, MillBook.wheel]
        let new = [MillBook.millrace + sources, MillBook.wheel]
        let notesHeading = try section("Notes", at: "Notes", of: old)
        let oldSources = try section("Sources", at: "Sources", of: old)
        let newSources = try section("Sources", at: "Sources", of: new)
        XCTAssertNil(try relocate(notesHeading, from: old, oldHeadings: MillBook.headings(of: old) + [notesHeading, oldSources],
                                  to: new, newHeadings: MillBook.headings(of: new) + [newSources]))
    }

    /// Another chapter's section of the same label does not take a skip
    /// whose section the new text left out (REV15, finding 4): chapter I's
    /// "Notes" is skipped and removed, and chapter II's "Notes", whose words
    /// the diff lines up with chapter II's own, plays, whether it is the only
    /// other "Notes" or one of two.
    func testAnotherChaptersSectionOfTheSameLabelDoesNotTakeASkip() throws {
        let notes = [
            "\n\nNotes\n\nThe pump belonged to the angling club and went back with a new washer.",
            "\n\nNotes\n\nThe carpenter's spoons are now in the county museum, in a case by the door.",
            "\n\nNotes\n\nThe millstone was lifted out of the clay by a borrowed tractor and two planks.",
        ]
        for count in [2, 3] {
            let chapters = Array(MillBook.chapters.prefix(count))
            let old = zip(chapters, notes).map { $0 + $1 }
            let new = [try item(chapters, 0)] + Array(old.dropFirst())
            let oldNotes = try (0..<count).map { try section("Notes", at: "Notes", inChapter: $0, of: old) }
            let newNotes = try (1..<count).map { try section("Notes", at: "Notes", inChapter: $0, of: new) }
            XCTAssertNil(try relocate(try item(oldNotes, 0), from: old, oldHeadings: MillBook.headings(of: old) + oldNotes,
                                      to: new, newHeadings: MillBook.headings(of: new) + newNotes), "\(count) chapters")
        }
    }

    /// A section of a common label left out does not pass its skip to the
    /// next section of that label, which slid into its numbers, though the
    /// diff lines the two headings' words up (REV15, V21): the next one's
    /// section goes on in the heading, so it is that one's, and the skip
    /// waits. The next one's own skip follows it there.
    func testASectionSlidIntoARemovedOnesNumbersIsTheSecondsNotTheFirsts() throws {
        let opening = "CHAPTER I. The Millrace\n\nThe volunteers met at the mill on the first dry Saturday of March, with spades and a flask.\n\n"
        let first = "Notes\n\nThe pump belonged to the angling club and went back with a new washer.\n\n"
        let second = "Notes\n\nA carpenter in the next village turned the offcuts into spoons for the market."
        let old = [opening + first + second]
        let new = [opening + second]
        let firstNotes = Heading(level: 2, text: "Notes", chapterIndex: 0, characterOffset: opening.utf16.count)
        let secondNotes = Heading(level: 2, text: "Notes", chapterIndex: 0, characterOffset: opening.utf16.count + first.utf16.count)
        let newNotes = Heading(level: 2, text: "Notes", chapterIndex: 0, characterOffset: opening.utf16.count)
        XCTAssertNil(try relocate(firstNotes, from: old, oldHeadings: [firstNotes, secondNotes], to: new, newHeadings: [newNotes]))
        let followed = try relocate(secondNotes, from: old, oldHeadings: [firstNotes, secondNotes], to: new, newHeadings: [newNotes])
        XCTAssertEqual(followed?.heading, newNotes)
        XCTAssertFalse(followed?.finding.isGuess ?? true)
    }

    /// A section replaced by another, longer or about as long, does not pass
    /// its skip to the section that replaced it (REV15, finding 5): its
    /// start is where what replaced it begins, but nothing of the new
    /// heading's words came from the skipped one's.
    func testASectionReplacedByAnotherWaits() throws {
        let opening = "CHAPTER I. The Millrace\n\nThe volunteers met at the mill on the first dry Saturday of March, with spades and a flask.\n\n"
        let pump = "Pump Repairs\n\nThe borrowed pump ran on paraffin and had to be primed with a kettle of water every half hour.\n\n"
        let soup = "The Soup\n\nThe flask held leek and potato, poured into enamel mugs with the solemnity of a verger."
        let forge = "Forge Work\n\nA blacksmith in Ludlow lent them a portable forge, whose leather lungs wheezed like a church harmonium on a damp Sunday morning. "
            + "He showed them how to draw out a bar, upset its end, and punch a hole while the iron glowed cherry red. "
            + "Nobody dared ask the forge's age, and nobody asked where the coke had come from either.\n\n"
        let bellows = "Bellows\n\nA blacksmith in Ludlow lent them a forge, whose lungs wheezed like a harmonium.\n\n"
        let old = [opening + pump + soup]
        let pumpHeading = try section("Pump Repairs", at: "Pump Repairs", of: old)
        let oldSoup = try section("The Soup", at: "The Soup", of: old)
        for (replacement, label) in [(forge, "Forge Work"), (bellows, "Bellows")] {
            let new = [opening + replacement + soup]
            let newHeadings = [try section(label, at: label, of: new), try section("The Soup", at: "The Soup", of: new)]
            XCTAssertNil(try relocate(pumpHeading, from: old, oldHeadings: [pumpHeading, oldSoup], to: new, newHeadings: newHeadings), label)
        }
    }

    /// A heading whose words came from another old heading's is another
    /// section, though some of its words came from the skipped one's (REV15,
    /// findings 6 and 7): a short dedication removed before chapter I; "BOOK
    /// ONE. CHAPTER II." removed before "BOOK ONE. CHAPTER III."; "Notes on
    /// the Pump" removed before "Notes on the Soup"; chapter III replaced by
    /// an interlude about as long. Each skip waits. And when chapter II comes
    /// back before "BOOK ONE. CHAPTER III.", III's skip stays on III.
    func testAHeadingWhoseWordsCameFromAnotherHeadingIsAnotherSection() throws {
        let dedication = "Dedication\n\nFor Nell, who kept the notebook.\n\n"
        let one = "CHAPTER I. The Millrace\n\nThe volunteers met at the mill on the first dry Saturday of March."
        let dedicated = [dedication + one]
        let undedicated = [one]
        let dedicationHeading = Heading(level: 1, text: "Dedication", chapterIndex: 0, characterOffset: 0)
        let chapterOne = { (texts: [String]) throws -> Heading in
            Heading(level: 1, text: "CHAPTER I. The Millrace", chapterIndex: 0, characterOffset: try Phrase.offset(of: "CHAPTER I.", in: texts.first ?? ""))
        }
        XCTAssertNil(try relocate(dedicationHeading, from: dedicated, oldHeadings: [dedicationHeading, try chapterOne(dedicated)],
                                  to: undedicated, newHeadings: [try chapterOne(undedicated)]), "the dedication")

        let bookOne = { (number: String, title: String, body: String) in "BOOK ONE. CHAPTER \(number). \(title)\n\n\(body)" }
        let press = bookOne("I", "The Press", "The shop on Tanner Lane had printed handbills for forty years before Ottilie bought it.")
        let apprentice = bookOne("II", "The Apprentice", "Desmond arrived in March with a cardboard suitcase and a letter from the parish clerk.")
        let strike = bookOne("III", "The Strike", "When the dockers walked out in August, every union hall in the city wanted leaflets by morning.")
        let three = [press, apprentice, strike].joined(separator: "\n\n")
        let two = [press, strike].joined(separator: "\n\n")
        let headings = { (text: String) in
            ["I. The Press", "II. The Apprentice", "III. The Strike"].compactMap { label -> Heading? in
                let full = "BOOK ONE. CHAPTER " + label
                let offset = (text as NSString).range(of: full).location
                return offset == NSNotFound ? nil : Heading(level: 1, text: full, chapterIndex: 0, characterOffset: offset)
            }
        }
        XCTAssertNil(try relocate(try item(headings(three), 1), from: [three], oldHeadings: headings(three), to: [two], newHeadings: headings(two)),
                     "BOOK ONE. CHAPTER II.")
        let restored = try relocate(try item(headings(two), 1), from: [two], oldHeadings: headings(two), to: [three], newHeadings: headings(three))
        XCTAssertEqual(restored, PlaceRelocator.HeadingResult(heading: try item(headings(three), 2), finding: .movedByTheDiff(.linedUp)), "III with II restored")

        let opening = "CHAPTER I. The Millrace\n\nThe volunteers met at the mill on the first dry Saturday of March, with spades and a flask.\n\n"
        let pumpNotes = "Notes on the Pump\n\nThe borrowed pump ran on paraffin and had to be primed with a kettle of water every half hour.\n\n"
        let soupNotes = "Notes on the Soup\n\nThe flask held leek and potato, poured into enamel mugs with the solemnity of a verger."
        let withPump = [opening + pumpNotes + soupNotes]
        let withoutPump = [opening + soupNotes]
        let pumpHeading = try section("Notes on the Pump", at: "Notes on the Pump", of: withPump)
        XCTAssertNil(try relocate(pumpHeading, from: withPump, oldHeadings: [pumpHeading, try section("Notes on the Soup", at: "Notes on the Soup", of: withPump)],
                                  to: withoutPump, newHeadings: [try section("Notes on the Soup", at: "Notes on the Soup", of: withoutPump)]), "Notes on the Pump")

        let interlude = "INTERLUDE. A Letter\n\nNobody wrote back to the parish about the upper millstone. A letter from the war, kept in a biscuit tin, "
            + "mentioned both stones leaning against the granary wall.\n\nIn June the farmer above the weir wrote again: something rang under his plough, and he would like it moved."
        let mill = MillBook.chapters
        let replaced = [MillBook.millrace, MillBook.wheel, interlude, MillBook.flour]
        let interludeHeading = Heading(level: 1, text: "INTERLUDE. A Letter", chapterIndex: 2, characterOffset: 0)
        XCTAssertNil(try relocate(try MillBook.heading(ofChapter: 2, in: mill), from: mill, oldHeadings: MillBook.headings(of: mill),
                                  to: replaced, newHeadings: MillBook.headings(of: replaced) + [interludeHeading]), "chapter III replaced by an interlude")
    }

    // MARK: - Headings Without Words of Their Own

    /// A cover's skipped heading (a chapter without words, whose saved words
    /// hold none) is found by its label, not given to a title page put in
    /// where the cover was, nor to the next chapter's heading.
    func testACoversSkippedHeadingIsFoundByItsLabel() throws {
        let old = ["", MillBook.millrace]
        let new = ["The Mill at Hollins Ford\n\nA restoration diary", "", MillBook.millrace]
        let oldCover = Heading(level: 1, text: "Cover", chapterIndex: 0, characterOffset: 0)
        let cover = Heading(level: 1, text: "Cover", chapterIndex: 1, characterOffset: 0)
        let headings = [Heading(level: 1, text: "Title Page", chapterIndex: 0, characterOffset: 0), cover] + MillBook.headings(of: new)
        let result = try relocate(oldCover, from: old, oldHeadings: [oldCover] + MillBook.headings(of: old), to: new, newHeadings: headings)
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
        let oldAppendix = Heading(level: 1, text: "Appendix", chapterIndex: 0, characterOffset: MillBook.millrace.utf16.count)
        let appendix = Heading(level: 1, text: "Appendix", chapterIndex: 0, characterOffset: edited.utf16.count)
        let result = try relocate(oldAppendix, from: old, oldHeadings: MillBook.headings(of: old) + [oldAppendix], to: new, newHeadings: MillBook.headings(of: new) + [appendix])
        XCTAssertEqual(result, PlaceRelocator.HeadingResult(heading: appendix, finding: .foundBySavedWords(.onlyHeadingWithItsLabel)))
    }

    /// In a pile of headings that start before the same words (an omnibus's
    /// "Cover", "Title Page", and "Copyright", whose images leave no words),
    /// the label decides (REV15, finding 15): the skip of "Copyright" stays
    /// on "Copyright" when a word is added earlier in its chapter, so the
    /// copyright page is not read aloud.
    func testInAPileOfHeadingsTheLabelDecides() throws {
        let about = "About the Author\n\nThe author lives in a lakeside town and keeps a notebook of every heron she sees on the morning walk along the shore road.\n\n"
        let copyright = "SECOND HARBOUR BOOKS EDITION, MAY 2011\n\nThis edition is published by arrangement with the author. All rights reserved, and no part of it may be copied without written permission."
        let before = "Book One\n\nThe ferry left the island at dawn, and the families who had waited on the jetty all night carried their bundles down the slipway in silence."
        let pile = " \n\n"
        let old = [before, about + pile + copyright]
        let new = [before, about.replacingOccurrences(of: "keeps a notebook", with: "keeps a pocket notebook") + pile + copyright]
        let headings = { (texts: [String]) throws -> [Heading] in
            let text = texts.last ?? ""
            let cover = try Phrase.offset(of: pile, in: text)
            return [Heading(level: 1, text: "About the Author", chapterIndex: 1, characterOffset: 0),
                    Heading(level: 1, text: "Cover", chapterIndex: 1, characterOffset: cover),
                    Heading(level: 1, text: "Title Page", chapterIndex: 1, characterOffset: cover + 1),
                    Heading(level: 1, text: "Copyright", chapterIndex: 1, characterOffset: try Phrase.offset(of: "SECOND", in: text))]
        }
        let result = try relocate(try item(headings(old), 3), from: old, oldHeadings: try headings(old), to: new, newHeadings: try headings(new))
        XCTAssertEqual(result, PlaceRelocator.HeadingResult(heading: try item(headings(new), 3), finding: .movedByTheDiff(.linedUp)))
    }
}
