import Foundation

/// Every word the spoken audio options of the Export dialog show or speak
/// (FMT43): the labels, values, and hints of the Format, From, and To
/// pop-ups and of the Rate and Pitch sliders, a heading as the pop-ups list
/// it, the line naming the voice, the line about Apple's licence, the words
/// an exported file's name is made of, and what the dialog says while an
/// export runs and when it ends. Each is defined once, here, so the dialog,
/// the options' view, and their state share it, the words on screen are the
/// words VoiceOver speaks, and a test pins each one exactly.
///
/// Every text is localized (FR34); a number inside a sentence is that
/// sentence's own plural string, or, for a limit that never varies (the
/// MP3's 255 chapters), a written number.
enum SpeechExportWording {
    // MARK: The Format

    /// The label of the pop-up that chooses the kind of audio file. Its items
    /// are the formats' names (`SpeechExportFormat.title`).
    static var formatLabel: String {
        String(localized: "Format",
               comment: "The label of the pop-up in the Export dialog's spoken audio options that chooses the kind of audio file.")
    }
    /// What the Format pop-up chooses, spoken after its label and value. An
    /// MP3's table of contents counts its chapters in one byte
    /// (`MP3Tag.maximumChapters`).
    static var formatHint: String {
        // The limit is a fixed number of the format, written without grouping.
        String(localized: "The kind of audio file. M4B is an audiobook; M4A and MP3 play in more apps. M4B and M4A have a chapter for each heading; an MP3, for each of the first \(String(MP3Tag.maximumChapters)).",
               comment: "The hint of the Format pop-up in the Export dialog's spoken audio options. M4B, M4A, and MP3 are audio file formats. %@ is the number of chapters an MP3 can have, 255.")
    }

    /// The line under the Format pop-up while MP3 is chosen for a range of
    /// more headings than an MP3 has chapters for, `headings` of them: what
    /// is lost, and what keeps it.
    static func mp3ChapterLimit(headings: Int) -> String {
        String(localized: "This range has \(headings) headings, and an MP3 has chapters for the first \(String(MP3Tag.maximumChapters)) only. Choose M4B to have a chapter for each of them.",
               comment: "The line under the Format pop-up in the Export dialog's spoken audio options while MP3 is chosen for a range with more headings than an MP3 has chapters. %1$lld is the number of headings in the range and %2$@ the number of chapters an MP3 can have, 255. M4B and MP3 are audio file formats.")
    }

    /// The sentence the Export dialog adds after an MP3 of `chapters`
    /// chapters is made, more than an MP3 has chapters for.
    static func mp3ChaptersKept(of chapters: Int) -> String {
        String(localized: "The MP3 has chapters for the first \(String(MP3Tag.maximumChapters)) of its \(chapters) headings; export it as M4B to have a chapter for each.",
               comment: "A sentence the Export dialog adds after it made an MP3 of more headings than an MP3 has chapters for. %1$@ is the number of chapters an MP3 can have, 255, and %2$lld the number of headings. M4B and MP3 are audio file formats.")
    }

    // MARK: The Range

    /// The label of the pop-up that chooses where the spoken audio begins.
    static var fromLabel: String {
        String(localized: "From",
               comment: "The label of the pop-up in the Export dialog's spoken audio options that chooses where the spoken audio begins.")
    }
    /// What the From pop-up chooses.
    static var fromHint: String {
        String(localized: "Where the spoken audio begins: the beginning of the book, or a heading.",
               comment: "The hint of the From pop-up in the Export dialog's spoken audio options.")
    }
    /// The From pop-up's first item: the book's beginning, with any text
    /// before its first heading.
    static var beginningOfBook: String {
        String(localized: "Beginning of the book",
               comment: "The first item of the From pop-up in the Export dialog's spoken audio options: the start of the book, with any text before its first heading.")
    }

    /// The label of the pop-up that chooses where the spoken audio ends.
    static var throughLabel: String {
        String(localized: "To",
               comment: "The label of the pop-up in the Export dialog's spoken audio options that chooses where the spoken audio ends.")
    }
    /// What the To pop-up chooses.
    static var throughHint: String {
        String(localized: "The heading whose section ends the spoken audio, with any headings under it, or the end of the book.",
               comment: "The hint of the To pop-up in the Export dialog's spoken audio options.")
    }
    /// The To pop-up's last item: the book's end.
    static var endOfBook: String {
        String(localized: "End of the book",
               comment: "The last item of the To pop-up in the Export dialog's spoken audio options: the end of the book.")
    }

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
    static var noHeadings: String {
        String(localized: "This book has no headings, so all of it is exported.",
               comment: "Shown in the Export dialog's spoken audio options in place of the From and To pop-ups when the book has no headings.")
    }

    /// Why Export refuses the folder chosen: it is the folder speech exports
    /// keep their spoken chapters in, or inside it, which TextMouth empties.
    static var destinationInKeptChapters: String {
        String(localized: "Export can't write into the folder where TextMouth keeps spoken chapters, since TextMouth empties it. Choose another folder.",
               comment: "Why the Export dialog refuses the folder chosen: it is the folder where TextMouth keeps the chapters of a spoken audio export, or inside it.")
    }

    /// What the dialog says under the checkbox, the first time it is checked,
    /// while the book's text is read for its headings.
    static var readingHeadings: String {
        String(localized: "Reading the book's headings…",
               comment: "Shown under the Text as spoken audio checkbox in the Export dialog while the book's text is read for its headings.")
    }

    /// What the dialog says under the checkbox when the book's text can't be
    /// read, so there is nothing to speak.
    static var unreadableText: String {
        String(localized: "This book's text can't be read, so it can't be spoken into an audio file.",
               comment: "Shown under the Text as spoken audio checkbox in the Export dialog when the book's text can't be read.")
    }

    // MARK: The Speed and the Pitch

    /// The label of the slider that sets how fast the voice speaks: "Speed",
    /// the word the reader and Settings use for the same words per minute.
    static var speedLabel: String {
        String(localized: "Speed",
               comment: "The label of the slider in the Export dialog's spoken audio options that sets how fast the voice speaks.")
    }
    /// The Speed slider's value, shown beside it and spoken as its value:
    /// "200 words per minute". The speed is one the options hold, so a
    /// finite number inside the speeds Settings offers.
    static func speedValue(_ wordsPerMinute: Double) -> String {
        String(localized: "\(Int(wordsPerMinute.rounded())) words per minute",
               comment: "The value of the Speed slider in the Export dialog's spoken audio options. %lld is the speed in words per minute.")
    }
    /// What the Speed slider sets.
    static var speedHint: String {
        String(localized: "How fast the voice speaks in the audio file. It starts at this book's speed.",
               comment: "The hint of the Speed slider in the Export dialog's spoken audio options.")
    }

    /// The label of the slider that sets how high the voice sounds.
    static var pitchLabel: String {
        String(localized: "Pitch",
               comment: "The label of the slider in the Export dialog's spoken audio options that sets how high the voice sounds.")
    }
    /// The Pitch slider's value, in the words the reader and Settings use
    /// for a pitch: "Normal (1.0x)", "1.5x".
    static func pitchValue(_ pitch: Double) -> String {
        SpeechService.pitchLabel(pitch)
    }
    /// What the Pitch slider sets.
    static var pitchHint: String {
        String(localized: "How high the voice sounds in the audio file. It starts at this book's pitch.",
               comment: "The hint of the Pitch slider in the Export dialog's spoken audio options.")
    }

    // MARK: The Voice and the Licence

    /// The line naming the voice the book is spoken with, "Voice: Moira";
    /// or, when no voice can speak it into a file, the export's own refusal
    /// saying why and what to do: no voice installed (`voice` nil), or a
    /// Personal Voice, which macOS never records to a file.
    static func voiceLine(_ voice: SpeechExportVoiceInfo?) -> String {
        guard let voice else { return sentence(for: .noVoice) }
        guard !voice.isPersonalVoice else { return sentence(for: .personalVoice(name: voice.name)) }
        return String(localized: "Voice: \(voice.name)",
                      comment: "The line in the Export dialog's spoken audio options naming the voice the book is spoken with. %@ is the voice's name.")
    }

    /// The line about the licence the Mac's voices come with (the user's
    /// answer to question 20 asked for it).
    static var licence: String {
        String(localized: "Speech made with the Mac's voices is for your personal, non-commercial use, under Apple's licence.",
               comment: "The line in the Export dialog's spoken audio options about the licence the Mac's voices come with.")
    }

    // MARK: A File's Name

    /// What a file of the whole book is called after the book's title:
    /// "Middlemarch - Audio".
    static var wholeBookName: String {
        String(localized: "Audio",
               comment: "Part of a spoken audio export's file name, after the book's title: the whole book, as in \"Middlemarch - Audio\".")
    }
    /// What the book's beginning is called in a file's name, as one end of
    /// its range: "Middlemarch - Beginning to Chapter 2".
    static var beginningName: String {
        String(localized: "Beginning",
               comment: "Part of a spoken audio export's file name: the beginning of the book as one end of the range, as in \"Middlemarch - Beginning to Chapter 2\".")
    }
    /// What the book's end is called in a file's name, as one end of its
    /// range: "Middlemarch - Chapter 2 to End".
    static var endName: String {
        String(localized: "End",
               comment: "Part of a spoken audio export's file name: the end of the book as one end of the range, as in \"Middlemarch - Chapter 2 to End\".")
    }

    /// An exported file's name, before it is made safe and given its
    /// extension: the book's part of the name, `stem`, then `part`, what of
    /// the book the file holds ("Middlemarch - Chapter 2").
    static func fileName(stem: String, part: String) -> String {
        "\(stem) - \(part)" // l10n: no (a file name's hyphen between the title and the part; both pieces are localized)
    }

    /// The part of a file's name for a range that runs from one end, `from`,
    /// to another, `through`, each a heading's words or the name of the
    /// book's beginning or end ("Chapter 1 to Chapter 3", "Beginning to
    /// Chapter 2").
    static func rangeName(from: String, through: String) -> String {
        String(localized: "\(from) to \(through)",
               comment: "Part of a spoken audio export's file name: a range of the book. %1$@ is where it begins and %2$@ where it ends, each a heading's words or the beginning or end of the book, as in \"Chapter 1 to Chapter 3\".")
    }

    // MARK: While an Export Runs, and When It Ends

    /// What the dialog's progress bar says, and VoiceOver reads, while a
    /// speech export runs: "Speaking chapter 3 of 12…", counting the chapter
    /// being spoken; "Encoding the audio file…"; nil once it has ended, when
    /// the dialog says what it says of any export.
    static func progress(_ progress: SpeechExportProgress) -> String? {
        switch progress {
        case .speaking(let done, let total, _):
            // Chapter numbers name places in the book, so they are written without grouping.
            return String(localized: "Speaking chapter \(String(min(done + 1, total))) of \(String(total))…",
                          comment: "The progress of a spoken audio export while it speaks the chapters. %1$@ is the number of the chapter being spoken and %2$@ the number of chapters, both written without digit grouping.")
        case .encoding:
            return String(localized: "Encoding the audio file…",
                          comment: "The progress of a spoken audio export once every chapter is spoken and the audio file is being made.")
        case .ended:
            return nil
        }
    }

    /// The Stop button's hint while a speech export runs: unlike the file
    /// other exports leave off making, its spoken chapters are kept, for as
    /// long as they are. They are kept until the next launch sweeps them
    /// (`SpeechExportStore.sweep`); a different speech export, of another
    /// book, range, voice, speed, or pitch, removes them as it opens the
    /// store; and a change to the book's voice, text, substitution rules, or
    /// pauses changes what the same range would speak, so it speaks every
    /// chapter again.
    static var stopHint: String {
        String(localized: "Stops the export. The chapters already spoken are kept, so exporting the same range at the same speed and pitch goes on from there, before TextMouth quits, a different export of spoken audio starts, or the book's voice, text, substitution rules, or pauses change.",
               comment: "The hint of the Stop button in the Export dialog while a spoken audio export runs.")
    }

    /// The sentence an export that ended without its file adds to what the
    /// dialog says, telling what it kept, how to use it, and for how long:
    /// `done` of its `total` chapters are kept (`SpeechExportProgress.ended`).
    /// Nil when none is.
    static func kept(done: Int, total: Int) -> String? {
        guard done > 0 else { return nil }
        guard done >= total else {
            // Chapter numbers name places in the book, so they are written without grouping.
            return String(localized: "Kept \(String(done)) of \(total) chapters: export the same range at the same speed and pitch to go on from chapter \(String(done + 1)), before TextMouth quits, a different export of spoken audio starts, or the book's voice, text, substitution rules, or pauses change.",
                          comment: "What the Export dialog says after a spoken audio export ended without its file and kept some of its chapters. %1$@ is how many chapters are kept, %2$lld how many there are, and %3$@ the number of the chapter to go on from, both written without digit grouping.")
        }
        return total == 1
            ? String(localized: "Kept the spoken chapter: export the same range at the same speed and pitch to make the audio file from it, before TextMouth quits, a different export of spoken audio starts, or the book's voice, text, substitution rules, or pauses change.",
                     comment: "What the Export dialog says after a spoken audio export ended without its file and kept its only chapter.")
            : String(localized: "Kept all \(total) spoken chapters: export the same range at the same speed and pitch to make the audio file from them, before TextMouth quits, a different export of spoken audio starts, or the book's voice, text, substitution rules, or pauses change.",
                     comment: "What the Export dialog says after a spoken audio export ended without its file and kept every one of its chapters. %lld is the number of chapters, more than one.")
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
