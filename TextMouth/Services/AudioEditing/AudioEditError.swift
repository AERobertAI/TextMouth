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
    /// The audio could not be written, for the reason given: an
    /// AVFoundation error's domain and code, for the debug log.
    case renderFailed(String)

    var errorDescription: String? {
        switch self {
        case .bookNotInLibrary:
            return "The book is no longer in the library."
        case .fileOutsidePackage:
            return "The book's edit history names a file outside the book, so TextMouth won't use it."
        case .unreadableAudio:
            return "The audio couldn't be read."
        case .missingAudio(let path):
            return "The audio file “\(path)” that the edits need is missing from the book."
        case .historyInCloud:
            return "The book's edit history is only in the cloud and isn't on this Mac yet. "
                + "Try again once the book has downloaded."
        case .historyFromNewerVersion:
            return "The book's audio was edited by a newer version of TextMouth, so this version leaves its edits alone."
        case .historyUnusable:
            return "The book's edit history couldn't be read. A copy of it was kept in the book's package."
        case .invalidEdit(let reason):
            return reason
        case .processingUnavailable:
            return "Filters can't be applied here."
        case .bookIsOpen:
            return "The book is open in a reader. Close it there, then save the edited audio again."
        case .audioInCloud:
            return "The book's audio is only in the cloud and isn't on this Mac yet. "
                + "Download the book, then try again."
        case .originalNeeded:
            return "These edits can only be made from the original audio, which is no longer kept. "
                + "Undo or redo back to the audio as last saved."
        case .renderFailed:
            return "The edited audio couldn't be written."
        }
    }
}
