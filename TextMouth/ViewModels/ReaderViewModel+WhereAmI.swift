import SwiftUI
import AppKit
import AVFoundation

// MARK: - Where Am I, Copy Reading Position, VoiceOver Announcements

extension ReaderViewModel {

    /// How soon a second Where Am I must follow the first to ask for the
    /// expanded announcement. A constant, so it is nonisolated like
    /// `shouldUseFullWhereAmI(last:now:)`, which reads it.
    nonisolated static let whereAmIEscalationInterval: TimeInterval = 3

    /// A rapid repeat asks for the expanded announcement; the exact boundary
    /// remains brief so a press at three seconds is deterministic.
    nonisolated static func shouldUseFullWhereAmI(last: Date, now: Date) -> Bool {
        now.timeIntervalSince(last) < whereAmIEscalationInterval
    }

    // MARK: - Where Am I?

    /// Pauses the book (if playing), then speaks a summary of current position
    /// using a separate synthesizer so the book engine state is preserved.
    /// First press: brief summary (heading, heading number, percentage).
    /// Quick second press (within 3 seconds): full details including time estimates.
    /// If already speaking: stops the announcement, resuming the book it
    /// paused or starting the play it held (`startPlayHeldByWhereAmI()`).
    func whereAmI() {
        // If already speaking a Where Am I announcement, stop it
        if isWhereAmISpeaking {
            whereAmISynth.stopSpeaking(at: .immediate)
            isWhereAmISpeaking = false
            if wasPlayingBeforeWhereAmI {
                wasPlayingBeforeWhereAmI = false
                resumeBookPausedForWhereAmI()
            }
            startPlayHeldByWhereAmI()
            return
        }

        // Determine detail level: brief on first press, full on quick second press
        let now = Date()
        let useFull = Self.shouldUseFullWhereAmI(last: lastWhereAmITime, now: now)
        lastWhereAmITime = now

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
        // timer countdown. The companion resume calls below are likewise direct.
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

        guard let content = content else {
            speakWhereAmI("No book is loaded.")
            return
        }

        let summary = useFull ? buildFullWhereAmI(content: content) : buildBriefWhereAmI()
        speakWhereAmI(summary)
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
    /// transcribed audiobook, the sentence being heard.
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
            heardSentence: heardTranscriptSentence
        )
    }

    /// Pure formatter for the full announcement, shared with regression tests.
    /// The heading is named exactly once, followed by its number, so the
    /// listener never hears two different names for the same place. A
    /// transcribed audiobook's `heardSentence` follows the times.
    nonisolated static func fullWhereAmISummary(
        bookTitle: String,
        locationTitle: String?,
        headingPosition: HeadingPosition,
        percentComplete: Double,
        timeRemaining: TimeInterval,
        timeRemainingInHeading: TimeInterval?,
        totalTime: TimeInterval,
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
    /// Used by skip/play/pause to cleanly interrupt an announcement.
    func cancelWhereAmIIfActive() {
        guard isWhereAmISpeaking else { return }
        whereAmISynth.stopSpeaking(at: .immediate)
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
    /// Sets up a delegate to resume book playback when the announcement finishes.
    func speakWhereAmI(_ text: String) {
        whereAmISynth.stopSpeaking(at: .immediate)

        // Set self as delegate via the WhereAmIDelegateHelper
        let delegate = WhereAmIDelegateHelper { [weak self] in
            self?.whereAmIAnnouncementFinished()
        }
        self.whereAmIDelegate = delegate
        whereAmISynth.delegate = delegate

        // Guarded like the book's own speech: the announcement quotes the
        // book, and the engine reads tag-shaped text as markup.
        let utterance = AVSpeechUtterance(string: SpeechMarkupGuard.neutralized(text))
        utterance.voice = speechService.currentVoice
        utterance.rate = SpeechService.rateForWPM(speechService.wordsPerMinute)
        utterance.prefersAssistiveTechnologySettings = false

        isWhereAmISpeaking = true
        whereAmISynth.speak(utterance)
    }

    /// End a Where Am I announcement that finished by itself: play the end
    /// sound, then, once it has played (`whereAmIEndSoundDelay`), resume
    /// the book the announcement paused, or start the play it held
    /// (`startPlayHeldByWhereAmI()`). The synthesizer's delegate calls it
    /// on the main queue; tests call it in the announcement's place.
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
