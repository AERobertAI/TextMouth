import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// Go to Page… and the page on the reader screen (PG03): the field's answer
/// for a page typed as the book numbers it, what it refuses, the jump and
/// what VoiceOver hears, the field's own accessibility, the page button on
/// the status row, and the setting that shows or hides it. Pure
/// (`makePagedReader` readers), except the hosted checks, which draw the
/// panel and the status row offscreen in a fixed frame.
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

    /// The wording, pinned.
    func testTheWordsAreFixed() {
        XCTAssertEqual(ReaderPageWording.fieldLabel, "Page")
        XCTAssertEqual(ReaderPageWording.fieldHint, "Type a page as the book numbers it, such as 12 or xii.")
        XCTAssertEqual(ReaderPageWording.emptyField, "Type a page number.")
        XCTAssertEqual(ReaderPageWording.jumped(to: "12"), "Jumped to page 12.")
        XCTAssertEqual(ReaderPageWording.openHint, "Opens jump to page controls")
        XCTAssertEqual(ReaderPageWording.hideHint, "Hides jump to page controls")
        XCTAssertEqual(ReaderPageWording.switchHint, "Switches to jump to page controls")
        XCTAssertEqual(ReaderPageWording.settingSection, "Pages")
        XCTAssertEqual(ReaderPageWording.showInReaderTitle, "Show the page on the reader screen")
        XCTAssertEqual(
            ReaderPageWording.showInReaderHint,
            "Shows the page being read, such as Page 12 of 300, beside the percent, for books with pages."
        )
        XCTAssertEqual(ReaderPageWording.sayInWhereAmITitle, "Say the page in Where Am I?")
        XCTAssertEqual(
            ReaderPageWording.sayInWhereAmIHint,
            "Adds the page, such as Page 12 of 300, to Where Am I?'s summaries, for books with pages."
        )
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

    /// The field starts at the current page's label, and empty before the
    /// first page; Jump on the starting text is no change.
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

    /// The page panel's field is one text field, labelled "Page", with what
    /// to type as its hint and the current page's label as its value.
    func testThePagePanelsFieldIsOneLabelledEditText() throws {
        let reader = makePagedReader(pages: Self.pagesAroundTwelve)
        defer { reader.close() }
        reader.currentChapterIndex = 0
        reader.currentCharacterOffset = 60
        let panel = JumpToPagePanel(viewModel: reader, onJump: {}, onCancel: {})

        try withHostedField(panel, holding: "12") { field, controls in
            XCTAssertEqual(field.role, .textField)
            XCTAssertEqual(field.label, "Page")
            XCTAssertEqual(field.hint, "Type a page as the book numbers it, such as 12 or xii.")
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

    /// With the setting off, or in a book without pages, the status row has
    /// no page button.
    func testTheStatusRowHasNoPageButtonWhenOffOrWithoutPages() throws {
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
}
