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
        guard seconds.isFinite, seconds >= 0, seconds < 3.6e9 else { return titleCase ? "Unknown Length" : "unknown length" }
        let tenths = (seconds * 10).rounded() / 10
        let shown = tenths == 0 && seconds > 0 ? (seconds * 100).rounded() / 100 : tenths
        let hours = Int(shown / 3_600)
        let minutes = Int(shown.truncatingRemainder(dividingBy: 3_600) / 60)
        let rest = shown - Double(hours * 3_600 + minutes * 60)

        var parts: [String] = []
        if hours > 0 { parts.append(CountWording.phrase(hours, singular: "hour", plural: "hours")) }
        if minutes > 0 { parts.append(CountWording.phrase(minutes, singular: "minute", plural: "minutes")) }
        // Subtracting whole minutes can leave a trace of rounding error, so
        // the seconds are compared to within half a thousandth.
        if rest > 0.000_5 || parts.isEmpty {
            parts.append("\(number(rest)) \(abs(rest - 1) < 0.000_5 ? "second" : "seconds")")
        }
        let phrase = parts.joined(separator: ", ")
        return titleCase ? phrase.capitalized(with: Locale(identifier: "en_US")) : phrase
    }

    /// `value` with at most two decimal places and no trailing zeros: "4.2",
    /// "4", "0.04".
    private static func number(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// The edit's name as the Edit menu gives it after "Undo" or "Redo", and
    /// VoiceOver reads it: "Cut 2.5 Seconds", "Insert 1 Second of Silence".
    static func actionName(_ edit: AudioEdit) -> String {
        switch edit {
        case .trimStart:
            return "Trim Start"
        case .trimEnd:
            return "Trim End"
        case .cut(let range):
            return "Cut \(duration(range.duration, titleCase: true))"
        case .move(let range, _):
            return "Move \(duration(range.duration, titleCase: true))"
        case .insertSilence(_, let length):
            return "Insert \(duration(length, titleCase: true)) of Silence"
        case .replace(let range, _):
            return "Replace \(duration(range.duration, titleCase: true))"
        case .insert(_, let take):
            return "Insert \(duration(take.range.duration, titleCase: true)) of Audio"
        case .setChapter:
            return "Set Chapter Marker"
        case .removeChapter:
            return "Remove Chapter Marker"
        case .filter:
            return "Apply Filter"
        case .gain(let decibels, _):
            return "Change Volume by \(signedDecibels(decibels))"
        }
    }

    /// A level change with its sign, as people say it: "+3 dB", "-6 dB",
    /// "+1.5 dB".
    static func signedDecibels(_ decibels: Double) -> String {
        let sign = decibels > 0 ? "+" : (decibels < 0 ? "-" : "")
        return "\(sign)\(number(abs(decibels))) dB"
    }

    /// Why undo can go no further, as a sentence, or nil when it can: what
    /// the editor says when Undo is asked for and can't, and the hint of a
    /// dimmed Undo.
    static func undoLimit(_ limit: AudioEditUndoLimit) -> String? {
        switch limit {
        case .canUndo:
            return nil
        case .nothingToUndo:
            return "There's nothing to undo."
        case .originalDeleted(let date):
            return "The original audio was deleted on \(date.formatted(date: .long, time: .omitted)), "
                + "so edits saved before then can't be undone."
        case .editedInPlace:
            return "No original audio is kept for this book, so saved edits can't be undone."
        }
    }
}
