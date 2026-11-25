import XCTest

/// Export on the iPhone (FR31), as XCUITest reads it in the simulator: the
/// sheet the reader's Export this book opens, in the Mac's words and in
/// VoiceOver's order, with Apple's audit; the Library row's Export…; the
/// Convert to choices and an export into a folder named at launch; and the
/// sheet at the largest text size.
///
/// The app runs in a sandbox of its own (TEXTMOUTH_UI_TEST), with the book
/// sent to it. Nothing here makes sound, and nothing is typed. The system's
/// folder picker cannot be driven by a test, so the one export that writes a
/// file names its folder at launch (`TEXTMOUTH_EXPORT_TO`, a debug build's);
/// the files go into a folder of the test's own, and spoken audio, which the
/// iPhone does not offer yet, is never pressed.
///
/// Four tests, since each interface test costs the planner 25 seconds, and a
/// third iPhone job begins past 1,600 seconds of tests (`ios_ui_tests.py`).
@MainActor
final class ExportUITests: TextMouthUITestCase {
    /// The sheet's title, the Mac's: "Export" and the book's title.
    private static let sheetTitle = "Export \(TextMouthUITestCase.bookTitle)"

    /// Opens the Export sheet from the reader's Export this book, and returns
    /// the sheet's elements in order.
    private func openTheSheet(in app: XCUIApplication) throws -> [Element] {
        try openReaderSheet("Export this book", titled: Self.sheetTitle, waitingFor: "Cancel", in: app)
    }

    /// The switch of the kind whose label begins `start`: a switch's label
    /// names its kind and its size, as "Text as Markdown, 1.1 MB".
    private func kindSwitch(_ start: String, in app: XCUIApplication) -> XCUIElement {
        app.switches.matching(NSPredicate(format: "label BEGINSWITH %@", start)).firstMatch
    }

    // MARK: - The Sheet

    /// The sheet opens from the reader's Export this book: its title, Cancel
    /// and Export, "What to export", a switch for each kind the iPhone offers
    /// (the book's own file, its Markdown, its plain text, and no spoken
    /// audio), and the folder row asking for a folder. Export is dimmed until
    /// a folder is chosen. The sheet passes Apple's audit, and Cancel closes
    /// it, which returns the reader's control.
    func testTheSheetHasTheSpecsOrderPassesTheAuditAndCancels() throws {
        let app = try launchIntoTheReader()

        let elements = try openTheSheet(in: app)

        assertOrder(
            [Self.sheetTitle, "Cancel", "Export", "What to export", "Original file…", "Text as Markdown…", "Text as plain text…", "Choose Folder…"],
            in: elements
        )
        XCTAssertFalse(elements.contains { $0.label.hasPrefix("Text as spoken audio") }, "The iPhone offers spoken audio before phase 2")
        XCTAssertTrue(app.buttons["Export"].exists)
        XCTAssertFalse(app.buttons["Export"].isEnabled, "Export is enabled before a folder is chosen")
        XCTAssertEqual(kindSwitch("Original file", in: app).value as? String, "1", "The first kind is not on")
        XCTAssertEqual(kindSwitch("Text as Markdown", in: app).value as? String, "0")
        keepScreenshot(of: app, named: "Export")

        try audit(
            app,
            screen: "Export sheet",
            informing: .dynamicType,
            accepting: [.navigationTitle(Self.sheetTitle), .barItem("Cancel"), .barItem("Export"), .firstHeader("What to export")]
        )

        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Export this book"].appears(within: Self.patience), "The reader's Export control is not back:\n\(app.debugDescription)")
        XCTAssertFalse(app.navigationBars[Self.sheetTitle].exists)
    }

    /// The Library's row has Export… in its context menu, after Move to Folder...,
    /// and it opens the same sheet: held down, the row offers its commands, and
    /// Export… is one of them.
    func testTheLibraryRowsExportCommandOpensTheSheet() throws {
        let app = try launchIntoTheReader()
        tap(app.navigationBars.buttons.element(boundBy: 0), until: app.navigationBars["Library"], in: app, what: "Back")
        let rowStart = "\(Self.bookTitle), by \(Self.bookAuthor)"
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", rowStart)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: Self.patience), "No row for the book:\n\(app.debugDescription)")

        row.press(forDuration: 1.5)

        let command = app.buttons["Export…"]
        XCTAssertTrue(command.waitForExistence(timeout: Self.patience), "The row's menu has no Export…:\n\(app.debugDescription)")
        command.tap()
        XCTAssertTrue(app.navigationBars[Self.sheetTitle].waitForExistence(timeout: Self.patience), "The sheet did not open:\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons["Cancel"].exists)
    }

    // MARK: - Convert To, and an Export

    /// Turning on Text as Markdown gives it a Convert to row, valued Markdown
    /// (its hint, which a test cannot read, is pinned by `PhoneExportOfferTests`
    /// and the model's); it opens the choices, the Markdown and then the
    /// iPhone's writers, in the Mac's order, Cancel first, the current one
    /// selected. Choosing HTML puts HTML in the row. With a folder named at
    /// launch, Export then writes the book's own file and its HTML into it,
    /// the bar offers Close, and the sheet stays open saying what it did, in
    /// the Mac's words, naming the folder.
    func testConvertToListsTheIPhonesWritersAndExportWritesIntoTheFolder() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportUITests-\(UUID().uuidString)", isDirectory: true)
        let app = try launchIntoTheReader(environment: ["TEXTMOUTH_EXPORT_TO": folder.path])
        let elements = try openTheSheet(in: app)
        assertOrder(["Export to: \(folder.lastPathComponent)"], in: elements)
        XCTAssertTrue(app.buttons["Export"].isEnabled, "Export is dimmed with a folder chosen")

        // The row is one element whose middle is its words; the switch itself is at its trailing edge.
        kindSwitch("Text as Markdown", in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)).tap()
        let row = app.buttons["Convert to"]
        XCTAssertTrue(row.appears(within: Self.patience), "No Convert to row:\n\(app.debugDescription)")
        XCTAssertEqual(row.value as? String, "Markdown")
        tap(row, until: app.navigationBars["Convert to"], in: app, what: "the Convert to row")
        XCTAssertTrue(app.buttons["PEF"].appears(within: Self.patience), "No PEF among the choices:\n\(app.debugDescription)")
        let choices = try elementsOfSheet(titled: "Convert to", in: app)
        assertOrder(["Convert to", "Cancel", "Markdown", "HTML", "RTF", "EPUB", "BRF", "PEF"], in: choices)
        XCTAssertTrue(app.buttons["Markdown"].isSelected, "Markdown, the current choice, is not marked selected")
        // BRF brings the braille rows, in the Mac's order, after the Convert to row.
        app.buttons["BRF"].tap()
        XCTAssertTrue(app.buttons["Braille code"].appears(within: Self.patience), "No Braille code row under BRF:\n\(app.debugDescription)")
        assertOrder(
            ["Convert to", "Braille code", "Cells per line", "Lines per page", "Braille page numbers", "Line ends", "Braille file characters"],
            in: try elementsInOrder(of: app)
        )
        XCTAssertTrue((app.buttons["Braille code"].value as? String ?? "").hasPrefix("Unified English Braille"), "Braille code says \(String(describing: app.buttons["Braille code"].value))")
        // Each row says its value, as the Mac's pop-ups and steppers do.
        let rows = try elementsInOrder(of: app)
        // The first element of the label that has a value: a stepper's words, shown beside it, have none.
        func value(of label: String) -> String? { rows.first { $0.label == label && $0.value != nil }?.value }
        // The rows are named when a value is missing, so the failure shows what the sheet did say.
        let seen = rows.map { "\($0.label)=\($0.value ?? "nil")" }.joined(separator: " | ")
        XCTAssertEqual(value(of: "Cells per line"), "40 cells", "The sheet's elements: \(seen)")
        XCTAssertEqual(value(of: "Lines per page"), "25 lines")
        XCTAssertEqual(value(of: "Line ends"), "CR LF")
        XCTAssertEqual(value(of: "Braille file characters"), "North American Braille ASCII")
        // The three choice rows each open one sheet, with Cancel first and the choices after it.
        tap(app.buttons["Braille code"], until: app.navigationBars["Braille code"], in: app, what: "the Braille code row")
        let codes = try elementsOfSheet(titled: "Braille code", in: app)
        assertOrder(["Braille code", "Cancel"], in: codes)
        XCTAssertTrue(codes.contains { $0.label.hasPrefix("Unified English Braille") }, "No table of Unified English Braille among the choices")
        app.navigationBars["Braille code"].buttons["Cancel"].tap()
        tap(app.buttons["Line ends"], until: app.navigationBars["Line ends"], in: app, what: "the Line ends row")
        assertOrder(["Line ends", "Cancel", "CR LF", "LF"], in: try elementsOfSheet(titled: "Line ends", in: app))
        app.buttons["LF"].tap()
        let lineEnd = NSPredicate(format: "value == %@", "LF")
        XCTAssertEqual(
            XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: lineEnd, object: app.buttons["Line ends"])], timeout: Self.patience),
            .completed, "Line ends does not say LF"
        )
        tap(app.buttons["Braille file characters"], until: app.navigationBars["Braille file characters"], in: app, what: "the Braille file characters row")
        assertOrder(
            ["Braille file characters", "Cancel", "North American Braille ASCII"],
            in: try elementsOfSheet(titled: "Braille file characters", in: app)
        )
        app.navigationBars["Braille file characters"].buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Convert to"].appears(within: Self.patience), "The export sheet is not back")
        // PEF has no line ends or braille file characters.
        tap(app.buttons["Convert to"], until: app.navigationBars["Convert to"], in: app, what: "the Convert to row")
        app.buttons["PEF"].tap()
        XCTAssertTrue(app.buttons["Braille code"].appears(within: Self.patience))
        XCTAssertFalse(app.buttons["Line ends"].exists, "A PEF has line ends")
        XCTAssertFalse(app.buttons["Braille file characters"].exists, "A PEF has braille file characters")
        tap(app.buttons["Convert to"], until: app.navigationBars["Convert to"], in: app, what: "the Convert to row")
        app.buttons["HTML"].tap()
        XCTAssertTrue(kindSwitch("Text as HTML", in: app).appears(within: Self.patience), "The switch does not name HTML:\n\(app.debugDescription)")
        XCTAssertEqual(app.buttons["Convert to"].value as? String, "HTML")

        app.buttons["Export"].tap()

        let done = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Exported 2 items to")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: Self.patience), "The sheet never said what the export did:\n\(app.debugDescription)")
        XCTAssertEqual(done.label, "Exported 2 items to \(folder.lastPathComponent).")
        XCTAssertTrue(app.buttons["Close"].exists, "No Close once the export has ended")
        XCTAssertTrue(app.navigationBars[Self.sheetTitle].exists, "The sheet closed itself")
        let written = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(written.count, 2, "The folder holds \(written)")
        XCTAssertTrue(written.contains("alice.epub"), "The book's own file is missing: \(written)")
        XCTAssertTrue(written.contains { $0.hasSuffix(" - Text.html") }, "The book's HTML is missing: \(written)")
        keepScreenshot(of: app, named: "Export done")
    }

    // MARK: - The Largest Text

    /// At the largest text size the sheet still lists its kinds and its
    /// folder row, and nothing in it is clipped (Dynamic Type is reported,
    /// not failed, as the other sheets' audits report it).
    func testTheSheetHoldsAtTheLargestText() throws {
        let app = try launchIntoTheReader(textSize: Self.largestText)
        _ = try openTheSheet(in: app)
        XCTAssertTrue(kindSwitch("Original file", in: app).appears(within: Self.patience), "No first switch at the largest size:\n\(app.debugDescription)")

        try audit(
            app,
            screen: "Export sheet at the largest text",
            types: [.dynamicType, .textClipped],
            informing: .dynamicType,
            accepting: [.navigationTitle(Self.sheetTitle), .barItem("Cancel"), .barItem("Export"), .scrolledPastTheEdge]
        )
    }
}
