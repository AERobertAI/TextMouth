import SwiftUI

/// The error alert over the phone's reader while the book plays: the Mac's
/// (`ReaderErrorAlert`), with the Mac's buttons, decided by
/// `PhoneErrorAlertPlan`.
///
/// It reads the alert from the session's snapshot, which changes only when the
/// alert comes or goes, never as the place moves. The system takes
/// VoiceOver's focus to an alert as it appears. Closing it by any button
/// forgets the error in the reader, as the Mac's does, and then calls
/// `closed`, which returns focus to Play.
struct PhoneReaderErrorAlert: ViewModifier {
    /// The error to show, from the session's snapshot, or nil for none.
    let alert: ReaderViewModel.ErrorAlert?
    /// The reader whose error it is: it retries, and forgets the error.
    let reader: ReaderViewModel?
    /// Called once the alert has closed.
    let closed: @MainActor () -> Void

    func body(content: Content) -> some View {
        let plan = alert.map(PhoneErrorAlertPlan.init)
        return content.alert(
            plan?.title ?? "",
            isPresented: Binding(
                get: { alert != nil },
                set: { if !$0 { close() } }
            ),
            presenting: plan
        ) { plan in
            ForEach(plan.buttons, id: \.title) { button in
                Button(button.title, role: button.role == .cancel ? .cancel : nil) {
                    perform(button.action)
                }
            }
        } message: { plan in
            Text(plan.message)
        }
    }

    /// Does what a button does besides closing the alert.
    private func perform(_ action: PhoneErrorAlertPlan.Action) {
        guard action == .retry, let reader else { return }
        // SwiftUI closes the alert around this action. Retrying on the next
        // turn of the main queue lets a retry that fails again present a
        // fresh alert, rather than having the closing alert clear its
        // message, as the Mac's does.
        DispatchQueue.main.async { reader.retryAudioPlayback() }
    }

    /// The alert has closed, by a button or by the system: forgets the error
    /// and tells the screen.
    private func close() {
        reader?.dismissErrorAlert()
        closed()
    }
}
