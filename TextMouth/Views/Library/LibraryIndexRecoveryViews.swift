import SwiftUI

/// Wording shared by the recovery sheet and banner, kept in one place so the
/// two always describe the state the same way.
enum LibraryIndexRecoveryText {
    static let title = "Library Index Could Not Be Read"

    static let summary = "TextMouth could not read its library index, the file that records your "
        + "folders, sort settings, and the order of your books. The library now shows a temporary "
        + "list rebuilt from the books on disk. You can open and read books, and reading positions "
        + "are still saved with each book, but changes to the library itself are not saved until "
        + "you choose one of the options below."

    static let noCopy = "TextMouth could not save a copy of the unreadable file. The file itself "
        + "has not been changed."

    static let tryAgain = "Reads the file again. Use this after restoring the file from a backup, "
        + "fixing its permissions, or updating TextMouth to the version that saved it."

    /// What Rebuild Library Index loses and where the old data stays.
    static func rebuild(savedCopy: URL?) -> String {
        let consequence = "Saves the temporary library as the new index. Folder placement, sort "
            + "settings, and manual order that were stored only in the unreadable index are lost "
            + "from the library."
        guard let savedCopy else {
            return consequence + " TextMouth first saves a copy of the old file, and does not "
                + "rebuild if it cannot."
        }
        return consequence + " The saved copy at \(savedCopy.path) keeps the old data."
    }

    static let continueReading = "Closes these options so you can keep reading. The index is not "
        + "changed until you choose Try Again or Rebuild Library Index, which stay available from "
        + "Recovery Options at the top of the library."

    static let quit = "Quits TextMouth without writing the library index, so you can restore the "
        + "file and open TextMouth again."

    static let banner = "The library index could not be read. This is a temporary library, and "
        + "library changes are not being saved."
}

/// The choices offered when the library index cannot be read, shown as a
/// sheet over the library window. It reads in order with VoiceOver and a
/// braille display: a heading, what happened, the reason, the unreadable
/// file and its saved copy, then each choice as a labelled button followed
/// by a sentence saying what it does. Return chooses Try Again and Escape
/// chooses Continue Reading.
struct LibraryIndexRecoverySheet: View {
    let recovery: LibraryIndexRecovery
    let onTryAgain: () -> Void
    let onRebuild: () -> Void
    let onContinue: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(LibraryIndexRecoveryText.title)
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
                .modifier(InitialVoiceOverFocusModifier(isTarget: true))

            paragraph(LibraryIndexRecoveryText.summary)

            detail("Reason", recovery.failure.reason)
            detail("Unreadable file", recovery.failure.indexURL.path)
            if let savedCopy = recovery.failure.quarantineURL {
                detail("Saved copy", savedCopy.path)
                Button("Show Saved Copy in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([savedCopy])
                }
            } else {
                paragraph(LibraryIndexRecoveryText.noCopy)
            }

            // The outcome of an attempt that did not end recovery, such as a
            // Try Again that still failed. VoiceOver also announces it.
            if let lastAttempt = recovery.lastAttempt {
                detail("Last attempt", lastAttempt.message)
            }

            Divider()

            option(
                "Try Again",
                description: LibraryIndexRecoveryText.tryAgain,
                shortcut: .defaultAction,
                action: onTryAgain
            )
            option(
                "Rebuild Library Index",
                description: LibraryIndexRecoveryText.rebuild(savedCopy: recovery.failure.quarantineURL),
                action: onRebuild
            )
            option(
                "Continue Reading",
                description: LibraryIndexRecoveryText.continueReading,
                shortcut: .cancelAction,
                action: onContinue
            )
            option(
                "Quit TextMouth",
                description: LibraryIndexRecoveryText.quit,
                action: onQuit
            )
        }
        .padding(24)
        .frame(width: 560)
    }

    /// Body text that wraps instead of being truncated.
    private func paragraph(_ text: String) -> some View {
        Text(text)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A labelled value, such as the reason or a file path, read by VoiceOver
    /// as one element ("Reason, The file is empty."). Paths can be selected
    /// and copied with the mouse or keyboard.
    private func detail(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.headline)
            Text(value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// One choice: its button, then the sentence saying what it does.
    private func option(
        _ title: String,
        description: String,
        shortcut: KeyboardShortcut? = nil,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(title, action: action)
                .keyboardShortcut(shortcut)
            Text(description)
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Shown at the top of the library while the index cannot be read, so the
/// state stays visible after the recovery sheet is closed and its options
/// stay one button away.
struct LibraryIndexRecoveryBanner: View {
    let onShowOptions: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .accessibilityHidden(true)
            Text(LibraryIndexRecoveryText.banner)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Recovery Options...", action: onShowOptions)
                .accessibilityHint("Shows the choices for recovering the library index")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.15))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Library index recovery")
    }
}
