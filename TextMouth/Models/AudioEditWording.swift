import Foundation

/// The words the audio editor uses for edits (FR04), shared by the Edit
/// menu's undo and redo items, VoiceOver's announcements, and the braille
/// display, so each says the same thing the same way. Times keep tenths of
/// a second, which an edit needs and `TimeFormatting.spoken` leaves out.
enum AudioEditWording {
    /// `seconds` as spoken and brailled, to the tenth: "2.5 seconds",
    /// "1 second", "1 minute, 4.2 seconds". A length under a twentieth of a
    /// second keeps hundredths, so it never reads as nothing. With
    /// `titleCase`, as menu items are written: "2.5 Seconds".
    static func duration(_ seconds: TimeInterval, titleCase: Bool = false) -> String {
        // A length beyond a million hours is no length of audio, and would
        // overflow the whole numbers below.
        guard seconds.isFinite, seconds >= 0, seconds < 3.6e9 else {
            return titleCase
                ? String(localized: "Unknown Length", comment: "A length of audio that is no length (not a finite number of seconds), as a menu item's title-cased words, such as the Undo item's \"Cut Unknown Length\".")
                : String(localized: "unknown length", comment: "A length of audio that is no length (not a finite number of seconds), said in a sentence, such as \"Cut unknown length.\"")
        }
        let tenths = (seconds * 10).rounded() / 10
        let shown = tenths == 0 && seconds > 0 ? (seconds * 100).rounded() / 100 : tenths
        let hours = Int(shown / 3_600)
        let minutes = Int(shown.truncatingRemainder(dividingBy: 3_600) / 60)
        let rest = shown - Double(hours * 3_600 + minutes * 60)

        var parts: [String] = []
        if hours > 0 { parts.append(CountWording.hours(hours)) }
        if minutes > 0 { parts.append(CountWording.minutes(minutes)) }
        // Subtracting whole minutes can leave a trace of rounding error, so
        // the seconds are compared to within half a thousandth.
        if rest > 0.000_5 || parts.isEmpty {
            parts.append(secondsPart(rest))
        }
        // The parts are one spoken list without "and": "1 minute, 4.2
        // seconds", in each language's own list punctuation.
        let phrase = parts.formatted(.list(type: .and, width: .narrow))
        return titleCase && capitalizesTitles ? phrase.capitalized(with: .current) : phrase
    }

    /// Whether the interface language capitalizes each word of a menu title,
    /// as English does ("Cut 2.5 Seconds"); other languages write a title in
    /// their ordinary case.
    private static var capitalizesTitles: Bool {
        Locale.current.language.languageCode?.identifier == "en" // l10n: no (a language code)
    }

    /// The seconds of a duration: counted, as "1 second" or "4 seconds",
    /// when whole, and with its decimals, as "4.2 seconds", when not.
    private static func secondsPart(_ rest: Double) -> String {
        if abs(rest - rest.rounded()) < 0.000_5 {
            return CountWording.seconds(Int(rest.rounded()))
        }
        // A decimal has no plural form of its own, so it is one string
        // around the formatted number.
        return String(localized: "\(number(rest)) seconds",
                      comment: "A number of seconds with decimals inside a spoken duration, such as \"4.2 seconds\" in \"12 minutes, 4.2 seconds\". %@ is the already formatted number.")
    }

    /// `value` with at most two decimal places and no trailing zeros, in the
    /// region's number format: "4.2", "4", "0.04".
    private static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    /// The edit's name as the Edit menu gives it after "Undo" or "Redo", and
    /// VoiceOver reads it: "Cut 2.5 Seconds", "Insert 1 Second of Silence".
    static func actionName(_ edit: AudioEdit) -> String {
        switch edit {
        case .trimStart:
            return String(localized: "Trim Start", comment: "Name of an edit, as the Undo and Redo menu items and VoiceOver say it after \"Undo\" or \"Redo\": trimming the start of the audio.")
        case .trimEnd:
            return String(localized: "Trim End", comment: "Name of an edit, as the Undo and Redo menu items and VoiceOver say it after \"Undo\" or \"Redo\": trimming the end of the audio.")
        case .cut(let range):
            return String(localized: "Cut \(duration(range.duration, titleCase: true))",
                          comment: "Name of an edit, as the Undo and Redo menu items say it after \"Undo\" or \"Redo\": cutting a stretch of audio. %@ is its length in title-cased words, such as \"2.5 Seconds\".")
        case .move(let range, _):
            return String(localized: "Move \(duration(range.duration, titleCase: true))",
                          comment: "Name of an edit, as the Undo and Redo menu items say it after \"Undo\" or \"Redo\": moving a stretch of audio. %@ is its length in title-cased words, such as \"2.5 Seconds\".")
        case .insertSilence(_, let length):
            return String(localized: "Insert \(duration(length, titleCase: true)) of Silence",
                          comment: "Name of an edit, as the Undo and Redo menu items say it after \"Undo\" or \"Redo\": inserting silence. %@ is its length in title-cased words, such as \"1 Second\".")
        case .replace(let range, _):
            return String(localized: "Replace \(duration(range.duration, titleCase: true))",
                          comment: "Name of an edit, as the Undo and Redo menu items say it after \"Undo\" or \"Redo\": replacing a stretch of audio with a new recording. %@ is the replaced length in title-cased words, such as \"2.5 Seconds\".")
        case .insert(_, let take):
            return String(localized: "Insert \(duration(take.range.duration, titleCase: true)) of Audio",
                          comment: "Name of an edit, as the Undo and Redo menu items say it after \"Undo\" or \"Redo\": inserting a new recording. %@ is its length in title-cased words, such as \"2.5 Seconds\".")
        case .setChapter:
            return String(localized: "Set Chapter Marker", comment: "Name of an edit, as the Undo and Redo menu items and VoiceOver say it after \"Undo\" or \"Redo\": setting a chapter marker.")
        case .removeChapter:
            return String(localized: "Remove Chapter Marker", comment: "Name of an edit, as the Undo and Redo menu items and VoiceOver say it after \"Undo\" or \"Redo\": removing a chapter marker.")
        case .filter:
            return String(localized: "Apply Filter", comment: "Name of an edit, as the Undo and Redo menu items say it after \"Undo\" or \"Redo\"; also the title of the audio editor's filter sheet.")
        case .gain(let decibels, _):
            return String(localized: "Change Volume by \(signedDecibels(decibels))",
                          comment: "Name of an edit, as the Undo and Redo menu items say it after \"Undo\" or \"Redo\": changing the volume. %@ is the change with its sign, such as \"+3 dB\".")
        }
    }

    /// A level change with its sign, as people say it: "+3 dB", "-6 dB",
    /// "+1.5 dB".
    static func signedDecibels(_ decibels: Double) -> String {
        let sign = decibels > 0 ? "+" : (decibels < 0 ? "-" : "")
        return String(localized: "\(sign)\(number(abs(decibels))) dB",
                      comment: "A level change in decibels with its sign, such as \"+3 dB\" or \"-6 dB\". %1$@ is the sign, \"+\" or \"-\" or nothing, and %2$@ the number, already formatted.")
    }

    /// Why undo can go no further, as a sentence, or nil when it can: what
    /// the editor says when Undo is asked for and can't, and the hint of a
    /// dimmed Undo.
    static func undoLimit(_ limit: AudioEditUndoLimit) -> String? {
        switch limit {
        case .canUndo:
            return nil
        case .nothingToUndo:
            return String(localized: "There's nothing to undo.", comment: "Said when Undo is asked for and there is no edit to undo, and the hint of a dimmed Undo in the audio editor.")
        case .originalDeleted(let date):
            return String(localized: "The original audio was deleted on \(date.formatted(date: .long, time: .omitted)), so edits saved before then can't be undone.",
                          comment: "Said when Undo can't reach edits already saved, and the hint of a dimmed Undo in the audio editor: the book's original audio was deleted. %@ is the date it was deleted, in long form.")
        case .editedInPlace:
            return String(localized: "No original audio is kept for this book, so saved edits can't be undone.",
                          comment: "Said when Undo can't reach edits already saved, and the hint of a dimmed Undo in the audio editor: the book keeps no original audio.")
        }
    }
}
