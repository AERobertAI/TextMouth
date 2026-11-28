import Foundation

/// The words a cue sheet's import says (FMT24): the headings it makes for
/// tracks without a title, its refusals, and its notices. One type holds them
/// so a test pins every word, and the headings read the same on screen, aloud,
/// and in braille.
enum CueSheetWording {
    /// The heading of a track the sheet gives no title: "Track 3", by the
    /// number the sheet gives the track.
    static func untitledTrack(number: Int) -> String {
        // Translators: Heading of a track that a cue sheet gives no title, made at import. %@ is the track's number from the sheet, an identifier written without digit grouping.
        InterfaceText.line("cueSheet.untitledTrack", "Track \(String(number))")
    }

    /// The heading of a track whose own performer is not the book's author:
    /// its title, then "by" and the performer ("Moonlight, by Ada Okafor"),
    /// as a compilation's tracks name their singers. A comma before "by" makes
    /// VoiceOver pause there, and braille shows it as written.
    static func trackHeading(title: String, performer: String) -> String {
        // Translators: Heading of a track whose performer is not the book's author, made at import: the title, a comma, then "by" and the performer. %1$@ is the track's title and %2$@ the performer. The comma makes VoiceOver pause.
        InterfaceText.line("common.valueCommaByValue", "\(title), by \(performer)")
    }

    /// The refusal of a cue sheet larger than TextMouth reads
    /// (`CueSheet.maximumByteCount`).
    static func tooLarge(fileName: String) -> String {
        // Translators: Refusal of a cue sheet that is larger than TextMouth reads. %@ is the cue sheet's file name.
        InterfaceText.line("cueSheet.tooLarge", "The cue sheet “\(fileName)” is too large to read.")
    }

    /// The refusal of a cue sheet chosen on its own that places no track: no
    /// audio track of it has a start (an INDEX 01 line) in a file it names.
    static var noTracks: String {
        // Translators: Refusal of a cue sheet chosen on its own that places no track. "It" is the cue sheet. Follows the sentence naming the file.
        InterfaceText.line("cueSheet.noTracks", "It lists no audio track with a start that TextMouth can read.")
    }

    /// The refusal of a cue sheet chosen on its own whose tracks begin, or
    /// end, past the end of the audio it names.
    static var timesPastAudio: String {
        // Translators: Refusal of a cue sheet chosen on its own whose tracks begin or end past the end of the audio it names. "Its" and "it" are the cue sheet.
        InterfaceText.line("cueSheet.timesPastAudio", "Its tracks run past the end of the audio it names, so it was made for another copy of that audio.")
    }

    /// The heading of an Audacity label with no text (FMT06): "Label 4", by
    /// its place among the file's labels, from 1.
    static func untitledLabel(number: Int) -> String {
        // Translators: Heading made at import for an Audacity label that has no text. %@ is the label's place among the file's labels, from 1, an identifier written without digit grouping.
        InterfaceText.line("cueSheet.untitledLabel", "Label \(String(number))")
    }

    /// The kinds of file that give a folder's audio its headings.
    enum ListKind: Equatable, Sendable {
        /// A CUE sheet (FMT24).
        case cueSheet
        /// An Audacity label file (FMT06).
        case labelFile

        /// The kind as a skipped entry's reason names it, inside the English
        /// reasons of `M3UPlaylist.SkipReason.words(listedIn:)`, which a
        /// parser words and stays English (question 3).
        var name: String {
            switch self {
            case .cueSheet: return "cue sheet" // l10n: no (inside M3UPlaylist's English skip reasons, which a parser words)
            case .labelFile: return "label file" // l10n: no (inside M3UPlaylist's English skip reasons, which a parser words)
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

    /// The notice of a folder's or archive's tracks imported without the
    /// headings of the cue sheets and label files `names` (their paths from
    /// the folder) gave, because the book's reading found one of those
    /// headings past the end of its audio (a converted file a little shorter
    /// than its source, or one the import could not measure first).
    static func headingsDidNotFit(_ names: [String]) -> String {
        let listed = CountWording.list(names.map { "“\($0)”" })
        // Translators: Notice after an import of tracks that came without the headings of some cue sheets and label files, because a heading lay past the end of the audio. %@ is the files' names in curly quotes, listed as a sentence lists them.
        return InterfaceText.line("cueSheet.headingsDidNotFit", "The headings from \(listed) run past the end of the audio, so the tracks were imported without them.")
    }

    /// The notice of a folder's or archive's cue sheet or label file that
    /// was not used, so the tracks it would have arranged imported as they
    /// are.
    static func sheetUnused(_ name: String, kind: ListKind = .cueSheet, because reason: UnusedReason) -> String {
        switch (kind, reason) {
        case (.labelFile, .namesNoAudio):
            // Translators: Notice that an Audacity label file of an imported folder or archive was not used, because no audio file beside it has its name. %@ is the label file's name.
            return InterfaceText.line("cueSheet.sheetUnused.matches", "The label file “\(name)” matches no audio file beside it by name, so its headings were not used.")
        case (.cueSheet, .namesNoAudio):
            // Translators: Notice that a cue sheet of an imported folder or archive was not used, because it names none of the audio beside it. %@ is the cue sheet's name.
            return InterfaceText.line("cueSheet.sheetUnused.names", "The cue sheet “\(name)” names none of the audio beside it, so its headings were not used.")
        case (.labelFile, .unreadable):
            // Translators: Notice that an Audacity label file of an imported folder or archive was not used, because it could not be read. %@ is the label file's name.
            return InterfaceText.line("cueSheet.sheetUnused.readLabel", "TextMouth could not read the label file “\(name)”, so its headings were not used.")
        case (.cueSheet, .unreadable):
            // Translators: Notice that a cue sheet of an imported folder or archive was not used, because it could not be read. %@ is the cue sheet's name.
            return InterfaceText.line("cueSheet.sheetUnused.readHeadings", "TextMouth could not read the cue sheet “\(name)”, so its headings were not used.")
        case (.labelFile, .timesPastAudio):
            // Translators: Notice that an Audacity label file of an imported folder or archive was not used, because its labels lie past the end of its audio. %@ is the label file's name.
            return InterfaceText.line("cueSheet.sheetUnused.labels", "The labels of the label file “\(name)” run past the end of its audio, so its headings were not used.")
        case (.cueSheet, .timesPastAudio):
            // Translators: Notice that a cue sheet of an imported folder or archive was not used, because its tracks lie past the end of its audio. %@ is the cue sheet's name.
            return InterfaceText.line("cueSheet.sheetUnused.tracks", "The tracks of the cue sheet “\(name)” run past the end of its audio, so its headings were not used.")
        }
    }
}
