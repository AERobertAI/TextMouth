import XCTest
@testable import TextMouth

/// The error alert over the phone's reader: the Mac's alert, with the Mac's
/// buttons (`ReaderErrorAlert`), decided by `PhoneErrorAlertPlan`.
final class PhoneErrorAlertPlanTests: XCTestCase {
    /// An audio failure offers Retry and Cancel, in the Mac's order, Retry
    /// the one that retries and Cancel the one the system's dismissal means.
    func testAnAudioFailureOffersRetryAndCancel() {
        let alert = ReaderViewModel.ErrorAlert(
            title: "Playback Problem",
            message: "The audio could not be played.",
            offersRetry: true
        )

        let plan = PhoneErrorAlertPlan(alert)

        XCTAssertEqual(plan.title, "Playback Problem")
        XCTAssertEqual(plan.message, "The audio could not be played.")
        XCTAssertEqual(plan.buttons, [
            PhoneErrorAlertPlan.Button(title: "Retry", role: .normal, action: .retry),
            PhoneErrorAlertPlan.Button(title: "Cancel", role: .cancel, action: .nothing),
        ])
    }

    /// A chapter not got from the cloud says "Try Again", as the Mac's alert
    /// does.
    func testAChapterNotDownloadedOffersTryAgain() {
        let alert = ReaderViewModel.ErrorAlert(
            title: "Chapter Not Downloaded",
            message: "Chapter 3 is not on this device yet.",
            offersRetry: true,
            retryTitle: "Try Again"
        )

        XCTAssertEqual(
            PhoneErrorAlertPlan(alert).buttons.map(\.title),
            ["Try Again", "Cancel"]
        )
    }

    /// An error that can't be retried has OK alone, which cancels.
    func testAnErrorThatCannotBeRetriedHasOKAlone() {
        let alert = ReaderViewModel.ErrorAlert(title: "Error", message: "Something went wrong.", offersRetry: false)

        XCTAssertEqual(PhoneErrorAlertPlan(alert).buttons, [
            PhoneErrorAlertPlan.Button(title: "OK", role: .cancel, action: .nothing),
        ])
    }

    /// Only Retry retries; every other button just closes the alert.
    func testOnlyTheRetryButtonRetries() {
        let alert = ReaderViewModel.ErrorAlert(title: "Playback Problem", message: "m", offersRetry: true)

        let retrying = PhoneErrorAlertPlan(alert).buttons.filter { $0.action == .retry }

        XCTAssertEqual(retrying.map(\.title), ["Retry"])
    }

    /// The Mac's words are the phone's: the plan takes them from the Mac's
    /// alert value and the shared wording, never a copy of its own.
    func testTheWordsAreTheMacs() {
        XCTAssertEqual(PhoneAppWording.cancel, "Cancel")
        XCTAssertEqual(PhoneAppWording.errorDismiss, "OK")
        XCTAssertEqual(ReaderViewModel.ErrorAlert(title: "t", message: "m", offersRetry: true).retryTitle, "Retry")
    }

    /// Focus returns to Play once the alert has closed, but not when a retry
    /// that failed again has presented a fresh alert, which VoiceOver is on.
    func testFocusReturnsToPlayOnlyWhenNoAlertShowsAgain() {
        XCTAssertTrue(PhoneErrorAlertPlan.returnsFocusToPlay(errorAlertNow: nil))
        XCTAssertFalse(PhoneErrorAlertPlan.returnsFocusToPlay(
            errorAlertNow: ReaderViewModel.ErrorAlert(title: "Error", message: "again", offersRetry: false)
        ))
    }
}
