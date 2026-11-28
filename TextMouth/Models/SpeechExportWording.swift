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
        // Translators: The label of the pop-up in the Export dialog's spoken audio options that chooses the kind of audio file.
        InterfaceText.line("common.format", "Format")
    }
    /// What the Format pop-up chooses, spoken after its label and value. An
    /// MP3's table of contents counts its chapters in one byte
    /// (`MP3Tag.maximumChapters`).
    static var formatHint: String {
        // The limit is a fixed number of the format, written without grouping.
        // Translators: The hint of the Format pop-up in the Export dialog's spoken audio options. M4B, M4A, and MP3 are audio file formats. %@ is the number of chapters an MP3 can have, 255.
        InterfaceText.line("speechExport.formatHint", "Chooses the file format. M4B is an audiobook; M4A and MP3 play in more apps. M4B and M4A have a chapter for each heading; an MP3, for the first \(String(MP3Tag.maximumChapters)).")
    }

    /// The line under the Format pop-up while MP3 is chosen for a range of
    /// more headings than an MP3 has chapters for, `headings` of them: what
    /// is lost, and what keeps it.
    static func mp3ChapterLimit(headings: Int) -> String {
        // Translators: The line under the Format pop-up in the Export dialog's spoken audio options while MP3 is chosen for a range with more headings than an MP3 has chapters. %1$lld is the number of headings in the range and %2$@ the number of chapters an MP3 can have, 255. M4B and MP3 are audio file formats.
        InterfaceText.line("speechExport.mp3ChapterLimit", "This range has \(number: headings) headings, but an MP3 has chapters for the first \(String(MP3Tag.maximumChapters)) only. Choose M4B for a chapter for each.")
    }

    /// The sentence the Export dialog adds after an MP3 of `chapters`
    /// chapters is made, more than an MP3 has chapters for.
    static func mp3ChaptersKept(of chapters: Int) -> String {
        // Translators: A sentence the Export dialog adds after it made an MP3 of more headings than an MP3 has chapters for. %1$@ is the number of chapters an MP3 can have, 255, and %2$lld the number of headings. M4B and MP3 are audio file formats.
        InterfaceText.line("speechExport.mp3ChaptersKept", "The MP3 has chapters for the first \(String(MP3Tag.maximumChapters)) of its \(number: chapters) headings; export as M4B for a chapter for each.")
    }

    // MARK: The Range

    /// The label of the pop-up that chooses where the spoken audio begins.
    static var fromLabel: String {
        // Translators: The label of the pop-up in the Export dialog's spoken audio options that chooses where the spoken audio begins.
        InterfaceText.line("speechExport.fromLabel", "From")
    }
    /// What the From pop-up chooses.
    static var fromHint: String {
        // Translators: The hint of the From pop-up in the Export dialog's spoken audio options.
        InterfaceText.line("speechExport.fromHint", "Where the audio begins: the book's beginning, or a heading.")
    }
    /// The From pop-up's first item: the book's beginning, with any text
    /// before its first heading.
    static var beginningOfBook: String {
        // Translators: The first item of the From pop-up in the Export dialog's spoken audio options: the start of the book, with any text before its first heading.
        InterfaceText.line("speechExport.beginningOfBook", "Beginning of the book")
    }

    /// The label of the pop-up that chooses where the spoken audio ends.
    static var throughLabel: String {
        // Translators: The label of the pop-up in the Export dialog's spoken audio options that chooses where the spoken audio ends.
        InterfaceText.line("speechExport.throughLabel", "To")
    }
    /// What the To pop-up chooses.
    static var throughHint: String {
        // Translators: The hint of the To pop-up in the Export dialog's spoken audio options.
        InterfaceText.line("speechExport.throughHint", "The heading whose section ends the audio, with its subheadings, or the end of the book.")
    }
    /// The To pop-up's last item: the book's end.
    static var endOfBook: String {
        // Translators: The last item of the To pop-up in the Export dialog's spoken audio options: the end of the book.
        InterfaceText.line("speechExport.endOfBook", "End of the book")
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
        // Translators: Shown in the Export dialog's spoken audio options in place of the From and To pop-ups when the book has no headings.
        InterfaceText.line("speechExport.noHeadings", "This book has no headings, so all of it is exported.")
    }

    /// Why Export refuses the folder chosen: it is the folder speech exports
    /// keep their spoken chapters in, or inside it, which TextMouth empties.
    static var destinationInKeptChapters: String {
        // Translators: Why the Export dialog refuses the folder chosen: it is the folder where TextMouth keeps the chapters of a spoken audio export, or inside it.
        InterfaceText.line("speechExport.destinationInKeptChapters", "Export can't write into the folder where TextMouth keeps spoken chapters, which it empties. Choose another folder.")
    }

    /// What the dialog says under the checkbox, the first time it is checked,
    /// while the book's text is read for its headings.
    static var readingHeadings: String {
        // Translators: Shown under the Text as spoken audio checkbox in the Export dialog while the book's text is read for its headings.
        InterfaceText.line("speechExport.readingHeadings", "Reading the book's headings…")
    }

    /// What the dialog says under the checkbox when the book's text can't be
    /// read, so there is nothing to speak.
    static var unreadableText: String {
        // Translators: Shown under the Text as spoken audio checkbox in the Export dialog when the book's text can't be read.
        InterfaceText.line("speechExport.unreadableText", "This book's text can't be read, so it can't be spoken into an audio file.")
    }

    // MARK: The Speed and the Pitch

    /// The label of the slider that sets how fast the voice speaks: "Speed",
    /// the word the reader and Settings use for the same words per minute.
    static var speedLabel: String {
        // Translators: The label of the slider in the Export dialog's spoken audio options that sets how fast the voice speaks.
        InterfaceText.line("common.speed", "Speed")
    }
    /// The Speed slider's value, shown beside it and spoken as its value:
    /// "200 words per minute". The speed is one the options hold, so a
    /// finite number inside the speeds Settings offers.
    static func speedValue(_ wordsPerMinute: Double) -> String {
        // Translators: The value of the Speed slider in the Export dialog's spoken audio options. %lld is the speed in words per minute.
        InterfaceText.line("common.countWordsPerMinute", "\(number: Int(wordsPerMinute.rounded())) words per minute")
    }
    /// What the Speed slider sets.
    static var speedHint: String {
        // Translators: The hint of the Speed slider in the Export dialog's spoken audio options.
        InterfaceText.line("speechExport.speedHint", "How fast the voice speaks in the file. It starts at the book's speed.")
    }

    /// The label of the slider that sets how high the voice sounds.
    static var pitchLabel: String {
        // Translators: The label of the slider in the Export dialog's spoken audio options that sets how high the voice sounds.
        InterfaceText.line("common.pitch", "Pitch")
    }
    /// The Pitch slider's value, in the words the reader and Settings use
    /// for a pitch: "Normal (1.0x)", "1.5x".
    static func pitchValue(_ pitch: Double) -> String {
        SpeechService.pitchLabel(pitch)
    }
    /// What the Pitch slider sets.
    static var pitchHint: String {
        // Translators: The hint of the Pitch slider in the Export dialog's spoken audio options.
        InterfaceText.line("speechExport.pitchHint", "How high the voice sounds in the file. It starts at the book's pitch.")
    }

    // MARK: The Voice and the Licence

    /// The line naming the voice the book is spoken with, "Voice: Moira";
    /// or, when no voice can speak it into a file, the export's own refusal
    /// saying why and what to do: no voice installed (`voice` nil), or a
    /// Personal Voice, which macOS never records to a file.
    static func voiceLine(_ voice: SpeechExportVoiceInfo?, onPhone: Bool = SpeechRefusalWording.runsOnPhone) -> String {
        guard let voice else { return sentence(for: .noVoice, onPhone: onPhone) }
        guard !voice.isPersonalVoice else { return sentence(for: .personalVoice(name: voice.name), onPhone: onPhone) }
        // Translators: The line in the Export dialog's spoken audio options naming the voice the book is spoken with. %@ is the voice's name.
        return InterfaceText.line("speechExport.voiceLine", "Voice: \(voice.name)")
    }

    /// The line about the licence the Mac's voices come with (the user's
    /// answer to question 20 asked for it).
    static var licence: String {
        licence(onPhone: SpeechRefusalWording.runsOnPhone)
    }

    /// The licence line in the words of the device: the Mac's voices', or, with `onPhone`, the iPhone's.
    static func licence(onPhone: Bool) -> String {
        if onPhone {
            // Translators: The line in the Export sheet's spoken audio options about the licence the iPhone's voices come with.
            return InterfaceText.line("speechExport.licence.iphone", "Speech from the iPhone's voices is for personal, non-commercial use, under Apple's licence.")
        }
        // Translators: The line in the Export dialog's spoken audio options about the licence the Mac's voices come with.
        return InterfaceText.line("speechExport.licence", "Speech from the Mac's voices is for personal, non-commercial use, under Apple's licence.")
    }

    // MARK: A File's Name

    /// What a file of the whole book is called after the book's title:
    /// "Middlemarch - Audio".
    static var wholeBookName: String {
        // Translators: Part of a spoken audio export's file name, after the book's title: the whole book, as in "Middlemarch - Audio".
        InterfaceText.line("common.audio", "Audio")
    }
    /// What the book's beginning is called in a file's name, as one end of
    /// its range: "Middlemarch - Beginning to Chapter 2".
    static var beginningName: String {
        // Translators: Part of a spoken audio export's file name: the beginning of the book as one end of the range, as in "Middlemarch - Beginning to Chapter 2".
        InterfaceText.line("speechExport.beginningName", "Beginning")
    }
    /// What the book's end is called in a file's name, as one end of its
    /// range: "Middlemarch - Chapter 2 to End".
    static var endName: String {
        // Translators: Part of a spoken audio export's file name: the end of the book as one end of the range, as in "Middlemarch - Chapter 2 to End".
        InterfaceText.line("speechExport.endName", "End")
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
        // Translators: Part of a spoken audio export's file name: a range of the book. %1$@ is where it begins and %2$@ where it ends, each a heading's words or the beginning or end of the book, as in "Chapter 1 to Chapter 3".
        InterfaceText.line("common.valueToValue", "\(from) to \(through)")
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
            // Translators: The progress of a spoken audio export while it speaks the chapters. %1$@ is the number of the chapter being spoken and %2$@ the number of chapters, both written without digit grouping.
            return InterfaceText.line("speechExport.progress.speaking", "Speaking chapter \(String(min(done + 1, total))) of \(String(total))…")
        case .encoding:
            // Translators: The progress of a spoken audio export once every chapter is spoken and the audio file is being made.
            return InterfaceText.line("speechExport.progress.encoding", "Encoding the audio file…")
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
        stopHint(onPhone: SpeechRefusalWording.runsOnPhone)
    }

    /// Stop's hint in the words of the device: the Mac keeps the chapters until TextMouth quits; the iPhone, for a
    /// week (`SpeechExportStore.keptOnPhone`), through a close of the app.
    static func stopHint(onPhone: Bool) -> String {
        if onPhone {
            // Translators: The hint of the Stop button in the Export sheet while a spoken audio export runs, on the iPhone.
            return InterfaceText.line("speechExport.stopHint.iphone", "Stops the export and keeps the chapters already spoken for a week, until a different spoken audio export starts, or until the book's voice, text, substitutions, or pauses change. Exporting the same range at the same speed and pitch goes on from them.")
        }
        // Translators: The hint of the Stop button in the Export dialog while a spoken audio export runs.
        return InterfaceText.line("speechExport.stopHint", "Stops the export and keeps the chapters already spoken until TextMouth quits, a different spoken audio export starts, or the book's voice, text, substitutions, or pauses change. Exporting the same range at the same speed and pitch goes on from them.")
    }

    /// The sentence an export that ended without its file adds to what the
    /// dialog says, telling what it kept, how to use it, and for how long:
    /// `done` of its `total` chapters are kept (`SpeechExportProgress.ended`).
    /// Nil when none is.
    static func kept(done: Int, total: Int, onPhone: Bool = SpeechRefusalWording.runsOnPhone) -> String? {
        guard done > 0 else { return nil }
        if onPhone { return keptOnPhone(done: done, total: total) }
        guard done >= total else {
            // Chapter numbers name places in the book, so they are written without grouping.
            // Translators: What the Export dialog says after a spoken audio export ended without its file and kept some of its chapters. %1$@ is how many chapters are kept, %2$lld how many there are, and %3$@ the number of the chapter to go on from, both written without digit grouping.
            return InterfaceText.line("speechExport.kept.chaptersGo", "Kept \(String(done)) of \(number: total) chapters until TextMouth quits, a different spoken audio export starts, or the book's voice, text, substitutions, or pauses change. To go on from chapter \(String(done + 1)), export the same range at the same speed and pitch.")
        }
        return total == 1
            // Translators: What the Export dialog says after a spoken audio export ended without its file and kept its only chapter.
            ? InterfaceText.line("speechExport.kept.chapter", "Kept the spoken chapter until TextMouth quits, a different spoken audio export starts, or the book's voice, text, substitutions, or pauses change. To make the audio file from it, export the same range at the same speed and pitch.")
            // Translators: What the Export dialog says after a spoken audio export ended without its file and kept every one of its chapters. %lld is the number of chapters, more than one.
            : InterfaceText.line("speechExport.kept.them", "Kept all \(number: total) spoken chapters until TextMouth quits, a different spoken audio export starts, or the book's voice, text, substitutions, or pauses change. To make the audio file from them, export the same range at the same speed and pitch.")
    }

    /// What an export that ended without its file kept, on the iPhone, which keeps spoken chapters for a week where
    /// the Mac keeps them until it quits. As `kept(done:total:onPhone:)` words the Mac's.
    private static func keptOnPhone(done: Int, total: Int) -> String {
        guard done >= total else {
            // Chapter numbers name places in the book, so they are written without grouping.
            // Translators: What the Export sheet says after a spoken audio export ended without its file and kept some of its chapters, on the iPhone. %1$@ is how many chapters are kept, %2$@ how many there are, and %3$@ the number of the chapter to go on from, each written without digit grouping. The counts follow a label, so no word has to agree with them.
            return InterfaceText.line("speechExport.kept.chaptersGo.iphone", "Chapters kept for a week: \(String(done)) of \(String(total)). They stay until a different spoken audio export starts, or until the book's voice, text, substitutions, or pauses change. To go on from chapter \(String(done + 1)), export the same range at the same speed and pitch.")
        }
        return total == 1
            // Translators: What the Export sheet says after a spoken audio export ended without its file and kept its only chapter, on the iPhone.
            ? InterfaceText.line("speechExport.kept.chapter.iphone", "The spoken chapter is kept for a week, until a different spoken audio export starts, or until the book's voice, text, substitutions, or pauses change. To make the audio file from it, export the same range at the same speed and pitch.")
            // Translators: What the Export sheet says after a spoken audio export ended without its file and kept every one of its chapters, on the iPhone. %@ is the number of chapters, more than one, written without digit grouping. The count follows a label, so no word has to agree with it.
            : InterfaceText.line("speechExport.kept.them.iphone", "Chapters kept for a week: all \(String(total)). They stay until a different spoken audio export starts, or until the book's voice, text, substitutions, or pauses change. To make the audio file from them, export the same range at the same speed and pitch.")
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
    private static func sentence(for refusal: SpeechExportError, onPhone: Bool = SpeechRefusalWording.runsOnPhone) -> String {
        refusal.description(onPhone: onPhone)
    }
}
