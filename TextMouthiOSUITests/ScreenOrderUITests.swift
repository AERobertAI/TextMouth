import XCTest

/// What the screens besides the reader and the Library's top read, in the
/// order the spec gives them, and Apple's accessibility audit of each: the
/// Add to Library sheet, Settings, and the reader's sheets (Bookmarks,
/// Headings, Go To, Sleep Timer, Voice & Speed, Book Information, and the
/// Navigation unit's choice).
///
/// A screen's order is the order of the accessibility tree read depth first
/// (`elementsInOrder`), which is what VoiceOver follows with a flick unless a
/// container orders its own. Each test opens its screen with silent taps
/// only. It never presses Play, Preview Voice, Where Am I?, a sleep timer's
/// presets, or anything that opens the file picker, and it types nothing:
/// what plays or types is in `PlaybackUITests` and `SearchUITests`, which run
/// only where sound is allowed (`TextMouthUITestCase.requireSound`).
/// A failed order prints the whole order found.
final class ScreenOrderUITests: TextMouthUITestCase {

    // MARK: - Add to Library

    /// The Add to Library sheet reads its title, Cancel, "Open Book…" with the
    /// Mac's summary as its hint, and "Import Folder…" (the spec, under
    /// "Adding a book"), and passes the audit.
    func testTheAddToLibrarySheetHasTheSpecsOrder() throws {
        let app = try launch(sendingTheBook: false)
        XCTAssertTrue(app.buttons["Add to Library"].waitForExistence(timeout: Self.patience), "No Add to Library:\n\(app.debugDescription)")
        app.buttons["Add to Library"].tap()
        XCTAssertTrue(app.buttons["Open Book…"].waitForExistence(timeout: Self.patience), "The sheet never opened:\n\(app.debugDescription)")

        let elements = try elementsOfSheet(titled: "Add to Library", in: app)
        assertOrder(["Add to Library", "Cancel", "Open Book…", "Import Folder…"], in: elements)
        try audit(app, screen: "Add to Library sheet", accepting: [.navigationTitle("Add to Library"), .barItem("Cancel")])
    }

    // MARK: - Settings

    /// Settings, pushed from the Library, reads its rows in the spec's order
    /// (under "Settings", "VoiceOver's order"). The list is longer than the
    /// screen, so the screen is read, scrolled a page, and read again until
    /// nothing new appears, and the rows found are put in the order met.
    /// Only the rows whose words the spec and the code agree on are listed;
    /// the sections' headings and the captions are not.
    func testSettingsHasTheSpecsOrder() throws {
        let app = try launch(sendingTheBook: false)
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: Self.patience), "No Settings button:\n\(app.debugDescription)")
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: Self.patience), "Settings never opened:\n\(app.debugDescription)")

        let elements = try elementsScrolling(in: app)
        assertOrder([
            "Settings",
            "Voice language", "Select voice", "Preview selected voice", "Default speed", "Default pitch",
            "Navigation unit for text books", "Navigation unit for audiobooks", "Auto-play after navigation",
            "Rewind on resume unit",
            "End of book behavior",
            "Follow in Braille",
            "Confirm before removing a book",
            "Reading Statistics",
            "Version", "Share Logs…",
        ], in: elements)
    }

    /// Settings passes Apple's audit, as it first appears, scrolled to the top.
    func testSettingsPassesTheAudit() throws {
        let app = try launch(sendingTheBook: false)
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: Self.patience), "No Settings button")
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: Self.patience), "Settings never opened")
        // Dynamic Type is reported and not failed here: the audit flags a few
        // plain text nodes ("Auto-play after navigation", its caption, and
        // some other captions) as "partially unsupported", and what it finds
        // repeats within a launch but not from one launch to the next (see
        // `audit`). The first header, "Voice", is accepted for contrast: a
        // false positive (`Accepted.firstHeader`).
        try audit(app, screen: "Settings", informing: .dynamicType, accepting: [.navigationTitle("Settings"), .firstHeader("Voice")])
    }

    // MARK: - The reader's sheets

    /// Bookmarks, with no bookmark yet: the title, Done, "Add bookmark at
    /// current position", then the Mac's empty note (the spec, under "The
    /// Bookmarks sheet"). Nothing is added: Add Bookmark would open a sheet
    /// with a field.
    func testTheBookmarksSheetHasTheSpecsOrder() throws {
        let app = try launchIntoTheReader()
        let elements = try openReaderSheet("Bookmarks", titled: "Bookmarks", waitingFor: "Done", in: app)
        assertOrder(["Bookmarks", "Done", "Add bookmark at current position", "No bookmarks yet.…"], in: elements)
        try audit(app, screen: "Bookmarks sheet", accepting: [.navigationTitle("Bookmarks"), .barItem("Done")])
    }

    /// Headings: the title, Back to Book, the Display row (and "Show levels"
    /// before it in a book of several levels), then the list (the spec, under
    /// "The Headings sheet"). Choosing nothing, so the book doesn't move.
    func testTheHeadingsSheetHasTheSpecsOrder() throws {
        let app = try launchIntoTheReader()
        let elements = try openReaderSheet("Headings", titled: "Headings", waitingFor: "Back to Book", in: app)
        assertOrder(["Headings", "Back to Book", "Heading info display mode"], in: elements)
        // Show levels, when the book has several levels, comes before Display.
        if let levels = elements.firstIndex(where: { $0.label == "Show levels" }),
           let display = elements.firstIndex(where: { $0.label == "Heading info display mode" }) {
            XCTAssertLessThan(levels, display, "Show levels is after Display")
        }
        try audit(app, screen: "Headings sheet", accepting: [.navigationTitle("Headings"), .barItem("Back to Book")])
    }

    /// Go To: the title, Cancel, then each field and its Jump, in the spec's
    /// order (under "The Go To sheet"). A text book has the percent and time
    /// fields, and a Page field before them when the book has pages. The
    /// sheet puts the keyboard in its first field, which clicks only when a
    /// key is pressed, and none is.
    func testTheGoToSheetHasTheSpecsOrder() throws {
        let app = try launchIntoTheReader()
        let elements = try openReaderSheet("Go To", titled: "Go To", waitingFor: "Cancel", in: app)
        assertOrder([
            "Go To", "Cancel",
            "Percent through the book", "Jump to percent",
            "Time…", "Jump to time",
        ], in: elements)
        // The Page field, in a book of pages, is first of the three.
        if let page = elements.firstIndex(where: { $0.label == "Page" }),
           let percent = elements.firstIndex(where: { $0.label == "Percent through the book" }) {
            XCTAssertLessThan(page, percent, "Page is after Percent through the book")
        }
        try audit(app, screen: "Go To sheet", accepting: [.navigationTitle("Go To"), .barItem("Cancel")])
    }

    /// Sleep Timer, with none running: the title, Close, New Timer, the
    /// five presets, the custom minutes field, its stepper and Set, then
    /// Stop At with End of heading and End of book (the spec, under "The
    /// Sleep Timer sheet"). No preset is pressed, since one would start the
    /// book playing.
    func testTheSleepTimerSheetHasTheSpecsOrder() throws {
        let app = try launchIntoTheReader()
        let elements = try openReaderSheet("Sleep Timer", titled: "Sleep Timer", waitingFor: "Close", in: app)
        assertOrder([
            "Sleep Timer", "Close", "New Timer",
            "Set timer for 10 minutes and start playing",
            "Set timer for 15 minutes and start playing",
            "Set timer for 30 minutes and start playing",
            "Set timer for 45 minutes and start playing",
            "Set timer for 60 minutes and start playing",
            "Custom timer minutes", "Adjust minutes",
            // The custom timer's Set button is labeled with its 30 minutes.
            "Set timer for 30 minutes and start playing",
            "Stop at the end of this heading and start playing",
            "Stop at the end of the book and start playing",
        ], in: elements)
        // No timer runs, so there is no Current Timer section.
        XCTAssertFalse(elements.contains { $0.label == "Current Timer" }, "Current Timer shows with no timer running")
        // Dynamic Type is reported and not failed: the audit flags the
        // stepper's title, "Adjust minutes" (see Settings). The first header,
        // "New Timer", is accepted for contrast: a false positive
        // (`Accepted.firstHeader`).
        try audit(app, screen: "Sleep Timer sheet", informing: .dynamicType, accepting: [.navigationTitle("Sleep Timer"), .barItem("Close"), .firstHeader("New Timer")])
    }

    /// Voice & Speed for a text book: the title, Close, Language, Voice,
    /// Preview Voice, Speed, Pitch, When this book ends, then Save to Global
    /// Settings and Reset to Global Settings (the spec, under "The Voice &
    /// Speed sheet"). Where the simulator has no voices, the three voice rows
    /// give way to the sentence that says so. Preview Voice is never pressed.
    func testTheVoiceSheetHasTheSpecsOrder() throws {
        let app = try launchIntoTheReader()
        let elements = try openReaderSheet("Voice", titled: "Voice & Speed for This Book", waitingFor: "Close", in: app)
        // Voices load a moment after the sheet opens: Speed is always there.
        if !app.sliders["Speed"].waitForExistence(timeout: Self.patience) {
            // What the sheet showed in its place: every slider by label,
            // identifier, and value, and the whole order with each type.
            let sliders = app.sliders.allElementsBoundByIndex.map {
                "label \"\($0.label)\" id \"\($0.identifier)\" value \"\(String(describing: $0.value))\""
            }
            let order = try elementsInOrder(of: app).map { "\($0.type.rawValue):\($0.label)" }
            XCTFail("The sheet never showed Speed. Sliders: \(sliders). Order (type:label): \(order.joined(separator: " | "))")
            return
        }
        let settled = try elementsOfSheet(titled: "Voice & Speed for This Book", in: app)
        let hasVoices = !settled.contains { $0.label.hasPrefix("No voices are installed") }
        let voiceRows = hasVoices ? ["Voice language filter", "Select voice for this book", "Preview selected voice"] : []
        assertOrder(
            ["Voice & Speed for This Book", "Close"] + voiceRows + [
                "Speed", "Pitch", "End of book behavior for this book",
                "Save this book's voice, speed, and pitch as the global defaults",
                "Reset this book's voice, speed, and pitch to the global defaults",
            ],
            in: settled.isEmpty ? elements : settled
        )
        try audit(app, screen: "Voice & Speed sheet", accepting: [.navigationTitle("Voice & Speed for This Book"), .barItem("Close")])
    }

    /// Book Information, from the reader: the title, Cancel and Save in the
    /// toolbar, "Book title" and the author, then the read-only rows (the
    /// spec, under "The Book Info sheet"). The book is an EPUB, whose form
    /// uses the Mac's metadata editor's words: its author field is "Author",
    /// where a book with no more than a title and author has "Book author".
    func testTheBookInformationSheetHasTheSpecsOrder() throws {
        let app = try launchIntoTheReader()
        let elements = try openReaderSheet("Book Info", titled: "Book Information", waitingFor: "Cancel", in: app)
        assertOrder(["Book Information", "Cancel", "Save", "Book title", "Author", "Publisher", "Publication date", "Format", "Added", "Last Opened", "Word Count"], in: elements)
        // Dynamic Type is reported and not failed: the audit flags the
        // read-only rows at the bottom, "Last Opened" and "Word Count" and
        // their values (see Settings).
        try audit(app, screen: "Book Information sheet", informing: .dynamicType, accepting: [.navigationTitle("Book Information"), .barItem("Cancel"), .barItem("Save")])
    }

    /// Navigation unit's choice: the title, Cancel, then the Mac's units in
    /// its order, the current one (Sentence) selected (the spec, under
    /// "Navigation unit"). Nothing is chosen, so the unit stays.
    func testTheNavigationUnitChoiceHasTheSpecsOrder() throws {
        let app = try launchIntoTheReader()
        let elements = try openReaderSheet("Navigation unit", titled: "Navigation unit", waitingFor: "Cancel", in: app)
        assertOrder([
            "Navigation unit", "Cancel",
            "10 seconds", "15 seconds", "30 seconds", "60 seconds",
            "Sentence", "Paragraph", "Heading", "Bookmark",
        ], in: elements)
        XCTAssertTrue(app.buttons["Sentence"].isSelected, "Sentence, the current unit, isn't marked selected")
        try audit(app, screen: "Navigation unit choice", accepting: [.navigationTitle("Navigation unit"), .barItem("Cancel")])
    }

    // MARK: - Helpers

    /// Every element of a screen longer than the display: the screen as it
    /// stands, then scrolled a page at a time (a swipe up, which is silent)
    /// until a page adds nothing new, at most `limit` times. Each new element
    /// joins at the end, so the whole is in the order the screen was met.
    private func elementsScrolling(in app: XCUIApplication, limit: Int = 15) throws -> [Element] {
        var all = try elementsInOrder(of: app)
        // What has been met, by kind and label (a scrolled screen shows the
        // same row twice at the edges).
        var met = Set(all.map { "\($0.type.rawValue)|\($0.label)" })
        for _ in 0..<limit {
            app.swipeUp()
            let fresh = try elementsInOrder(of: app).filter { met.insert("\($0.type.rawValue)|\($0.label)").inserted }
            if fresh.isEmpty { break }
            all.append(contentsOf: fresh)
        }
        return all
    }
}
