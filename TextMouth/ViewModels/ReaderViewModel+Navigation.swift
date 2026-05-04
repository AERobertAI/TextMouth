import SwiftUI
import AppKit

// MARK: - Navigation (skip, heading, word/character seeking)

extension ReaderViewModel {

    /// Convert an original-text offset to modified-text space and seek the speech service.
    /// Falls back to using the offset directly if no transformation pipeline is active.
    func seekSpeechService(toOriginalOffset offset: Int) {
        let seekOffset = currentOffsetMap?.toModified(offset) ?? offset
        speechService.seek(toCharOffset: seekOffset)
    }

    /// Skip forward by the configured unit (or shift-unit if shift is held).
    /// Debounces rapid-fire calls within 0.3 seconds.
    func skipForward(useShiftUnit: Bool = false) {
        // Debounce: ignore if called again within 0.3 seconds
        let now = Date()
        guard now.timeIntervalSince(lastSkipTime) > 0.3 else { return }
        lastSkipTime = now
        cancelWhereAmIIfActive()
        soundEffectService?.play(for: .skipForward)
        let unit = useShiftUnit ? settingsViewModel.shiftSkipForwardUnit : settingsViewModel.skipForwardUnit
        debugLog("skipForward called, unit=\(unit.rawValue) shift=\(useShiftUnit)")
        performSkip(unit: unit, forward: true)
    }

    /// Skip backward by the configured unit (or shift-unit if shift is held).
    /// Debounces rapid-fire calls within 0.3 seconds.
    func skipBackward(useShiftUnit: Bool = false) {
        let now = Date()
        guard now.timeIntervalSince(lastSkipTime) > 0.3 else { return }
        lastSkipTime = now
        cancelWhereAmIIfActive()
        soundEffectService?.play(for: .skipBackward)
        let unit = useShiftUnit ? settingsViewModel.shiftSkipBackwardUnit : settingsViewModel.skipBackwardUnit
        debugLog("skipBackward called, unit=\(unit.rawValue) shift=\(useShiftUnit)")
        performSkip(unit: unit, forward: false)
    }

    /// Dispatch a skip action based on the skip unit type.
    /// Time-based units convert to word or character deltas; structural units delegate to heading/bookmark nav.
    func performSkip(unit: SkipUnit, forward: Bool) {
        debugLog("performSkip unit=\(unit.rawValue) forward=\(forward) wpm=\(speechService.wordsPerMinute)")
        switch unit {
        case .sentence:
            if forward { nextSentence() } else { previousSentence() }
        case .paragraph:
            if forward { nextParagraph() } else { previousParagraph() }
        case .heading:
            if forward { nextHeading() } else { previousHeading() }
        case .subheading:
            // Find next heading of level >= 2
            if forward { nextSubheading() } else { previousSubheading() }
        case .bookmark:
            if forward { goToNextBookmark() } else { goToPreviousBookmark() }
        default:
            // Time-based skip: calculate character delta from the same formula used
            // for the time display so the displayed time change is always consistent.
            // Time display uses: timeRemaining = totalTime * (remainingChars / totalChars)
            // So: deltaChars = deltaSeconds * totalChars / totalTime
            if isAudioBook, let seconds = unit.seconds {
                // For audio: convert seconds directly to character offset (10 chars = 1 second)
                let charDelta = Int(Double(seconds) * Self.audioCharsPerSecond)
                skipCharacters(count: forward ? charDelta : -charDelta)
            } else if let seconds = unit.seconds {
                skipByTime(seconds: forward ? Double(seconds) : -Double(seconds))
            }
        }
    }

    /// Jump to the next subheading (level >= 2) after the current position
    func nextSubheading() {
        guard let content = content else { return }
        let allHeadings = content.allHeadings
        if let nextIndex = allHeadings.firstIndex(where: {
            $0.level >= 2 && (
                $0.chapterIndex > currentChapterIndex ||
                ($0.chapterIndex == currentChapterIndex && $0.characterOffset > currentCharacterOffset)
            )
        }) {
            let heading = allHeadings[nextIndex]
            navigateTo(chapterIndex: heading.chapterIndex, characterOffset: heading.characterOffset)
            sleepTimerService.notifyHeadingBoundary(by: book.id)
            announceToVoiceOver("Heading: \(heading.text)")
        }
    }

    /// Jump to the previous subheading (level >= 2) before the current position
    func previousSubheading() {
        guard let content = content else { return }
        let allHeadings = content.allHeadings
        if let prevIndex = allHeadings.lastIndex(where: {
            $0.level >= 2 && (
                $0.chapterIndex < currentChapterIndex ||
                ($0.chapterIndex == currentChapterIndex && $0.characterOffset < currentCharacterOffset - 10)
            )
        }) {
            let heading = allHeadings[prevIndex]
            navigateTo(chapterIndex: heading.chapterIndex, characterOffset: heading.characterOffset)
            sleepTimerService.notifyHeadingBoundary(by: book.id)
            announceToVoiceOver("Heading: \(heading.text)")
        }
    }

    // MARK: - Sentence Navigation

    /// Jump forward to the start of the next sentence after the current position.
    /// Scans for sentence-ending punctuation (. ! ?) followed by whitespace.
    /// Crosses chapter boundaries if no next sentence is found in the current chapter.
    func nextSentence() {
        guard let content = content,
              currentChapterIndex < content.chapters.count else { return }

        let text = content.chapters[currentChapterIndex].text
        let sentenceEnders: Set<Character> = [".", "!", "?"]

        // Scan forward from current position for the end of a sentence
        if currentCharacterOffset < text.count {
            let startIdx = text.index(text.startIndex, offsetBy: currentCharacterOffset)
            var pos = startIdx
            while pos < text.endIndex {
                if sentenceEnders.contains(text[pos]) {
                    // Found sentence end — move past punctuation and whitespace to next sentence start
                    var nextStart = text.index(after: pos)
                    while nextStart < text.endIndex && text[nextStart].isWhitespace {
                        nextStart = text.index(after: nextStart)
                    }
                    let newOffset = text.distance(from: text.startIndex, to: nextStart)
                    // Only advance if we actually moved forward and there's text ahead
                    if newOffset > currentCharacterOffset && nextStart < text.endIndex {
                        navigateTo(chapterIndex: currentChapterIndex, characterOffset: newOffset)
                        announceToVoiceOver("Next sentence")
                        return
                    }
                }
                pos = text.index(after: pos)
            }
        }

        // No next sentence in current chapter — advance to start of next non-empty chapter
        var nextChapter = currentChapterIndex + 1
        while nextChapter < content.chapters.count &&
              content.chapters[nextChapter].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            nextChapter += 1
        }
        if nextChapter < content.chapters.count {
            navigateTo(chapterIndex: nextChapter, characterOffset: 0)
            announceToVoiceOver("Next chapter")
        }
    }

    /// Jump backward to the start of the current or previous sentence.
    /// Uses a grace zone: if we're near the start of a sentence, goes to the one before it.
    /// Crosses chapter boundaries if at the start of the current chapter.
    func previousSentence() {
        guard let content = content,
              currentChapterIndex < content.chapters.count else { return }

        let text = content.chapters[currentChapterIndex].text
        let offset = currentCharacterOffset

        // Use the existing findSentenceStart to find the start of the current sentence
        let sentenceStart = findSentenceStart(in: text, before: offset)

        if sentenceStart < offset {
            navigateTo(chapterIndex: currentChapterIndex, characterOffset: sentenceStart)
            announceToVoiceOver("Previous sentence")
            return
        }

        // Already at sentence start or start of chapter — go to previous chapter
        if currentChapterIndex > 0 {
            var prevChapter = currentChapterIndex - 1
            while prevChapter > 0 &&
                  content.chapters[prevChapter].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                prevChapter -= 1
            }
            let prevText = content.chapters[prevChapter].text
            // Find the last sentence start in the previous chapter
            let prevOffset = findSentenceStart(in: prevText, before: prevText.count)
            navigateTo(chapterIndex: prevChapter, characterOffset: prevOffset)
            announceToVoiceOver("Previous chapter")
        }
    }

    // MARK: - Paragraph Navigation

    /// Jump forward to the start of the next paragraph after the current position.
    /// Scans for double-newline paragraph breaks.
    /// Crosses chapter boundaries if no next paragraph is found in the current chapter.
    func nextParagraph() {
        guard let content = content,
              currentChapterIndex < content.chapters.count else { return }

        let text = content.chapters[currentChapterIndex].text

        // Scan forward for the next double-newline paragraph boundary
        if currentCharacterOffset < text.count - 1 {
            let startIdx = text.index(text.startIndex, offsetBy: currentCharacterOffset)
            var pos = startIdx
            while pos < text.endIndex {
                let nextPos = text.index(after: pos)
                if nextPos < text.endIndex && text[pos] == "\n" && text[nextPos] == "\n" {
                    // Found paragraph break — skip past newlines and leading whitespace
                    var paragraphStart = text.index(after: nextPos)
                    while paragraphStart < text.endIndex && text[paragraphStart].isWhitespace && text[paragraphStart] != "\n" {
                        paragraphStart = text.index(after: paragraphStart)
                    }
                    // Skip any additional newlines (triple+ newlines)
                    while paragraphStart < text.endIndex && text[paragraphStart] == "\n" {
                        paragraphStart = text.index(after: paragraphStart)
                    }
                    let newOffset = text.distance(from: text.startIndex, to: paragraphStart)
                    if newOffset > currentCharacterOffset && paragraphStart < text.endIndex {
                        navigateTo(chapterIndex: currentChapterIndex, characterOffset: newOffset)
                        announceToVoiceOver("Next paragraph")
                        return
                    }
                }
                pos = text.index(after: pos)
            }
        }

        // No next paragraph in current chapter — advance to next non-empty chapter
        var nextChapter = currentChapterIndex + 1
        while nextChapter < content.chapters.count &&
              content.chapters[nextChapter].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            nextChapter += 1
        }
        if nextChapter < content.chapters.count {
            navigateTo(chapterIndex: nextChapter, characterOffset: 0)
            announceToVoiceOver("Next chapter")
        }
    }

    /// Jump backward to the start of the current or previous paragraph.
    /// Crosses chapter boundaries if at the start of the current chapter.
    func previousParagraph() {
        guard let content = content,
              currentChapterIndex < content.chapters.count else { return }

        let text = content.chapters[currentChapterIndex].text
        let offset = currentCharacterOffset

        // Use the existing findParagraphStart to find the start of the current paragraph
        let paragraphStart = findParagraphStart(in: text, before: offset)

        if paragraphStart < offset {
            navigateTo(chapterIndex: currentChapterIndex, characterOffset: paragraphStart)
            announceToVoiceOver("Previous paragraph")
            return
        }

        // Already at paragraph start or start of chapter — go to previous chapter
        if currentChapterIndex > 0 {
            var prevChapter = currentChapterIndex - 1
            while prevChapter > 0 &&
                  content.chapters[prevChapter].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                prevChapter -= 1
            }
            let prevText = content.chapters[prevChapter].text
            // Find the last paragraph start in the previous chapter
            let prevOffset = findParagraphStart(in: prevText, before: prevText.count)
            navigateTo(chapterIndex: prevChapter, characterOffset: prevOffset)
            announceToVoiceOver("Previous chapter")
        }
    }

    /// Skip forward or backward by a number of words, scanning actual word boundaries
    /// in the text. Handles cross-chapter boundaries.
    func skipWords(count: Int) {
        guard let content = content,
              currentChapterIndex < content.chapters.count else { return }

        let wasPlaying = speechService.isSpeaking && !speechService.isPaused

        debugLog("skipWords count=\(count) currentOffset=\(currentCharacterOffset) chapter=\(currentChapterIndex)")

        var chapIdx = currentChapterIndex
        var remainingWords = abs(count)
        let forward = count > 0

        // Start from current position and scan word boundaries, crossing chapters as needed
        var charOffset = currentCharacterOffset

        while remainingWords > 0 {
            let chapterText = content.chapters[chapIdx].text

            if forward {
                // Scan forward through word boundaries in this chapter
                let newOffset = offsetAfterSkippingWords(in: chapterText, from: charOffset, wordCount: remainingWords)
                let wordsSkipped = countWordsBetween(in: chapterText, from: charOffset, to: newOffset)
                remainingWords -= wordsSkipped

                if remainingWords > 0 {
                    // Hit end of chapter — advance to next
                    if chapIdx + 1 < content.chapters.count {
                        chapIdx += 1
                        charOffset = 0
                    } else {
                        // At last chapter — clamp to end
                        charOffset = max(0, chapterText.count - 1)
                        break
                    }
                } else {
                    charOffset = newOffset
                }
            } else {
                // Scan backward through word boundaries in this chapter
                let newOffset = offsetAfterSkippingWords(in: chapterText, from: charOffset, wordCount: -remainingWords)
                let wordsSkipped = countWordsBetween(in: chapterText, from: newOffset, to: charOffset)
                remainingWords -= wordsSkipped

                if remainingWords > 0 && newOffset == 0 {
                    // Hit start of chapter — go to previous
                    if chapIdx > 0 {
                        chapIdx -= 1
                        charOffset = content.chapters[chapIdx].text.count
                    } else {
                        charOffset = 0
                        break
                    }
                } else {
                    charOffset = newOffset
                }
            }
        }

        let sameChapter = (chapIdx == currentChapterIndex)

        debugLog("skipWords result -> chapter=\(chapIdx) offset=\(charOffset) sameChapter=\(sameChapter)")

        if sameChapter {
            // Same chapter: seek without re-rendering.
            // If engine has rendered audio, this is an instant buffer seek.
            // If still in direct mode, this restarts direct speech from the new offset
            // without cancelling the in-progress engine render.
            currentCharacterOffset = charOffset
            seekSpeechService(toOriginalOffset: charOffset)
        } else {
            // Different chapter — invalidate stale callbacks before changing state
            chapterPlaybackGeneration += 1
            // Cancel stale pre-rendered chapter
            nextChapterEngine?.cancelRender()
            nextChapterEngine = nil
            nextChapterIndex = nil

            speechService.stop()

            // Now safe to update chapter/offset — no stale callback can overwrite
            currentChapterIndex = chapIdx
            currentCharacterOffset = charOffset

            if wasPlaying {
                speakCurrentChapter()
            }
        }

        if wasPlaying {
            nowPlayingService.updateNowPlayingInfo(
                title: book.title, author: book.author, isPlaying: true
            )
        }

        savePosition()
    }

    /// Skip forward or backward by a number of seconds for TTS text books.
    /// Calculates the character delta using the same formula as the time-remaining display
    /// (deltaChars = deltaSeconds * totalChars / totalTime) so the displayed time change
    /// is always consistent regardless of word length at the skip location.
    /// Snaps to the nearest word boundary after computing the character delta.
    func skipByTime(seconds: Double) {
        guard let content = content,
              currentChapterIndex < content.chapters.count else { return }

        let totalTime = content.estimatedReadingTime(wpm: speechService.wordsPerMinute)
        guard totalTime > 0 else { return }

        // Calculate character delta from the time display formula:
        // timeRemaining = totalTime * (remainingChars / totalChars)
        // So: deltaChars = deltaSeconds / totalTime * totalChars
        let totalChars = Double(content.totalCharacterCount)
        let charDelta = Int(seconds / totalTime * totalChars)

        debugLog("skipByTime seconds=\(seconds) totalTime=\(totalTime) totalChars=\(totalChars) charDelta=\(charDelta)")

        let wasPlaying = speechService.isSpeaking && !speechService.isPaused

        var chapIdx = currentChapterIndex
        var charOffset = currentCharacterOffset + charDelta

        // Handle cross-chapter navigation
        if charOffset < 0 {
            while charOffset < 0 && chapIdx > 0 {
                chapIdx -= 1
                charOffset += content.chapters[chapIdx].text.count
            }
            charOffset = max(0, charOffset)
        } else {
            while chapIdx < content.chapters.count && charOffset >= content.chapters[chapIdx].text.count {
                charOffset -= content.chapters[chapIdx].text.count
                chapIdx += 1
            }
            if chapIdx >= content.chapters.count {
                chapIdx = content.chapters.count - 1
                charOffset = max(0, content.chapters[chapIdx].text.count - 1)
            }
        }

        // Snap to nearest word boundary so playback doesn't start mid-word
        let text = content.chapters[chapIdx].text
        if charOffset > 0 && charOffset < text.count {
            let targetIndex = text.index(text.startIndex, offsetBy: charOffset)
            var wordStart = targetIndex
            while wordStart > text.startIndex && !text[text.index(before: wordStart)].isWhitespace {
                wordStart = text.index(before: wordStart)
            }
            charOffset = text.distance(from: text.startIndex, to: wordStart)
        }

        let sameChapter = (chapIdx == currentChapterIndex)

        if sameChapter {
            currentCharacterOffset = charOffset
            seekSpeechService(toOriginalOffset: charOffset)
        } else {
            chapterPlaybackGeneration += 1
            nextChapterEngine?.cancelRender()
            nextChapterEngine = nil
            nextChapterIndex = nil

            speechService.stop()
            currentChapterIndex = chapIdx
            currentCharacterOffset = charOffset

            if wasPlaying {
                speakCurrentChapter()
            }
        }

        if wasPlaying {
            nowPlayingService.updateNowPlayingInfo(
                title: book.title, author: book.author, isPlaying: true
            )
        }

        savePosition()
    }

    /// Skip by a specific number of characters (used for audio book time-based skipping).
    /// For audio books, 10 characters = 1 second.
    func skipCharacters(count: Int) {
        guard let content = content,
              currentChapterIndex < content.chapters.count else { return }

        let wasPlaying = audioPlaybackService.isPlaying && !audioPlaybackService.isPaused

        var chapIdx = currentChapterIndex
        var charOffset = currentCharacterOffset + count

        // Handle cross-chapter navigation
        if charOffset < 0 {
            while charOffset < 0 && chapIdx > 0 {
                chapIdx -= 1
                charOffset += content.chapters[chapIdx].text.count
            }
            charOffset = max(0, charOffset)
        } else {
            while chapIdx < content.chapters.count && charOffset >= content.chapters[chapIdx].text.count {
                charOffset -= content.chapters[chapIdx].text.count
                chapIdx += 1
            }
            if chapIdx >= content.chapters.count {
                chapIdx = content.chapters.count - 1
                charOffset = max(0, content.chapters[chapIdx].text.count - 1)
            }
        }

        if chapIdx != currentChapterIndex {
            audioPlaybackService.stop()
            currentChapterIndex = chapIdx
            currentCharacterOffset = charOffset
            if wasPlaying {
                playAudioChapter()
            }
        } else {
            currentCharacterOffset = charOffset
            let timeOffset = Double(charOffset) / Self.audioCharsPerSecond
            audioPlaybackService.seek(to: timeOffset)
        }

        savePosition()
    }

    /// Jump to the next top-level heading after the current position
    func nextHeading() {
        guard let content = content else { return }
        let allHeadings = content.allHeadings

        if let nextIndex = allHeadings.firstIndex(where: {
            $0.chapterIndex > currentChapterIndex ||
            ($0.chapterIndex == currentChapterIndex && $0.characterOffset > currentCharacterOffset)
        }) {
            let heading = allHeadings[nextIndex]
            navigateTo(chapterIndex: heading.chapterIndex, characterOffset: heading.characterOffset)
            sleepTimerService.notifyHeadingBoundary(by: book.id)
            announceToVoiceOver("Heading: \(heading.text)")
        }
    }

    /// Jump to the previous top-level heading before the current position
    func previousHeading() {
        guard let content = content else { return }
        let allHeadings = content.allHeadings

        if let prevIndex = allHeadings.lastIndex(where: {
            $0.chapterIndex < currentChapterIndex ||
            ($0.chapterIndex == currentChapterIndex && $0.characterOffset < currentCharacterOffset - 10)
        }) {
            let heading = allHeadings[prevIndex]
            navigateTo(chapterIndex: heading.chapterIndex, characterOffset: heading.characterOffset)
            sleepTimerService.notifyHeadingBoundary(by: book.id)
            announceToVoiceOver("Heading: \(heading.text)")
        }
    }

    /// Navigate to a specific heading (from table of contents), saving current position for return.
    func navigateToHeading(_ heading: Heading) {
        savePositionForReturn()
        navigateTo(chapterIndex: heading.chapterIndex, characterOffset: heading.characterOffset)
        autoPlayIfEnabled()
    }

    /// Navigate to a specific chapter and character offset.
    /// Handles both TTS and audio book playback, with same-chapter seek optimization.
    func navigateTo(chapterIndex: Int, characterOffset: Int) {
        guard let content = content, !content.chapters.isEmpty else { return }

        // Clamp chapter index to valid range
        let chapterIndex = min(max(0, chapterIndex), content.chapters.count - 1)
        // Clamp character offset to chapter text length
        let chapterLen = content.chapters[chapterIndex].text.count
        let characterOffset = min(max(0, characterOffset), max(0, chapterLen - 1))

        if isAudioBook {
            let wasPlaying = audioPlaybackService.isPlaying && !audioPlaybackService.isPaused
            if chapterIndex != currentChapterIndex {
                audioPlaybackService.stop()
                currentChapterIndex = chapterIndex
                currentCharacterOffset = characterOffset
                if wasPlaying {
                    playAudioChapter()
                }
            } else {
                currentCharacterOffset = characterOffset
                let timeOffset = Double(characterOffset) / 10.0
                audioPlaybackService.seek(to: timeOffset)
            }
            savePosition()
            return
        }

        let wasPlaying = speechService.isSpeaking && !speechService.isPaused

        if chapterIndex == currentChapterIndex && wasPlaying {
            // Same chapter: instant seek, no re-rendering.
            // Convert original-text offset to modified-text offset for the speech service.
            currentCharacterOffset = characterOffset
            seekSpeechService(toOriginalOffset: characterOffset)
        } else {
            // Different chapter — invalidate stale callbacks first
            chapterPlaybackGeneration += 1
            nextChapterEngine?.cancelRender()
            nextChapterEngine = nil
            nextChapterIndex = nil

            speechService.stop()
            currentChapterIndex = chapterIndex
            currentCharacterOffset = characterOffset
            if wasPlaying {
                speakCurrentChapter()
                nowPlayingService.updateNowPlayingInfo(
                    title: book.title, author: book.author, isPlaying: true
                )
            }
        }

        savePosition()
    }

    // MARK: - Word Boundary Scanning

    /// Find the character offset after skipping a given number of words forward (positive)
    /// or backward (negative) from a starting offset. Scans actual word boundaries in the text
    /// rather than using a fixed chars-per-word estimate.
    func offsetAfterSkippingWords(in text: String, from startOffset: Int, wordCount: Int) -> Int {
        guard !text.isEmpty else { return 0 }
        let clampedStart = max(0, min(startOffset, text.count))

        if wordCount > 0 {
            // Scan forward: find the start of the Nth next word
            var idx = text.index(text.startIndex, offsetBy: clampedStart)
            var wordsFound = 0

            // Skip the rest of the current word (if we're in one)
            while idx < text.endIndex && !text[idx].isWhitespace {
                idx = text.index(after: idx)
            }

            while wordsFound < wordCount && idx < text.endIndex {
                // Skip whitespace between words
                while idx < text.endIndex && text[idx].isWhitespace {
                    idx = text.index(after: idx)
                }
                if idx < text.endIndex {
                    wordsFound += 1
                }
                // If more words to skip, advance past this word
                if wordsFound < wordCount {
                    while idx < text.endIndex && !text[idx].isWhitespace {
                        idx = text.index(after: idx)
                    }
                }
            }
            return text.distance(from: text.startIndex, to: idx)
        } else {
            // Scan backward: find the start of the Nth previous word
            let targetWords = abs(wordCount)
            var idx = text.index(text.startIndex, offsetBy: clampedStart)
            var wordsFound = 0

            while wordsFound < targetWords && idx > text.startIndex {
                // Skip whitespace backward
                while idx > text.startIndex && text[text.index(before: idx)].isWhitespace {
                    idx = text.index(before: idx)
                }
                // Skip word characters backward
                while idx > text.startIndex && !text[text.index(before: idx)].isWhitespace {
                    idx = text.index(before: idx)
                }
                wordsFound += 1
            }
            return text.distance(from: text.startIndex, to: idx)
        }
    }

    /// Count the number of word boundaries between two offsets in a text.
    /// Used to determine how many words were actually skipped within a chapter.
    func countWordsBetween(in text: String, from startOffset: Int, to endOffset: Int) -> Int {
        guard !text.isEmpty, startOffset < endOffset else { return 0 }
        let start = text.index(text.startIndex, offsetBy: max(0, min(startOffset, text.count)))
        let end = text.index(text.startIndex, offsetBy: max(0, min(endOffset, text.count)))
        guard start < end else { return 0 }

        // Count transitions from whitespace to non-whitespace (word starts) in the range
        var count = 0
        var inWhitespace = true
        var idx = start
        while idx < end {
            if text[idx].isWhitespace {
                inWhitespace = true
            } else if inWhitespace {
                count += 1
                inWhitespace = false
            }
            idx = text.index(after: idx)
        }
        return count
    }
}
