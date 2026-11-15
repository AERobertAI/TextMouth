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
    /// What `file` is, as a sentence names it: "its index, library.json".
    static func naming(_ file: LibraryFileAwaited) -> String {
        switch file {
        case .index: return "its index, \(file.fileName)"
        case .identity: return "its identity file, \(file.fileName)"
        }
    }

    /// The screen's reason, which VoiceOver announces after the heading:
    /// which file is here, which did not come from `provider`, what to check
    /// while it may still come, and the way to open the library without it.
    static func explanation(of file: LibraryFileAwaited, in provider: CloudProvider?) -> String {
        let service = DataDirectoryUnavailability.service(provider)
        let here: String
        switch file {
        case .index: here = "The library's identity file is on this Mac"
        case .identity: here = "The library's index is on this Mac"
        }
        return "\(here), but \(naming(file)), hasn't arrived from \(service). TextMouth waited for it. "
            + DataDirectoryUnavailability.whatToCheck(provider)
            + " If it is gone, choose \(openName(for: file))."
    }

    /// The screen's button that opens the library without `file`, after
    /// asking (`confirmationTitle(for:)`). Its title ends in an ellipsis,
    /// since it asks first.
    static func openTitle(for file: LibraryFileAwaited) -> String {
        switch file {
        case .index: return "Open Without the Index…"
        case .identity: return "Restore Its Identity…"
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
            return "Asks first, then makes a new library index from the books in this folder and opens the library."
        case .identity:
            return "Asks first, then writes the identity this Mac knows for the library and opens it."
        }
    }

    /// The question the button asks first.
    static func confirmationTitle(for file: LibraryFileAwaited) -> String {
        switch file {
        case .index: return "Open the library without its index?"
        case .identity: return "Restore the library's identity?"
        }
    }

    /// What the question explains: what opening does, and what becomes of
    /// the file should it arrive from `provider` later.
    static func confirmationMessage(for file: LibraryFileAwaited, in provider: CloudProvider?) -> String {
        let service = DataDirectoryUnavailability.service(provider)
        switch file {
        case .index:
            return "TextMouth makes a new library index from the books in this folder. The reading list, the "
                + "folders' sorts and listening options, and any book whose files aren't in this folder yet won't "
                + "be in it. If \(file.fileName) arrives from \(service) later, \(service) may keep two copies of it."
        case .identity:
            return "TextMouth writes \(file.fileName) with the identity this Mac knows for the library, and opens "
                + "it. If the file arrives from \(service) later, it names the same library."
        }
    }

    /// The question's button that opens the library.
    static func confirmTitle(for file: LibraryFileAwaited) -> String {
        switch file {
        case .index: return "Make a New Index"
        case .identity: return "Restore and Open"
        }
    }

    /// The question's button that leaves everything as it is.
    static let cancel = "Cancel"
}
