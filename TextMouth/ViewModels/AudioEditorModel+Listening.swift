import Foundation

// MARK: - Listening and Moving (FR04)

/// Playing, stopping, and moving the cursor: by a step, to the start or the
/// end, to a time typed, from chapter marker to chapter marker, and from
/// pause to pause; and Where Am I. A move while playing carries the audio
/// on from the new place; a move while still plays half a second there, so
/// the place is heard, when the setting says so. The small steps announce
/// nothing, since the time display and the half second say where the
/// cursor went; every jump says where it landed.
extension AudioEditorModel {
    // MARK: Playing

    /// Plays from the cursor, or pauses where the audio is, saying where.
    /// At the very end it plays from the start.
    func togglePlay() {
        guard hasPreview else { return announce(AudioEditorWording.notReadyToPlay) }
        if playing == .previewing {
            // Play stops a filter's preview, as Stop does.
            return endFilterPreview()
        }
        if case .listening = playing {
            player.pause()
            cursor = clamped(player.currentTime)
            playing = .idle
            isPlaying = false
            announce(AudioEditorWording.paused(at: cursor))
            return
        }
        var from = cursor
        if from >= duration - Self.timeTolerance {
            from = 0
            cursor = 0
            announce(AudioEditorWording.playingFromStart)
        }
        playing = .listening(from: from)
        isPlaying = true
        player.play(from: from, until: nil)
    }

    /// Stops playing and goes back to where playing began, saying where;
    /// stops a scrub where it is.
    func stop() {
        switch playing {
        case .listening(let from):
            player.pause()
            playing = .idle
            isPlaying = false
            cursor = clamped(from)
            player.seek(to: cursor)
            announce(AudioEditorWording.stopped(backAt: cursor))
        case .scrubbing:
            player.pause()
            playing = .idle
        case .previewing:
            endFilterPreview()
        case .idle:
            announce(AudioEditorWording.notPlaying)
        }
    }

    /// The player's clock moved while playing: the cursor follows it while
    /// listening, and stays put during a scrub.
    func playerMoved(to time: TimeInterval) {
        guard case .listening = playing else { return }
        cursor = clamped(time)
    }

    /// The player stopped by itself: at the end of the audio while
    /// listening, which is said; at a scrub's end, which says nothing.
    func playerStopped() {
        switch playing {
        case .listening:
            playing = .idle
            isPlaying = false
            cursor = clamped(player.currentTime)
            if cursor >= duration - 0.05 {
                cursor = duration
                announce(AudioEditorWording.endOfAudio)
            }
        case .scrubbing:
            playing = .idle
        case .previewing:
            // The preview played to its end: the edited audio comes back.
            endFilterPreview()
        case .idle:
            break
        }
    }

    // MARK: Moving

    /// Whether the half second after each move is played: the setting in
    /// the Audio Editing group, on until turned off.
    var scrubsAfterMoves: Bool {
        AudioEditorPreferences.playAfterMoves.read(from: store)
    }

    /// Moves the cursor to `time`, kept inside the audio, and says
    /// `sentence` when there is one. While listening, the audio plays on
    /// from there; otherwise half a second of it plays there, when the
    /// setting says so.
    func move(to time: TimeInterval, saying sentence: String? = nil) {
        let target = clamped(time)
        cursor = target
        if playing == .previewing {
            // The edited audio comes back, at the new place.
            endFilterPreview()
            if let sentence {
                announce(sentence)
            }
            return
        }
        switch playing {
        case .listening:
            player.play(from: target, until: nil)
        case .scrubbing, .previewing, .idle:
            if scrubsAfterMoves, target < duration - Self.timeTolerance {
                playing = .scrubbing
                player.play(from: target, until: min(duration, target + AudioEditorModel.scrubLength))
            } else {
                playing = .idle
                player.seek(to: target)
            }
        }
        if let sentence {
            announce(sentence)
        }
    }

    /// How long a scrub plays, in seconds.
    static let scrubLength: TimeInterval = 0.5

    /// Moves the cursor `seconds` on, or back for a negative number; at the
    /// start or the end, says it can go no further.
    func skip(by seconds: TimeInterval) {
        let from = isPlaying ? clamped(player.currentTime) : cursor
        if seconds < 0, from <= Self.timeTolerance {
            announce(AudioEditorWording.atStart)
            return
        }
        if seconds > 0, from >= duration - Self.timeTolerance {
            announce(AudioEditorWording.atEnd)
            return
        }
        move(to: from + seconds)
    }

    /// Moves the cursor to the start of the audio.
    func goToStart() {
        move(to: 0, saying: AudioEditorWording.startOfAudio)
    }

    /// Moves the cursor to the end of the audio.
    func goToEnd() {
        move(to: duration, saying: AudioEditorWording.endOfAudio(duration))
    }

    /// Moves the cursor to the time `text` names, as Go to Time's field
    /// holds it; returns the sentence saying what's wrong with it, or nil
    /// once moved.
    func goToTime(typed text: String) -> String? {
        switch TimeEntry.reading(text) {
        case .problem(let sentence):
            return sentence
        case .seconds(let time):
            guard time <= duration + Self.timeTolerance else {
                return AudioEditorWording.afterTheEnd(duration)
            }
            move(to: time, saying: AudioEditorWording.spoken(clamped(time)))
            return nil
        }
    }

    // MARK: Chapters

    /// Moves the cursor to the next chapter marker, saying which.
    func nextChapter() {
        guard !chapters.isEmpty else { return announce(AudioEditorWording.noChapters) }
        guard let index = chapters.firstIndex(where: { $0.start > cursor + Self.timeTolerance }) else {
            return announce(AudioEditorWording.noChapterAfter)
        }
        goToChapter(index)
    }

    /// Moves the cursor to the previous chapter marker, saying which: the
    /// start of the chapter the cursor is in, unless it is at that start.
    func previousChapter() {
        guard !chapters.isEmpty else { return announce(AudioEditorWording.noChapters) }
        guard let index = chapters.lastIndex(where: { $0.start < cursor - Self.timeTolerance }) else {
            return announce(AudioEditorWording.noChapterBefore)
        }
        goToChapter(index)
    }

    /// Moves the cursor to chapter marker `index`, saying which, closing the
    /// list it may have been chosen in.
    func goToChapter(_ index: Int) {
        guard chapters.indices.contains(index) else { return }
        if sheet == .markers {
            sheet = nil
        }
        let chapter = chapters[index]
        move(to: chapter.start, saying: AudioEditorWording.chapter(number: index + 1, title: chapter.title, at: chapter.start))
    }

    // MARK: Pauses

    /// Moves the cursor to where the sound after the next pause begins,
    /// saying how long the pause was.
    func nextPause() {
        guard let pauses = pausesFound() else { return }
        guard let pause = pauses.first(where: { $0.end > cursor + Self.timeTolerance }) else {
            return announce(AudioEditorWording.noPauseAfter)
        }
        move(to: pause.end, saying: AudioEditorWording.afterPause(pause))
    }

    /// Moves the cursor to where the sound after the previous pause begins,
    /// saying how long the pause was.
    func previousPause() {
        guard let pauses = pausesFound() else { return }
        guard let pause = pauses.last(where: { $0.end < cursor - Self.timeTolerance }) else {
            return announce(AudioEditorWording.noPauseBefore)
        }
        move(to: pause.end, saying: AudioEditorWording.afterPause(pause))
    }

    /// The pauses, once found; otherwise says why there are none yet, and
    /// gives nil.
    func pausesFound() -> [AudioEditorPause]? {
        switch pauseSearch {
        case .found:
            return pauses
        case .finding:
            announce(AudioEditorWording.findingPauses)
        case .failed(let reason):
            announce(AudioEditorWording.pausesFailed(reason))
        }
        return nil
    }

    /// Measures the edited audio's levels again, on a thread of their own,
    /// and finds its pauses; a measurement under way, of audio since
    /// changed, is cancelled, and the new one begins once it has stopped.
    func measureLevels() {
        // One measurement at a time. The older one, cancelled, stops only
        // at its next buffer, so the newer waits for it to end before it
        // builds its composition and reads: two readers decoding the
        // edited audio at once would double the decoding and the memory of
        // a long book for nothing, and a burst of edits would pile readers
        // up as fast as the keys are pressed. Waiting keeps a burst to one
        // reader, and the editor's pauses to the order of its edits.
        let older = measuring
        older?.cancel()
        pauseSearch = .finding
        pauses = []
        measuring = Task { [weak self] in
            await older?.value
            guard let self, !Task.isCancelled else { return }
            do {
                let preview = try await self.session.makePreview()
                let measured = try await AudioEditorLevels.measure(preview)
                try Task.checkCancellation()
                self.levels = measured
                self.pauses = measured.pauses()
                self.pauseSearch = .found
            } catch is CancellationError {
                // A newer measurement replaced this one.
            } catch {
                guard !Task.isCancelled else { return }
                self.pauseSearch = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Where Am I

    /// Says the status line: where the cursor is, of how long the audio
    /// lasts, in which chapter, and what is selected.
    func whereAmI() {
        announce(statusSentence)
    }
}
