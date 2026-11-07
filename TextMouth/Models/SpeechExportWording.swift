import Foundation

/// Every word the spoken audio options of the Export dialog show or speak
/// (FMT43): the labels, values, and hints of the Format, From, and To
/// pop-ups and of the Rate and Pitch sliders, a heading as the pop-ups list
/// it, the line naming the voice, the line about Apple's licence, the words
/// an exported file's name is made of, and what the dialog says while an
/// export runs and when it ends. Each is defined once, here, so the dialog,
/// the options' view, and their state share it, the words on screen are the
/// words VoiceOver speaks, and a test pins each one exactly.
enum SpeechExportWording {
    // MARK: The Format

    /// The label of the pop-up that chooses the kind of audio file. Its items
    /// are the formats' names (`SpeechExportFormat.title`).
    static let formatLabel = "Format"
    /// What the Format pop-up chooses, spoken after its label and value. An
    /// MP3's table of contents counts its chapters in one byte
    /// (`MP3Tag.maximumChapters`).
    static let formatHint = "The kind of audio file. M4B is an audiobook; M4A and MP3 play in more apps. "
        + "M4B and M4A have a chapter for each heading; an MP3, for each of the first \(MP3Tag.maximumChapters)."

    /// The line under the Format pop-up while MP3 is chosen for a range of
    /// more headings than an MP3 has chapters for, `headings` of them: what
    /// is lost, and what keeps it.
    static func mp3ChapterLimit(headings: Int) -> String {
        "This range has \(headings.formatted()) headings, and an MP3 has chapters for the first "
            + "\(MP3Tag.maximumChapters) only. Choose M4B to have a chapter for each of them."
    }

    /// The sentence the Export dialog adds after an MP3 of `chapters`
    /// chapters is made, more than an MP3 has chapters for.
    static func mp3ChaptersKept(of chapters: Int) -> String {
        "The MP3 has chapters for the first \(MP3Tag.maximumChapters) of its \(chapters.formatted()) headings; "
            + "export it as M4B to have a chapter for each."
    }

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

    /// The label of the slider that sets how fast the voice speaks: "Speed",
    /// the word the reader and Settings use for the same words per minute.
    static let speedLabel = "Speed"
    /// The Speed slider's value, shown beside it and spoken as its value:
    /// "200 words per minute". The speed is one the options hold, so a
    /// finite number inside the speeds Settings offers.
    static func speedValue(_ wordsPerMinute: Double) -> String {
        "\(Int(wordsPerMinute.rounded())) words per minute"
    }
    /// What the Speed slider sets.
    static let speedHint = "How fast the voice speaks in the audio file. It starts at this book's speed."

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

    // MARK: While an Export Runs, and When It Ends

    /// What the dialog's progress bar says, and VoiceOver reads, while a
    /// speech export runs: "Speaking chapter 3 of 12…", counting the chapter
    /// being spoken; "Encoding the audio file…"; nil once it has ended, when
    /// the dialog says what it says of any export.
    static func progress(_ progress: SpeechExportProgress) -> String? {
        switch progress {
        case .speaking(let done, let total, _):
            return "Speaking chapter \(min(done + 1, total)) of \(total)…"
        case .encoding:
            return "Encoding the audio file…"
        case .ended:
            return nil
        }
    }

    /// Until when spoken chapters are kept for the same export to go on from
    /// them: the next launch sweeps them (`SpeechExportStore.sweep`); a
    /// different speech export, of another book, range, voice, speed, or
    /// pitch, removes them as it opens the store; and a change to the book's
    /// voice, text, substitution rules, or pauses changes what the same
    /// range would speak, so it speaks every chapter again.
    private static let keptUntil = "before TextMouth quits, a different export of spoken audio starts, "
        + "or the book's voice, text, substitution rules, or pauses change"

    /// The Stop button's hint while a speech export runs: unlike the file
    /// other exports leave off making, its spoken chapters are kept, for as
    /// long as they are.
    static let stopHint = "Stops the export. The chapters already spoken are kept, so exporting the same range "
        + "at the same speed and pitch goes on from there, \(keptUntil)."

    /// The sentence an export that ended without its file adds to what the
    /// dialog says, telling what it kept, how to use it, and for how long:
    /// `done` of its `total` chapters are kept (`SpeechExportProgress.ended`).
    /// Nil when none is.
    static func kept(done: Int, total: Int) -> String? {
        guard done > 0 else { return nil }
        let again = "export the same range at the same speed and pitch"
        guard done >= total else {
            return "Kept \(done) of \(total) chapters: \(again) to go on from chapter \(done + 1), \(keptUntil)."
        }
        return total == 1
            ? "Kept the spoken chapter: \(again) to make the audio file from it, \(keptUntil)."
            : "Kept all \(total) spoken chapters: \(again) to make the audio file from them, \(keptUntil)."
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
