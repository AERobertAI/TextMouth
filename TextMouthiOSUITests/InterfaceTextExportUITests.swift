import XCTest

/// Export Interface Text… on the iPhone (FR39): Settings has the button in its Language section, below the person's own
/// lines; it opens the system's file exporter, and cancelling the exporter leaves the button where it was, to be found
/// again. (A cancel is the case Apple's `fileExporter` reports through `onCancellation` only.)
///
/// The app runs in a sandbox of its own (TEXTMOUTH_UI_TEST). Nothing here saves a file, makes sound, or types.
@MainActor
final class InterfaceTextExportUITests: TextMouthUITestCase {
    /// The button's label, in English.
    private static let button = "Export Interface Text…"

    /// Swipes up until the button can be tapped, at most ten times.
    private func scrollToTheButton(in app: XCUIApplication) {
        let export = app.buttons[Self.button]
        for _ in 0..<10 where !(export.exists && export.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(export.exists && export.isHittable, "No \(Self.button) button in Settings:\n\(app.debugDescription)")
    }

    /// Finds the button in Settings by its label, opens the exporter, cancels it, and finds the button again.
    func testTheExporterOpensAndCancelsAndTheButtonIsStillThere() throws {
        let app = try launch(sendingTheBook: false)
        tap(app.buttons["Settings"], until: app.navigationBars["Settings"], in: app, what: "Settings")
        scrollToTheButton(in: app)
        let export = app.buttons[Self.button]
        XCTAssertFalse(export.label.isEmpty)

        export.tap()

        // The system's exporter has a Cancel button (a document picker in the app's own process or another's).
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: Self.patience), "The exporter did not open:\n\(app.debugDescription)")
        cancel.tap()

        XCTAssertTrue(cancel.waitForNonExistence(timeout: Self.patience), "The exporter stayed open")
        scrollToTheButton(in: app)
        XCTAssertTrue(app.buttons[Self.button].exists, "The button is gone after the exporter was cancelled")
    }
}
