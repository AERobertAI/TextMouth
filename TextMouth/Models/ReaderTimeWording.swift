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
        // Translators: Label of the Go to Time field for an audiobook: the time is counted in the recording itself.
        InterfaceText.line("readerTime.recordingTimeFieldLabel", "Time in the recording")
    }

    /// Go to Time's field: "Time in the recording" for an audiobook, and for
    /// a text book its own speed, "Time at 500 words a minute".
    static func timeFieldLabel(_ count: Count) -> String {
        switch count {
        case .recording:
            return recordingTimeFieldLabel
        case .words(let perMinute):
            // Translators: Label of the Go to Time field for a text book. %@ is the reading speed the times count at, such as "500 words a minute".
            return InterfaceText.line("readerTime.timeFieldLabel.words", "Time at \(wordsAMinute(perMinute))")
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
                // Translators: First sentence of the refusal when the time typed in Go to Time is after the end of an audiobook.
                InterfaceText.line("readerTime.pastTheEnd.recording.exceeds", "Time exceeds the recording's length."),
                // Translators: Second sentence of that refusal. %@ is the recording's length spoken in words, such as "9 hours, 41 minutes, 7 seconds".
                InterfaceText.line("readerTime.pastTheEnd.recording.lasts", "The recording lasts \(TimeFormatting.spoken(length))."),
            ])
        case .words:
            return SentenceWording.joined([
                // Translators: First sentence of the refusal when the time typed in Go to Time is after the end of a text book.
                InterfaceText.line("readerTime.pastTheEnd.words.exceeds", "Time exceeds book length."),
                // Translators: Second sentence of that refusal. %@ is the longest time allowed, spoken in words, such as "1 hour".
                InterfaceText.line("readerTime.pastTheEnd.words.maximum", "Maximum is \(TimeFormatting.spoken(length))."),
            ])
        }
    }

    /// What Go to Time announces once it has jumped. An audiobook's names
    /// the recording: "Jumped to 2 hours, 13 minutes, 5 seconds in the
    /// recording." A text book's is as it was.
    static func jumped(to time: TimeInterval, _ count: Count) -> String {
        switch count {
        case .recording:
            // Translators: Announcement after Go to Time jumped in an audiobook. %@ is the time spoken in words, such as "2 hours, 13 minutes, 5 seconds".
            return InterfaceText.line("readerTime.jumped.recording", "Jumped to \(TimeFormatting.spoken(time)) in the recording.")
        case .words:
            // Translators: Announcement after Go to Time jumped in a text book. %@ is the time spoken in words, such as "2 hours, 13 minutes, 5 seconds".
            return InterfaceText.line("readerTime.jumped.words", "Jumped to \(TimeFormatting.spoken(time)).")
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
            // Translators: Part of the text Copy Reading Position copies, for an audiobook. %1$@ is the time reached and %2$@ the recording's length, both written as clock times such as 2:13:05.
            return InterfaceText.line("readerTime.copiedPlace.recording", "at \(at) of \(of) in the recording")
        case .words(let perMinute):
            // Translators: Part of the text Copy Reading Position copies, for a text book. %1$@ is the time reached and %2$@ the book's length, both written as clock times such as 2:10:24; %3$@ is the reading speed they count at, such as "500 words a minute".
            return InterfaceText.line("readerTime.copiedPlace.words", "at \(at) of \(of) at \(wordsAMinute(perMinute))")
        }
    }

    // MARK: - Go to Percent

    /// Go to Percent's field, named as the status row's percent is spoken
    /// ("22.9% through the book").
    static var percentFieldLabel: String {
        // Translators: Label of the Go to Percent field, where the user types how far through the book to jump.
        InterfaceText.line("readerTime.percentFieldLabel", "Percent through the book")
    }

    /// What Go to Percent's field takes, as its hint says.
    static var percentFieldHint: String {
        // Translators: Hint of the Go to Percent field: what the user may type. 47.5 is an example number; write it as the language writes numbers.
        InterfaceText.line("readerTime.percentFieldHint", "Type a percent from 0 to 100, such as 47.5.")
    }

    /// What Go to Percent announces once it has jumped: "Jumped to 47.5
    /// percent."
    static func jumped(toPercent percent: Double) -> String {
        // One decimal place, written as the region writes numbers.
        let shown = percent.formatted(.number.precision(.fractionLength(1)).locale(InterfaceLanguage.current.locale))
        // Translators: Announcement after Go to Percent jumped. %@ is the percent reached with one decimal place, such as 47.5.
        return InterfaceText.line("readerTime.jumped", "Jumped to \(shown) percent.")
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
        // Translators: An amount of time followed by the speed it counts at. %1$@ is the amount with its words, such as "3:44:01 left" or "Total time: 4 hours"; %2$@ is the speed, such as "2.0x", "2.0 times speed" or "500 words a minute".
        return InterfaceText.line("common.valueAtValue", "\(amount) at \(speedName)")
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
        // Translators: Time left in the book as Where Am I? speaks it. %@ is the time in words, such as "3 hours".
        amount(InterfaceText.line("common.valueRemaining", "\(spokenTime) remaining"),
               at: spokenSpeedName(speed))
    }

    /// The reader's time left as its status row shows it: "3:44:01 left",
    /// or with the speed named, "3:44:01 left at 2.0x".
    static func timeLeftShown(_ formatted: String, _ speed: ListeningSpeed?) -> String {
        // Translators: Time left in the book as the reader's status row shows it. %@ is a clock time such as 3:44:01.
        amount(InterfaceText.line("common.valueLeft", "\(formatted) left"),
               at: shownSpeedName(speed))
    }

    /// The reader's time left as its status row speaks it: "3 hours, 44
    /// minutes, 1 second remaining at current speed", or with the speed
    /// named, "3 hours, 44 minutes, 1 second remaining at 2.0 times speed".
    static func timeLeftSpoken(_ seconds: TimeInterval, _ speed: ListeningSpeed?) -> String {
        let spokenTime = TimeFormatting.spoken(seconds)
        guard spokenSpeedName(speed) != nil else {
            // Translators: Time left in the book as the reader's status row speaks it when no speed is named: it counts at the speed now set. %@ is the time in words, such as "3 hours, 44 minutes, 1 second".
            return InterfaceText.line("readerTime.timeLeftSpoken", "\(spokenTime) remaining at current speed")
        }
        return remainingSpoken(spokenTime, speed: speed)
    }

    /// The book's total time as the reader's status row shows it: "Total:
    /// 4:50:33", or with the speed named, "Total: 4:50:33 at 2.0x".
    static func totalShown(_ formatted: String, _ speed: ListeningSpeed?) -> String {
        // Translators: The book's total time as the reader's status row shows it. %@ is a clock time such as 4:50:33.
        amount(InterfaceText.line("readerTime.totalShown", "Total: \(formatted)"),
               at: shownSpeedName(speed))
    }

    /// The book's total time as the reader's status row speaks it: "Total
    /// time: 4 hours, 50 minutes, 33 seconds", or with the speed named,
    /// "Total time: 4 hours, 50 minutes, 33 seconds at 2.0 times speed".
    static func totalSpoken(_ seconds: TimeInterval, _ speed: ListeningSpeed?) -> String {
        // Translators: The book's total time as the reader's status row speaks it. %@ is the time in words, such as "4 hours, 50 minutes, 33 seconds".
        amount(InterfaceText.line("readerTime.totalSpoken", "Total time: \(TimeFormatting.spoken(seconds))"),
               at: spokenSpeedName(speed))
    }

    /// The setting's checkbox in Playback settings.
    static var settingTitle: String {
        // Translators: Label of the Playback setting's checkbox that names the speed beside the time left and the total time.
        InterfaceText.line("readerTime.settingTitle", "Include the speed with time left and total time")
    }

    /// The setting's group in Playback settings.
    static var settingSection: String {
        // Translators: Heading of the group in Playback settings that holds the setting about naming the speed beside times.
        InterfaceText.line("readerTime.settingSection", "Times")
    }

    /// What the setting does, as its checkbox's hint says and its caption
    /// shows.
    static var settingHint: String {
        // Translators: Hint and caption of the Playback setting that names the speed beside times. 2.0x and 500 are examples; Where Am I?, Copy Reading Position and the Headings sheet are names of commands and a sheet in the app.
        InterfaceText.line("readerTime.settingHint", "Adds the speed they count at, such as 2.0x for an audiobook not at 1x, or 500 words a minute for a text book, in the reader, Where Am I?, Copy Reading Position, and the Headings sheet's durations.")
    }

    // MARK: - Speeds

    /// A text book's speed as its times name it, in whole words, as the
    /// reader shows its speed: "500 words a minute".
    static func wordsAMinute(_ wordsPerMinute: Double) -> String {
        let words = wholeWords(wordsPerMinute)
        // Translators: A text book's reading speed. %lld is the number of words read in a minute, such as 500.
        return InterfaceText.line("readerTime.wordsAMinute", "\(number: words) words a minute")
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
