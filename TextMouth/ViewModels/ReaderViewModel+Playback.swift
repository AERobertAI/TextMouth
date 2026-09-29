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
        // Loading or closed readers cannot own a playback/statistics session.
        guard !hasClosed, !isLoading, let content,
              content.chapters.indices.contains(currentChapterIndex) else { return }
        // Don't start playback while Where Am I is speaking
        if WhereAmIInterruptionPolicy.blocksBookPlayback(
            isAnnouncementSpeaking: isWhereAmISpeaking
        ) { return }
        restartPlaybackBackendOnNextResume = false
        mediaControlsReleased = false
        nowPlayingService.activateRemoteCommandsIfNeeded()
        soundEffectService?.play(for: .play)
        recordPlaybackStarted()
        readingStatsService.startSession(bookID: book.id)
        // Resume any sleep-timer countdown that was halted at the
        // matching pause(). No-op when no countdown was paused (cold
        // start, expired/cancelled timer, heading/document mode).
        sleepTimerService.resumeCountdown(by: book.id)
        if isAudioBook {
            playAudioChapter()
        } else {
            speakCurrentChapter()
            nowPlayingService.updateNowPlayingInfo(
                title: book.title, author: book.author, isPlaying: true
            )
        }
    }

    /// Resume playback if the book is already paused, otherwise fall
    /// back to a cold start when nothing is active.
    func playOrResume() {
        if isAudioBook {
            if audioPlaybackService.isPaused {
                resumeAudioPlayback()
            } else if !audioPlaybackService.isPlaying {
                play()
            }
            return
        }

        if speechService.isPaused {
            resumeSpeechPlayback()
        } else if !speechService.isSpeaking {
            play()
        }
    }

    private func resumeAudioPlayback() {
        mediaControlsReleased = false
        nowPlayingService.activateRemoteCommandsIfNeeded()
        soundEffectService?.play(for: .play)
        recordPlaybackStarted()
        readingStatsService.startSession(bookID: book.id)
        sleepTimerService.resumeCountdown(by: book.id)
        if restartPlaybackBackendOnNextResume {
            restartPlaybackBackendOnNextResume = false
            audioPlaybackService.stop()
            playAudioChapter()
            return
        }
        if audioPlaybackService.resume() {
            isCurrentlyPaused = false
            nowPlayingService.updateNowPlayingInfo(
                title: book.title, author: book.author, isPlaying: true
            )
        } else {
            debugLog("audio resume rejected by backend; reloading current chapter")
            audioPlaybackService.stop()
            playAudioChapter()
        }
    }

    private func resumeSpeechPlayback() {
        mediaControlsReleased = false
        nowPlayingService.activateRemoteCommandsIfNeeded()
        soundEffectService?.play(for: .play)
        applyRewindOnResume()
        recordPlaybackStarted()
        readingStatsService.startSession(bookID: book.id)
        sleepTimerService.resumeCountdown(by: book.id)
        if restartPlaybackBackendOnNextResume {
            restartPlaybackBackendOnNextResume = false
            speechService.stop()
            speakCurrentChapter()
            nowPlayingService.updateNowPlayingInfo(
                title: book.title, author: book.author, isPlaying: true
            )
            return
        }
        if speechService.resume() {
            nowPlayingService.updateNowPlayingInfo(
                title: book.title, author: book.author, isPlaying: true
            )
        } else {
            debugLog("speech resume rejected by backend; restarting current chapter at cursor")
            speechService.stop()
            speakCurrentChapter()
            if speechService.isSpeaking && !speechService.isPaused {
                nowPlayingService.updateNowPlayingInfo(
                    title: book.title, author: book.author, isPlaying: true
                )
            }
        }
    }

    /// Pause the current playback (TTS or audio) and save position.
    /// No-op for the persisted-state side-effects when nothing was actually
    /// playing — that guard prevents a stray pause (e.g. a sleep-timer
    /// expiry that races with a user-initiated stop, or a Bluetooth-
    /// suppress toggle that lands in pause-direction while nothing is
    /// playing) from clobbering `book.lastPlaybackStopped`, which the
    /// rewind-on-resume threshold reads to decide how far back to rewind
    /// on the next play.
    func pause() {
        pause(playingPauseSound: true)
    }

    /// Pause because CoreAudio reported an output-route change. A normal
    /// resume may keep using a synthesizer/engine graph bound to the old
    /// Bluetooth device, so the next resume cold-starts the backend at the
    /// saved cursor while preserving the user-facing paused state.
    func pauseForAudioRouteChange() {
        invalidatePlaybackBackendForAudioRouteChange()
        pause(playingPauseSound: true)
    }

    /// Mark retained audio state as route-stale without altering playback.
    /// CoreAudio sends this for transitions both to and from AirPods. A paused
    /// engine can otherwise claim to resume successfully while remaining
    /// attached to the old, now-silent output device.
    func invalidatePlaybackBackendForAudioRouteChange() {
        restartPlaybackBackendOnNextResume = true
        debugLog("audio route changed; next resume will cold-start playback backend")
    }

    /// Stop TextMouth's current media session and release Now Playing /
    /// headphone media controls while keeping the reader window open.
    /// Starting playback from TextMouth again reclaims the controls.
    func releaseMediaControls() {
        guard canReleaseMediaControls else { return }
        stop()
        mediaControlsReleased = true
        nowPlayingService.releaseMediaControls()
        announceToVoiceOver("Media controls released")
    }

    /// Toggle between play and pause states. Handles Where Am I interruption,
    /// audio book resume, TTS resume with rewind-on-resume, and cold start.
    func togglePlayPause() {
        // If Where Am I is speaking, stop the announcement and resume/don't resume book.
        // Don't allow toggling playback while Where Am I is active — it would cause
        // both the book and the announcement to play simultaneously.
        if WhereAmIInterruptionPolicy.blocksBookPlayback(
            isAnnouncementSpeaking: isWhereAmISpeaking
        ) {
            whereAmISynth.stopSpeaking(at: .immediate)
            isWhereAmISpeaking = false
            // Don't resume book — user explicitly pressed play/pause, not "dismiss Where Am I"
            wasPlayingBeforeWhereAmI = false
            return
        }

        if isAudioBook {
            if audioPlaybackService.isPaused {
                resumeAudioPlayback()
            } else if audioPlaybackService.isPlaying {
                pause()
            } else {
                play()
            }
            return
        }

        debugLog("togglePlayPause called, isSpeaking=\(speechService.isSpeaking) isPaused=\(speechService.isPaused)")
        if speechService.isPaused {
            resumeSpeechPlayback()
        } else if speechService.isSpeaking {
            pause()
        } else {
            play()
        }
    }

    /// Stop all playback completely and clear Now Playing info.
    /// Same gating principle as `pause()`: only persist
    /// `lastPlaybackStopped` and the current position when something was
    /// actually playing or paused. A redundant stop on a stopped/empty
    /// reader (cleanup paths, deinit, lifecycle handlers) shouldn't
    /// clobber the timestamp that drives smart rewind.
    func stop() {
        let wasActive: Bool
        if isAudioBook {
            wasActive = audioPlaybackService.isPlaying || audioPlaybackService.isPaused
        } else {
            wasActive = speechService.isSpeaking || speechService.isPaused
        }

        let wasSleepTimerFading = sleepTimerService.ownerID == book.id && sleepTimerService.isFadingOut
        // Stop audio FIRST, then restore volume. Restoring volume
        // while audio is still playing causes a brief pop of
        // full-volume audio (same fix pattern as pause()).
        if isAudioBook {
            audioPlaybackService.stop()
            audioPlaybackService.restoreVolume()
            isCurrentlyPlaying = false
            isCurrentlyPaused = false
        } else {
            speechService.stop()
            speechService.audioEngine.restoreVolume()
        }
        // Cancel the timer after playback is stopped. Its fade-cancellation
        // callback can now restore volume without briefly restarting direct
        // speech that this stop operation would immediately halt again.
        if wasSleepTimerFading {
            sleepTimerService.stop()
        }
        readingStatsService.endSession(bookID: book.id)
        nowPlayingService.clearNowPlaying()
        if wasActive {
            recordPlaybackStopped()
            savePosition()
        }
    }

    /// Speak the current chapter's text from the current character offset.
    /// Applies section filtering, punctuation pauses, and text substitutions before speaking.
    func speakCurrentChapter() {
        guard let content = content,
              content.chapters.indices.contains(currentChapterIndex) else { return }

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

        // Filter out skipped sections, apply punctuation pauses, then text substitutions.
        // Each stage returns an OffsetMap tracking how character positions shifted.
        // Compose all three into a single bidirectional map for offset conversion.
        let (filteredText, filterMap) = filterSkippedSections(chapterIndex: currentChapterIndex, text: chapter.text)
        let (pausedText, pauseMap) = applyPunctuationPauses(filteredText)
        let transformation = substitutionService.transform(pausedText)
        currentTransformation = transformation
        currentOffsetMap = ComposedOffsetMap(stages: [filterMap, pauseMap] + transformation.offsetMap.stages)
        let speakText = transformation.modifiedText
        // Convert original-text offset to modified-text offset using the full composed map
        let speakOffset = currentOffsetMap?.toModified(currentCharacterOffset) ?? currentCharacterOffset

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
        // Apply the full text transformation pipeline so pre-rendered audio
        // matches what speakCurrentChapter would produce.
        let rawText = content.chapters[nextIdx].text
        let (filteredText, _) = filterSkippedSections(chapterIndex: nextIdx, text: rawText)
        let (pausedText, _) = applyPunctuationPauses(filteredText)
        let chapterText = substitutionService.transform(pausedText).modifiedText
        nextChapterIndex = nextIdx

        // Keep look-ahead rendering under the same safety limit as the current
        // chapter. Oversized chapters remain playable through direct chunking.
        guard chapterText.utf16Length <= SpeechRenderCoordinator.maximumTextLength else {
            nextChapterEngine = nil
            nextChapterIndex = nil
            debugLog("preRender: skipped oversized chapter \(nextIdx) (\(chapterText.utf16Length) UTF-16 units)")
            return
        }

        // Capture generation so stale renders from rapid navigation are discarded
        let renderGeneration = chapterPlaybackGeneration
        SpeechRenderCoordinator.shared.render(
            text: chapterText,
            engine: engine,
            voice: speechService.currentVoice,
            wpm: speechService.wordsPerMinute,
            shouldStart: { [weak self] in
                guard let self else { return false }
                return Self.isCurrentPlaybackGeneration(
                    captured: renderGeneration,
                    current: self.chapterPlaybackGeneration
                )
            },
            completion: { [weak self] success in
            guard let self = self else { return }
            // Discard result if playback generation changed (user navigated elsewhere)
            guard Self.isCurrentPlaybackGeneration(
                captured: renderGeneration,
                current: self.chapterPlaybackGeneration
            ) else { return }
            if success {
                self.nextChapterEngine = engine
                self.debugLog("preRender: chapter \(nextIdx) ready (\(chapterText.utf16Length) UTF-16 units)")
            }
            }
        )
    }

    /// A render may publish its result only while the playback generation it
    /// captured is still current. Navigation increments the generation.
    nonisolated static func isCurrentPlaybackGeneration(captured: Int, current: Int) -> Bool {
        captured == current
    }

    // MARK: - Audio Book Playback

    /// Three audio-book layouts handled by this VM, each with a
    /// different relationship between AVPlayer time and the
    /// (chapter, characterOffset) pair the navigation system uses:
    ///
    /// - `multiFile`: each chapter is its own audio file. Player time
    ///   is already chapter-relative; no offset needed.
    /// - `segmented`: DAISY-style — chapters are time ranges within
    ///   one shared file. Chapter start = `audioSegments[i].startTime`.
    /// - `chaptersInOneFile`: an m4b (or similar) with chapter
    ///   metadata. Chapter start is the cumulative duration of all
    ///   preceding chapters' placeholder text divided by the
    ///   chars-per-second constant.
    /// - `singleFile`: no chapter splits at all (one mp3, one chapter).
    ///   Player time = chapter-relative offset directly.
    ///
    /// Picking the right layout is what makes the time observer
    /// store offsets the rest of the code can interpret correctly,
    /// and what makes navigateTo / skipCharacters seek to the
    /// right ABSOLUTE time for chapter-RELATIVE inputs.
    enum AudioLayout: Equatable {
        case multiFile
        case segmented
        case chaptersInOneFile
        case singleFile

        /// Resolve an audiobook's storage layout from the parser outputs.
        /// Segmented DAISY parsing also returns a file path for every segment,
        /// so segment metadata must take precedence over the non-empty file list.
        static func determine(
            hasChapterFiles: Bool,
            hasSegments: Bool,
            chapterCount: Int
        ) -> AudioLayout {
            if hasSegments { return .segmented }
            if hasChapterFiles { return .multiFile }
            if chapterCount > 1 { return .chaptersInOneFile }
            return .singleFile
        }

        func chapterStartTime(
            chapterIndex: Int,
            chapterUTF16Lengths: [Int],
            segmentStartTimes: [TimeInterval]
        ) -> TimeInterval {
            guard chapterUTF16Lengths.indices.contains(chapterIndex) else { return 0 }
            switch self {
            case .multiFile, .singleFile:
                return 0
            case .segmented:
                return segmentStartTimes.indices.contains(chapterIndex)
                    ? segmentStartTimes[chapterIndex]
                    : 0
            case .chaptersInOneFile:
                return Double(chapterUTF16Lengths.prefix(chapterIndex).reduce(0, +))
                    / ReaderViewModel.audioCharsPerSecond
            }
        }

        func relativeCharacterOffset(playerTime: TimeInterval, chapterStartTime: TimeInterval) -> Int {
            let relativeTime: TimeInterval
            switch self {
            case .segmented, .chaptersInOneFile:
                relativeTime = max(0, playerTime - chapterStartTime)
            case .multiFile, .singleFile:
                relativeTime = max(0, playerTime)
            }
            return AudioBookParser.characterOffset(forTime: relativeTime)
        }

        func absoluteSeekTime(characterOffset: Int, chapterStartTime: TimeInterval) -> TimeInterval {
            let relative = AudioBookParser.time(forCharacterOffset: characterOffset)
            switch self {
            case .segmented, .chaptersInOneFile:
                return chapterStartTime + relative
            case .multiFile, .singleFile:
                return relative
            }
        }
    }

    /// Determine which layout this audio book uses. Pre-conditions:
    /// `isAudioBook == true` and `content` is loaded.
    var audioLayout: AudioLayout {
        AudioLayout.determine(
            hasChapterFiles: !audioChapterFiles.isEmpty,
            hasSegments: !audioSegments.isEmpty,
            chapterCount: content?.chapters.count ?? 0
        )
    }

    /// Absolute time (seconds) at which the given chapter starts in
    /// the underlying audio file. Used both to translate
    /// chapter-relative offsets into AVPlayer seek targets and to
    /// translate the player's reported time back into a
    /// chapter-relative offset.
    ///
    /// For multi-file audio every chapter starts at 0 of its own
    /// file. For DAISY segments, it's `audioSegments[idx].startTime`.
    /// For an m4b with chapter metadata, it's the sum of preceding
    /// chapter placeholder lengths converted from chars to seconds.
    func chapterStartTime(_ chapterIndex: Int) -> TimeInterval {
        guard let content = content,
              chapterIndex >= 0,
              chapterIndex < content.chapters.count else { return 0 }
        return audioLayout.chapterStartTime(
            chapterIndex: chapterIndex,
            chapterUTF16Lengths: content.chapters.map { $0.text.utf16Length },
            segmentStartTimes: audioSegments.map(\.startTime)
        )
    }

    /// Wire up audio playback service callbacks for position tracking and chapter advancement.
    func setupAudioCallbacks() {
        audioPlaybackService.onPositionUpdate = { [weak self] time in
            // AVPlayer time observer fires on main queue (setupTimeObserver uses queue: .main),
            // so this is already on the main thread
            guard let self = self, self.isAudioBook else { return }

            // Convert AVPlayer time → (chapterIndex, chapter-relative
            // offset) according to this book's layout. Without this
            // conversion, an m4b with chapter markers would store
            // ABSOLUTE offsets in `currentCharacterOffset`, which the
            // skip / navigation code (which walks chapters by
            // text.count) interprets as chapter-relative — producing
            // wildly wrong skip targets. This was the root cause of
            // the user-reported "rewind 15s sometimes goes 60s+".
            switch self.audioLayout {
            case .multiFile, .singleFile:
                // Player time is chapter-relative directly.
                self.currentCharacterOffset = Int(time * Self.audioCharsPerSecond)
            case .segmented:
                // DAISY: subtract the segment's start time so the
                // stored offset is chapter-relative.
                if self.currentChapterIndex < self.audioSegments.count {
                    let segStart = self.audioSegments[self.currentChapterIndex].startTime
                    let relativeTime = max(0, time - segStart)
                    self.currentCharacterOffset = Int(relativeTime * Self.audioCharsPerSecond)
                } else {
                    self.currentCharacterOffset = Int(time * Self.audioCharsPerSecond)
                }
            case .chaptersInOneFile:
                // m4b-style: convert absolute time to a global character
                // offset, then look up which chapter contains it. This
                // ALSO advances `currentChapterIndex` automatically as
                // playback crosses chapter boundaries — without this,
                // the index stayed pinned to whatever it was set to at
                // playback start (the underlying issue behind random-
                // looking skip behavior in m4b chapter books).
                let absoluteOffset = Int(time * Self.audioCharsPerSecond)
                if let content = self.content {
                    let location = content.location(forGlobalOffset: absoluteOffset)
                    if location.chapterIndex != self.currentChapterIndex {
                        self.currentChapterIndex = location.chapterIndex
                    }
                    self.currentCharacterOffset = location.localOffset
                } else {
                    self.currentCharacterOffset = absoluteOffset
                }
            }
        }

        audioPlaybackService.onPlaybackFinished = { [weak self] in
            guard let self = self else { return }
            self.savePosition()
            self.sleepTimerService.notifyDocumentEnd(by: self.book.id)

            // Advance to next chapter (audio file)
            if let content = self.content {
                let nextIndex = self.currentChapterIndex + 1
                if nextIndex < content.chapters.count {
                    self.currentChapterIndex = nextIndex
                    self.currentCharacterOffset = 0
                    self.playAudioChapter()
                } else {
                    self.readingStatsService.endSession(bookID: self.book.id)
                    self.handleEndOfBook()
                }
            }
        }
    }

    /// Start playing the current audio chapter file from the current character offset.
    /// Handles multi-file audio books and DAISY segmented audio with clip boundaries.
    func playAudioChapter() {
        guard isAudioBook, let content = content,
              content.chapters.indices.contains(currentChapterIndex) else { return }

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

        // Translate chapter-relative offset to an absolute seek target.
        // chapterStartTime() handles all four layouts: 0 for multi-file
        // and single-file, segment.startTime for DAISY, and cumulative
        // preceding-chapter durations for an m4b with chapter markers.
        var timeOffset = Double(currentCharacterOffset) / Self.audioCharsPerSecond
        timeOffset += chapterStartTime(currentChapterIndex)

        // Set up a clip-end boundary so the chapter-finished callback
        // fires when playback crosses the chapter boundary, matching
        // the multi-file behaviour where the file simply ends.
        // Without this, an m4b with chapter markers would play
        // straight through every chapter as one continuous stream
        // and never auto-advance currentChapterIndex via the
        // playback-finished path. (The position observer also
        // advances it, so this is a defense-in-depth — the clip-end
        // callback is the canonical "chapter done" signal.)
        switch audioLayout {
        case .segmented:
            if currentChapterIndex < audioSegments.count {
                let segment = audioSegments[currentChapterIndex]
                if segment.endTime > segment.startTime {
                    audioPlaybackService.setClipEndTime(segment.endTime)
                }
            }
        case .chaptersInOneFile:
            // Clip end = this chapter's absolute end time.
            let chapterChars = content.chapters[currentChapterIndex].text.utf16Length
            let clipEnd = chapterStartTime(currentChapterIndex)
                + Double(chapterChars) / Self.audioCharsPerSecond
            audioPlaybackService.setClipEndTime(clipEnd)
        case .multiFile, .singleFile:
            // No clip end — the file's natural end IS the chapter's end
            // (or the whole book's end). Clear any clip end inherited
            // from a previous load() call so it doesn't stale-trigger.
            audioPlaybackService.setClipEndTime(nil)
        }

        audioPlaybackService.play(fromTime: timeOffset)

        isCurrentlyPlaying = true
        isCurrentlyPaused = false

        nowPlayingService.updateNowPlayingInfo(
            title: book.title, author: book.author, isPlaying: true
        )
    }

    /// Apply a new audio speed to the reader and the player, save it as this
    /// book's speed, and announce it.
    ///
    /// This is the single write path for user-chosen audio speeds; every
    /// step command reaches it through `adjustAudioSpeed(delta:)`. The value
    /// is clamped and snapped by `AudioSpeed.normalized(_:)`, so the speed
    /// that plays is exactly the one that is shown, announced, and saved.
    func setAudioSpeed(_ requestedSpeed: Double) {
        // A text book's `localWPM` holds words per minute; writing a
        // multiplier there would corrupt its speech speed.
        guard isAudioBook else { return }
        let newSpeed = AudioSpeed.normalized(requestedSpeed)
        audioSpeed = newSpeed
        audioPlaybackService.setSpeed(newSpeed)
        // The persisted schema stores an audio book's multiplier in the
        // `localWPM` slot; it is never interpreted as words per minute.
        book.localWPM = newSpeed
        saveLocalVoiceSettings()
        announceToVoiceOver(AudioSpeed.spokenLabel(for: newSpeed))
    }

    /// Move the audio speed by a signed multiplier delta (e.g. +0.25x).
    func adjustAudioSpeed(delta: Double) {
        setAudioSpeed(audioSpeed + delta)
    }

    // MARK: - End of Book Behavior

    /// Called when the last chapter finishes playing.
    /// Behavior depends on per-book override or global setting: stop, loop, or continue to next book.
    func handleEndOfBook() {
        // Audio completion does not flow through SpeechService's publishers.
        // Clear its mirrored UI state before applying stop/loop/continue.
        isCurrentlyPlaying = false
        isCurrentlyPaused = false
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
            // Route through the correct backend and start the next listening
            // session. Audiobook placeholder text cannot be looped via TTS.
            play()

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

    // MARK: - Sleep Timer

    /// Start a sleep timer owned by this book. Replaces any timer that
    /// might be running for another book. The provided duration is
    /// captured along with this book's pause/fade callbacks so the
    /// shared service knows what to do when the timer fires.
    /// Calling this with a timer already running just replaces it
    /// (the singleton's start() implicitly stops any previous timer).
    /// When `startPlaybackIfNeeded` is true, paused/stopped playback is
    /// resumed or started so the armed timer has audio to count against.
    func startSleepTimer(duration: SleepTimerDuration, startPlaybackIfNeeded: Bool = false) {
        // Capture one value for both timer scheduling and direct-speech fade
        // planning. A settings edit while the timer runs must not make the
        // utterance queue disagree with the timer's already-armed duration.
        let fadeOutDuration = settingsViewModel.sleepFadeOutDuration
        sleepTimerService.start(
            duration: duration,
            ownerID: book.id,
            onExpire: { [weak self] in
                guard let self = self else { return }
                let bookToken = String(self.book.id.uuidString.prefix(8))
                let wasPlaying = self.isAudioBook
                    ? self.audioPlaybackService.isPlaying
                    : self.speechService.isSpeaking
                let wasPaused = self.isAudioBook
                    ? self.audioPlaybackService.isPaused
                    : self.speechService.isPaused
                let backend = self.isAudioBook ? "audiobook" : "speech"
                SleepTimerService.appendDiagnosticLog(
                    "EXPIRY_HANDLER_BEGIN book=\(bookToken) backend=\(backend) "
                        + "playing=\(wasPlaying) paused=\(wasPaused)"
                )
                // Use the sleep-timer-specific pause path so the
                // end-of-fade completion does not play the normal
                // pause sound. The pause helper still stops audio
                // before restoring volume, and it also consumes the
                // service's one-shot fade-completion latch so the
                // "just finished fading" case is treated the same as
                // a still-in-progress fade.
                self.pause(playingPauseSound: false)
                let isPlayingAfterPause = self.isAudioBook
                    ? self.audioPlaybackService.isPlaying
                    : self.speechService.isSpeaking
                let isPausedAfterPause = self.isAudioBook
                    ? self.audioPlaybackService.isPaused
                    : self.speechService.isPaused
                SleepTimerService.appendDiagnosticLog(
                    "EXPIRY_HANDLER_END book=\(bookToken) playing=\(isPlayingAfterPause) "
                        + "paused=\(isPausedAfterPause)"
                )
                self.announceToVoiceOver("Sleep timer expired. Playback paused.")
            },
            onFadeStep: { [weak self] volume in
                guard let self = self else { return }
                if self.isAudioBook {
                    self.audioPlaybackService.setVolume(volume)
                } else {
                    self.speechService.setSleepTimerFadeVolume(
                        volume,
                        duration: fadeOutDuration
                    )
                }
            },
            onFadeCancelled: { [weak self] in
                guard let self else { return }
                if self.isAudioBook {
                    self.audioPlaybackService.restoreVolume()
                } else {
                    self.speechService.cancelSleepTimerFade()
                }
            },
            fadeOutDuration: fadeOutDuration
        )
        if startPlaybackIfNeeded {
            startSleepTimerPlaybackIfNeeded()
        }
    }

    /// Cancel the sleep timer if one is running. Anyone may cancel —
    /// no owner check, since "Cancel" should always work even if the
    /// user is in a different window from the one that started it.
    func cancelSleepTimer() {
        sleepTimerService.stop()
    }

    /// Restart the running timer with its original duration using the
    /// latest fade-out settings. Used by the "Reset Timer" button in
    /// the sleep timer sheet.
    func restartSleepTimer(startPlaybackIfNeeded: Bool = false) {
        guard let duration = sleepTimerService.duration else { return }
        // Rebuild every callback rather than asking the service to retain the
        // old closures. The direct-speech callback captures the effective fade
        // duration, so retaining it after a settings change would arm the new
        // timer with stale utterance-planning input.
        startSleepTimer(duration: duration, startPlaybackIfNeeded: startPlaybackIfNeeded)
    }

    /// Reset a running timer or — if the previous one already ended —
    /// arm a fresh timer with the same duration the user last picked.
    /// Wired to the "Restart Sleep Timer" keyboard shortcut and the
    /// experimental media-gesture detector. Both paths funnel through
    /// here so the user-visible behavior matches regardless of how
    /// they triggered it.
    /// No-op (with a VoiceOver announcement) when there's no prior
    /// duration to restore from — the user has never set a timer in
    /// this install, so we have nothing to repeat.
    func restartOrStartLastSleepTimer() {
        let bookToken = String(book.id.uuidString.prefix(8))
        if sleepTimerService.isActive {
            // Existing timer running — same as Reset Timer.
            SleepTimerService.appendDiagnosticLog(
                "RESTART_ACTION book=\(bookToken) result=reset-active remainingBefore=\(sleepTimerService.remainingSeconds)"
            )
            restartSleepTimer(startPlaybackIfNeeded: true)
            announceToVoiceOver("Timer reset.")
        } else if let last = sleepTimerService.lastUsedDuration {
            // Previous timer ended — re-arm with that duration.
            SleepTimerService.appendDiagnosticLog(
                "RESTART_ACTION book=\(bookToken) result=rearm-last duration=\(last.displayName)"
            )
            startSleepTimer(duration: last, startPlaybackIfNeeded: true)
            announceToVoiceOver("Timer restarted: \(last.displayName).")
        } else {
            // First-ever press — nothing to repeat.
            SleepTimerService.appendDiagnosticLog(
                "RESTART_ACTION book=\(bookToken) result=no-previous-duration"
            )
            announceToVoiceOver("No previous sleep timer to restart.")
        }
    }

    /// Start playback if the reader is currently paused or stopped.
    /// The sleep timer uses this after arming a new or reset timer so
    /// the timer's countdown matches the user's "read until it ends"
    /// intent, regardless of whether the timer was replaced or newly
    /// created.
    private func startSleepTimerPlaybackIfNeeded() {
        guard !isCurrentlyPlaying || isCurrentlyPaused else { return }
        togglePlayPause()
    }

    private func pause(playingPauseSound: Bool) {
        // Capture pre-pause playing state BEFORE we issue any pause calls.
        // The audio / speech services flip their flags synchronously, so
        // checking after would always return "not playing" and the guard
        // would never apply.
        let wasPlaying: Bool
        if isAudioBook {
            wasPlaying = Self.wasActivelyPlaying(
                isPlaying: audioPlaybackService.isPlaying,
                isPaused: audioPlaybackService.isPaused
            )
        } else {
            wasPlaying = Self.wasActivelyPlaying(
                isPlaying: speechService.isSpeaking,
                isPaused: speechService.isPaused
            )
        }

        if playingPauseSound {
            soundEffectService?.play(for: .pause)
        }
        // `AVPlayer.pause()` / `AVAudioPlayerNode.pause()` do not
        // restore volume on their own. The only explicit volume reset
        // lives in the fade-cleanup branch below, which is why the
        // sleep timer must keep a one-shot "fade just completed"
        // marker until this helper runs.
        let ownsSleepTimer = sleepTimerService.ownerID == book.id
        let completedSleepTimerFade = ownsSleepTimer && sleepTimerService.consumePendingFadeCompletion()
        let completingSleepFade = ownsSleepTimer && (sleepTimerService.isFadingOut || completedSleepTimerFade)
        // Halt audio output before any volume restoration. For TTS engine
        // playback, a sleep fade needs stronger handling than pause(): the
        // engine is stopped at volume 0 so downstream time-pitch/mixer
        // buffers cannot be exposed when volume is restored.
        if isAudioBook {
            audioPlaybackService.pause()
            // Only advertise the "playing-but-paused" state when there
            // was something to pause. Otherwise (book stopped or never
            // started, but pause() called by a stray notification) we'd
            // falsely tell the UI a paused track is loaded.
            if wasPlaying {
                isCurrentlyPlaying = true // still "playing" but paused
                isCurrentlyPaused = true
            }
        } else if completingSleepFade {
            speechService.pauseForSleepTimerFadeCompletion()
        } else {
            speechService.pause()
        }
        // Now safe to clean up fade state. Audio books still restore here;
        // TTS restores inside SpeechService after the engine has stopped.
        if completingSleepFade {
            sleepTimerService.stop()
            if isAudioBook { audioPlaybackService.restoreVolume() }
        } else {
            // Halt any minutes-based countdown so it doesn't keep
            // ticking during the pause and expire while the user is
            // taking a break. Mid-fade pauses fall through the branch
            // above and do not reach here. Heading/document-end modes
            // are no-ops — the service guards on duration kind.
            sleepTimerService.pauseCountdown(by: book.id)
        }
        readingStatsService.endSession(bookID: book.id)
        nowPlayingService.updateNowPlayingInfo(
            title: book.title, author: book.author, isPlaying: false
        )
        // Only record the stopped timestamp / persist position if we
        // actually transitioned from playing to paused. A no-op pause
        // (e.g. spurious media-key event when already paused, or a
        // toggle that landed in pause-direction during the BT suppress
        // window with nothing playing) should not update
        // book.lastPlaybackStopped — the rewind-on-resume threshold
        // depends on it being the moment the user stopped real playback.
        if wasPlaying {
            recordPlaybackStopped()
            savePosition()
        }
    }

    nonisolated static func wasActivelyPlaying(isPlaying: Bool, isPaused: Bool) -> Bool {
        isPlaying && !isPaused
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
            let now = Date()
            let elapsed = now.timeIntervalSince(stoppedAt)
            if !Self.hasReachedSmartRewindThreshold(
                lastStoppedAt: stoppedAt,
                now: now,
                threshold: settingsViewModel.rewindSmartThreshold
            ) {
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
                seekSpeechService(toOriginalOffset: newOffset)
            }
        case .paragraph:
            let newOffset = findParagraphStart(in: text, before: offset)
            if newOffset < offset {
                debugLog("rewindOnResume: paragraph rewind \(offset) -> \(newOffset)")
                currentCharacterOffset = newOffset
                seekSpeechService(toOriginalOffset: newOffset)
            }
        case .heading:
            if let heading = currentHeadingAtPosition() {
                let headingOffset = heading.chapterIndex == currentChapterIndex ? heading.characterOffset : 0
                if headingOffset < offset {
                    debugLog("rewindOnResume: heading rewind \(offset) -> \(headingOffset)")
                    currentCharacterOffset = headingOffset
                    seekSpeechService(toOriginalOffset: headingOffset)
                }
            }
        }
    }

    /// Determine whether a paused book has been idle long enough for smart rewind.
    /// The explicit clock makes boundary behavior deterministic in regression tests.
    nonisolated static func hasReachedSmartRewindThreshold(
        lastStoppedAt: Date,
        now: Date,
        threshold: TimeInterval
    ) -> Bool {
        now.timeIntervalSince(lastStoppedAt) >= threshold
    }

    /// Find the start of the current sentence by scanning backward for sentence-ending punctuation.
    func findSentenceStart(in text: String, before offset: Int) -> Int {
        Self.sentenceStart(in: text, before: offset)
    }

    /// Find the start of the current paragraph by scanning backward for double newlines.
    func findParagraphStart(in text: String, before offset: Int) -> Int {
        Self.paragraphStart(in: text, before: offset)
    }

    // MARK: - Punctuation Pauses

    /// Insert extra pause characters at punctuation to slow down dense text.
    /// Returns the paused text and an OffsetMap tracking where insertions occurred.
    /// Level 0 = off, 1 = subtle (periods), 2 = moderate (periods + commas), 3 = heavy (+ paragraph breaks)
    func applyPunctuationPauses(_ text: String) -> (text: String, offsetMap: OffsetMap) {
        Self.applyPunctuationPauses(text, level: settingsViewModel.punctuationPauseLevel)
    }

    static func applyPunctuationPauses(
        _ text: String,
        level: Double
    ) -> (text: String, offsetMap: OffsetMap) {
        guard level > 0 else { return (text, .identity) }

        // Build the set of (pattern, replacement) pairs.
        // Each replacement is the full string that replaces the pattern.
        // The extra characters (replacement.count - pattern.count) create the pause.
        var replacements: [(pattern: String, replacement: String)] = []

        // Level 1+: Extra pause after sentence-ending punctuation
        // ". " → ".. " (period repeated for TTS pause), same for ! and ?
        if level >= 1 {
            replacements.append((pattern: ". ", replacement: ".. "))
            replacements.append((pattern: "! ", replacement: "!. "))
            replacements.append((pattern: "? ", replacement: "?. "))
        }

        // Level 2+: Extra pause after commas
        // ", " → ",, " (comma repeated for TTS pause)
        if level >= 2 {
            replacements.append((pattern: ", ", replacement: ",, "))
        }

        // Level 3: Extra pause at paragraph breaks
        // "\n\n" → "\n\n.\n\n" (extra sentence break at paragraph boundary)
        if level >= 3 {
            replacements.append((pattern: "\n\n", replacement: "\n\n.\n\n"))
        }

        // Scan through text, matching patterns and tracking insertions.
        // At each position, check if any pattern matches. If so, emit the
        // full replacement and record the offset delta for the extra characters.
        var result = ""
        result.reserveCapacity(text.count + text.count / 10) // estimate ~10% growth
        var sourcePos = 0
        var cumulativeDelta = 0
        var points: [(targetPos: Int, cumulativeDelta: Int)] = []

        while sourcePos < text.utf16Length {
            var matched = false

            for (pattern, replacement) in replacements {
                // Check if pattern matches at current source position
                let patternLen = pattern.utf16Length
                if sourcePos + patternLen > text.utf16Length { continue }

                let startIdx = text.index(atUTF16Offset: sourcePos)
                let endIdx = text.index(atUTF16Offset: sourcePos + patternLen)
                if text[startIdx..<endIdx] == pattern {
                    // Emit the full replacement string
                    result += replacement

                    // Record the offset delta at the target position after the replacement.
                    // The delta is negative because the target text is longer (extra chars inserted).
                    let extraChars = replacement.utf16Length - patternLen
                    cumulativeDelta -= extraChars
                    let targetPosAfter = result.utf16Length
                    points.append((targetPos: targetPosAfter, cumulativeDelta: cumulativeDelta))

                    sourcePos += patternLen
                    matched = true
                    break
                }
            }

            if !matched {
                // No pattern matched — copy one character as-is
                let idx = text.index(atUTF16Offset: sourcePos)
                let character = text[idx]
                result.append(character)
                sourcePos += String(character).utf16Length
            }
        }

        if points.isEmpty {
            return (text, .identity)
        }
        return (result, OffsetMap(points: points))
    }
}
