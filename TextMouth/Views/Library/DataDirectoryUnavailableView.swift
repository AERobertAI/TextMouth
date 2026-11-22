import SwiftUI

/// The words of the Library Not Available screen (FR02), kept in one place
/// so the screen, the window's title, the announcements, and the tests say
/// the same thing.
enum DataDirectoryUnavailableText {
    /// The screen's heading, and the Library window's title meanwhile.
    static var title: String {
        // Translators: Heading of the screen shown in place of the library when its folder can't be used, and the Library window's title meanwhile.
        InterfaceText.line("dataDirectoryUnavailable.title", "Library Not Available")
    }
    /// The heading while TextMouth is getting the library's files from the
    /// cloud, which it opens by itself when they arrive.
    static var gettingTitle: String {
        // Translators: Heading of the screen shown while TextMouth gets the library's files from the cloud; the library opens by itself when they arrive.
        InterfaceText.line("dataDirectoryUnavailable.gettingTitle", "Getting Your Library")
    }

    /// The heading for `reason`: "Getting Your Library" while the files are
    /// on their way, "Library Not Available" otherwise.
    static func title(for reason: DataDirectoryUnavailability) -> String {
        reason.isGettingFromCloud ? gettingTitle : title
    }
    /// What the full path of the data directory is labelled.
    static var locationLabel: String {
        // Translators: Label of the library's full folder path on the Library Not Available screen.
        InterfaceText.line("common.location", "Location")
    }
    /// The button that checks the data directory again.
    static var tryAgain: String {
        // Translators: Button on the Library Not Available screen that checks the library's folder again.
        InterfaceText.line("common.tryAgain", "Try Again")
    }
    /// What Try Again does.
    static var tryAgainHint: String {
        // Translators: VoiceOver hint of Try Again on the Library Not Available screen.
        InterfaceText.line("dataDirectoryUnavailable.tryAgainHint", "Checks the library's location again, and opens the library when it is there.")
    }
    /// The button that quits.
    static var quit: String {
        // Translators: Button on the Library Not Available screen that quits TextMouth.
        InterfaceText.line("common.quitTextmouth", "Quit TextMouth")
    }
    /// What Quit TextMouth does.
    static var quitHint: String {
        // Translators: VoiceOver hint of Quit TextMouth on the Library Not Available screen.
        InterfaceText.line("dataDirectoryUnavailable.quitHint", "Quits TextMouth without changing anything in the library's location.")
    }

    /// The way to another library, under the reason: Storage settings and
    /// the two buttons they show while the library isn't available, named
    /// as their titles read (`StorageLocationWording`), so the sentence
    /// follows any change to them. "To use another folder, open Settings,
    /// Storage, and choose Choose Another Library or Use Default Location."
    static var anotherFolderPointer: String {
        // Translators: Sentence on the Library Not Available screen that points to the way to another library. Settings and Storage are the names of the settings window and its tab; %1$@ and %2$@ are the names of two buttons in Storage settings, as they show them.
        InterfaceText.line("dataDirectoryUnavailable.anotherFolderPointer", "To use another folder, open Settings, Storage, and choose \(buttonName(StorageLocationWording.chooserTitle(isLibraryAvailable: false))) or \(buttonName(StorageLocationWording.useDefaultTitle)).")
    }

    /// What VoiceOver hears when the screen appears: the heading, then why.
    static func announcement(for reason: DataDirectoryUnavailability) -> String {
        // Translators: What VoiceOver says when the Library Not Available screen appears. %1$@ is the screen's heading; %2$@ is why the library can't be used.
        InterfaceText.line("common.valuePeriodValue", "\(title(for: reason)). \(reason.explanation)")
    }

    /// What the window says when an app-wide action reaches it while the
    /// library is unavailable, or nil for an action that needs no library,
    /// such as bringing the Library window forward.
    static func refusal(of action: GlobalAction) -> String? {
        switch action {
        case .openBookFile, .newFromText, .importDAISYFolder, .openFiles:
            // Translators: What the Library window says when a command that adds a book is chosen while the library can't be used.
            return InterfaceText.line("dataDirectoryUnavailable.refusal.openBookFile", "Books can't be added while the library isn't available.")
        case .openBookWindow, .continueToNextBook:
            // Translators: What the Library window says when a command that opens a book is chosen while the library can't be used.
            return InterfaceText.line("dataDirectoryUnavailable.refusal.openBookWindow", "Books can't be opened while the library isn't available.")
        case .goToLibrary:
            return nil
        }
    }

    /// What the window says when actions it held while the library's files
    /// were on their way cannot be taken after all, because the fetch
    /// failed, the window closed, or another library was chosen: each
    /// action's refusal once, then which books were not opened, by file name
    /// where there is one. Nil when none of the actions needs the library.
    static func heldRefusal(of actions: [GlobalAction]) -> String? {
        var sentences: [String] = []
        var names: [String] = []
        var unnamedBooks = 0
        for action in actions {
            guard let sentence = refusal(of: action) else { continue }
            if !sentences.contains(sentence) {
                sentences.append(sentence)
            }
            switch action {
            case .openFiles(let urls): names += urls.map(\.lastPathComponent)
            case .openBookWindow, .continueToNextBook: unnamedBooks += 1
            default: break
            }
        }
        guard !sentences.isEmpty else { return nil }
        if unnamedBooks > 0 {
            // Translators: An entry in the list of what was not opened: books the listener asked to open that have no file name. %lld is how many books. The English one form is "one book from the library".
            names.append(InterfaceText.line("dataDirectoryUnavailable.heldRefusal.library", "\(number: unnamedBooks) books from the library"))
        }
        // Translators: Sentence on the Library Not Available screen that lists what was not opened. %@ is the list of file names and counts of books, separated by commas.
        let detail = names.isEmpty ? [] : [InterfaceText.line("dataDirectoryUnavailable.heldRefusal.opened", "Not opened: \(SentenceWording.commaJoined(names)).")]
        return SentenceWording.joined(sentences + detail)
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
    /// Opens the library without the file that did not arrive beside the
    /// other in a cloud location (risk 5), once the listener has confirmed
    /// it; nil offers no such button.
    var onOpenWithoutAwaitedFile: (() -> Void)? = nil

    /// Whether the question before opening without the file is shown.
    @State private var isConfirmingOpen = false

    /// How long after VoiceOver's move the reason is announced: time for
    /// VoiceOver to land on the reason and begin saying it.
    static let announcementLag: TimeInterval = 0.8

    /// The library file that did not arrive, with the service it was to come
    /// from, when that is the reason the screen shows; nil otherwise.
    private var awaited: (file: LibraryFileAwaited, provider: CloudProvider?)? {
        if case .libraryFileNotArrived(let provider, _, let file) = unavailability {
            return (file, provider)
        }
        return nil
    }

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
                // The way to open the library without the file that did not
                // arrive, which asks first (risk 5).
                if let awaited, onOpenWithoutAwaitedFile != nil {
                    Button(LibraryFileWaitWording.openTitle(for: awaited.file)) { isConfirmingOpen = true }
                        .accessibilityLabel(LibraryFileWaitWording.openTitle(for: awaited.file))
                        .accessibilityHint(LibraryFileWaitWording.openHint(for: awaited.file))
                }
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
        // The question before opening without the file: its title and
        // message are spoken by VoiceOver, Return or the Tab key reach its
        // buttons, and Escape cancels.
        .alert(
            awaited.map { LibraryFileWaitWording.confirmationTitle(for: $0.file) } ?? "",
            isPresented: $isConfirmingOpen,
            presenting: awaited
        ) { awaited in
            Button(
                LibraryFileWaitWording.confirmTitle(for: awaited.file),
                role: awaited.file == .index ? .destructive : nil
            ) {
                onOpenWithoutAwaitedFile?()
            }
            Button(LibraryFileWaitWording.cancel, role: .cancel) {}
        } message: { awaited in
            Text(LibraryFileWaitWording.confirmationMessage(for: awaited.file, in: awaited.provider))
        }
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
