import XCTest

/// The Sync section of the iPhone's Settings (FR43), as VoiceOver reads it before sync is set up: the heading, what sync does,
/// the status "Sync is off.", and the two buttons that begin it. Nothing is chosen, so no folder is made, no picker opens, and no
/// file is touched; and the library's summary offers no Sync Now yet (nothing is added before a folder is chosen).
///
/// The app runs in a sandbox of its own (TEXTMOUTH_UI_TEST). Nothing here makes sound or types.
@MainActor
final class SyncSettingsUITests: TextMouthUITestCase {
    /// The first button of the section with sync off.
    private static let setUp = "Set Up Sync…"
    /// The second.
    private static let join = "Join Sync Folder…"

    /// Opens Settings from the library and scrolls to the Set Up Sync… button, which waits at the end of the screen.
    private func openSettingsAtTheSyncSection() throws -> XCUIApplication {
        let app = try launch(sendingTheBook: false)
        tap(app.buttons["Settings"], until: app.navigationBars["Settings"], in: app, what: "Settings")
        let button = app.buttons[Self.setUp]
        for _ in 0..<20 where !(button.exists && button.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(button.exists && button.isHittable, "No \"\(Self.setUp)\" button in Settings:\n\(app.debugDescription)")
        return app
    }

    /// The section reads in order after About: its heading, what it does, the status, and the two buttons, each a button with its
    /// own label.
    func testTheSectionReadsRightWithSyncOff() throws {
        let app = try openSettingsAtTheSyncSection()
        let elements = try elementsInOrder(of: app)
        assertOrder(
            [
                "About",
                "Sync",
                "Keeps your books, places, and bookmarks the same on your Mac and iPhone, through iCloud Drive.",
                "Sync is off.",
                Self.setUp,
                Self.join,
            ],
            in: elements
        )
        for label in [Self.setUp, Self.join] {
            XCTAssertTrue(
                elements.contains { $0.label == label && $0.type == .button },
                "\"\(label)\" is not a button:\n\(Self.describe(elements))"
            )
        }
        XCTAssertFalse(elements.contains { $0.label == "Sync Now" }, "Sync Now is offered before sync is set up")
        keepScreenshot(of: app, named: "Settings, Sync off")
    }

    /// Set Up through a sandbox folder, then Stop, as VoiceOver reads them: the Debug seam (TEXTMOUTH_SYNC_FOLDER) takes the
    /// test's folder for the one the picker would give, since a test can't drive the system's picker. Sync turns on, the
    /// controls become Sync Now and Stop Syncing…, the status stops saying "Sync is off.", and Stop Syncing… asks first and
    /// puts the section back. Nothing here touches iCloud Drive or the person's library: the folder is made in the test's
    /// own temporary folder.
    func testSetUpAndStopThroughASandboxFolder() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("sync-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let app = try launch(sendingBookAt: nil, environment: ["TEXTMOUTH_SYNC_FOLDER": parent.path])
        tap(app.buttons["Settings"], until: app.navigationBars["Settings"], in: app, what: "Settings")
        let setUp = app.buttons[Self.setUp]
        for _ in 0..<20 where !(setUp.exists && setUp.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(setUp.exists && setUp.isHittable, "No \"\(Self.setUp)\" button in Settings:\n\(app.debugDescription)")
        setUp.tap()

        // Sync is on: its two buttons are there, and the section no longer says it is off.
        let syncNow = app.buttons["Sync Now"]
        let stop = app.buttons["Stop Syncing…"]
        // Sync's two settings (Books on this device, and the days) now come before the buttons, which a list may not have
        // drawn yet: scroll until Sync Now is there.
        for _ in 0..<20 where !syncNow.waitForExistence(timeout: 3) {
            app.swipeUp()
        }
        XCTAssertTrue(syncNow.appears(within: 60), "Sync Now never appeared:\n\(app.debugDescription)")
        for _ in 0..<20 where !stop.waitForExistence(timeout: 3) {
            app.swipeUp()
        }
        XCTAssertTrue(stop.appears(within: Self.patience), "Stop Syncing… never appeared:\n\(app.debugDescription)")
        XCTAssertFalse(app.buttons[Self.setUp].exists, "Set Up Sync… is still offered with sync on")
        let on = try elementsInOrder(of: app)
        XCTAssertFalse(on.contains { $0.label == "Sync is off." }, Self.describe(on))
        keepScreenshot(of: app, named: "Settings, Sync on")

        // Stop Syncing… asks first; Cancel changes nothing.
        stop.tap()
        let cancel = app.alerts.buttons["Cancel"]
        XCTAssertTrue(cancel.appears(within: Self.patience), "No question before stopping:\n\(app.debugDescription)")
        cancel.tap()
        XCTAssertTrue(app.buttons["Sync Now"].appears(within: Self.patience), "Cancel stopped sync")
        // Answering yes stops it, and the section is as it was.
        app.buttons["Stop Syncing…"].tap()
        let confirm = app.alerts.buttons["Stop Syncing"]
        XCTAssertTrue(confirm.appears(within: Self.patience), "No Stop Syncing in the question:\n\(app.debugDescription)")
        confirm.tap()
        XCTAssertTrue(app.buttons[Self.setUp].appears(within: Self.patience), "Stopping did not bring back Set Up Sync…")
        let off = try elementsInOrder(of: app)
        XCTAssertTrue(off.contains { $0.label.contains("Sync is off.") }, Self.describe(off))
    }

    /// Nothing called Sync Now is on the library's screen while sync is off, of any kind: a VoiceOver action is never a
    /// button, so every element's label is read, and the test fails if one says it. (That the summary line carries no such
    /// action is `PhoneSyncSettingsTests`'s: this screen can't list a line's actions.)
    func testTheLibraryShowsNothingCalledSyncNowWhileOff() throws {
        let app = try launch(sendingTheBook: false)
        XCTAssertTrue(app.buttons["Settings"].appears(within: Self.patience), "No library:\n\(app.debugDescription)")
        let elements = try elementsInOrder(of: app)
        XCTAssertFalse(elements.contains { $0.label.contains("Sync Now") }, Self.describe(elements))
    }
}
