import SwiftUI
import AppKit
import AVFoundation

// MARK: - Where Am I, Copy Reading Position, VoiceOver Announcements

extension ReaderViewModel {

    // MARK: - Where Am I?

    /// Pauses the book (if playing), then speaks a summary of current position
    /// using a separate synthesizer so the book engine state is preserved.
    /// First press: brief summary (chapter, percentage).
    /// Quick second press (within 3 seconds): full details including heading, time estimates.
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
        let timeSinceLast = now.timeIntervalSince(lastWhereAmITime)
        let useFull = timeSinceLast < 3.0
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

        let summary = useFull ? buildFullWhereAmI(content: content) : buildBriefWhereAmI(content: content)
        speakWhereAmI(summary)
    }

    /// Brief summary: title, chapter name, position, percentage
    func buildBriefWhereAmI(content: DocumentContent) -> String {
        var parts: [String] = []
        parts.append(book.title)
        // Include the current heading name so the user knows where they are semantically
        if let currentHeading = currentHeadingAtPosition() {
            parts.append(currentHeading.text)
        } else if currentChapterIndex < content.chapters.count {
            // Fall back to chapter title if no heading found
            let chapter = content.chapters[currentChapterIndex]
            if !chapter.title.isEmpty {
                parts.append(chapter.title)
            }
        }
        if currentChapterIndex < content.chapters.count {
            parts.append("Chapter \(currentChapterIndex + 1) of \(content.chapters.count)")
        }
        parts.append(String(format: "%.0f percent", percentComplete))
        parts.append("\(TimeFormatting.spoken(timeRemaining)) remaining")
        return parts.joined(separator: ". ") + "."
    }

    /// Full summary: title, chapter, heading, time remaining in heading, total book time
    func buildFullWhereAmI(content: DocumentContent) -> String {
        var parts: [String] = []
        parts.append(book.title)
        if currentChapterIndex < content.chapters.count {
            let chapter = content.chapters[currentChapterIndex]
            if !chapter.title.isEmpty {
                parts.append("Chapter: \(chapter.title)")
            }
            parts.append("Chapter \(currentChapterIndex + 1) of \(content.chapters.count)")
        }
        parts.append(String(format: "%.0f percent through the book", percentComplete))
        parts.append("\(TimeFormatting.spoken(timeRemaining)) remaining")
        if let currentHeading = currentHeadingAtPosition() {
            parts.append("Current heading: \(currentHeading.text)")
            let headingTime = timeEstimateForHeading(currentHeading)
            let headingGlobalStart = content.globalOffset(chapterIndex: currentHeading.chapterIndex, localOffset: currentHeading.characterOffset)
            let headingElapsed = currentGlobalOffset - headingGlobalStart
            let totalHeadingChars = estimatedCharsInHeading(currentHeading)
            if totalHeadingChars > 0 {
                let fractionRemaining = max(0, 1.0 - Double(headingElapsed) / Double(totalHeadingChars))
                let headingRemaining = headingTime * fractionRemaining
                parts.append("\(TimeFormatting.spoken(headingRemaining)) remaining in this heading")
            }
        }
        parts.append("Total book time: \(TimeFormatting.spoken(totalEstimatedTime))")
        return parts.joined(separator: ". ") + "."
    }

    /// Cancel a Where Am I announcement if one is active, resuming book playback if it was playing before.
    /// Used by skip/play/pause to cleanly interrupt an announcement.
    func cancelWhereAmIIfActive() {
        guard isWhereAmISpeaking else { return }
        whereAmISynth.stopSpeaking(at: .immediate)
        isWhereAmISpeaking = false
        // Resume book if it was playing before Where Am I interrupted it
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
            if self.wasPlayingBeforeWhereAmI {
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

    /// Find the heading at or before the current reading position
    func currentHeadingAtPosition() -> Heading? {
        guard let content = content else { return nil }
        return Self.currentHeading(
            in: content.allHeadings,
            chapterIndex: currentChapterIndex,
            characterOffset: currentCharacterOffset
        )
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
        guard let content = content else { return }

        var parts: [String] = []
        parts.append(book.title)
        if !book.author.isEmpty && book.author != "Unknown" {
            parts.append("by \(book.author)")
        }

        if currentChapterIndex < content.chapters.count {
            let chapter = content.chapters[currentChapterIndex]
            if !chapter.title.isEmpty {
                parts.append("Chapter: \(chapter.title)")
            }
            parts.append("Chapter \(currentChapterIndex + 1) of \(content.chapters.count)")
        }

        if let heading = currentHeadingAtPosition() {
            parts.append("Heading: \(heading.text)")
        }

        parts.append(String(format: "%.1f%% through", percentComplete))
        parts.append("\(formattedTimeRemaining) remaining")

        let positionText = parts.joined(separator: " | ")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(positionText, forType: .string)
        announceToVoiceOver("Reading position copied to clipboard")
    }

    // MARK: - VoiceOver Announcement

    /// Post a VoiceOver announcement to the key window with high priority
    func announceToVoiceOver(_ message: String) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        NSAccessibility.post(
            element: window,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }
}
