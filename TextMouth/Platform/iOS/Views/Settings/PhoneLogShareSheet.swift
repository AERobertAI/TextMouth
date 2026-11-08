import SwiftUI
import UIKit

/// The system's share sheet, offering one file: Settings' Share Logs….
///
/// SwiftUI's `ShareLink` isn't used, for two reasons its interface shows. It
/// takes its item as the view is made, so the logs would have to be gathered
/// each time Settings appears, and the file would be stale by the press. And
/// it has no hook for its sheet closing, so VoiceOver's focus couldn't be
/// returned to the row, which the spec requires of every sheet. This is shown
/// through `.sheet`, whose `onDismiss` does that.
///
/// Apple's documentation says to present `UIActivityViewController` modally on
/// an iPhone and in a popover on an iPad. Here it fills a SwiftUI sheet, which
/// is modal on both. Nothing here has run on iOS: how VoiceOver lands in it,
/// and that closing it closes the sheet, are on the hand-check list.
struct PhoneLogShareSheet: UIViewControllerRepresentable {
    /// The file to share.
    let file: URL
    /// Called once the person is done with the sheet, on the main actor.
    let onFinished: @MainActor @Sendable () -> Void

    /// Makes the share sheet, which dismisses itself when a person closes it
    /// or an activity finishes. SwiftUI isn't told of that dismissal, so
    /// `onFinished` is what clears the state that presented it.
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        // `@Sendable`, since UIKit doesn't say which thread this runs on, and
        // a closure formed here would otherwise trap on any thread but the
        // main one, under Swift 6's isolation checks.
        let onFinished = onFinished
        controller.completionWithItemsHandler = { @Sendable activity, completed, _, _ in
            guard PhoneLogExport.shareSheetIsFinished(choseActivity: activity != nil, completed: completed) else {
                return
            }
            Task { @MainActor in onFinished() }
        }
        return controller
    }

    /// Nothing changes once it's made: the file stays the same while it's up.
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
