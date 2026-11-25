import SwiftUI
import UniformTypeIdentifiers

/// The rows of Settings' Sync section (FR43): what sync does, the status line
/// and the lines after it, and the section's buttons. With sync off they are
/// Set Up Sync… and Join Sync Folder…, each opening the system's folder picker
/// (Files), and with it on, Sync Now and Stop Syncing…. Every decision is in
/// `PhoneSyncSettingsModel` and `PhoneSyncSettingsController`, which tests run;
/// this view only draws them. Nothing here has run on a phone.
///
/// Each state is words, never colour or position: the status is static text
/// that VoiceOver and braille read where it stands, a press that fails is an
/// alert and is spoken, and VoiceOver's focus comes back to the button that
/// opened the picker, the confirmation, or the alert.
struct PhoneSyncSettingsSection: View {
    /// What the app's one sync reports; the rows are drawn again when it changes.
    @ObservedObject private var center = SyncCenter.shared
    /// The steps the buttons take.
    @StateObject private var steps = PhoneSyncSettingsController()
    /// What the folder picker now showing is for.
    @State private var pick: PhoneSyncPick = .setUp
    /// Whether the folder picker is up.
    @State private var isPicking = false
    /// The button VoiceOver's focus returns to once what it opened has closed.
    @AccessibilityFocusState private var focusedControl: PhoneSyncControl?

    var body: some View {
        // What sync is for, left where VoiceOver and braille can read it. The picker and the alerts hang on this one row
        // (never on all of them, which would present each of them once for each row), and apart from the screen's own file
        // exporter, since two of the system's file dialogs on one view are not known to work together.
        PhoneReadableCaption(SyncWording.sectionSummary)
            .background {
                Color.clear
                    .fileImporter(
                        isPresented: $isPicking,
                        allowedContentTypes: [.folder],
                        allowsMultipleSelection: false,
                        onCompletion: { picked($0) },
                        // A cancel never reaches `onCompletion`: without this, focus would not come back.
                        onCancellation: { returnFocus(to: pick == .setUp ? .setUp : .join) }
                    )
            }
            .alert(SyncWording.sectionTitle, isPresented: isShowingFailure) {
            } message: {
                Text(steps.alertMessage ?? "")
            }
            .alert(PhoneSyncWording.stopQuestion, isPresented: $steps.isAskingToStop) {
                Button(PhoneSyncWording.stopButton, role: .destructive) {
                    steps.confirmStop()
                    returnFocus(to: .setUp)
                }
                Button(PhoneAppWording.cancel, role: .cancel) { returnFocus(to: .stop) }
            }
        statusLines
        ForEach(PhoneSyncSettingsModel.controls(isOn: center.status.isOn)) { control in
            PhoneActionButton(title: control.title) { press(control) }
                .disabled(steps.isWorking)
                .accessibilityHint(control.hint ?? "")
                .accessibilityFocused($focusedControl, equals: control)
        }
    }

    /// The status line, then who was last heard from and the books' backup,
    /// each its own static line; while a step waits, the words for the wait.
    @ViewBuilder
    private var statusLines: some View {
        if steps.isWorking {
            Text(SyncWording.waitingForFiles).phonePrimaryText()
        } else {
            ForEach(Array(PhoneSyncSettingsModel.lines(for: center.status).enumerated()), id: \.offset) { _, line in
                Text(line).phonePrimaryText()
            }
        }
    }

    /// What pressing `control` does.
    private func press(_ control: PhoneSyncControl) {
        switch control {
        case .setUp:
            pick = .setUp
            isPicking = true
        case .join:
            pick = .join
            isPicking = true
        case .syncNow:
            steps.syncNow()
        case .stop:
            steps.askToStop()
        }
    }

    /// The picker returned: makes or joins the folder, then gives focus back.
    private func picked(_ result: Result<[URL], Error>) {
        let kind = pick
        Task {
            await steps.picked(result, for: kind)
            // The failure alert, if one is up, returns focus itself when it closes.
            if steps.alertMessage == nil { returnFocus(to: kind == .setUp ? .setUp : .join) }
        }
    }

    /// Asks for VoiceOver's focus on `control`, after what covered it has gone:
    /// a request made at once is lost, as `PhoneListFocus` says.
    private func returnFocus(to control: PhoneSyncControl) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            // With sync now on, the button may be another: the first one stands in.
            let shown = PhoneSyncSettingsModel.controls(isOn: center.status.isOn)
            focusedControl = shown.contains(control) ? control : shown.first
        }
    }

    /// Whether the failure alert is up; closing it brings focus back.
    private var isShowingFailure: Binding<Bool> {
        Binding(
            get: { steps.alertMessage != nil },
            set: { isShowing in
                guard !isShowing else { return }
                steps.alertMessage = nil
                returnFocus(to: pick == .setUp ? .setUp : .join)
            }
        )
    }
}

/// The library's summary line, with Sync Now as a VoiceOver action on it
/// while sync is on (FR43). A view of its own, so that only it is drawn again
/// when the sync's status changes, not the whole library list.
struct PhoneLibrarySummaryText: View {
    /// The summary sentence, such as "743 books. 14 hours left."
    let summary: String
    /// What the app's one sync reports.
    @ObservedObject private var center = SyncCenter.shared

    var body: some View {
        Text(summary)
            .font(.subheadline)
            .phoneSecondaryText()
            .frame(maxWidth: .infinity, alignment: .leading)
            // Nothing is added before sync is set up (R1): no action, and no words, until it is on.
            .accessibilityActions {
                if PhoneSyncSettingsModel.offersSyncNowOnSummary(center.status) {
                    Button(SyncWording.syncNowTitle) { center.syncNow() }
                }
            }
    }
}
