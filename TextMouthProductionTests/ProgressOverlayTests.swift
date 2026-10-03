import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// The progress overlay as VoiceOver meets it (TODO I05): a container
/// labelled with its status, whose message joins the status while the bar
/// has no total, holding a Cancel button named "Cancel Import" that Escape
/// presses too, which in the Library window's import overlay reaches the
/// library's `cancelImports()`. SwiftUI builds the accessibility elements
/// of its texts and buttons only for a connected assistive app, so the
/// rendered tests skip, rather than fail, when it exposes none; the wording
/// tests cover every label either way.
@MainActor
final class ProgressOverlayTests: XCTestCase {

    // MARK: - Wording

    /// While the bar has a total, VoiceOver reads the title and the items
    /// done of the total, as before; the message, which repeats the count
    /// while books import, is left out.
    func testStatusCountsItemsWhileTheBarHasATotal() {
        let overlay = ProgressOverlay(
            title: "Importing Books",
            current: 3,
            total: 10,
            message: "Importing book 3 of 10...",
            itemNoun: "books processed"
        )

        XCTAssertEqual(overlay.spokenStatus, "Importing Books: 3 of 10 books processed")
    }

    /// While the bar is indeterminate, the message carries the progress, so
    /// VoiceOver reads it after the title: a ZIP archive's items extracted.
    func testStatusReadsTheMessageWhileTheBarIsIndeterminate() {
        XCTAssertEqual(
            Self.extractingOverlay().spokenStatus,
            "Importing Books: Extracting “Library Export.zip”: 37 of 120 items..."
        )
    }

    /// With neither a total nor a message, the title is read alone, as before.
    func testStatusIsTheTitleAloneWithNothingMoreToTell() {
        let overlay = ProgressOverlay(title: "Extracting Text", current: 0, total: 0, message: "", itemNoun: "books extracted")

        XCTAssertEqual(overlay.spokenStatus, "Extracting Text")
    }

    /// The Cancel button is named for what it cancels and says what it does;
    /// an overlay given no cancel action has none.
    func testCancelButtonIsNamedForTheImport() {
        XCTAssertEqual(ProgressOverlay.cancelButtonLabel, "Cancel Import")
        XCTAssertEqual(
            ProgressOverlay.cancelButtonHint,
            "Stops importing ZIP archives. Books already imported stay in the library."
        )
        XCTAssertNil(ProgressOverlay(title: "Extracting Text", current: 1, total: 2, message: "", itemNoun: "books extracted").onCancel)
    }

    // MARK: - Rendered Overlay

    /// VoiceOver finds the overlay as one container labelled with its status
    /// that holds the Cancel Import button, hint included, as a control of
    /// its own; pressing that button through accessibility cancels once.
    func testContainerHoldsTheCancelButtonForVoiceOver() throws {
        let cancels = CancelCounter()
        let overlay = Self.extractingOverlay(onCancel: cancels.cancel)

        try withHostedView(overlay, until: { !self.buttons(in: $0).isEmpty }) { hostingView in
            let found = buttons(in: hostingView)
            guard !found.isEmpty else {
                throw XCTSkip("SwiftUI exposed no button to accessibility without an assistive app")
            }
            XCTAssertEqual(found.map(\.label), [ProgressOverlay.cancelButtonLabel])
            XCTAssertEqual(found.first?.hint, ProgressOverlay.cancelButtonHint)

            let containers = accessibilityElements(labelled: overlay.spokenStatus, in: hostingView)
            XCTAssertEqual(containers.count, 1, "One element carries the status")
            XCTAssertEqual(
                containers.first.map { buttons(in: $0).map(\.label) },
                [ProgressOverlay.cancelButtonLabel],
                "The status container holds the Cancel button"
            )

            XCTAssertTrue(found[0].element.accessibilityPerformPress())
            XCTAssertTrue(waitUntil { cancels.count == 1 }, "The button was pressed \(cancels.count) times")
        }
    }

    /// Without a cancel action the overlay holds no button, as the text
    /// extraction overlay never has.
    func testOverlayWithoutACancelActionHoldsNoButton() throws {
        let overlay = ProgressOverlay(title: "Extracting Text", current: 2, total: 5, message: "", itemNoun: "books extracted")

        try withHostedView(overlay, until: { !self.accessibilityElements(labelled: overlay.spokenStatus, in: $0).isEmpty }) { hostingView in
            guard !accessibilityElements(labelled: overlay.spokenStatus, in: hostingView).isEmpty else {
                throw XCTSkip("SwiftUI exposed no accessibility elements without an assistive app")
            }
            XCTAssertEqual(buttons(in: hostingView).map(\.label), [])
        }
    }

    /// Escape presses the Cancel button, as the cancel key does in any Mac
    /// dialog, so the import can be stopped without finding the button.
    func testEscapePressesTheCancelButton() throws {
        let cancels = CancelCounter()
        let overlay = Self.extractingOverlay(onCancel: cancels.cancel)

        // SwiftUI may draw this button itself rather than with an AppKit
        // button, so the overlay counts as ready once it has laid out.
        try withHostedView(overlay, until: { $0.fittingSize.height > 0 }) { hostingView in
            guard pressKeyEquivalent(.escape, in: hostingView) else {
                throw XCTSkip("This macOS hands an offscreen window no key equivalents")
            }
            XCTAssertTrue(waitUntil { cancels.count == 1 }, "Escape pressed the button \(cancels.count) times")
        }
    }

    // MARK: - The Library Window's Import Overlay

    /// The overlay the Library window shows while imports run reads the
    /// library's import progress under its own title and noun, and has a
    /// Cancel button.
    func testImportOverlayShowsTheLibrarysProgress() {
        let library = LibraryViewModel(initializeServices: false)
        library.importProgressCurrent = 3
        library.importProgressTotal = 10
        library.importProgressMessage = "Importing book 3 of 10..."

        let overlay = LibraryWindowView.importProgressOverlay(for: library)

        XCTAssertEqual(overlay.spokenStatus, "Importing Books: 3 of 10 books processed")
        XCTAssertEqual(overlay.message, "Importing book 3 of 10...")
        XCTAssertNotNil(overlay.onCancel)
    }

    /// The import overlay's Cancel reaches the library's `cancelImports()`:
    /// the imports queued so far are cancelled, and an import queued
    /// afterwards would not be.
    func testImportOverlaysCancelReachesTheLibrary() throws {
        let library = LibraryViewModel(initializeServices: false)
        let queuedBefore = library.importOperationQueue.currentCancellation
        let cancel = try XCTUnwrap(LibraryWindowView.importProgressOverlay(for: library).onCancel)

        cancel()

        XCTAssertTrue(queuedBefore.isCancelled)
        XCTAssertFalse(library.importOperationQueue.currentCancellation.isCancelled)
    }

    // MARK: - Fixtures

    /// An import overlay while a ZIP archive is extracted: the bar has no
    /// total, and the message counts the archive's items. `onCancel`, when
    /// given, is its cancel action.
    private static func extractingOverlay(onCancel: (@MainActor () -> Void)? = nil) -> ProgressOverlay {
        ProgressOverlay(
            title: "Importing Books",
            current: 0,
            total: 0,
            message: "Extracting “Library Export.zip”: 37 of 120 items...",
            itemNoun: "books processed",
            onCancel: onCancel
        )
    }

    /// The buttons VoiceOver can land on below `root`.
    private func buttons(in root: Any) -> [AccessibleControl] {
        accessibleControls(in: root).filter { $0.role == .button }
    }
}

/// Counts the times an overlay's cancel action runs.
@MainActor
private final class CancelCounter {
    /// How many times `cancel()` has run.
    private(set) var count = 0

    /// The cancel action: counts one more run.
    func cancel() {
        count += 1
    }
}
