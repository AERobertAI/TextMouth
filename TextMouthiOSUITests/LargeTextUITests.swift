import XCTest

/// The screens at the largest text size iOS offers (Accessibility Extra Extra
/// Extra Large), where text must grow and wrap and never be cut: Apple's
/// audit of Dynamic Type and of clipped text on the Library with a book,
/// Settings, and the Add to Library sheet. Clipped text and Dynamic Type both
/// fail a test, except findings accepted by element and kind alone: the
/// Library's summary ("partially unsupported", `Accepted.librarySummary`) and,
/// on the two scrolled screens only, findings that name no element: "Text
/// clipped" for a line the screen's edge cuts (`Accepted.scrolledPastTheEdge`),
/// and the two Dynamic Type wordings (`Accepted.unnamedUnsupported`,
/// `Accepted.unnamedPartlyUnsupported`). The screenshots kept with the results show
/// the text grown and wrapped, nothing cut or overlapped. Any other Dynamic
/// Type finding, such as a fixed font on either screen, fails. The size is set at launch, as the
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
        try audit(app, screen: "Library with a book at the largest text", types: Self.sizeFindings, accepting: LibraryUITests.systemParts + [.librarySummary])
        // The summary row, the list's last, is below the first screen at this
        // size: scrolled to, it is audited in place.
        app.swipeUp()
        try audit(app, screen: "Library with a book at the largest text, scrolled", types: Self.sizeFindings, accepting: LibraryUITests.systemParts + [.librarySummary, .scrolledPastTheEdge, .unnamedUnsupported, .unnamedPartlyUnsupported])
    }

    /// Settings, at the largest size, as it first appears.
    func testSettingsHoldsAtTheLargestText() throws {
        let app = try launch(sendingTheBook: false, textSize: Self.largestText)
        tap(app.buttons["Settings"], until: app.navigationBars["Settings"], in: app, what: "Settings")
        try audit(app, screen: "Settings at the largest text", types: Self.sizeFindings, accepting: [.navigationTitle("Settings"), .unnamedUnsupported])
        // Two screens down, where the sliders' captions and the switches are.
        app.swipeUp()
        app.swipeUp()
        try audit(app, screen: "Settings at the largest text, scrolled", types: Self.sizeFindings, accepting: [.navigationTitle("Settings"), .scrolledPastTheEdge, .unnamedUnsupported, .unnamedPartlyUnsupported])
    }

    /// The Add to Library sheet, at the largest size.
    func testAddToLibraryHoldsAtTheLargestText() throws {
        let app = try launch(sendingTheBook: false, textSize: Self.largestText)
        tap(app.buttons["Add to Library"], until: app.buttons["Open Book…"], in: app, what: "Add to Library")
        try audit(app, screen: "Add to Library sheet at the largest text", types: Self.sizeFindings, accepting: [.navigationTitle("Add to Library"), .barItem("Cancel")])
    }
}
