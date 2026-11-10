import XCTest

/// The reader, as XCUITest reads it in the simulator, opened on a text book
/// sent to the app: its 20 elements in the spec's order (under "VoiceOver's
/// order"), what its controls hold before anything is pressed, and Apple's
/// accessibility audit. Nothing in the reader is pressed: Play would play, and
/// Where Am I? speaks.
final class ReaderUITests: TextMouthUITestCase {

    /// The reader's elements after Back and the title, in the spec's order:
    /// Book content, then Play, then the grid, the skip buttons last. A skip
    /// button's label names the unit, so only its start is fixed.
    static let controls = [
        "Book content", "Play", "Where Am I?", "Navigation unit", "Speed",
        "Previous Heading", "Next Heading", "Add bookmark", "Bookmarks", "Headings",
        "Search in Book", "Go To", "Return to previous reading position", "Sleep Timer", "Voice", "Book Info",
        "Skip backward…", "Skip forward…",
    ]

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
    /// book moves by sentence, the timer is off, no bookmark is counted, and
    /// Book content holds the book's text from its place.
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
        XCTAssertEqual(value(of: "Sleep Timer"), "Off")
        XCTAssertTrue((value(of: "Bookmarks") ?? "").isEmpty, "No bookmark yet: \(value(of: "Bookmarks") ?? "")")
        XCTAssertTrue(elements.contains { $0.label.hasPrefix("Skip forward") && $0.label.hasSuffix("Sentence") }, "The skips don't name the unit")

        let text = try XCTUnwrap(value(of: "Book content"), "Book content holds no text")
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Book content is blank")
        XCTAssertLessThanOrEqual(text.count, 20_000, "More than the passage's limit")
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
