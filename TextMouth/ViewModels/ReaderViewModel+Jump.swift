import Foundation

// MARK: - Jump-to-Percent / Jump-to-Time
//
// Both jumps reduce to the same underlying operation: translate a
// user-facing position (a percent of the book or a wall-clock time)
// into a global character offset, then look up the (chapter,
// localOffset) pair the navigation system already understands.
// Audio books and TTS books share the same code path — the only
// difference is how time maps to characters (10 chars/sec for audio
// vs the WPM-derived rate for TTS).
//
// The implementation deliberately funnels through `navigateTo`, the
// same entry point the headings/bookmarks panels use. That keeps the
// audio-book seek path, TTS chapter-render path, and chapter-end
// pre-render invalidation all consistent.

extension ReaderViewModel {

    /// Jump to a specific percent through the book. Accepts 0 ≤ percent ≤ 100;
    /// out-of-range values are clamped. No-op if the book hasn't loaded.
    /// Plays an announcement after the jump so VoiceOver users get
    /// audible confirmation that the percent landed where they asked.
    func jumpToPercent(_ percent: Double) {
        guard let content = content, content.totalCharacterCount > 0 else { return }
        let clamped = max(0.0, min(percent, 100.0))
        // Round to the nearest character — fractional offsets aren't
        // meaningful and would surface as visual jitter when the user
        // jumps to e.g. "47.0%" and lands at one character earlier.
        let target = Int((clamped / 100.0 * Double(content.totalCharacterCount)).rounded())
        jumpToGlobalOffset(target)
        announceToVoiceOver(String(format: "Jumped to %.1f percent.", clamped))
    }

    /// Jump to a specific wall-clock time within the book. The time is
    /// interpreted as "time from the start of the book at the current
    /// playback rate" — so a 1-hour audio book takes a 30-minute jump
    /// to its midpoint, regardless of speed setting.
    /// Behaviour for ranges outside [0, totalTime]: clamped to the
    /// nearest endpoint. No-op if the book hasn't loaded.
    func jumpToTime(seconds: TimeInterval) {
        guard let content = content, content.totalCharacterCount > 0 else { return }
        let clampedSeconds = max(0, seconds)

        // Compute the target global offset using the same formulas the
        // book-info-bar uses for its forward-direction display, so a
        // round-trip (offset → display → jump back) lands on itself.
        let target: Int
        if isAudioBook {
            // 10 chars per second is the fixed audio-book mapping.
            target = Int((clampedSeconds * Self.audioCharsPerSecond).rounded())
        } else {
            // TTS uses the same proportional formula as the time
            // display: timeRemaining = totalTime * (remainingChars /
            // totalChars), which inverts to:
            // globalOffset = (timeElapsed / totalTime) * totalChars.
            let totalTime = content.estimatedReadingTime(wpm: speechService.wordsPerMinute)
            guard totalTime > 0 else { return }
            let elapsed = min(clampedSeconds, totalTime)
            target = Int((elapsed / totalTime * Double(content.totalCharacterCount)).rounded())
        }

        jumpToGlobalOffset(target)
        announceToVoiceOver("Jumped to \(TimeFormatting.spoken(clampedSeconds)).")
    }

    /// Lower-level jump used by both `jumpToPercent` and `jumpToTime`.
    /// Translates a global character offset into a (chapter, local
    /// offset) pair via DocumentContent.location(forGlobalOffset:),
    /// then routes through `navigateTo` so all the existing seek /
    /// pre-render-invalidation / position-save plumbing applies.
    /// Public so the test suite can exercise the route end-to-end.
    func jumpToGlobalOffset(_ globalOffset: Int) {
        guard let content = content else { return }
        let target = content.location(forGlobalOffset: globalOffset)
        // savePositionForReturn so the user can press Return-to-Saved
        // to undo a jump that landed them somewhere unexpected — same
        // affordance heading/bookmark navigation provides.
        savePositionForReturn()
        navigateTo(chapterIndex: target.chapterIndex, characterOffset: target.localOffset)
    }
}
