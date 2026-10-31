import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// The skip that keeps the checks of hosted controls from failing where a
/// session exposes no accessibility elements for a hosted window's AppKit
/// controls, as a CI runner does. Putting each answer in place of the
/// measured one shows, on any Mac, that without the capability a test is
/// skipped with the one message naming it before its checks run. Where the
/// capability exists, as on the development Mac, the checks still run: a
/// stepper deliberately left without a label fails its label check. The
/// up-front skip of the checks that read SwiftUI's own texts and buttons
/// in-process is shown both ways too.
@MainActor
final class AccessibilityTestSupportTests: XCTestCase {

    /// The label every check below expects of a stepper.
    private nonisolated static let stepperLabel = "Pause length"

    // MARK: - Without the Capability

    /// Without the capability, the skip carries the one message naming it;
    /// with it, the test goes on.
    func testTheSkipNamesTheCapabilityAndComesOnlyWithoutIt() throws {
        try HostedWindowAccessibility.assuming(false) {
            XCTAssertThrowsError(try skipUnlessHostedWindowsExposeAccessibility()) { error in
                XCTAssertEqual((error as? XCTSkip)?.message, HostedWindowAccessibility.unavailableMessage)
            }
        }
        try HostedWindowAccessibility.assuming(true) {
            XCTAssertNoThrow(try skipUnlessHostedWindowsExposeAccessibility())
        }
    }

    /// Without the capability, a test that reads hosted controls is skipped
    /// before its checks meet the empty list that would fail them.
    func testHostedControlsSkipBeforeTheChecksWithoutTheCapability() throws {
        var checksRan = false

        try HostedWindowAccessibility.assuming(false) {
            XCTAssertThrowsError(
                try withHostedControls(LoneStepper(label: Self.stepperLabel)) { _ in checksRan = true }
            ) { error in
                XCTAssertEqual((error as? XCTSkip)?.message, HostedWindowAccessibility.unavailableMessage)
            }
        }

        XCTAssertFalse(checksRan, "The checks ran without the capability")
    }

    // MARK: - With the Capability

    /// A labelled stepper passes the label check that the tests of hosted
    /// controls make, so the failure in the next test comes from the missing
    /// label and not from the harness.
    func testALabelledStepperPassesTheLabelCheck() throws {
        try withHostedControls(LoneStepper(label: Self.stepperLabel)) { controls in
            XCTAssertEqual(steppers(in: controls).map(\.label), [Self.stepperLabel])
        }
    }

    /// Where the session has the capability, the checks run: a stepper
    /// deliberately left without a label fails the same label check, here
    /// as an expected failure, rather than being skipped. Without the
    /// capability no check can run, so this test is skipped as well.
    func testAnUnlabelledStepperStillFailsTheLabelCheck() throws {
        try skipUnlessHostedWindowsExposeAccessibility()
        var labelsChecked: [String]?

        try XCTExpectFailure(
            "A stepper left without a label must fail its label check",
            failingBlock: {
                try withHostedControls(LoneStepper(label: nil)) { controls in
                    let labels = steppers(in: controls).map(\.label)
                    labelsChecked = labels
                    XCTAssertEqual(labels, [Self.stepperLabel])
                }
            },
            // Only the label check's failure is expected; any other fails
            // the test. XCTest may call the matcher from any thread, so it
            // reads nothing tied to the main actor.
            issueMatcher: { @Sendable issue in issue.compactDescription.contains(Self.stepperLabel) }
        )

        XCTAssertEqual(labelsChecked, [""], "The label check ran on the one stepper, which has no label")
    }

    // MARK: - SwiftUI's Own Elements

    /// Where SwiftUI exposes nothing of its own to an in-process read, the
    /// skip carries the one message saying so, word for word; where it
    /// exposes its elements, the test goes on.
    func testTheSwiftUISkipSaysWhyAndComesOnlyWithoutTheExposure() throws {
        XCTAssertEqual(
            SwiftUIElementExposure.unavailableMessage,
            "SwiftUI exposes the accessibility elements of its own texts and buttons only to an accessibility client, "
                + "never to a test reading them in-process"
        )
        try SwiftUIElementExposure.assuming(false) {
            XCTAssertThrowsError(try skipUnlessSwiftUIExposesItsOwnElements()) { error in
                XCTAssertEqual((error as? XCTSkip)?.message, SwiftUIElementExposure.unavailableMessage)
            }
        }
        try SwiftUIElementExposure.assuming(true) {
            XCTAssertNoThrow(try skipUnlessSwiftUIExposesItsOwnElements())
        }
    }

    // MARK: - Helpers

    /// The steppers among `controls`.
    private func steppers(in controls: [AccessibleControl]) -> [AccessibleControl] {
        controls.filter { $0.role == .incrementor }
    }
}
