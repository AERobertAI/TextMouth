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
        }
    }
}
