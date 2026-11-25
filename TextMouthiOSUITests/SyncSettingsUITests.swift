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

    /// The library's summary line offers no Sync Now action while sync is off.
    func testTheLibraryOffersNoSyncNowWhileOff() throws {
        let app = try launch(sendingTheBook: false)
        XCTAssertTrue(app.buttons["Settings"].appears(within: Self.patience), "No library:\n\(app.debugDescription)")
        XCTAssertFalse(app.buttons["Sync Now"].exists, "Sync Now is offered before sync is set up")
    }
}
