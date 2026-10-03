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
            DiagnosticLog.event(.playback, "PLAYBACK_RESUME_REJECTED: audio resume rejected by backend; reloading current chapter")
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
            DiagnosticLog.event(.playback, "PLAYBACK_RESUME_REJECTED: speech resume rejected by backend; restarting current chapter at cursor")
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
        DiagnosticLog.trace(.playback, "audio route changed; next resume will cold-start playback backend")
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
            } else if audioPlaybackService.isPlaying || isWaitingForChapterDownload {
                // A reader waiting for its chapter's files to download
                // (FR02) shows Playing, so Play/Pause pauses it too.
                pause()
            } else {
                play()
            }
            return
        }

        DiagnosticLog.trace(.playback, "togglePlayPause called, isSpeaking=\(speechService.isSpeaking) isPaused=\(speechService.isPaused)")
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
            // Stopped speech looks ahead to nothing: the next Play chooses
            // the next chapter afresh. Abandoning the look-ahead now also
            // releases its rendered audio instead of holding it while idle.
            discardLookAhead()
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

    /// Speak `start`'s chapter from its offset, in a new chapter play, then
    /// look ahead to the next speakable chapter. Starting a chapter other
    /// than the cursor's moves the cursor to the beginning of that chapter.
    ///
    /// - Parameters:
    ///   - start: The chapter's prepared speech and the offset to start at.
    ///   - preRenderedEngine: An engine holding audio rendered ahead from
    ///     exactly this speech, as `takeLookAheadEngine(for:)` hands it
    ///     over, to play for an instant start; nil speaks the text.
    func startSpeaking(_ start: SpeechStart, playing preRenderedEngine: AudioEngineService? = nil) {
        let speech = start.speech
        if speech.chapterIndex != currentChapterIndex {
            DiagnosticLog.trace(.playback, "passing over silent text from chapter \(currentChapterIndex) to \(speech.chapterIndex)")
            currentChapterIndex = speech.chapterIndex
            currentCharacterOffset = 0
        }
        let play = beginChapterPlay()
        listenForSpeechEnd(of: play)
        DiagnosticLog.trace(.playback, "startSpeaking: chapter=\(currentChapterIndex) offset=\(currentCharacterOffset) gen=\(play.generation)")

        currentTransformation = speech.transformation
        currentOffsetMap = speech.offsetMap
        utteranceBaseOffset = 0
        if let preRenderedEngine {
            DiagnosticLog.trace(.playback, "using pre-rendered engine for chapter \(speech.chapterIndex)")
            speechService.usePreRenderedEngine(preRenderedEngine, text: speech.text, fromCharOffset: start.offset)
        } else {
            speechService.speak(speech.text, fromCharOffset: start.offset)
        }

        // Pre-render the next chapter so it can start instantly when this one ends
        preRenderNextChapter()
    }

    /// End the book because nothing speakable remains from the cursor. The
    /// cursor stays where it is, and the end-of-book behavior decides what
    /// happens next.
    private func endBookWithNothingLeftToSpeak() {
        DiagnosticLog.trace(.playback, "nothing speakable from chapter=\(currentChapterIndex) offset=\(currentCharacterOffset); ending book")
        handleEndOfBook()
    }

    // MARK: - Chapter Plays and Their Ends

    /// One play of one chapter: the chapter played, and the playback
    /// generation the play began in.
    ///
    /// Every start of a chapter's speech or audio begins a new play in a
    /// new generation: Play, a resume that starts the chapter again, a move
    /// to another chapter, a chapter advance, and a loop. The speech or
    /// audio service reports the end of what it plays to a callback made for
    /// the play under way, so the end of a play the reader has left, by
    /// beginning another or moving to another chapter, is told apart from
    /// the end of the play under way however late it is reported.
    struct ChapterPlay: Equatable, Sendable {
        /// The chapter the play plays.
        let chapterIndex: Int
        /// The playback generation the play began in.
        let generation: Int
    }

    /// Begin a new play of the cursor's chapter, in a new playback
    /// generation.
    func beginChapterPlay() -> ChapterPlay {
        chapterPlaybackGeneration += 1
        return ChapterPlay(chapterIndex: currentChapterIndex, generation: chapterPlaybackGeneration)
    }

    /// The play a reader stands in before any chapter has begun to play: the
    /// cursor's chapter, in the current generation.
    var cursorChapterPlay: ChapterPlay {
        ChapterPlay(chapterIndex: currentChapterIndex, generation: chapterPlaybackGeneration)
    }

    /// Whether the end reported for `play` ends the play under way.
    ///
    /// The end of a play the reader has left is stale: a later play began,
    /// which advances the generation, as moving a text book to another
    /// chapter does too (moving an audiobook stops its audio service, which
    /// then reports no end at all); or the reader closed. A stale end is
    /// ignored, with one trace line, so no chapter is advanced from twice or
    /// skipped.
    ///
    /// - Parameters:
    ///   - play: The play whose end was reported.
    ///   - backend: What reported it, "speech" or "audio", for the log.
    func endsPlayUnderWay(_ play: ChapterPlay, reportedBy backend: String) -> Bool {
        guard !hasClosed else {
            DiagnosticLog.trace(.playback, "ignoring the \(backend) end of chapter \(play.chapterIndex): the reader has closed")
            return false
        }
        guard play.generation == chapterPlaybackGeneration else {
            DiagnosticLog.trace(
                .playback,
                "ignoring a stale \(backend) end of chapter \(play.chapterIndex): its play began in "
                    + "generation \(play.generation), now \(chapterPlaybackGeneration)"
            )
            return false
        }
        return true
    }

    /// Take the end the speech service reports next as the end of `play`.
    func listenForSpeechEnd(of play: ChapterPlay) {
        speechService.onUtteranceFinished = { [weak self] in
            self?.speechDidFinish(play)
        }
    }

    /// Take the end the audio service reports next as the end of `play`.
    func listenForAudioEnd(of play: ChapterPlay) {
        audioPlaybackService.onPlaybackFinished = { [weak self] in
            self?.audioDidFinish(play)
        }
    }

    /// The speech of `play` finished. Save the position, tell the sleep
    /// timer this book's document ended, and move on to the next chapter
    /// with anything to say, or end the book when none remains.
    ///
    /// Chapters that are empty, entirely inside skipped sections, or deleted
    /// by substitutions are passed over, exactly as starting playback passes
    /// over them. The next chapter starts from audio rendered ahead when
    /// that audio is exactly its speech now, rendered from the text and
    /// voice in effect, for an instant start; audio rendered before the
    /// voice, a substitution rule, the punctuation pauses, or the skipped
    /// sections changed is discarded, and the chapter is spoken from its
    /// current text.
    private func speechDidFinish(_ play: ChapterPlay) {
        DiagnosticLog.trace(.playback, "speech finished: chapter=\(play.chapterIndex) offset=\(currentCharacterOffset) gen=\(play.generation)")
        guard endsPlayUnderWay(play, reportedBy: "speech") else { return }
        savePosition()
        sleepTimerService.notifyDocumentEnd(by: book.id)
        guard content != nil else { return }
        guard let speech = nextSpeakableChapterSpeech(from: play.chapterIndex + 1) else {
            DiagnosticLog.trace(.playback, "no more speakable chapters, book ended")
            handleEndOfBook()
            return
        }
        DiagnosticLog.trace(.playback, "advancing to chapter \(speech.chapterIndex) (from \(play.chapterIndex))")
        currentChapterIndex = speech.chapterIndex
        currentCharacterOffset = 0
        startSpeaking(SpeechStart(speech: speech, offset: 0), playing: takeLookAheadEngine(for: speech))
    }

    /// The audio of `play` played to its end. Save the position, tell the
    /// sleep timer this book's document ended, and play the next chapter,
    /// or end the book after the last.
    private func audioDidFinish(_ play: ChapterPlay) {
        guard endsPlayUnderWay(play, reportedBy: "audio") else { return }
        savePosition()
        sleepTimerService.notifyDocumentEnd(by: book.id)
        guard let content else { return }
        let nextIndex = play.chapterIndex + 1
        if nextIndex < content.chapters.count {
            currentChapterIndex = nextIndex
            currentCharacterOffset = 0
            playAudioChapter()
        } else {
            handleEndOfBook()
        }
    }

    // MARK: - Look-ahead

    /// The next speakable chapter, chosen while the current one plays and
    /// rendered ahead so it can start the moment the current one ends.
    ///
    /// The look-ahead holds its engine from the moment the render is queued,
    /// so discarding the look-ahead reaches a render still in progress.
    struct LookAhead {
        /// The chapter being rendered.
        let chapterIndex: Int
        /// What the render was asked for: the chapter's spoken text and the
        /// voice, as they were when the chapter was chosen.
        let signature: SpeechRenderSignature
        /// The engine rendering the chapter, and then holding its audio.
        let engine: AudioEngineService
    }

    /// What rendering `speech` asks of the synthesizer now: its exact text,
    /// in the voice chosen now.
    func renderRequest(for speech: ChapterSpeech) -> SpeechRenderRequest {
        SpeechRenderRequest(text: speech.text, voice: speechService.currentVoice)
    }

    /// The signature that audio for chapter `chapterIndex` must carry to be
    /// played now: the chapter's speech prepared from the current skipped
    /// sections, punctuation pauses, and substitution rules, in the current
    /// voice. Nil when there is no such chapter.
    func currentRenderSignature(forChapterAt chapterIndex: Int) -> SpeechRenderSignature? {
        preparedSpeech(forChapterAt: chapterIndex).map { renderRequest(for: $0).signature }
    }

    /// Pre-render the next speakable chapter's audio in the background so
    /// the chapter transition is instant. Chapters with nothing to say are
    /// passed over exactly as the utterance-finished path passes over them.
    func preRenderNextChapter() {
        // Forget any earlier look-ahead before choosing a new one. The next
        // speakable chapter changes when sections are skipped, so an old
        // engine must never stay paired with a newly chosen chapter.
        discardLookAhead()

        // Render exactly the text playback will speak for that chapter.
        guard let speech = nextSpeakableChapterSpeech(from: currentChapterIndex + 1) else { return }
        let nextIdx = speech.chapterIndex
        let chapterText = speech.text

        // Keep look-ahead rendering under the same safety limit as the current
        // chapter. Oversized chapters remain playable through direct chunking.
        guard chapterText.utf16Length <= SpeechRenderCoordinator.maximumTextLength else {
            DiagnosticLog.trace(.playback, "preRender: skipped oversized chapter \(nextIdx) (\(chapterText.utf16Length) UTF-16 units)")
            return
        }

        let request = renderRequest(for: speech)
        let lookAhead = LookAhead(chapterIndex: nextIdx, signature: request.signature, engine: AudioEngineService())
        self.lookAhead = lookAhead
        // Capture generation so stale renders from rapid navigation are discarded
        let renderGeneration = chapterPlaybackGeneration
        // Checked before the render starts and again when it finishes.
        let isStillWanted: @MainActor @Sendable () -> Bool = { [weak self] in
            guard let self else { return false }
            return Self.isCurrentLookAhead(
                capturedGeneration: renderGeneration,
                currentGeneration: self.chapterPlaybackGeneration,
                renderedChapterIndex: nextIdx,
                chosenChapterIndex: self.chosenLookAheadChapter(renderedBy: lookAhead.engine)
            )
        }
        renderScheduler.render(
            request,
            engine: lookAhead.engine,
            shouldStart: isStillWanted,
            completion: { [weak self] success in
                self?.finishLookAheadRender(lookAhead, succeeded: success && isStillWanted())
            }
        )
    }

    /// Keep a finished look-ahead render only while its audio is exactly what
    /// its chapter would render now, and otherwise leave nothing to look ahead
    /// to. A render whose inputs changed while it ran, such as a voice chosen,
    /// a substitution rule edited, the punctuation pause level moved, or a
    /// section skipped, is never kept.
    ///
    /// - Parameters:
    ///   - render: The look-ahead the render was queued for.
    ///   - succeeded: Whether the render produced audio and was still wanted
    ///     in its playback generation when it finished.
    private func finishLookAheadRender(_ render: LookAhead, succeeded: Bool) {
        // A render the reader has since replaced or discarded keeps nothing.
        guard chosenLookAheadChapter(renderedBy: render.engine) != nil else { return }
        guard succeeded else {
            DiagnosticLog.trace(.playback, "preRender: chapter \(render.chapterIndex) did not render, or playback moved on; nothing looked ahead to")
            lookAhead = nil
            return
        }
        // Prepare the chapter's speech again from the settings in effect now:
        // a setting changed while the render ran makes the signatures differ.
        let current = currentRenderSignature(forChapterAt: render.chapterIndex)
        guard let rendered = render.engine.renderedSignature, rendered == current else {
            DiagnosticLog.trace(.playback, "preRender: dropped chapter \(render.chapterIndex), rendered from inputs that changed while it ran (rendered \(render.engine.renderedSignature?.description ?? "nothing"), now \(current?.description ?? "no chapter"))")
            lookAhead = nil
            return
        }
        DiagnosticLog.trace(.playback, "preRender: chapter \(render.chapterIndex) ready (\(rendered))")
    }

    /// Forget the look-ahead. A render still in progress is abandoned: the
    /// synthesizer may run on to the end of the text, but the audio is never
    /// installed in the engine, and nothing keeps or plays it.
    func discardLookAhead() {
        lookAhead?.engine.cancelRender()
        lookAhead = nil
    }

    /// Take the look-ahead's engine to play `speech`, the chapter that is
    /// beginning, when it holds exactly that speech's audio: rendered for the
    /// same chapter, finished, and signed with the text and voice speech uses
    /// now. The look-ahead is used up either way.
    ///
    /// A look-ahead that cannot be used is discarded with one log line saying
    /// why, and the caller starts the chapter the ordinary way, from its
    /// current text, so the audio, the offsets, and Where Am I always describe
    /// the same speech.
    ///
    /// - Returns: The engine to adopt, or nil when the chapter must start
    ///   without pre-rendered audio.
    func takeLookAheadEngine(for speech: ChapterSpeech) -> AudioEngineService? {
        guard let lookAhead else { return nil }
        let current = renderRequest(for: speech).signature
        let reason: String
        if lookAhead.chapterIndex != speech.chapterIndex {
            reason = "it was for chapter \(lookAhead.chapterIndex)"
        } else if !lookAhead.engine.hasRenderedAudio {
            reason = "it was still rendering"
        } else if lookAhead.engine.renderedSignature != current {
            reason = "it was rendered from other inputs (\(lookAhead.engine.renderedSignature?.description ?? "unsigned"), now \(current))"
        } else {
            // Used up by the chapter that plays it: forget it without
            // abandoning anything.
            self.lookAhead = nil
            return lookAhead.engine
        }
        DiagnosticLog.trace(.playback, "preRender: not using the look-ahead for chapter \(speech.chapterIndex): \(reason)")
        discardLookAhead()
        return nil
    }

    /// Whether a text book's speech is playing or paused: the only time the
    /// reader keeps a look-ahead.
    var isSpeechSessionActive: Bool {
        !isAudioBook && speechService.isActive
    }

    /// Bring the look-ahead up to date after a setting that shapes spoken
    /// audio changed: the voice, the substitution rules or whether they
    /// apply, the punctuation pause level, or the skipped sections.
    ///
    /// Every such change comes through here, however it was made, so every
    /// input is handled alike. The look-ahead is kept while the next
    /// speakable chapter's speech, prepared from the current settings in the
    /// current voice, still has the signature it renders, as after a section
    /// is skipped in the chapter being spoken; a repeated notice of one change
    /// therefore does nothing more. Otherwise its render is abandoned and the
    /// next speakable chapter, which may now be another one, is queued to
    /// render from the current settings, so the next chapter keeps its
    /// instant start. Speed and pitch are not such settings: they are applied
    /// as the audio plays.
    ///
    /// Nothing happens unless a text book's speech is playing or paused.
    func refreshLookAhead() {
        guard isSpeechSessionActive else { return }
        if let lookAhead,
           let next = nextSpeakableChapterSpeech(from: currentChapterIndex + 1),
           next.chapterIndex == lookAhead.chapterIndex,
           renderRequest(for: next).signature == lookAhead.signature {
            return
        }
        DiagnosticLog.trace(.playback, "preRender: speech settings changed; choosing the chapter to render ahead again")
        preRenderNextChapter()
    }

    /// The chapter of the reader's look-ahead when that look-ahead renders
    /// with `engine`, or nil when the look-ahead is another render or there is
    /// none. A look-ahead chosen later is another render even when it is for
    /// the same chapter, so a superseded render is never started or kept.
    private func chosenLookAheadChapter(renderedBy engine: AudioEngineService) -> Int? {
        guard let lookAhead, lookAhead.engine === engine else { return nil }
        return lookAhead.chapterIndex
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
        /// Offsets through every stage (skipped sections, repeated symbols,
        /// punctuation pauses, substitutions), between original and spoken
        /// text.
        let offsetMap: ComposedOffsetMap

        /// The exact text handed to the speech engine.
        var text: String { transformation.modifiedText }
    }

    /// Run one chapter through the playback text pipeline: remove skipped
    /// sections, rewrite runs of a repeated symbol, add punctuation pauses,
    /// then apply text substitutions. Speaking a chapter and pre-rendering
    /// the next one both use this, so look-ahead audio always matches what
    /// playback would speak. Every setting is read as the chapter is
    /// prepared, so a change applies from the next chapter spoken.
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
        // Repeated symbols are rewritten before the pauses are added: the
        // pause marks are periods and commas, which would lengthen runs of
        // those symbols, and the substitution rules then see the counts.
        let (symbolText, symbolMap) = substitutionService.repeatedSymbolRule.apply(to: filteredText)
        let (pausedText, pauseMap) = applyPunctuationPauses(symbolText)
        let transformation = substitutionService.transform(pausedText)
        return ChapterSpeech(
            chapterIndex: chapterIndex,
            transformation: transformation,
            offsetMap: ComposedOffsetMap(stages: [filterMap, symbolMap, pauseMap] + transformation.offsetMap.stages)
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
    /// - `segmented`: DAISY-style — each chapter plays one or more
    ///   clips, time ranges within one or more shared files
    ///   (`audioSegments[i].clips`). The audio service plays them as one
    ///   chain and reports the chapter's own time, so, as for
    ///   `multiFile`, player time is chapter-relative.
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

        /// Where the chapter at `chapterIndex` starts on the time line the
        /// audio service reports: the sum of the chapters before it in one
        /// file of chapters, and 0 for every other layout, whose player
        /// time already counts from the chapter's start.
        func chapterStartTime(
            chapterIndex: Int,
            chapterUTF16Lengths: [Int]
        ) -> TimeInterval {
            guard chapterUTF16Lengths.indices.contains(chapterIndex) else { return 0 }
            switch self {
            case .multiFile, .segmented, .singleFile:
                return 0
            case .chaptersInOneFile:
                return Double(chapterUTF16Lengths.prefix(chapterIndex).reduce(0, +))
                    / ReaderViewModel.audioCharsPerSecond
            }
        }

        /// The chapter-relative character offset of `playerTime`, a time on
        /// the line the audio service reports, for a chapter starting at
        /// `chapterStartTime` on it.
        func relativeCharacterOffset(playerTime: TimeInterval, chapterStartTime: TimeInterval) -> Int {
            let relativeTime: TimeInterval
            switch self {
            case .chaptersInOneFile:
                relativeTime = max(0, playerTime - chapterStartTime)
            case .multiFile, .segmented, .singleFile:
                relativeTime = max(0, playerTime)
            }
            return AudioBookParser.characterOffset(forTime: relativeTime)
        }

        /// The time on the line the audio service reports at which to play
        /// chapter-relative `characterOffset`, for a chapter starting at
        /// `chapterStartTime` on it.
        func absoluteSeekTime(characterOffset: Int, chapterStartTime: TimeInterval) -> TimeInterval {
            let relative = AudioBookParser.time(forCharacterOffset: characterOffset)
            switch self {
            case .chaptersInOneFile:
                return chapterStartTime + relative
            case .multiFile, .segmented, .singleFile:
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

    /// Absolute time (seconds) at which the given chapter starts on the
    /// time line the audio service reports. Used both to translate
    /// chapter-relative offsets into seek targets and to translate the
    /// player's reported time back into a chapter-relative offset.
    ///
    /// For multi-file audio every chapter starts at 0 of its own file,
    /// and a DAISY segment's clips play as a chain timed from 0 at the
    /// chapter's start. For an m4b with chapter metadata, it's the sum of
    /// preceding chapter placeholder lengths converted from chars to
    /// seconds.
    func chapterStartTime(_ chapterIndex: Int) -> TimeInterval {
        guard let content = content,
              chapterIndex >= 0,
              chapterIndex < content.chapters.count else { return 0 }
        return audioLayout.chapterStartTime(
            chapterIndex: chapterIndex,
            chapterUTF16Lengths: content.chapters.map { $0.text.utf16Length }
        )
    }

    /// The clips segmented chapter `chapterIndex` plays, as the audio
    /// service chains them, each clip's file found in the book's audio
    /// folder (the book's own path), in its working copy when the reader
    /// has one (FR02); nil when the book has no segment for that chapter.
    func audioClipChain(forChapterAt chapterIndex: Int) -> AudioClipChain? {
        guard audioSegments.indices.contains(chapterIndex) else { return nil }
        return AudioClipChain(
            segment: audioSegments[chapterIndex],
            folder: playbackURL(for: URL(fileURLWithPath: book.filePath, isDirectory: true))
        )
    }

    /// Where a chapter's audio plays from.
    enum ChapterAudioSource: Equatable {
        /// A segmented chapter's clips, played one after another.
        case clips(AudioClipChain)
        /// One file: a multi-file book's chapter file, or the book's file.
        case file(URL)

        /// Every file the chapter plays from, each once, in playing order.
        var files: [URL] {
            switch self {
            case .clips(let chain):
                var seen = Set<URL>()
                return chain.clips.map(\.url).filter { seen.insert($0).inserted }
            case .file(let url):
                return [url]
            }
        }
    }

    /// Where chapter `chapterIndex`'s audio plays from: a segmented
    /// chapter's clips, a multi-file book's chapter file, or the book's one
    /// file, each in the book's working copy when the reader has one (FR02).
    /// A segmented book's chapter without a segment plays its file whole.
    func chapterAudioSource(forChapterAt chapterIndex: Int) -> ChapterAudioSource {
        if audioLayout == .segmented, let chain = audioClipChain(forChapterAt: chapterIndex) {
            return .clips(chain)
        }
        if !audioChapterFiles.isEmpty && chapterIndex < audioChapterFiles.count {
            // Multi-file audio book: each chapter is its own file.
            return .file(playbackURL(for: URL(fileURLWithPath: audioChapterFiles[chapterIndex])))
        }
        // Single audio file — use book file path
        return .file(playbackURL(for: URL(fileURLWithPath: book.filePath)))
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
            case .multiFile, .segmented, .singleFile:
                // Player time is chapter-relative directly: a DAISY
                // segment's clips play as one chain, timed from the
                // chapter's start whichever clip and file is playing.
                self.currentCharacterOffset = Int(time * Self.audioCharsPerSecond)
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

        // Each chapter's audio, once it starts, reports its end for its own
        // play (see `playAudioChapter()`); until one starts, the end belongs
        // to the cursor's chapter.
        listenForAudioEnd(of: cursorChapterPlay)

        // A file that cannot be played reports here instead, on the main
        // queue like the callbacks above, and never also as finished: the
        // reader stops at the failed chapter rather than advancing.
        audioPlaybackService.onPlaybackFailed = { [weak self] failure in
            self?.handleAudioPlaybackFailure(failure)
        }
    }

    /// Start playing the current audio chapter from the current character
    /// offset. Handles multi-file audio books, single files with or without
    /// chapter markers, and DAISY segmented audio, whose chapter plays its
    /// clips one after another.
    ///
    /// A file that cannot be played is reported by the audio service before
    /// this returns, or later while it plays, and its failure handler stops
    /// the reader; this method then claims no Playing state at all.
    ///
    /// Each call begins a new play of the chapter, whose end alone the
    /// audio service's next report can be: an end of an earlier play still
    /// on its way is stale.
    func playAudioChapter() {
        guard isAudioBook, let content = content,
              content.chapters.indices.contains(currentChapterIndex) else { return }
        listenForAudioEnd(of: beginChapterPlay())
        // A chapter whose file is only in the cloud is downloaded first,
        // and plays once it is here: the player is never handed a file it
        // would wait on the network for (FR02).
        guard chapterFilesReadyToPlay() else { return }
        // Audio that cannot be played claims no Playing state.
        guard startCurrentChapterAudio(in: content) else { return }

        isCurrentlyPlaying = true
        isCurrentlyPaused = false
        // Audio that plays again resolves a failure its alert still shows,
        // however playback was started.
        if audioPlaybackFailure != nil || cloudSession.chapterFailure != nil {
            dismissErrorAlert()
        }

        nowPlayingService.updateNowPlayingInfo(
            title: book.title, author: book.author, isPlaying: true
        )
    }

    /// Load the current chapter's audio and play it from the cursor.
    ///
    /// - Returns: Whether playback started. A missing or unreadable file is
    ///   refused before playing, after its failure handler has already
    ///   stopped the reader and told the listener, and an item that has
    ///   already failed is reported through the same handler.
    private func startCurrentChapterAudio(in content: DocumentContent) -> Bool {
        let audioURL: URL
        switch chapterAudioSource(forChapterAt: currentChapterIndex) {
        case .clips(let chain):
            // A segmented chapter plays its clips, in one file or several,
            // as one chain timed from the chapter's start, so the cursor's
            // offset is the time to play from, whichever clip holds it.
            audioPlaybackService.setSpeed(audioSpeed)
            return audioPlaybackService.playClips(
                chain,
                fromChapterTime: AudioBookParser.time(forCharacterOffset: currentCharacterOffset)
            )
        case .file(let url):
            audioURL = url
        }

        guard audioPlaybackService.load(url: audioURL) else { return false }
        audioPlaybackService.setSpeed(audioSpeed)

        // Translate chapter-relative offset to an absolute seek target.
        // chapterStartTime() handles the file layouts: 0 for multi-file
        // and single-file, and cumulative preceding-chapter durations for
        // an m4b with chapter markers.
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
        case .chaptersInOneFile:
            // Clip end = this chapter's absolute end time.
            let chapterChars = content.chapters[currentChapterIndex].text.utf16Length
            let clipEnd = chapterStartTime(currentChapterIndex)
                + Double(chapterChars) / Self.audioCharsPerSecond
            audioPlaybackService.setClipEndTime(clipEnd)
        case .multiFile, .segmented, .singleFile:
            // No clip end — the file's natural end IS the chapter's end
            // (or the whole book's end). Clear any clip end inherited
            // from a previous load() call so it doesn't stale-trigger. A
            // segmented book reaches here only for a chapter without a
            // segment, which plays its file whole.
            audioPlaybackService.setClipEndTime(nil)
        }

        // Play refuses an item it finds has already failed, and reports it
        // through the same failure handler.
        return audioPlaybackService.play(fromTime: timeOffset)
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
        DiagnosticLog.event(
            .playback,
            "AUDIO_PLAYBACK_FAILED: reason=\(failure.reason) file=\(DiagnosticLog.loggablePath(failure.url)) "
                + "error=\(errorDescription)"
        )

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
            DiagnosticLog.trace(.playback, "end of book: nothing speakable to loop to; stopping")
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
                    DiagnosticLog.trace(.playback, "end of book: this book's sleep timer is in effect; not starting the next book")
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
        DiagnosticLog.trace(.playback, "continue to next book: starting this book")
        cancelWhereAmIIfActive()
        playOrResume()
    }

    /// Throw away this book's waiting request because the book could not be
    /// loaded, so that the request cannot start it later.
    func discardAutoplayRequest() {
        guard autoplayRequests.consume(for: book.id) != nil else { return }
        DiagnosticLog.trace(.playback, "continue to next book: this book could not be loaded; request dropped")
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
                SleepTimerService.log(
                    .event,
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
                SleepTimerService.log(
                    .event,
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
            SleepTimerService.log(
                .event,
                "RESTART_ACTION book=\(bookToken) result=reset-active remainingBefore=\(sleepTimerService.remainingSeconds)"
            )
            restartSleepTimer(startPlaybackIfNeeded: true)
            announceToVoiceOver("Timer reset.")
        } else if let last = sleepTimerService.lastUsedDuration {
            // Previous timer ended — re-arm with that duration.
            SleepTimerService.log(
                .event,
                "RESTART_ACTION book=\(bookToken) result=rearm-last duration=\(last.displayName)"
            )
            startSleepTimer(duration: last, startPlaybackIfNeeded: true)
            announceToVoiceOver("Timer restarted: \(last.displayName).")
        } else {
            // First-ever press — nothing to repeat.
            SleepTimerService.log(
                .event,
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
            // A reader waiting for its chapter's files to download (FR02)
            // shows Playing while nothing plays yet, so it counts as
            // playing: it is left paused at the chapter, below.
            wasPlaying = Self.wasActivelyPlaying(
                isPlaying: audioPlaybackService.isPlaying,
                isPaused: audioPlaybackService.isPaused
            ) || isWaitingForChapterDownload
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
            // Stop waiting for a chapter's download, so the chapter does not
            // start when the download ends (a sleep timer that ran out would
            // otherwise have the book play on).
            stopWaitingForChapterDownload(because: "playback paused")
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
                DiagnosticLog.trace(.playback, "rewindOnResume: smart mode skip, elapsed=\(Int(elapsed))s < threshold=\(Int(settingsViewModel.rewindSmartThreshold))s")
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
                DiagnosticLog.trace(.playback, "rewindOnResume: sentence rewind \(offset) -> \(newOffset)")
                currentCharacterOffset = newOffset
                seekSpeechService(toOriginalOffset: newOffset)
            }
        case .paragraph:
            let newOffset = findParagraphStart(in: text, before: offset)
            if newOffset < offset {
                DiagnosticLog.trace(.playback, "rewindOnResume: paragraph rewind \(offset) -> \(newOffset)")
                currentCharacterOffset = newOffset
                seekSpeechService(toOriginalOffset: newOffset)
            }
        case .heading:
            if let heading = currentHeadingAtPosition() {
                let headingOffset = heading.chapterIndex == currentChapterIndex ? heading.characterOffset : 0
                if headingOffset < offset {
                    DiagnosticLog.trace(.playback, "rewindOnResume: heading rewind \(offset) -> \(headingOffset)")
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
    ///
    /// The text is read one character at a time from the start. At each
    /// character the level's pauses are tried in order, and the first whose
    /// pattern the characters there spell exactly is replaced; otherwise the
    /// character is kept. The text between pauses is copied in pieces, and a
    /// UTF-16 offset is measured only where a pause is added, so the work
    /// grows with the text's length. Locating every character by its UTF-16
    /// offset, and measuring the growing result after every pause, made the
    /// work grow with the square of its length on non-ASCII text (PERF05:
    /// 1.9 to 3.1 s for 500K characters).
    ///
    /// Pure, so speech can be prepared off the main actor.
    nonisolated static func applyPunctuationPauses(
        _ text: String,
        level: Double
    ) -> (text: String, offsetMap: OffsetMap) {
        guard level > 0, hasSpeakableText(text) else { return (text, .identity) }
        let pauses = PunctuationPause.pauses(atLevel: level)
        // Every pattern begins with one of a few ASCII bytes, so a character
        // beginning with any other byte is passed over at once.
        var beginsAPause = [Bool](repeating: false, count: 128)
        for pause in pauses {
            beginsAPause[Int(pause.pattern[0])] = true
        }

        let utf8 = text.utf8
        var paused = ""
        paused.reserveCapacity(text.utf8.count + text.utf8.count / 10)
        var points: [(targetPos: Int, cumulativeDelta: Int)] = []
        // The text before `copiedUpTo` is in `paused` already, pauses and
        // all; `copiedLength` is its length in `text`, in UTF-16 units, and
        // `addedLength` how much longer the pauses made it.
        var copiedUpTo = text.startIndex
        var copiedLength = 0
        var addedLength = 0
        var index = text.startIndex

        while index < text.endIndex {
            let byte = utf8[index]
            guard byte < 0x80, beginsAPause[Int(byte)],
                  let (pause, patternEnd) = firstPause(of: pauses, in: text, at: index) else {
                index = text.index(after: index)
                continue
            }
            paused += text[copiedUpTo..<index]
            paused += pause.replacement
            copiedLength += text.utf16.distance(from: copiedUpTo, to: patternEnd)
            addedLength += pause.addedLength
            // From here on, an offset in the paused text less the length
            // the pauses added is the offset in `text`.
            points.append((targetPos: copiedLength + addedLength, cumulativeDelta: -addedLength))
            copiedUpTo = patternEnd
            index = patternEnd
        }

        guard !points.isEmpty else { return (text, .identity) }
        paused += text[copiedUpTo...]
        return (paused, OffsetMap(points: points))
    }

    /// The first of `pauses` whose pattern the characters at `index` in
    /// `text` spell exactly, and where its pattern ends; nil when none does.
    private nonisolated static func firstPause(
        of pauses: [PunctuationPause],
        in text: String,
        at index: String.Index
    ) -> (pause: PunctuationPause, patternEnd: String.Index)? {
        for pause in pauses {
            if let patternEnd = pause.patternEnd(in: text, at: index) {
                return (pause, patternEnd)
            }
        }
        return nil
    }

    /// One pause mark the punctuation pauses add: a pattern of punctuation
    /// and spacing, and the text that replaces it, which repeats a mark so
    /// the voice pauses longer there.
    struct PunctuationPause {
        /// The characters replaced, each a single ASCII character, as bytes.
        let pattern: [UInt8]
        /// The text put in their place.
        let replacement: String
        /// How many UTF-16 units longer the replacement is than the pattern.
        let addedLength: Int

        /// A pause that replaces `pattern`, ASCII characters only, with
        /// `replacement`.
        init(replacing pattern: String, with replacement: String) {
            self.pattern = Array(pattern.utf8)
            self.replacement = replacement
            addedLength = replacement.utf16.count - pattern.utf16.count
        }

        /// The pauses `level` adds, in the order they are tried at each
        /// character. Level 1 and up repeats the mark after a sentence's
        /// end (". " becomes ".. ", and "!" and "?" are followed by a
        /// period), level 2 and up after a comma, and level 3 adds a
        /// sentence of its own at each paragraph break.
        static func pauses(atLevel level: Double) -> [PunctuationPause] {
            var pauses: [PunctuationPause] = []
            if level >= 1 {
                pauses.append(PunctuationPause(replacing: ". ", with: ".. "))
                pauses.append(PunctuationPause(replacing: "! ", with: "!. "))
                pauses.append(PunctuationPause(replacing: "? ", with: "?. "))
            }
            if level >= 2 {
                pauses.append(PunctuationPause(replacing: ", ", with: ",, "))
            }
            if level >= 3 {
                pauses.append(PunctuationPause(replacing: "\n\n", with: "\n\n.\n\n"))
            }
            return pauses
        }

        /// Where this pause's pattern ends in `text` when the characters
        /// beginning at `index`, a character boundary, spell it exactly; nil
        /// otherwise.
        ///
        /// Each byte of the pattern must be a whole character, as the
        /// pattern's characters compare with the text's: a period, space, or
        /// line break that a combining mark follows is another character,
        /// and gets no pause.
        func patternEnd(in text: String, at index: String.Index) -> String.Index? {
            let utf8 = text.utf8
            var position = index
            for byte in pattern {
                guard position < text.endIndex, utf8[position] == byte else { return nil }
                let next = text.index(after: position)
                // The character here is this one byte and nothing more.
                guard utf8.distance(from: position, to: next) == 1 else { return nil }
                position = next
            }
            return position
        }
    }
}
