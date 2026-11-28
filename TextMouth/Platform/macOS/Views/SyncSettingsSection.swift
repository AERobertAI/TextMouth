import AppKit
import SwiftUI

/// The Sync section of Storage settings (FR43): what syncing is, how it
/// stands, and its commands. Off, it offers Set Up Sync… and Join Sync
/// Folder…, each choosing a folder in iCloud Drive with an open panel; on, it
/// offers Sync Now and Stop Syncing…. Everything it says is `SyncWording`'s,
/// through `SyncSettingsModel`, and every control speaks its label and hint.
struct SyncSettingsSection: View {
    /// What the commands do and say.
    @StateObject private var model = SyncSettingsModel()
    /// The sync's state, which redraws the status line as it changes.
    @ObservedObject private var center = SyncCenter.shared
    /// This Mac's own choice of books to keep, and the days a book may stay unopened (FR45).
    @ObservedObject private var space = SyncSpaceSettings.shared
    /// Whether Stop Syncing's question is up.
    @State private var confirmingStop = false
    /// How many books have files only in the sync folder, counted from their packages as Stop Syncing was pressed,
    /// which its question names.
    @State private var onlyInCloud = 0
    /// Whether a command is running, which holds the others back.
    @State private var isWorking = false
    /// Whether Set Up or Join has just worked and its first run's outcome is
    /// still to be said.
    @State private var awaitingFirstRun = false
    /// VoiceOver's focus in the section: on the status line when the controls
    /// change under it, so the button just pressed leaving does not lose it.
    @AccessibilityFocusState private var statusIsFocused: Bool

    var body: some View {
        Section {
            Text(SyncWording.sectionSummary)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // The status line and its details are one element, so VoiceOver
            // reads where sync stands in one go.
            VStack(alignment: .leading, spacing: 2) {
                Text(statusSentence)
                ForEach(Array(details.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption).foregroundColor(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityFocused($statusIsFocused)

            if let message = model.message {
                // The words say what went wrong, so the color is never the only sign.
                Text(message)
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if center.status.isOn {
                SyncSpaceControls(settings: space)
                Button(SyncWording.syncNowTitle) { model.syncNow() }
                    .disabled(center.status.isSyncing)
                    .accessibilityLabel(SyncWording.syncNowTitle)
                    .accessibilityHint(SyncWording.sectionSummary)
                Button(SyncWording.stopTitle) { askToStop() }
                    .accessibilityLabel(SyncWording.stopTitle)
                    .accessibilityHint(SyncWording.stopQuestion(isPhone: false))
            } else {
                Button(SyncWording.setUpTitle) { choose(joining: false) }
                    .disabled(isWorking)
                    .accessibilityLabel(SyncWording.setUpTitle)
                    .accessibilityHint(SyncWording.setUpHint)
                Button(SyncWording.joinTitle) { choose(joining: true) }
                    .disabled(isWorking)
                    .accessibilityLabel(SyncWording.joinTitle)
                    .accessibilityHint(SyncWording.joinHint)
            }
        } header: {
            Text(SyncWording.sectionTitle)
        }
        .alert(stopQuestion, isPresented: $confirmingStop) {
            // Cancel is first, so Return presses the safe choice.
            Button(StorageSettingsWording.cancelTitle, role: .cancel) {}
                .keyboardShortcut(.defaultAction)
            Button(Self.withoutEllipsis(SyncWording.stopTitle), role: .destructive) { model.stop() }
        }
        // The controls change when sync turns on or off; focus goes to the
        // status line, not to nothing.
        .onChange(of: center.status.isOn) { _, _ in statusIsFocused = true }
        // The first run's outcome, after Set Up or Join, is said when it ends.
        .onChange(of: center.status.isSyncing) { _, syncing in
            guard !syncing, awaitingFirstRun, center.status.isOn else { return }
            awaitingFirstRun = false
            VoiceOverAnnouncer.announce(statusSentence)
        }
    }

    /// The question before syncing stops, with the books only in iCloud Drive counted.
    private var stopQuestion: String {
        SyncWording.stopQuestion(isPhone: false, onlyInCloud: onlyInCloud)
    }

    /// Counts the books only in the sync folder, from their packages, then asks whether to stop.
    private func askToStop() {
        Task {
            onlyInCloud = await center.countBooksOnlyInTheSyncFolder()
            confirmingStop = true
        }
    }

    /// The status line's sentence now.
    private var statusSentence: String {
        SyncStatusLine.text(for: center.status, isPhone: false, time: Self.timeOfDay)
    }

    /// The lines after it.
    private var details: [String] {
        SyncStatusLine.detailLines(for: center.status, time: Self.timeOfDay, isPhone: false)
    }

    // MARK: - Choosing a Folder

    /// The settings of the panel that chooses a folder in iCloud Drive: to
    /// set up sync in it, or to join the TextMouth Sync folder there. The
    /// panel's title and default button name the command, without its ellipsis.
    static func panelSettings(joining: Bool) -> FolderPanelSettings {
        let title = withoutEllipsis(joining ? SyncWording.joinTitle : SyncWording.setUpTitle)
        return FolderPanelSettings(
            canChooseDirectories: true,
            canChooseFiles: false,
            allowsMultipleSelection: false,
            canCreateDirectories: !joining,
            title: title,
            message: joining ? SyncWording.joinHint : SyncWording.setUpHint,
            prompt: title,
            directoryURL: nil
        )
    }

    /// A date as a time of day, as the system writes one: "9:41 AM".
    static func timeOfDay(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// A command's title without the ellipsis that says a window follows.
    static func withoutEllipsis(_ title: String) -> String {
        title.hasSuffix("…") ? String(title.dropLast()) : title
    }

    /// Opens the folder panel as a sheet on the Settings window, and hands
    /// the folder chosen to Set Up Sync or Join Sync Folder.
    private func choose(joining: Bool) {
        let panel = Self.panelSettings(joining: joining).makePanel()
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let folder = panel.url else { return }
            isWorking = true
            // Set before the run starts, so a run that ends at once is heard.
            awaitingFirstRun = true
            Task { @MainActor in
                let worked = joining ? await model.join(folder) : await model.setUp(in: folder)
                isWorking = false
                if worked {
                    VoiceOverAnnouncer.announce(SyncWording.statusSyncing)
                } else {
                    awaitingFirstRun = false
                }
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            panel.begin(completionHandler: handle)
        }
    }
}
