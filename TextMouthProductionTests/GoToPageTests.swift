import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// Go to Page… and the page on the reader screen (PG03): the field's answer
/// for a page typed as the book numbers it, what it refuses, the jump and
/// what VoiceOver hears, the field's own accessibility, the page button on
/// the status row, and the setting that shows or hides it. Pure
/// (`makePagedReader` readers), except the hosted checks, which draw the
/// panel and the status row offscreen in a fixed frame, and the jumps made
/// while a book plays, whose speech goes to a recorder, never to the
/// synthesizer.
@MainActor
final class GoToPageTests: XCTestCase {

    // MARK: - Fixtures

    /// Pages i, ii, 1, 2, 2, and 300 (indices 0 to 5): the front matter
    /// numbered in Roman numerals, a label used twice, and a last page that
    /// sets the book's total. The first four are in chapter 0 (200
    /// characters), the others in chapter 1 (100).
    private static let sixPages = [
        PageBreak(label: "i", chapterIndex: 0, characterOffset: 0),
        PageBreak(label: "ii", chapterIndex: 0, characterOffset: 50),
        PageBreak(label: "1", chapterIndex: 0, characterOffset: 100),
        PageBreak(label: "2", chapterIndex: 0, characterOffset: 150),
        PageBreak(label: "2", chapterIndex: 1, characterOffset: 0),
        PageBreak(label: "300", chapterIndex: 1, characterOffset: 50),
    ]

    /// A book's one page, at its start.
    private static let onePage = [PageBreak(label: "1", chapterIndex: 0, characterOffset: 0)]

    /// Pages 11, 12, and 300 in chapter 0, so a place at offset 60 is on
    /// "Page 12 of 300".
    private static let pagesAroundTwelve = [
        PageBreak(label: "11", chapterIndex: 0, characterOffset: 0),
        PageBreak(label: "12", chapterIndex: 0, characterOffset: 50),
        PageBreak(label: "300", chapterIndex: 0, characterOffset: 100),
    ]

    // MARK: - The Validator

    /// The index `JumpInputValidator.page` gives for `text`, or its
    /// refusal, over `sixPages`.
    private func answer(_ text: String, from current: Int? = nil) -> JumpInputValidator.PageResult {
        JumpInputValidator.page(text, in: BookPages(breaks: Self.sixPages), currentIndex: current)
    }

    /// An empty field, or one of spaces, is refused with the sentence that
    /// asks for a number.
    func testAnEmptyFieldIsRefused() {
        XCTAssertEqual(answer(""), .error("Type a page number."))
        XCTAssertEqual(answer("  "), .error("Type a page number."))
        XCTAssertEqual(answer(" \n "), .error("Type a page number."))
    }

    /// A label is matched ignoring case and the spaces around it.
    func testALabelIsMatchedIgnoringCaseAndSpaces() {
        XCTAssertEqual(answer("II"), .page(1))
        XCTAssertEqual(answer("ii"), .page(1))
        XCTAssertEqual(answer(" 300 "), .page(5))
        XCTAssertEqual(answer("I"), .page(0))
    }

    /// A label used by two pages is taken at its first page after the
    /// current one, and wraps to its first in the book.
    func testALabelUsedTwiceReachesTheNextOneAndWraps() {
        XCTAssertEqual(answer("2", from: nil), .page(3))
        XCTAssertEqual(answer("2", from: 3), .page(4))
        XCTAssertEqual(answer("2", from: 4), .page(3))
    }

    /// A page the book does not have is refused with the book's first and
    /// last pages, and a one-page book says its only page.
    func testAPageTheBookLacksIsRefusedWithTheRange() {
        XCTAssertEqual(
            answer("400"),
            .error("There is no page 400 in this book. Its pages run from i to 300.")
        )
        let single = BookPages(breaks: [PageBreak(label: "1", chapterIndex: 0, characterOffset: 0)])
        XCTAssertEqual(
            JumpInputValidator.page("5", in: single, currentIndex: nil),
            .error("There is no page 5 in this book. Its only page is 1.")
        )
        XCTAssertEqual(
            JumpInputValidator.page("1", in: .none, currentIndex: nil),
            .error("This book has no pages.")
        )
    }

    /// The field's hint says how many pages the book has, the N of "Page 12
    /// of N", and its first and last pages' labels, before saying how to
    /// type one: for a book numbered i, ii, then 1 to 300, "This book has
    /// 300 pages, from i to 300." A book of one page names it, a book whose
    /// labels hold no number counts its pages, and a book without pages
    /// says so.
    func testTheFieldHintGivesTheBooksPages() {
        let typing = " Type a page as the book numbers it, such as 12 or xii."
        XCTAssertEqual(
            ReaderPageWording.fieldHint(for: BookPages(breaks: Self.sixPages)),
            "This book has 300 pages, from i to 300." + typing
        )
        XCTAssertEqual(
            ReaderPageWording.fieldHint(for: BookPages(breaks: [PageBreak(label: "1", chapterIndex: 0, characterOffset: 0)])),
            "This book's only page is 1." + typing
        )
        let lettered = ["A", "B", "C"].enumerated().map {
            PageBreak(label: $0.element, chapterIndex: 0, characterOffset: $0.offset * 10)
        }
        XCTAssertEqual(
            ReaderPageWording.fieldHint(for: BookPages(breaks: lettered)),
            "This book has 3 pages, from A to C." + typing
        )
        let oneNumbered = [
            PageBreak(label: "1", chapterIndex: 0, characterOffset: 0),
            PageBreak(label: "A", chapterIndex: 0, characterOffset: 10),
        ]
        XCTAssertEqual(
            ReaderPageWording.fieldHint(for: BookPages(breaks: oneNumbered)),
            "This book has 1 page, from 1 to A." + typing,
            "the count follows the N of \"Page A of 1\", in the singular"
        )
        XCTAssertEqual(ReaderPageWording.fieldHint(for: .none), "This book has no pages.")
    }

    /// The wording, pinned.
    func testTheWordsAreFixed() {
        XCTAssertEqual(ReaderPageWording.fieldLabel, "Page")
        XCTAssertEqual(ReaderPageWording.typingHint, "Type a page as the book numbers it, such as 12 or xii.")
        XCTAssertEqual(ReaderPageWording.emptyField, "Type a page number.")
        XCTAssertEqual(ReaderPageWording.jumped(to: "12"), "Jumped to page 12.")
        XCTAssertEqual(
            ReaderPageWording.jumped(to: "2", occurrence: 2),
            "Jumped to page 2, the second page labelled 2."
        )
        XCTAssertEqual(
            ReaderPageWording.hasNoWords("7", cursor: "on page 8"),
            "Page 7 has no words, so the cursor is on page 8."
        )
        XCTAssertEqual(
            ReaderPageWording.hasNoWords("3", occurrence: 1, cursor: "on the second page labelled 3"),
            "The first page labelled 3 has no words, so the cursor is on the second page labelled 3."
        )
        XCTAssertEqual(
            ReaderPageWording.isInSkippedSection("40", cursor: "on page 52"),
            "Page 40 is in a skipped section, so the cursor is on page 52."
        )
        XCTAssertEqual(
            ReaderPageWording.isInSkippedSection("2", occurrence: 2, cursor: "on page 3"),
            "The second page labelled 2 is in a skipped section, so the cursor is on page 3."
        )
        XCTAssertEqual(ReaderPageWording.cursorIs("on page 52"), "The cursor is on page 52.")
        XCTAssertEqual(ReaderPageWording.openHint, "Opens jump to page controls")
        XCTAssertEqual(ReaderPageWording.hideHint, "Hides jump to page controls")
        XCTAssertEqual(ReaderPageWording.switchHint, "Switches to jump to page controls")
        XCTAssertEqual(ReaderPageWording.settingSection, "Pages")
        XCTAssertEqual(ReaderPageWording.showInReaderTitle, "Show the page on the reader screen")
        XCTAssertEqual(
            ReaderPageWording.showInReaderHint,
            "Shows the page being read, such as Page 12 of 300, beside the percent, for books of more than one page."
        )
        XCTAssertEqual(ReaderPageWording.sayInWhereAmITitle, "Say the page in Where Am I?")
        XCTAssertEqual(
            ReaderPageWording.sayInWhereAmIHint,
            "Adds the page, such as Page 12 of 300, to Where Am I?'s summaries, for books with pages."
        )
    }

    /// Where the cursor is, as Go to Page's sentences say it: on a page, on
    /// one of the pages that carry a label, or before the first page, in the
    /// position's own words, as the status row says them.
    func testTheCursorsPlaceIsSaidAsTheRowNamesIt() {
        let pages = BookPages(breaks: Self.sixPages)
        XCTAssertEqual(ReaderPageWording.cursorPlace(PagePosition(pages: pages, index: 5)), "on page 300")
        XCTAssertEqual(
            ReaderPageWording.cursorPlace(PagePosition(pages: pages, index: 4), occurrence: 2),
            "on the second page labelled 2"
        )
        XCTAssertEqual(PagePosition(pages: pages, index: nil).label, "Before page i")
        XCTAssertEqual(ReaderPageWording.cursorPlace(PagePosition(pages: pages, index: nil)), "before page i")
    }

    // MARK: - The Reader's Answer

    /// Go to Page jumps to the page typed, keeps a Return position, says
    /// where it went, and returns nil.
    func testGoToPageJumpsKeepsAReturnPositionAndSaysSo() {
        let reader = makePagedReader(pages: Self.sixPages)
        defer { reader.close() }
        reader.currentChapterIndex = 0
        reader.currentCharacterOffset = 0

        XCTAssertNil(reader.goToPage(typed: "300"))

        XCTAssertEqual(pagedPlace(of: reader), "1:50")
        XCTAssertEqual(reader.lastAnnouncement, "Jumped to page 300.")
        reader.returnToSavedPosition()
        XCTAssertEqual(pagedPlace(of: reader), "0:0")
    }

    /// Go to Page says the page the status row names at the place it reaches,
    /// which is the last of the pages that begin there, and why it is not the
    /// page asked for: a blank page "7" shares its place with page "8", so
    /// asking for 7 lands where the row reads "Page 8", and "Jumped to page
    /// 7." would have told the listener a page the row, Where Am I?, and Next
    /// Page all deny. A page that begins alone is said as it is, whatever
    /// case it was typed in.
    func testGoToPageSaysThePageTheRowNames() {
        let pages = [
            PageBreak(label: "6", chapterIndex: 0, characterOffset: 0),
            PageBreak(label: "7", chapterIndex: 0, characterOffset: 100),
            PageBreak(label: "8", chapterIndex: 0, characterOffset: 100),
            PageBreak(label: "ix", chapterIndex: 1, characterOffset: 0),
        ]
        let reader = makePagedReader(pages: pages)
        defer { reader.close() }
        reader.currentChapterIndex = 0
        reader.currentCharacterOffset = 0

        XCTAssertNil(reader.goToPage(typed: "7"))
        XCTAssertEqual(pagedPlace(of: reader), "0:100")
        XCTAssertEqual(reader.currentPagePosition.page?.label, "8", "the row names the later page")
        XCTAssertEqual(reader.lastAnnouncement, "Page 7 has no words, so the cursor is on page 8.")

        // The later page itself, typed, is the same place and the same words.
        reader.lastAnnouncement = nil
        reader.currentCharacterOffset = 0
        XCTAssertNil(reader.goToPage(typed: "8"))
        XCTAssertEqual(reader.lastAnnouncement, "Jumped to page 8.")

        // A page that begins alone is said as the book labels it.
        XCTAssertNil(reader.goToPage(typed: "IX"))
        XCTAssertEqual(pagedPlace(of: reader), "1:0")
        XCTAssertEqual(reader.lastAnnouncement, "Jumped to page ix.")
        XCTAssertEqual(reader.currentPagePosition.page?.label, "ix")
    }

    /// The page said is read from where the reader stands after the jump,
    /// not worked out from the page typed: a page that begins after the
    /// book's last word (the chapter holds 100 characters, and page 9 begins
    /// at 100) is reached at the last word, where the row names the page
    /// before it, and that is the page said, with the reason the cursor is
    /// not on page 9. The sentence is pinned as it is spoken, and the page it
    /// names is the row's, checked on its own: the expected words are not
    /// taken from the row, which the code under test reads as well.
    func testGoToPageSaysThePageAtTheCursorWhereTheJumpStopsShort() {
        let pages = [
            PageBreak(label: "7", chapterIndex: 1, characterOffset: 0),
            PageBreak(label: "8", chapterIndex: 1, characterOffset: 50),
            PageBreak(label: "9", chapterIndex: 1, characterOffset: 100),
        ]
        let reader = makePagedReader(pages: pages)
        defer { reader.close() }
        reader.currentChapterIndex = 1
        reader.currentCharacterOffset = 0

        XCTAssertNil(reader.goToPage(typed: "9"))

        XCTAssertEqual(reader.currentChapterIndex, 1)
        XCTAssertEqual(reader.currentPagePosition.page?.label, "8", "the reader stands on page 8, whose words end the book")
        XCTAssertEqual(reader.lastAnnouncement, "Page 9 has no words, so the cursor is on page 8.")
    }

    /// The reason and the place go together: a blank page asked for, whose
    /// place the cursor shares with one of several pages of a label, is told
    /// as "Page 5 has no words, so the cursor is on the second page labelled
    /// 2." A blank page that shares a label with the page it is beside is
    /// told too, since it is another page, and named as which of them it
    /// is: "Page 3 has no words, so the cursor is on page 3, the second page
    /// labelled 3." denied the words of the page 3 the cursor was on. A page
    /// that has words, whatever its label, is told without a reason.
    func testTheReasonNamesWhichPageOfASharedLabelTheCursorIsOn() {
        let pages = [
            PageBreak(label: "2", chapterIndex: 0, characterOffset: 0),
            PageBreak(label: "5", chapterIndex: 0, characterOffset: 50),
            PageBreak(label: "2", chapterIndex: 0, characterOffset: 50),
            PageBreak(label: "3", chapterIndex: 0, characterOffset: 100),
            PageBreak(label: "3", chapterIndex: 0, characterOffset: 100),
        ]
        let reader = makePagedReader(pages: pages)
        defer { reader.close() }
        reader.currentChapterIndex = 0
        reader.currentCharacterOffset = 0

        // Page 5 is blank: the cursor is on the second page labelled 2.
        XCTAssertNil(reader.goToPage(typed: "5"))
        XCTAssertEqual(pagedPlace(of: reader), "0:50")
        XCTAssertEqual(
            reader.lastAnnouncement,
            "Page 5 has no words, so the cursor is on the second page labelled 2."
        )

        // The first page labelled 3 is blank beside the second, which has
        // the words: the reason, naming the first, and the second of them.
        reader.currentCharacterOffset = 0
        XCTAssertNil(reader.goToPage(typed: "3"))
        XCTAssertEqual(pagedPlace(of: reader), "0:100")
        XCTAssertEqual(
            reader.lastAnnouncement,
            "The first page labelled 3 has no words, so the cursor is on the second page labelled 3."
        )

        // "2" asked for from there goes round to its first page, which has
        // words of its own: no reason, and the place it is.
        XCTAssertNil(reader.goToPage(typed: "2"))
        XCTAssertEqual(pagedPlace(of: reader), "0:0")
        XCTAssertEqual(reader.lastAnnouncement, "Jumped to page 2, the first page labelled 2.")
    }

    /// A label two pages carry, the second of them blank beside page 3:
    /// typing it reaches the page with words first, then the blank one,
    /// which the reason names as which of them it is. "Page 2 has no words"
    /// would deny the words of the other page 2, which the cursor has just
    /// left.
    func testABlankPageOfARepeatedLabelIsNamedAsWhichOfThemItIs() {
        let pages = [
            PageBreak(label: "1", chapterIndex: 0, characterOffset: 0),
            PageBreak(label: "2", chapterIndex: 0, characterOffset: 50),
            PageBreak(label: "2", chapterIndex: 0, characterOffset: 100),
            PageBreak(label: "3", chapterIndex: 0, characterOffset: 100),
        ]
        let reader = makePagedReader(pages: pages)
        defer { reader.close() }
        reader.currentChapterIndex = 0
        reader.currentCharacterOffset = 0

        XCTAssertNil(reader.goToPage(typed: "2"))
        XCTAssertEqual(pagedPlace(of: reader), "0:50")
        XCTAssertEqual(reader.lastAnnouncement, "Jumped to page 2, the first page labelled 2.")

        XCTAssertNil(reader.goToPage(typed: "2"))
        XCTAssertEqual(pagedPlace(of: reader), "0:100")
        XCTAssertEqual(reader.currentPagePosition.page?.label, "3", "the row names the page after the blank one")
        XCTAssertEqual(
            reader.lastAnnouncement,
            "The second page labelled 2 has no words, so the cursor is on page 3."
        )
    }

    /// A cursor on no page is told as the status row tells it. A book whose
    /// only page begins after its last word is reached at that word, before
    /// the page, where the row reads "Before page 1"; Go to Page said
    /// "Jumped to page 1." there, a page the cursor was not on.
    func testGoToPageSaysWhenTheCursorIsBeforeTheFirstPage() {
        let reader = makePagedReader(pages: [PageBreak(label: "1", chapterIndex: 1, characterOffset: 100)])
        defer { reader.close() }
        reader.currentChapterIndex = 0
        reader.currentCharacterOffset = 0

        XCTAssertNil(reader.goToPage(typed: "1"))

        XCTAssertEqual(pagedPlace(of: reader), "1:99")
        XCTAssertEqual(reader.currentPagePosition.label, "Before page 1")
        XCTAssertEqual(reader.lastAnnouncement, "Page 1 has no words, so the cursor is before page 1.")
    }

    // MARK: - Go to Page While the Book Plays

    /// Plays `reader` with its speech going nowhere: the speech service
    /// hands each utterance to a recorder in place of the synthesizer, so
    /// nothing is heard however long the test takes. Call it inside
    /// `withIsolatedListeningStatistics`, since Play opens a listening
    /// session.
    private func playSilently(_ reader: ReaderViewModel) {
        reader.speechService._directUtteranceRecorderForTesting = { _ in }
        reader.play()
    }

    /// Stops `reader`'s speech before the main run loop turns, and moves its
    /// playback generation on, so that no look-ahead render queued meanwhile
    /// starts. Record what the test checks first.
    private func silence(_ reader: ReaderViewModel) {
        reader.stop()
        reader.chapterPlaybackGeneration += 1
    }

    /// Pages 39 and 40 in chapter One, 40 at offset 150, and 52 at chapter
    /// Two's start.
    private static let pagesAroundForty = [
        PageBreak(label: "39", chapterIndex: 0, characterOffset: 0),
        PageBreak(label: "40", chapterIndex: 0, characterOffset: 150),
        PageBreak(label: "52", chapterIndex: 1, characterOffset: 0),
    ]

    /// Go to Page while a text book plays, to a page whose words are all in
    /// a skipped section that ends its chapter (its notes, say): the jump
    /// restarts speech, which passes over the section to the next chapter
    /// it reads, on page 52, and the sentence gives that reason, read from
    /// the book's pages and skipped sections. The cursor's being elsewhere
    /// was once taken to mean the page had no words: "Page 40 has no words,
    /// so the cursor is on page 52.", of a page full of them.
    func testGoToPageWhilePlayingSaysThePageIsInASkippedSection() throws {
        let headings = [
            Heading(level: 1, text: "Story", chapterIndex: 0, characterOffset: 0),
            Heading(level: 1, text: "Notes", chapterIndex: 0, characterOffset: 100),
        ]
        try withIsolatedListeningStatistics {
            let reader = makePagedReader(pages: Self.pagesAroundForty, chapterZeroHeadings: headings)
            defer { reader.close() }
            reader.toggleHeadingSkip(try XCTUnwrap(reader.headings.first { $0.text == "Notes" }))
            reader.currentChapterIndex = 0
            reader.currentCharacterOffset = 0
            playSilently(reader)
            let played = reader.speechService.isSpeaking

            XCTAssertNil(reader.goToPage(typed: "40"))
            let place = pagedPlace(of: reader)
            let said = reader.lastAnnouncement
            silence(reader)

            XCTAssertTrue(played, "the book never played")
            XCTAssertEqual(place, "1:0", "speech goes on at the next chapter it reads")
            XCTAssertEqual(said, "Page 40 is in a skipped section, so the cursor is on page 52.")
        }
    }

    /// When the pages give no reason for where the cursor is, Go to Page says
    /// only where that is, as the status row names it. Here a text
    /// substitution deletes every word of page 40, and no skipped section
    /// holds them, so a jump there while the book plays goes on to page 52.
    func testGoToPageWhilePlayingSaysOnlyWhereTheCursorIsWhenThePagesGiveNoReason() {
        // Page 40's words, from offset 150, are the ones the rule deletes.
        let text = String(repeating: "word ", count: 30) + String(repeating: "zzzz ", count: 10)
        withIsolatedListeningStatistics {
            let reader = makePagedReader(
                pages: Self.pagesAroundForty,
                chapterZeroText: text,
                substitutions: [SubstitutionRule(pattern: "zzzz")]
            )
            defer { reader.close() }
            reader.currentChapterIndex = 0
            reader.currentCharacterOffset = 0
            playSilently(reader)
            let played = reader.speechService.isSpeaking

            XCTAssertNil(reader.goToPage(typed: "40"))
            let place = pagedPlace(of: reader)
            let said = reader.lastAnnouncement
            silence(reader)

            XCTAssertTrue(played, "the book never played")
            XCTAssertEqual(place, "1:0", "speech goes on at the next chapter it reads")
            XCTAssertEqual(said, "The cursor is on page 52.")
        }
    }

    /// A refusal is the sentence, and nothing moves or is said.
    func testGoToPageRefusalMovesNothing() {
        let reader = makePagedReader(pages: Self.sixPages)
        defer { reader.close() }
        reader.currentChapterIndex = 0
        reader.currentCharacterOffset = 100
        reader.lastAnnouncement = nil

        XCTAssertEqual(
            reader.goToPage(typed: "400"),
            "There is no page 400 in this book. Its pages run from i to 300."
        )
        XCTAssertEqual(reader.goToPage(typed: ""), "Type a page number.")

        XCTAssertEqual(pagedPlace(of: reader), "0:100")
        XCTAssertNil(reader.lastAnnouncement)
        XCTAssertFalse(reader.hasSavedPosition)
    }

    /// Asking for the label the place is on moves to the next page of that
    /// label when the book repeats it, so asking again goes on.
    func testAskingForARepeatedLabelAgainGoesOn() {
        let reader = makePagedReader(pages: Self.sixPages)
        defer { reader.close() }
        reader.currentChapterIndex = 0
        reader.currentCharacterOffset = 0

        XCTAssertNil(reader.goToPage(typed: "2"))
        XCTAssertEqual(pagedPlace(of: reader), "0:150")
        XCTAssertNil(reader.goToPage(typed: "2"))
        XCTAssertEqual(pagedPlace(of: reader), "1:0")
        XCTAssertNil(reader.goToPage(typed: "2"))
        XCTAssertEqual(pagedPlace(of: reader), "0:150")
    }

    // MARK: - A Label More Than One Page Carries

    /// What Return does in the page panel on the text its field started at,
    /// as the panel asks it (`JumpFieldPanel.take`).
    private func returnOnTheStartingLabel(of reader: ReaderViewModel) -> JumpFieldOutcome {
        let starting = reader.goToPageStartingText
        return JumpFieldOutcome.taking(
            starting,
            startedAt: starting,
            submitsUnchanged: reader.goToPageLabelIsRepeated(starting),
            submit: reader.goToPage(typed:)
        )
    }

    /// Every page a label names is found by the one rule, spaces and case
    /// set aside, in book order; a label no page carries, and an empty one,
    /// name none.
    func testEveryPageOfALabelIsFoundByOneRule() {
        let pages = BookPages(breaks: Self.sixPages)
        XCTAssertEqual(JumpInputValidator.pageIndices(named: "2", in: pages), [3, 4])
        XCTAssertEqual(JumpInputValidator.pageIndices(named: " II\n", in: pages), [1])
        XCTAssertEqual(JumpInputValidator.pageIndices(named: "300", in: pages), [5])
        XCTAssertEqual(JumpInputValidator.pageIndices(named: "400", in: pages), [])
        XCTAssertEqual(JumpInputValidator.pageIndices(named: "", in: pages), [])
        XCTAssertEqual(JumpInputValidator.pageIndices(named: "2", in: .none), [])
    }

    /// Return on the label the field started at, when another page carries
    /// it too, goes to that label's next page, and the last goes round to
    /// the first, so every page of a repeated label can be reached from the
    /// panel. Before, the starting label was always no change, and the
    /// second "2" could be reached only by typing something else first.
    func testReturnOnARepeatedStartingLabelGoesToItsNextPage() {
        let reader = makePagedReader(pages: Self.sixPages)
        defer { reader.close() }
        reader.currentChapterIndex = 0
        reader.currentCharacterOffset = 160
        XCTAssertEqual(reader.goToPageStartingText, "2")
        XCTAssertTrue(reader.goToPageLabelIsRepeated("2"))

        XCTAssertEqual(returnOnTheStartingLabel(of: reader), .jumped)
        XCTAssertEqual(pagedPlace(of: reader), "1:0")
        XCTAssertEqual(reader.lastAnnouncement, "Jumped to page 2, the second page labelled 2.")

        // The panel opens afresh at the new place, still on a "2": the next
        // press wraps to the first, and says so, and a Return position was
        // kept.
        XCTAssertEqual(returnOnTheStartingLabel(of: reader), .jumped)
        XCTAssertEqual(pagedPlace(of: reader), "0:150")
        XCTAssertEqual(reader.lastAnnouncement, "Jumped to page 2, the first page labelled 2.")
        XCTAssertTrue(reader.hasSavedPosition)
    }

    /// Go to Page says which of the pages that carry a label it reached,
    /// however it came to be there (typed from elsewhere, by Return on the
    /// starting label, or by wrapping round), counting in book order and
    /// naming the label as the book spells it; a label of one page is said
    /// as ever. Without this a listener hears "Jumped to page A." for each
    /// of three pages and cannot tell where they are.
    func testGoToPageSaysWhichPageOfASharedLabelItReached() {
        let pages = [
            PageBreak(label: "1", chapterIndex: 0, characterOffset: 0),
            PageBreak(label: "A", chapterIndex: 0, characterOffset: 50),
            PageBreak(label: "2", chapterIndex: 0, characterOffset: 100),
            PageBreak(label: "A", chapterIndex: 0, characterOffset: 150),
            PageBreak(label: "A", chapterIndex: 1, characterOffset: 0),
            PageBreak(label: "3", chapterIndex: 1, characterOffset: 50),
        ]
        let reader = makePagedReader(pages: pages)
        defer { reader.close() }
        reader.currentChapterIndex = 0
        reader.currentCharacterOffset = 0

        // Typed from page 1, in the case the field was given: the book's own.
        XCTAssertNil(reader.goToPage(typed: "a"))
        XCTAssertEqual(pagedPlace(of: reader), "0:50")
        XCTAssertEqual(reader.lastAnnouncement, "Jumped to page A, the first page labelled A.")

        // Return on the starting label goes on, and round.
        for (place, said) in [
            ("0:150", "Jumped to page A, the second page labelled A."),
            ("1:0", "Jumped to page A, the third page labelled A."),
            ("0:50", "Jumped to page A, the first page labelled A."),
        ] {
            XCTAssertEqual(returnOnTheStartingLabel(of: reader), .jumped)
            XCTAssertEqual(pagedPlace(of: reader), place)
            XCTAssertEqual(reader.lastAnnouncement, said)
        }

        // A label of one page says nothing of the kind.
        XCTAssertNil(reader.goToPage(typed: "2"))
        XCTAssertEqual(reader.lastAnnouncement, "Jumped to page 2.")
    }

    /// The first ten ordinals are said in words, the rest in figures with
    /// their endings, 11th, 12th, and 13th among the "th"s.
    func testTheOccurrenceOfALabelIsSaidAsAnOrdinal() {
        let expected = [
            (1, "first"), (2, "second"), (3, "third"), (4, "fourth"), (5, "fifth"), (6, "sixth"),
            (7, "seventh"), (8, "eighth"), (9, "ninth"), (10, "tenth"), (11, "11th"), (12, "12th"),
            (13, "13th"), (14, "14th"), (21, "21st"), (22, "22nd"), (23, "23rd"), (24, "24th"),
            (101, "101st"), (111, "111th"), (112, "112th"), (113, "113th"), (122, "122nd"),
        ]
        for (occurrence, ordinal) in expected {
            XCTAssertEqual(
                ReaderPageWording.jumped(to: "2", occurrence: occurrence),
                "Jumped to page 2, the \(ordinal) page labelled 2.",
                "occurrence \(occurrence)"
            )
        }
        XCTAssertEqual(ReaderPageWording.jumped(to: "2", occurrence: nil), "Jumped to page 2.")
    }

    /// Return on a starting label that only the page being read carries is
    /// no change, as before: the panel closes as Cancel does, nothing moves
    /// or is said, and no Return position is kept. So is Return before the
    /// first page, where the field starts empty.
    func testReturnOnAUniqueStartingLabelMovesNothing() {
        let reader = makePagedReader(pages: Self.sixPages)
        defer { reader.close() }
        reader.currentChapterIndex = 0
        reader.currentCharacterOffset = 110
        reader.lastAnnouncement = nil
        XCTAssertEqual(reader.goToPageStartingText, "1")
        XCTAssertFalse(reader.goToPageLabelIsRepeated("1"))

        XCTAssertEqual(returnOnTheStartingLabel(of: reader), .unchanged)
        XCTAssertEqual(pagedPlace(of: reader), "0:110")
        XCTAssertNil(reader.lastAnnouncement)
        XCTAssertFalse(reader.hasSavedPosition)

        let later = makePagedReader(pages: [PageBreak(label: "i", chapterIndex: 0, characterOffset: 50)])
        defer { later.close() }
        later.currentChapterIndex = 0
        later.currentCharacterOffset = 0
        XCTAssertEqual(later.goToPageStartingText, "")
        XCTAssertEqual(returnOnTheStartingLabel(of: later), .unchanged)
        XCTAssertEqual(pagedPlace(of: later), "0:0")
    }

    /// The page panel's own Return does the same: the panel hosted offscreen,
    /// its field given the label it started at, a "2" the book carries on
    /// two pages, goes to the second and closes by jumping; on a label of one
    /// page it closes as Cancel. Skipped where an offscreen window gives the
    /// field no keyboard focus or takes no key.
    func testTheHostedPanelsReturnOnARepeatedLabelJumpsAndOnAUniqueOneCancels() throws {
        let repeated = makePagedReader(pages: Self.sixPages)
        defer { repeated.close() }
        repeated.currentChapterIndex = 0
        repeated.currentCharacterOffset = 160
        var jumped = false
        var cancelled = false
        let panel = JumpToPagePanel(viewModel: repeated, onJump: { jumped = true }, onCancel: { cancelled = true })

        try withHostedField(panel, holding: "2") { field, _ in
            let hostingView = field.hostingView
            let textField = try XCTUnwrap(
                editableTextFields(in: hostingView).first { $0.placeholderString == "Page" },
                "the field was not drawn"
            )
            // The starting label typed back over itself, which gives the
            // field the keyboard as the user's own typing would.
            try typeReplacingText("2", in: textField, of: hostingView)

            _ = pressReturnKey(in: hostingView)
            settleHostedView(hostingView)
            guard jumped || cancelled else { throw XCTSkip("This macOS hands an offscreen window's field no Return") }
            XCTAssertTrue(jumped, "Return on a repeated starting label did not jump")
            XCTAssertFalse(cancelled)
            XCTAssertEqual(pagedPlace(of: repeated), "1:0")
        }

        let unique = makePagedReader(pages: Self.sixPages)
        defer { unique.close() }
        unique.currentChapterIndex = 0
        unique.currentCharacterOffset = 110
        jumped = false
        cancelled = false
        let uniquePanel = JumpToPagePanel(viewModel: unique, onJump: { jumped = true }, onCancel: { cancelled = true })

        try withHostedField(uniquePanel, holding: "1") { field, _ in
            let hostingView = field.hostingView
            let textField = try XCTUnwrap(
                editableTextFields(in: hostingView).first { $0.placeholderString == "Page" },
                "the field was not drawn"
            )
            try typeReplacingText("1", in: textField, of: hostingView)

            _ = pressReturnKey(in: hostingView)
            settleHostedView(hostingView)
            guard jumped || cancelled else { throw XCTSkip("This macOS hands an offscreen window's field no Return") }
            XCTAssertTrue(cancelled, "Return on a unique starting label did not close the panel as Cancel does")
            XCTAssertFalse(jumped)
            XCTAssertEqual(pagedPlace(of: unique), "0:110")
        }
    }

    /// The field starts at the current page's label, and empty before the
    /// first page; Jump on the starting text of a label one page carries is
    /// no change.
    func testTheStartingTextIsTheCurrentPagesLabel() {
        let reader = makePagedReader(pages: Self.sixPages)
        defer { reader.close() }
        reader.currentChapterIndex = 0
        reader.currentCharacterOffset = 100
        XCTAssertEqual(reader.goToPageStartingText, "1")
        XCTAssertEqual(
            JumpFieldOutcome.taking(reader.goToPageStartingText, startedAt: reader.goToPageStartingText) { _ in
                XCTFail("an unchanged field must not be submitted")
                return nil
            },
            .unchanged
        )

        // A book whose first page begins after the start has none there.
        let later = makePagedReader(pages: [PageBreak(label: "i", chapterIndex: 0, characterOffset: 50)])
        defer { later.close() }
        later.currentChapterIndex = 0
        later.currentCharacterOffset = 0
        XCTAssertEqual(later.goToPageStartingText, "")
        XCTAssertNil(later.goToPage(typed: "i"))
        XCTAssertEqual(pagedPlace(of: later), "0:50")
    }

    /// Go to Page… raises the request count in a book with pages, and says
    /// there are none otherwise.
    func testGoToPageRequestsOnlyWithPages() {
        let reader = makePagedReader(pages: Self.sixPages)
        defer { reader.close() }
        XCTAssertEqual(reader.goToPageRequests, 0)
        reader.requestGoToPage()
        reader.requestGoToPage()
        XCTAssertEqual(reader.goToPageRequests, 2)

        let plain = makePagedReader(pages: [])
        defer { plain.close() }
        plain.requestGoToPage()
        XCTAssertEqual(plain.goToPageRequests, 0)
        XCTAssertEqual(plain.lastAnnouncement, "This book has no pages.")
    }

    /// The command arrives by notification at the targeted reader: the
    /// request count rises once.
    func testTheGoToPageNotificationReachesTheReader() {
        let reader = makePagedReader(pages: Self.sixPages)
        defer { reader.close() }
        NotificationCenter.default.post(name: .goToPage, object: nil)

        XCTAssertEqual(reader.goToPageRequests, 1)
    }

    // MARK: - The Hosted Field and Status Row

    /// The page panel's field is one text field, labelled "Page", with the
    /// book's pages and what to type as its hint and the current page's
    /// label as its value.
    func testThePagePanelsFieldIsOneLabelledEditText() throws {
        let reader = makePagedReader(pages: Self.pagesAroundTwelve)
        defer { reader.close() }
        reader.currentChapterIndex = 0
        reader.currentCharacterOffset = 60
        let panel = JumpToPagePanel(viewModel: reader, onJump: {}, onCancel: {})

        try withHostedField(panel, holding: "12") { field, controls in
            XCTAssertEqual(field.role, .textField)
            XCTAssertEqual(field.label, "Page")
            XCTAssertEqual(
                field.hint,
                "This book has 300 pages, from 11 to 300. Type a page as the book numbers it, such as 12 or xii."
            )
            XCTAssertEqual(field.element.accessibilityValue() as? String, "12")
            XCTAssertEqual(controls.filter { $0.role == .textField }.count, 1)
        }
    }

    /// The labels of the buttons the status row of `reader` exposes,
    /// hosted in a frame of fixed size; skipped where hosted windows expose
    /// no accessibility elements or draw the row's buttons as none (the
    /// percent button, always drawn, is the witness).
    private func statusRowButtons(of reader: ReaderViewModel) throws -> [AccessibleControl] {
        try skipUnlessHostedWindowsExposeAccessibility()
        let size = NSSize(width: 640, height: 120)
        var buttons: [AccessibleControl] = []
        withHostedView(
            BookInfoBar(viewModel: reader).frame(width: size.width, height: size.height),
            size: size,
            until: { !self.accessibleControls(in: $0).filter { $0.role == .button }.isEmpty }
        ) { hostingView in
            buttons = accessibleControls(in: hostingView).filter { $0.role == .button }
        }
        try XCTSkipUnless(
            buttons.contains { $0.label.hasSuffix("through the book") },
            "The hosted status row exposed no buttons to accessibility"
        )
        return buttons
    }

    /// A reader on page 12 of 300 has a page button in its status row, named
    /// by the position, with the hint that says what it opens.
    func testTheStatusRowHasAPageButton() throws {
        try skipUnlessSwiftUIExposesItsOwnElements()
        let settings = try makeIsolatedSettings("page-button")
        let reader = makePagedReader(pages: Self.pagesAroundTwelve, settings: settings)
        defer { reader.close() }
        reader.currentChapterIndex = 0
        reader.currentCharacterOffset = 60
        reader.refreshPlaybackUI(chapterIndex: 0, offset: 60)

        let buttons = try statusRowButtons(of: reader)

        let button = try XCTUnwrap(buttons.first { $0.label == "Page 12 of 300" }, "\(buttons.map(\.label))")
        XCTAssertEqual(button.hint, "Opens jump to page controls")
    }

    /// With the setting off, in a book without pages, or in a book of one
    /// page, the status row has no page button.
    func testTheStatusRowHasNoPageButtonWhenOffOrWithOnePageOrNone() throws {
        try skipUnlessSwiftUIExposesItsOwnElements()
        let hidden = try makeIsolatedSettings("page-button-off")
        hidden.showsPageInReader = false
        let off = makePagedReader(pages: Self.pagesAroundTwelve, settings: hidden)
        defer { off.close() }
        // Read outside the assertion, which cannot take a skip thrown in it.
        let offButtons = try statusRowButtons(of: off)
        XCTAssertFalse(offButtons.contains { $0.label.hasPrefix("Page") })

        let plain = makePagedReader(pages: [], settings: try makeIsolatedSettings("page-button-none"))
        defer { plain.close() }
        let plainButtons = try statusRowButtons(of: plain)
        XCTAssertFalse(plainButtons.contains { $0.label.hasPrefix("Page") })

        let single = makePagedReader(pages: Self.onePage, settings: try makeIsolatedSettings("page-button-one"))
        defer { single.close() }
        let singleButtons = try statusRowButtons(of: single)
        XCTAssertFalse(singleButtons.contains { $0.label.hasPrefix("Page") || $0.label.hasPrefix("Before page") })
    }

    /// A book of one page has a page to go to, so the page commands and Go
    /// to Page… work in it, but not several, so the status row leaves its
    /// page button out (the user's request, November 4, 2026): it would say
    /// "Page 1 of 1" wherever the book is read. A book of two pages has
    /// several, and a book without pages has neither.
    func testABookOfOnePageHasAPageButNotSeveral() {
        let single = makePagedReader(pages: Self.onePage)
        defer { single.close() }
        XCTAssertTrue(single.hasPages)
        XCTAssertFalse(single.hasSeveralPages)

        let two = makePagedReader(pages: Array(Self.pagesAroundTwelve.prefix(2)))
        defer { two.close() }
        XCTAssertTrue(two.hasSeveralPages)

        let none = makePagedReader(pages: [])
        defer { none.close() }
        XCTAssertFalse(none.hasPages)
        XCTAssertFalse(none.hasSeveralPages)
    }

    // MARK: - The Setting

    /// The setting is on until it is turned off, config.json names it, and
    /// a change is written to the file.
    func testTheSettingIsOnByDefaultAndConfigCarriesIt() throws {
        let file = try makeConfigFileURL()
        let settings = try makeIsolatedSettings("page-setting", configFile: file)
        XCTAssertTrue(settings.showsPageInReader)

        let named = try JSONDecoder().decode(ConfigService.AppConfig.self, from: Data(#"{"showsPageInReader": false}"#.utf8))
        XCTAssertEqual(named.showsPageInReader, false)
        let without = try JSONDecoder().decode(ConfigService.AppConfig.self, from: Data(#"{"autoPlayOnNavigate": true}"#.utf8))
        XCTAssertNil(without.showsPageInReader)
        XCTAssertTrue(ConfigService.AppConfig.Portability.mirrored.contains {
            $0.storeKey == "showsPageInReader" && $0.field == "showsPageInReader"
        })

        // Turning it off, and on again, is written to config.json.
        for value in [false, true] {
            settings.showsPageInReader = value
            XCTAssertTrue(
                waitUntil(timeout: 5) {
                    guard let data = try? Data(contentsOf: file),
                          let config = try? ConfigService.decode(data) else { return false }
                    return config.showsPageInReader == value
                },
                "config.json never held showsPageInReader = \(value)"
            )
        }
    }

    // MARK: - The Page in Where Am I? (PG04)

    /// The 26th of 412 headings, as the headings panel would number it.
    private var twentySixthOf412Headings: HeadingPosition {
        let headings = (0..<412).map { Heading(level: 2, text: "Part \($0 + 1)", characterOffset: $0 * 10) }
        return HeadingPosition(in: headings, chapterIndex: 0, characterOffset: 25 * 10 + 5)
    }

    /// "Page 112 of 300", as the reading position describes a place on the
    /// book's page 112 when its last page is 300.
    private var page112Of300: String {
        let pages = BookPages(breaks: [
            PageBreak(label: "112", chapterIndex: 0, characterOffset: 0),
            PageBreak(label: "300", chapterIndex: 0, characterOffset: 500),
        ])
        return pages.position(atChapter: 0, offset: 10).label
    }

    /// The brief summary for the shared fixture, with `pageLabel`.
    private func briefSummary(pageLabel: String, isFinished: Bool = false) -> String {
        ReaderViewModel.briefWhereAmISummary(
            bookTitle: "Dune",
            locationTitle: "The Battle",
            headingPosition: twentySixthOf412Headings,
            pageLabel: pageLabel,
            percentComplete: 30,
            timeRemaining: 10_800,
            isFinished: isFinished
        )
    }

    /// The full summary for the shared fixture, with `pageLabel`.
    private func fullSummary(pageLabel: String) -> String {
        ReaderViewModel.fullWhereAmISummary(
            bookTitle: "Dune",
            locationTitle: "The Battle",
            headingPosition: twentySixthOf412Headings,
            pageLabel: pageLabel,
            percentComplete: 30,
            timeRemaining: 10_800,
            timeRemainingInHeading: 900,
            totalTime: 36_000
        )
    }

    /// The brief summary says the page right after the heading number.
    func testTheBriefSummarySaysThePageAfterTheHeading() {
        XCTAssertEqual(page112Of300, "Page 112 of 300")
        XCTAssertEqual(
            briefSummary(pageLabel: page112Of300),
            "Dune. The Battle. Heading 26 of 412. Page 112 of 300. 30 percent. 3 hours remaining."
        )
    }

    /// The full summary says "Page 112 of 300." right after "Heading 26 of 412."
    func testTheFullSummarySaysThePageAfterTheHeading() {
        let summary = fullSummary(pageLabel: page112Of300)
        XCTAssertTrue(
            summary.hasPrefix("Dune. The Battle. Heading 26 of 412. Page 112 of 300. 30 percent through the book."),
            summary
        )
    }

    /// Before the first page the summaries say so.
    func testBeforeTheFirstPageTheSummariesSaySo() {
        let pages = BookPages(breaks: [PageBreak(label: "1", chapterIndex: 0, characterOffset: 100)])
        let label = pages.position(atChapter: 0, offset: 5).label
        XCTAssertEqual(label, "Before page 1")
        XCTAssertTrue(briefSummary(pageLabel: label).contains("Heading 26 of 412. Before page 1. 30 percent."))
        XCTAssertTrue(fullSummary(pageLabel: label).contains("Heading 26 of 412. Before page 1. 30 percent through the book."))
    }

    /// With no page to say, both summaries are exactly what they were, with
    /// the page label left out or given empty.
    func testWithoutAPageTheSummariesAreAsTheyWere() {
        XCTAssertEqual(
            briefSummary(pageLabel: ""),
            "Dune. The Battle. Heading 26 of 412. 30 percent. 3 hours remaining."
        )
        XCTAssertEqual(
            ReaderViewModel.briefWhereAmISummary(
                bookTitle: "Dune",
                locationTitle: "The Battle",
                headingPosition: twentySixthOf412Headings,
                percentComplete: 30,
                timeRemaining: 10_800
            ),
            briefSummary(pageLabel: "")
        )
        XCTAssertEqual(
            ReaderViewModel.fullWhereAmISummary(
                bookTitle: "Dune",
                locationTitle: "The Battle",
                headingPosition: twentySixthOf412Headings,
                percentComplete: 30,
                timeRemaining: 10_800,
                timeRemainingInHeading: 900,
                totalTime: 36_000
            ),
            fullSummary(pageLabel: "")
        )
    }

    /// A finished book says the page before "Finished".
    func testAFinishedBookSaysThePageBeforeFinished() {
        XCTAssertEqual(
            briefSummary(pageLabel: page112Of300, isFinished: true),
            "Dune. The Battle. Heading 26 of 412. Page 112 of 300. Finished."
        )
    }

    /// The reader's own summaries follow the setting and the book: the page
    /// is said while the setting is on and the book has pages, and neither
    /// summary changes otherwise.
    func testTheReadersSummariesFollowTheSettingAndTheBook() throws {
        let settings = try makeIsolatedSettings("page-where-am-i")
        let reader = makePagedReader(pages: Self.pagesAroundTwelve, settings: settings)
        defer { reader.close() }
        reader.currentChapterIndex = 0
        reader.currentCharacterOffset = 60
        let content = try XCTUnwrap(reader.content)

        XCTAssertTrue(settings.saysPageInWhereAmI)
        XCTAssertEqual(reader.whereAmIPageLabel, "Page 12 of 300")
        XCTAssertTrue(reader.buildBriefWhereAmI().contains("Page 12 of 300."), reader.buildBriefWhereAmI())
        XCTAssertTrue(reader.buildFullWhereAmI(content: content).contains("Page 12 of 300."))

        settings.saysPageInWhereAmI = false
        XCTAssertEqual(reader.whereAmIPageLabel, "")
        XCTAssertFalse(reader.buildBriefWhereAmI().contains("of 300"))
        XCTAssertFalse(reader.buildFullWhereAmI(content: content).contains("of 300"))

        let plain = makePagedReader(pages: [], settings: try makeIsolatedSettings("page-where-am-i-none"))
        defer { plain.close() }
        XCTAssertEqual(plain.whereAmIPageLabel, "")
        XCTAssertFalse(plain.buildBriefWhereAmI().contains(" of "))
    }

    /// The setting is on until it is turned off, config.json names it, and
    /// its change is written to the file.
    func testTheWhereAmISettingIsOnByDefaultAndConfigCarriesIt() throws {
        let file = try makeConfigFileURL()
        let settings = try makeIsolatedSettings("page-where-am-i-setting", configFile: file)
        XCTAssertTrue(settings.saysPageInWhereAmI)

        let named = try JSONDecoder().decode(ConfigService.AppConfig.self, from: Data(#"{"saysPageInWhereAmI": false}"#.utf8))
        XCTAssertEqual(named.saysPageInWhereAmI, false)
        XCTAssertTrue(ConfigService.AppConfig.Portability.mirrored.contains {
            $0.storeKey == "saysPageInWhereAmI" && $0.field == "saysPageInWhereAmI"
        })

        settings.saysPageInWhereAmI = false
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                guard let data = try? Data(contentsOf: file),
                      let config = try? ConfigService.decode(data) else { return false }
                return config.saysPageInWhereAmI == false
            },
            "config.json never held saysPageInWhereAmI = false"
        )
    }
}
