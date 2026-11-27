import XCTest

/// The reader, as XCUITest reads it in the simulator, opened on a text book
/// sent to the app: its 21 elements in the spec's order (under "VoiceOver's
/// order"), what its controls hold before anything is pressed, and Apple's
/// accessibility audit. Nothing in the reader is pressed here: Play, which plays,
/// is pressed in `PlaybackUITests` (it runs only where sound is allowed), and
/// Where Am I? speaks, so no test presses it.
final class ReaderUITests: TextMouthUITestCase {

    /// The reader's elements after Back and the title, in the spec's order:
    /// Book content, then Play, then the grid, the skip buttons last. A skip
    /// button's label names the unit, so only its start is fixed.
    static let controls = [
        "Book content", "Play", "Where Am I?", "Navigation unit", "Speed",
        "Previous Heading", "Next Heading", "Add bookmark", "Bookmarks", "Headings",
        "Search in Book", "Go To", "Return to previous reading position", "Book Actions",
        "Skip backward…", "Skip forward…",
    ]

    /// The items of the Book Actions menu, in its order (FR51).
    static let bookActionItems = ["Sleep Timer", "Voice", "Book Info", "Export this book"]

    /// The reader opens on the book, titled with it, with Back first and its
    /// controls in the spec's order after the title.
    func testTheReaderHasTheSpecsOrder() throws {
        let app = try launchIntoTheReader()
        let bar = app.navigationBars[Self.bookTitle]
        XCTAssertTrue(bar.waitForExistence(timeout: Self.patience), "The reader isn't titled with the book:\n\(app.debugDescription)")
        XCTAssertEqual(bar.buttons.firstMatch.label, "Library", "Back is named for where it goes")

        let elements = try elementsInOrder(of: app)
        assertOrder(["Library", Self.bookTitle] + Self.controls, in: elements)
        keepScreenshot(of: app, named: "Reader")
    }

    /// Before anything is pressed: Play says "Play" with no value, a text
    /// book moves by sentence, no timer shows (FR51), no bookmark is counted,
    /// and Book content holds the book's text from its place.
    func testTheControlsHoldTheirFirstValues() throws {
        let app = try launchIntoTheReader()
        let play = app.buttons["Play"]
        XCTAssertEqual(play.label, "Play")
        XCTAssertTrue((play.value as? String ?? "").isEmpty, "Play's value: \(String(describing: play.value))")

        let elements = try elementsInOrder(of: app)
        func value(of label: String) -> String? {
            elements.first { $0.label == label }?.value
        }
        XCTAssertEqual(value(of: "Navigation unit"), "Sentence")
        // Go To says the place, its time at least (FR50).
        XCTAssertFalse((value(of: "Go To") ?? "").isEmpty, "Go To says no place: \(Self.describe(elements))")
        XCTAssertFalse(elements.contains { $0.label == "Sleep Timer" }, "A Sleep Timer shows with no timer running: \(Self.describe(elements))")
        XCTAssertTrue((value(of: "Bookmarks") ?? "").isEmpty, "No bookmark yet: \(value(of: "Bookmarks") ?? "")")
        XCTAssertTrue(elements.contains { $0.label.hasPrefix("Skip forward") && $0.label.hasSuffix("Sentence") }, "The skips don't name the unit")

        let text = try XCTUnwrap(value(of: "Book content"), "Book content holds no text")
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Book content is blank")
        XCTAssertLessThanOrEqual(text.count, 20_000, "More than the passage's limit")
    }

    /// Book content is one element, one swipe for VoiceOver (FR48): nothing
    /// labeled stands between it and Play, as a paragraph of its own would,
    /// and it is the screen's main area, taller than Play. The text view's own
    /// scroll bars, which XCUITest lists after it ("Vertical scroll bar, 5
    /// pages", train 1127-1548), are UIKit's and not the text's, so they are
    /// passed over.
    func testBookContentIsOneElementAndTheMainArea() throws {
        let app = try launchIntoTheReader()
        let elements = try elementsInOrder(of: app).filter { !$0.label.contains("scroll bar") }
        let index = try XCTUnwrap(elements.firstIndex { $0.label == "Book content" }, "No Book content")
        XCTAssertTrue(elements.indices.contains(index + 1), "Nothing after Book content")
        XCTAssertEqual(elements[index + 1].label, "Play", "The element after Book content: \(Self.describe(elements))")
        let play = try XCTUnwrap(elements.first { $0.label == "Play" })
        XCTAssertGreaterThan(elements[index].frame.height, play.frame.height, "Book content is smaller than Play")
    }

    /// Book Actions opens a menu of Sleep Timer, Voice, Book Info, and Export
    /// this book, in that order, none of which is on the reader by itself, and
    /// its Book Info opens the Book Information sheet (FR51).
    func testBookActionsOpensItsMenu() throws {
        let app = try launchIntoTheReader()
        let before = try elementsInOrder(of: app)
        for item in Self.bookActionItems {
            XCTAssertFalse(before.contains { $0.label == item }, "\(item) is loose in the reader: \(Self.describe(before))")
        }
        tap(app.buttons["Book Actions"], until: app.buttons["Book Info"], in: app, what: "Book Actions")
        assertOrder(Self.bookActionItems, in: try elementsInOrder(of: app))
        keepScreenshot(of: app, named: "Book Actions")
        app.buttons["Book Info"].tap()
        XCTAssertTrue(
            app.navigationBars["Book Information"].waitForExistence(timeout: Self.patience),
            "Book Info in the menu opened no sheet:\n\(app.debugDescription)"
        )
    }

    /// Each control is big enough to find by touch: at least 44 points tall,
    /// Apple's smallest, as `PhoneControlButton.minimumHeight` holds them.
    func testEveryControlIsBigEnoughToTouch() throws {
        let app = try launchIntoTheReader()
        let elements = try elementsInOrder(of: app)
        for label in Self.controls.dropFirst() {
            let prefix = label.hasSuffix("…") ? String(label.dropLast()) : label
            let control = try XCTUnwrap(elements.first { $0.label.hasPrefix(prefix) }, "No \(label)")
            XCTAssertGreaterThanOrEqual(control.frame.height, 44, "\(control.label) is \(control.frame.height) points tall")
        }
    }

    /// The reader passes Apple's audit, with the book loaded and paused.
    func testTheReaderPassesTheAudit() throws {
        let app = try launchIntoTheReader()
        try audit(app, screen: "reader", accepting: [.navigationTitle(Self.bookTitle)])
    }
}
