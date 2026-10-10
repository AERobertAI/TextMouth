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

    // MARK: - Copy Reading Position's Place

    /// The place Copy Reading Position adds (P08, the user's answer 20), as
    /// Go to Time's field reads a time back: for an audiobook, its time in
    /// the recording, "at 2:13:05 of 9:41:07 in the recording"; for a text
    /// book, its time at its speed, "at 2:10:24 of 4:20:49 at 500 words a
    /// minute".
    static func copiedPlace(_ time: TimeInterval, of length: TimeInterval, _ count: Count) -> String {
        let place = "at \(TimeFormatting.format(time)) of \(TimeFormatting.format(length))"
        switch count {
        case .recording:
            return "\(place) in the recording"
        case .words(let perMinute):
            return "\(place) at \(wordsAMinute(perMinute))"
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

    // MARK: - The Speed Beside Amounts of Time

    /// The speed a book's amounts of time are heard at, which the setting
    /// "Include the speed with time left and total time" names beside them
    /// (P08, `SettingsViewModel.includeSpeedWithTimes`).
    enum ListeningSpeed: Equatable, Sendable {
        /// An audiobook's: its recording played at this multiple of its own
        /// speed.
        case audio(Double)
        /// A text book's: its words at this many words a minute.
        case words(perMinute: Double)
    }

    /// What follows an amount of time shown on screen when `speed` is named:
    /// " at 2.0x" for an audiobook not at 1x, " at 500 words a minute" for a
    /// text book; nothing for an audiobook at 1x, which its times are
    /// already, or while the speed is not named (nil).
    static func shownSpeed(_ speed: ListeningSpeed?) -> String {
        switch speed {
        case .audio(let multiple)?:
            return isNormal(multiple) ? "" : " at \(AudioSpeed.visibleLabel(for: multiple))"
        case .words(let perMinute)?:
            return " at \(wordsAMinute(perMinute))"
        case nil:
            return ""
        }
    }

    /// What follows an amount of time spoken when `speed` is named: " at 2.0
    /// times speed" for an audiobook not at 1x, " at 500 words a minute"
    /// for a text book; nothing otherwise, as for `shownSpeed(_:)`.
    static func spokenSpeed(_ speed: ListeningSpeed?) -> String {
        switch speed {
        case .audio(let multiple)?:
            return isNormal(multiple) ? "" : " at \(AudioSpeed.spokenLabel(for: multiple))"
        case .words(let perMinute)?:
            return " at \(wordsAMinute(perMinute))"
        case nil:
            return ""
        }
    }

    /// The reader's time left as its status row shows it: "3:44:01 left",
    /// or with the speed named, "3:44:01 left at 2.0x".
    static func timeLeftShown(_ formatted: String, _ speed: ListeningSpeed?) -> String {
        "\(formatted) left\(shownSpeed(speed))"
    }

    /// The reader's time left as its status row speaks it: "3 hours, 44
    /// minutes, 1 second remaining at current speed", or with the speed
    /// named, "3 hours, 44 minutes, 1 second remaining at 2.0 times speed".
    static func timeLeftSpoken(_ seconds: TimeInterval, _ speed: ListeningSpeed?) -> String {
        let named = spokenSpeed(speed)
        return "\(TimeFormatting.spoken(seconds)) remaining\(named.isEmpty ? " at current speed" : named)"
    }

    /// The book's total time as the reader's status row shows it: "Total:
    /// 4:50:33", or with the speed named, "Total: 4:50:33 at 2.0x".
    static func totalShown(_ formatted: String, _ speed: ListeningSpeed?) -> String {
        "Total: \(formatted)\(shownSpeed(speed))"
    }

    /// The book's total time as the reader's status row speaks it: "Total
    /// time: 4 hours, 50 minutes, 33 seconds", or with the speed named,
    /// "Total time: 4 hours, 50 minutes, 33 seconds at 2.0 times speed".
    static func totalSpoken(_ seconds: TimeInterval, _ speed: ListeningSpeed?) -> String {
        "Total time: \(TimeFormatting.spoken(seconds))\(spokenSpeed(speed))"
    }

    /// The setting's checkbox in Playback settings.
    static let settingTitle = "Include the speed with time left and total time"

    /// The setting's group in Playback settings.
    static let settingSection = "Times"

    /// What the setting does, as its checkbox's hint says and its caption
    /// shows.
    static let settingHint = "Adds the speed they count at, such as 2.0x for an audiobook not at 1x, "
        + "or 500 words a minute for a text book, in the reader, Where Am I?, Copy Reading Position, "
        + "and the Headings sheet's durations."

    // MARK: - Speeds

    /// A text book's speed as its times name it, in whole words, as the
    /// reader shows its speed: "500 words a minute".
    static func wordsAMinute(_ wordsPerMinute: Double) -> String {
        "\(wholeWords(wordsPerMinute)) words a minute"
    }

    /// Whether `multiple` plays at the recording's own speed, as the player
    /// would snap it.
    private static func isNormal(_ multiple: Double) -> Bool {
        AudioSpeed.normalized(multiple) == AudioSpeed.normal
    }

    /// `wordsPerMinute`'s whole words, its fraction dropped; 0 for a speed
    /// that is no number or too large for one, so no label can trap.
    private static func wholeWords(_ wordsPerMinute: Double) -> Int {
        Int(exactly: wordsPerMinute.rounded(.towardZero)) ?? 0
    }
}
