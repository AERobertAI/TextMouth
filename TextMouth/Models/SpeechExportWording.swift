import Foundation

/// Every word the spoken audio options of the Export dialog show or speak
/// (FMT43): the labels, values, and hints of the Format, From, and To
/// pop-ups and of the Rate and Pitch sliders, a heading as the pop-ups list
/// it, the line naming the voice, the line about Apple's licence, and the
/// words an exported file's name is made of. Each is defined once, here, so
/// the options' view and state share it, the words on screen are the words
/// VoiceOver speaks, and a test pins each one exactly.
enum SpeechExportWording {
    // MARK: The Format

    /// The label of the pop-up that chooses the kind of audio file. Its items
    /// are the formats' names (`SpeechExportFormat.title`).
    static let formatLabel = "Format"
    /// What the Format pop-up chooses, spoken after its label and value.
    static let formatHint = "The kind of audio file. M4B is an audiobook; M4A and MP3 play in more apps. "
        + "Each has a chapter for each heading."

    // MARK: The Range

    /// The label of the pop-up that chooses where the spoken audio begins.
    static let fromLabel = "From"
    /// What the From pop-up chooses.
    static let fromHint = "Where the spoken audio begins: the beginning of the book, or a heading."
    /// The From pop-up's first item: the book's beginning, with any text
    /// before its first heading.
    static let beginningOfBook = "Beginning of the book"

    /// The label of the pop-up that chooses where the spoken audio ends.
    static let throughLabel = "To"
    /// What the To pop-up chooses.
    static let throughHint = "The heading whose section ends the spoken audio, with any headings under it, "
        + "or the end of the book."
    /// The To pop-up's last item: the book's end.
    static let endOfBook = "End of the book"

    /// `heading` as the From and To pop-ups list it, in the words the
    /// headings panel speaks it with: its text on one line, then its level,
    /// after "Skipped, " when the listener skips it ("Chapter 3 - level 1",
    /// "Skipped, Notes - level 2").
    static func headingItem(_ heading: Heading, isSkipped: Bool) -> String {
        HeadingNavigatorView.accessibilityDescription(
            text: oneLine(heading.text),
            level: heading.level,
            isSkipped: isSkipped
        )
    }

    /// What the options say in place of the From and To pop-ups when the
    /// book has no headings to choose.
    static let noHeadings = "This book has no headings, so all of it is exported."

    // MARK: The Speed and the Pitch

    /// The label of the slider that sets how fast the voice speaks.
    static let rateLabel = "Rate"
    /// The Rate slider's value, shown beside it and spoken as its value:
    /// "200 words per minute". The speed is one the options hold, so a
    /// finite number inside the speeds Settings offers.
    static func rateValue(_ wordsPerMinute: Double) -> String {
        "\(Int(wordsPerMinute.rounded())) words per minute"
    }
    /// What the Rate slider sets.
    static let rateHint = "How fast the voice speaks in the audio file. It starts at this book's speed."

    /// The label of the slider that sets how high the voice sounds.
    static let pitchLabel = "Pitch"
    /// The Pitch slider's value, in the words the reader and Settings use
    /// for a pitch: "Normal (1.0x)", "1.5x".
    static func pitchValue(_ pitch: Double) -> String {
        SpeechService.pitchLabel(pitch)
    }
    /// What the Pitch slider sets.
    static let pitchHint = "How high the voice sounds in the audio file. It starts at this book's pitch."

    // MARK: The Voice and the Licence

    /// The line naming the voice the book is spoken with, "Voice: Moira";
    /// or, when no voice can speak it into a file, the export's own refusal
    /// saying why and what to do: no voice installed (`voice` nil), or a
    /// Personal Voice, which macOS never records to a file.
    static func voiceLine(_ voice: SpeechExportVoiceInfo?) -> String {
        guard let voice else { return sentence(for: .noVoice) }
        guard !voice.isPersonalVoice else { return sentence(for: .personalVoice(name: voice.name)) }
        return "Voice: \(voice.name)"
    }

    /// The line about the licence the Mac's voices come with (the user's
    /// answer to question 20 asked for it).
    static let licence = "Speech made with the Mac's voices is for your personal, non-commercial use, "
        + "under Apple's licence."

    // MARK: The Options as a Whole

    /// The accessibility label of the group holding the options, which
    /// VoiceOver speaks on entering it.
    static let optionsLabel = "Spoken audio options"

    // MARK: A File's Name

    /// What a file of the whole book is called after the book's title:
    /// "Middlemarch - Audio".
    static let wholeBookName = "Audio"
    /// What the book's beginning is called in a file's name, as one end of
    /// its range: "Middlemarch - Beginning to Chapter 2".
    static let beginningName = "Beginning"
    /// What the book's end is called in a file's name, as one end of its
    /// range: "Middlemarch - Chapter 2 to End".
    static let endName = "End"

    /// An exported file's name, before it is made safe and given its
    /// extension: the book's part of the name, `stem`, then `part`, what of
    /// the book the file holds ("Middlemarch - Chapter 2").
    static func fileName(stem: String, part: String) -> String {
        "\(stem) - \(part)"
    }

    /// The part of a file's name for a range that runs from one end, `from`,
    /// to another, `through`, each a heading's words or the name of the
    /// book's beginning or end ("Chapter 1 to Chapter 3", "Beginning to
    /// Chapter 2").
    static func rangeName(from: String, through: String) -> String {
        "\(from) to \(through)"
    }

    // MARK: Text on One Line

    /// `text` on one line, as the pop-ups list a heading and a file's name
    /// holds it: each run of white space, line breaks included, made one
    /// space, and none left at either end. Empty for text of white space
    /// alone.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The sentence of a refusal, as the export would show it.
    private static func sentence(for refusal: SpeechExportError) -> String {
        refusal.errorDescription ?? ""
    }
}
