import Foundation

// The pure half of the voice sweep (TODO P09): the fixed sample every voice
// renders, one voice's result, the circuit breaker that spares a wedged speech
// service the rest of the run, and the Markdown report that is read with
// VoiceOver and a braille display. Nothing here touches a synthesizer, so
// `VoiceSweepReportTests` runs on every Mac; `VoiceSweepTests` does the
// rendering.

// MARK: - The sample

/// The text every voice renders, the same on every run so that the voices and
/// the runs can be compared. It holds four kinds of text that voices handle
/// differently: numbers with a time and a date, punctuation, a bracketed
/// aside, and one long sentence of about 60 words with commas.
enum VoiceSweepSample {
    /// Numbers, a time, a date, and a telephone number.
    static let numbers = "The ferry leaves at 3:45 p.m. on March 14, 2026, from berth 12; call 555-0134 for 2 or 3 spare seats."

    /// Ellipsis, interrobang, parentheses, a currency amount, a spaced dash,
    /// and a decimal comma.
    static let punctuation = "Wait... what?! He said (quietly) that it cost $4.50 - or was it 4,50 euros?"

    /// An aside in square brackets.
    static let aside = "[An aside, in brackets, that the speech should handle.]"

    /// One sentence of 65 words with a dozen commas, long enough to show how a
    /// voice breathes.
    static let longSentence =
        "When the last of the passengers had finally found their seats, and the crew, who had been shouting over "
        + "the engine since dawn, had counted the crates, the bags, the two nervous goats, and the one enormous, "
        + "slightly damp piano, the captain, without so much as a glance at the sky, pulled the long brass lever "
        + "and let the ferry drift out into the channel."

    /// The whole sample: the four parts, in order, one space apart.
    static let text = [numbers, punctuation, aside, longSentence].joined(separator: " ")
}

// MARK: - One voice's result

/// How one voice's render ended.
enum VoiceSweepOutcome: String, Equatable, Sendable {
    /// The render finished and wrote audio.
    case ok
    /// The render ended, finished or cancelled, with no audio: a refusal.
    case noAudio = "no audio"
    /// The render did not end within the watchdog interval.
    case timedOut = "timed out"
    /// The render was cancelled after some audio had been written.
    case stoppedEarly = "stopped early"
    /// The sweep stopped before this voice (the breaker tripped).
    case notTried = "not tried"
}

/// What the sweep learned about one voice. A plain value so that the report is
/// testable without a synthesizer.
struct VoiceSweepResult: Equatable, Sendable {
    /// The voice's identifier, such as `com.apple.voice.compact.en-US.Samantha`.
    let identifier: String
    /// The voice's name, as the voice list shows it.
    let name: String
    /// The voice's language tag, such as `en-US`.
    let language: String
    /// The voice's quality in words: `default`, `enhanced`, or `premium`.
    let quality: String
    /// How the render ended.
    let outcome: VoiceSweepOutcome
    /// The audio buffers the render wrote.
    let buffers: Int
    /// The audio frames the render wrote.
    let frames: Int
    /// The sample rate of the audio, in Hz; 0 when no audio was written.
    let sampleRate: Double
    /// How long the render took on the clock, in seconds.
    let wallSeconds: Double
    /// A word of explanation (what went wrong, or a fact about the voice);
    /// empty when there is none.
    let note: String

    /// The length of the audio in seconds (frames divided by the sample
    /// rate), or 0 when there is no audio or no rate.
    var durationSeconds: Double {
        sampleRate > 0 ? Double(frames) / sampleRate : 0
    }

    /// The result of rendering the sample with `voice`.
    ///
    /// - Parameters:
    ///   - end: How the synthesizer ended the render, or nil when it never
    ///     did within the watchdog interval.
    ///   - buffers: The buffers written.
    ///   - frames: The frames written.
    ///   - sampleRate: The rate of the first buffer, or 0 when none came.
    ///   - wallSeconds: How long the render ran on the clock.
    ///   - watchdogSeconds: The interval the render was given, for the note.
    static func measured(
        _ voice: VoiceSweepVoice,
        end: OfflineRenderProbe.End?,
        buffers: Int,
        frames: Int,
        sampleRate: Double,
        wallSeconds: Double,
        watchdogSeconds: Double
    ) -> VoiceSweepResult {
        let outcome = VoiceSweepOutcome.classify(end: end, frames: frames)
        let problem: String
        switch outcome {
        case .ok, .notTried:
            problem = ""
        case .noAudio:
            problem = "The speech engine ended the render without writing any audio."
        case .timedOut:
            problem = "The render did not end within \(Int(watchdogSeconds.rounded())) seconds, "
                + "after \(frames) frames."
        case .stoppedEarly:
            problem = "The speech engine cancelled the render after \(frames) frames."
        }
        return VoiceSweepResult(
            identifier: voice.identifier, name: voice.name, language: voice.language, quality: voice.quality,
            outcome: outcome, buffers: buffers, frames: frames, sampleRate: sampleRate,
            wallSeconds: wallSeconds, note: [problem, voice.note].filter { !$0.isEmpty }.joined(separator: " ")
        )
    }

    /// The result for a voice the sweep did not reach.
    static func notTried(_ voice: VoiceSweepVoice) -> VoiceSweepResult {
        VoiceSweepResult(
            identifier: voice.identifier, name: voice.name, language: voice.language, quality: voice.quality,
            outcome: .notTried, buffers: 0, frames: 0, sampleRate: 0, wallSeconds: 0,
            note: "The sweep stopped before this voice."
        )
    }
}

/// Who a voice is, as the sweep records it before rendering: everything about
/// a voice that the report shows, as plain strings.
struct VoiceSweepVoice: Equatable, Sendable {
    let identifier: String
    let name: String
    let language: String
    /// `default`, `enhanced`, or `premium`.
    let quality: String
    /// A word about the voice that goes in its note whatever the outcome
    /// (for example that it is a novelty voice the app does not list); may be
    /// empty.
    let note: String
}

extension VoiceSweepOutcome {
    /// How a render counts, from how the synthesizer ended it and the frames
    /// it wrote. A render that never ended timed out, whatever it wrote; one
    /// that ended with no frames was refused; one the synthesizer cancelled
    /// after some frames stopped early.
    static func classify(end: OfflineRenderProbe.End?, frames: Int) -> VoiceSweepOutcome {
        switch end {
        case nil: return .timedOut
        case .finished: return frames > 0 ? .ok : .noAudio
        case .cancelled: return frames > 0 ? .stoppedEarly : .noAudio
        }
    }
}

// MARK: - The circuit breaker

/// Stops the sweep after `limit` timeouts in a row. One voice that hangs costs
/// one watchdog interval; three in a row mean the speech service itself is
/// wedged, and every voice after them would only cost another interval.
struct VoiceSweepBreaker: Equatable, Sendable {
    /// How many timeouts in a row trip the breaker.
    static let limit = 3

    /// The timeouts in a row so far.
    private(set) var consecutiveTimeouts = 0

    /// Whether the sweep should stop and report the remaining voices as not
    /// tried.
    var shouldStop: Bool { consecutiveTimeouts >= Self.limit }

    /// Take note of one voice's outcome. A timeout adds to the run; any other
    /// outcome (even a refusal, since the service answered) ends it.
    mutating func record(_ outcome: VoiceSweepOutcome) {
        consecutiveTimeouts = outcome == .timedOut ? consecutiveTimeouts + 1 : 0
    }
}

// MARK: - The report

/// Formats the sweep's results as Markdown for VoiceOver and a braille
/// display: headings and bullet lines only, no tables, no emoji, no color, and
/// every outcome in words.
enum VoiceSweepReport {
    /// The report for `results` (in the order given), on a Mac running
    /// `macOS`, written at `date` (shown in `timeZone`), for `sample`.
    static func markdown(
        results: [VoiceSweepResult],
        macOS: String,
        date: Date,
        sample: String = VoiceSweepSample.text,
        timeZone: TimeZone = .current
    ) -> String {
        var lines = ["# Voice sweep", ""]
        lines.append("- Mac: \(macOS)")
        lines.append("- Date: \(formatted(date, in: timeZone))")
        lines.append("- Sample: \(oneLine(sample))")
        lines.append("")
        lines.append(countsLine(results))
        lines.append("")

        if results.isEmpty {
            lines.append("No voices were swept: none are installed, or none matched the filters.")
            return lines.joined(separator: "\n") + "\n"
        }

        // The problems come first, so that a reader need not walk every voice.
        lines.append("## Problems")
        lines.append("")
        let problems = results.filter { $0.outcome != .ok }
        if problems.isEmpty {
            lines.append("No problems: every voice rendered audio.")
        } else {
            if problems.contains(where: { $0.outcome == .notTried }) {
                lines.append(
                    "The sweep stopped early after \(VoiceSweepBreaker.limit) timeouts in a row, which means the "
                        + "speech service may be wedged. The voices after them were not tried."
                )
                lines.append("")
            }
            for result in problems {
                lines.append("- \(problemLine(result))")
            }
        }
        lines.append("")

        lines.append("## Voices")
        for result in results {
            lines.append("")
            lines.append(contentsOf: voiceSection(result))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `N voices: A ok, B no audio, C timed out, D not tried`, with
    /// `, E stopped early` added only when a voice stopped early (the line a
    /// script reads keeps the same first four counts).
    static func countsLine(_ results: [VoiceSweepResult]) -> String {
        func count(_ outcome: VoiceSweepOutcome) -> Int { results.filter { $0.outcome == outcome }.count }
        var line = "\(results.count) \(results.count == 1 ? "voice" : "voices"): "
            + "\(count(.ok)) ok, \(count(.noAudio)) no audio, \(count(.timedOut)) timed out, "
            + "\(count(.notTried)) not tried"
        if count(.stoppedEarly) > 0 { line += ", \(count(.stoppedEarly)) stopped early" }
        return line
    }

    /// One problem voice as a single line: who it is and what went wrong.
    private static func problemLine(_ result: VoiceSweepResult) -> String {
        var line = "\(oneLine(result.name)), \(result.language), \(result.quality), "
            + "\(oneLine(result.identifier)): \(result.outcome.rawValue)"
        if !result.note.isEmpty { line += ". \(oneLine(result.note))" }
        return line
    }

    /// One voice's heading and bullet lines.
    private static func voiceSection(_ result: VoiceSweepResult) -> [String] {
        var lines = ["### \(oneLine(result.name)) (\(result.language))", ""]
        lines.append("- Identifier: \(oneLine(result.identifier))")
        lines.append("- Quality: \(result.quality)")
        lines.append("- Outcome: \(result.outcome.rawValue)")
        lines.append("- Duration: \(durationText(result))")
        lines.append("- Buffers: \(buffersText(result))")
        lines.append("- Time taken: \(seconds(result.wallSeconds))")
        if !result.note.isEmpty { lines.append("- Note: \(oneLine(result.note))") }
        return lines
    }

    /// The audio's length in words, or "none" when the voice wrote nothing.
    private static func durationText(_ result: VoiceSweepResult) -> String {
        result.frames > 0 && result.sampleRate > 0 ? seconds(result.durationSeconds) : "none"
    }

    /// The buffer count, with the frames and the rate when there is audio.
    private static func buffersText(_ result: VoiceSweepResult) -> String {
        guard result.frames > 0 else { return "\(result.buffers)" }
        let rate = result.sampleRate > 0 ? " at \(Int(result.sampleRate.rounded())) Hz" : ""
        return "\(result.buffers) (\(result.frames) frames\(rate))"
    }

    /// A number of seconds in words, to one decimal place.
    private static func seconds(_ value: Double) -> String {
        String(format: "%.1f seconds", value)
    }

    /// `date` as year-month-day and hour:minute in `timeZone`, with the zone's
    /// abbreviation, in a fixed format so the same instant reads the same on
    /// every Mac.
    private static func formatted(_ date: Date, in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
        return formatter.string(from: date)
    }

    /// `text` on one line: a name or a note with a line break must not break a
    /// heading or a bullet. Quotes, slashes, and other punctuation stay as
    /// they are, since a screen reader reads the text as it is.
    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}
