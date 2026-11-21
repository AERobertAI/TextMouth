import Foundation

/// Tells when direct speech has gone silent while the synthesizer says it is
/// speaking: playing, not paused, and no word reported for several seconds.
///
/// One report (thread 849627, October 2026) says a direct utterance pauses at
/// the screen lock and resumes at unlock, with `isSpeaking` true all the while,
/// so the playback watchdog sees nothing wrong. Nothing is being heard then, so
/// recovering is a natural break, which the user's rule allows: speech never
/// switches from direct to rendered audio in mid-play.
///
/// A recovery repeats words, so the watchdog is armed only once this play's
/// first word has arrived (the engineer's review, F19), and only for a voice
/// shown to report word by word: one that reports no words at all, or a
/// sentence at a time, is never taken for silent. It counts ticks rather than
/// reading a clock, so a suspended app, whose ticks stop, wakes with nothing
/// counted.
///
/// A plain value, so that every condition is tested on the Mac. **Unverified on
/// a phone:** the limits below are guesses until a first run logs real gaps.
struct PhoneAudioWordWatchdog: Equatable, Sendable {
    /// The longest silence at ordinary speeds, in seconds: several words at
    /// any speed, and a sentence's pause, with room to spare.
    static let shortestSilenceLimit: TimeInterval = 8
    /// The longest gap, in seconds, between two reports of a voice that counts
    /// as reporting word by word.
    static let wordByWordGap: TimeInterval = 2
    /// How many such gaps in a row show that a voice reports word by word.
    static let wordByWordReportsNeeded = 3

    /// How long speech may go with no word reported at `wordsPerMinute`: the
    /// shortest limit, or ten average words at a speed so slow that a long word
    /// takes seconds by itself.
    static func silenceLimit(wordsPerMinute: Double) -> TimeInterval {
        guard wordsPerMinute > 0 else { return shortestSilenceLimit }
        return max(shortestSilenceLimit, 10 * 60 / wordsPerMinute)
    }

    /// Seconds between ticks.
    private let tickInterval: TimeInterval
    /// Ticks since the last word was reported or an utterance started.
    private(set) var silentTicks = 0
    /// Whether a word has arrived since this play began (`playStarted()`).
    private(set) var hasHeardThisPlaysFirstWord = false
    /// The voice the reports below count for: nil before any report, and the
    /// empty string for the system's default voice.
    private var reportingVoice: String?
    /// How many reports of `reportingVoice` in a row have come quickly after
    /// the one before, which is how a voice shows that it reports word by word.
    private var quickReports = 0

    /// - Parameter tickInterval: How many seconds pass between calls to `tick`.
    init(tickInterval: TimeInterval) {
        self.tickInterval = tickInterval
    }

    /// A play began: Play, a resume, a seek, or a recovery spoke afresh. The
    /// watchdog waits for its first word.
    mutating func playStarted() {
        hasHeardThisPlaysFirstWord = false
        silentTicks = 0
    }

    /// The synthesizer reported a word of the live utterance, in the voice
    /// `voiceIdentifier` names, nil for the system's default.
    mutating func wordReported(voiceIdentifier: String?) {
        let voice = voiceIdentifier ?? ""
        if reportingVoice != voice {
            reportingVoice = voice
            quickReports = 0
        } else if hasHeardThisPlaysFirstWord {
            // Only a gap between two words of one play is judged: the wait for
            // a play's first word is no word gap.
            if Double(silentTicks) * tickInterval <= Self.wordByWordGap {
                quickReports += 1
            } else {
                // Only gaps in a row count: a voice that reports a sentence at
                // a time has short ones too, whenever two short sentences meet.
                quickReports = 0
            }
        }
        hasHeardThisPlaysFirstWord = true
        silentTicks = 0
    }

    /// An utterance started: the silence is counted from here.
    mutating func utteranceStarted() {
        silentTicks = 0
    }

    /// One tick of the playback watchdog.
    ///
    /// - Parameters:
    ///   - isExpectedToSpeak: Whether direct speech should be heard now, with
    ///     the synthesizer holding it: not paused, stopped, on rendered audio,
    ///     in a sleep fade, or interrupted. Anything else starts the count again.
    ///   - voiceIdentifier: The voice in use, nil for the system's default.
    ///   - wordsPerMinute: The speed in use.
    /// - Returns: True once speech has gone silent for the limit, when the
    ///   caller recovers. The count starts again.
    mutating func tick(isExpectedToSpeak: Bool, voiceIdentifier: String?, wordsPerMinute: Double) -> Bool {
        guard isExpectedToSpeak else {
            silentTicks = 0
            return false
        }
        silentTicks += 1
        guard hasHeardThisPlaysFirstWord,
              reportingVoice == (voiceIdentifier ?? ""),
              quickReports >= Self.wordByWordReportsNeeded,
              Double(silentTicks) * tickInterval >= Self.silenceLimit(wordsPerMinute: wordsPerMinute) else {
            return false
        }
        silentTicks = 0
        return true
    }
}
