import Foundation

/// What the reader says about its times (P08): Go to Time's and Go to
/// Percent's fields, what they refuse, and what a jump announces. Every
/// sentence is shown and spoken alike, and pinned by tests.
enum ReaderTimeWording {
    /// How a book's times are counted, which the words about them name.
    enum Count: Equatable, Sendable {
        /// An audiobook's: its recording's own time, whatever its speed.
        case recording
        /// A text book's: its words at this many words a minute.
        case words(perMinute: Double)
    }

    // MARK: - Go to Time

    /// Go to Time's field for an audiobook.
    static let recordingTimeFieldLabel = "Time in the recording"

    /// Go to Time's field: "Time in the recording" for an audiobook, and for
    /// a text book its own speed, "Time at 500 words a minute".
    static func timeFieldLabel(_ count: Count) -> String {
        switch count {
        case .recording:
            return recordingTimeFieldLabel
        case .words(let perMinute):
            return "Time at \(wordsAMinute(perMinute))"
        }
    }

    /// What Go to Time's field takes, as its hint says: a time written as
    /// people write one, as the audio editor's Go to Time asks for it.
    static let timeFieldHint = TimeEntry.howToType

    /// Go to Time's refusal of a time after the end. An audiobook's names
    /// the recording: "Time exceeds the recording's length. The recording
    /// lasts 9 hours, 41 minutes, 7 seconds." A text book's is as it was.
    static func pastTheEnd(_ length: TimeInterval, _ count: Count) -> String {
        switch count {
        case .recording:
            return "Time exceeds the recording's length. The recording lasts \(TimeFormatting.spoken(length))."
        case .words:
            return "Time exceeds book length. Maximum is \(TimeFormatting.spoken(length))."
        }
    }

    /// What Go to Time announces once it has jumped. An audiobook's names
    /// the recording: "Jumped to 2 hours, 13 minutes, 5 seconds in the
    /// recording." A text book's is as it was.
    static func jumped(to time: TimeInterval, _ count: Count) -> String {
        switch count {
        case .recording:
            return "Jumped to \(TimeFormatting.spoken(time)) in the recording."
        case .words:
            return "Jumped to \(TimeFormatting.spoken(time))."
        }
    }

    // MARK: - Go to Percent

    /// Go to Percent's field, named as the status row's percent is spoken
    /// ("22.9% through the book").
    static let percentFieldLabel = "Percent through the book"

    /// What Go to Percent's field takes, as its hint says.
    static let percentFieldHint = "Type a percent from 0 to 100, such as 47.5."

    /// What Go to Percent announces once it has jumped: "Jumped to 47.5
    /// percent."
    static func jumped(toPercent percent: Double) -> String {
        String(format: "Jumped to %.1f percent.", percent)
    }

    // MARK: - Speeds

    /// A text book's speed as its times name it, in whole words, as the
    /// reader shows its speed: "500 words a minute".
    static func wordsAMinute(_ wordsPerMinute: Double) -> String {
        "\(wholeWords(wordsPerMinute)) words a minute"
    }

    /// `wordsPerMinute`'s whole words, its fraction dropped; 0 for a speed
    /// that is no number or too large for one, so no label can trap.
    private static func wholeWords(_ wordsPerMinute: Double) -> Int {
        Int(exactly: wordsPerMinute.rounded(.towardZero)) ?? 0
    }
}
