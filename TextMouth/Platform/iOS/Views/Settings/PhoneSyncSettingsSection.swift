import SwiftUI
import UniformTypeIdentifiers

/// The rows of Settings' Sync section (FR43): what sync does, the status line
/// and the lines after it, and the section's buttons. With sync off they are
/// Set Up Sync… and Join Sync Folder…, each opening the system's folder picker
/// (Files), and with it on, Sync Now and Stop Syncing…. The words and the steps are
/// the Mac's own (`SyncSettingsModel`, `SyncStatusLine`), in the iPhone's forms;
/// this view draws them and keeps what is the phone's alone: the picker, the
/// confirmation, and VoiceOver's focus. Nothing here has run on a phone.
///
/// Each state is words, never colour or position: the status is static text
/// that VoiceOver and braille read where it stands, a refusal or failure is a line
/// of words (and is spoken), and VoiceOver's focus comes back to the status line
/// when the controls change under it.
struct PhoneSyncSettingsSection: View {
    /// What the app's one sync reports; the rows are drawn again when it changes.
    @ObservedObject private var center = SyncCenter.shared
    /// The steps the buttons take.
    @StateObject private var steps = PhoneSyncSettingsController()
    /// This iPhone's own choice of books to keep, and the days a book may stay unopened (FR45).
    @ObservedObject private var space = SyncSpaceSettings.shared
    /// What the folder picker now showing is for.
    @State private var pick: PhoneSyncPick = .setUp
    /// Whether the folder picker is up.
    @State private var isPicking = false
    /// Whether Set Up or Join has just worked and its first run's outcome is still to be said.
    @State private var awaitingFirstRun = false
    /// VoiceOver's focus in the section: on the status line when the controls change under it, so the button just
    /// pressed leaving does not lose it.
    @AccessibilityFocusState private var statusIsFocused: Bool

    var body: some View {
        // What sync is for, left where VoiceOver and braille can read it. The picker and the confirmation hang on this one
        // row (never on all of them, which would present each of them once for each row), and apart from the screen's own
        // file exporter, since two of the system's file dialogs on one view are not known to work together.
        PhoneReadableCaption(SyncWording.sectionSummary)
            .background {
                Color.clear
                    .fileImporter(
                        isPresented: $isPicking,
                        allowedContentTypes: [.folder],
                        allowsMultipleSelection: false,
                        onCompletion: { picked($0) },
                        // A cancel never reaches `onCompletion`: without this, focus would not come back.
                        onCancellation: { statusIsFocused = true }
                    )
            }
            .alert(SyncWording.stopQuestion(isPhone: true, onlyInCloud: steps.onlyInCloud), isPresented: $steps.isAskingToStop) {
                // Cancel is first, so the safe choice is the one VoiceOver reaches first.
                Button(PhoneAppWording.cancel, role: .cancel) {}
                Button(SyncWording.stopButton, role: .destructive) { steps.confirmStop() }
            }
        // The status line and its details are one element, so VoiceOver reads where sync stands in one go.
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).phonePrimaryText()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityFocused($statusIsFocused)
        // These hang on the one status element, not on each button. The controls change when sync turns on or off; focus goes to the status line, not to nothing.
        .onChange(of: center.status.isOn) { _, _ in statusIsFocused = true }
        // The first run's outcome, after Set Up or Join, is said when it ends.
        .onChange(of: center.status.isSyncing) { _, syncing in
            guard !syncing, awaitingFirstRun, center.status.isOn else { return }
            awaitingFirstRun = false
            VoiceOverAnnouncer.announce(lines.first ?? "")
        }
        if let message = steps.model.message {
            // The words say what went wrong, so the color is never the only sign.
            Text(message).phonePrimaryText()
        }
        // Nothing is added before sync is set up (R1): the device's own choice of books shows once it is on.
        if center.status.isOn {
            SyncSpaceControls(settings: space)
        }
        ForEach(PhoneSyncSettingsModel.controls(isOn: center.status.isOn)) { control in
            PhoneActionButton(title: control.title) { press(control) }
                .disabled(steps.isWorking || (control == .syncNow && center.status.isSyncing))
                .accessibilityHint(control.hint)
        }
    }

    /// The status line, then who was last heard from and the books' backup; while a step runs, the words for the wait.
    private var lines: [String] {
        steps.working.map { [PhoneSyncSettingsController.workingLine(for: $0)] } ?? PhoneSyncSettingsModel.lines(for: center.status)
    }

    /// What pressing `control` does.
    private func press(_ control: PhoneSyncControl) {
        switch control {
        case .setUp:
            pick = .setUp
            choose()
        case .join:
            pick = .join
            choose()
        case .syncNow:
            steps.syncNow()
        case .stop:
            Task { await steps.askToStop() }
        }
    }

    /// Opens the folder picker; in a Debug build whose interface test names a sandbox folder (`TEXTMOUTH_SYNC_FOLDER`), the
    /// folder is taken as if it had been picked, since a test can't drive the system's picker.
    private func choose() {
        if let folder = SyncCenter.seamFolder() {
            picked(.success([folder]))
        } else {
            isPicking = true
        }
    }

    /// The picker returned: makes or joins the folder, says what came of it, and leaves VoiceOver on the status line.
    private func picked(_ result: Result<[URL], Error>) {
        let kind = pick
        Task {
            let worked = await steps.picked(result, for: kind)
            if worked {
                awaitingFirstRun = true
                VoiceOverAnnouncer.announce(SyncWording.statusSyncing)
            }
            statusIsFocused = true
        }
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
            // Nothing is added before sync is set up (R1): no action until it is on.
            .accessibilityActions {
                if PhoneSyncSettingsModel.offersSyncNowOnSummary(center.status) {
                    Button(SyncWording.syncNowTitle) { center.syncNow() }
                }
            }
    }
}
