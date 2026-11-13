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
/// Library, and nothing is typed, except in the Search in Book sheet's test,
/// which types a search (so it runs only where sound is allowed, on a GitHub
/// runner) and measures that the sheet's text grows, in place of failing on
/// Dynamic Type findings, which the sheet's own audit (`SearchUITests`) reports
/// without failing.
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

    // MARK: - The Search in Book sheet

    /// What the Search sheet's text sizes are checked on: the search field, the line that says what was found, the
    /// regular-expression switch, and the "Search results" heading. These four were the findings of the sheet's audit that
    /// said "Dynamic Type font sizes are partially unsupported" in run 43032983986 and in none of the three before it.
    private static let searchParts = [TextMouthUITestCase.searchFieldLabel, "the status line", "Use regular expression", "Search results"]

    /// The height in points of each of `searchParts`, as the sheet with results shows them in `app`.
    private func searchPartHeights(in app: XCUIApplication) throws -> [String: CGFloat] {
        let elements = try waitForResults(in: app)
        let labels = [Self.searchFieldLabel, "Use regular expression", "Search results"]
        var heights = Dictionary(uniqueKeysWithValues: labels.compactMap { label in
            elements.first { $0.label == label }.map { (label, $0.frame.height) }
        })
        // The status line is known by how it ends ("7 matches"): the number changes with the book.
        if let status = elements.first(where: { $0.label.hasSuffix(" matches") || $0.label.hasSuffix(" match") }) {
            heights["the status line"] = status.frame.height
        }
        XCTAssertEqual(Set(heights.keys), Set(Self.searchParts), "The sheet is missing a part. The sheet's elements: \(Self.describe(elements))")
        return heights
    }

    /// The least each part must grow, as its height at the largest text size over its height at the default size. Each
    /// bound lies between what a part capped at Accessibility 2 (`.accessibility2`, the largest cap that still shows
    /// growth) measures and what the uncapped sheet measures, so a cap at that size or any smaller one fails and the
    /// sheet as it is passes. The ratios come from the heights of GitHub run 43066870675 (the uncapped sheet) and
    /// PROOF_RUN (the sheet with all four parts capped at `.accessibility2`):
    ///
    /// | part                          | default height | uncapped | capped at AX2 | bound |
    /// | ----------------------------- | -------------- | -------- | ------------- | ----- |
    /// | the field                     | 22             | 2.95     | CAPPED_FIELD  | 2.4   |
    /// | the status line               | 52             | 1.79     | CAPPED_STATUS | 1.5   |
    /// | the regular-expression switch | 52             | 2.99     | CAPPED_SWITCH | 2.4   |
    /// | the "Search results" heading  | 40.3           | 2.07     | CAPPED_HEADING | 1.8  |
    ///
    /// The parts do not share one bound because they do not grow alike: the status line and the heading carry padding
    /// that does not grow, so their ratios are lower, and the field is one line of the largest text.
    private static let minimumGrowth: [String: CGFloat] = [
        TextMouthUITestCase.searchFieldLabel: 2.4,
        "the status line": 1.5,
        "Use regular expression": 2.4,
        "Search results": 1.8,
    ]

    /// The Search in Book sheet with results, at the largest size: its text grows with the text size (so the findings of
    /// Apple's Dynamic Type audit on it, which `SearchUITests` reports and does not fail, are not that text stays small),
    /// and none of it is cut.
    ///
    /// **Growth** is measured, not left to the audit: each of the four parts the audit named is at least its
    /// `minimumGrowth` times as tall at the largest size as at the default size, in the same test, on the same book and
    /// search. A part drawn in a fixed font would be as tall at both sizes, and one capped at Accessibility 2 or any
    /// smaller size falls short of its bound. Every part's heights and ratio are printed on every run, and the failure
    /// names every part that fell short, not only the first. **Clipping** is the audit's `textClipped` kind, which fails
    /// the test but for the same findings as the other screens accept. Typing makes sound, so the test runs only where
    /// sound is allowed, on a GitHub runner.
    func testTheSearchSheetHoldsAtTheLargestText() throws {
        let normal = try openSearchSheet(typing: SearchUITests.word)
        let normalHeights = try searchPartHeights(in: normal)
        // One app at a time: the second launch is of the same app.
        normal.terminate()

        let large = try openSearchSheet(typing: SearchUITests.word, textSize: Self.largestText)
        let largeHeights = try searchPartHeights(in: large)
        var shortfalls: [String] = []
        for part in Self.searchParts {
            let before = normalHeights[part] ?? 0
            let after = largeHeights[part] ?? 0
            let ratio = before > 0 ? after / before : 0
            let bound = Self.minimumGrowth[part] ?? 0
            // In the log on every run, so that a bound can be read against what the sheet measures.
            let line = "SEARCH-GROWTH \"\(part)\": default \(before) points, largest \(after) points, ratio \(ratio), bound \(bound)"
            print(line)
            NSLog("%@", line)
            if !(ratio >= bound) {
                shortfalls.append("\"\(part)\" grew \(ratio) times (\(before) to \(after) points) and must grow at least \(bound) times")
            }
        }
        XCTAssertTrue(
            shortfalls.isEmpty,
            "The text of \(shortfalls.count) part(s) of the Search sheet did not grow with the text size: " + shortfalls.joined(separator: "; ")
        )
        keepScreenshot(of: large, named: "Search in Book at the largest text")
        // The keyboard's own Search key puts it away, as the sheet's audit test does, so that the audit reads the sheet.
        let searchKey = large.keyboards.buttons["Search"]
        if searchKey.waitForExistence(timeout: 5) {
            searchKey.tap()
        }
        try audit(
            large, screen: "Search in Book sheet at the largest text", types: .textClipped,
            accepting: [.navigationTitle("Search in Book"), .barItem("Back to Book"), .scrolledPastTheEdge]
        )
    }
}
