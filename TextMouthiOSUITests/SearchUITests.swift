import XCTest

/// The Search in Book sheet, as XCUITest reads it in the simulator: what it
/// reads, in what order, what a result does, and Apple's accessibility audit.
///
/// Nothing here types: the software keyboard clicks aloud, and the simulator
/// plays through the Mac's speakers. The app fills the sheet's field itself
/// when the launch asks (`TEXTMOUTH_SEARCH_IN_BOOK`, debug builds only,
/// `PhoneLaunchRequest`), so a test names the search it wants in its launch.
/// Nothing is played, and a result's jump is silent, since Auto-play after
/// navigation is off in the sandbox the launch gets.
final class SearchUITests: TextMouthUITestCase {
    /// The word every search here is for: in Alice's Adventures in Wonderland
    /// it names one character, in several chapters, far fewer times than the
    /// book's 500-result limit.
    static let word = "Cheshire"

    /// What the launch asks to be searched for.
    private func searching(for text: String) -> [String: String] {
        ["TEXTMOUTH_SEARCH_IN_BOOK": text]
    }

    /// Launches into the reader with the search named in the launch, and
    /// opens the Search in Book sheet from its button, returning the app.
    private func openSearchSheet(for text: String?) throws -> XCUIApplication {
        let app = try launchIntoTheReader(environment: text.map(searching(for:)) ?? [:])
        _ = try openReaderSheet("Search in Book", titled: "Search in Book", waitingFor: "Back to Book", in: app)
        return app
    }

    /// Waits, for at most `patience`, until a static text of the sheet reads
    /// `ending` (the search's status), and returns the sheet's elements in
    /// order, from the sheet's title on. The status is "Searching…" until the search, which waits a
    /// second for typing to pause, has finished.
    private func waitForStatus(ending suffixes: [String], in app: XCUIApplication) throws -> [Element] {
        let predicate = NSPredicate(format: suffixes.map { _ in "label ENDSWITH %@" }.joined(separator: " OR "), argumentArray: suffixes)
        let status = app.staticTexts.matching(predicate).firstMatch
        XCTAssertTrue(
            status.waitForExistence(timeout: Self.patience),
            "No status ending \(suffixes) appeared. The screen:\n\(app.debugDescription)"
        )
        return try elementsOfSheet(titled: "Search in Book", in: app)
    }

    // MARK: - What it reads

    /// With a search, the sheet reads its title, Back to Book, the field, the
    /// status line, the regular-expression switch, the "Search results"
    /// heading, then the results, each ending with its place in the book.
    func testTheSearchSheetReadsItsFieldStatusSwitchAndResultsInOrder() throws {
        let app = try openSearchSheet(for: Self.word)
        let elements = try waitForStatus(ending: [" matches", " match"], in: app)

        assertOrder([
            "Search in Book", "Back to Book", "Search text", "Use regular expression", "Search results",
        ], in: elements)
        // The status line is between the field and the switch.
        let field = try XCTUnwrap(elements.firstIndex { $0.label == "Search text" }, "No field")
        let toggle = try XCTUnwrap(elements.firstIndex { $0.label == "Use regular expression" }, "No switch")
        let status = elements.firstIndex { $0.label.hasSuffix(" matches") || $0.label.hasSuffix(" match") }
        XCTAssertNotNil(status, "No status line in: \(Self.describe(elements))")
        if let status {
            XCTAssertTrue(field < status && status < toggle, "The status line isn't between the field and the switch: \(Self.describe(elements))")
        }
        // A result reads its context, then where it is.
        let results = elements.drop { $0.label != "Search results" }.dropFirst()
        let first = try XCTUnwrap(results.first, "No result after the heading in: \(Self.describe(elements))")
        XCTAssertTrue(first.label.localizedCaseInsensitiveContains(Self.word), "The first result doesn't hold the word: \(first.label)")
        XCTAssertTrue(first.label.hasSuffix(" percent of book"), "The first result doesn't end with its place: \(first.label)")
        XCTAssertEqual(first.type, .button, "A result isn't a button")
        keepScreenshot(of: app, named: "Search in Book with results")
    }

    /// With nothing searched for, the status line says to enter a term, and
    /// there are no results or heading for them.
    func testWithNothingSearchedTheSheetSaysSo() throws {
        let app = try openSearchSheet(for: nil)
        let elements = try elementsOfSheet(titled: "Search in Book", in: app)

        assertOrder(["Search in Book", "Back to Book", "Search text", "Enter a search term above.", "Use regular expression"], in: elements)
        XCTAssertFalse(elements.contains { $0.label == "Search results" }, "A results heading with no results: \(Self.describe(elements))")
    }

    /// A word the book doesn't hold gives "No matches" and no results.
    func testAWordNotInTheBookGivesNoMatches() throws {
        let app = try openSearchSheet(for: "Xyzzyplugh")
        let elements = try waitForStatus(ending: ["No matches"], in: app)

        XCTAssertFalse(elements.contains { $0.label == "Search results" }, "A results heading with no results: \(Self.describe(elements))")
    }

    // MARK: - What a result does

    /// Choosing a result closes the sheet and moves Book content to it: its
    /// text now holds the word, the sheet is gone, the control that opened
    /// the sheet is back, and nothing plays.
    func testAResultTakesTheReaderToItsPlace() throws {
        let app = try openSearchSheet(for: Self.word)
        let elements = try waitForStatus(ending: [" matches", " match"], in: app)
        let results = elements.drop { $0.label != "Search results" }.dropFirst()
        let first = try XCTUnwrap(results.first, "No result in: \(Self.describe(elements))")

        let row = app.buttons.matching(NSPredicate(format: "label == %@", first.label)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: Self.patience), "The first result isn't there to tap")
        row.tap()

        XCTAssertTrue(
            app.buttons["Back to Book"].waitForNonExistence(timeout: Self.patience),
            "The sheet stayed open after a result was chosen:\n\(app.debugDescription)"
        )
        XCTAssertTrue(app.buttons["Search in Book"].waitForExistence(timeout: Self.patience), "No Search in Book back on the reader")
        XCTAssertEqual(app.buttons["Play"].label, "Play", "The book started to play after a jump")

        // Book content follows the move a moment later: look for the word,
        // for at most a minute.
        var text = ""
        let deadline = Date().addingTimeInterval(Self.patience)
        while Date() < deadline {
            let now = try elementsInOrder(of: app)
            text = now.first { $0.label == "Book content" }?.value ?? ""
            if text.localizedCaseInsensitiveContains(Self.word) { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertTrue(
            text.localizedCaseInsensitiveContains(Self.word),
            "Book content doesn't hold \(Self.word) after the jump; it begins: \(text.prefix(200))"
        )
        keepScreenshot(of: app, named: "Reader after a search result")
    }

    // MARK: - The audit

    /// The sheet with results passes Apple's audit. Findings of the system's
    /// own title and the sheet's bar button are accepted as on every sheet.
    func testTheSearchSheetPassesTheAudit() throws {
        let app = try openSearchSheet(for: Self.word)
        _ = try waitForStatus(ending: [" matches", " match"], in: app)
        // The field holds the keyboard, as the spec has it, and the audit
        // reads the keyboard's own cells too (pass 1, November 9, 2026: three
        // "TUIPredictionViewCell" findings, and contrast findings on the rows
        // under the keyboard). A scroll, which is silent, puts it away
        // (`scrollDismissesKeyboard`); then back to the top.
        app.swipeUp()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: Self.patience), "Scrolling didn't put the keyboard away")
        app.swipeDown()
        try audit(app, screen: "Search in Book sheet", accepting: [.navigationTitle("Search in Book"), .barItem("Back to Book")])
    }
}
