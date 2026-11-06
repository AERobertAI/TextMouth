import SwiftUI

/// The words of the Library Not Available screen (FR02), kept in one place
/// so the screen, the window's title, the announcements, and the tests say
/// the same thing.
enum DataDirectoryUnavailableText {
    /// The screen's heading, and the Library window's title meanwhile.
    static let title = "Library Not Available"
    /// The heading while TextMouth is getting the library's files from the
    /// cloud, which it opens by itself when they arrive.
    static let gettingTitle = "Getting Your Library"

    /// The heading for `reason`: "Getting Your Library" while the files are
    /// on their way, "Library Not Available" otherwise.
    static func title(for reason: DataDirectoryUnavailability) -> String {
        reason.isGettingFromCloud ? gettingTitle : title
    }
    /// What the full path of the data directory is labelled.
    static let locationLabel = "Location"
    /// The button that checks the data directory again.
    static let tryAgain = "Try Again"
    /// What Try Again does.
    static let tryAgainHint = "Checks the library's location again, and opens the library when it is there."
    /// The button that quits.
    static let quit = "Quit TextMouth"
    /// What Quit TextMouth does.
    static let quitHint = "Quits TextMouth without changing anything in the library's location."

    /// The way to another library, under the reason: Storage settings and
    /// the two buttons they show while the library isn't available, named
    /// as their titles read (`StorageLocationWording`), so the sentence
    /// follows any change to them. "To use another folder, open Settings,
    /// Storage, and choose Choose Another Library or Use Default Location."
    static let anotherFolderPointer = "To use another folder, open Settings, Storage, and choose "
        + "\(buttonName(StorageLocationWording.chooserTitle(isLibraryAvailable: false))) or "
        + "\(buttonName(StorageLocationWording.useDefaultTitle))."

    /// What VoiceOver hears when the screen appears: the heading, then why.
    static func announcement(for reason: DataDirectoryUnavailability) -> String {
        "\(title(for: reason)). \(reason.explanation)"
    }

    /// What the window says when an app-wide action reaches it while the
    /// library is unavailable, or nil for an action that needs no library,
    /// such as bringing the Library window forward.
    static func refusal(of action: GlobalAction) -> String? {
        switch action {
        case .openBookFile, .newFromText, .importDAISYFolder, .openFiles:
            return "Books can't be added while the library isn't available."
        case .openBookWindow, .continueToNextBook:
            return "Books can't be opened while the library isn't available."
        case .goToLibrary:
            return nil
        }
    }

    /// A button's title as a sentence names it: without the "..." that marks
    /// a button opening a window or a chooser ("Use Default Location...").
    private static func buttonName(_ title: String) -> String {
        title.hasSuffix("...") ? String(title.dropLast(3)) : title
    }
}

/// What every Library window shows in place of the library while the data
/// directory can't be used (FR02): nothing was loaded, and nothing is saved.
///
/// It reads in order with VoiceOver and a braille display: the heading, the
/// reason in one sentence, where to choose another folder instead (Storage
/// settings), the full path as selectable text, any refused action, then
/// Try Again, the default button, which Return presses, and Quit TextMouth.
/// VoiceOver focus moves to the reason when the view appears, and once
/// VoiceOver has had time to say it, the heading and the reason are
/// announced through `onAnnounce`, which the library model answers once for
/// each reason, however many windows show the screen.
struct DataDirectoryUnavailableView: View {
    /// Why the library can't be used.
    let unavailability: DataDirectoryUnavailability
    /// The sentence about an action refused meanwhile, or nil.
    let notice: String?
    /// How long VoiceOver waits before moving to the reason: as long as the
    /// window takes to settle at launch. Tests pass a shorter one.
    var focusDelay: TimeInterval = 1.2
    /// Asks for the reason to be announced.
    let onAnnounce: () -> Void
    /// Checks the data directory again.
    let onTryAgain: () -> Void
    /// Quits TextMouth.
    let onQuit: () -> Void

    /// How long after VoiceOver's move the reason is announced: time for
    /// VoiceOver to land on the reason and begin saying it.
    static let announcementLag: TimeInterval = 0.8

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 44))
                .foregroundColor(.orange)
                .accessibilityHidden(true)

            Text(DataDirectoryUnavailableText.title(for: unavailability))
                .font(.title.bold())
                .accessibilityAddTraits(.isHeader)

            Text(unavailability.explanation)
                .font(.title3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .modifier(InitialVoiceOverFocusModifier(isTarget: true, delay: focusDelay))

            // The way out when the library won't come back, read right
            // after the reason and before the buttons.
            Text(DataDirectoryUnavailableText.anotherFolderPointer)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            location

            if let notice {
                Text(notice)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Button(DataDirectoryUnavailableText.tryAgain, action: onTryAgain)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel(DataDirectoryUnavailableText.tryAgain)
                    .accessibilityHint(DataDirectoryUnavailableText.tryAgainHint)
                Button(DataDirectoryUnavailableText.quit, action: onQuit)
                    .accessibilityLabel(DataDirectoryUnavailableText.quit)
                    .accessibilityHint(DataDirectoryUnavailableText.quitHint)
            }
            .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A new reason, as when the fetch ends, is announced again.
        .task(id: unavailability) { await announceReason() }
    }

    /// The data directory's full path, under its label, read by VoiceOver
    /// as one element ("Location, /Volumes/Backup/TextMouth"). The path can
    /// be selected and copied.
    private var location: some View {
        VStack(spacing: 4) {
            Text(DataDirectoryUnavailableText.locationLabel)
                .font(.headline)
            Text(unavailability.folder)
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundColor(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// Announces the reason once VoiceOver has had time to move to it and
    /// begin saying it, so the announcement follows rather than cuts it
    /// off. A view that is gone by then announces nothing.
    private func announceReason() async {
        try? await Task.sleep(for: .seconds(focusDelay + Self.announcementLag))
        guard !Task.isCancelled else { return }
        onAnnounce()
    }
}
