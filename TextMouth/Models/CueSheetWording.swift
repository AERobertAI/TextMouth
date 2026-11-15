import Foundation

/// The words a cue sheet's import says (FMT24): the headings it makes for
/// tracks without a title, its refusals, and its notices. One type holds them
/// so a test pins every word, and the headings read the same on screen, aloud,
/// and in braille.
enum CueSheetWording {
    /// The heading of a track the sheet gives no title: "Track 3", by the
    /// number the sheet gives the track.
    static func untitledTrack(number: Int) -> String {
        "Track \(number)"
    }

    /// The heading of a track whose own performer is not the book's author:
    /// its title, then "by" and the performer ("Moonlight, by Ada Okafor"),
    /// as a compilation's tracks name their singers. A comma before "by" makes
    /// VoiceOver pause there, and braille shows it as written.
    static func trackHeading(title: String, performer: String) -> String {
        "\(title), by \(performer)"
    }

    /// The refusal of a cue sheet larger than TextMouth reads
    /// (`CueSheet.maximumByteCount`).
    static func tooLarge(fileName: String) -> String {
        "The cue sheet “\(fileName)” is too large to read."
    }

    /// The refusal of a cue sheet chosen on its own that places no track: no
    /// audio track of it has a start (an INDEX 01 line) in a file it names.
    static let noTracks = "It lists no audio track with a start that TextMouth can read."

    /// The refusal of a cue sheet chosen on its own whose tracks begin, or
    /// end, past the end of the audio it names.
    static let timesPastAudio = "Its tracks run past the end of the audio it names, so it was made for another copy of that audio."

    /// The heading of an Audacity label with no text (FMT06): "Label 4", by
    /// its place among the file's labels, from 1.
    static func untitledLabel(number: Int) -> String {
        "Label \(number)"
    }

    /// The kinds of file that give a folder's audio its headings.
    enum ListKind: Equatable, Sendable {
        /// A CUE sheet (FMT24).
        case cueSheet
        /// An Audacity label file (FMT06).
        case labelFile

        /// The kind as a notice names it.
        var name: String {
            switch self {
            case .cueSheet: return "cue sheet"
            case .labelFile: return "label file"
            }
        }

        /// What the kind's entries are called.
        var entries: String {
            switch self {
            case .cueSheet: return "tracks"
            case .labelFile: return "labels"
            }
        }
    }

    /// Why a folder's or archive's cue sheet or label file was not used.
    enum UnusedReason: Equatable, Sendable {
        /// It names none of the audio beside it (for a label file: no audio
        /// file has its stem, and there is not just one beside it).
        case namesNoAudio
        /// It could not be read (too large, or not readable as text).
        case unreadable
        /// Its tracks run past the end of the audio it names.
        case timesPastAudio
    }

    /// The notice of a folder's or archive's cue sheet or label file that
    /// was not used, so the tracks it would have arranged imported as they
    /// are.
    static func sheetUnused(_ name: String, kind: ListKind = .cueSheet, because reason: UnusedReason) -> String {
        switch reason {
        case .namesNoAudio where kind == .labelFile:
            return "The label file “\(name)” matches no audio file beside it by name, so its headings were not used."
        case .namesNoAudio:
            return "The \(kind.name) “\(name)” names none of the audio beside it, so its headings were not used."
        case .unreadable:
            return "TextMouth could not read the \(kind.name) “\(name)”, so its headings were not used."
        case .timesPastAudio:
            return "The \(kind.entries) of the \(kind.name) “\(name)” run past the end of its audio, so its headings were not used."
        }
    }
}
