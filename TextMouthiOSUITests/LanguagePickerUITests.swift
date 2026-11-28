import XCTest

/// The Interface Language picker on the iPhone (FR39): Settings has a Language section whose row opens the choices; choosing
/// Spanish words the screen in Spanish at once, without a restart, and choosing System puts English back; choosing Arabic
/// words it in Arabic and lays it out from right to left.
///
/// The app runs in a sandbox of its own (TEXTMOUTH_UI_TEST), so the choice is kept in its sandboxed store, never in the
/// real domain. Nothing here makes sound: no book is sent, nothing is played or typed.
@MainActor
final class LanguagePickerUITests: TextMouthUITestCase {
    /// The Language row's label, in English. The row and the choices' title are worded in the interface language, so after
    /// a switch they are found by that language's words.
    private static let row = "Interface Language"
    /// The row's label, and the choices' title, in the catalog's Spanish.
    private static let spanishRow = "Idioma de la interfaz"
    /// The row's label, and the choices' title, in the catalog's Arabic.
    private static let arabicRow = "لغة الواجهة"

    /// Opens Settings from the library and scrolls to the Language row, which waits among the later sections.
    private func openSettingsAtTheLanguageRow() throws -> XCUIApplication {
        let app = try launch(sendingTheBook: false)
        tap(app.buttons["Settings"], until: app.navigationBars["Settings"], in: app, what: "Settings")
        try scrollToTheLanguageRow(in: app)
        return app
    }

    /// Swipes up until the row labelled `row` can be tapped, at most ten times, then down, at most ten times, for a screen
    /// that was scrolled past the row (the Settings list is long, and a search for a label further down leaves it near its end).
    private func scrollToTheLanguageRow(in app: XCUIApplication, row: String = LanguagePickerUITests.row) throws {
        let button = app.buttons[row]
        for goingUp in [true, false] {
            for _ in 0..<10 where !(button.exists && button.isHittable) {
                if goingUp { app.swipeUp() } else { app.swipeDown() }
            }
        }
        XCTAssertTrue(button.exists && button.isHittable, "No \"\(row)\" row in Settings:\n\(app.debugDescription)")
    }

    /// The first choice, System, whose label ends with the name of the language it gives (the simulator's English), however
    /// the word "System" is worded in the interface language.
    private static let system = NSPredicate(format: "label ENDSWITH %@", "(English)")

    /// A language's choice, which begins with the language's own name.
    private static func language(_ ownName: String) -> NSPredicate {
        NSPredicate(format: "label BEGINSWITH %@", ownName)
    }

    /// Opens the choices from the row labelled `row`, in the words of the interface language now in use, and taps the one
    /// `predicate` finds. `rowAfter` is the same title in the language the choice switches to: the open choices are worded
    /// again at once, so they have closed only when neither title is left.
    private func choose(_ predicate: NSPredicate, in app: XCUIApplication, from row: String = LanguagePickerUITests.row, to rowAfter: String) throws {
        tap(app.buttons[row], until: app.navigationBars[row], in: app, what: "the \"\(row)\" row")
        let choice = app.buttons.matching(predicate).firstMatch
        // The list makes its rows lazily, sorts the languages by their own names, and opens at the current choice, so the row
        // wanted may be above or below: swipe up until it is made and can be tapped (a language in another script, Arabic, is
        // far down), then, if it was above, swipe down, at most fifteen swipes each way. The swipe is made on the sheet's own
        // list (the last list in the tree: the screen under the sheet has one too), not on the whole app, whose swipe can drag
        // the sheet itself, and stops if the sheet is gone. Slowly, so the list's momentum does not carry a row past the screen
        // between two looks.
        // A row counts as ready only when it is below the sheet's navigation bar: a row scrolled up under or past the bar
        // still "exists" and "is hittable", but a tap on its middle lands on the bar or outside the sheet and chooses nothing
        // (train 1123-0731 left the choices open that way, with the screen behind them unchanged). A row found above the
        // bar is brought back by swiping down at once.
        let bar = app.navigationBars[row]
        func isReady() -> Bool {
            choice.exists && choice.isHittable && (!bar.exists || choice.frame.minY >= bar.frame.maxY)
        }
        func isAboveTheBar() -> Bool {
            choice.exists && bar.exists && choice.frame.minY < bar.frame.maxY
        }
        for goingUp in [true, false] {
            for _ in 0..<15 where !isReady() {
                guard bar.exists, let list = app.collectionViews.allElementsBoundByIndex.last else { break }
                if goingUp && !isAboveTheBar() { list.swipeUp(velocity: .slow) } else { list.swipeDown(velocity: .slow) }
            }
        }
        let seen = app.buttons.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
        XCTAssertTrue(isReady(), "No such choice \(predicate), at \(choice.frame) under a bar ending at \(bar.frame.maxY). The buttons now made: \(seen)")
        choice.tap()
        for title in [row, rowAfter] where !app.navigationBars[title].waitForNonExistence(timeout: Self.patience) {
            // What is on the screen, sheet and all, so a failure says whether the choices were left open or only their bar.
            XCTFail("The choices stayed open, as \"\(title)\":\n\(app.debugDescription)")
        }
    }

    /// Waits until the screen's elements include `label`, and returns them in order. Settings is a long list that makes its
    /// rows lazily, so the label may be off the screen (the Braille section pushed About past the first screen): while it is
    /// missing the list is scrolled, up first, and turned round whenever a swipe leaves the screen as it was (the list's end).
    private func waitForLabel(_ label: String, in app: XCUIApplication) throws -> [Element] {
        let deadline = Date().addingTimeInterval(Self.patience)
        var elements = try elementsInOrder(of: app)
        var goingUp = true
        while !elements.contains(where: { $0.label == label }), Date() < deadline {
            if goingUp { app.swipeUp() } else { app.swipeDown() }
            Thread.sleep(forTimeInterval: 0.5)
            let scrolled = try elementsInOrder(of: app)
            if scrolled.map(\.label) == elements.map(\.label) { goingUp.toggle() }
            elements = scrolled
        }
        XCTAssertTrue(elements.contains { $0.label == label }, "No \"\(label)\" in: \(Self.describe(elements))")
        return elements
    }

    /// Spanish and back: Settings' own headings read in Spanish after the choice, with no restart and the screen kept, and
    /// System puts English back. The Language row says the chosen language by its own name.
    func testSpanishAndBackToSystem() throws {
        let app = try openSettingsAtTheLanguageRow()
        try choose(Self.language("Español"), in: app, to: Self.spanishRow)
        // The screen that was open is worded again in place: its title reads "Ajustes" and the Language row, which the
        // screen is still scrolled to, is a button worded in Spanish too, saying the language by its own name.
        let reworded = try waitForLabel("Ajustes", in: app)
        let languageRow = try XCTUnwrap(reworded.first { $0.label == Self.spanishRow && $0.type == .button })
        XCTAssertEqual(languageRow.value, "Español", "The row says the language by its own name")
        keepScreenshot(of: app, named: "Settings in Spanish")
        // "About" and "Version" in the catalog's Spanish, further down the list than the first screen.
        let spanish = try waitForLabel("Acerca de", in: app)
        XCTAssertTrue(spanish.contains { $0.label == "Versión" || $0.label.hasPrefix("Versión") }, "Spanish Settings: \(Self.describe(spanish))")

        try scrollToTheLanguageRow(in: app, row: Self.spanishRow)
        try choose(Self.system, in: app, from: Self.spanishRow, to: Self.row)
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

        try choose(Self.language("العربية"), in: app, to: Self.arabicRow)
        // The title "Settings", and the heading "Times": the screen is worded again at its top.
        _ = try waitForLabel("الإعدادات", in: app)
        keepScreenshot(of: app, named: "Settings in Arabic")
        // The "Times" heading is further up the list than the Language row this screen is scrolled to.
        let arabic = try waitForLabel("الأوقات", in: app)
        XCTAssertTrue(arabic.contains { $0.label == "الأوقات" }, "Arabic Settings: \(Self.describe(arabic))")
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertGreaterThan(back.frame.midX, app.frame.midX, "Back moved to the right, the reading direction of Arabic")

        // Back to System, which puts English and the left-to-right layout back. The row is worded in Arabic now.
        try scrollToTheLanguageRow(in: app, row: Self.arabicRow)
        try choose(Self.system, in: app, from: Self.arabicRow, to: Self.row)
        // English is back: the screen is at its top, where the title is "Settings" and no heading is Arabic.
        let english = try waitForLabel("Settings", in: app)
        XCTAssertFalse(english.contains { $0.label == "الإعدادات" }, "Still Arabic: \(Self.describe(english))")
        XCTAssertLessThan(app.navigationBars.buttons.element(boundBy: 0).frame.midX, app.frame.midX)
    }
}
