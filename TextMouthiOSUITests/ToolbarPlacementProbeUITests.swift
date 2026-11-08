import XCTest

/// What iOS 26 shows in a sheet's bar for a button in `.cancellationAction`,
/// the placement every sheet button left (`PhoneSheetButtonPlacement`).
///
/// The app, launched with `PhoneSheetButtonPlacement.probeVariable`, puts
/// every sheet button back in `.cancellationAction`, and this test opens
/// Book Information from the reader and writes down what the sheet's bar
/// holds: each button's type, label, and identifier, the order of the whole
/// sheet, and a screenshot. It records and does not judge: it fails only when
/// the sheet never opens. The record is a note kept with the results, and is
/// printed, so a run's log has it. Nothing is pressed but the sheet's opener,
/// and nothing is typed.
final class ToolbarPlacementProbeUITests: TextMouthUITestCase {

    func testWhatTheSystemShowsForACancellationAction() throws {
        let app = try launchIntoTheReader(environment: [PhoneProbe.variable: "1"])
        let opener = app.buttons["Book Info"]
        XCTAssertTrue(opener.waitForExistence(timeout: Self.patience), "No Book Info control:\n\(app.debugDescription)")
        opener.tap()
        XCTAssertTrue(app.navigationBars["Book Information"].waitForExistence(timeout: Self.patience), "The sheet never opened:\n\(app.debugDescription)")
        // The sheet reads the book's file first, then shows its fields.
        _ = app.textFields.firstMatch.waitForExistence(timeout: Self.patience)

        // Every button of every bar, whatever its words: the type is what
        // the tree calls it, "id" its identifier, and the frame says where.
        let bars = app.navigationBars.allElementsBoundByIndex.map { bar in
            "bar id \"\(bar.identifier)\": " + bar.buttons.allElementsBoundByIndex.map {
                "button label \"\($0.label)\" id \"\($0.identifier)\" frame \($0.frame)"
            }.joined(separator: "; ")
        }
        let order = try elementsInOrder(of: app)
        let record = """
        Placement probe (.cancellationAction and .confirmationAction replaced by .cancellationAction):
        Bars: \(bars.joined(separator: " || "))
        Order: \(Self.describe(order))
        Elements by type: \(order.map { "\($0.type.rawValue):\($0.label)" }.joined(separator: " | "))
        """
        print("TOOLBAR-PROBE \(record)")
        let note = XCTAttachment(string: record)
        note.name = "What .cancellationAction showed"
        note.lifetime = .keepAlways
        add(note)
        keepScreenshot(of: app, named: "Book Information with .cancellationAction")
    }
}

/// The launch variable the probe sets: the app's own name for it, spelled
/// out here because the UI test bundle does not compile the app's sources.
private enum PhoneProbe {
    static let variable = "TEXTMOUTH_PROBE_SYSTEM_PLACEMENT"
}
