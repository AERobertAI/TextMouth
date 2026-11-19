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
            return String(localized: "The book is no longer in the library.",
                          comment: "Said when an audio edit can't proceed: the book was removed from the library, or is not an audiobook kept in a package of its own.")
        case .fileOutsidePackage:
            return String(localized: "The edit history names a file outside the book, so it isn't used.",
                          comment: "Said when an audio edit can't proceed: the book's saved edit history points at a file outside the book's own package.")
        case .unreadableAudio:
            return String(localized: "The audio couldn't be read.",
                          comment: "Said when an audio file that the edits need can't be read as audio.")
        case .missingAudio(let path):
            return String(localized: "The audio file “\(path)” that the edits need is missing from the book.",
                          comment: "Said when an audio file that the edits need is missing. %@ is its path inside the book's package.")
        case .historyInCloud:
            return SentenceWording.joined([
                String(localized: "The edit history is only in the cloud, not on this Mac yet.",
                       comment: "Said when the audio editor can't open a book: its edit history is only in the cloud. A second sentence says to try again once the book has downloaded."),
                String(localized: "Try again once the book has downloaded.",
                       comment: "Ends a message saying a file of the book is only in the cloud and isn't on this Mac yet: what to do about it.")
            ])
        case .historyFromNewerVersion:
            return String(localized: "A newer TextMouth edited this audio, so this version leaves its edits alone.",
                          comment: "Said when the book's saved edit history was written by a later version of TextMouth than this one.")
        case .historyUnusable:
            return String(localized: "The edit history couldn't be read. A copy was kept in the book's package.",
                          comment: "Said when the book's saved edit history can't be read. A copy of the unreadable file was kept in the book's package.")
        case .invalidEdit(let reason):
            return reason
        case .processingUnavailable:
            return String(localized: "Filters can't be applied here.",
                          comment: "Said when a filter or a volume change is asked for where nothing can render one.")
        case .bookIsOpen:
            return String(localized: "The book is open in a reader. Close it, then save again.",
                          comment: "Said when saving the edited audio is refused because a reader has the book open and plays the file the save would replace.")
        case .audioInCloud:
            return SentenceWording.joined([
                String(localized: "The audio is only in the cloud, not on this Mac yet.",
                       comment: "Said when an audio file that the edits need is only in the cloud. A second sentence says to download the book and try again."),
                String(localized: "Download the book, then try again.",
                       comment: "Ends a message saying the book's audio is only in the cloud: what to do about it.")
            ])
        case .originalNeeded:
            return SentenceWording.joined([
                String(localized: "These edits need the original audio, which is no longer kept.",
                       comment: "Said when the edits wait to be rendered from an original audio that is gone. A second sentence says what helps."),
                String(localized: "Undo or redo back to the audio as last saved.",
                       comment: "Ends a message saying the edits need an original audio that is gone: only undoing or redoing back to the audio as last saved helps.")
            ])
        case .renderFailed:
            return String(localized: "The edited audio couldn't be written.",
                          comment: "Said when the edited audio could not be written, whatever the technical reason, which goes to the debug log.")
        case .mp3NeedsFFmpeg:
            return String(localized: "MP3 can't be written: TextMouth's encoder couldn't start, and ffmpeg is missing or off in Storage settings.",
                          comment: "Said when MP3 is asked for and neither TextMouth's built-in encoder nor an installed ffmpeg program can write it. \"Storage settings\" is the name of a settings tab.")
        }
    }
}
