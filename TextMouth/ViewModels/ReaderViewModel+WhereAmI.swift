import SwiftUI
import AppKit
import AVFoundation

// MARK: - Where Am I, Copy Reading Position, VoiceOver Announcements

extension ReaderViewModel {

    static let whereAmIEscalationInterval: TimeInterval = 3

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
    /// If already speaking: stops the announcement.
    func whereAmI() {
        // If already speaking a Where Am I announcement, stop it
        if isWhereAmISpeaking {
            whereAmISynth.stopSpeaking(at: .immediate)
            isWhereAmISpeaking = false
            if wasPlayingBeforeWhereAmI {
                wasPlayingBeforeWhereAmI = false
                if isAudioBook {
                    audioPlaybackService.resume()
                } else {
                    speechService.resume()
                }
                nowPlayingService.updateNowPlayingInfo(
                    title: book.title, author: book.author, isPlaying: true
                )
            }
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
    /// percentage, and time remaining.
    func buildBriefWhereAmI() -> String {
        let position = currentHeadingPosition
        return Self.briefWhereAmISummary(
            bookTitle: book.title,
            locationTitle: locationTitle(for: position, chapterIndex: currentChapterIndex),
            headingPosition: position,
            percentComplete: percentComplete,
            timeRemaining: timeRemaining
        )
    }

    /// Pure formatter for the brief announcement, shared with regression tests.
    /// Example: "My Book. The Battle. Heading 26 of 412. 30 percent. 3 hours remaining."
    nonisolated static func briefWhereAmISummary(
        bookTitle: String,
        locationTitle: String?,
        headingPosition: HeadingPosition,
        percentComplete: Double,
        timeRemaining: TimeInterval
    ) -> String {
        let parts = whereAmILocationParts(
            bookTitle: bookTitle,
            locationTitle: locationTitle,
            headingPosition: headingPosition
        ) + [
            String(format: "%.0f percent", percentComplete),
            "\(TimeFormatting.spoken(timeRemaining)) remaining",
        ]
        return whereAmISummary(parts: parts)
    }

    /// Full summary: the brief summary's location, then time remaining in the
    /// book and in the current heading, and the total book time.
    func buildFullWhereAmI(content: DocumentContent) -> String {
        let position = currentHeadingPosition
        return Self.fullWhereAmISummary(
            bookTitle: book.title,
            locationTitle: locationTitle(for: position, chapterIndex: currentChapterIndex),
            headingPosition: position,
            percentComplete: percentComplete,
            timeRemaining: timeRemaining,
            timeRemainingInHeading: position.heading.flatMap { remainingTime(inHeading: $0, content: content) },
            totalTime: totalEstimatedTime
        )
    }

    /// Pure formatter for the full announcement, shared with regression tests.
    /// The heading is named exactly once, followed by its number, so the
    /// listener never hears two different names for the same place.
    nonisolated static func fullWhereAmISummary(
        bookTitle: String,
        locationTitle: String?,
        headingPosition: HeadingPosition,
        percentComplete: Double,
        timeRemaining: TimeInterval,
        timeRemainingInHeading: TimeInterval?,
        totalTime: TimeInterval
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
        return whereAmISummary(parts: parts)
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
    /// so a missing heading or label never becomes an audible pause.
    nonisolated static func whereAmISummary(parts: [String]) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: ". ") + "."
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

    /// Cancel a Where Am I announcement if one is active, resuming book playback if it was playing before.
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
            if isAudioBook {
                audioPlaybackService.resume()
            } else {
                speechService.resume()
            }
            nowPlayingService.updateNowPlayingInfo(
                title: book.title, author: book.author, isPlaying: true
            )
        }
    }

    /// Speak a Where Am I announcement using the dedicated synthesizer (not the book reader).
    /// Sets up a delegate to resume book playback when the announcement finishes.
    func speakWhereAmI(_ text: String) {
        whereAmISynth.stopSpeaking(at: .immediate)

        // Set self as delegate via the WhereAmIDelegateHelper
        let delegate = WhereAmIDelegateHelper { [weak self] in
            guard let self = self else { return }
            self.isWhereAmISpeaking = false
            self.soundEffectService?.play(for: .whereAmIEnd)
            if WhereAmIInterruptionPolicy.shouldResume(
                wasPlayingBeforeAnnouncement: self.wasPlayingBeforeWhereAmI,
                reason: .naturalCompletion
            ) {
                self.wasPlayingBeforeWhereAmI = false
                // Small delay to let sound effect play
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self = self else { return }
                    if self.isAudioBook {
                        self.audioPlaybackService.resume()
                    } else {
                        self.speechService.resume()
                    }
                    self.nowPlayingService.updateNowPlayingInfo(
                        title: self.book.title, author: self.book.author, isPlaying: true
                    )
                }
            }
        }
        self.whereAmIDelegate = delegate
        whereAmISynth.delegate = delegate

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = speechService.currentVoice
        utterance.rate = SpeechService.rateForWPM(speechService.wordsPerMinute)
        utterance.prefersAssistiveTechnologySettings = false

        isWhereAmISpeaking = true
        whereAmISynth.speak(utterance)
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
        parts.filter { !$0.isEmpty && $0 != "by Unknown" }.joined(separator: " | ")
    }

    // MARK: - VoiceOver Announcement

    /// Post a VoiceOver announcement from the key (or main) window with high
    /// priority, and remember it in `lastAnnouncement` for tests.
    func announceToVoiceOver(_ message: String) {
        lastAnnouncement = message
        VoiceOverAnnouncer.announce(message)
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
