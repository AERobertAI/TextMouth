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
    static var recordingTimeFieldLabel: String {
        String(localized: "Time in the recording",
               comment: "Label of the Go to Time field for an audiobook: the time is counted in the recording itself.")
    }

    /// Go to Time's field: "Time in the recording" for an audiobook, and for
    /// a text book its own speed, "Time at 500 words a minute".
    static func timeFieldLabel(_ count: Count) -> String {
        switch count {
        case .recording:
            return recordingTimeFieldLabel
        case .words(let perMinute):
            return String(localized: "Time at \(wordsAMinute(perMinute))",
                          comment: "Label of the Go to Time field for a text book. %@ is the reading speed the times count at, such as \"500 words a minute\".")
        }
    }

    /// What Go to Time's field takes, as its hint says: a time written as
    /// people write one, as the audio editor's Go to Time asks for it.
    static var timeFieldHint: String { TimeEntry.howToType }

    /// Go to Time's refusal of a time after the end. An audiobook's names
    /// the recording: "Time exceeds the recording's length. The recording
    /// lasts 9 hours, 41 minutes, 7 seconds." A text book's is as it was.
    static func pastTheEnd(_ length: TimeInterval, _ count: Count) -> String {
        switch count {
        case .recording:
            return SentenceWording.joined([
                String(localized: "Time exceeds the recording's length.",
                       comment: "First sentence of the refusal when the time typed in Go to Time is after the end of an audiobook."),
                String(localized: "The recording lasts \(TimeFormatting.spoken(length)).",
                       comment: "Second sentence of that refusal. %@ is the recording's length spoken in words, such as \"9 hours, 41 minutes, 7 seconds\"."),
            ])
        case .words:
            return SentenceWording.joined([
                String(localized: "Time exceeds book length.",
                       comment: "First sentence of the refusal when the time typed in Go to Time is after the end of a text book."),
                String(localized: "Maximum is \(TimeFormatting.spoken(length)).",
                       comment: "Second sentence of that refusal. %@ is the longest time allowed, spoken in words, such as \"1 hour\"."),
            ])
        }
    }

    /// What Go to Time announces once it has jumped. An audiobook's names
    /// the recording: "Jumped to 2 hours, 13 minutes, 5 seconds in the
    /// recording." A text book's is as it was.
    static func jumped(to time: TimeInterval, _ count: Count) -> String {
        switch count {
        case .recording:
            return String(localized: "Jumped to \(TimeFormatting.spoken(time)) in the recording.",
                          comment: "Announcement after Go to Time jumped in an audiobook. %@ is the time spoken in words, such as \"2 hours, 13 minutes, 5 seconds\".")
        case .words:
            return String(localized: "Jumped to \(TimeFormatting.spoken(time)).",
                          comment: "Announcement after Go to Time jumped in a text book. %@ is the time spoken in words, such as \"2 hours, 13 minutes, 5 seconds\".")
        }
    }

    // MARK: - Copy Reading Position's Place

    /// The place Copy Reading Position adds (P08, the user's answer 20), as
    /// Go to Time's field reads a time back: for an audiobook, its time in
    /// the recording, "at 2:13:05 of 9:41:07 in the recording"; for a text
    /// book, its time at its speed, "at 2:10:24 of 4:20:49 at 500 words a
    /// minute".
    static func copiedPlace(_ time: TimeInterval, of length: TimeInterval, _ count: Count) -> String {
        let at = TimeFormatting.format(time)
        let of = TimeFormatting.format(length)
        switch count {
        case .recording:
            return String(localized: "at \(at) of \(of) in the recording",
                          comment: "Part of the text Copy Reading Position copies, for an audiobook. %1$@ is the time reached and %2$@ the recording's length, both written as clock times such as 2:13:05.")
        case .words(let perMinute):
            return String(localized: "at \(at) of \(of) at \(wordsAMinute(perMinute))",
                          comment: "Part of the text Copy Reading Position copies, for a text book. %1$@ is the time reached and %2$@ the book's length, both written as clock times such as 2:10:24; %3$@ is the reading speed they count at, such as \"500 words a minute\".")
        }
    }

    // MARK: - Go to Percent

    /// Go to Percent's field, named as the status row's percent is spoken
    /// ("22.9% through the book").
    static var percentFieldLabel: String {
        String(localized: "Percent through the book",
               comment: "Label of the Go to Percent field, where the user types how far through the book to jump.")
    }

    /// What Go to Percent's field takes, as its hint says.
    static var percentFieldHint: String {
        String(localized: "Type a percent from 0 to 100, such as 47.5.",
               comment: "Hint of the Go to Percent field: what the user may type. 47.5 is an example number; write it as the language writes numbers.")
    }

    /// What Go to Percent announces once it has jumped: "Jumped to 47.5
    /// percent."
    static func jumped(toPercent percent: Double) -> String {
        // One decimal place, written as the region writes numbers.
        let shown = percent.formatted(.number.precision(.fractionLength(1)))
        return String(localized: "Jumped to \(shown) percent.",
                      comment: "Announcement after Go to Percent jumped. %@ is the percent reached with one decimal place, such as 47.5.")
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

    /// The speed as an amount of time shown on screen names it: "2.0x" for
    /// an audiobook not at 1x, "500 words a minute" for a text book; nil for
    /// an audiobook at 1x, which its times are already, or while the speed
    /// is not named (nil).
    private static func shownSpeedName(_ speed: ListeningSpeed?) -> String? {
        switch speed {
        case .audio(let multiple)?:
            return isNormal(multiple) ? nil : AudioSpeed.visibleLabel(for: multiple)
        case .words(let perMinute)?:
            return wordsAMinute(perMinute)
        case nil:
            return nil
        }
    }

    /// The speed as an amount of time spoken names it: "2.0 times speed" for
    /// an audiobook not at 1x, "500 words a minute" for a text book; nil
    /// otherwise, as for `shownSpeedName(_:)`.
    private static func spokenSpeedName(_ speed: ListeningSpeed?) -> String? {
        switch speed {
        case .audio(let multiple)?:
            return isNormal(multiple) ? nil : AudioSpeed.spokenLabel(for: multiple)
        case .words(let perMinute)?:
            return wordsAMinute(perMinute)
        case nil:
            return nil
        }
    }

    /// An amount of time with the speed it counts at, "3:44:01 left at
    /// 2.0x"; the amount alone when there is no speed to name.
    private static func amount(_ amount: String, at speedName: String?) -> String {
        guard let speedName else { return amount }
        return String(localized: "\(amount) at \(speedName)",
                      comment: "An amount of time followed by the speed it counts at. %1$@ is the amount with its words, such as \"3:44:01 left\" or \"Total time: 4 hours\"; %2$@ is the speed, such as \"2.0x\", \"2.0 times speed\" or \"500 words a minute\".")
    }

    /// An amount of time as the screen shows it, with the speed named when
    /// the setting asks (the Headings sheet's durations): "3:44:01 at 2.0x",
    /// and "3:44:01" for an audiobook at 1x or when no speed is named.
    static func shown(_ time: String, speed: ListeningSpeed?) -> String {
        amount(time, at: shownSpeedName(speed))
    }

    /// An amount of time as VoiceOver speaks it, with the speed named when
    /// the setting asks: "3 hours at 2.0 times speed".
    static func spoken(_ time: String, speed: ListeningSpeed?) -> String {
        amount(time, at: spokenSpeedName(speed))
    }

    /// The summaries' time left in the book, spoken: "3 hours remaining", or
    /// with the speed named, "3 hours remaining at 2.0 times speed".
    static func remainingSpoken(_ spokenTime: String, speed: ListeningSpeed?) -> String {
        amount(String(localized: "\(spokenTime) remaining",
                      comment: "Time left in the book as Where Am I? speaks it. %@ is the time in words, such as \"3 hours\"."),
               at: spokenSpeedName(speed))
    }

    /// The reader's time left as its status row shows it: "3:44:01 left",
    /// or with the speed named, "3:44:01 left at 2.0x".
    static func timeLeftShown(_ formatted: String, _ speed: ListeningSpeed?) -> String {
        amount(String(localized: "\(formatted) left",
                      comment: "Time left in the book as the reader's status row shows it. %@ is a clock time such as 3:44:01."),
               at: shownSpeedName(speed))
    }

    /// The reader's time left as its status row speaks it: "3 hours, 44
    /// minutes, 1 second remaining at current speed", or with the speed
    /// named, "3 hours, 44 minutes, 1 second remaining at 2.0 times speed".
    static func timeLeftSpoken(_ seconds: TimeInterval, _ speed: ListeningSpeed?) -> String {
        let spokenTime = TimeFormatting.spoken(seconds)
        guard spokenSpeedName(speed) != nil else {
            return String(localized: "\(spokenTime) remaining at current speed",
                          comment: "Time left in the book as the reader's status row speaks it when no speed is named: it counts at the speed now set. %@ is the time in words, such as \"3 hours, 44 minutes, 1 second\".")
        }
        return remainingSpoken(spokenTime, speed: speed)
    }

    /// The book's total time as the reader's status row shows it: "Total:
    /// 4:50:33", or with the speed named, "Total: 4:50:33 at 2.0x".
    static func totalShown(_ formatted: String, _ speed: ListeningSpeed?) -> String {
        amount(String(localized: "Total: \(formatted)",
                      comment: "The book's total time as the reader's status row shows it. %@ is a clock time such as 4:50:33."),
               at: shownSpeedName(speed))
    }

    /// The book's total time as the reader's status row speaks it: "Total
    /// time: 4 hours, 50 minutes, 33 seconds", or with the speed named,
    /// "Total time: 4 hours, 50 minutes, 33 seconds at 2.0 times speed".
    static func totalSpoken(_ seconds: TimeInterval, _ speed: ListeningSpeed?) -> String {
        amount(String(localized: "Total time: \(TimeFormatting.spoken(seconds))",
                      comment: "The book's total time as the reader's status row speaks it. %@ is the time in words, such as \"4 hours, 50 minutes, 33 seconds\"."),
               at: spokenSpeedName(speed))
    }

    /// The setting's checkbox in Playback settings.
    static var settingTitle: String {
        String(localized: "Include the speed with time left and total time",
               comment: "Label of the Playback setting's checkbox that names the speed beside the time left and the total time.")
    }

    /// The setting's group in Playback settings.
    static var settingSection: String {
        String(localized: "Times",
               comment: "Heading of the group in Playback settings that holds the setting about naming the speed beside times.")
    }

    /// What the setting does, as its checkbox's hint says and its caption
    /// shows.
    static var settingHint: String {
        String(localized: "Adds the speed they count at, such as 2.0x for an audiobook not at 1x, or 500 words a minute for a text book, in the reader, Where Am I?, Copy Reading Position, and the Headings sheet's durations.",
               comment: "Hint and caption of the Playback setting that names the speed beside times. 2.0x and 500 are examples; Where Am I?, Copy Reading Position and the Headings sheet are names of commands and a sheet in the app.")
    }

    // MARK: - Speeds

    /// A text book's speed as its times name it, in whole words, as the
    /// reader shows its speed: "500 words a minute".
    static func wordsAMinute(_ wordsPerMinute: Double) -> String {
        let words = wholeWords(wordsPerMinute)
        return String(localized: "\(words) words a minute",
                      comment: "A text book's reading speed. %lld is the number of words read in a minute, such as 500.")
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
