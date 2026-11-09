import XCTest

/// The screens at the largest text size iOS offers (Accessibility Extra Extra
/// Extra Large), where text must grow and wrap and never be cut: Apple's
/// audit of Dynamic Type and of clipped text on the Library with a book,
/// Settings, and the Add to Library sheet. The size is set at launch, as the
/// Larger Text setting would set it, so nothing here changes the simulator's
/// own settings. Nothing is pressed but a book's Back, Settings, and Add to
/// Library, and nothing is typed.
final class LargeTextUITests: TextMouthUITestCase {

    /// The kinds of finding that text size can cause.
    private static let sizeFindings: XCUIAccessibilityAuditType = [.dynamicType, .textClipped]

    /// The Library with a book, at the largest size.
    func testTheLibraryWithABookHoldsAtTheLargestText() throws {
        let app = try launchIntoTheReader(textSize: Self.largestText)
        goBackToTheLibrary(from: app)
        let rowStart = "\(Self.bookTitle), by \(Self.bookAuthor)"
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", rowStart)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: Self.patience), "No row for the book at the largest size:\n\(app.debugDescription)")
        try audit(app, screen: "Library with a book at the largest text", types: Self.sizeFindings, accepting: LibraryUITests.systemParts)
        // The summary row, the list's last, is below the first screen at this
        // size: scrolled to, it is audited in place.
        app.swipeUp()
        try audit(app, screen: "Library with a book at the largest text, scrolled", types: Self.sizeFindings, accepting: LibraryUITests.systemParts)
    }

    /// Settings, at the largest size, as it first appears.
    func testSettingsHoldsAtTheLargestText() throws {
        let app = try launch(sendingTheBook: false, textSize: Self.largestText)
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: Self.patience), "No Settings button at the largest size:\n\(app.debugDescription)")
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: Self.patience), "Settings never opened:\n\(app.debugDescription)")
        try audit(app, screen: "Settings at the largest text", types: Self.sizeFindings, accepting: [.navigationTitle("Settings")])
        // Two screens down, where the sliders' captions and the switches are.
        app.swipeUp()
        app.swipeUp()
        try audit(app, screen: "Settings at the largest text, scrolled", types: Self.sizeFindings, accepting: [.navigationTitle("Settings")])
    }

    /// The Add to Library sheet, at the largest size.
    func testAddToLibraryHoldsAtTheLargestText() throws {
        let app = try launch(sendingTheBook: false, textSize: Self.largestText)
        XCTAssertTrue(app.buttons["Add to Library"].waitForExistence(timeout: Self.patience), "No Add to Library at the largest size:\n\(app.debugDescription)")
        app.buttons["Add to Library"].tap()
        XCTAssertTrue(app.buttons["Open Book…"].waitForExistence(timeout: Self.patience), "The sheet never opened:\n\(app.debugDescription)")
        try audit(app, screen: "Add to Library sheet at the largest text", types: Self.sizeFindings, accepting: [.navigationTitle("Add to Library"), .barItem("Cancel")])
    }
}
