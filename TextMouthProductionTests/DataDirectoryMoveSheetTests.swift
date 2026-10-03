import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// The sheet every Library window shows while the library moves, and the
/// progress Storage settings show (FR02), as VoiceOver and a braille display
/// meet them: a native progress bar that takes VoiceOver's focus in the
/// sheet, labelled "Moving the library" with the percentage as its value,
/// and a labelled Cancel button that Escape presses and that is unavailable
/// once the copy is complete.
///
/// SwiftUI builds the spoken label and value of the bar, and the elements of
/// its buttons, only for a connected assistive app; where it exposes no
/// button here, those checks are skipped, and the words are pinned through
/// `DataDirectoryMoveWording`, where they come from.
@MainActor
final class DataDirectoryMoveSheetTests: XCTestCase {

    /// The sheet draws a native progress bar, VoiceOver's progress
    /// indicator, at the percentage copied, and asks for VoiceOver's focus to
    /// move to it; the bar's words are the move's.
    func testTheSheetDrawsAProgressBarThatTakesVoiceOverFocus() {
        let move = makeMove(copiedPercent: 40)

        withHostedProgressBar(DataDirectoryMoveSheet(move: move)) { bar, hostingView in
            XCTAssertEqual(bar.accessibilityRole(), .progressIndicator)
            XCTAssertFalse(bar.isIndeterminate)
            XCTAssertEqual(bar.doubleValue / bar.maxValue, 0.4, accuracy: 0.0001)
            XCTAssertEqual(descendants(of: hostingView, as: VoiceOverFocusTriggerView.self).count, 1)
        }
        XCTAssertEqual(DataDirectoryMoveWording.progressLabel, "Moving the library")
        XCTAssertEqual(move.spokenValue, "40 percent")
        XCTAssertEqual(move.statusText, "Moving the library… 40 percent")
    }

    /// Before the copy starts, while the move waits, the bar shows no amount.
    func testWhileTheMoveWaitsTheBarShowsNoAmount() {
        let move = DataDirectoryMoveProgress(destination: URL(fileURLWithPath: "/Volumes/Backup/Library"))
        recordingAnnouncements { move.wait(for: .importing) }

        withHostedProgressBar(DataDirectoryMoveSheet(move: move)) { bar, _ in
            XCTAssertTrue(bar.isIndeterminate, "a move that has copied nothing showed an amount")
        }
        XCTAssertEqual(move.spokenValue, "Waiting for the current import to finish...")
    }

    /// Storage settings show the same progress without taking VoiceOver's
    /// focus from where the user is.
    func testStorageSettingsShowTheProgressWithoutTakingFocus() {
        let move = makeMove(copiedPercent: 25)

        withHostedProgressBar(DataDirectoryMoveProgressView(move: move)) { bar, hostingView in
            XCTAssertEqual(bar.doubleValue / bar.maxValue, 0.25, accuracy: 0.0001)
            XCTAssertEqual(descendants(of: hostingView, as: VoiceOverFocusTriggerView.self).count, 0)
        }
    }

    /// Cancel is labelled and hinted, and pressing it through accessibility
    /// cancels the move.
    func testTheCancelButtonIsLabelledAndCancelsTheMove() throws {
        let move = makeMove(copiedPercent: 40)

        try withHostedControls(DataDirectoryMoveSheet(move: move)) { controls in
            let buttons = controls.filter { $0.role == .button }
            guard !buttons.isEmpty else {
                throw XCTSkip("SwiftUI exposed no AppKit button to accessibility in this run")
            }
            XCTAssertEqual(buttons.map(\.label), [DataDirectoryMoveWording.cancelLabel])
            XCTAssertEqual(buttons.map(\.hint), [DataDirectoryMoveWording.cancelHint])
            recordingAnnouncements {
                XCTAssertTrue(buttons[0].element.accessibilityPerformPress())
            }
            XCTAssertTrue(waitUntil { move.isCancelRequested }, "pressing Cancel did not cancel the move")
        }
        XCTAssertEqual(DataDirectoryMoveWording.cancelLabel, "Cancel Move")
        XCTAssertEqual(
            DataDirectoryMoveWording.cancelHint,
            "Stops moving the library. The library stays where it is, and nothing is changed."
        )
    }

    /// Escape presses Cancel.
    func testEscapeCancelsTheMove() throws {
        let move = makeMove(copiedPercent: 40)

        try withHostedView(DataDirectoryMoveSheet(move: move), until: { $0.fittingSize.height > 0 }) { hostingView in
            var pressed = false
            recordingAnnouncements {
                pressed = pressKeyEquivalent(.escape, in: hostingView)
            }
            guard pressed else {
                throw XCTSkip("This macOS hands an offscreen window no key equivalents")
            }
            XCTAssertTrue(waitUntil { move.isCancelRequested }, "Escape did not cancel the move")
        }
    }

    /// Once the copy is complete, Cancel is unavailable, which VoiceOver
    /// says, as the move can only finish.
    func testCancelIsUnavailableOnceTheCopyIsComplete() throws {
        let move = makeMove(copiedPercent: 40)
        move.receive(DataDirectoryCopyProgress(copiedBytes: 100, totalBytes: 100, copiedItems: 4, totalItems: 4))

        try withHostedControls(DataDirectoryMoveSheet(move: move)) { controls in
            let buttons = controls.filter { $0.role == .button }
            guard let cancel = buttons.first else {
                throw XCTSkip("SwiftUI exposed no AppKit button to accessibility in this run")
            }
            XCTAssertFalse(cancel.element.isAccessibilityEnabled(), "Cancel was available while the move finished")
        }
        XCTAssertFalse(move.canCancel)
    }

    // MARK: - Fixtures

    /// A move to a drive, copying, `copiedPercent` done.
    private func makeMove(copiedPercent: Int) -> DataDirectoryMoveProgress {
        let move = DataDirectoryMoveProgress(destination: URL(fileURLWithPath: "/Volumes/Backup/Library"))
        recordingAnnouncements {
            move.beginCopying()
            move.receive(DataDirectoryCopyProgress(
                copiedBytes: Int64(copiedPercent),
                totalBytes: 100,
                copiedItems: 1,
                totalItems: 4
            ))
        }
        return move
    }

    /// Hosts `view`, waits for SwiftUI to draw its progress bar, and passes
    /// the bar and the hosting view to `body`.
    private func withHostedProgressBar<Content: View>(
        _ view: Content,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: (NSProgressIndicator, NSView) -> Void
    ) {
        withHostedView(view, until: { !self.descendants(of: $0, as: NSProgressIndicator.self).isEmpty }) { hostingView in
            guard let bar = descendants(of: hostingView, as: NSProgressIndicator.self).first else {
                return XCTFail("No progress bar was drawn", file: file, line: line)
            }
            body(bar, hostingView)
        }
    }
}
