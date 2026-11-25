import XCTest

/// Export on the iPhone (FR31), as XCUITest reads it in the simulator: the
/// sheet the reader's Export this book opens, in the Mac's words and in
/// VoiceOver's order, the Convert to choices, an export into a folder named
/// at launch, and the sheet at the largest text size, with Apple's audit.
///
/// The app runs in a sandbox of its own (TEXTMOUTH_UI_TEST), with the book
/// sent to it. Nothing here makes sound, and nothing is typed. The system's
/// folder picker cannot be driven by a test, so the one export that writes a
/// file names its folder at launch (`TEXTMOUTH_EXPORT_TO`, a debug build's);
/// the file goes into a folder of the test's own, and only an export of the
/// book's own file is pressed, never spoken audio, which the iPhone does not
/// offer yet.
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
    /// a folder is chosen. Nothing is pressed.
    func testTheSheetHasTheSpecsOrder() throws {
        let app = try launchIntoTheReader()

        let elements = try openTheSheet(in: app)

        assertOrder(
            [Self.sheetTitle, "Cancel", "Export", "What to export", "Original file…", "Text as Markdown…", "Text as plain text…", "Choose Folder…"],
            in: elements
        )
        XCTAssertFalse(elements.contains { $0.label.hasPrefix("Text as spoken audio") }, "The iPhone offers spoken audio before phase 2")
        XCTAssertTrue(app.buttons["Export"].exists)
        XCTAssertFalse(app.buttons["Export"].isEnabled, "Export is enabled before a folder is chosen")
        XCTAssertTrue(kindSwitch("Original file", in: app).exists)
        XCTAssertEqual(kindSwitch("Original file", in: app).value as? String, "1", "The first kind is not on")
        XCTAssertEqual(kindSwitch("Text as Markdown", in: app).value as? String, "0")
        keepScreenshot(of: app, named: "Export")
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

    /// The sheet passes Apple's audit, with the book listed and nothing pressed.
    func testTheSheetPassesTheAudit() throws {
        let app = try launchIntoTheReader()
        _ = try openTheSheet(in: app)

        try audit(
            app,
            screen: "Export sheet",
            informing: .dynamicType,
            accepting: [.navigationTitle(Self.sheetTitle), .barItem("Cancel"), .barItem("Export"), .firstHeader("What to export")]
        )
    }

    /// The Cancel button closes the sheet, and the reader's control is there
    /// again.
    func testCancelClosesTheSheet() throws {
        let app = try launchIntoTheReader()
        _ = try openTheSheet(in: app)

        app.buttons["Cancel"].tap()

        XCTAssertTrue(app.buttons["Export this book"].appears(within: Self.patience), "The reader's Export control is not back:\n\(app.debugDescription)")
        XCTAssertFalse(app.navigationBars[Self.sheetTitle].exists)
    }

    // MARK: - Convert To

    /// Turning on Text as Markdown gives it a Convert to row, valued Markdown
    /// (its hint, which a test cannot read, is pinned by `PhoneExportOfferTests`
    /// and the model's); it opens the choices, the
    /// Markdown and then the iPhone's writers, in the Mac's order, Cancel
    /// first, the current one selected. Choosing HTML puts HTML in the row.
    func testConvertToListsTheIPhonesWriters() throws {
        let app = try launchIntoTheReader()
        _ = try openTheSheet(in: app)
        kindSwitch("Text as Markdown", in: app).tap()
        let row = app.buttons["Convert to"]
        XCTAssertTrue(row.appears(within: Self.patience), "No Convert to row:\n\(app.debugDescription)")
        XCTAssertEqual(row.value as? String, "Markdown")

        tap(row, until: app.navigationBars["Convert to"], in: app, what: "the Convert to row")
        XCTAssertTrue(app.buttons["PEF"].appears(within: Self.patience), "No PEF among the choices:\n\(app.debugDescription)")
        let choices = try elementsOfSheet(titled: "Convert to", in: app)
        assertOrder(["Convert to", "Cancel", "Markdown", "HTML", "RTF", "EPUB", "BRF", "PEF"], in: choices)
        XCTAssertTrue(app.buttons["Markdown"].isSelected, "Markdown, the current choice, is not marked selected")

        app.buttons["HTML"].tap()

        XCTAssertTrue(app.buttons["Convert to"].appears(within: Self.patience))
        let chosen = NSPredicate(format: "value == %@", "HTML")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: chosen, object: app.buttons["Convert to"])], timeout: Self.patience), .completed, "The row does not say HTML")
        XCTAssertTrue(kindSwitch("Text as HTML", in: app).exists, "The switch does not name HTML")
    }

    // MARK: - An Export

    /// With a folder named at launch, Export writes the book's own file into
    /// it, the bar then offers Close, and the sheet stays open saying what it
    /// did, in the Mac's words, naming the folder.
    func testExportWritesTheBookIntoTheFolder() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportUITests-\(UUID().uuidString)", isDirectory: true)
        let app = try launchIntoTheReader(environment: ["TEXTMOUTH_EXPORT_TO": folder.path])
        let elements = try openTheSheet(in: app)
        assertOrder(["Export to: \(folder.lastPathComponent)"], in: elements)
        XCTAssertTrue(app.buttons["Export"].isEnabled, "Export is dimmed with a folder chosen")

        app.buttons["Export"].tap()

        let done = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Exported 1 item to")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: Self.patience), "The sheet never said what the export did:\n\(app.debugDescription)")
        XCTAssertEqual(done.label, "Exported 1 item to \(folder.lastPathComponent).")
        XCTAssertTrue(app.buttons["Close"].exists, "No Close once the export has ended")
        XCTAssertTrue(app.navigationBars[Self.sheetTitle].exists, "The sheet closed itself")
        let written = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(written, ["alice.epub"], "The folder holds \(written)")
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
