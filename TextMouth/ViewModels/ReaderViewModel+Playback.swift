import SwiftUI
import Combine
import AppKit
import AVFoundation

// MARK: - Playback Controls & Audio Engine

extension ReaderViewModel {

    // MARK: - TTS Playback

    /// Start speaking the current chapter from the current offset.
    /// For audio books, delegates to playAudioChapter().
    func play() {
        // Don't start playback while Where Am I is speaking
        if isWhereAmISpeaking { return }
        soundEffectService?.play(for: .play)
        recordPlaybackStarted()
        readingStatsService.startSession(bookID: book.id)
        if isAudioBook {
            playAudioChapter()
        } else {
            speakCurrentChapter()
            nowPlayingService.updateNowPlayingInfo(
                title: book.title, author: book.author, isPlaying: true
            )
        }
    }

    /// Pause the current playback (TTS or audio) and save position.
    func pause() {
        soundEffectService?.play(for: .pause)
        if sleepTimerService.isFadingOut {
            sleepTimerService.stop()
            if isAudioBook { audioPlaybackService.restoreVolume() }
            else { speechService.audioEngine.restoreVolume() }
        }
        if isAudioBook {
            audioPlaybackService.pause()
            isCurrentlyPlaying = true // still "playing" but paused
            isCurrentlyPaused = true
        } else {
            speechService.pause()
        }
        readingStatsService.endSession()
        nowPlayingService.updateNowPlayingInfo(
            title: book.title, author: book.author, isPlaying: false
        )
        recordPlaybackStopped()
        savePosition()
    }

    /// Toggle between play and pause states. Handles Where Am I interruption,
    /// audio book resume, TTS resume with rewind-on-resume, and cold start.
    func togglePlayPause() {
        // If Where Am I is speaking, stop the announcement and resume/don't resume book.
        // Don't allow toggling playback while Where Am I is active — it would cause
        // both the book and the announcement to play simultaneously.
        if isWhereAmISpeaking {
            whereAmISynth.stopSpeaking(at: .immediate)
            isWhereAmISpeaking = false
            // Don't resume book — user explicitly pressed play/pause, not "dismiss Where Am I"
            wasPlayingBeforeWhereAmI = false
            return
        }

        if isAudioBook {
            if audioPlaybackService.isPaused {
                soundEffectService?.play(for: .play)
                recordPlaybackStarted()
                readingStatsService.startSession(bookID: book.id)
                audioPlaybackService.resume()
                isCurrentlyPaused = false
                nowPlayingService.updateNowPlayingInfo(
                    title: book.title, author: book.author, isPlaying: true
                )
            } else if audioPlaybackService.isPlaying {
                pause()
            } else {
                play()
            }
            return
        }

        debugLog("togglePlayPause called, isSpeaking=\(speechService.isSpeaking) isPaused=\(speechService.isPaused)")
        if speechService.isPaused {
            soundEffectService?.play(for: .play)
            applyRewindOnResume()
            recordPlaybackStarted()
            readingStatsService.startSession(bookID: book.id)
            speechService.resume()
            nowPlayingService.updateNowPlayingInfo(
                title: book.title, author: book.author, isPlaying: true
            )
        } else if speechService.isSpeaking {
            pause()
        } else {
            play()
        }
    }

    /// Stop all playback completely and clear Now Playing info.
    func stop() {
        if sleepTimerService.isFadingOut {
            sleepTimerService.stop()
        }
        if isAudioBook {
            audioPlaybackService.restoreVolume()
            audioPlaybackService.stop()
            isCurrentlyPlaying = false
            isCurrentlyPaused = false
        } else {
            speechService.audioEngine.restoreVolume()
            speechService.stop()
        }
        readingStatsService.endSession()
        nowPlayingService.clearNowPlaying()
        recordPlaybackStopped()
        savePosition()
    }

    /// Speak the current chapter's text from the current character offset.
    /// Applies section filtering, punctuation pauses, and text substitutions before speaking.
    func speakCurrentChapter() {
        guard let content = content,
              currentChapterIndex < content.chapters.count else { return }

        // Skip empty chapters
        var idx = currentChapterIndex
        while idx < content.chapters.count && content.chapters[idx].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            idx += 1
        }
        if idx != currentChapterIndex {
            currentChapterIndex = idx
            currentCharacterOffset = 0
        }
        guard idx < content.chapters.count else { return }

        let chapter = content.chapters[currentChapterIndex]
        guard !chapter.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        debugLog("speakCurrentChapter: chapter=\(currentChapterIndex) offset=\(currentCharacterOffset) gen=\(chapterPlaybackGeneration)")

        // Filter out skipped sections, apply punctuation pauses, then text substitutions
        let filteredText = filterSkippedSections(chapterIndex: currentChapterIndex, text: chapter.text)
        let pausedText = applyPunctuationPauses(filteredText)
        let transformation = substitutionService.transform(pausedText)
        currentTransformation = transformation
        let speakText = transformation.modifiedText
        let speakOffset = transformation.toModifiedOffset(currentCharacterOffset)

        // Start playback from the current offset.
        utteranceBaseOffset = 0
        speechService.speak(speakText, fromCharOffset: speakOffset)

        // Pre-render the next chapter so it can start instantly when this one ends
        preRenderNextChapter()
    }

    /// Pre-render the next chapter's audio in background so chapter transitions are instant
    func preRenderNextChapter() {
        guard let content = content else { return }
        var nextIdx = currentChapterIndex + 1
        while nextIdx < content.chapters.count && content.chapters[nextIdx].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            nextIdx += 1
        }
        guard nextIdx < content.chapters.count else {
            nextChapterEngine?.cancelRender()
            nextChapterEngine = nil
            nextChapterIndex = nil
            return
        }

        // Cancel any stale pre-render before starting a new one
        nextChapterEngine?.cancelRender()

        let engine = AudioEngineService()
        let rawText = content.chapters[nextIdx].text
        let chapterText = substitutionService.transform(rawText).modifiedText
        nextChapterIndex = nextIdx

        engine.render(text: chapterText, voice: speechService.currentVoice, wpm: speechService.wordsPerMinute) { [weak self] success in
            guard let self = self else { return }
            if success {
                self.nextChapterEngine = engine
                self.debugLog("preRender: chapter \(nextIdx) ready (\(chapterText.count) chars)")
            }
        }
    }

    // MARK: - Audio Book Playback

    /// Wire up audio playback service callbacks for position tracking and chapter advancement.
    func setupAudioCallbacks() {
        audioPlaybackService.onPositionUpdate = { [weak self] time in
            // AVPlayer time observer fires on main queue (setupTimeObserver uses queue: .main),
            // so this is already on the main thread
            guard let self = self, self.isAudioBook else { return }
            // Convert time position to character offset for position tracking
            let charOffset = Int(time * 10) // 10 chars per second in placeholder text
            self.currentCharacterOffset = charOffset
        }

        audioPlaybackService.onPlaybackFinished = { [weak self] in
            guard let self = self else { return }
            self.savePosition()
            self.sleepTimerService.notifyDocumentEnd()

            // Advance to next chapter (audio file)
            if let content = self.content {
                let nextIndex = self.currentChapterIndex + 1
                if nextIndex < content.chapters.count {
                    self.currentChapterIndex = nextIndex
                    self.currentCharacterOffset = 0
                    self.playAudioChapter()
                } else {
                    self.readingStatsService.endSession()
                    self.handleEndOfBook()
                }
            }
        }
    }

    /// Start playing the current audio chapter file from the current character offset.
    /// Handles multi-file audio books and DAISY segmented audio with clip boundaries.
    func playAudioChapter() {
        guard isAudioBook, let content = content,
              currentChapterIndex < content.chapters.count else { return }

        let audioURL: URL
        if !audioChapterFiles.isEmpty && currentChapterIndex < audioChapterFiles.count {
            // Multi-file audio book (or segmented DAISY audio)
            audioURL = URL(fileURLWithPath: audioChapterFiles[currentChapterIndex])
        } else {
            // Single audio file — use book file path
            audioURL = URL(fileURLWithPath: book.filePath)
        }

        audioPlaybackService.load(url: audioURL)
        audioPlaybackService.setSpeed(audioSpeed)

        // For segmented audio (DAISY), the clip starts at the segment's startTime
        // rather than 0. The characterOffset is relative to the segment.
        var timeOffset = Double(currentCharacterOffset) / 10.0
        if !audioSegments.isEmpty && currentChapterIndex < audioSegments.count {
            let segment = audioSegments[currentChapterIndex]
            timeOffset += segment.startTime

            // Set up a clip end boundary — when playback reaches endTime,
            // treat it as chapter finished
            let clipEnd = segment.endTime
            if clipEnd > segment.startTime {
                audioPlaybackService.setClipEndTime(clipEnd)
            }
        }

        audioPlaybackService.play(fromTime: timeOffset)

        isCurrentlyPlaying = true
        isCurrentlyPaused = false

        nowPlayingService.updateNowPlayingInfo(
            title: book.title, author: book.author, isPlaying: true
        )
    }

    /// Adjust audio playback speed by a delta (e.g. +0.25x or -0.25x).
    /// Clamped to the audio service's min/max range. Persisted as per-book setting.
    func adjustAudioSpeed(delta: Double) {
        let newSpeed = max(audioPlaybackService.minimumSpeed,
                          min(audioSpeed + delta, audioPlaybackService.maximumSpeed))
        audioSpeed = newSpeed
        audioPlaybackService.setSpeed(newSpeed)
        // Save as per-book setting
        book.localWPM = newSpeed
        libraryViewModel.updateLocalVoiceAndSpeed(bookID: book.id, voiceID: book.localVoiceID, wpm: newSpeed, pitch: book.localPitch)
        announceToVoiceOver(String(format: "%.2fx speed", newSpeed))
    }

    // MARK: - End of Book Behavior

    /// Called when the last chapter finishes playing.
    /// Behavior depends on per-book override or global setting: stop, loop, or continue to next book.
    func handleEndOfBook() {
        // Determine behavior: per-book override or global setting
        let behavior: EndOfBookBehavior
        if let localRaw = book.localEndOfBookBehavior,
           let local = EndOfBookBehavior(rawValue: localRaw) {
            behavior = local
        } else {
            behavior = settingsViewModel.endOfBookBehavior
        }

        switch behavior {
        case .stop:
            readingStatsService.markBookFinished(bookID: book.id, title: book.title)
            nowPlayingService.updateNowPlayingInfo(
                title: book.title, author: book.author, isPlaying: false
            )
            announceToVoiceOver("Finished: \(book.title)")

        case .loop:
            currentChapterIndex = 0
            currentCharacterOffset = 0
            chapterPlaybackGeneration += 1
            savePosition()
            announceToVoiceOver("Restarting: \(book.title)")
            speakCurrentChapter()
            nowPlayingService.updateNowPlayingInfo(
                title: book.title, author: book.author, isPlaying: true
            )

        case .continueNext:
            readingStatsService.markBookFinished(bookID: book.id, title: book.title)
            savePosition()
            // Find the next book in the same folder by manual sort order
            if let nextBook = libraryViewModel.nextBookInFolder(after: book) {
                announceToVoiceOver("Starting: \(nextBook.title)")
                // Post notification to open next book (the app handles window management)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NotificationCenter.default.post(
                        name: .continueToNextBook,
                        object: nil,
                        userInfo: ["bookID": nextBook.id, "previousBookID": self.book.id]
                    )
                }
            } else {
                nowPlayingService.updateNowPlayingInfo(
                    title: book.title, author: book.author, isPlaying: false
                )
                announceToVoiceOver("Finished: \(book.title). No more books in folder.")
            }
        }
    }

    /// The effective end-of-book behavior for this book (per-book override or global default)
    var effectiveEndOfBookBehavior: EndOfBookBehavior {
        if let localRaw = book.localEndOfBookBehavior,
           let local = EndOfBookBehavior(rawValue: localRaw) {
            return local
        }
        return settingsViewModel.endOfBookBehavior
    }

    /// Set or clear the per-book end-of-book behavior override
    func setLocalEndOfBookBehavior(_ behavior: EndOfBookBehavior?) {
        book.localEndOfBookBehavior = behavior?.rawValue
        libraryViewModel.updateEndOfBookBehavior(bookID: book.id, behavior: behavior?.rawValue)
    }

    // MARK: - Rewind on Resume

    /// Record that playback has started (for rewind-on-resume timing)
    func recordPlaybackStarted() {
        book.lastPlaybackStarted = Date()
        libraryViewModel.updatePlaybackTimestamps(
            bookID: book.id,
            started: book.lastPlaybackStarted,
            stopped: book.lastPlaybackStopped
        )
    }

    /// Record that playback has stopped (for rewind-on-resume timing)
    func recordPlaybackStopped() {
        book.lastPlaybackStopped = Date()
        libraryViewModel.updatePlaybackTimestamps(
            bookID: book.id,
            started: book.lastPlaybackStarted,
            stopped: book.lastPlaybackStopped
        )
    }

    /// Check settings and apply rewind-on-resume if appropriate.
    /// Called before speechService.resume() so the seek takes effect on the paused state.
    func applyRewindOnResume() {
        let unit = settingsViewModel.rewindOnResumeUnit
        guard unit != .none else { return }

        // Smart mode: only rewind if pause was long enough
        if settingsViewModel.rewindSmartMode {
            guard let stoppedAt = book.lastPlaybackStopped else { return }
            let elapsed = Date().timeIntervalSince(stoppedAt)
            if elapsed < settingsViewModel.rewindSmartThreshold {
                debugLog("rewindOnResume: smart mode skip, elapsed=\(Int(elapsed))s < threshold=\(Int(settingsViewModel.rewindSmartThreshold))s")
                return
            }
        }

        guard let content = content,
              currentChapterIndex < content.chapters.count else { return }

        let text = content.chapters[currentChapterIndex].text
        let offset = currentCharacterOffset

        switch unit {
        case .none:
            break
        case .sentence:
            let newOffset = findSentenceStart(in: text, before: offset)
            if newOffset < offset {
                debugLog("rewindOnResume: sentence rewind \(offset) -> \(newOffset)")
                currentCharacterOffset = newOffset
                speechService.seek(toCharOffset: newOffset)
            }
        case .paragraph:
            let newOffset = findParagraphStart(in: text, before: offset)
            if newOffset < offset {
                debugLog("rewindOnResume: paragraph rewind \(offset) -> \(newOffset)")
                currentCharacterOffset = newOffset
                speechService.seek(toCharOffset: newOffset)
            }
        case .heading:
            if let heading = currentHeadingAtPosition() {
                let headingOffset = heading.chapterIndex == currentChapterIndex ? heading.characterOffset : 0
                if headingOffset < offset {
                    debugLog("rewindOnResume: heading rewind \(offset) -> \(headingOffset)")
                    currentCharacterOffset = headingOffset
                    speechService.seek(toCharOffset: headingOffset)
                }
            }
        }
    }

    /// Find the start of the current sentence by scanning backward for sentence-ending punctuation.
    func findSentenceStart(in text: String, before offset: Int) -> Int {
        guard offset > 0, offset <= text.count else { return 0 }
        let sentenceEnders: Set<Character> = [".", "!", "?"]
        let idx = text.index(text.startIndex, offsetBy: min(offset - 1, text.count - 1))

        // Walk backward to find the end of the previous sentence
        var pos = idx
        while pos > text.startIndex {
            pos = text.index(before: pos)
            if sentenceEnders.contains(text[pos]) {
                // Move past the punctuation and any whitespace
                var start = text.index(after: pos)
                while start < text.endIndex && text[start].isWhitespace {
                    start = text.index(after: start)
                }
                return text.distance(from: text.startIndex, to: start)
            }
        }
        return 0 // No sentence boundary found — rewind to start of chapter
    }

    /// Find the start of the current paragraph by scanning backward for double newlines.
    func findParagraphStart(in text: String, before offset: Int) -> Int {
        guard offset > 1, offset <= text.count else { return 0 }
        let searchEnd = min(offset - 1, text.count - 1)
        let idx = text.index(text.startIndex, offsetBy: searchEnd)

        var pos = idx
        while pos > text.startIndex {
            let prev = text.index(before: pos)
            if text[pos] == "\n" && text[prev] == "\n" {
                // Move past the newlines
                var start = text.index(after: pos)
                while start < text.endIndex && text[start].isWhitespace && text[start] != "\n" {
                    start = text.index(after: start)
                }
                return text.distance(from: text.startIndex, to: start)
            }
            pos = prev
        }
        return 0 // No paragraph boundary found — rewind to start of chapter
    }

    // MARK: - Punctuation Pauses

    /// Insert extra pause characters at punctuation to slow down dense text.
    /// Level 0 = off, 1 = subtle (periods), 2 = moderate (periods + commas), 3 = heavy (+ paragraph breaks)
    func applyPunctuationPauses(_ text: String) -> String {
        let level = settingsViewModel.punctuationPauseLevel
        guard level > 0 else { return text }

        // Use a period followed by space as a natural TTS pause cue
        let periodPause = ". "     // Extra pause after sentences
        let commaPause = ", "      // Extra pause after commas
        let paragraphPause = ".\n\n" // Extra pause at paragraph breaks

        var result = text

        // Level 1+: Extra pause after sentence-ending punctuation
        if level >= 1 {
            result = result.replacingOccurrences(of: ". ", with: ".\(periodPause)")
            result = result.replacingOccurrences(of: "! ", with: "!\(periodPause)")
            result = result.replacingOccurrences(of: "? ", with: "?\(periodPause)")
        }

        // Level 2+: Extra pause after commas
        if level >= 2 {
            result = result.replacingOccurrences(of: ", ", with: ",\(commaPause)")
        }

        // Level 3: Extra pause at paragraph breaks
        if level >= 3 {
            result = result.replacingOccurrences(of: "\n\n", with: "\n\n\(paragraphPause)")
        }

        return result
    }
}
