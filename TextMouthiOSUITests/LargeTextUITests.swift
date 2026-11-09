import XCTest

/// The screens at the largest text size iOS offers (Accessibility Extra Extra
/// Extra Large), where text must grow and wrap and never be cut: Apple's
/// audit of Dynamic Type and of clipped text on the Library with a book,
/// Settings, and the Add to Library sheet. Clipped text fails a test. Dynamic
/// Type is reported with the results and does not: at this size the audit
/// still flags a plain text node ("partially unsupported", the Library's
/// summary) and the system stepper's controls ("unsupported"), though the
/// screenshots kept with the results show the text grown and wrapped, nothing
/// cut or overlapped (see `audit` and the iPhone section of testing.md). The size is set at launch, as the
/// Larger Text setting would set it, so nothing here changes the simulator's
/// own settings. Nothing is pressed but a book's Back, Settings, and Add to
/// Library, and nothing is typed.
final class LargeTextUITests: TextMouthUITestCase {

    /// The kinds of finding that text size can cause.
    private static let sizeFindings: XCUIAccessibilityAuditType = [.dynamicType, .textClipped]

    /// The Library with a book, at the largest size.
    func testTheLibraryWithABookHoldsAtTheLargestText() throws {
        let app = try launchIntoTheReader(textSize: Self.largestText)
        tap(app.navigationBars.buttons.element(boundBy: 0), until: app.navigationBars["Library"], in: app, what: "Back")
        let rowStart = "\(Self.bookTitle), by \(Self.bookAuthor)"
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", rowStart)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: Self.patience), "No row for the book at the largest size:\n\(app.debugDescription)")
        try audit(app, screen: "Library with a book at the largest text", types: Self.sizeFindings, informing: .dynamicType, accepting: LibraryUITests.systemParts)
        // The summary row, the list's last, is below the first screen at this
        // size: scrolled to, it is audited in place.
        app.swipeUp()
        try audit(app, screen: "Library with a book at the largest text, scrolled", types: Self.sizeFindings, informing: .dynamicType, accepting: LibraryUITests.systemParts)
    }

    /// Settings, at the largest size, as it first appears.
    func testSettingsHoldsAtTheLargestText() throws {
        let app = try launch(sendingTheBook: false, textSize: Self.largestText)
        tap(app.buttons["Settings"], until: app.navigationBars["Settings"], in: app, what: "Settings")
        try audit(app, screen: "Settings at the largest text", types: Self.sizeFindings, informing: .dynamicType, accepting: [.navigationTitle("Settings")])
        // Two screens down, where the sliders' captions and the switches are.
        app.swipeUp()
        app.swipeUp()
        try audit(app, screen: "Settings at the largest text, scrolled", types: Self.sizeFindings, informing: .dynamicType, accepting: [.navigationTitle("Settings")])
    }

    /// The Add to Library sheet, at the largest size.
    func testAddToLibraryHoldsAtTheLargestText() throws {
        let app = try launch(sendingTheBook: false, textSize: Self.largestText)
        tap(app.buttons["Add to Library"], until: app.buttons["Open Book…"], in: app, what: "Add to Library")
        try audit(app, screen: "Add to Library sheet at the largest text", types: Self.sizeFindings, informing: .dynamicType, accepting: [.navigationTitle("Add to Library"), .barItem("Cancel")])
    }
}
