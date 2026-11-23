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
        // Found by its label among the elements of any kind: the exporter's Cancel is drawn as an element that is not a button.
        let cancels = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Cancel"))
        XCTAssertTrue(cancels.firstMatch.waitForExistence(timeout: Self.patience), "The exporter did not open:\n\(app.debugDescription)")

        // The exporter is closed when its Save button is gone. A person dismisses a sheet by dragging it down from its top, which
        // is a cancel too; if that leaves it open, tap what it offers as Cancel, if that can be tapped (its only Cancel may
        // share the place of the More button).
        let save = app.buttons["Save"]
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
        from.press(forDuration: 0.1, thenDragTo: to)
        var closed = save.waitForNonExistence(timeout: 10)
        for index in (0..<cancels.count).reversed() where !closed {
            let candidate = cancels.element(boundBy: index)
            guard candidate.exists, candidate.isHittable else { continue }
            candidate.tap()
            closed = save.waitForNonExistence(timeout: 10)
        }
        XCTAssertTrue(closed, "The exporter stayed open:\n\(app.debugDescription)")
        scrollToTheButton(in: app)
        XCTAssertTrue(app.buttons[Self.button].exists, "The button is gone after the exporter was cancelled")
    }
}
