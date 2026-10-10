import SwiftUI
import AppKit
import AVFoundation

// MARK: - Where Am I, Copy Reading Position, VoiceOver Announcements

extension ReaderViewModel {

    // MARK: - Where Am I?

    /// Handles a press of Where Am I? (`.brief`, the W key) or Where Am I?
    /// Full Summary (`.full`, W twice), as `SummaryPress` decides (FR12,
    /// section 3 of the design). An announcement speaks through a
    /// synthesizer of its own, so the book's engine state is preserved.
    /// - With no announcement speaking, the book pauses, if it plays, and
    ///   the summary pressed for speaks after the start sound: the brief one
    ///   (the heading, its number, the percentage, and the time left) or the
    ///   full one (adding the time left in the heading and the book's whole
    ///   time). The book resumes when it ends (`whereAmIAnnouncementFinished()`).
    /// - A brief press while an announcement speaks stops it, resuming the
    ///   book it paused or starting the play it held, as a command that
    ///   interrupts it does (`cancelWhereAmIIfActive()`); so does a full
    ///   press while the full summary speaks.
    /// - A full press while the brief summary speaks, the second press of W
    ///   twice, switches to the full summary, the book still paused until
    ///   the full one ends.
    ///
    /// No press depends on when the last one came: the three-second rule
    /// is retired (question 4), so W always speaks the brief summary.
    func whereAmI(_ detail: SummaryDetail = .brief) {
        switch SummaryPress.outcome(pressing: detail, while: isWhereAmISpeaking ? whereAmIDetail : nil) {
        case .stop:
            cancelWhereAmIIfActive()
        case .replace(with: let replacement):
            // The announcement goes on in more detail: the book stays as the
            // first left it, and no second start sound plays. It speaks on a
            // fresh synthesizer, the one saying the brief summary stopped and
            // let go with its delegate: an utterance handed to a synthesizer
            // just told to stop can be cancelled with what it was saying, and
            // that cancel, of the announcement speaking, would end the full
            // summary at once, taken for one nobody asked for, with the book
            // left paused.
            replaceWhereAmISynthesizer()
            speakWhereAmISummary(replacement)
        case .speak(let summary):
            pauseBookForWhereAmI()
            speakWhereAmISummary(summary)
        }
    }

    /// Begins an announcement: records whether the book plays, plays the
    /// start sound, and pauses the book if it plays.
    private func pauseBookForWhereAmI() {
        if isAudioBook {
            wasPlayingBeforeWhereAmI = audioPlaybackService.isPlaying && !audioPlaybackService.isPaused
        } else {
            wasPlayingBeforeWhereAmI = speechService.isSpeaking && !speechService.isPaused
        }

        soundEffectService?.play(for: .whereAmIStart)

        // Pause the book if it's currently playing (without the normal pause sound).
        // This deliberately bypasses ReaderViewModel.pause() — Where Am I is a
        // brief announcement (a few seconds), and we don't want it to fire the
        // pause sound effect, end the reading-stats session, or halt the sleep
        // timer countdown. The companion resume calls below are likewise direct;
        // an announcement that ends with the book left paused settles the pause
        // then (`settlePauseLeftByWhereAmI()`).
        if wasPlayingBeforeWhereAmI {
            if isAudioBook {
                audioPlaybackService.pause()
            } else {
                speechService.pause()
            }
            nowPlayingService.updateNowPlayingInfo(
                title: book.title, author: book.author, isPlaying: false
            )
            savePosition()
        }
    }

    /// Speaks the `detail` summary of the position as it is now, or, with
    /// no book loaded, says so, and records which summary speaks.
    private func speakWhereAmISummary(_ detail: SummaryDetail) {
        whereAmIDetail = detail
        guard let content else {
            speakWhereAmI("No book is loaded.")
            return
        }
        speakWhereAmI(detail == .full ? buildFullWhereAmI(content: content) : buildBriefWhereAmI())
    }

    /// Brief summary: book title, current heading, heading number,
    /// percentage, and time remaining, then, for a transcribed audiobook,
    /// the sentence being heard.
    func buildBriefWhereAmI() -> String {
        let position = currentHeadingPosition
        return Self.briefWhereAmISummary(
            bookTitle: book.title,
            locationTitle: locationTitle(for: position, chapterIndex: currentChapterIndex),
            headingPosition: position,
            percentComplete: percentComplete,
            timeRemaining: timeRemaining,
            heardSentence: heardTranscriptSentence
        )
    }

    /// Pure formatter for the brief announcement, shared with regression tests.
    /// Example: "My Book. The Battle. Heading 26 of 412. 30 percent. 3 hours remaining."
    /// A transcribed audiobook's `heardSentence` follows, quoted as it is:
    /// "… 3 hours remaining. The salt road bends east."
    nonisolated static func briefWhereAmISummary(
        bookTitle: String,
        locationTitle: String?,
        headingPosition: HeadingPosition,
        percentComplete: Double,
        timeRemaining: TimeInterval,
        heardSentence: String? = nil
    ) -> String {
        let parts = whereAmILocationParts(
            bookTitle: bookTitle,
            locationTitle: locationTitle,
            headingPosition: headingPosition
        ) + [
            String(format: "%.0f percent", percentComplete),
            "\(TimeFormatting.spoken(timeRemaining)) remaining",
        ]
        return whereAmISummary(parts: parts, quoting: heardSentence)
    }

    /// Full summary: the brief summary's location, then time remaining in the
    /// book and in the current heading, and the total book time, then, for a
    /// book read from the reading list, where it stands in the list (FR09),
    /// and, for a transcribed audiobook, the sentence being heard.
    func buildFullWhereAmI(content: DocumentContent) -> String {
        let position = currentHeadingPosition
        return Self.fullWhereAmISummary(
            bookTitle: book.title,
            locationTitle: locationTitle(for: position, chapterIndex: currentChapterIndex),
            headingPosition: position,
            percentComplete: percentComplete,
            timeRemaining: timeRemaining,
            timeRemainingInHeading: position.heading.flatMap { remainingTime(inHeading: $0, content: content) },
            totalTime: totalEstimatedTime,
            readingListPlace: readingListPlace,
            heardSentence: heardTranscriptSentence
        )
    }

    /// Pure formatter for the full announcement, shared with regression tests.
    /// The heading is named exactly once, followed by its number, so the
    /// listener never hears two different names for the same place. A book
    /// read from the reading list says its place there after the times
    /// ("Reading list, book 3 of 12", FR09), the broader setting, which only
    /// this second announcement gives: the brief one is the quick check of
    /// a place in the book, pressed often while listening, and the window's
    /// title and header say the book is read from the list. A transcribed
    /// audiobook's `heardSentence` follows last.
    nonisolated static func fullWhereAmISummary(
        bookTitle: String,
        locationTitle: String?,
        headingPosition: HeadingPosition,
        percentComplete: Double,
        timeRemaining: TimeInterval,
        timeRemainingInHeading: TimeInterval?,
        totalTime: TimeInterval,
        readingListPlace: ReadingListPlace? = nil,
        heardSentence: String? = nil
    ) -> String {
        var parts = whereAmILocationParts(
            bookTitle: bookTitle,
            locationTitle: locationTitle,
            headingPosition: headingPosition
        )
        parts.append(String(format: "%.0f percent through the book", percentComplete))
        parts.append("\(TimeFormatting.spoken(timeRemaining)) remaining")
        if let timeRemainingInHeading {
            parts.append("\(TimeFormatting.spoken(timeRemainingInHeading)) remaining in this heading")
        }
        parts.append("Total book time: \(TimeFormatting.spoken(totalTime))")
        if let readingListPlace {
            parts.append(ReadingListReaderWording.place(readingListPlace))
        }
        return whereAmISummary(parts: parts, quoting: heardSentence)
    }

    /// Opening shared by both announcements: the book, the heading being read
    /// (empty when there is none to name), and the heading number.
    private nonisolated static func whereAmILocationParts(
        bookTitle: String,
        locationTitle: String?,
        headingPosition: HeadingPosition
    ) -> [String] {
        [bookTitle, locationTitle ?? "", headingPosition.label]
    }

    /// Joins announcement fields into spoken sentences, dropping empty fields
    /// so a missing heading or label never becomes an audible pause, then
    /// quotes `heardSentence`, when there is one, after them as it is, with
    /// its own punctuation.
    nonisolated static func whereAmISummary(parts: [String], quoting heardSentence: String? = nil) -> String {
        let summary = parts.filter { !$0.isEmpty }.joined(separator: ". ") + "."
        guard let heardSentence, !heardSentence.isEmpty else { return summary }
        return summary + " " + heardSentence
    }

    // MARK: - The Transcript Sentence Being Heard

    /// The most words of the sentence being heard that Where Am I quotes. A
    /// recognizer's sentence can run on for a paragraph, and Where Am I is
    /// for finding one's place in a few seconds.
    nonisolated static let whereAmIQuoteWordLimit = 40

    /// For a transcribed audiobook (FR05), the transcript's sentence being
    /// heard at the cursor, as Where Am I quotes it (`whereAmIQuote(of:)`):
    /// the sentence the reader's text is shown around
    /// (`shownText(of:chapterIndex:cursorOffset:)`). Nil for any other
    /// book, before a chapter's first sentence, and in a chapter the
    /// transcript has no sentences for.
    var heardTranscriptSentence: String? {
        guard isAudioBook,
              let sentence = content?.transcript?.sentenceText(
                  atAudioOffset: currentCharacterOffset,
                  inChapter: currentChapterIndex
              ) else { return nil }
        return Self.whereAmIQuote(of: sentence)
    }

    /// `sentence` as Where Am I quotes it: its words, one space apart, as a
    /// sentence wrapped across lines is read; past `whereAmIQuoteWordLimit`
    /// words, the first that many and an ellipsis. Nil when it holds no
    /// words.
    nonisolated static func whereAmIQuote(of sentence: String) -> String? {
        let words = sentence.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        guard words.count > whereAmIQuoteWordLimit else {
            return words.joined(separator: " ")
        }
        return words.prefix(whereAmIQuoteWordLimit).joined(separator: " ") + "…"
    }

    /// Time left in `heading` from the live cursor at the current speed, or
    /// nil when the heading spans no text to measure.
    private func remainingTime(inHeading heading: Heading, content: DocumentContent) -> TimeInterval? {
        let totalHeadingChars = estimatedCharsInHeading(heading)
        guard totalHeadingChars > 0 else { return nil }
        let headingStart = content.globalOffset(chapterIndex: heading.chapterIndex, localOffset: heading.characterOffset)
        let elapsed = currentGlobalOffset - headingStart
        let fractionRemaining = max(0, 1.0 - Double(elapsed) / Double(totalHeadingChars))
        return timeEstimateForHeading(heading) * fractionRemaining
    }

    /// Cancel a Where Am I announcement if one is active, resuming book
    /// playback if it was playing before, or starting the play the
    /// announcement held (`startPlayHeldByWhereAmI()`).
    /// Used by skips and moves to cleanly interrupt an announcement, and by
    /// a press of Where Am I? that stops one (`whereAmI(_:)`).
    func cancelWhereAmIIfActive() {
        guard isWhereAmISpeaking else { return }
        stopWhereAmISynthesizer()
        isWhereAmISpeaking = false
        // Resume book if it was playing before Where Am I interrupted it
        if WhereAmIInterruptionPolicy.shouldResume(
            wasPlayingBeforeAnnouncement: wasPlayingBeforeWhereAmI,
            reason: .navigationOrRepeatedCommand
        ) {
            wasPlayingBeforeWhereAmI = false
            resumeBookPausedForWhereAmI()
        }
        startPlayHeldByWhereAmI()
    }

    /// How long after a Where Am I announcement ends by itself the book
    /// resumes, or the play it held starts: long enough for the end sound
    /// to play first.
    nonisolated static let whereAmIEndSoundDelay: TimeInterval = 0.3

    /// Speak a Where Am I announcement using the dedicated synthesizer (not the book reader).
    /// Sets up a delegate that hears how the announcement ends: a finish
    /// resumes book playback, and a cancel the reader did not ask for ends
    /// the announcement without it (`whereAmISynthesizerCancelled(_:)`).
    func speakWhereAmI(_ text: String) {
        stopWhereAmISynthesizer()

        // Set self as delegate via the WhereAmIDelegateHelper
        let delegate = WhereAmIDelegateHelper(
            onFinished: { [weak self] finished in self?.whereAmISynthesizerFinished(finished) },
            onCancelled: { [weak self] cancelled in self?.whereAmISynthesizerCancelled(cancelled) }
        )
        self.whereAmIDelegate = delegate
        whereAmISynth.delegate = delegate

        // Guarded like the book's own speech: the announcement quotes the
        // book, and the engine reads tag-shaped text as markup.
        let utterance = AVSpeechUtterance(string: SpeechMarkupGuard.neutralized(text))
        utterance.voice = speechService.currentVoice
        utterance.rate = SpeechService.rateForWPM(speechService.wordsPerMinute)
        utterance.prefersAssistiveTechnologySettings = false

        isWhereAmISpeaking = true
        liveWhereAmIUtterance = utterance
        handWhereAmIToSynthesizer(utterance)
    }

    /// Hands `utterance` to the Where Am I synthesizer, or to the test's
    /// recorder in its place (`_whereAmIUtteranceRecorderForTesting`).
    private func handWhereAmIToSynthesizer(_ utterance: AVSpeechUtterance) {
        if let record = _whereAmIUtteranceRecorderForTesting {
            record(utterance)
        } else {
            whereAmISynth.speak(utterance)
        }
    }

    /// Silences the Where Am I synthesizer because the reader asked: a
    /// press while an announcement speaks, a command that interrupts it, a
    /// new announcement, or the reader closing. The announcement speaking is
    /// forgotten first, so that the cancel the synthesizer then reports for
    /// it is known for one the reader asked for, handled where it was asked,
    /// once (`whereAmISynthesizerCancelled(_:)`).
    func stopWhereAmISynthesizer() {
        liveWhereAmIUtterance = nil
        whereAmISynth.stopSpeaking(at: .immediate)
    }

    /// The synthesizer says `finished` ended by itself, on the main queue.
    /// When it is the announcement speaking, the announcement ends as one
    /// that finished does (`whereAmIAnnouncementFinished()`); the end of
    /// one the reader stopped or replaced since is ignored, so it can
    /// neither play the end sound again nor end a newer announcement.
    func whereAmISynthesizerFinished(_ finished: ReportedUtterance) {
        guard isLiveWhereAmIUtterance(finished) else { return }
        liveWhereAmIUtterance = nil
        whereAmIAnnouncementFinished()
    }

    /// The synthesizer says `cancelled` was cancelled, on the main queue
    /// (#1296). A cancel the reader asked for, of an utterance it forgot as
    /// it stopped it (`stopWhereAmISynthesizer()`), was handled where it
    /// was asked and changes nothing here.
    ///
    /// A cancel of the announcement speaking, which the reader did not ask
    /// for, as when the speech engine refuses its text, ends it without the
    /// end sound or the resume a finished announcement makes: the book it
    /// paused stays paused, and a play it held pauses, as when Play/Pause
    /// ends an announcement (`endWhereAmIWithoutResuming()`), so Play/Pause
    /// works at once instead of only ending an announcement nobody hears.
    /// Its synthesizer is replaced, since one the engine refused never
    /// speaks again, as the speech service replaces its own.
    func whereAmISynthesizerCancelled(_ cancelled: ReportedUtterance) {
        guard isLiveWhereAmIUtterance(cancelled) else { return }
        DiagnosticLog.event(
            .playback,
            "WHERE_AM_I_CANCEL_UNEXPECTED: the announcement was cancelled before it ended; "
                + "synthesizer replaced, book left paused"
        )
        liveWhereAmIUtterance = nil
        replaceWhereAmISynthesizer()
        endWhereAmIWithoutResuming()
    }

    /// Whether `reported` is the announcement speaking now
    /// (`liveWhereAmIUtterance`).
    private func isLiveWhereAmIUtterance(_ reported: ReportedUtterance) -> Bool {
        liveWhereAmIUtterance.map(ObjectIdentifier.init) == reported.id
    }

    /// Replaces the Where Am I synthesizer with a fresh one, the old one
    /// stopped and its delegate let go, so that nothing it still reports
    /// reaches the reader. The next announcement gives the fresh one its
    /// delegate (`speakWhereAmI(_:)`).
    private func replaceWhereAmISynthesizer() {
        whereAmISynth.delegate = nil
        whereAmISynth.stopSpeaking(at: .immediate)
        whereAmISynth = AVSpeechSynthesizer()
    }

    /// End a Where Am I announcement that finished by itself: play the end
    /// sound, then, once it has played (`whereAmIEndSoundDelay`), resume
    /// the book the announcement paused, or start the play it held
    /// (`startPlayHeldByWhereAmI()`). The synthesizer's delegate calls it
    /// on the main queue, for the announcement speaking
    /// (`whereAmISynthesizerFinished(_:)`); tests call it in the
    /// announcement's place.
    func whereAmIAnnouncementFinished() {
        isWhereAmISpeaking = false
        soundEffectService?.play(for: .whereAmIEnd)
        let resumesBook = WhereAmIInterruptionPolicy.shouldResume(
            wasPlayingBeforeAnnouncement: wasPlayingBeforeWhereAmI,
            reason: .naturalCompletion
        )
        if resumesBook {
            wasPlayingBeforeWhereAmI = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.whereAmIEndSoundDelay) { [weak self] in
            guard let self else { return }
            if resumesBook {
                self.resumeBookPausedForWhereAmI()
            }
            // Asked only now: a pause, or another announcement, since the
            // end leaves no play to start.
            self.startPlayHeldByWhereAmI()
        }
    }

    /// Settles the pause a Where Am I announcement made, now that the
    /// announcement ends with the book left paused: by Play/Pause pressed
    /// during it, or by a cancel nobody asked for
    /// (`endWhereAmIWithoutResuming()`). The announcement paused the book
    /// without the rest of a pause, expecting to resume it seconds later;
    /// left paused, the book gets the rest now, as `pause()` would have
    /// given it: the listening session ends, a minutes sleep timer's
    /// countdown waits for Play, the stop is recorded for rewind-on-resume,
    /// and an audiobook shows paused, so its Play/Pause button says Play
    /// rather than Pause. Its place was saved, and Now Playing told, as the
    /// announcement paused it.
    func settlePauseLeftByWhereAmI() {
        sleepTimerService.pauseCountdown(by: readerID)
        readingStatsService.endSession(bookID: book.id)
        recordPlaybackStopped()
        // An audiobook's Playing state is the reader's own, which the
        // announcement's direct pause left showing Playing; still loaded,
        // it shows paused, as `pause()` leaves it. A text book's follows
        // its speech service, which shows the pause already.
        if isAudioBook, audioPlaybackService.isPaused {
            isCurrentlyPlaying = true
            isCurrentlyPaused = true
        }
    }

    /// Resume the book a Where Am I announcement paused, as it was paused:
    /// directly, without the play sound or a new listening session, and
    /// tell Now Playing it plays again.
    private func resumeBookPausedForWhereAmI() {
        if isAudioBook {
            audioPlaybackService.resume()
        } else {
            speechService.resume()
        }
        nowPlayingService.updateNowPlayingInfo(
            title: book.title, author: book.author, isPlaying: true
        )
    }

    // MARK: - Heading Location

    /// Heading-based location of the live reading cursor, used by Where Am I,
    /// the copied reading position, and navigation announcements.
    var currentHeadingPosition: HeadingPosition {
        HeadingPosition(in: headings, chapterIndex: currentChapterIndex, characterOffset: currentCharacterOffset)
    }

    /// Heading-based location of the throttled display cursor. The reader
    /// header reads it, so the header follows playback across headings
    /// without re-rendering on every spoken word.
    var displayHeadingPosition: HeadingPosition {
        HeadingPosition(in: headings, chapterIndex: displayChapterIndex, characterOffset: displayCharacterOffset)
    }

    /// Name for `position`, which lies in content unit `chapterIndex`: the
    /// containing heading's text, or for a book without headings that unit's
    /// own title (see `HeadingPosition.title(contentTitle:bookTitle:)`).
    func locationTitle(for position: HeadingPosition, chapterIndex: Int) -> String? {
        let chapters = content?.chapters ?? []
        let contentTitle = chapters.indices.contains(chapterIndex) ? chapters[chapterIndex].title : nil
        return position.title(contentTitle: contentTitle, bookTitle: book.title)
    }

    /// Find the heading at or before the current reading position
    func currentHeadingAtPosition() -> Heading? {
        currentHeadingPosition.heading
    }

    /// Estimated character count for a heading section (from heading start to next heading or end of book)
    func estimatedCharsInHeading(_ heading: Heading) -> Int {
        guard let content = content else { return 0 }
        let allHeadings = content.allHeadings
        let headingGlobalStart = content.globalOffset(chapterIndex: heading.chapterIndex, localOffset: heading.characterOffset)
        var nextOffset = content.totalCharacterCount
        if let idx = allHeadings.firstIndex(where: { $0.id == heading.id }),
           idx + 1 < allHeadings.count {
            let next = allHeadings[idx + 1]
            nextOffset = content.globalOffset(chapterIndex: next.chapterIndex, localOffset: next.characterOffset)
        }
        return nextOffset - headingGlobalStart
    }

    // MARK: - Copy Reading Position

    /// Copy a formatted summary of the current reading position to the system clipboard
    func copyReadingPosition() {
        guard content != nil else { return }

        let position = currentHeadingPosition
        let positionText = Self.readingPositionSummary(
            bookTitle: book.title,
            author: book.author,
            locationTitle: locationTitle(for: position, chapterIndex: currentChapterIndex),
            headingPosition: position,
            percentComplete: percentComplete,
            formattedTimeRemaining: formattedTimeRemaining
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(positionText, forType: .string)
        announceToVoiceOver("Reading position copied to clipboard")
    }

    /// Pure formatter for the copied reading position, using the same heading
    /// vocabulary as Where Am I. Example:
    /// "My Book | by An Author | The Battle | Heading 26 of 412 | 30.0% through | 3:00:00 remaining"
    nonisolated static func readingPositionSummary(
        bookTitle: String,
        author: String,
        locationTitle: String?,
        headingPosition: HeadingPosition,
        percentComplete: Double,
        formattedTimeRemaining: String
    ) -> String {
        readingPositionSummary(parts: [
            bookTitle,
            author.isEmpty ? "" : "by \(author)",
            locationTitle ?? "",
            headingPosition.label,
            String(format: "%.1f%% through", percentComplete),
            "\(formattedTimeRemaining) remaining",
        ])
    }

    /// Joins copied-position fields with " | ", dropping empty fields and the
    /// placeholder "Unknown" author.
    nonisolated static func readingPositionSummary(parts: [String]) -> String {
        parts.filter { !$0.isEmpty && $0 != "by \(Book.unknownAuthor)" }.joined(separator: " | ")
    }

    // MARK: - VoiceOver Announcement

    /// Post a VoiceOver announcement from the key (or main) window with high
    /// priority, and remember it in `lastAnnouncement` for tests.
    func announceToVoiceOver(_ message: String) {
        postAnnouncement(message, priority: .high)
    }

    /// Post a VoiceOver announcement with medium priority, which VoiceOver
    /// speaks after what it is saying rather than over it, and remember it
    /// in `lastAnnouncement` for tests.
    func announceToVoiceOverAfterCurrentSpeech(_ message: String) {
        postAnnouncement(message, priority: .medium)
    }

    /// Post `message` from the key (or main) window at `priority`, and
    /// remember it in `lastAnnouncement`.
    private func postAnnouncement(_ message: String, priority: NSAccessibilityPriorityLevel) {
        lastAnnouncement = message
        VoiceOverAnnouncer.announce(message, priority: priority)
    }
}

/// Central decision table for interactions between the separate Where Am I
/// synthesizer and book playback.
enum WhereAmIInterruptionPolicy {
    enum Reason: Equatable {
        case playbackToggle
        case navigationOrRepeatedCommand
        case naturalCompletion
    }

    static func blocksBookPlayback(isAnnouncementSpeaking: Bool) -> Bool {
        isAnnouncementSpeaking
    }

    static func shouldResume(
        wasPlayingBeforeAnnouncement: Bool,
        reason: Reason
    ) -> Bool {
        guard wasPlayingBeforeAnnouncement else { return false }
        return reason != .playbackToggle
    }
}
