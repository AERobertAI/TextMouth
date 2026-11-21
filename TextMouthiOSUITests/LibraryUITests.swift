import XCTest

/// The Library, as XCUITest reads it in the simulator: its words, their order
/// (the spec, under "The Library's top"), and Apple's accessibility audit,
/// empty and with a book. Nothing is pressed but a book's row and Back.
final class LibraryUITests: TextMouthUITestCase {

    /// The empty Library says what it is and what to do, and its bar at the
    /// bottom comes after it: Settings, then Sort, then Add to Library.
    func testTheEmptyLibrarySaysWhatToDo() throws {
        let app = try launch(sendingTheBook: false)
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: Self.patience), "No Library:\n\(app.debugDescription)")
        let empty = "Your library is empty. Add to Library adds a book."
        XCTAssertTrue(app.staticTexts[empty].waitForExistence(timeout: Self.patience), "No empty note:\n\(app.debugDescription)")
        XCTAssertTrue(app.searchFields.firstMatch.exists, "No search field")

        let elements = try elementsInOrder(of: app)
        assertOrder(["Library", empty, "Settings", "Sort books by…", "Add to Library"], in: elements)
        for label in ["Settings", "Add to Library"] {
            XCTAssertTrue(app.buttons[label].isHittable, "\(label) can't be reached by touch")
        }
        // An empty library has no Library view row and no Continue row.
        XCTAssertFalse(elements.contains { $0.label == "Library view" }, "Library view is shown with nothing to list")
        keepScreenshot(of: app, named: "Library, empty")
    }

    /// The empty Library passes Apple's audit.
    func testTheEmptyLibraryPassesTheAudit() throws {
        let app = try launch(sendingTheBook: false)
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: Self.patience))
        try audit(app, screen: "empty Library", accepting: Self.systemParts)
    }

    /// The Library's findings on the parts iOS draws: the search field, and
    /// the bar at the bottom's buttons with words.
    static let systemParts: [Accepted] = [.searchField, .barItem("Settings"), .barItem("Add to Library")]

    /// A book sent to the app is imported and opened; Back leaves it for the
    /// Library, whose row for it begins with its title and author and ends
    /// with its format, under the Mac's "Books (1)".
    func testABookSentIsListedByItsRow() throws {
        let app = try launchIntoTheReader()
        let back = app.navigationBars.buttons.element(boundBy: 0)
        let backLabel = back.label
        back.tap()
        if !app.navigationBars["Library"].waitForExistence(timeout: Self.patience) {
            // What came instead: the order, and the bars by identifier.
            let bars = app.navigationBars.allElementsBoundByIndex.map(\.identifier)
            let order = try elementsInOrder(of: app).map { "\($0.type.rawValue):\($0.label)" }
            XCTFail("Back (\"\(backLabel)\") didn't reach the Library. Bars: \(bars). Order: \(order.joined(separator: " | "))")
            return
        }

        let rowStart = "\(Self.bookTitle), by \(Self.bookAuthor)"
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", rowStart)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: Self.patience), "No row for the book:\n\(app.debugDescription)")
        XCTAssertTrue(row.label.hasSuffix(", EPUB"), row.label)
        XCTAssertTrue(row.isHittable, "The book's row can't be reached by touch")

        let elements = try elementsInOrder(of: app)
        assertOrder(["Library", "Library view", "Books (1)", "\(rowStart)…", "1 book…", "Settings", "Sort books by…", "Add to Library"], in: elements)
        keepScreenshot(of: app, named: "Library, one book")
    }

    /// The Library with a book in it passes Apple's audit.
    func testTheLibraryWithABookPassesTheAudit() throws {
        let app = try launchIntoTheReader()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let rowStart = "\(Self.bookTitle), by \(Self.bookAuthor)"
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", rowStart)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: Self.patience), "No row for the book")
        // Dynamic Type is reported and not failed: the audit flags the
        // summary row, the list's last, as "partially unsupported", and its
        // cause is not known (the row is a plain text style that scales).
        // `LargeTextUITests` audits that row in place at the largest size,
        // and fails on it until the cause is found.
        try audit(app, screen: "Library with a book", informing: .dynamicType, accepting: Self.systemParts)
    }
}
