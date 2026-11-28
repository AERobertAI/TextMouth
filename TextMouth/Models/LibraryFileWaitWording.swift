import Foundation

/// The words of the Library Not Available screen when one of a cloud
/// library's two small files, its index or its identity file, did not
/// arrive beside the other while TextMouth waited for it (risk 5 of
/// LOCAL-FIRST-LIBRARY-RESEARCH-2026-11-13.md,
/// `DataDirectoryUnavailability.libraryFileNotArrived`): the reason, the
/// button that opens the library without the file, and the question that
/// button asks first. TextMouth never opens such a library as a fresh start
/// or gives it a new identity on its own; these words put the choice to the
/// listener. The screen, VoiceOver, a braille display, and the tests read
/// them from here.
enum LibraryFileWaitWording {
    /// The screen's reason, which VoiceOver announces after the heading:
    /// which file is here, which did not come from `provider`, what to check
    /// while it may still come, and the way to open the library without it.
    static func explanation(of file: LibraryFileAwaited, in provider: CloudProvider?) -> String {
        let service = DataDirectoryUnavailability.service(provider)
        // The file that is here, and the one that did not arrive, as one sentence.
        let arrival: String
        switch file {
        case .index:
            // Translators: First sentence of why the library can't open: its index file did not arrive from the cloud service. %1$@ is the index's file name, which stays as written; %2$@ is the cloud service's name, or "the cloud" when it is unknown.
            arrival = InterfaceText.line("libraryFileWait.explanation.index", "The library's identity file is on this Mac, but its index, \(file.fileName), hasn't arrived from \(service).")
        case .identity, .identityNotKnown:
            // Translators: First sentence of why the library can't open: its identity file did not arrive from the cloud service. %1$@ is the identity file's name, which stays as written; %2$@ is the cloud service's name, or "the cloud" when it is unknown.
            arrival = InterfaceText.line("libraryFileWait.explanation.identity", "The library's index is on this Mac, but its identity file, \(file.fileName), hasn't arrived from \(service).")
        }
        var sentences = [
            arrival,
            // Translators: Second sentence of why the library can't open: TextMouth waited for the missing file to arrive. "It" is the file named in the sentence before.
            InterfaceText.line("libraryFileWait.explanation.waited", "TextMouth waited for it."),
        ]
        // A Mac that knows no identity has none to restore, which it says.
        if file == .identityNotKnown {
            // Translators: A sentence of why the library can't open: this Mac has no record of the library's identity, so the identity file can't be restored from it.
            sentences.append(InterfaceText.line("libraryFileWait.explanation.identityRestore", "This Mac doesn't know the library's identity, so it can't restore it."))
        }
        sentences.append(DataDirectoryUnavailability.whatToCheck(provider))
        // Translators: Last sentence of why the library can't open, pointing to the button that opens it anyway. %@ is that button's name, without its ellipsis. "It" is the missing file.
        sentences.append(InterfaceText.line("libraryFileWait.explanation.choose", "If it is gone, choose \(openName(for: file))."))
        return SentenceWording.joined(sentences)
    }

    /// The screen's button that opens the library without `file`, after
    /// asking (`confirmationTitle(for:)`). Its title ends in an ellipsis,
    /// since it asks first.
    static func openTitle(for file: LibraryFileAwaited) -> String {
        switch file {
        case .index:
            // Translators: Button that opens the library without its index file, after asking. The ellipsis shows that a question follows.
            return InterfaceText.line("libraryFileWait.openTitle.index", "Open Without the Index…")
        case .identity:
            // Translators: Button that restores the library's identity file from what this Mac knows, after asking. The ellipsis shows that a question follows.
            return InterfaceText.line("libraryFileWait.openTitle.identity", "Restore Its Identity…")
        case .identityNotKnown:
            // Translators: Button that gives the library a new identity file, after asking. The ellipsis shows that a question follows.
            return InterfaceText.line("libraryFileWait.openTitle.identityNotKnown", "Give It a New Identity…")
        }
    }

    /// The button's name in a sentence: its title without the ellipsis.
    static func openName(for file: LibraryFileAwaited) -> String {
        openTitle(for: file).replacingOccurrences(of: "…", with: "")
    }

    /// What the button does, as VoiceOver's hint.
    static func openHint(for file: LibraryFileAwaited) -> String {
        switch file {
        case .index:
            // Translators: VoiceOver hint of the button that opens the library without its index file.
            return InterfaceText.line("libraryFileWait.openHint.index", "Asks first, then makes a new library index from the books in this folder and opens the library.")
        case .identity:
            // Translators: VoiceOver hint of the button that restores the library's identity file.
            return InterfaceText.line("libraryFileWait.openHint.identity", "Asks first, then writes the identity this Mac knows for the library and opens it.")
        case .identityNotKnown:
            // Translators: VoiceOver hint of the button that gives the library a new identity file.
            return InterfaceText.line("libraryFileWait.openHint.identityNotKnown", "Asks first, then gives the library a new identity and opens it.")
        }
    }

    /// The question the button asks first.
    static func confirmationTitle(for file: LibraryFileAwaited) -> String {
        switch file {
        case .index:
            // Translators: Title of the question asked before opening the library without its index file.
            return InterfaceText.line("libraryFileWait.confirmationTitle.index", "Open the library without its index?")
        case .identity:
            // Translators: Title of the question asked before restoring the library's identity file.
            return InterfaceText.line("libraryFileWait.confirmationTitle.identity", "Restore the library's identity?")
        case .identityNotKnown:
            // Translators: Title of the question asked before giving the library a new identity file.
            return InterfaceText.line("libraryFileWait.identityNotKnown", "Give the library a new identity?")
        }
    }

    /// What the question explains: what opening does, and what becomes of
    /// the file should it arrive from `provider` later.
    static func confirmationMessage(for file: LibraryFileAwaited, in provider: CloudProvider?) -> String {
        let service = DataDirectoryUnavailability.service(provider)
        switch file {
        case .index:
            return SentenceWording.joined([
                // Translators: First sentence of the question asked before opening the library without its index file.
                InterfaceText.line("libraryFileWait.confirmationMessage.index.makes", "TextMouth makes a new library index from the books in this folder."),
                // Translators: Second sentence of the question asked before opening the library without its index file: what the new index will not hold. "It" is the new index.
                InterfaceText.line("libraryFileWait.confirmation.index.listening", "The reading list, the folders' sorts and listening options, and any book whose files aren't in this folder yet won't be in it."),
                // Translators: Last sentence of the question asked before opening the library without its index file. %1$@ is the index file's name, which stays as written; %2$@ and %3$@ are the cloud service's name, or "the cloud" when it is unknown.
                InterfaceText.line("libraryFileWait.confirmation.index.arrives", "If \(file.fileName) arrives from \(service) later, \(service) may keep two copies of it."),
            ])
        case .identity:
            return SentenceWording.joined([
                // Translators: First sentence of the question asked before restoring the library's identity file. %@ is the identity file's name, which stays as written.
                InterfaceText.line("libraryFileWait.confirmation.identity.writes", "TextMouth writes \(file.fileName) with the identity this Mac knows for the library, and opens it."),
                // Translators: Last sentence of the question asked before restoring the library's identity file. %@ is the cloud service's name, or "the cloud" when it is unknown.
                InterfaceText.line("libraryFileWait.confirmation.identity.arrives", "If the file arrives from \(service) later, it names the same library."),
            ])
        case .identityNotKnown:
            return SentenceWording.joined([
                // Translators: First sentence of the question asked before giving the library a new identity file. %@ is the identity file's name, which stays as written.
                InterfaceText.line("libraryFileWait.identityNotKnown.writes", "TextMouth writes \(file.fileName) with a new identity for the library, and opens it."),
                // Translators: Last sentence of the question asked before giving the library a new identity file. %1$@ is the identity file's name, which stays as written; %2$@ and %3$@ are the cloud service's name, or "the cloud" when it is unknown.
                InterfaceText.line("libraryFileWait.identityNotKnown.disagree", "If the library's own \(file.fileName) arrives from \(service) later, \(service) may keep two copies of it, and this Mac and the other would disagree about which library this is."),
            ])
        }
    }

    /// The question's button that opens the library.
    static func confirmTitle(for file: LibraryFileAwaited) -> String {
        switch file {
        case .index:
            // Translators: Button of the question that opens the library without its index file: makes a new index and opens the library.
            return InterfaceText.line("libraryFileWait.confirmTitle.index", "Make a New Index")
        case .identity:
            // Translators: Button of the question that restores the library's identity file: restores it and opens the library.
            return InterfaceText.line("libraryFileWait.confirmTitle.identity", "Restore and Open")
        case .identityNotKnown:
            // Translators: Button of the question that gives the library a new identity file: gives it and opens the library.
            return InterfaceText.line("libraryFileWait.confirmTitle.identityNotKnown", "Give a New Identity")
        }
    }

    /// The question's button that leaves everything as it is.
    static var cancel: String {
        // Translators: Button that closes a question and changes nothing.
        InterfaceText.line("common.cancel", "Cancel")
    }
}
