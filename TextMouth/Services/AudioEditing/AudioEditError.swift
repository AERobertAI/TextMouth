import Foundation

/// Why an audio edit, a preview, or a render could not be made (FR04). Each
/// description is a sentence the editor can show and VoiceOver can read as
/// it stands: it names what happened and, where there is one, what to do.
enum AudioEditError: LocalizedError, Equatable, Sendable {
    /// The book is no longer in the library, or is not an audiobook kept in
    /// a package of its own.
    case bookNotInLibrary
    /// A path in the edit history would reach outside the book's package.
    case fileOutsidePackage
    /// An audio file the edits need could not be read as audio.
    case unreadableAudio
    /// An audio file the edits need is missing: named by its path inside
    /// the package.
    case missingAudio(String)
    /// The edit history is only in the cloud, so it was not read.
    case historyInCloud
    /// The edit history was written by a later TextMouth, in the layout
    /// numbered here, so this one leaves it alone.
    case historyFromNewerVersion(Int)
    /// The edit history could not be read, for the reason given; a copy of
    /// it was kept beside it.
    case historyUnusable(String)
    /// The edit does not fit the audio, for the reason given as a sentence.
    case invalidEdit(String)
    /// A filter or a gain change was asked for where nothing can render one.
    case processingUnavailable
    /// The book is open in a reader, which plays the file a render replaces.
    case bookIsOpen
    /// An audio file the edits need is only in the cloud, so it was not read.
    case audioInCloud
    /// The edits wait to be rendered from an original that is gone; only
    /// undoing or redoing them back to the audio as last rendered helps.
    case originalNeeded
    /// The audio could not be written, for the reason given, for the debug
    /// log: an AVFoundation error's domain and code, or the name and reason
    /// of the Objective-C exception it raised (`ObjCException.Raised.summary`).
    case renderFailed(String)
    /// MP3 was asked for, but neither the LAME built into TextMouth, which
    /// could not start, nor an installed ffmpeg it may use can write it.
    case mp3NeedsFFmpeg

    var errorDescription: String? {
        switch self {
        case .bookNotInLibrary:
            // Translators: Said when an audio edit can't proceed: the book was removed from the library, or is not an audiobook kept in a package of its own.
            return InterfaceText.line("audioEditError.bookNotInLibrary", "The book is no longer in the library.")
        case .fileOutsidePackage:
            // Translators: Said when an audio edit can't proceed: the book's saved edit history points at a file outside the book's own package.
            return InterfaceText.line("audioEditError.fileOutsidePackage", "The edit history names a file outside the book, so it isn't used.")
        case .unreadableAudio:
            // Translators: Said when an audio file that the edits need can't be read as audio.
            return InterfaceText.line("audioEditError.unreadableAudio", "The audio couldn't be read.")
        case .missingAudio(let path):
            // Translators: Said when an audio file that the edits need is missing. %@ is its path inside the book's package.
            return InterfaceText.line("audioEditError.missingAudio", "The audio file “\(path)” that the edits need is missing from the book.")
        case .historyInCloud:
            return SentenceWording.joined([
                // Translators: Said when the audio editor can't open a book: its edit history is only in the cloud. A second sentence says to try again once the book has downloaded.
                InterfaceText.line("audioEditError.historyInCloud.only", "The edit history is only in the cloud, not on this Mac yet."),
                // Translators: Ends a message saying a file of the book is only in the cloud and isn't on this Mac yet: what to do about it.
                InterfaceText.line("audioEditError.historyInCloud.downloaded", "Try again once the book has downloaded.")
            ])
        case .historyFromNewerVersion:
            // Translators: Said when the book's saved edit history was written by a later version of TextMouth than this one.
            return InterfaceText.line("audioEditError.historyFromNewerVersion", "A newer TextMouth edited this audio, so this version leaves its edits alone.")
        case .historyUnusable:
            // Translators: Said when the book's saved edit history can't be read. A copy of the unreadable file was kept in the book's package.
            return InterfaceText.line("audioEditError.historyUnusable", "The edit history couldn't be read. A copy was kept in the book's package.")
        case .invalidEdit(let reason):
            return reason
        case .processingUnavailable:
            // Translators: Said when a filter or a volume change is asked for where nothing can render one.
            return InterfaceText.line("audioEditError.processingUnavailable", "Filters can't be applied here.")
        case .bookIsOpen:
            // Translators: Said when saving the edited audio is refused because a reader has the book open and plays the file the save would replace.
            return InterfaceText.line("audioEditError.bookIsOpen", "The book is open in a reader. Close it, then save again.")
        case .audioInCloud:
            return SentenceWording.joined([
                // Translators: Said when an audio file that the edits need is only in the cloud. A second sentence says to download the book and try again.
                InterfaceText.line("audioEditError.audioInCloud.only", "The audio is only in the cloud, not on this Mac yet."),
                // Translators: Ends a message saying the book's audio is only in the cloud: what to do about it.
                InterfaceText.line("audioEditError.audioInCloud.download", "Download the book, then try again.")
            ])
        case .originalNeeded:
            return SentenceWording.joined([
                // Translators: Said when the edits wait to be rendered from an original audio that is gone. A second sentence says what helps.
                InterfaceText.line("audioEditError.originalNeeded.longer", "These edits need the original audio, which is no longer kept."),
                // Translators: Ends a message saying the edits need an original audio that is gone: only undoing or redoing back to the audio as last saved helps.
                InterfaceText.line("audioEditError.originalNeeded.saved", "Undo or redo back to the audio as last saved.")
            ])
        case .renderFailed:
            // Translators: Said when the edited audio could not be written, whatever the technical reason, which goes to the debug log.
            return InterfaceText.line("audioEditError.renderFailed", "The edited audio couldn't be written.")
        case .mp3NeedsFFmpeg:
            // Translators: Said when MP3 is asked for and neither TextMouth's built-in encoder nor an installed ffmpeg program can write it. "Storage settings" is the name of a settings tab.
            return InterfaceText.line("audioEditError.mp3NeedsFFmpeg", "MP3 can't be written: TextMouth's encoder couldn't start, and ffmpeg is missing or off in Storage settings.")
        }
    }

    /// The case's name alone, never its payload, for the debug log (which must
    /// not hold a file's name or path). Written out, not read from the value
    /// with `String(describing:)`, which would also print the payload.
    var caseName: String {
        switch self {
        case .bookNotInLibrary: return "bookNotInLibrary"
        case .fileOutsidePackage: return "fileOutsidePackage"
        case .unreadableAudio: return "unreadableAudio"
        case .missingAudio: return "missingAudio"
        case .historyInCloud: return "historyInCloud"
        case .historyFromNewerVersion: return "historyFromNewerVersion"
        case .historyUnusable: return "historyUnusable"
        case .invalidEdit: return "invalidEdit"
        case .processingUnavailable: return "processingUnavailable"
        case .bookIsOpen: return "bookIsOpen"
        case .audioInCloud: return "audioInCloud"
        case .originalNeeded: return "originalNeeded"
        case .renderFailed: return "renderFailed"
        case .mp3NeedsFFmpeg: return "mp3NeedsFFmpeg"
        }
    }
}
