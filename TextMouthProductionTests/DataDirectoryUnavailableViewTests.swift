import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// The Library Not Available screen as the user meets it (FR02): every
/// control has an explicit label and a hint, Return presses Try Again, the
/// VoiceOver focus target is the reason, the reason is announced once for
/// each reason however many windows show the screen, and an app-wide action
/// that needs the library is refused in words. SwiftUI builds the
/// accessibility elements of its buttons only for a connected assistive
/// app, so the test that reads them skips, rather than fails, when it
/// exposes none; the wording test covers every label either way.
@MainActor
final class DataDirectoryUnavailableViewTests: XCTestCase {

    /// The reason the screen shows in these tests.
    private let reason = DataDirectoryUnavailability.driveNotConnected(volume: "Backup", folder: "/Volumes/Backup/TextMouth")

    // MARK: - Wording

    /// The heading, labels, hints, announcement, and refusals say what they
    /// are about.
    func testTheScreenIsWordedForTheListener() {
        XCTAssertEqual(DataDirectoryUnavailableText.title, "Library Not Available")
        XCTAssertEqual(DataDirectoryUnavailableText.tryAgain, "Try Again")
        XCTAssertEqual(DataDirectoryUnavailableText.quit, "Quit TextMouth")
        XCTAssertTrue(DataDirectoryUnavailableText.tryAgainHint.hasSuffix("."))
        XCTAssertTrue(DataDirectoryUnavailableText.quitHint.hasSuffix("."))
        XCTAssertEqual(
            DataDirectoryUnavailableText.announcement(for: reason),
            "Library Not Available. The drive “Backup” isn't connected."
        )
        let adding = "Books can't be added while the library isn't available."
        let opening = "Books can't be opened while the library isn't available."
        let book = UUID()
        let refusals: [(GlobalAction, String?)] = [
            (.openBookFile, adding), (.newFromText, adding), (.importDAISYFolder, adding),
            (.openFiles([URL(fileURLWithPath: "/Downloads/Atlas.epub")]), adding),
            (.openBookWindow(book), opening), (.continueToNextBook(book), opening),
            (.goToLibrary, nil),
        ]
        for (action, refusal) in refusals {
            XCTAssertEqual(DataDirectoryUnavailableText.refusal(of: action), refusal, "\(action)")
        }
    }

    // MARK: - The Rendered Screen

    /// Try Again and Quit TextMouth each have their label and hint, in that
    /// order, and pressing Try Again through accessibility tries again.
    func testTheButtonsAreLabelledAndTryAgainCanBePressed() throws {
        let tries = CallLog<String>()
        let screen = makeScreen(onTryAgain: { tries.record("try") })

        try withHostedControls(screen) { controls in
            let buttons = controls.filter { $0.role == .button }
            guard !buttons.isEmpty else {
                throw XCTSkip("SwiftUI exposed no AppKit button to accessibility in this run")
            }
            XCTAssertEqual(buttons.map(\.label), ["Try Again", "Quit TextMouth"])
            XCTAssertEqual(
                buttons.map(\.hint),
                [DataDirectoryUnavailableText.tryAgainHint, DataDirectoryUnavailableText.quitHint]
            )
            XCTAssertTrue(buttons[0].element.accessibilityPerformPress())
            XCTAssertTrue(waitUntil { tries.calls == ["try"] }, "pressing Try Again did \(tries.calls)")
        }
    }

    /// Return presses Try Again, the default button.
    func testReturnTriesAgain() throws {
        let tries = CallLog<String>()
        let screen = makeScreen(onTryAgain: { tries.record("try") })

        try withHostedView(screen, until: { $0.fittingSize.height > 0 }) { hostingView in
            guard pressKeyEquivalent(.return, in: hostingView) else {
                throw XCTSkip("This macOS hands an offscreen window no key equivalents")
            }
            XCTAssertTrue(waitUntil { tries.calls == ["try"] }, "Return did \(tries.calls)")
        }
    }

    /// The reason is the one VoiceOver focus target: exactly one focus
    /// request is attached, and, where SwiftUI exposes its elements, it is
    /// on the element that reads the reason.
    func testVoiceOverFocusMovesToTheReason() throws {
        let screen = makeScreen()

        withHostedView(screen, until: { !self.descendants(of: $0, as: VoiceOverFocusTriggerView.self).isEmpty }) { hostingView in
            XCTAssertEqual(descendants(of: hostingView, as: VoiceOverFocusTriggerView.self).count, 1)
            let targets = elements(identified: voiceOverFocusID, in: hostingView)
            if !targets.isEmpty {
                XCTAssertEqual(targets.map { $0.accessibilityLabel() ?? "" }, [reason.explanation])
            }
        }
    }

    /// Once VoiceOver has had time to move to the reason, the screen asks
    /// for it to be announced.
    func testTheScreenAsksForTheReasonToBeAnnounced() {
        let announced = CallLog<String>()
        let screen = makeScreen(focusDelay: 0, onAnnounce: { announced.record("announce") })

        withHostedView(screen, until: { $0.fittingSize.height > 0 }) { _ in
            XCTAssertTrue(waitUntil(timeout: 5) { announced.calls == ["announce"] }, "asked \(announced.calls)")
        }
    }

    // MARK: - The Model's Part

    /// However many windows ask, each reason is announced once; a refused
    /// action is shown and announced.
    func testEachReasonIsAnnouncedOnceAndRefusalsAreShown() throws {
        let fixture = try UnavailableModelFixture(test: self)
        let model = LibraryViewModel(dataDirectoryEnvironment: fixture.environment)
        let expected = "Library Not Available. The folder \(fixture.root.path) can't be found."

        let recorder = recordingAnnouncements {
            model.announceDataDirectoryUnavailability()
            model.announceDataDirectoryUnavailability()
            model.refuseWhileDataDirectoryUnavailable("Books can't be opened while the library isn't available.")
        }

        XCTAssertEqual(
            recorder.announcements.map(\.message),
            [expected, "Books can't be opened while the library isn't available."]
        )
        XCTAssertEqual(model.dataDirectoryRefusalNotice, "Books can't be opened while the library isn't available.")
    }

    // MARK: - Storage Settings

    /// Storage settings say the library isn't available, ahead of every
    /// other status, and offer no maintenance meanwhile.
    func testStorageSettingsSayTheLibraryIsNotAvailable() {
        XCTAssertEqual(
            StorageSettingsView.statusText(
                isRecoveringIndex: true,
                directoryExists: false,
                hasUnsavedChanges: true,
                isLibraryUnavailable: true
            ),
            "Library Not Available"
        )
        XCTAssertTrue(StorageSettingsView.maintenanceUnavailable(
            isRecoveringIndex: false,
            isRunning: false,
            isLibraryUnavailable: true
        ))
    }

    /// Moving the data directory while the library isn't available fails,
    /// saying so, and changes nothing.
    func testAMoveWhileTheLibraryIsUnavailableSaysWhy() async throws {
        let fixture = try UnavailableModelFixture(test: self)
        let model = LibraryViewModel(dataDirectoryEnvironment: fixture.environment)
        let destination = try makeSandboxDirectory("NowhereToGo").appendingPathComponent("Moved", isDirectory: true)

        let outcome = await model.moveDataDirectoryReturningOutcome(to: destination)

        XCTAssertEqual(
            outcome.failureMessage,
            "Failed to move directory: The library at \(fixture.root.path) isn't available."
        )
        XCTAssertEqual(TextMouthPaths.root.path, fixture.root.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - Fixtures

    /// The screen for `reason`, recording nothing unless told to.
    private func makeScreen(
        focusDelay: TimeInterval = 0.2,
        onAnnounce: @escaping () -> Void = {},
        onTryAgain: @escaping () -> Void = {}
    ) -> DataDirectoryUnavailableView {
        DataDirectoryUnavailableView(
            unavailability: reason,
            notice: nil,
            focusDelay: focusDelay,
            onAnnounce: onAnnounce,
            onTryAgain: onTryAgain,
            onQuit: {}
        )
    }

    /// Every accessibility element below `root` whose identifier is
    /// `identifier`.
    private func elements(identified identifier: String, in root: Any) -> [NSAccessibilityProtocol] {
        guard let node = root as? NSAccessibilityProtocol else { return [] }
        let match = node.accessibilityIdentifier() == identifier ? [node] : []
        return match + (node.accessibilityChildren() ?? []).flatMap { elements(identified: identifier, in: $0) }
    }
}

/// A custom data directory that is missing, made the current one until the
/// test ends, with a preferences store and a volume notification center of
/// the fixture's own.
@MainActor
private struct UnavailableModelFixture {
    /// The missing data directory.
    let root: URL
    /// What the library model under test uses.
    let environment: DataDirectoryEnvironment

    init(test: XCTestCase) throws {
        let root = try test.makeDataDirectoryMoveDestination("UnavailableScreen")
        self.root = root
        environment = DataDirectoryEnvironment(
            preferences: test.makeSandboxedPreferences("unavailable-screen"),
            volumeNotifications: NotificationCenter()
        )
        TextMouthPaths.setCustomRoot(root, in: environment.preferences)
        StorageBoundary.shared.publish(root: root)
        test.addTeardownBlock { DataDirectoryGate.open(root) }
    }
}
