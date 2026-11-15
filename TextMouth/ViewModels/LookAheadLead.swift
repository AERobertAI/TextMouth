import Foundation

/// How long before the current chapter's end the next chapter's audio is
/// rendered (audit C11).
///
/// The next chapter's speech is prepared the moment the current chapter
/// starts, but its audio, 16 MB for a novel's chapter and over 100 MB for
/// the longest chapter rendered, was once held from then on. Rendering it
/// only this lead before the end keeps a playing reader to one chapter's
/// audio for most of each chapter. The one cost of a render that comes late
/// is a chapter that begins in direct speech, as it already does whenever a
/// render is not ready, so the lead is generous: several times the render's
/// own time, and never under five minutes of listening.
///
/// The numbers come from `Scripts/agents/probes/speech-render-speed-probe.swift`,
/// whose results of November 15, 2026 are recorded at its end.
enum LookAheadLead {
    /// The shortest lead, in seconds of listening: five minutes, however
    /// short the next chapter. A pause counts as long after the same time
    /// (`LongPauseWatch.delay`, which is this number).
    static let minimum: TimeInterval = 5 * 60

    /// How many times the next chapter's estimated render time the lead is.
    static let renderTimeMultiple = 4.0

    /// UTF-16 units of text the synthesizer is assumed to render each
    /// second: about half the slowest rate measured, so a busy Mac or a
    /// slower voice still finishes well inside the lead. Measured: 1,600 to
    /// 3,400 a second for a chapter of 20,000 units, and 750 to 920 for one
    /// of 100,000, in Samantha, Eddy, and enhanced Alex.
    static let assumedRenderUnitsPerSecond = 400.0

    /// UTF-16 units of spoken text counted for each word of the reader's
    /// words-a-minute speed, spaces and punctuation included. English prose
    /// measured 5.3 (Samantha) to 6.9 (Alex); counting more makes the
    /// chapter seem to end sooner, which starts the render earlier.
    static let assumedUnitsPerWord = 7.5

    /// The lead before the current chapter's end at which a next chapter of
    /// `nextChapterLength` UTF-16 units of speech starts to render, in
    /// seconds of listening.
    static func lead(forNextChapterOfLength nextChapterLength: Int) -> TimeInterval {
        let renderTime = Double(max(0, nextChapterLength)) / assumedRenderUnitsPerSecond
        return max(minimum, renderTimeMultiple * renderTime)
    }

    /// About how many seconds of listening `unitsLeft` UTF-16 units of
    /// speech take at `wordsPerMinute`; none for a speed that is not a
    /// positive number, so that a render never waits on a bad speed.
    static func listeningTime(forUnitsLeft unitsLeft: Int, wordsPerMinute: Double) -> TimeInterval {
        guard wordsPerMinute.isFinite, wordsPerMinute > 0 else { return 0 }
        return Double(max(0, unitsLeft)) / (wordsPerMinute * assumedUnitsPerWord / 60)
    }

    /// Whether the next chapter's render is due: the listening time left in
    /// the current chapter has fallen within the lead for the next one.
    ///
    /// - Parameters:
    ///   - unitsLeft: UTF-16 units of the current chapter's speech still to
    ///     be spoken.
    ///   - wordsPerMinute: The speed speech plays at now. Speed and pitch
    ///     are applied as audio plays, so a faster speed only brings the
    ///     lead nearer.
    ///   - nextChapterLength: UTF-16 units of the next chapter's speech.
    static func isReached(unitsLeft: Int, wordsPerMinute: Double, nextChapterLength: Int) -> Bool {
        listeningTime(forUnitsLeft: unitsLeft, wordsPerMinute: wordsPerMinute)
            <= lead(forNextChapterOfLength: nextChapterLength)
    }
}
