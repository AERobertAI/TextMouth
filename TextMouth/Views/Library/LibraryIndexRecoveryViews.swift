import SwiftUI

/// Wording shared by the recovery sheet and banner, kept in one place so the
/// two always describe the state the same way.
enum LibraryIndexRecoveryText {
    static var title: String {
        // Translators: Heading of the sheet shown when the library index file can't be read.
        InterfaceText.line("libraryIndexRecovery.title", "Library Index Could Not Be Read")
    }

    /// What the sheet says happened, in five sentences.
    static var summary: String {
        SentenceWording.joined([
            // Translators: First sentence of the library index recovery sheet: what the unreadable file holds.
            InterfaceText.line("libraryIndexRecovery.summary.settings", "TextMouth could not read its library index, the file that records your folders, sort settings, and the order of your books."),
            // Translators: Second sentence of the library index recovery sheet.
            InterfaceText.line("libraryIndexRecovery.summary.temporary", "The library now shows a temporary list rebuilt from the books on disk."),
            // Translators: Last sentence of the library index recovery sheet: what still works, and what does not until an option is chosen.
            InterfaceText.line("libraryIndexRecovery.summary.positions", "You can open and read books, and reading positions are still saved with each book, but changes to the library itself are not saved until you choose one of the options below."),
        ])
    }

    static var noCopy: String {
        SentenceWording.joined([
            // Translators: First sentence of the library index recovery sheet when no copy of the unreadable file was saved.
            InterfaceText.line("libraryIndexRecovery.noCopy.unreadable", "TextMouth could not save a copy of the unreadable file."),
            // Translators: Last sentence of the library index recovery sheet when no copy of the unreadable file was saved.
            InterfaceText.line("libraryIndexRecovery.noCopy.changed", "The file itself has not been changed."),
        ])
    }

    // MARK: The Choices' Names

    /// Try Again's title, as the sheet's button shows it and sentences name it.
    static var tryAgainTitle: String {
        // Translators: Button of the library index recovery sheet that reads the index file again. Also the name sentences use for it.
        InterfaceText.line("common.tryAgain", "Try Again")
    }

    /// Rebuild Library Index's title, as the sheet's button shows it and sentences name it.
    static var rebuildTitle: String {
        // Translators: Button of the library index recovery sheet that saves the temporary library as the new index. Also the name sentences use for it.
        InterfaceText.line("libraryIndexRecovery.rebuildTitle", "Rebuild Library Index")
    }

    /// Continue Reading's title.
    static var continueReadingTitle: String {
        // Translators: Button of the library index recovery sheet that closes it so the listener can keep reading.
        InterfaceText.line("libraryIndexRecovery.continueReadingTitle", "Continue Reading")
    }

    /// Quit TextMouth's title.
    static var quitTitle: String {
        // Translators: Button of the library index recovery sheet that quits TextMouth.
        InterfaceText.line("common.quitTextmouth", "Quit TextMouth")
    }

    /// The banner's button that brings the sheet back, as sentences name it.
    static var recoveryOptionsName: String {
        // Translators: The name sentences use for the button at the top of the library that shows the library index recovery choices again.
        InterfaceText.line("libraryIndexRecovery.recoveryOptionsName", "Recovery Options")
    }

    /// The banner's button that brings the sheet back.
    static var recoveryOptionsTitle: String {
        // Translators: Button at the top of the library that shows the library index recovery choices again. The three dots show that a sheet opens.
        InterfaceText.line("libraryIndexRecovery.recoveryOptionsTitle", "Recovery Options...")
    }

    static var showSavedCopyTitle: String {
        // Translators: Button of the library index recovery sheet that shows the saved copy of the unreadable file in the Finder.
        InterfaceText.line("libraryIndexRecovery.showSavedCopyTitle", "Show Saved Copy in Finder")
    }

    // MARK: The Sheet's Labels

    static var reasonLabel: String {
        // Translators: Label of why the library index could not be read, on the library index recovery sheet.
        InterfaceText.line("libraryIndexRecovery.reasonLabel", "Reason")
    }

    static var unreadableFileLabel: String {
        // Translators: Label of the path of the unreadable library index file, on the library index recovery sheet.
        InterfaceText.line("libraryIndexRecovery.unreadableFileLabel", "Unreadable file")
    }

    static var savedCopyLabel: String {
        // Translators: Label of the path of the saved copy of the unreadable library index file, on the library index recovery sheet.
        InterfaceText.line("libraryIndexRecovery.savedCopyLabel", "Saved copy")
    }

    static var lastAttemptLabel: String {
        // Translators: Label of the outcome of the last Try Again or Rebuild Library Index, on the library index recovery sheet.
        InterfaceText.line("libraryIndexRecovery.lastAttemptLabel", "Last attempt")
    }

    static var tryAgain: String {
        SentenceWording.joined([
            // Translators: First sentence of what Try Again does on the library index recovery sheet.
            InterfaceText.line("libraryIndexRecovery.tryAgain.reads", "Reads the file again."),
            // Translators: Last sentence of what Try Again does on the library index recovery sheet: when to use it.
            InterfaceText.line("libraryIndexRecovery.tryAgain.restoring", "Use this after restoring the file from a backup, fixing its permissions, or updating TextMouth to the version that saved it."),
        ])
    }

    /// What Rebuild Library Index keeps and loses, and where the old data
    /// stays: it keeps the reading list and the sort settings the temporary
    /// library began with (FR09), and names those of them, `notKept`, that
    /// could not be read in the unreadable index.
    static func rebuild(savedCopy: URL?, notKept: LibraryIndexArrangement = []) -> String {
        var sentences = [
            // Translators: First sentence of what Rebuild Library Index does on the library index recovery sheet.
            InterfaceText.line("libraryIndexRecovery.rebuild.temporary", "Saves the temporary library as the new index, with the reading list and the sort settings TextMouth could read."),
            // Translators: Second sentence of what Rebuild Library Index does: what is lost.
            InterfaceText.line("libraryIndexRecovery.rebuild.placement", "Folder placement and manual order that were stored only in the unreadable index are lost from the library."),
        ]
        if let notRead = notKept.notReadSentence(in: .unreadable) {
            sentences.append(notRead)
        }
        if let savedCopy {
            // Translators: Last sentence of what Rebuild Library Index does: where the old data stays. %@ is the saved copy's path.
            sentences.append(InterfaceText.line("libraryIndexRecovery.rebuild.saved", "The saved copy at \(savedCopy.path) keeps the old data."))
        } else {
            // Translators: Last sentence of what Rebuild Library Index does when no copy has been saved yet: it saves one first.
            sentences.append(InterfaceText.line("libraryIndexRecovery.rebuild.cannot", "TextMouth first saves a copy of the old file, and does not rebuild if it cannot."))
        }
        return SentenceWording.joined(sentences)
    }

    static var continueReading: String {
        SentenceWording.joined([
            // Translators: First sentence of what Continue Reading does on the library index recovery sheet.
            InterfaceText.line("libraryIndexRecovery.continueReading.options", "Closes these options so you can keep reading."),
            // Translators: Last sentence of what Continue Reading does. %1$@ and %2$@ are the names of the Try Again and Rebuild Library Index buttons; %3$@ is the name of the Recovery Options button.
            InterfaceText.line("libraryIndexRecovery.continueReading.available", "The index is not changed until you choose \(tryAgainTitle) or \(rebuildTitle), which stay available from \(recoveryOptionsName) at the top of the library."),
        ])
    }

    static var quit: String {
        // Translators: What Quit TextMouth does on the library index recovery sheet.
        InterfaceText.line("libraryIndexRecovery.quit", "Quits TextMouth without writing the library index, so you can restore the file and open TextMouth again.")
    }

    static var banner: String {
        SentenceWording.joined([
            // Translators: First sentence of the banner shown at the top of the library while the library index is unreadable.
            InterfaceText.line("libraryIndexRecovery.banner.read", "The library index could not be read."),
            // Translators: Last sentence of the banner shown at the top of the library while the library index is unreadable.
            InterfaceText.line("libraryIndexRecovery.banner.temporary", "This is a temporary library, and library changes are not being saved."),
        ])
    }

    /// The Storage settings status while recovering.
    static var settingsStatus: String {
        // Translators: Storage settings status line while the library index can't be read.
        InterfaceText.line("libraryIndexRecovery.settingsStatus", "Library index unreadable")
    }

    static var settingsExplanation: String {
        SentenceWording.joined([
            // Translators: First sentence of the Storage settings explanation while the library index can't be read.
            InterfaceText.line("libraryIndexRecovery.settingsExplanation.changes", "The library index could not be read, so library changes are not being saved."),
            // Translators: Second sentence of the Storage settings explanation while the library index can't be read. %1$@ and %2$@ are the names of the Try Again and Rebuild Library Index buttons; %3$@ is the name of the Recovery Options button.
            InterfaceText.line("libraryIndexRecovery.settingsExplanation.choose", "Choose \(tryAgainTitle) or \(rebuildTitle) from \(recoveryOptionsName) at the top of the Library window."),
            // Translators: Last sentence of the Storage settings explanation while the library index can't be read.
            InterfaceText.line("libraryIndexRecovery.settings.rebuilding", "Until then, changing the location and rebuilding the directory are unavailable."),
        ])
    }

    // MARK: The Banner

    static var bannerHint: String {
        // Translators: VoiceOver hint of the Recovery Options button at the top of the library.
        InterfaceText.line("libraryIndexRecovery.bannerHint", "Shows the choices for recovering the library index")
    }

    static var bannerLabel: String {
        // Translators: VoiceOver label of the banner at the top of the library while the library index is unreadable.
        InterfaceText.line("libraryIndexRecovery.bannerLabel", "Library index recovery")
    }
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

            detail(LibraryIndexRecoveryText.reasonLabel, recovery.failure.reason)
            detail(LibraryIndexRecoveryText.unreadableFileLabel, recovery.failure.indexURL.path)
            if let savedCopy = recovery.failure.quarantineURL {
                detail(LibraryIndexRecoveryText.savedCopyLabel, savedCopy.path)
                // Finder is the Mac's; the saved copy's path is already
                // shown on the line above, so iOS has no button here.
                #if os(macOS)
                Button(LibraryIndexRecoveryText.showSavedCopyTitle) {
                    NSWorkspace.shared.activateFileViewerSelecting([savedCopy])
                }
                #endif
            } else {
                paragraph(LibraryIndexRecoveryText.noCopy)
            }

            // The outcome of an attempt that did not end recovery, such as a
            // Try Again that still failed. VoiceOver also announces it.
            if let lastAttempt = recovery.lastAttempt {
                detail(LibraryIndexRecoveryText.lastAttemptLabel, lastAttempt.message)
            }

            Divider()

            option(
                LibraryIndexRecoveryText.tryAgainTitle,
                description: LibraryIndexRecoveryText.tryAgain,
                shortcut: .defaultAction,
                action: onTryAgain
            )
            option(
                LibraryIndexRecoveryText.rebuildTitle,
                description: LibraryIndexRecoveryText.rebuild(
                    savedCopy: recovery.failure.quarantineURL,
                    notKept: recovery.arrangementNotKept
                ),
                action: onRebuild
            )
            option(
                LibraryIndexRecoveryText.continueReadingTitle,
                description: LibraryIndexRecoveryText.continueReading,
                shortcut: .cancelAction,
                action: onContinue
            )
            option(
                LibraryIndexRecoveryText.quitTitle,
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
    /// as one element ("Reason, The file is empty."). The value can be
    /// selected and copied; Show Saved Copy in Finder reaches the saved copy
    /// without selecting or typing its path.
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
            Button(LibraryIndexRecoveryText.recoveryOptionsTitle, action: onShowOptions)
                .accessibilityHint(LibraryIndexRecoveryText.bannerHint)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.15))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(LibraryIndexRecoveryText.bannerLabel)
    }
}
