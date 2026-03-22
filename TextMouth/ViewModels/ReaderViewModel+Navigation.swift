import SwiftUI
import AppKit

// MARK: - Navigation (skip, heading, word/character seeking)

extension ReaderViewModel {

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
        case .heading:
            if forward { nextHeading() } else { previousHeading() }
        case .subheading:
            // Find next heading of level >= 2
            if forward { nextSubheading() } else { previousSubheading() }
        case .bookmark:
            if forward { goToNextBookmark() } else { goToPreviousBookmark() }
        default:
            // Time-based skip
            if isAudioBook, let seconds = unit.seconds {
                // For audio: convert seconds directly to character offset (10 chars = 1 second)
                let charDelta = Int(Double(seconds) * Self.audioCharsPerSecond)
                skipCharacters(count: forward ? charDelta : -charDelta)
            } else if let wordCount = unit.wordCount(wpm: speechService.wordsPerMinute) {
                skipWords(count: forward ? wordCount : -wordCount)
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
            sleepTimerService.notifyHeadingBoundary()
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
            sleepTimerService.notifyHeadingBoundary()
            announceToVoiceOver("Heading: \(heading.text)")
        }
    }

    /// Skip forward or backward by a number of words (approximately 5 chars per word).
    /// Handles cross-chapter boundaries and snaps to word boundaries.
    func skipWords(count: Int) {
        guard let content = content,
              currentChapterIndex < content.chapters.count else { return }

        let wasPlaying = speechService.isSpeaking && !speechService.isPaused
        let charDelta = count * 5  // ~5 chars per word average
        let chapterLen = content.chapters[currentChapterIndex].text.count

        debugLog("skipWords count=\(count) charDelta=\(charDelta) currentOffset=\(currentCharacterOffset) chapterLen=\(chapterLen) chapter=\(currentChapterIndex)")

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

        // Snap to word boundary
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

        debugLog("skipWords result -> chapter=\(chapIdx) offset=\(charOffset) sameChapter=\(sameChapter)")

        if sameChapter {
            // Same chapter: seek without re-rendering.
            // If engine has rendered audio, this is an instant buffer seek.
            // If still in direct mode, this restarts direct speech from the new offset
            // without cancelling the in-progress engine render.
            currentCharacterOffset = charOffset
            speechService.seek(toCharOffset: charOffset)
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
            sleepTimerService.notifyHeadingBoundary()
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
            sleepTimerService.notifyHeadingBoundary()
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
            // Same chapter: instant seek, no re-rendering
            currentCharacterOffset = characterOffset
            speechService.seek(toCharOffset: characterOffset)
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
}
