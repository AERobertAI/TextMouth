import XCTest

/// The Interface Language picker on the iPhone (FR39): Settings has a Language section whose row opens the choices; choosing
/// Spanish words the screen in Spanish at once, without a restart, and choosing System puts English back; choosing Arabic
/// words it in Arabic and lays it out from right to left.
///
/// The app runs in a sandbox of its own (TEXTMOUTH_UI_TEST), so the choice is kept in its sandboxed store, never in the
/// real domain. Nothing here makes sound: no book is sent, nothing is played or typed.
@MainActor
final class LanguagePickerUITests: TextMouthUITestCase {
    /// The Language row's label, in English.
    private static let row = "Interface Language"

    /// Opens Settings from the library and scrolls to the Language row, which waits among the later sections.
    private func openSettingsAtTheLanguageRow() throws -> XCUIApplication {
        let app = try launch(sendingTheBook: false)
        tap(app.buttons["Settings"], until: app.navigationBars["Settings"], in: app, what: "Settings")
        try scrollToTheLanguageRow(in: app)
        return app
    }

    /// Swipes up until the row can be tapped, at most ten times.
    private func scrollToTheLanguageRow(in app: XCUIApplication) throws {
        let button = app.buttons[Self.row]
        for _ in 0..<10 where !(button.exists && button.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(button.exists && button.isHittable, "No Interface Language row in Settings:\n\(app.debugDescription)")
    }

    /// The first choice, System, whose label ends with the name of the language it gives (the simulator's English), however
    /// the word "System" is worded in the interface language.
    private static let system = NSPredicate(format: "label ENDSWITH %@", "(English)")

    /// A language's choice, which begins with the language's own name.
    private static func language(_ ownName: String) -> NSPredicate {
        NSPredicate(format: "label BEGINSWITH %@", ownName)
    }

    /// Opens the choices and taps the one `predicate` finds.
    private func choose(_ predicate: NSPredicate, in app: XCUIApplication) throws {
        tap(app.buttons[Self.row], until: app.navigationBars[Self.row], in: app, what: "the Interface Language row")
        let choice = app.buttons.matching(predicate).firstMatch
        // The list makes its rows lazily and sorts the languages by their own names, so a language written in another
        // script (Arabic) is far down the list: swipe up until its row is made and can be tapped, at most fifteen times.
        // The swipe is made on the sheet's own list (the last list in the tree: the screen under the sheet has one too), not on
        // the whole app, whose swipe can drag the sheet itself, and stops if the sheet is gone.
        for _ in 0..<15 where !(choice.exists && choice.isHittable) {
            guard app.navigationBars[Self.row].exists, let list = app.collectionViews.allElementsBoundByIndex.last else { break }
            list.swipeUp()
        }
        XCTAssertTrue(choice.exists && choice.isHittable, "No such choice \(predicate):\n\(app.debugDescription)")
        choice.tap()
        XCTAssertTrue(app.navigationBars[Self.row].waitForNonExistence(timeout: Self.patience), "The choices stayed open")
    }

    /// Waits until the screen's elements include `label`, and returns them in order.
    private func waitForLabel(_ label: String, in app: XCUIApplication) throws -> [Element] {
        let deadline = Date().addingTimeInterval(Self.patience)
        var elements = try elementsInOrder(of: app)
        while !elements.contains(where: { $0.label == label }), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            elements = try elementsInOrder(of: app)
        }
        XCTAssertTrue(elements.contains { $0.label == label }, "No \"\(label)\" in: \(Self.describe(elements))")
        return elements
    }

    /// Spanish and back: Settings' own headings read in Spanish after the choice, with no restart and the screen kept, and
    /// System puts English back. The Language row says the chosen language by its own name.
    func testSpanishAndBackToSystem() throws {
        let app = try openSettingsAtTheLanguageRow()
        try choose(Self.language("Español"), in: app)
        // "About" and "Version" in the catalog's Spanish, on the screen that was open: it was worded again in place.
        let spanish = try waitForLabel("Acerca de", in: app)
        XCTAssertTrue(spanish.contains { $0.label == "Versión" || $0.label.hasPrefix("Versión") }, "Spanish Settings: \(Self.describe(spanish))")
        // The row is a button; the section's heading carries the same words and no value, and comes first.
        let languageRow = try XCTUnwrap(spanish.first { $0.label == Self.row && $0.type == .button })
        XCTAssertEqual(languageRow.value, "Español", "The row says the language by its own name")
        keepScreenshot(of: app, named: "Settings in Spanish")

        try scrollToTheLanguageRow(in: app)
        try choose(Self.system, in: app)
        let english = try waitForLabel("About", in: app)
        XCTAssertFalse(english.contains { $0.label == "Acerca de" }, "Still Spanish: \(Self.describe(english))")
    }

    /// Arabic: Settings' headings read in Arabic, and the screen reads from right to left: the navigation bar's Back button
    /// is at the right edge.
    func testArabicLaysTheScreenOutFromRightToLeft() throws {
        let app = try openSettingsAtTheLanguageRow()
        let backBeforeTheSwitch = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(backBeforeTheSwitch.exists)
        XCTAssertLessThan(backBeforeTheSwitch.frame.midX, app.frame.midX, "Back starts at the left, in English")

        try choose(Self.language("العربية"), in: app)
        let arabic = try waitForLabel("حول", in: app)  // "About"
        keepScreenshot(of: app, named: "Settings in Arabic")
        XCTAssertTrue(arabic.contains { $0.label.hasPrefix("الإصدار") }, "Arabic Settings: \(Self.describe(arabic))")  // "Version"
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertGreaterThan(back.frame.midX, app.frame.midX, "Back moved to the right, the reading direction of Arabic")

        // Back to System, which puts English and the left-to-right layout back.
        try scrollToTheLanguageRow(in: app)
        try choose(Self.system, in: app)
        _ = try waitForLabel("About", in: app)
        XCTAssertLessThan(app.navigationBars.buttons.element(boundBy: 0).frame.midX, app.frame.midX)
    }
}
