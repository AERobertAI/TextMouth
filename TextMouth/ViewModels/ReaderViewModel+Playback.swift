import SwiftUI
import Combine
import AppKit
import AVFoundation

// MARK: - Playback Controls & Audio Engine

extension ReaderViewModel {

    // MARK: - TTS Playback

    /// Start speaking the current chapter from the current offset.
    /// For audio books, delegates to playAudioChapter().
    ///
    /// A text book first finds what it will say. When nothing speakable
    /// remains from the cursor, the book ends at once through its
    /// end-of-book behavior, without claiming media controls, making the
    /// play sound, or starting a Playing state or listening session.
    func play() {
        // Loading or closed readers cannot own a playback/statistics session.
        guard !hasClosed, !isLoading, let content,
              content.chapters.indices.contains(currentChapterIndex) else { return }
        // Don't start playback while Where Am I is speaking
        if WhereAmIInterruptionPolicy.blocksBookPlayback(
            isAnnouncementSpeaking: isWhereAmISpeaking
        ) { return }
        // Find what a text book will say before claiming playback, so a book
        // with nothing left to say ends before any playback state is claimed.
        var speechStart: SpeechStart?
        if !isAudioBook {
            guard let start = speechStartFromCursor() else {
                endBookWithNothingLeftToSpeak()
                return
            }
            speechStart = start
        }
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
        } else if let speechStart {
            startSpeaking(speechStart)
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
        // Restart from the cursor instead of resuming after an audio-route
        // change, and when nothing speakable follows the cursor in the loaded
        // speech (a skip made while paused can land there), since resuming
        // would restart that speech with nothing to say.
        if restartPlaybackBackendOnNextResume
            || !loadedSpeechHasSpeakableText(afterOriginalOffset: currentCharacterOffset) {
            restartPlaybackBackendOnNextResume = false
            speechService.stop()
            // The book ends instead when nothing speakable remains, for
            // example after skipping the rest of it while paused.
            if speakCurrentChapter() {
                nowPlayingService.updateNowPlayingInfo(
                    title: book.title, author: book.author, isPlaying: true
                )
            }
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

        let wasSleepTimerFading = isOwnSleepTimerFading
        // Stop audio FIRST, then restore volume. Restoring volume
        // while audio is still playing causes a brief pop of
        // full-volume audio (same fix pattern as pause()).
        if isAudioBook {
            audioPlaybackService.stop()
        } else {
            speechService.stop()
        }
        finishStopping(wasActive: wasActive, wasSleepTimerFading: wasSleepTimerFading)
    }

    /// Whether this book's sleep timer is fading playback out right now.
    private var isOwnSleepTimerFading: Bool {
        sleepTimerService.ownerID == book.id && sleepTimerService.isFadingOut
    }

    /// Everything stopping does once the playback backend is silent:
    /// restore full volume, show the stopped state, end a sleep-timer fade,
    /// close this book's listening session, clear Now Playing, and, when
    /// something was playing or paused, record the stop and save the
    /// position.
    ///
    /// - Parameters:
    ///   - wasActive: Whether playback was playing or paused before it was
    ///     silenced.
    ///   - wasSleepTimerFading: Whether this book's sleep timer was fading
    ///     out before playback was silenced.
    private func finishStopping(wasActive: Bool, wasSleepTimerFading: Bool) {
        if isAudioBook {
            audioPlaybackService.restoreVolume()
            isCurrentlyPlaying = false
            isCurrentlyPaused = false
        } else {
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

    /// Speak from the cursor, passing over text with nothing to say.
    ///
    /// Speech starts at the cursor when anything speakable follows it in its
    /// chapter, and otherwise at the start of the next chapter whose
    /// prepared speech has something to say. Chapters that are empty,
    /// entirely inside skipped sections, or deleted by substitutions are
    /// passed over. When nothing speakable remains, nothing is spoken and
    /// the book ends through its end-of-book behavior instead.
    ///
    /// - Returns: True when speech started. False when the cursor is not in
    ///   a chapter, or when the book ended instead (its end-of-book behavior
    ///   may itself have restarted playback).
    @discardableResult
    func speakCurrentChapter() -> Bool {
        guard let content = content,
              content.chapters.indices.contains(currentChapterIndex) else { return false }
        guard let start = speechStartFromCursor() else {
            endBookWithNothingLeftToSpeak()
            return false
        }
        startSpeaking(start)
        return true
    }

    /// Where speaking begins: a chapter's prepared speech and the offset in
    /// its spoken text to start from. The offset is 0 unless the chapter is
    /// the one holding the cursor.
    struct SpeechStart {
        let speech: ChapterSpeech
        let offset: Int
    }

    /// Where speech resumes from the cursor: the rest of the cursor's
    /// chapter when anything speakable follows the cursor there, otherwise
    /// the start of the next speakable chapter. Nil when nothing speakable
    /// remains in the book, and when no content is loaded or the cursor is
    /// outside it, which callers rule out first.
    ///
    /// A chapter that is speakable as a whole can still have nothing left
    /// after the cursor, when the cursor sits in a skipped section at the
    /// end of the chapter or in its trailing blank lines.
    func speechStartFromCursor() -> SpeechStart? {
        guard let current = preparedSpeech(forChapterAt: currentChapterIndex) else { return nil }
        // The cursor is an offset in the original text. Map it into the
        // spoken text; an offset inside a removed section can map past the
        // spoken text's end, so clamp it there.
        let offset = min(current.offsetMap.toModified(currentCharacterOffset), current.text.utf16Length)
        if Self.hasSpeakableText(in: current.text, fromSpokenOffset: offset) {
            return SpeechStart(speech: current, offset: offset)
        }
        return nextSpeakableChapterSpeech(from: currentChapterIndex + 1)
            .map { SpeechStart(speech: $0, offset: 0) }
    }

    /// Whether the speech loaded for the cursor's chapter has anything
    /// speakable after an original-text offset. A seek or resume that lands
    /// where nothing follows, such as in a skipped section that closes the
    /// chapter, must restart from the cursor instead, because continuing
    /// the loaded speech there would restart it with nothing to say.
    /// True when no speech is loaded, since nothing would be continued.
    func loadedSpeechHasSpeakableText(afterOriginalOffset offset: Int) -> Bool {
        guard let spokenText = currentTransformation?.modifiedText else { return true }
        let spokenOffset = currentOffsetMap?.toModified(offset) ?? offset
        return Self.hasSpeakableText(in: spokenText, fromSpokenOffset: spokenOffset)
    }

    /// Speak `start`'s chapter from its offset, then look ahead to the next
    /// speakable chapter. Starting a chapter other than the cursor's moves
    /// the cursor to the beginning of that chapter.
    func startSpeaking(_ start: SpeechStart) {
        let speech = start.speech
        if speech.chapterIndex != currentChapterIndex {
            debugLog("passing over silent text from chapter \(currentChapterIndex) to \(speech.chapterIndex)")
            currentChapterIndex = speech.chapterIndex
            currentCharacterOffset = 0
        }
        debugLog("startSpeaking: chapter=\(currentChapterIndex) offset=\(currentCharacterOffset) gen=\(chapterPlaybackGeneration)")

        currentTransformation = speech.transformation
        currentOffsetMap = speech.offsetMap
        utteranceBaseOffset = 0
        speechService.speak(speech.text, fromCharOffset: start.offset)

        // Pre-render the next chapter so it can start instantly when this one ends
        preRenderNextChapter()
    }

    /// End the book because nothing speakable remains from the cursor. The
    /// cursor stays where it is, and the end-of-book behavior decides what
    /// happens next.
    private func endBookWithNothingLeftToSpeak() {
        debugLog("nothing speakable from chapter=\(currentChapterIndex) offset=\(currentCharacterOffset); ending book")
        handleEndOfBook()
    }

    /// Pre-render the next speakable chapter's audio in the background so
    /// the chapter transition is instant. Chapters with nothing to say are
    /// passed over exactly as the utterance-finished path passes over them.
    func preRenderNextChapter() {
        // Forget any earlier look-ahead before choosing a new one. A
        // cancelled engine keeps the audio it already rendered, and the next
        // speakable chapter changes when sections are skipped, so an old
        // engine must never stay paired with a newly chosen chapter.
        nextChapterEngine?.cancelRender()
        nextChapterEngine = nil
        nextChapterIndex = nil

        // Render exactly the text playback will speak for that chapter.
        guard let speech = nextSpeakableChapterSpeech(from: currentChapterIndex + 1) else { return }
        let nextIdx = speech.chapterIndex
        let chapterText = speech.text

        // Keep look-ahead rendering under the same safety limit as the current
        // chapter. Oversized chapters remain playable through direct chunking.
        guard chapterText.utf16Length <= SpeechRenderCoordinator.maximumTextLength else {
            debugLog("preRender: skipped oversized chapter \(nextIdx) (\(chapterText.utf16Length) UTF-16 units)")
            return
        }

        let engine = AudioEngineService()
        nextChapterIndex = nextIdx
        // Capture generation so stale renders from rapid navigation are discarded
        let renderGeneration = chapterPlaybackGeneration
        // Checked before the render starts and again when it finishes.
        let isStillWanted: @MainActor @Sendable () -> Bool = { [weak self] in
            guard let self else { return false }
            return Self.isCurrentLookAhead(
                capturedGeneration: renderGeneration,
                currentGeneration: self.chapterPlaybackGeneration,
                renderedChapterIndex: nextIdx,
                chosenChapterIndex: self.nextChapterIndex
            )
        }
        SpeechRenderCoordinator.shared.render(
            SpeechRenderRequest(text: chapterText, voice: speechService.currentVoice),
            engine: engine,
            shouldStart: isStillWanted,
            completion: { [weak self] success in
                guard let self, success, isStillWanted() else { return }
                self.nextChapterEngine = engine
                self.debugLog("preRender: chapter \(nextIdx) ready (\(chapterText.utf16Length) UTF-16 units)")
            }
        )
    }

    /// A render may publish its result only while the playback generation it
    /// captured is still current. Navigation increments the generation.
    nonisolated static func isCurrentPlaybackGeneration(captured: Int, current: Int) -> Bool {
        captured == current
    }

    /// A look-ahead render may start, and its engine may be kept, only while
    /// playback is still on the generation it captured and its chapter is
    /// still the chosen look-ahead. Within one generation a newer look-ahead
    /// can choose a different chapter, for example after a section is
    /// skipped, and an engine must never be paired with a chapter it did not
    /// render.
    nonisolated static func isCurrentLookAhead(
        capturedGeneration: Int,
        currentGeneration: Int,
        renderedChapterIndex: Int,
        chosenChapterIndex: Int?
    ) -> Bool {
        isCurrentPlaybackGeneration(captured: capturedGeneration, current: currentGeneration)
            && chosenChapterIndex == renderedChapterIndex
    }

    // MARK: - Chapter Speech

    /// One chapter as the speech engine hears it, with the map back to the
    /// chapter's original text.
    struct ChapterSpeech {
        /// Index of the chapter this speech was prepared from.
        let chapterIndex: Int
        /// Result of the text substitutions, the pipeline's last stage.
        let transformation: TextTransformation
        /// Offsets through every stage (skipped sections, punctuation
        /// pauses, substitutions), between original and spoken text.
        let offsetMap: ComposedOffsetMap

        /// The exact text handed to the speech engine.
        var text: String { transformation.modifiedText }
    }

    /// Run one chapter through the playback text pipeline: remove skipped
    /// sections, add punctuation pauses, then apply text substitutions.
    /// Speaking a chapter and pre-rendering the next one both use this, so
    /// look-ahead audio always matches what playback would speak.
    ///
    /// - Returns: Nil when no content is loaded or the index is out of range.
    func preparedSpeech(forChapterAt chapterIndex: Int) -> ChapterSpeech? {
        guard let content, content.chapters.indices.contains(chapterIndex) else { return nil }
        // Each stage reports how it shifted character offsets; composing the
        // stages converts between original chapter text and spoken text.
        let (filteredText, filterMap) = filterSkippedSections(
            chapterIndex: chapterIndex,
            text: content.chapters[chapterIndex].text
        )
        let (pausedText, pauseMap) = applyPunctuationPauses(filteredText)
        let transformation = substitutionService.transform(pausedText)
        return ChapterSpeech(
            chapterIndex: chapterIndex,
            transformation: transformation,
            offsetMap: ComposedOffsetMap(stages: [filterMap, pauseMap] + transformation.offsetMap.stages)
        )
    }

    // MARK: - Speakable Chapters

    /// Whether text gives the speech engine anything to say: at least one
    /// character that is not whitespace or a line break. Playback passes
    /// over a chapter whose prepared speech fails this, exactly as it passes
    /// over a chapter with no text at all.
    nonisolated static func hasSpeakableText(_ text: some StringProtocol) -> Bool {
        text.contains { !$0.isWhitespace }
    }

    /// Whether anything speakable follows `spokenOffset` in `spokenText`,
    /// read exactly as speech starting there would read it: an offset past
    /// the end leaves nothing, and one inside a character starts at that
    /// character.
    nonisolated static func hasSpeakableText(in spokenText: String, fromSpokenOffset spokenOffset: Int) -> Bool {
        hasSpeakableText(spokenText[spokenText.index(atUTF16Offset: spokenOffset)...])
    }

    /// The index of the first chapter at or after `start` that `isSpeakable`
    /// accepts, or nil when none does.
    ///
    /// The search moves forward only and ends at the last chapter; it never
    /// wraps around to the beginning of the book. It therefore asks about
    /// each chapter at most once and always finishes, however many chapters
    /// are silent. A negative `start` searches from the first chapter.
    nonisolated static func nextSpeakableChapterIndex(
        from start: Int,
        chapterCount: Int,
        isSpeakable: (Int) -> Bool
    ) -> Int? {
        let first = max(0, start)
        guard first < chapterCount else { return nil }
        return (first..<chapterCount).first(where: isSpeakable)
    }

    /// The prepared speech of the first chapter at or after `start` that has
    /// anything to say once skipped sections, punctuation pauses, and text
    /// substitutions are applied, or nil when every remaining chapter is
    /// silent: empty, entirely inside skipped sections, or deleted by
    /// substitutions.
    func nextSpeakableChapterSpeech(from start: Int) -> ChapterSpeech? {
        guard let content else { return nil }
        // The search stops at the first chapter whose speech qualifies, so
        // the speech prepared last belongs to that chapter. Keeping it spares
        // the chosen chapter a second trip through the text pipeline.
        var lastPrepared: ChapterSpeech?
        let index = Self.nextSpeakableChapterIndex(
            from: start,
            chapterCount: content.chapters.count
        ) { chapterIndex in
            lastPrepared = preparedSpeech(forChapterAt: chapterIndex)
            return lastPrepared.map { Self.hasSpeakableText($0.text) } ?? false
        }
        return index == nil ? nil : lastPrepared
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
                    self.handleEndOfBook()
                }
            }
        }

        // A file that cannot be played reports here instead, on the main
        // queue like the callbacks above, and never also as finished: the
        // reader stops at the failed chapter rather than advancing.
        audioPlaybackService.onPlaybackFailed = { [weak self] failure in
            self?.handleAudioPlaybackFailure(failure)
        }
    }

    /// Start playing the current audio chapter file from the current character offset.
    /// Handles multi-file audio books and DAISY segmented audio with clip boundaries.
    ///
    /// A file that cannot be played is reported by the audio service before
    /// this returns, or later while it plays, and its failure handler stops
    /// the reader; this method then claims no Playing state at all.
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

        // A missing or unreadable file is refused here, after its failure
        // handler has already stopped the reader and told the listener.
        guard audioPlaybackService.load(url: audioURL) else { return }
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

        // Play refuses an item it finds has already failed, and reports it
        // through the same failure handler.
        guard audioPlaybackService.play(fromTime: timeOffset) else { return }

        isCurrentlyPlaying = true
        isCurrentlyPaused = false
        // Audio that plays again resolves a failure its alert still shows,
        // however playback was started.
        if audioPlaybackFailure != nil {
            dismissErrorAlert()
        }

        nowPlayingService.updateNowPlayingInfo(
            title: book.title, author: book.author, isPlaying: true
        )
    }

    // MARK: - Audio Playback Failures

    /// Stop the reader because its audio could not be played, and tell the
    /// listener which chapter and file failed and what to do about it.
    ///
    /// The reader stops exactly as `stop()` stops it: the Play button shows
    /// Play again, Now Playing is cleared, this book's listening session
    /// closes, and the position is saved. The cursor stays where the audio
    /// failed, so Retry plays from there, and neither the next chapter nor
    /// the end-of-book behavior follows. A running sleep-timer countdown is
    /// halted, as pausing halts it, so it is not spent on silence; playing
    /// again resumes it.
    private func handleAudioPlaybackFailure(_ failure: AudioPlaybackFailure) {
        guard !hasClosed else { return }
        let errorDescription = failure.underlyingError.map { "\($0.domain) \($0.code)" } ?? "none"
        debugLog("audio playback failed: reason=\(failure.reason) file=\(failure.fileName) error=\(errorDescription)")

        // The service has already halted and released its player. A
        // failure only ever comes from a file the reader loaded to play,
        // so playback was active and its stop is recorded.
        finishStopping(wasActive: true, wasSleepTimerFading: isOwnSleepTimerFading)
        sleepTimerService.pauseCountdown(by: book.id)
        // A Where Am I announcement that ends now has nothing to resume.
        wasPlayingBeforeWhereAmI = false

        let message = Self.audioPlaybackFailureMessage(
            for: failure,
            chapterNumber: currentChapterIndex + 1,
            bookHasPackage: !book.tmbDirectoryName.isEmpty
        )
        audioPlaybackFailure = failure
        errorMessage = message
        announceToVoiceOver(message)
    }

    /// What the listener is told when a chapter's audio could not be
    /// played: the chapter, the file, what went wrong, and what to do.
    ///
    /// - Parameters:
    ///   - failure: What the audio service reported.
    ///   - chapterNumber: The chapter's number, counted from one.
    ///   - bookHasPackage: Whether the book keeps its files in a `.tmb`
    ///     package, which a missing file is then said to be missing from.
    nonisolated static func audioPlaybackFailureMessage(
        for failure: AudioPlaybackFailure,
        chapterNumber: Int,
        bookHasPackage: Bool
    ) -> String {
        var problem = failure.problem
        let remedy: String
        switch failure.reason {
        case .fileMissing:
            if bookHasPackage {
                problem += " from the book's package"
            }
            remedy = "Re-import the book to restore it."
        case .fileUnreadable:
            remedy = "Re-import the book to replace it."
        case .failedDuringPlayback:
            remedy = "Choose Retry to try again, or re-import the book if it keeps failing."
        case .stalled:
            remedy = "Check that the disk holding your library is connected, then choose Retry."
        }
        return "Chapter \(chapterNumber) could not be played: \(problem). \(remedy)"
    }

    /// The error alert's Retry: close the alert and play the failed chapter
    /// again from the saved position, just as Play does. Play claims the
    /// media controls and a listening session again, which the failure gave
    /// up.
    func retryAudioPlayback() {
        dismissErrorAlert()
        // Playback that started some other way since the failure needs no
        // second start.
        guard !isPlaybackActivelyAdvancing else { return }
        play()
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

    /// Move the audio speed by a signed multiplier delta, such as
    /// `AudioSpeed.coarseStep` from the playback bar, menus, and shortcuts.
    func adjustAudioSpeed(delta: Double) {
        setAudioSpeed(audioSpeed + delta)
    }

    // MARK: - End of Book Behavior

    /// Called when the last chapter finishes playing.
    /// Behavior depends on per-book override or global setting: stop, loop, or continue to next book.
    func handleEndOfBook() {
        // Time after the end of the book is not listening time, so close this
        // book's session here, once, for every way a book can end. Another
        // window's session is left running.
        readingStatsService.endSession(bookID: book.id)
        // Audio completion does not flow through SpeechService's publishers.
        // Clear its mirrored UI state before applying stop/loop/continue.
        isCurrentlyPlaying = false
        isCurrentlyPaused = false
        // Determine behavior: per-book override or global setting
        var behavior = effectiveEndOfBookBehavior
        // Looping restarts speech at the first chapter with anything to say.
        // A text book with none (every section skipped, or all text deleted
        // by substitutions) would reach its end again at once, forever, so
        // it stops instead.
        if behavior == .loop, !isAudioBook, nextSpeakableChapterSpeech(from: 0) == nil {
            debugLog("end of book: nothing speakable to loop to; stopping")
            behavior = .stop
        }

        switch behavior {
        case .stop:
            readingStatsService.markBookFinished(bookID: book.id, title: book.title)
            finishListening(announcing: "Finished: \(book.title)")

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
                if sleepTimerEndsListeningHere {
                    // The next book would play on past this book's sleep
                    // timer, which can pause only the book that set it.
                    debugLog("end of book: this book's sleep timer is in effect; not starting the next book")
                    finishListening(
                        announcing: "Finished: \(book.title). Next book not started because of the sleep timer."
                    )
                } else {
                    announceToVoiceOver("Starting: \(nextBook.title)")
                    // Ask for the next book once VoiceOver has begun the
                    // announcement. This reader is kept until then, so
                    // closing its window meanwhile still continues, as
                    // announced.
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.continueToNextBookDelay) {
                        self.continueToNextBook(nextBook.id)
                    }
                }
            } else {
                finishListening(announcing: "Finished: \(book.title). No more books in folder.")
            }
        }
    }

    /// End listening with this finished book: Now Playing shows it
    /// stopped, and the listener hears `announcement`.
    private func finishListening(announcing announcement: String) {
        nowPlayingService.updateNowPlayingInfo(
            title: book.title, author: book.author, isPlaying: false
        )
        announceToVoiceOver(announcement)
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

    // MARK: - Continue to Next Book

    /// How long a finished book waits after announcing the next one before
    /// asking for it, so VoiceOver can begin "Starting: <title>" before the
    /// next book's window takes focus.
    static let continueToNextBookDelay: TimeInterval = 0.5

    /// Ask the next book to start playing, then ask for its reader window.
    ///
    /// The request comes first, so it is already waiting when anything
    /// acts on the notification: a reader open for that book claims it and
    /// plays at once, and a reader the notification opens claims it as
    /// soon as it has loaded. The notification goes out on this reader's
    /// own center, where the app opens the book's reader window, or
    /// brings it forward when it is already open.
    ///
    /// - Parameter nextBookID: The book after this one in its folder.
    func continueToNextBook(_ nextBookID: UUID) {
        let request = autoplayRequests.request(for: nextBookID, from: book.id)
        notificationCenter.post(
            name: .continueToNextBook,
            object: nil,
            userInfo: request.notificationUserInfo
        )
    }

    /// Start playing because a finished book continued to this one, when
    /// its request is waiting and this book has finished loading.
    ///
    /// The request is claimed, so it starts this book only once, whether
    /// it is claimed when loading ends or as soon as it is made for a
    /// reader that was already open. Playback starts the way Play starts
    /// it, from the saved position, or resumes a paused book, so listening
    /// statistics, Now Playing, sounds, and the passing over of silent
    /// chapters all apply, and nothing more is announced. A reader whose
    /// book is already playing keeps playing, untouched. A Where Am I
    /// announcement in this window is ended first, since playback cannot
    /// start while it speaks. A book that failed to load has nothing to
    /// play, so its request is claimed and dropped.
    ///
    /// A closed reader claims nothing, and a reader still loading leaves
    /// the request waiting until loading ends.
    func claimAutoplayRequest() {
        guard !hasClosed, !isLoading,
              autoplayRequests.consume(for: book.id) != nil else { return }
        debugLog("continue to next book: starting this book")
        cancelWhereAmIIfActive()
        playOrResume()
    }

    /// Throw away this book's waiting request because the book could not be
    /// loaded, so that the request cannot start it later.
    func discardAutoplayRequest() {
        guard autoplayRequests.consume(for: book.id) != nil else { return }
        debugLog("continue to next book: this book could not be loaded; request dropped")
    }

    /// Whether this book's own sleep timer ends listening with this book,
    /// so that Continue to Next Book does not start the next one.
    ///
    /// The timer pauses only the book that set it, so it could never pause
    /// the next book, which would play on past it. Continuing is therefore
    /// ruled out while the timer is in effect: counting down, fading out,
    /// or waiting for the end of a heading. It is also ruled out once a
    /// timer set for the end of the document has expired, since that timer
    /// fires as the book's last document ends, just before the book does.
    var sleepTimerEndsListeningHere: Bool {
        Self.sleepTimerEndsListening(
            timerBelongsToThisBook: sleepTimerService.ownerID == book.id,
            timerIsActive: sleepTimerService.isActive,
            timerDuration: sleepTimerService.duration
        )
    }

    /// The decision behind `sleepTimerEndsListeningHere`, from the sleep
    /// timer's state.
    ///
    /// - Parameters:
    ///   - timerBelongsToThisBook: Whether the finished book set the timer.
    ///   - timerIsActive: Whether the timer is counting down, waiting for
    ///     its moment, or fading out.
    ///   - timerDuration: What the timer was set for, which it keeps after
    ///     expiring until it is stopped or replaced.
    nonisolated static func sleepTimerEndsListening(
        timerBelongsToThisBook: Bool,
        timerIsActive: Bool,
        timerDuration: SleepTimerDuration?
    ) -> Bool {
        guard timerBelongsToThisBook else { return false }
        return timerIsActive || timerDuration == .endOfDocument
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

    /// Insert pause marks into `text` at `level` (see the instance method).
    ///
    /// Text with nothing to speak is returned unchanged at every level. The
    /// heavy level turns each blank-line break into "\n\n.\n\n", which would
    /// otherwise give blank lines, such as those left in front of a skipped
    /// section, a speakable "." and stop a silent chapter from being passed
    /// over.
    static func applyPunctuationPauses(
        _ text: String,
        level: Double
    ) -> (text: String, offsetMap: OffsetMap) {
        guard level > 0, hasSpeakableText(text) else { return (text, .identity) }

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
