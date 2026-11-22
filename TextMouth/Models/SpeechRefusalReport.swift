import Foundation

// The report TextMouth shows when the Mac's speech engine refused a passage
// twice and speech stopped there (B05). The user asked, on October 7, for
// "a dialog with the error and any log to help find it", so that each
// refusal can be fixed rather than skipped: what happened, where, and the
// details that help find the cause. Everything here is a plain value and its
// words, so every line is pinned by a test without a window.

// MARK: - What Speech Hands Its Reader

/// What a speech service hands its reader when the Mac's speech engine
/// refused a passage on a fresh synthesizer too and speech stopped there
/// (`SpeechService.onSpeechRefused`): where, what was refused, exactly as it
/// was handed to the engine, and how it was to be spoken.
///
/// Offsets count UTF-16 units of the spoken text: the chapter as speech
/// speaks it, after the substitutions, the skipped sections, and the pauses,
/// which is what the speech log's offsets count too.
struct SpeechRefusal: Equatable, Sendable {
    /// A voice, as the report names it.
    struct Voice: Equatable, Sendable {
        /// The voice's name, such as "Samantha".
        let name: String
        /// The voice's identifier, such as
        /// "com.apple.voice.compact.en-US.Samantha".
        let identifier: String
        /// The voice's language, such as "en-US".
        let language: String
        /// The voice's quality, as the voice pickers say it ("Standard",
        /// "Enhanced", "Premium").
        let quality: String
    }

    /// Where speech stopped, the cursor left there.
    let offset: Int
    /// Where the refused utterance began and ended.
    let refusedRange: Range<Int>
    /// The refused utterance's text, exactly as it was handed to the engine:
    /// after the substitutions and the markup guard (`SpeechMarkupGuard`),
    /// which keeps every length, so it is as long as `refusedRange`.
    let refusedText: String
    /// The part of the spoken text handed over with every angle bracket
    /// silent (`SpeechService`'s strictly guarded range), or nil when only
    /// the usual guard applied.
    let strictlyGuardedRange: Range<Int>?
    /// The voice the refused utterance was handed over in, or nil for the
    /// system's default voice.
    let voice: Voice?
    /// The speed the listener chose, in words per minute.
    let wordsPerMinute: Double
    /// The refused utterance's rate, as the engine takes it (0 to 1).
    let rate: Float
    /// The refused utterance's pitch multiplier.
    let pitchMultiplier: Float
    /// The refused utterance's volume, below 1 in a sleep timer's fade.
    let volume: Float
    /// The speech service's newest transition lines, ending with the one
    /// that ended speech (`DIRECT_RETRY_FAILED`).
    let recentLines: [RecentTransitionLines.Line]
}

// MARK: - A Passage Around the Refusal

/// A few hundred characters of a text around where speech stopped, with
/// where the refused text begins and ends in it (B05). The report shows two:
/// the chapter as the book has it, and the refused text as it was handed to
/// the engine.
///
/// Every offset is clamped to the text and moved back to the start of the
/// character it falls in, so a passage never splits a character and never
/// reaches outside its text, at a chapter's start, at its end, or with
/// offsets that do not fit the text at all.
struct SpeechRefusalPassage: Equatable, Sendable {
    /// The most UTF-16 units a passage holds before where speech stopped.
    static let unitsBefore = 100
    /// The most UTF-16 units a passage holds from where speech stopped on.
    static let unitsAfter = 400

    /// Where the passage begins and ends, in the offsets of the text it
    /// comes from.
    let range: Range<Int>
    /// Where the refused text begins and ends, in the same offsets, as far
    /// as the text goes; it may begin before the passage or end after it.
    let refusedRange: Range<Int>
    /// The passage's text before the refused text begins; empty when the
    /// refused text begins at or before the passage's start.
    let before: String
    /// The part of the refused text the passage holds.
    let refused: String
    /// The passage's text after the refused text ends; empty when the
    /// refused text ends at or after the passage's end.
    let after: String

    /// The passage of `text` around `stop`, where speech stopped, holding
    /// at most `unitsBefore` UTF-16 units before it and `unitsAfter` from it
    /// on, with the part of `refused` it holds.
    ///
    /// - Parameters:
    ///   - text: The text the passage is taken from.
    ///   - textStart: The offset `text` begins at, in the offsets `stop`
    ///     and `refused` count in: 0 for a whole chapter, the refused text's
    ///     start for the refused utterance's own text.
    ///   - stop: Where speech stopped. Speech stops inside the refused
    ///     text, so a stop outside it counts as its nearer end.
    ///   - refused: Where the refused text begins and ends.
    init(
        of text: String,
        startingAt textStart: Int = 0,
        around stop: Int,
        refused: Range<Int>,
        unitsBefore: Int = Self.unitsBefore,
        unitsAfter: Int = Self.unitsAfter
    ) {
        let length = text.utf16Length
        // The offsets in `text`'s own terms, inside it.
        func local(_ offset: Int) -> Int {
            max(0, min(offset - textStart, length))
        }
        // The start of the character an offset falls in.
        func characterStart(_ offset: Int) -> Int {
            text.utf16Offset(of: text.index(atUTF16Offset: offset))
        }
        let refusedStart = characterStart(local(refused.lowerBound))
        let refusedEnd = characterStart(local(refused.upperBound))
        let stopped = max(refusedStart, min(local(stop), refusedEnd))
        let start = characterStart(max(0, stopped - max(0, unitsBefore)))
        let end = characterStart(min(length, stopped + max(0, unitsAfter)))
        // The refused text's part of the passage, inside it.
        let partStart = max(start, min(refusedStart, end))
        let partEnd = max(partStart, min(refusedEnd, end))

        /// `text` from `lower` to `upper`, both character starts.
        func piece(_ lower: Int, _ upper: Int) -> String {
            String(text[text.index(atUTF16Offset: lower)..<text.index(atUTF16Offset: upper)])
        }
        range = (start + textStart)..<(end + textStart)
        refusedRange = (refusedStart + textStart)..<(refusedEnd + textStart)
        before = piece(start, partStart)
        self.refused = piece(partStart, partEnd)
        after = piece(partEnd, end)
    }
}

// MARK: - The Report

/// Everything the report of a refusal says (B05): what happened and where,
/// the passage as the book has it and as it was handed to the engine, the
/// voice and speed, this Mac and TextMouth's build, the speech log's newest
/// lines, the time, and how often this place was refused while the window
/// has been open. `lines` words it, line by line, for the report's sheet,
/// a braille display, and Copy Details alike.
struct SpeechRefusalReport: Equatable, Sendable {
    /// The book's title.
    let bookTitle: String
    /// The book's format, as the library names it ("EPUB", "Plain Text").
    let bookFormat: String
    /// Where the reader is, as the brief Where Am I? says it, without the
    /// book's title: "Tides. Heading 2 of 9. 42 percent. 3 hours remaining."
    let position: String
    /// The chapter speech stopped in, counted from 0 as the logs count
    /// chapters, and how many chapters the book has.
    let chapterIndex: Int
    let chapterCount: Int
    /// The chapter's own title, when it has one.
    let chapterTitle: String?
    /// Where speech stopped in the chapter's text as the book has it, and
    /// that text's length, in UTF-16 units.
    let chapterOffset: Int
    let chapterLength: Int
    /// What the speech service handed the reader.
    let refusal: SpeechRefusal
    /// The chapter as the book has it, around where speech stopped.
    let bookPassage: SpeechRefusalPassage
    /// The refused text as it was handed to the engine.
    let spokenPassage: SpeechRefusalPassage
    /// macOS's version, as the system says it ("Version 26.3.1 (Build
    /// 25D2128)").
    let systemVersion: String
    /// TextMouth's build.
    let build: BuildIdentity
    /// When the reader heard of the refusal.
    let time: Date
    /// How many times speech was refused at this place while the window
    /// has been open, this time included: the reader counts it as it shows
    /// the report (`SpeechRefusalAlert.show(_:)`).
    var timesRefusedHere: Int

    /// The report of `refusal`, which stopped speech in the chapter at
    /// `chapterIndex`, whose text as the book has it is `chapterText`.
    ///
    /// - Parameters:
    ///   - toChapterOffset: Turns an offset of the spoken text into one of
    ///     `chapterText`, as the reader's offset map does; whatever it
    ///     returns is kept inside the chapter.
    ///   - timesRefusedHere: How often this place was refused, this time
    ///     included.
    init(
        bookTitle: String,
        bookFormat: String,
        position: String,
        chapterIndex: Int,
        chapterCount: Int,
        chapterTitle: String?,
        chapterText: String,
        toChapterOffset: (Int) -> Int,
        refusal: SpeechRefusal,
        systemVersion: String,
        build: BuildIdentity,
        time: Date,
        timesRefusedHere: Int = 1
    ) {
        let length = chapterText.utf16Length
        let inChapter = { (offset: Int) in max(0, min(offset, length)) }
        let stop = inChapter(toChapterOffset(refusal.offset))
        // A map need not keep the refused text's ends in order; the
        // passage needs them so.
        let refusedStart = inChapter(toChapterOffset(refusal.refusedRange.lowerBound))
        let refusedEnd = inChapter(toChapterOffset(refusal.refusedRange.upperBound))
        let refusedInChapter = min(refusedStart, refusedEnd)..<max(refusedStart, refusedEnd)

        self.bookTitle = bookTitle
        self.bookFormat = bookFormat
        self.position = position
        self.chapterIndex = chapterIndex
        self.chapterCount = chapterCount
        self.chapterTitle = chapterTitle
        chapterOffset = stop
        chapterLength = length
        self.refusal = refusal
        bookPassage = SpeechRefusalPassage(of: chapterText, around: stop, refused: refusedInChapter)
        spokenPassage = SpeechRefusalPassage(
            of: refusal.refusedText,
            startingAt: refusal.refusedRange.lowerBound,
            around: refusal.offset,
            refused: refusal.refusedRange
        )
        self.systemVersion = systemVersion
        self.build = build
        self.time = time
        self.timesRefusedHere = timesRefusedHere
    }

    /// Where speech was refused: the chapter, and where speech stopped in
    /// its text as the book has it.
    var place: SpeechRefusalPlace {
        SpeechRefusalPlace(chapterIndex: chapterIndex, characterOffset: chapterOffset)
    }

    /// The report, line by line: what happened, where, the two passages,
    /// the voice and speed, this Mac, and the speech log's lines.
    var lines: [String] {
        typealias Words = SpeechRefusalWording
        var lines = [Words.heading, Words.summary, ""]

        lines.append(Words.whereHeading)
        lines.append(Words.book(title: bookTitle, format: bookFormat))
        if !position.isEmpty {
            lines.append(Words.position(position))
        }
        lines.append(Words.chapter(index: chapterIndex, of: chapterCount, title: chapterTitle))
        lines.append(Words.stoppedInChapter(offset: chapterOffset, of: chapterLength))
        lines.append(Words.stoppedInSpokenText(offset: refusal.offset, refused: refusal.refusedRange))
        lines.append(Words.refusedHere(times: timesRefusedHere))
        lines.append(Words.timeLine(time))
        lines.append("")

        lines.append(Words.bookPassageHeading(range: bookPassage.range, chapterNumber: chapterIndex + 1))
        lines += Words.passageLines(bookPassage)
        lines.append("")

        lines.append(Words.spokenPassageHeading(range: spokenPassage.range))
        lines += Words.passageLines(spokenPassage)
        lines.append(Words.markupGuard(strictlyWithin: refusal.strictlyGuardedRange))
        lines.append("")

        lines.append(Words.voiceAndSpeedHeading)
        lines.append(Words.voice(refusal.voice))
        lines.append(Words.speed(of: refusal))
        lines.append("")

        lines.append(Words.deviceHeading(onPhone: Words.runsOnPhone))
        lines.append(Words.systemLine(version: systemVersion, onPhone: Words.runsOnPhone))
        lines.append(Words.build(build))
        lines.append("")

        lines += Words.logLines(refusal.recentLines)
        return lines
    }

    /// The whole report as plain text, one line after another: what the
    /// sheet's details show and what Copy Details copies.
    var text: String {
        lines.joined(separator: "\n")
    }
}

// MARK: - The Words

/// Every word of the report of a refusal and of what goes with it: the
/// sheet's heading, buttons, and labels, and what VoiceOver hears, each
/// defined once for the screen, VoiceOver, a braille display, and the tests.
///
/// A character offset, a chapter's number, and the number of a chapter in
/// the logs are written as `String(number)`: each names a place that the
/// speech log gives by the same digits, so it is never grouped ("1,204")
/// and always matches the log. The speech log's own lines stay as the log
/// wrote them, English.
enum SpeechRefusalWording {
    /// The sheet's heading, and the report's first line.
    static var heading: String {
        // Translators: Heading of the sheet that reports speech stopped because the speech engine refused a passage, and the first line of its report.
        InterfaceText.line("speechRefusal.heading", "Speech Stopped")
    }

    /// What happened, in one plain sentence, and what Play does now. It names
    /// no device, so one sentence serves the Mac and the iPhone: the report's
    /// own device heading says which ("This Mac", "This iPhone").
    static var summary: String {
        // Translators: Summary under the heading of the report of a refusal, on the Mac and the iPhone: what happened, and that Play tries again.
        InterfaceText.line("speechRefusal.summary", "The speech engine refused to speak the text here, twice, so speech stopped. Play tries again from the same place.")
    }

    /// Whether this build is the iPhone app, which words the report's device
    /// lines for the iPhone (the spec, "Words that say Mac"). A parameter of
    /// the functions below, so that a test on the Mac reaches both.
    static var runsOnPhone: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    /// The heading of the report's lines about the device it ran on.
    static func deviceHeading(onPhone: Bool) -> String {
        if onPhone {
            // Translators: Heading of the report's lines about the device it ran on, on the iPhone.
            return InterfaceText.line("speechRefusal.deviceHeading.iphone", "This iPhone")
        }
        // Translators: Heading of the report's lines about the device it ran on, on the Mac.
        return InterfaceText.line("speechRefusal.deviceHeading.mac", "This Mac")
    }

    /// The report's line naming the system and its version: "macOS: ..." on
    /// the Mac, "iOS: ..." on the iPhone.
    static func systemLine(version: String, onPhone: Bool) -> String {
        let system = onPhone ? "iOS" : "macOS" // l10n: no (the operating system's own name)
        return SentenceWording.labelled(system, version)
    }

    /// What VoiceOver hears at the stop when the book's window is not in
    /// front, where the sheet cannot speak for itself: another window or
    /// app is, or another sheet is over the book, or the report is already
    /// open there.
    static var announcement: String {
        // Translators: Announcement when speech stopped because the speech engine refused a passage and the book's window is not in front, so its report sheet cannot speak.
        InterfaceText.line("speechRefusal.announcement", "Speech stopped: the speech engine refused this passage. Details are in the book's window.")
    }

    /// The spoken label of the text area holding the whole report.
    static var detailsLabel: String {
        // Translators: VoiceOver label of the text area holding the whole report of a speech refusal.
        InterfaceText.line("speechRefusal.detailsLabel", "Details")
    }

    /// The button that copies the whole report, and what it does.
    static var copyTitle: String {
        // Translators: Title of the button of the speech refusal report that copies the whole report.
        InterfaceText.line("speechRefusal.copyTitle", "Copy Details")
    }
    static var copyHint: String {
        // Translators: VoiceOver hint of the Copy Details button of the speech refusal report.
        InterfaceText.line("speechRefusal.copyHint", "Copies the whole report as plain text")
    }

    /// What VoiceOver hears once Copy Details has copied the report, and
    /// should the pasteboard refuse it.
    static var copiedAnnouncement: String {
        // Translators: Announcement after Copy Details copied the report of a speech refusal.
        InterfaceText.line("speechRefusal.copiedAnnouncement", "Details copied")
    }
    static var notCopiedAnnouncement: String {
        // Translators: Announcement when Copy Details could not copy the report of a speech refusal to the pasteboard.
        InterfaceText.line("speechRefusal.notCopiedAnnouncement", "The details could not be copied")
    }

    /// The button that closes the sheet, which Return and Escape press, and
    /// what it does.
    static var closeTitle: String {
        // Translators: Title of the button that closes a sheet, such as the speech refusal report.
        InterfaceText.line("common.close", "Close")
    }
    static var closeHint: String {
        // Translators: VoiceOver hint of the Close button of the speech refusal report.
        InterfaceText.line("speechRefusal.closeHint", "Afterwards, Play tries the passage again")
    }

    // MARK: Where

    /// The heading of the report's lines about where speech stopped.
    static var whereHeading: String {
        // Translators: Heading of the lines of a speech refusal report that say where in the book speech stopped.
        InterfaceText.line("speechRefusal.whereHeading", "Where")
    }

    /// The book's line: "Book: Moby Dick (EPUB)".
    static func book(title: String, format: String) -> String {
        // Translators: A line of the speech refusal report naming the book. %1$@ is its title and %2$@ its format, such as EPUB.
        InterfaceText.line("speechRefusal.book", "Book: \(title) (\(format))")
    }

    /// The reader's position in the book, as the book's own position text
    /// says it: "Position: Page 12".
    static func position(_ position: String) -> String {
        SentenceWording.labelled(
            // Translators: Label before the reader's position in the book, in a line of the speech refusal report.
            InterfaceText.line("common.position", "Position"),
            position)
    }

    /// The chapter speech stopped in, the one at `index` counting from 0:
    /// "Chapter 3 of 12 (chapter=2 in the logs): The Battle". The logs count
    /// chapters from 0, the listener from 1.
    static func chapter(index: Int, of count: Int, title: String?) -> String {
        // Translators: A line of the speech refusal report naming the chapter speech stopped in. %1$@ is the chapter's number counting from 1, %2$@ the number of chapters, and %3$@ the chapter's number counting from 0 as the debug log writes it, each written without digit grouping. Keep "chapter=" as it is: it is the log's own tag.
        let place = InterfaceText.line("speechRefusal.chapter", "Chapter \(String(index + 1)) of \(String(count)) (chapter=\(String(index)) in the logs)")
        guard let title, !title.isEmpty else { return place }
        return SentenceWording.labelled(place, title)
    }

    /// Where speech stopped, in the chapter's text as the book has it: "Speech
    /// stopped at character 1204 of 5000 in the chapter."
    static func stoppedInChapter(offset: Int, of length: Int) -> String {
        // Translators: A line of the speech refusal report. %1$@ is the character offset where speech stopped and %2$@ the chapter's length in characters, each written without digit grouping like the speech log's offsets.
        InterfaceText.line("speechRefusal.stoppedInChapter", "Speech stopped at character \(String(offset)) of \(String(length)) in the chapter.")
    }

    /// Where speech stopped in the spoken text, and what range of it the
    /// engine refused.
    static func stoppedInSpokenText(offset: Int, refused: Range<Int>) -> String {
        // Translators: A line of the speech refusal report. %1$@ is the character offset in the spoken text where speech stopped; %2$@ and %3$@ are where the refused text begins and ends, each written without digit grouping like the speech log's offsets.
        InterfaceText.line("speechRefusal.stoppedInSpokenText", "In the spoken text, whose offsets the speech log gives: speech stopped at character \(String(offset)); the refused text runs from character \(String(refused.lowerBound)) to \(String(refused.upperBound)).")
    }

    /// How many times the engine refused text since the window opened.
    static func refusedHere(times: Int) -> String {
        // Translators: A line of the speech refusal report. %lld is how many times the speech engine refused text while the book's window has been open.
        InterfaceText.line("speechRefusal.refusedHere", "Refused here: \(number: times) times while this window has been open.")
    }

    /// A time, as the log files write theirs, so that the report's time and
    /// the log's lines can be read side by side: "2026-10-09 22:42:05 +0000".
    static func time(_ date: Date) -> String {
        "\(date)" // l10n: no (a time as the log files write it)
    }

    /// The report's time line: "Time: 2026-10-09 22:42:05 +0000".
    static func timeLine(_ date: Date) -> String {
        SentenceWording.labelled(
            // Translators: Label before the time of the refusal, in a line of the speech refusal report; the time is written as the log files write it.
            InterfaceText.line("common.time", "Time"),
            time(date))
    }

    // MARK: Passages

    /// The heading above the passage as the book has it.
    static func bookPassageHeading(range: Range<Int>, chapterNumber: Int) -> String {
        // Translators: A line of the speech refusal report that introduces the passage as the book has it. %1$@ and %2$@ are the first and last character offsets of the passage, and %3$@ is the chapter's number, each written without digit grouping.
        InterfaceText.line("speechRefusal.bookPassageHeading", "The passage as the book has it, characters \(String(range.lowerBound)) to \(String(range.upperBound)) of chapter \(String(chapterNumber)):")
    }

    /// The heading above the passage as the speech engine was handed it.
    static func spokenPassageHeading(range: Range<Int>) -> String {
        // Translators: A line of the speech refusal report that introduces the text the speech engine was handed, after the user's substitution rules and the markup guard. %1$@ and %2$@ are the first and last character offsets in the spoken text, written without digit grouping.
        InterfaceText.line("speechRefusal.spokenPassageHeading", "The text handed to the speech engine, after the substitutions and the markup guard, characters \(String(range.lowerBound)) to \(String(range.upperBound)) of the spoken text:")
    }

    /// The heading of the lines about the voice and its speed.
    static var voiceAndSpeedHeading: String {
        // Translators: Heading of the lines of a speech refusal report about the voice and the speaking speed.
        InterfaceText.line("speechRefusal.voiceAndSpeedHeading", "Voice and speed")
    }

    /// A passage's lines: its text, with where the refused text begins and
    /// ends said in words on lines of their own, so that each can be found
    /// line by line with VoiceOver and on a braille display, whatever the
    /// text around it holds.
    static func passageLines(_ passage: SpeechRefusalPassage) -> [String] {
        var lines: [String] = []
        let refused = passage.refusedRange
        if refused.lowerBound < passage.range.lowerBound {
            // Translators: A line of the speech refusal report: the refused text began before the passage shown. %@ is the character offset where it began, written without digit grouping.
            lines.append(InterfaceText.line("speechRefusal.passageLines.before", "The refused text began before this passage, at character \(String(refused.lowerBound))."))
        } else {
            if !passage.before.isEmpty {
                lines.append(passage.before)
            }
            // Translators: A line of the speech refusal report, just before the refused text. %@ is the character offset where it begins, written without digit grouping.
            lines.append(InterfaceText.line("speechRefusal.passageLines.begins", "The refused text begins here, at character \(String(refused.lowerBound))."))
        }
        if !passage.refused.isEmpty {
            lines.append(passage.refused)
        }
        if refused.upperBound > passage.range.upperBound {
            // Translators: A line of the speech refusal report: the refused text goes on past the passage shown. %@ is the character offset where it ends, written without digit grouping.
            lines.append(InterfaceText.line("speechRefusal.passageLines.goes", "The refused text goes on past this passage, to character \(String(refused.upperBound))."))
        } else {
            // Translators: A line of the speech refusal report, just after the refused text. %@ is the character offset where it ends, written without digit grouping.
            lines.append(InterfaceText.line("speechRefusal.passageLines.ends", "The refused text ends here, at character \(String(refused.upperBound))."))
            if !passage.after.isEmpty {
                lines.append(passage.after)
            }
        }
        return lines
    }

    /// Which markup guard the refused text was handed over through: every
    /// angle bracket silent in `strictlyWithin`, as for a passage the engine
    /// refused once, or else only the brackets of tag-shaped text.
    static func markupGuard(strictlyWithin strict: Range<Int>?) -> String {
        guard let strict else {
            // Translators: A line of the speech refusal report: the markup guard that was used silences only the angle brackets that make tags.
            return InterfaceText.line("speechRefusal.markupGuard.silences", "Markup guard: the usual one, which silences only the brackets of tag-shaped text.")
        }
        // Translators: A line of the speech refusal report: the markup guard silenced every angle bracket between two characters. %1$@ and %2$@ are the first and last character offsets in the spoken text, written without digit grouping.
        return InterfaceText.line("speechRefusal.markupGuard.character", "Markup guard: strict, every angle bracket silent, from character \(String(strict.lowerBound)) to \(String(strict.upperBound)) of the spoken text.")
    }

    // MARK: Voice, Speed, and Build

    /// The voice: "Voice: Samantha (com.apple.voice.compact.en-US.Samantha),
    /// en-US, Standard quality".
    static func voice(_ voice: SpeechRefusal.Voice?) -> String {
        guard let voice else {
            // Translators: A line of the speech refusal report: no voice was chosen, so the system's default voice spoke.
            return InterfaceText.line("speechRefusal.voice.default", "Voice: the system's default voice")
        }
        // Translators: A line of the speech refusal report naming the voice. %1$@ is its name, %2$@ its system identifier, %3$@ its language code such as en-US, and %4$@ its quality such as Standard, Enhanced, or Premium.
        return InterfaceText.line("speechRefusal.voice.quality", "Voice: \(voice.name) (\(voice.identifier)), \(voice.language), \(voice.quality) quality")
    }

    /// The speed, and the rate, pitch, and volume the refused utterance was
    /// handed over with: "Speed: 200 words per minute; rate 0.43, pitch
    /// 1.00, volume 1.00".
    static func speed(of refusal: SpeechRefusal) -> String {
        let wordsPerMinute = Int(refusal.wordsPerMinute.rounded())
        let rate = twoDecimals(refusal.rate)
        let pitch = twoDecimals(refusal.pitchMultiplier)
        let volume = twoDecimals(refusal.volume)
        // Translators: A line of the speech refusal report. %1$lld is the speaking speed in words per minute; %2$@, %3$@, and %4$@ are the engine's rate, pitch multiplier, and volume, each written with two decimals.
        return InterfaceText.line("speechRefusal.speed", "Speed: \(number: wordsPerMinute) words per minute; rate \(rate), pitch \(pitch), volume \(volume)")
    }

    /// `value` with two decimals in the interface language: "0.43".
    private static func twoDecimals(_ value: some BinaryFloatingPoint) -> String {
        Double(value).formatted(.number.precision(.fractionLength(2)).locale(InterfaceLanguage.current.locale))
    }

    /// TextMouth's build, with the details the app's Info.plist holds:
    /// "TextMouth: version 1.0, build 7, Debug, commit abc1234, built
    /// 2026-10-09T17:00:00Z". A detail the build did not record is left out.
    static func build(_ build: BuildIdentity) -> String {
        let known = { (value: String) in value != "unknown" && !value.isEmpty } // l10n: no (the build record's own marker for a missing detail)
        var details: [String] = []
        if known(build.version) {
            // Translators: A detail of the build line of the speech refusal report. %@ is the app's version, such as 0.5.3.
            details.append(InterfaceText.line("speechRefusal.build.version", "version \(build.version)"))
        }
        if known(build.buildNumber) {
            // Translators: A detail of the build line of the speech refusal report. %@ is the app's build number.
            details.append(InterfaceText.line("speechRefusal.build.number", "build \(build.buildNumber)"))
        }
        if known(build.configuration) { details.append(build.configuration) } // l10n: no (a build configuration's own name, such as Debug)
        if known(build.gitCommit) {
            // Translators: A detail of the build line of the speech refusal report. %@ is the abbreviated identifier of the source commit the app was built from.
            details.append(InterfaceText.line("speechRefusal.build.commit", "commit \(build.gitCommit)"))
        }
        if known(build.buildDate) {
            // Translators: A detail of the build line of the speech refusal report. %@ is the date and time the app was built, as written in its Info.plist.
            details.append(InterfaceText.line("speechRefusal.build.built", "built \(build.buildDate)"))
        }
        guard !details.isEmpty else {
            // Translators: A line of the speech refusal report: the app recorded nothing about how it was built.
            return InterfaceText.line("speechRefusal.build.recorded", "TextMouth: no build details recorded")
        }
        return SentenceWording.labelled("TextMouth", SentenceWording.commaJoined(details)) // l10n: no (the app's name)
    }

    /// The speech log's lines, as the log file holds them, under a line
    /// saying how many there are and that they hold no words of the book.
    static func logLines(_ lines: [RecentTransitionLines.Line]) -> [String] {
        guard !lines.isEmpty else {
            // Translators: A line of the speech refusal report: the speech log has no lines to show.
            return [InterfaceText.line("speechRefusal.logLines.speechNo", "Speech log: no lines.")]
        }
        // Translators: A line of the speech refusal report, above the speech log's own lines (which stay English, as the log wrote them). %lld is how many lines follow.
        let heading = InterfaceText.line("speechRefusal.logLines.offsets", "Speech log, its last \(number: lines.count) lines, offsets and lengths only:")
        return [heading] + lines.map(\.logged)
    }
}

// MARK: - Where the Book's Window Stands

/// Where a book's window stands for the listener when the report of a
/// refusal comes (B05), which decides whether the report's sheet can speak
/// for itself. A refusal never takes the keyboard or VoiceOver from another
/// window or app: its sheet waits on its own window.
enum SpeechRefusalWindowStanding: Equatable, Sendable {
    /// The window is the key window of the active app, with nothing over
    /// it: the sheet opens at once in front of the listener, and VoiceOver
    /// moves to it.
    case inFront
    /// The window has the keyboard in the active app, but a sheet is over
    /// it, one of the reader's panels or the report itself: the report
    /// waits for the panel to close, or updates in place.
    case underASheet
    /// Another window or another app is in front: the sheet waits on its
    /// window.
    case behind

    /// Where a window stands: whether TextMouth is the active app, whether
    /// the window is its key window, whether a sheet is over the window, and
    /// whether that sheet is the key window.
    static func of(appIsActive: Bool, windowIsKey: Bool, windowHasSheet: Bool, keyWindowIsItsSheet: Bool) -> Self {
        guard appIsActive, windowIsKey || keyWindowIsItsSheet else { return .behind }
        return windowHasSheet || keyWindowIsItsSheet ? .underASheet : .inFront
    }

    /// Whether the report's sheet, made now, moves VoiceOver to its heading
    /// as it opens: when it opens in front of the listener, at once or as
    /// the panel over the window closes; never from behind.
    var sheetTakesVoiceOverFocus: Bool {
        self != .behind
    }

    /// Whether the report, coming now, is told to the listener by its sheet
    /// alone, which opens at once in front and speaks for itself. Anywhere
    /// else, under a sheet or behind, the sheet opens later or not in
    /// front, or is open already and only changes, so VoiceOver hears
    /// `SpeechRefusalWording.announcement` instead: one message either way.
    var sheetSpeaksForItself: Bool {
        self == .inFront
    }
}

// MARK: - What a Reader Keeps

/// A place in a book where speech was refused: its chapter, counted from 0,
/// and where speech stopped in the chapter's text as the book has it.
struct SpeechRefusalPlace: Hashable, Sendable {
    let chapterIndex: Int
    let characterOffset: Int
}

/// What a reader keeps of the speech engine's refusals while its window is
/// open (B05): the report its sheet shows, and how many times each place was
/// refused. A refusal while the sheet is open replaces the report it shows,
/// so there is never more than one; closing the sheet forgets the report but
/// not the counts.
struct SpeechRefusalAlert: Equatable, Sendable {
    /// The report the reader's sheet shows; nil while it shows none.
    var report: SpeechRefusalReport?
    /// How many times speech was refused at each place so far.
    private var timesRefused: [SpeechRefusalPlace: Int] = [:]

    /// Shows `report` in place of any report shown, counting one more
    /// refusal at its place, which the report then says.
    mutating func show(_ report: SpeechRefusalReport) {
        var counted = report
        counted.timesRefusedHere = countRefusal(at: report.place)
        self.report = counted
    }

    /// Counts one more refusal at `place`, and returns how many there have
    /// been there, this one included.
    private mutating func countRefusal(at place: SpeechRefusalPlace) -> Int {
        let count = timesRefused[place, default: 0] + 1
        timesRefused[place] = count
        return count
    }
}
