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
    ///
    /// When the chapter speech starts in is long and its speech is being
    /// prepared off the main thread from exactly the settings in force, as
    /// the chapter a book opens at is (`prepareOpenedChapterSpeech()`), Play
    /// waits for that speech instead of preparing the chapter again on the
    /// main thread, showing Playing meanwhile (`waitForChapterSpeech(_:)`).
    /// Play pressed while it waits changes nothing.
    func play() {
        // Loading or closed readers cannot own a playback/statistics session.
        guard !hasClosed, !isLoading, let content,
              content.chapters.indices.contains(currentChapterIndex) else { return }
        // Don't start playback while Where Am I is speaking
        if WhereAmIInterruptionPolicy.blocksBookPlayback(
            isAnnouncementSpeaking: isWhereAmISpeaking
        ) { return }
        // A play waiting for its chapter's speech starts once it is ready.
        guard !isWaitingForChapterSpeech else { return }
        // Find what a text book will say before claiming playback, so a book
        // with nothing left to say ends before any playback state is claimed.
        var speechStart: SpeechStart?
        var awaitedSpeech: ChapterSpeechInputs?
        if !isAudioBook {
            switch searchForSpeechStart(preparingLongChapters: .nowUnlessUnderWay) {
            case .noneLeft:
                endBookWithNothingLeftToSpeak()
                return
            case .found(let start):
                speechStart = start
            case .preparingInBackground(let inputs):
                awaitedSpeech = inputs
            }
        }
        // The book plays again, so it no longer rests finished at its end; a
        // book with nothing left to say ended again above instead.
        hasFinishedBook = false
        restartPlaybackBackendOnNextResume = false
        mediaControlsReleased = false
        nowPlayingService.activateRemoteCommandsIfNeeded()
        soundEffectService?.play(for: .play)
        recordPlaybackStarted()
        readingStatsService.startSession(bookID: book.id)
        // Resume any sleep-timer countdown that was halted at the
        // matching pause(). No-op when no countdown was paused (cold
        // start, expired/cancelled timer, heading/chapter mode).
        sleepTimerService.resumeCountdown(by: readerID)
        if isAudioBook {
            playAudioChapter()
        } else if let speechStart {
            startSpeakingAsNowPlaying(speechStart)
        } else if let awaitedSpeech {
            waitForChapterSpeech(awaitedSpeech)
        }
    }

    /// Speak `start`'s chapter from its offset (`startSpeaking(_:playing:)`),
    /// and tell Now Playing the book plays.
    private func startSpeakingAsNowPlaying(_ start: SpeechStart) {
        startSpeaking(start)
        nowPlayingService.updateNowPlayingInfo(
            title: book.title, author: book.author, isPlaying: true
        )
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
        sleepTimerService.resumeCountdown(by: readerID)
        if restartPlaybackBackendOnNextResume {
            restartPlaybackBackendOnNextResume = false
            audioPlaybackService.stop()
            playAudioChapter()
            return
        }
        // Resume at the volume the place calls for, should this reader's
        // sleep timer have been cancelled or replaced during the pause, in
        // this window or another (TODO P01).
        fadeOutBeforeSleepTimerStop()
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
        sleepTimerService.resumeCountdown(by: readerID)
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
            // Nor start a play waiting for its chapter's speech, which shows
            // Playing: it pauses, as a book the announcement paused stays
            // paused, whether its speech is ready or still being prepared.
            if isWaitingForChapterSpeech {
                pause(playingPauseSound: false)
            }
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
        } else if speechService.isSpeaking || isWaitingForChapterSpeech {
            // A reader waiting for its chapter's speech shows Playing, so
            // Play/Pause pauses it too.
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
            // A play waiting for its chapter's speech counts, as it does
            // for `pause()`.
            wasActive = speechService.isSpeaking || speechService.isPaused || isWaitingForChapterSpeech
        }

        let wasSleepTimerFading = isOwnSleepTimerFading
        // Stop audio FIRST, then restore volume. Restoring volume
        // while audio is still playing causes a brief pop of
        // full-volume audio (same fix pattern as pause()).
        if isAudioBook {
            audioPlaybackService.stop()
        } else {
            stopWaitingForChapterSpeech()
            speechService.stop()
            // Stopped speech looks ahead to nothing: the next Play chooses
            // the next chapter afresh. Abandoning the look-ahead now also
            // releases its rendered audio instead of holding it while idle.
            discardLookAhead()
        }
        // A closed reader, which `close()` stops, keeps no prepared speech:
        // SwiftUI may keep the closed window, and its reader, alive (PERF27).
        if hasClosed {
            chapterSpeechCache.removeAll()
        }
        finishStopping(wasActive: wasActive, wasSleepTimerFading: wasSleepTimerFading)
    }

    /// Whether this reader's sleep timer is fading playback out right now.
    private var isOwnSleepTimerFading: Bool {
        sleepTimerService.ownerID == readerID && sleepTimerService.isFadingOut
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
    ///   - wasSleepTimerFading: Whether this reader's sleep timer was fading
    ///     out before playback was silenced.
    private func finishStopping(wasActive: Bool, wasSleepTimerFading: Bool) {
        if isAudioBook {
            audioPlaybackService.restoreVolume()
            isCurrentlyPlaying = false
            isCurrentlyPaused = false
        } else {
            // Speech that never made its engine has no volume to restore.
            speechService.restoreEngineVolume()
        }
        // Cancel the timer after playback is stopped. Its fade-cancellation
        // callback can now restore volume without briefly restarting direct
        // speech that this stop operation would immediately halt again.
        if wasSleepTimerFading {
            sleepTimerService.stop()
        }
        readingStatsService.endSession(bookID: book.id)
        // A stopped reader rests wherever it is with no media session, so
        // its skips move the cursor only: a finished book that is stopped,
        // by Release Media Controls or by closing, is finished no longer.
        hasFinishedBook = false
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
    /// outside it, which callers rule out first. A chapter whose speech is
    /// not kept yet is prepared at once, on the main actor.
    ///
    /// A chapter that is speakable as a whole can still have nothing left
    /// after the cursor, when the cursor sits in a skipped section at the
    /// end of the chapter or in its trailing blank lines.
    func speechStartFromCursor() -> SpeechStart? {
        if case .found(let start) = searchForSpeechStart(preparingLongChapters: .now) {
            return start
        }
        return nil
    }

    /// What a search for where speech begins from the cursor found.
    enum SpeechStartSearch {
        /// Where speech begins.
        case found(SpeechStart)
        /// Nothing speakable remains in the book.
        case noneLeft
        /// The chapter the search reached is long, and its speech is being
        /// prepared in the background from exactly these inputs, the ones
        /// in force, before the search can go on.
        case preparingInBackground(ChapterSpeechInputs)
    }

    /// Search for where speech begins from the cursor, as
    /// `speechStartFromCursor()` describes, preparing a long chapter whose
    /// speech is not kept yet as `preparation` says: Play asks for
    /// `.nowUnlessUnderWay`, and every other caller for `.now`.
    private func searchForSpeechStart(preparingLongChapters preparation: LongChapterPreparation) -> SpeechStartSearch {
        guard let inputs = speechInputs(forChapterAt: currentChapterIndex) else { return .noneLeft }
        if preparation == .nowUnlessUnderWay, waitsForPreparation(of: inputs) {
            return .preparingInBackground(inputs)
        }
        let current = preparedSpeech(for: inputs)
        // The cursor is an offset in the original text. Map it into the
        // spoken text; an offset inside a removed section can map past the
        // spoken text's end, so clamp it there.
        let offset = min(current.offsetMap.toModified(currentCharacterOffset), current.text.utf16Length)
        if Self.hasSpeakableText(in: current.text, fromSpokenOffset: offset) {
            return .found(SpeechStart(speech: current, offset: offset))
        }
        switch searchForSpeakableChapter(from: currentChapterIndex + 1, preparingLongChapters: preparation) {
        case .found(let speech):
            return .found(SpeechStart(speech: speech, offset: 0))
        case .noneLeft:
            return .noneLeft
        case .preparingInBackground(let awaited):
            return .preparingInBackground(awaited)
        }
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

    /// The speech of `play` finished. Save the position, and move on to the
    /// next chapter with anything to say, or end the book when none
    /// remains; this reader's sleep timer set for the end of the heading
    /// stops playback here instead when the heading ends here, where the
    /// next chapter begins the next heading (finding #787,
    /// `stopForSleepTimerAtChapterEnd`).
    ///
    /// Chapters that are empty, entirely inside skipped sections, or deleted
    /// by substitutions are passed over, exactly as starting playback passes
    /// over them. The next chapter starts from audio rendered ahead when
    /// that audio is exactly its speech now, rendered from the text and
    /// voice in effect, for an instant start; audio rendered before the
    /// voice, a substitution rule, the punctuation pauses, or the skipped
    /// sections changed is discarded, and the chapter is spoken from its
    /// current text. The speech the look-ahead chose is carried here, so a
    /// chapter whose inputs did not change is not prepared again.
    private func speechDidFinish(_ play: ChapterPlay) {
        DiagnosticLog.trace(.playback, "speech finished: chapter=\(play.chapterIndex) offset=\(currentCharacterOffset) gen=\(play.generation)")
        guard endsPlayUnderWay(play, reportedBy: "speech") else { return }
        savePosition()
        guard content != nil else { return }
        guard let speech = nextSpeakableChapterSpeech(from: play.chapterIndex + 1) else {
            DiagnosticLog.trace(.playback, "no more speakable chapters, book ended")
            handleEndOfBook()
            return
        }
        if expireSleepTimerAtChapterEnd(beforeChapter: speech.chapterIndex) {
            stopForSleepTimerAtChapterEnd(of: play, nextChapterIndex: speech.chapterIndex)
            return
        }
        DiagnosticLog.trace(.playback, "advancing to chapter \(speech.chapterIndex) (from \(play.chapterIndex))")
        currentChapterIndex = speech.chapterIndex
        currentCharacterOffset = 0
        startSpeaking(SpeechStart(speech: speech, offset: 0), playing: takeLookAheadEngine(for: speech))
    }

    /// The audio of `play` played to its end. Save the position, and play
    /// the next chapter, or end the book after the last; this reader's sleep
    /// timer set for the end of the heading stops playback here instead,
    /// since an audiobook's chapters are its headings (finding #787,
    /// `stopForSleepTimerAtChapterEnd`).
    private func audioDidFinish(_ play: ChapterPlay) {
        guard endsPlayUnderWay(play, reportedBy: "audio") else { return }
        savePosition()
        guard let content else { return }
        let nextIndex = play.chapterIndex + 1
        guard nextIndex < content.chapters.count else {
            handleEndOfBook()
            return
        }
        if expireSleepTimerAtChapterEnd(beforeChapter: nextIndex) {
            stopForSleepTimerAtChapterEnd(of: play, nextChapterIndex: nextIndex)
            return
        }
        currentChapterIndex = nextIndex
        currentCharacterOffset = 0
        playAudioChapter()
    }

    /// What the listener hears when this reader's sleep timer runs out on
    /// its own clock and pauses playback: one counting minutes.
    nonisolated static let sleepTimerExpiredAnnouncement = "Sleep timer expired. Playback paused."

    /// What the listener hears when this reader's sleep timer stops playback
    /// where the heading it was set in ends, before the next heading is
    /// heard, wherever that end comes: within a chapter, where the next
    /// heading begins, or at a chapter's end that the next heading begins,
    /// as an audiobook's chapters do (TODO P01, finding #787). One
    /// announcement for one concept: the heading's end is the same place in
    /// any document. At the book's end, which ends the last heading, the
    /// listener hears instead that the book finished and why nothing follows
    /// (`handleEndOfBook()`).
    nonisolated static let sleepTimerStoppedAtHeadingEndAnnouncement =
        "Sleep timer expired at the end of the heading. Playback paused."

    /// Stop where the chapter just played ended, because this reader's sleep
    /// timer, which has just ended, was set for the end of the heading, and
    /// the heading ends there: the next chapter opens with the next heading,
    /// as every audiobook chapter does (TODO P01, finding #787). Nothing
    /// more plays: the cursor waits at the beginning of the next chapter,
    /// saved, so that Play starts that chapter, and the listener hears once
    /// that the timer stopped playback at the heading's end, in the words
    /// heard for a heading's end within a chapter.
    ///
    /// The chapter has already played to its end, so there is nothing left
    /// to pause or fade (`stopPlaybackForSleepTimer(waitingAt:characterOffset:)`).
    /// An audiobook's fade toward this end (`fadeOutBeforeSleepTimerStop()`)
    /// ends with it, so the next chapter plays at full volume.
    ///
    /// - Parameters:
    ///   - play: The chapter play that ended.
    ///   - nextChapterIndex: The chapter Play will start: the next one with
    ///     anything to play.
    private func stopForSleepTimerAtChapterEnd(of play: ChapterPlay, nextChapterIndex: Int) {
        DiagnosticLog.trace(
            .playback,
            "sleep timer: the heading ended with chapter \(play.chapterIndex); chapter \(nextChapterIndex) waits"
        )
        stopPlaybackForSleepTimer(waitingAt: nextChapterIndex, characterOffset: 0)
        announceToVoiceOver(Self.sleepTimerStoppedAtHeadingEndAnnouncement)
    }

    /// Stops playback where this reader's sleep timer, which has just ended,
    /// stops it (TODO P01): where the heading it waits for ends, within a
    /// chapter or with one (finding #787). Nothing more plays: the cursor
    /// waits at `chapterIndex`, `characterOffset`, saved, so that Play
    /// starts there.
    ///
    /// A text book stops waiting for its chapter's speech, so that chapter
    /// does not start once the speech is ready, stops its speech, and lets
    /// go of the next chapter rendered ahead, unplayed. An audiobook stops
    /// waiting for a chapter's files to download, so that chapter does not
    /// start once they are here, and lets go of its player, together with
    /// any next chapter's file it may already have rolled on into, one named
    /// to follow before the timer was set. Either way the reader shows
    /// playback stopped, ends its listening session, and tells Now Playing,
    /// as a pause does. The caller tells the listener why.
    private func stopPlaybackForSleepTimer(waitingAt chapterIndex: Int, characterOffset: Int) {
        if isAudioBook {
            stopWaitingForChapterDownload(because: "the sleep timer stopped playback")
            audioPlaybackService.stop()
            isCurrentlyPlaying = false
            isCurrentlyPaused = false
        } else {
            stopWaitingForChapterSpeech()
            speechService.stop()
            discardLookAhead()
        }
        // Stopping begins a new playback generation, as any move to another
        // chapter does, so the end of what played until now, were it
        // reported after all, could not move on from it.
        chapterPlaybackGeneration += 1
        currentChapterIndex = chapterIndex
        currentCharacterOffset = characterOffset
        readingStatsService.endSession(bookID: book.id)
        nowPlayingService.updateNowPlayingInfo(
            title: book.title, author: book.author, isPlaying: false
        )
        recordPlaybackStopped()
        savePosition()
    }

    // MARK: - Where a Chapter's End Stops the Timer

    /// Whether this reader's sleep timer stops playback where the cursor's
    /// chapter ends, before chapter `nextChapterIndex` starts (TODO P01): a
    /// timer set for the end of the heading when the heading ends there too
    /// (finding #787), or, where the book ends, which ends every heading,
    /// one set for the end of the heading or of the book.
    ///
    /// - Parameter nextChapterIndex: The chapter that plays next; nil, or an
    ///   index past the last chapter, where the book ends.
    func sleepTimerStopsPlaybackAtChapterEnd(beforeChapter nextChapterIndex: Int?) -> Bool {
        let ending = chapterEnding(beforeChapter: nextChapterIndex)
        return sleepTimerService.stopsPlaybackAtChapterEnd(
            endingTheHeading: ending.heading,
            endingTheBook: ending.book,
            ownedBy: readerID
        )
    }

    /// Ends this reader's sleep timer where the cursor's chapter ends, before
    /// chapter `nextChapterIndex` starts, when the timer stops playback there
    /// (`sleepTimerStopsPlaybackAtChapterEnd(beforeChapter:)`); the caller
    /// then stops there rather than play on.
    ///
    /// - Parameter nextChapterIndex: The chapter that would play next; nil,
    ///   or an index past the last chapter, where the book ends.
    /// - Returns: Whether the timer ended, so that playback stops here.
    private func expireSleepTimerAtChapterEnd(beforeChapter nextChapterIndex: Int?) -> Bool {
        let ending = chapterEnding(beforeChapter: nextChapterIndex)
        return sleepTimerService.expireAtChapterEnd(
            endingTheHeading: ending.heading,
            endingTheBook: ending.book,
            by: readerID
        )
    }

    /// What ends, for this reader's sleep timer, where the cursor's chapter
    /// ends and chapter `nextChapterIndex` would begin: the book, when no
    /// such chapter is in it, which ends every heading too; and otherwise
    /// the heading an End of heading timer waits for, when the next heading
    /// has begun by the time that chapter says anything
    /// (`headingHasBegun(_:atStartOfChapter:text:)`, finding #787).
    ///
    /// This is where End of chapter and End of heading differed, and where
    /// the one timer (October 6, 2026) keeps the heading's meaning: a next
    /// chapter that opens with its heading, as every audiobook chapter and
    /// most EPUB chapters do, ends the heading with the chapter, so playback
    /// stops here; a next chapter that has text before its first heading, or
    /// no heading at all, goes on under the heading playing, so playback
    /// goes on into it and stops where the next heading begins, or where
    /// the book ends.
    private func chapterEnding(beforeChapter nextChapterIndex: Int?) -> (heading: Bool, book: Bool) {
        guard let content, let nextChapterIndex, content.chapters.indices.contains(nextChapterIndex) else {
            return (heading: true, book: true)
        }
        let headingEnds = sleepTimerNextHeading.map {
            Self.headingHasBegun($0, atStartOfChapter: nextChapterIndex, text: content.chapters[nextChapterIndex].text)
        } ?? false
        return (heading: headingEnds, book: false)
    }

    /// Whether `heading` has begun by the time chapter `chapterIndex`, whose
    /// text is `text`, says anything: it begins in an earlier chapter, or in
    /// this one with nothing but white space before it, as a chapter that
    /// opens with its heading has. A heading that ends where `heading`
    /// begins then ends where the chapter before ends.
    nonisolated static func headingHasBegun(_ heading: Heading, atStartOfChapter chapterIndex: Int, text: String) -> Bool {
        guard heading.chapterIndex == chapterIndex else { return heading.chapterIndex < chapterIndex }
        let headingStart = text.index(atUTF16Offset: heading.characterOffset)
        return !hasSpeakableText(text[..<headingStart])
    }

    // MARK: - Stopping Where a Heading Ends (finding #787)

    /// Stops playback where the heading this reader's End of heading sleep
    /// timer waits for ends, once playback has carried the cursor there.
    ///
    /// Called as the reader refreshes its view of the cursor, at most every
    /// `playbackUIRefreshInterval`, when the reader header learns the heading
    /// the cursor is in (`displayHeadingPosition`), so no spoken word costs
    /// more than it did. Playback has run on a moment past the next
    /// heading's start by then, so the cursor goes back to that start, for
    /// Play to begin the next heading from its first word. Where the next
    /// heading begins a chapter, playback stops at the end of the chapter
    /// before instead (`stopForSleepTimerAtChapterEnd`).
    func stopForSleepTimerIfPlaybackReachedHeadingEnd() {
        endSleepTimerAtHeadingEnd(movedByListener: false)
    }

    /// Ends this reader's End of heading sleep timer when a move the listener
    /// made took the cursor to or past where the heading the timer waits for
    /// ends: a jump to the next heading, a bookmark, a search result, or a
    /// place in the book, or a skip. Playback, when under way, stops where
    /// the move went, and the cursor stays there. A move back never reaches
    /// that end, so the timer still waits for it. Called once each move is
    /// made.
    func endSleepTimerIfMoveReachedHeadingEnd() {
        endSleepTimerAtHeadingEnd(movedByListener: true)
    }

    /// Ends this reader's End of heading sleep timer once the cursor is at or
    /// past where the heading the timer waits for ends, the start of the
    /// next heading, and stops playback there when it is under way: the
    /// first such end ends the timer, once (finding #787). The listener
    /// hears that the timer ended: at once when playback brought the cursor
    /// there, and after what a move of their own says of where it went, such
    /// as the next heading's name, when they moved it, so that neither cuts
    /// the other off.
    ///
    /// A heading that ends with the book has no next heading, and the end of
    /// the book stops playback for it (`handleEndOfBook()`).
    ///
    /// - Parameter movedByListener: Whether a move of the listener's took
    ///   the cursor there, where it stays; otherwise playback carried it
    ///   there, and it goes back to the start of the next heading.
    private func endSleepTimerAtHeadingEnd(movedByListener: Bool) {
        // The cheapest checks come first, since this runs as the cursor moves.
        guard let nextHeading = sleepTimerNextHeading,
              sleepTimerService.waitsForHeadingEnd(ownedBy: readerID),
              nextHeading.startsAtOrBefore(chapterIndex: currentChapterIndex, characterOffset: currentCharacterOffset),
              sleepTimerService.expireAtHeadingEnd(by: readerID) else { return }
        sleepTimerNextHeading = nil
        DiagnosticLog.trace(
            .playback,
            "sleep timer: the heading ended at chapter \(nextHeading.chapterIndex) offset \(nextHeading.characterOffset); "
                + "the cursor is at chapter \(currentChapterIndex) offset \(currentCharacterOffset)"
        )
        if isPlaybackUnderWay {
            if movedByListener {
                stopPlaybackForSleepTimer(waitingAt: currentChapterIndex, characterOffset: currentCharacterOffset)
            } else {
                stopPlaybackForSleepTimer(waitingAt: nextHeading.chapterIndex, characterOffset: nextHeading.characterOffset)
            }
        }
        guard movedByListener else {
            announceToVoiceOver(Self.sleepTimerStoppedAtHeadingEndAnnouncement)
            return
        }
        // The move says where it went first; the timer's end follows it, on
        // the main queue's next turn and at a lower priority, which VoiceOver
        // speaks after what it is saying rather than over it.
        DispatchQueue.main.async { [weak self] in
            self?.announceToVoiceOverAfterCurrentSpeech(Self.sleepTimerStoppedAtHeadingEndAnnouncement)
        }
    }

    // MARK: - Fading Out Before the Timer's Stop

    /// Fade an audiobook out over the sleep timer's fade-out time as the
    /// chapter playing nears the end where this reader's timer stops
    /// playback, so that the stop comes in silence (TODO P01).
    ///
    /// The volume follows the time left in the chapter, at the speed it
    /// plays (`sleepTimerFadeVolume(secondsLeft:fadeSeconds:)`), so a pause
    /// holds it where it is, a move back raises it again, and the chapter's
    /// end, where the timer stops playback, comes at silence. Called as the
    /// audio's position is reported, as a chapter starts or resumes, and as
    /// the timer is set or cancelled. Once no such fade applies, because the
    /// timer was cancelled, replaced, or has ended, or playback moved away
    /// from the end, the volume returns to full, unless this reader's timer
    /// is fading the audio out on its own clock, as one counting minutes does
    /// when it runs out. Speech is not faded: a text book stops at the
    /// chapter's end as it is.
    func fadeOutBeforeSleepTimerStop() {
        guard isAudioBook else { return }
        if let volume = sleepTimerFadeVolumeBeforeStop {
            audioPlaybackService.setVolume(volume)
        } else if audioPlaybackService.intendedVolume < 1, !isOwnSleepTimerFading {
            audioPlaybackService.restoreVolume()
        }
    }

    /// The volume for the audio now, as it fades toward the end of the
    /// chapter where this reader's sleep timer stops playback; nil when no
    /// such fade applies: no fade-out time is set, the timer does not stop
    /// at this chapter's end, the time left is not known yet, or more than
    /// the fade-out time is left.
    private var sleepTimerFadeVolumeBeforeStop: Float? {
        let fadeSeconds = sleepTimerService.fadeOutDuration
        guard fadeSeconds > 0,
              sleepTimerStopsPlaybackAtChapterEnd(beforeChapter: currentChapterIndex + 1),
              let mediaSecondsLeft = audioPlaybackService.timeLeftToPlay,
              audioPlaybackService.playbackSpeed > 0 else { return nil }
        let volume = Self.sleepTimerFadeVolume(
            secondsLeft: mediaSecondsLeft / audioPlaybackService.playbackSpeed,
            fadeSeconds: fadeSeconds
        )
        return volume < 1 ? volume : nil
    }

    /// The volume of audio fading out toward a sleep timer's stop with
    /// `secondsLeft` seconds of listening to go: full until the last
    /// `fadeSeconds`, then falling evenly to silence at the stop. Full with
    /// no fade-out time, and for a time left that is not a number.
    nonisolated static func sleepTimerFadeVolume(secondsLeft: TimeInterval, fadeSeconds: TimeInterval) -> Float {
        guard fadeSeconds > 0, secondsLeft.isFinite else { return 1 }
        return Float(min(1, max(0, secondsLeft / fadeSeconds)))
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
    ///
    /// The chapter's speech is carried to the moment it begins, so the
    /// chapter's end prepares nothing. A long chapter whose speech is not
    /// prepared yet is prepared off the main actor first, and this runs
    /// again once it is ready (PERF02).
    func preRenderNextChapter() {
        // Forget any earlier look-ahead before choosing a new one. The next
        // speakable chapter changes when sections are skipped, so an old
        // engine must never stay paired with a newly chosen chapter.
        discardLookAhead()

        // Render exactly the text playback will speak for that chapter.
        let search = searchForSpeakableChapter(from: currentChapterIndex + 1, preparingLongChapters: .inBackground)
        guard case .found(let speech) = search else { return }
        chapterSpeechCache.lookAheadSpeech = speech
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
        // The chapter's speech from the settings in effect now, prepared again
        // only if one of them changed: a setting changed while the render ran
        // makes the signatures differ.
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
    /// installed in the engine, and nothing keeps or plays it. The speech it
    /// carried, and any preparation it waited for, are forgotten with it;
    /// that speech stays among the recently prepared chapters.
    func discardLookAhead() {
        lookAhead?.engine.cancelRender()
        lookAhead = nil
        chapterSpeechCache.forgetLookAhead()
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
    /// Speech already prepared from the current settings is not prepared
    /// again, and a long chapter is prepared off the main actor.
    func refreshLookAhead() {
        guard isSpeechSessionActive else { return }
        if let lookAhead,
           case .found(let next) = searchForSpeakableChapter(
               from: currentChapterIndex + 1,
               preparingLongChapters: .inBackground
           ),
           next.chapterIndex == lookAhead.chapterIndex,
           renderRequest(for: next).signature == lookAhead.signature {
            // The same speech, perhaps from inputs that changed without
            // changing it: carry it as prepared from the inputs now.
            chapterSpeechCache.lookAheadSpeech = next
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
    /// chapter's original text and what it was prepared from.
    struct ChapterSpeech: Sendable {
        /// Everything this speech was prepared from; while they stay the
        /// same, so does the speech (`ChapterSpeechCache`).
        let inputs: ChapterSpeechInputs
        /// Result of the text substitutions, the pipeline's last stage.
        let transformation: TextTransformation
        /// Offsets through every stage (skipped sections, repeated symbols,
        /// punctuation pauses, substitutions), between original and spoken
        /// text.
        let offsetMap: ComposedOffsetMap

        /// Index of the chapter this speech was prepared from.
        var chapterIndex: Int { inputs.chapterIndex }
        /// The exact text handed to the speech engine.
        var text: String { transformation.modifiedText }
    }

    /// Run one chapter through the playback text pipeline: remove skipped
    /// sections, rewrite runs of a repeated symbol, add punctuation pauses,
    /// then apply text substitutions (`ChapterSpeechInputs.prepare()`).
    /// Speaking a chapter and pre-rendering the next one both use this, so
    /// look-ahead audio always matches what playback would speak. Every
    /// setting is read as the chapter is asked for, so a change applies from
    /// the next chapter spoken.
    ///
    /// A chapter is prepared once while everything it is prepared from stays
    /// the same, and its speech is used again until any of it changes
    /// (PERF02).
    ///
    /// - Returns: Nil when no content is loaded or the index is out of range.
    func preparedSpeech(forChapterAt chapterIndex: Int) -> ChapterSpeech? {
        speechInputs(forChapterAt: chapterIndex).map { preparedSpeech(for: $0) }
    }

    /// What chapter `chapterIndex`'s speech is prepared from now: its text,
    /// its skipped sections, and the repeated-symbol, punctuation pause, and
    /// substitution settings in force. Nil when no content is loaded or the
    /// index is out of range.
    func speechInputs(forChapterAt chapterIndex: Int) -> ChapterSpeechInputs? {
        guard let content, content.chapters.indices.contains(chapterIndex) else { return nil }
        // Most books skip nothing, and then no heading shapes the speech.
        // `headings` always equals `content.allHeadings`; reading it avoids
        // rebuilding every heading of the book for each chapter.
        let skippedIDs = skippedHeadingIDs
        let chapterHeadings = skippedIDs.isEmpty ? [] : headings.filter { $0.chapterIndex == chapterIndex }
        return ChapterSpeechInputs(
            chapterIndex: chapterIndex,
            text: content.chapters[chapterIndex].text,
            chapterHeadings: chapterHeadings,
            bookSkippedHeadingIDs: skippedIDs,
            repeatedSymbolRule: substitutionService.repeatedSymbolRule,
            punctuationPauseLevel: settingsViewModel.punctuationPauseLevel,
            substitutions: substitutionService.substitutionPass
        )
    }

    /// The speech `inputs` describe: the speech kept for exactly those
    /// inputs, or else speech prepared now, which is kept.
    func preparedSpeech(for inputs: ChapterSpeechInputs) -> ChapterSpeech {
        chapterSpeechCache.speech(for: inputs) ?? prepareAndKeep(inputs)
    }

    /// Speech prepared now from `inputs`, on the main actor, and kept.
    private func prepareAndKeep(_ inputs: ChapterSpeechInputs) -> ChapterSpeech {
        let speech = inputs.prepare()
        chapterSpeechCache.keep(speech)
        return speech
    }

    /// Prepare the speech of the chapter Play will start in off the main
    /// actor once a text book has loaded, so that Play finds it kept instead
    /// of preparing it on the main thread, where the developer's rules take
    /// 155 ms for a chapter of 744,000 UTF-16 units and 4 s for a book of
    /// one 20 MB chapter in the Release app. That chapter is the cursor's,
    /// or, when the cursor's chapter holds no words at all, as a cover page
    /// does, the next chapter that does, which Play passes on to. Nothing is
    /// prepared for an audiobook, by a closed reader, or when the speech is
    /// already kept or being prepared.
    ///
    /// The speech is kept only while the chapter is still prepared from the
    /// same inputs when it is ready (`finishPreparingInBackground(_:)`): a
    /// change to the substitution rules, the repeated-symbol setting, the
    /// pauses, or the skipped sections meanwhile leaves Play to prepare the
    /// chapter from the settings in force, as it always did. Play pressed
    /// before the preparation ends waits for it when the chapter is long,
    /// showing Playing meanwhile (`play()`), and prepares a shorter chapter
    /// at once, in a few milliseconds.
    func prepareOpenedChapterSpeech() {
        guard !hasClosed, !isAudioBook, let content else { return }
        let chapters = content.chapters
        let chapterIndex = Self.nextSpeakableChapterIndex(from: currentChapterIndex, chapterCount: chapters.count) {
            Self.hasSpeakableText(chapters[$0].text)
        } ?? currentChapterIndex
        guard let inputs = speechInputs(forChapterAt: chapterIndex),
              !chapterSpeechCache.isKeptOrPreparing(inputs) else { return }
        prepareInBackground(inputs, forLookAhead: false)
    }

    /// Prepare a chapter's speech off the main actor and keep it when it is
    /// ready. For the look-ahead (`forLookAhead`), which waits for a long
    /// chapter's speech this way, choose the chapter to render ahead again
    /// once the speech is ready. A preparation of the same inputs already
    /// under way is not started again.
    private func prepareInBackground(_ inputs: ChapterSpeechInputs, forLookAhead: Bool = true) {
        if forLookAhead {
            chapterSpeechCache.awaitedByLookAhead = inputs
        }
        guard chapterSpeechCache.beginPreparingInBackground(inputs) else { return }
        DiagnosticLog.trace(
            .playback,
            "\(forLookAhead ? "preRender" : "open"): preparing chapter \(inputs.chapterIndex) "
                + "(\(inputs.text.utf16Length) UTF-16 units) off the main thread"
        )
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let speech = inputs.prepare()
            DispatchQueue.main.async { [weak self] in
                self?.finishPreparingInBackground(speech)
            }
        }
    }

    /// Keep speech prepared in the background while its chapter is still
    /// prepared from the same inputs; start the play that waited for it
    /// (`continueWaitingPlay()`); and, when the look-ahead waited for it,
    /// choose the chapter to render ahead again, now without waiting. A
    /// closed reader keeps nothing. Tests hand it a preparation's result
    /// themselves, so that no speech they start can start while the run
    /// loop turns.
    func finishPreparingInBackground(_ speech: ChapterSpeech) {
        chapterSpeechCache.endPreparingInBackground(speech.inputs)
        guard !hasClosed else { return }
        if speechInputs(forChapterAt: speech.chapterIndex) == speech.inputs {
            chapterSpeechCache.keep(speech)
        }
        if chapterSpeechCache.awaitedByPlay == speech.inputs {
            continueWaitingPlay()
        }
        guard chapterSpeechCache.awaitedByLookAhead == speech.inputs else { return }
        chapterSpeechCache.awaitedByLookAhead = nil
        DiagnosticLog.trace(.playback, "preRender: chapter \(speech.chapterIndex) prepared off the main thread")
        if isSpeechSessionActive {
            preRenderNextChapter()
        }
    }

    // MARK: - Play Waiting for Its Chapter's Speech

    /// Whether the reader waits for the speech of the chapter Play starts
    /// in, a long one being prepared off the main thread: it shows Playing,
    /// as an audiobook waiting for its chapter's files to download does, but
    /// says nothing until the speech is ready (`continueWaitingPlay()`), or,
    /// when the speech is ready while a Where Am I announcement speaks, until
    /// the announcement ends (`startPlayHeldByWhereAmI()`).
    var isWaitingForChapterSpeech: Bool {
        chapterSpeechCache.awaitedByPlay != nil
    }

    /// Whether Play waits for the speech of `inputs` rather than prepare it
    /// on the main thread: the chapter is long (`ChapterSpeechInputs.isLong`),
    /// no speech is kept for exactly these inputs, and they are being
    /// prepared in the background. A shorter chapter is prepared at once,
    /// in a few milliseconds, as Play always prepared it.
    private func waitsForPreparation(of inputs: ChapterSpeechInputs) -> Bool {
        inputs.isLong && chapterSpeechCache.isOnlyBeingPreparedInBackground(inputs)
    }

    /// Wait for the speech of `inputs`, the long chapter Play starts in,
    /// which is being prepared off the main thread, showing Playing
    /// meanwhile, in the reader and in Now Playing.
    private func waitForChapterSpeech(_ inputs: ChapterSpeechInputs) {
        DiagnosticLog.trace(
            .playback,
            "play: waiting for chapter \(inputs.chapterIndex)'s speech "
                + "(\(inputs.text.utf16Length) UTF-16 units), being prepared off the main thread"
        )
        chapterSpeechCache.awaitedByPlay = inputs
        isCurrentlyPlaying = true
        isCurrentlyPaused = false
        nowPlayingService.updateNowPlayingInfo(
            title: book.title, author: book.author, isPlaying: true
        )
    }

    /// Start the play that waited for its chapter's speech, now that the
    /// preparation it waited for has ended: from the cursor as it is now,
    /// so that a move made meanwhile is where speech begins. Speech prepared
    /// from settings that changed meanwhile was not kept, so the chapter is
    /// then prepared afresh from the settings in force, at once, unless a
    /// preparation of exactly those is under way, which the play waits for
    /// in turn. A book with nothing left to say ends. Nothing is said over a
    /// Where Am I announcement: the play goes on waiting, showing Playing,
    /// and starts once the announcement ends (`startPlayHeldByWhereAmI()`).
    private func continueWaitingPlay() {
        guard !WhereAmIInterruptionPolicy.blocksBookPlayback(isAnnouncementSpeaking: isWhereAmISpeaking) else {
            DiagnosticLog.trace(.playback, "play: the chapter's speech is ready while Where Am I speaks; starting it once the announcement ends")
            return
        }
        chapterSpeechCache.awaitedByPlay = nil
        switch searchForSpeechStart(preparingLongChapters: .nowUnlessUnderWay) {
        case .found(let start):
            startSpeakingAsNowPlaying(start)
        case .preparingInBackground(let inputs):
            waitForChapterSpeech(inputs)
        case .noneLeft:
            endBookWithNothingLeftToSpeak()
        }
    }

    /// Start the play a Where Am I announcement held, now that the
    /// announcement has ended: a play that waited for its chapter's speech,
    /// which was ready while the announcement spoke (`continueWaitingPlay()`),
    /// starts from the cursor as it is now. Nothing starts while an
    /// announcement speaks, when no play waits, or while the speech the play
    /// waits for is still being prepared, whose end starts the play itself.
    func startPlayHeldByWhereAmI() {
        guard !hasClosed, !isWhereAmISpeaking,
              let awaited = chapterSpeechCache.awaitedByPlay,
              !chapterSpeechCache.isPreparingInBackground(awaited) else { return }
        DiagnosticLog.trace(.playback, "play: Where Am I ended; starting the chapter's speech it held")
        continueWaitingPlay()
    }

    /// Stops waiting for the speech of the chapter Play starts in, when the
    /// reader waits for it, so that the chapter does not start once its
    /// speech is ready: playback was paused or stopped. The preparation goes
    /// on, and keeps the speech for the next Play. The reader shows that
    /// nothing plays.
    ///
    /// - Returns: Whether the reader was waiting.
    @discardableResult
    private func stopWaitingForChapterSpeech() -> Bool {
        guard isWaitingForChapterSpeech else { return false }
        chapterSpeechCache.awaitedByPlay = nil
        isCurrentlyPlaying = false
        isCurrentlyPaused = false
        DiagnosticLog.trace(.playback, "play: stopped waiting for the chapter's speech")
        return true
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
        if case .found(let speech) = searchForSpeakableChapter(from: start, preparingLongChapters: .now) {
            return speech
        }
        return nil
    }

    /// When a search for the next speakable chapter prepares a long chapter
    /// whose speech is not kept yet.
    enum LongChapterPreparation {
        /// At once, on the main actor, for a caller that needs the answer
        /// now: a chapter's end, the end of the book, and a restart of
        /// speech.
        case now
        /// At once, on the main actor, unless its speech is already being
        /// prepared in the background from exactly the inputs in force:
        /// then the search ends, to wait for that preparation. Play, which
        /// shows Playing while it waits.
        case nowUnlessUnderWay
        /// In the background, ending the search until it is ready: the
        /// look-ahead, which waits for it rather than hold the main thread.
        case inBackground
    }

    /// What a search for the next speakable chapter found.
    enum SpeakableChapterSearch {
        /// The speech of the first chapter with anything to say.
        case found(ChapterSpeech)
        /// No chapter from where the search began has anything to say.
        case noneLeft
        /// A long chapter is being prepared in the background, from these
        /// inputs, before the search can go on.
        case preparingInBackground(ChapterSpeechInputs)
    }

    /// Search for the first chapter at or after `start` with anything to
    /// say, as `nextSpeakableChapterSpeech(from:)` does, preparing a long
    /// chapter whose speech is not kept yet as `preparingLongChapters` says.
    private func searchForSpeakableChapter(
        from start: Int,
        preparingLongChapters: LongChapterPreparation
    ) -> SpeakableChapterSearch {
        guard let content else { return .noneLeft }
        var result = SpeakableChapterSearch.noneLeft
        // The search stops at the first chapter this accepts: the first with
        // anything to say, or a long one being prepared in the background,
        // and `result` says which.
        _ = Self.nextSpeakableChapterIndex(from: start, chapterCount: content.chapters.count) { chapterIndex in
            guard let inputs = speechInputs(forChapterAt: chapterIndex) else { return false }
            // Play waits for a long chapter being prepared in the background
            // rather than prepare it again on the main thread.
            if preparingLongChapters == .nowUnlessUnderWay, waitsForPreparation(of: inputs) {
                result = .preparingInBackground(inputs)
                return true
            }
            let speech: ChapterSpeech
            if let kept = chapterSpeechCache.speech(for: inputs) {
                speech = kept
            } else if preparingLongChapters == .inBackground, inputs.isLong {
                prepareInBackground(inputs)
                result = .preparingInBackground(inputs)
                return true
            } else {
                speech = prepareAndKeep(inputs)
            }
            guard Self.hasSpeakableText(speech.text) else { return false }
            result = .found(speech)
            return true
        }
        return result
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
            // The audio fades out as the chapter nears the end where this
            // reader's sleep timer stops playback (TODO P01).
            self.fadeOutBeforeSleepTimerStop()
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
        guard chapterFilesReadyToPlay() else {
            // The player may have rolled straight on into this chapter's
            // file, named to follow the chapter before while it was on this
            // Mac and gone back to the cloud since (TODO PERF09): nothing
            // plays while the reader waits for it.
            if audioPlaybackService.isPlaying {
                audioPlaybackService.stop()
            }
            return
        }
        // Audio that cannot be played claims no Playing state.
        guard startCurrentChapterAudio(in: content) else { return }
        // The chapter starts at the volume its place calls for: full, or
        // already fading toward the end where this reader's sleep timer
        // stops playback (TODO P01).
        fadeOutBeforeSleepTimerStop()

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

    /// Load the current chapter's audio and play it from the cursor, then
    /// name the next chapter's file to follow it with no gap, where one may
    /// (`nameFileAfterCurrentChapter()`, TODO PERF09).
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
        guard audioPlaybackService.play(fromTime: timeOffset) else { return false }
        nameFileAfterCurrentChapter()
        return true
    }

    // MARK: - The Next Chapter's File (PERF09)

    /// Names the file the audio service rolls straight on into once the
    /// cursor's chapter's file plays to its end, or names none, as
    /// `fileAfterCurrentChapter` decides now (TODO PERF09). Starting a
    /// stopped player costs about a quarter of a second of silence, which a
    /// file named ahead is spared: the service queues it behind the one
    /// playing, and the next chapter takes it over as it begins.
    ///
    /// Called as each chapter's audio starts, and as this reader's sleep timer
    /// is set or cancelled, since a timer set for the end of the heading,
    /// which an audiobook's chapter ends, stops playback at the chapter's
    /// end. Only audio playing or paused in the cursor's chapter's own file
    /// is given a file to follow: audio that has stopped, or that still
    /// plays a file the library has moved since, is given none.
    private func nameFileAfterCurrentChapter() {
        guard isAudioBook, audioPlaybackService.isPlaying,
              case .file(let chapterFile) = chapterAudioSource(forChapterAt: currentChapterIndex),
              audioPlaybackService.loadedURL == chapterFile.standardizedFileURL else { return }
        audioPlaybackService.setFileAfterCurrent(fileAfterCurrentChapter)
    }

    /// The file to play straight on into once the cursor's chapter's file
    /// ends (TODO PERF09): the next chapter's file, in a multi-file
    /// audiobook, whose chapters are files of their own, each played whole
    /// from its start. None where playback may have to stop or wait at that
    /// end:
    /// - at the last chapter, where the book's end-of-book behavior decides
    ///   what comes next;
    /// - while this reader's sleep timer stops playback at the end of the
    ///   chapter playing, as one set for the end of the heading does in an
    ///   audiobook, whose every chapter begins with its heading
    ///   (`sleepTimerStopsPlaybackAtChapterEnd(beforeChapter:)`);
    /// - when the next chapter's file is only in the cloud, where the player
    ///   would wait on the network, so the chapter downloads first instead
    ///   (`chapterHasFileOnlyInCloud(_:)`).
    /// None either in any other layout, whose chapters play a chain of clips
    /// or a stretch of one file, ending where no file ends.
    private var fileAfterCurrentChapter: URL? {
        guard audioLayout == .multiFile, let content else { return nil }
        let nextIndex = currentChapterIndex + 1
        guard nextIndex < content.chapters.count, nextIndex < audioChapterFiles.count,
              !sleepTimerStopsPlaybackAtChapterEnd(beforeChapter: nextIndex),
              case .file(let nextFile) = chapterAudioSource(forChapterAt: nextIndex),
              !chapterHasFileOnlyInCloud(nextIndex) else { return nil }
        return nextFile
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
        sleepTimerService.pauseCountdown(by: readerID)
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

    /// Called when the last chapter finishes playing, and when Play finds
    /// nothing left to say. Behavior depends on per-book override or global
    /// setting: stop, loop, or continue to next book.
    ///
    /// This reader's sleep timer set for the end of the heading or of the
    /// book stops playback here, where the book's last chapter ends, which
    /// ends the last heading too (TODO P01, finding #787): the timer ends,
    /// and the book neither starts again nor continues to the next book,
    /// whatever its end-of-book behavior.
    /// The listener hears once that the book finished and why nothing
    /// follows.
    ///
    /// A book that ends listening here rests finished at its end
    /// (`hasFinishedBook`), and keeps what it owns: its media session, shown
    /// paused at the end rather than stopped (`finishListening`), so that
    /// macOS goes on sending the AirPods and the media keys to this reader.
    /// A Previous Track or Skip Backward after the end therefore reaches it
    /// and plays the book again from where the skip lands
    /// (`performSkip(unit:forward:)`), as the listener who rewinds a
    /// finished book means to hear its end again. A book that loops is not
    /// finished: it plays again, or waits at its beginning.
    func handleEndOfBook() {
        // Time after the end of the book is not listening time, so close this
        // book's session here, once, for every way a book can end. Another
        // window's session is left running.
        readingStatsService.endSession(bookID: book.id)
        // Audio completion does not flow through SpeechService's publishers.
        // Clear its mirrored UI state before applying stop/loop/continue.
        isCurrentlyPlaying = false
        isCurrentlyPaused = false
        // The book rests at its end from here on, keeping its media session
        // so the AirPods still reach it; its next backward skip plays it
        // again from where the skip lands. A loop that moves the cursor back
        // to the start takes this back below.
        hasFinishedBook = true
        // Whether this reader's sleep timer keeps the next book from starting,
        // decided before a timer that stops playback here ends just below.
        let sleepTimerEndsListening = sleepTimerEndsListeningHere
        let sleepTimerStoppedHere = expireSleepTimerAtChapterEnd(beforeChapter: nil)
        // Audio faded out toward this end, where the timer stopped it, plays
        // at full volume again next time.
        fadeOutBeforeSleepTimerStop()
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
            finishListening(
                announcing: sleepTimerStoppedHere
                    ? "Finished: \(book.title). Sleep timer expired."
                    : "Finished: \(book.title)"
            )

        case .loop:
            currentChapterIndex = 0
            currentCharacterOffset = 0
            // The book waits at its beginning, not its end: a backward skip
            // from here has nowhere to go back to, and starts nothing.
            hasFinishedBook = false
            chapterPlaybackGeneration += 1
            savePosition()
            if sleepTimerStoppedHere {
                // The book waits at its beginning, where Play starts it again.
                DiagnosticLog.trace(.playback, "end of book: this reader's sleep timer stopped playback here; not starting it again")
                finishListening(announcing: "Finished: \(book.title). Not restarted because of the sleep timer.")
            } else {
                announceToVoiceOver("Restarting: \(book.title)")
                // Route through the correct backend and start the next
                // listening session. Audiobook placeholder text cannot be
                // looped via TTS.
                play()
            }

        case .continueNext:
            readingStatsService.markBookFinished(bookID: book.id, title: book.title)
            savePosition()
            // Find the next book in the same folder by manual sort order
            if let nextBook = libraryViewModel.nextBookInFolder(after: book) {
                if sleepTimerEndsListening {
                    // The next book would play on past this reader's sleep
                    // timer, which can pause only the reader that set it.
                    DiagnosticLog.trace(.playback, "end of book: this reader's sleep timer is in effect; not starting the next book")
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
                finishListening(
                    announcing: sleepTimerStoppedHere
                        ? "Finished: \(book.title). No more books in folder. Sleep timer expired."
                        : "Finished: \(book.title). No more books in folder."
                )
            }
        }
    }

    /// End listening with this finished book, and say `announcement`.
    ///
    /// The book's media session is kept: Now Playing shows the book paused
    /// at its end rather than stopped, and the reader stays the focused
    /// owner (`NowPlayingService.activeOwnerID`), so macOS goes on sending
    /// the AirPods and the media keys to this reader, where a stopped item
    /// would hand them to another app. A Previous Track or Skip Backward
    /// after the end therefore reaches `skipBackward()`, which plays the
    /// book again from where it lands (`performSkip(unit:forward:)`), as
    /// the listener who rewinds a finished book means to hear its end
    /// again. Only Release Media Controls or closing the window gives the
    /// controls up.
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

    /// Whether this reader's own sleep timer ends listening with this book,
    /// so that Continue to Next Book does not start the next one.
    ///
    /// The timer pauses only the reader that set it, so it could never pause
    /// the next book, which would play on past it. Continuing is therefore
    /// ruled out while the timer is in effect: counting down, fading out,
    /// or waiting for the end of a heading or of the book. A timer set for
    /// either place is still in effect as the book's last chapter ends,
    /// since it ends there itself (`handleEndOfBook()` asks first). A timer
    /// that has ended, at an earlier heading's end or by running out, rules
    /// nothing out.
    var sleepTimerEndsListeningHere: Bool {
        Self.sleepTimerEndsListening(
            timerBelongsToThisReader: sleepTimerService.ownerID == readerID,
            timerIsActive: sleepTimerService.isActive
        )
    }

    /// The decision behind `sleepTimerEndsListeningHere`, from the sleep
    /// timer's state.
    ///
    /// - Parameters:
    ///   - timerBelongsToThisReader: Whether this reader, the finished
    ///     book's, set the timer.
    ///   - timerIsActive: Whether the timer is counting down, waiting for
    ///     its moment, or fading out.
    nonisolated static func sleepTimerEndsListening(
        timerBelongsToThisReader: Bool,
        timerIsActive: Bool
    ) -> Bool {
        timerBelongsToThisReader && timerIsActive
    }

    // MARK: - Sleep Timer

    /// Start a sleep timer owned by this reader. Replaces any timer that
    /// might be running for another reader. The provided duration is
    /// captured along with this reader's pause/fade callbacks so the
    /// shared service knows what to do when the timer fires.
    /// Calling this with a timer already running just replaces it
    /// (the singleton's start() implicitly stops any previous timer).
    /// When `startPlaybackIfNeeded` is true, paused/stopped playback is
    /// resumed or started so the armed timer has audio to count against.
    /// A timer for the end of the heading waits for the heading the cursor
    /// is in now to end, where the next heading begins, or the book ends
    /// after the last heading, for which nothing is kept (finding #787).
    func startSleepTimer(duration: SleepTimerDuration, startPlaybackIfNeeded: Bool = false) {
        sleepTimerNextHeading = duration == .endOfHeading ? headingAfterCursor : nil
        // Capture one value for both timer scheduling and direct-speech fade
        // planning. A settings edit while the timer runs must not make the
        // utterance queue disagree with the timer's already-armed duration.
        let fadeOutDuration = settingsViewModel.sleepFadeOutDuration
        sleepTimerService.start(
            duration: duration,
            ownerID: readerID,
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
                self.announceToVoiceOver(Self.sleepTimerExpiredAnnouncement)
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
        // A timer for the end of the heading stops playback at this chapter's
        // end when the heading ends with it, as an audiobook's does, where no
        // file may follow on; any other timer lets the next chapter's file
        // follow (TODO PERF09). Audio already near that end fades from now
        // on, and a fade toward an end the new timer does not stop at is
        // undone (TODO P01).
        nameFileAfterCurrentChapter()
        fadeOutBeforeSleepTimerStop()
        if startPlaybackIfNeeded {
            startSleepTimerPlaybackIfNeeded()
        }
    }

    /// Cancel the sleep timer if one is running. Anyone may cancel —
    /// no owner check, since "Cancel" should always work even if the
    /// user is in a different window from the one that started it.
    func cancelSleepTimer() {
        sleepTimerService.stop()
        // Playback no longer has to stop at this chapter's end for a timer,
        // so the next chapter's file may follow on again (TODO PERF09), and
        // audio fading toward that end returns to full volume (TODO P01).
        nameFileAfterCurrentChapter()
        fadeOutBeforeSleepTimerStop()
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
        // would never apply. An audiobook waiting for its chapter's files to
        // download counts as playing: it is left paused at the chapter, below.
        // So does a text book waiting for its chapter's speech, which stops.
        let wasPlaying = isPlaybackUnderWay

        if playingPauseSound {
            soundEffectService?.play(for: .pause)
        }
        // `AVPlayer.pause()` / `AVAudioPlayerNode.pause()` do not
        // restore volume on their own. The only explicit volume reset
        // lives in the fade-cleanup branch below, which is why the
        // sleep timer must keep a one-shot "fade just completed"
        // marker until this helper runs.
        let ownsSleepTimer = sleepTimerService.ownerID == readerID
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
        } else {
            // A play still waiting for its chapter's speech has said nothing:
            // it stops waiting and shows nothing playing, and the speech
            // service below, with nothing to pause, does nothing.
            stopWaitingForChapterSpeech()
            if completingSleepFade {
                speechService.pauseForSleepTimerFadeCompletion()
            } else {
                speechService.pause()
            }
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
            // above and do not reach here. A timer waiting for the end
            // of the heading or of the book is left waiting: the service
            // guards on the duration's kind.
            sleepTimerService.pauseCountdown(by: readerID)
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

    /// Whether playback is under way: speech or audio playing, not paused,
    /// or an audiobook waiting for its chapter's files to download (FR02),
    /// which shows Playing while nothing plays yet, and plays the chapter
    /// once the files are here; likewise a text book waiting for the speech
    /// of its chapter, prepared off the main thread, which speaks once the
    /// speech is ready.
    var isPlaybackUnderWay: Bool {
        if isAudioBook {
            return Self.wasActivelyPlaying(
                isPlaying: audioPlaybackService.isPlaying,
                isPaused: audioPlaybackService.isPaused
            ) || isWaitingForChapterDownload
        }
        return Self.wasActivelyPlaying(isPlaying: speechService.isSpeaking, isPaused: speechService.isPaused)
            || isWaitingForChapterSpeech
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
    /// Returns the paused text and an OffsetMap tracking where insertions
    /// occurred. Level 0 = off, 1 = subtle (periods), 2 = moderate (periods +
    /// commas), 3 = heavy (+ paragraph breaks); speech preparation uses the
    /// level in Settings (`ChapterSpeechInputs.punctuationPauseLevel`).
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
