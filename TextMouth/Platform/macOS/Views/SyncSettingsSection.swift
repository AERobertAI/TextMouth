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
    /// Whether Stop Syncing's question is up.
    @State private var confirmingStop = false
    /// Whether a command is running, which holds the others back.
    @State private var isWorking = false

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

            if let message = model.message {
                // The words say what went wrong, so the color is never the only sign.
                Text(message)
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if center.status.isOn {
                Button(SyncWording.syncNowTitle) { model.syncNow() }
                    .disabled(center.status.isSyncing)
                    .accessibilityLabel(SyncWording.syncNowTitle)
                    .accessibilityHint(SyncWording.sectionSummary)
                Button(SyncWording.stopTitle) { confirmingStop = true }
                    .accessibilityLabel(SyncWording.stopTitle)
                    .accessibilityHint(SyncWording.stopQuestion)
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
        .alert(SyncWording.stopQuestion, isPresented: $confirmingStop) {
            Button(Self.withoutEllipsis(SyncWording.stopTitle)) { model.stop() }
            Button(StorageSettingsWording.cancelTitle, role: .cancel) {}
        }
    }

    /// The status line's sentence now.
    private var statusSentence: String {
        SyncStatusLine.text(for: center.status, isPhone: false, time: Self.timeOfDay)
    }

    /// The lines after it.
    private var details: [String] {
        SyncStatusLine.detailLines(for: center.status, time: Self.timeOfDay)
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
            Task { @MainActor in
                let worked = joining ? await model.join(folder) : await model.setUp(in: folder)
                isWorking = false
                if worked { VoiceOverAnnouncer.announce(SyncWording.statusSyncing) }
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            panel.begin(completionHandler: handle)
        }
    }
}
