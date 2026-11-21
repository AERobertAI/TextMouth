import Foundation

/// What the error alert over the phone's reader shows and does: the Mac's
/// `ReaderViewModel.ErrorAlert`, with the Mac's buttons (`ReaderErrorAlert`, in
/// `ReaderView.swift`), decided here so a test on the Mac can reach them.
///
/// The Mac offers "Retry", or "Try Again" for a chapter that could not be got
/// from the cloud, with "Cancel" for an error that can be retried, and "OK"
/// alone for one that can't. Closing the alert by any button forgets the
/// error, as the Mac's does (`ReaderViewModel.dismissErrorAlert`).
struct PhoneErrorAlertPlan: Equatable, Sendable {
    /// What a button does, besides closing the alert, which every one does.
    enum Action: Equatable, Sendable {
        /// Plays the audio again, on the next turn of the main queue.
        case retry
        /// Nothing more.
        case nothing
    }

    /// A button's role: the one that cancels is the one the alert's own
    /// dismissal means.
    enum Role: Equatable, Sendable {
        case normal
        case cancel
    }

    /// One button of the alert.
    struct Button: Equatable, Sendable {
        /// The Mac's word for it.
        let title: String
        /// Its role.
        let role: Role
        /// What it does.
        let action: Action
    }

    /// The alert's title, naming the kind of problem.
    let title: String
    /// What went wrong and what to do.
    let message: String
    /// The buttons, in the order the Mac lists them.
    let buttons: [Button]

    /// The plan for `alert`.
    init(_ alert: ReaderViewModel.ErrorAlert) {
        title = alert.title
        message = alert.message
        if alert.offersRetry {
            buttons = [
                Button(title: alert.retryTitle, role: .normal, action: .retry),
                Button(title: PhoneAppWording.cancel, role: .cancel, action: .nothing),
            ]
        } else {
            buttons = [Button(title: PhoneAppWording.errorDismiss, role: .cancel, action: .nothing)]
        }
    }

    /// Whether focus returns to Play once the alert has closed: only when no
    /// alert is showing then. A retry that fails again presents a fresh alert,
    /// which VoiceOver is on, and focus must not be taken from it.
    static func returnsFocusToPlay(errorAlertNow: ReaderViewModel.ErrorAlert?) -> Bool {
        errorAlertNow == nil
    }
}
