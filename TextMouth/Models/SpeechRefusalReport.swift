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

        lines.append("Where")
        lines.append("Book: \(bookTitle) (\(bookFormat))")
        if !position.isEmpty {
            lines.append("Position: \(position)")
        }
        lines.append(Words.chapter(index: chapterIndex, of: chapterCount, title: chapterTitle))
        lines.append("Speech stopped at character \(chapterOffset) of \(chapterLength) in the chapter.")
        lines.append(
            "In the spoken text, whose offsets the speech log gives: speech stopped at character \(refusal.offset); "
                + "the refused text runs from character \(refusal.refusedRange.lowerBound) "
                + "to \(refusal.refusedRange.upperBound)."
        )
        lines.append("Refused here: \(CountWording.phrase(timesRefusedHere, singular: "time", plural: "times")) while this window has been open.")
        lines.append("Time: \(Words.time(time))")
        lines.append("")

        lines.append(
            "The passage as the book has it, characters \(bookPassage.range.lowerBound) "
                + "to \(bookPassage.range.upperBound) of chapter \(chapterIndex + 1):"
        )
        lines += Words.passageLines(bookPassage)
        lines.append("")

        lines.append(
            "The text handed to the speech engine, after the substitutions and the markup guard, "
                + "characters \(spokenPassage.range.lowerBound) to \(spokenPassage.range.upperBound) of the spoken text:"
        )
        lines += Words.passageLines(spokenPassage)
        lines.append(Words.markupGuard(strictlyWithin: refusal.strictlyGuardedRange))
        lines.append("")

        lines.append("Voice and speed")
        lines.append(Words.voice(refusal.voice))
        lines.append(Words.speed(of: refusal))
        lines.append("")

        lines.append("This Mac")
        lines.append("macOS: \(systemVersion)")
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
enum SpeechRefusalWording {
    /// The sheet's heading, and the report's first line.
    static let heading = "Speech Stopped"

    /// What happened, in one plain sentence, and what Play does now.
    static let summary = "The Mac's speech engine refused to speak the text here, twice, so speech stopped. "
        + "Play tries again from the same place."

    /// What VoiceOver hears at the stop when the book's window is not in
    /// front, where the sheet cannot speak for itself: another window or
    /// app is, or another sheet is over the book, or the report is already
    /// open there.
    static let announcement = "Speech stopped: the speech engine refused this passage. Details are in the book's window."

    /// The spoken label of the text area holding the whole report.
    static let detailsLabel = "Details"

    /// The button that copies the whole report, and what it does.
    static let copyTitle = "Copy Details"
    static let copyHint = "Copies the whole report as plain text, to paste where it helps find the cause"

    /// What VoiceOver hears once Copy Details has copied the report.
    static let copiedAnnouncement = "Details copied"

    /// The button that closes the sheet, which Return and Escape press, and
    /// what it does.
    static let closeTitle = "Close"
    static let closeHint = "Closes the report; Play tries the passage again"

    /// The chapter speech stopped in, the one at `index` counting from 0:
    /// "Chapter 3 of 12 (chapter=2 in the logs): The Battle". The logs count
    /// chapters from 0, the listener from 1.
    static func chapter(index: Int, of count: Int, title: String?) -> String {
        let place = "Chapter \(index + 1) of \(count) (chapter=\(index) in the logs)"
        guard let title, !title.isEmpty else { return place }
        return "\(place): \(title)"
    }

    /// A time, as the log files write theirs, so that the report's time and
    /// the log's lines can be read side by side: "2026-10-09 22:42:05 +0000".
    static func time(_ date: Date) -> String {
        "\(date)"
    }

    /// A passage's lines: its text, with where the refused text begins and
    /// ends said in words on lines of their own, so that each can be found
    /// line by line with VoiceOver and on a braille display, whatever the
    /// text around it holds.
    static func passageLines(_ passage: SpeechRefusalPassage) -> [String] {
        var lines: [String] = []
        let refused = passage.refusedRange
        if refused.lowerBound < passage.range.lowerBound {
            lines.append("The refused text began before this passage, at character \(refused.lowerBound).")
        } else {
            if !passage.before.isEmpty {
                lines.append(passage.before)
            }
            lines.append("The refused text begins here, at character \(refused.lowerBound).")
        }
        if !passage.refused.isEmpty {
            lines.append(passage.refused)
        }
        if refused.upperBound > passage.range.upperBound {
            lines.append("The refused text goes on past this passage, to character \(refused.upperBound).")
        } else {
            lines.append("The refused text ends here, at character \(refused.upperBound).")
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
            return "Markup guard: the usual one, which silences only the brackets of tag-shaped text."
        }
        return "Markup guard: strict, every angle bracket silent, from character \(strict.lowerBound) "
            + "to \(strict.upperBound) of the spoken text."
    }

    /// The voice: "Voice: Samantha (com.apple.voice.compact.en-US.Samantha),
    /// en-US, Standard quality".
    static func voice(_ voice: SpeechRefusal.Voice?) -> String {
        guard let voice else { return "Voice: the system's default voice" }
        return "Voice: \(voice.name) (\(voice.identifier)), \(voice.language), \(voice.quality) quality"
    }

    /// The speed, and the rate, pitch, and volume the refused utterance was
    /// handed over with: "Speed: 200 words per minute; rate 0.43, pitch
    /// 1.00, volume 1.00".
    static func speed(of refusal: SpeechRefusal) -> String {
        let wordsPerMinute = Int(refusal.wordsPerMinute.rounded())
        return "Speed: \(wordsPerMinute) words per minute; "
            + String(format: "rate %.2f, pitch %.2f, volume %.2f", refusal.rate, refusal.pitchMultiplier, refusal.volume)
    }

    /// TextMouth's build, with the details the app's Info.plist holds:
    /// "TextMouth: version 1.0, build 7, Debug, commit abc1234, built
    /// 2026-10-09T17:00:00Z". A detail the build did not record is left out.
    static func build(_ build: BuildIdentity) -> String {
        let known = { (value: String) in value != "unknown" && !value.isEmpty }
        var details: [String] = []
        if known(build.version) { details.append("version \(build.version)") }
        if known(build.buildNumber) { details.append("build \(build.buildNumber)") }
        if known(build.configuration) { details.append(build.configuration) }
        if known(build.gitCommit) { details.append("commit \(build.gitCommit)") }
        if known(build.buildDate) { details.append("built \(build.buildDate)") }
        guard !details.isEmpty else { return "TextMouth: no build details recorded" }
        return "TextMouth: " + details.joined(separator: ", ")
    }

    /// The speech log's lines, as the log file holds them, under a line
    /// saying how many there are and that they hold no words of the book.
    static func logLines(_ lines: [RecentTransitionLines.Line]) -> [String] {
        guard !lines.isEmpty else { return ["Speech log: no lines."] }
        let count = CountWording.phrase(lines.count, singular: "line", plural: "lines")
        return ["Speech log, its last \(count), offsets and lengths only:"] + lines.map(\.logged)
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
