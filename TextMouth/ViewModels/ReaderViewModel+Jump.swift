import Foundation

// MARK: - Jump-to-Percent / Jump-to-Time
//
// Both jumps translate what the user typed into a place, a chapter and an
// offset within it, and go there. A percent is a share of the book's units.
// A time names a place on the book's clock (P08, `placeClock`): for an
// audiobook its recording's own time, whatever speed it plays at; for a text
// book its words at the reader's words per minute.
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
        announceToVoiceOver(ReaderTimeWording.jumped(toPercent: clamped))
    }

    /// Jump to `seconds` on the book's clock (P08, `placeClock`): for an
    /// audiobook, that time in its recording, whatever speed it plays at, so
    /// a time from its chapter list, its show notes, the audio editor, or
    /// any time the reader shows lands where it says; for a text book, that
    /// time at the reader's words per minute. A heading starting less than
    /// a second after the time is landed on instead
    /// (`PlaceClock.place(forTypedTime:headings:)`), so a heading's time,
    /// shown in whole seconds, lands on the heading. A time outside the
    /// book is clamped to it. Nothing happens before the book loads, or for
    /// a book with no time to count (a text book without words). Announces
    /// the time jumped to, an audiobook's "in the recording".
    func jumpToTime(seconds: TimeInterval) {
        guard let content, content.totalCharacterCount > 0,
              let clock = placeClock, clock.length > 0 else { return }
        let time = seconds.isNaN ? 0 : min(max(0, seconds), clock.length)
        let target = clock.place(forTypedTime: time, headings: headings)
        // The shared departure-point helper keeps the Return affordance
        // heading and bookmark jumps have.
        navigatePreservingReturnPosition(chapterIndex: target.chapterIndex, characterOffset: target.characterOffset)
        announceToVoiceOver(ReaderTimeWording.jumped(to: time, timeCount))
    }

    /// Go to Percent's answer: jumps to the percent `text` names and returns
    /// nil, or returns why it will not do, as a sentence the panel shows and
    /// announces. An empty field is refused rather than taken as 0. The
    /// panel never hands it the field's unchanged starting value, which
    /// would move the place by what its rounding left off
    /// (`JumpFieldOutcome`).
    func goToPercent(typed text: String) -> String? {
        switch JumpInputValidator.percent(text) {
        case .value(let percent):
            jumpToPercent(percent)
            return nil
        case .error(let message):
            return message
        }
    }

    /// Go to Time's answer (P08): jumps to the time `text` names on the
    /// book's clock (`jumpToTime(seconds:)`) and returns nil, or returns
    /// why it will not do: not a time, or after the end of the clock
    /// (`JumpInputValidator.time`), as a sentence the panel shows and
    /// announces. The panel never hands it the field's unchanged starting
    /// value, which would move the place back by the fraction of a second
    /// it leaves off (`JumpFieldOutcome`).
    func goToTime(typed text: String) -> String? {
        switch JumpInputValidator.time(text, length: placeClock?.length ?? 0, count: timeCount) {
        case .value(let time):
            jumpToTime(seconds: time)
            return nil
        case .error(let message):
            return message
        }
    }

    /// Lower-level jump used by `jumpToPercent`.
    /// Translates a global character offset into a (chapter, local
    /// offset) pair via DocumentContent.location(forGlobalOffset:),
    /// then routes through `navigateTo` so all the existing seek /
    /// pre-render-invalidation / position-save plumbing applies.
    /// Public so the test suite can exercise the route end-to-end.
    func jumpToGlobalOffset(_ globalOffset: Int) {
        guard let content = content else { return }
        let target = content.location(forGlobalOffset: globalOffset)
        // Route through the shared departure-point helper so percent/time
        // jumps retain the same Return affordance as heading and bookmark jumps.
        navigatePreservingReturnPosition(
            chapterIndex: target.chapterIndex,
            characterOffset: target.localOffset
        )
    }
}

// MARK: - The Clock Places Are Named By (P08)

extension ReaderViewModel {
    /// The clock this book's places are named by (P08): an audiobook's
    /// recording, whatever speed it plays at, or a text book's words at the
    /// reader's words per minute. Nil until the book's content has loaded.
    /// Built afresh from the content's index on each use, which costs one
    /// pass over the chapters; a caller naming many places keeps one.
    var placeClock: PlaceClock? {
        guard let content else { return nil }
        if isAudioBook {
            return .recording(of: content.contentIndex)
        }
        return .reading(
            of: content.contentIndex,
            readingTime: content.estimatedReadingTime(wpm: speechService.wordsPerMinute)
        )
    }

    /// How this book's times are counted (P08), which Go to Time's field and
    /// words name: an audiobook's recording, or a text book's words at the
    /// reader's words per minute.
    var timeCount: ReaderTimeWording.Count {
        isAudioBook ? .recording : .words(perMinute: speechService.wordsPerMinute)
    }

    /// The speed this book's amounts of time are heard at, when the setting
    /// names it beside them (P08, `SettingsViewModel.includeSpeedWithTimes`):
    /// an audiobook's speed, or a text book's words a minute. Nil while the
    /// setting is off, when every time reads as it did before the setting.
    var namedListeningSpeed: ReaderTimeWording.ListeningSpeed? {
        guard settingsViewModel.includeSpeedWithTimes else { return nil }
        return isAudioBook ? .audio(audioSpeed) : .words(perMinute: speechService.wordsPerMinute)
    }

    /// Go to Time's starting value: the reading position's time on the
    /// book's clock, in whole seconds as every time is shown ("2:13:05"), at
    /// every speed the same for an audiobook; "0:00" before the book loads.
    /// It falls up to a second before the place, so Jump on it unchanged
    /// moves nothing (`JumpFieldOutcome.unchanged`, REV14).
    var goToTimeStartingText: String {
        TimeFormatting.format(
            placeClock?.time(chapterIndex: currentChapterIndex, characterOffset: currentCharacterOffset) ?? 0
        )
    }

    /// Go to Percent's starting value: the reading position's percent
    /// through the book as the status row shows it, to a tenth ("47.0"). It
    /// falls up to 0.05 percent from the place, so Jump on it unchanged moves
    /// nothing (`JumpFieldOutcome.unchanged`, REV14).
    var goToPercentStartingText: String {
        String(format: "%.1f", displayPercentComplete)
    }
}
