import Foundation

/// Why a speech export (FMT43) could not speak a book into a file, in the
/// words the Export dialog shows and VoiceOver speaks. Each is found before
/// anything is spoken, and each says what the listener can do about it.
enum SpeechExportError: LocalizedError, Equatable {
    /// The voice the book is read with is a Personal Voice, named `name`,
    /// which macOS speaks aloud but never into a file.
    case personalVoice(name: String)
    /// No voice is installed to speak the book: neither the book's own nor
    /// the global one, nor the system's voice for US English.
    case noVoice
    /// A disk lacks room for the export: the spoken chapters kept on this
    /// Mac, the exported file, or both, which need about `needed` bytes on
    /// it beyond the room TextMouth always leaves free.
    case notEnoughSpace(needed: Int64)
    /// Another book is being exported as spoken audio; one export runs at a
    /// time (`SpeechExportStore.claim()`).
    case busy
    /// The part of the book chosen to export, the whole book or a range of
    /// its headings, has no words to speak.
    case nothingToSpeak
    /// A heading the Export dialog's range names is no longer in the book:
    /// the book's headings changed after the dialog opened.
    case headingsChanged

    var errorDescription: String? {
        switch self {
        case .personalVoice(let name):
            return "“\(name)” is a Personal Voice, which macOS can't record to a file. "
                + "Choose another voice for this book with the Voice button in its reader, then export again."
        case .noVoice:
            return "No voice is installed to speak it. "
                + "Add a voice in System Settings, Accessibility, Spoken Content, then export again."
        case .notEnoughSpace(let needed):
            return "There isn't room on the disk for it: it needs about \(Self.size(needed)), "
                + "and TextMouth keeps \(Self.size(ArchiveLimits.standard.freeSpaceReserve)) free. "
                + "Free some space, then export again."
        case .busy:
            return "Another book is being exported as spoken audio. Export this one once it has finished."
        case .nothingToSpeak:
            return "The part of the book chosen has no words to speak."
        case .headingsChanged:
            return "The book's headings changed after the Export dialog opened. "
                + "Close it, open it again, and choose the range again."
        }
    }

    /// `bytes` as the Finder shows a file's size ("1 GB"), in the
    /// listener's own language.
    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
