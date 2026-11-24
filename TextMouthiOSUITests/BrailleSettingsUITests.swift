import XCTest

/// The Braille section of the iPhone's Settings (FR32), as VoiceOver reads it: the section's heading, the Braille code row
/// with the table in use as its value, the braille file characters row, the guess switch; the list of tables the row opens,
/// grouped by language, each table a row whose label says its code, grade, and language, and whose selected state is its
/// trait; and a choice that sticks.
///
/// The app runs in a sandbox of its own (TEXTMOUTH_UI_TEST), so the setting is kept in its sandboxed store. Nothing here makes
/// sound: no book is sent, nothing is played or typed.
@MainActor
final class BrailleSettingsUITests: TextMouthUITestCase {
    /// The row's label, and the title of its list.
    private static let row = "Braille code"
    /// The default table's words, which are the row's value and the label of its choice until another is chosen.
    private static let defaultTable = "Unified English Braille, contracted (Grade 2), in English"

    /// Opens Settings from the library and scrolls to the Braille code row, which waits among the later sections.
    private func openSettingsAtTheBrailleRow() throws -> XCUIApplication {
        let app = try launch(sendingTheBook: false)
        try scrollToTheBrailleRow(afterOpeningSettingsIn: app)
        return app
    }

    /// Opens Settings from the library of `app`, and scrolls to the Braille code row.
    private func scrollToTheBrailleRow(afterOpeningSettingsIn app: XCUIApplication) throws {
        tap(app.buttons["Settings"], until: app.navigationBars["Settings"], in: app, what: "Settings")
        let button = app.buttons[Self.row]
        for _ in 0..<10 where !(button.exists && button.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(button.exists && button.isHittable, "No \"\(Self.row)\" row in Settings:\n\(app.debugDescription)")
    }

    /// The section reads in order: its heading, the Braille code row with the table in use as its value, the caption, the braille
    /// file characters row with its value, and the guess switch.
    func testTheBrailleSectionReadsRight() throws {
        let app = try openSettingsAtTheBrailleRow()
        let elements = try elementsInOrder(of: app)
        assertOrder(["Braille", Self.row, "TextMouth reads braille files you add from now on…", "Braille file characters", "Guess the braille code of new books"], in: elements)
        let row = try XCTUnwrap(elements.first { $0.label == Self.row && $0.type == .button }, Self.describe(elements))
        XCTAssertEqual(row.value, Self.defaultTable, "The row says the table in use as its value")
        let characters = try XCTUnwrap(elements.first { $0.label == "Braille file characters" && $0.type == .button }, Self.describe(elements))
        XCTAssertFalse((characters.value ?? "").isEmpty, "The braille file characters row has no value")
        XCTAssertTrue(elements.contains { $0.label == "Guess the braille code of new books" }, Self.describe(elements))
        keepScreenshot(of: app, named: "Settings, Braille")
    }

    /// The row opens a list under its title, headed by languages; the table in use is its row, selected, with a label that says
    /// its code, grade, and language; Cancel closes it with the setting as it was.
    func testTheListIsGroupedByLanguageAndMarksTheTableInUse() throws {
        let app = try openSettingsAtTheBrailleRow()
        app.buttons[Self.row].tap()
        XCTAssertTrue(app.navigationBars[Self.row].waitForExistence(timeout: Self.patience), "The list never opened:\n\(app.debugDescription)")
        let current = app.buttons[Self.defaultTable]
        XCTAssertTrue(current.waitForExistence(timeout: Self.patience), "No row for the table in use:\n\(app.debugDescription)")
        XCTAssertTrue(current.isSelected, "The table in use is not marked selected")
        // English heads the list, as a heading.
        let headings = app.staticTexts.matching(NSPredicate(format: "label == %@", "English"))
        XCTAssertTrue(headings.firstMatch.waitForExistence(timeout: Self.patience), "No English heading:\n\(app.debugDescription)")
        // Every table row says its language after its code and grade.
        let rows = app.buttons.allElementsBoundByIndex.map(\.label).filter { $0.contains(", in ") }
        XCTAssertFalse(rows.isEmpty)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars[Self.row].waitForNonExistence(timeout: Self.patience), "Cancel left the list open")
        XCTAssertEqual(app.buttons[Self.row].value as? String, Self.defaultTable)
    }

    /// A choice sticks: a French table chosen from the list is the row's value, is marked selected the next time the list opens,
    /// and is still the row's value when Settings is left and opened again, read from the setting's store afresh. A relaunch is
    /// not asked for: an app a UI test launches runs in a sandbox that begins empty at every launch (`TextMouthRuntime`), so a
    /// second launch would show the default; that the setting is kept across launches is the store's, and the unit tests'
    /// (`PhoneBrailleSettingsTests.testAChoiceIsTheSettingAndSticks`).
    func testAChoiceSticks() throws {
        let app = try openSettingsAtTheBrailleRow()
        app.buttons[Self.row].tap()
        XCTAssertTrue(app.navigationBars[Self.row].waitForExistence(timeout: Self.patience))
        let french = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", ", in French")).firstMatch
        // The list makes its rows lazily: swipe its own list up until a French table can be tapped, at most thirty times.
        for _ in 0..<30 where !(french.exists && french.isHittable) {
            guard let list = app.collectionViews.allElementsBoundByIndex.last else { break }
            list.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(french.exists && french.isHittable, "No French table in the list:\n\(app.debugDescription)")
        let label = french.label
        french.tap()
        XCTAssertTrue(app.navigationBars[Self.row].waitForNonExistence(timeout: Self.patience), "The list stayed open after a choice")
        let button = app.buttons[Self.row]
        XCTAssertTrue(button.waitForExistence(timeout: Self.patience))
        XCTAssertEqual(button.value as? String, label, "The row does not say the choice")
        // Opened again, the choice is the one marked.
        button.tap()
        XCTAssertTrue(app.navigationBars[Self.row].waitForExistence(timeout: Self.patience))
        let marked = app.buttons[label]
        for _ in 0..<30 where !(marked.exists && marked.isHittable) {
            guard let list = app.collectionViews.allElementsBoundByIndex.last else { break }
            list.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(marked.exists, "The chosen table is not in the list:\n\(app.debugDescription)")
        XCTAssertTrue(marked.isSelected, "The chosen table is not marked selected")

        // Leave Settings and open them again: the screen is made afresh from the setting.
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars[Self.row].waitForNonExistence(timeout: Self.patience), "Cancel left the list open")
        let back = app.navigationBars["Settings"].buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: Self.patience), "No Back button:\n\(app.debugDescription)")
        back.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForNonExistence(timeout: Self.patience), "Settings stayed open")
        try scrollToTheBrailleRow(afterOpeningSettingsIn: app)
        XCTAssertEqual(app.buttons[Self.row].value as? String, label, "The choice did not outlast leaving Settings")
    }
}
