import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Navigation (skip, heading, word/character seeking)

extension ReaderViewModel {

    /// Effective unit shown and used by the playback forward button. Hidden
    /// menus intentionally ignore saved book overrides and use global choices.
    var playbackSkipForwardUnit: SkipUnit {
        playbackSkipUnits.forward
    }

    /// Effective unit shown and used by the playback backward button.
    var playbackSkipBackwardUnit: SkipUnit {
        playbackSkipUnits.backward
    }

    /// Resolve both directions once through the shared, independently-tested
    /// policy so UI labels, button icons, and navigation actions cannot drift.
    private var playbackSkipUnits: (forward: SkipUnit, backward: SkipUnit) {
        PlaybackSkipUnitPolicy.resolve(
            mode: settingsViewModel.playbackNavigationUnitControlMode,
            localForwardRawValue: book.localSkipForwardUnit,
            localBackwardRawValue: book.localSkipBackwardUnit,
            globalForward: settingsViewModel.skipForwardUnit,
            globalBackward: settingsViewModel.skipBackwardUnit
        )
    }

    /// Save one per-book unit for both playback directions.
    func setSharedPlaybackSkipUnit(_ unit: SkipUnit) {
        persistPlaybackSkipUnits(forward: unit, backward: unit)
        announceToVoiceOver(unit.playbackMenuAccessibilityLabel())
    }

    /// Save a per-book unit for one playback direction while preserving the
    /// other direction's current effective choice.
    func setPlaybackSkipUnit(_ unit: SkipUnit, direction: PlaybackSkipDirection) {
        switch direction {
        case .forward:
            persistPlaybackSkipUnits(forward: unit, backward: playbackSkipBackwardUnit)
            announceToVoiceOver(unit.playbackMenuAccessibilityLabel(direction: .forward))
        case .backward:
            persistPlaybackSkipUnits(forward: playbackSkipForwardUnit, backward: unit)
            announceToVoiceOver(unit.playbackMenuAccessibilityLabel(direction: .backward))
        }
    }

    /// Advance one direction through the unit picker and announce the complete
    /// new value. Shared mode intentionally treats either key as editing the
    /// one common unit. Hidden-control mode edits the corresponding global
    /// fallback because no per-book choice is active in that mode.
    func cyclePlaybackSkipUnit(direction: PlaybackSkipDirection) {
        let currentUnit = direction == .forward
            ? playbackSkipForwardUnit
            : playbackSkipBackwardUnit
        // A book without pages, or of only one page, has no Page unit to
        // stop at (PG02).
        let nextUnit = Self.unit(after: currentUnit, bookHasPages: hasSeveralPages)

        switch settingsViewModel.playbackNavigationUnitControlMode {
        case .none:
            switch direction {
            case .forward:
                settingsViewModel.skipForwardUnit = nextUnit
            case .backward:
                settingsViewModel.skipBackwardUnit = nextUnit
            }
            announceToVoiceOver(nextUnit.playbackMenuAccessibilityLabel(direction: direction))
        case .shared:
            setSharedPlaybackSkipUnit(nextUnit)
        case .separate:
            setPlaybackSkipUnit(nextUnit, direction: direction)
        }
    }

    /// Update the observable reader copy and the durable library/package copy
    /// together so icons refresh immediately and values survive reopening.
    private func persistPlaybackSkipUnits(forward: SkipUnit, backward: SkipUnit) {
        book.localSkipForwardUnit = forward.rawValue
        book.localSkipBackwardUnit = backward.rawValue
        libraryViewModel.updateLocalSkipUnits(
            bookID: book.id,
            forward: forward.rawValue,
            backward: backward.rawValue
        )
    }

    /// Convert an original-text offset to modified-text space and seek the speech service.
    /// Falls back to using the offset directly if no transformation pipeline is active.
    func seekSpeechService(toOriginalOffset offset: Int) {
        let seekOffset = currentOffsetMap?.toModified(offset) ?? offset
        speechService.seek(toCharOffset: seekOffset)
    }

    /// Whether a move to `offset` in chapter `chapterIndex` can seek the
    /// speech already loaded instead of restarting it.
    ///
    /// Speech must be loaded, playing or paused. Speech that has finished,
    /// or never started, holds nothing to seek, and seeking it would start
    /// a direct utterance from the new offset on its own, outside Play, as
    /// a skip after a finished book once did: the move restarts from the
    /// cursor instead, which leaves a stopped reader silent until Play, or
    /// until a backward skip plays a finished book again (`performSkip`).
    /// The move must stay in the cursor's chapter, and while speech plays it
    /// must land where something speakable follows: seeking onto silent
    /// text, such as a skipped section that closes the chapter, would
    /// restart speech with nothing to say. Restarting from the cursor
    /// instead passes over that text, or ends the book when nothing
    /// speakable remains.
    private func canSeekLoadedSpeech(toChapter chapterIndex: Int, offset: Int, whilePlaying isPlaying: Bool) -> Bool {
        guard speechService.isSpeaking || speechService.isPaused else { return false }
        return chapterIndex == currentChapterIndex
            && (!isPlaying || loadedSpeechHasSpeakableText(afterOriginalOffset: offset))
    }

    /// Skip forward by the configured unit (or shift-unit if shift is held).
    /// Debounces rapid-fire calls. The window is wide enough to absorb
    /// a single physical press that arrives via two paths
    /// (NowPlayingService skip command + KeyboardShortcutManager
    /// notification, in cases where macOS routes a single media key to
    /// both) without dropping a deliberate second press.
    /// `lastSkipTime` is updated BEFORE running the skip so a re-entrant
    /// call inside the same main-loop tick is reliably blocked.
    func skipForward(useShiftUnit: Bool = false) {
        guard acquireSkipToken() else { return }
        cancelWhereAmIIfActive()
        soundEffectService?.play(for: .skipForward)
        let unit = Self.selectedSkipUnit(
            primary: playbackSkipForwardUnit,
            secondary: settingsViewModel.shiftSkipForwardUnit,
            useSecondary: useShiftUnit
        )
        DiagnosticLog.trace(.playback, "skipForward called, unit=\(unit.rawValue) shift=\(useShiftUnit)")
        performSkip(unit: unit, forward: true)
    }

    /// Skip backward by the configured unit (or shift-unit if shift is held).
    /// Debounces rapid-fire calls. See `skipForward` for the rationale.
    func skipBackward(useShiftUnit: Bool = false) {
        guard acquireSkipToken() else { return }
        cancelWhereAmIIfActive()
        soundEffectService?.play(for: .skipBackward)
        let unit = Self.selectedSkipUnit(
            primary: playbackSkipBackwardUnit,
            secondary: settingsViewModel.shiftSkipBackwardUnit,
            useSecondary: useShiftUnit
        )
        DiagnosticLog.trace(.playback, "skipBackward called, unit=\(unit.rawValue) shift=\(useShiftUnit)")
        performSkip(unit: unit, forward: false)
    }

    /// Atomically check the debounce window and update `lastSkipTime`.
    /// Returns true if the caller may proceed with a skip; false if the
    /// call should be dropped as a duplicate. The 0.4s window is
    /// deliberately a bit larger than the time between a media-key
    /// press hitting MPRemoteCommandCenter and the same key hitting an
    /// NSEvent local monitor on systems where both paths fire — the
    /// observed worst case is ~50–150ms, but I want margin so a brief
    /// macOS scheduling hiccup doesn't slip through. A user pressing
    /// rewind twice deliberately can wait 400ms.
    private func acquireSkipToken() -> Bool {
        let now = Date()
        if !Self.shouldAcquireSkipToken(lastSkipTime: lastSkipTime, now: now) {
            return false
        }
        // Update BEFORE running so a re-entrant call (e.g. a hook fires
        // synchronously from cancelWhereAmIIfActive() that re-posts a
        // skip notification) sees the updated timestamp on its next
        // check.
        lastSkipTime = now
        return true
    }

    nonisolated static func shouldAcquireSkipToken(lastSkipTime: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastSkipTime) > skipDebounceWindow
    }

    nonisolated static func selectedSkipUnit(
        primary: SkipUnit,
        secondary: SkipUnit,
        useSecondary: Bool
    ) -> SkipUnit {
        useSecondary ? secondary : primary
    }

    /// Dispatch a skip action based on the skip unit type.
    /// Time-based units convert to word or character deltas; structural units delegate to heading/bookmark nav.
    ///
    /// A finished book rests at its end with nothing playing, and keeps its
    /// media session so that the AirPods still reach it (`hasFinishedBook`).
    /// A backward skip from there, by whatever unit, plays the book again
    /// from where it lands, exactly as a skip during playback plays on: the
    /// listener who rewinds a finished book means to hear its end again.
    /// Play claims the media controls and a listening session as every
    /// start does, with its own sound after the skip's, and the book rests
    /// finished again when it ends again. A backward skip that could not
    /// move, such as a heading skip with no heading before, leaves the book
    /// finished and silent, as does a forward skip at the end, which stays
    /// there.
    ///
    /// The book plays again only while its reader is still the active
    /// owner (`NowPlayingSession.isActiveOwner`), as it is unless another
    /// book plays, since the rewind exists to hear the end again while
    /// nothing else plays. While another book plays, a backward skip in the
    /// finished book's window moves its cursor only, as any stopped
    /// reader's skip does, rather than play the finished book and pause the
    /// one being listened to by accident; the book then rests at its end no
    /// longer (REV07, speech finding 5, as the orchestrator recommended on
    /// October 7). The AirPods reach only the active owner, so their rewind
    /// plays any finished book it reaches.
    ///
    /// A forward skip from the book's end, where a finished book rests
    /// (`cursorRestsAtEnd`, TODO P07), has nowhere to go, and the cursor
    /// stays there, finished. Every skip by time or by words stops one unit,
    /// or one word, inside the last chapter, so it would otherwise move the
    /// cursor back off the end, and the book would read as finished no more.
    ///
    /// The play a backward skip starts from the end replays the finished
    /// book's end (`replaysFinishedEnd`, TODO P07): the end it plays on to
    /// is no new finish, counted or told, as the user decided on October 10,
    /// 2026 (question 14). A skip made while that replay plays is part of it,
    /// a structural one too, though it jumps (`navigateTo`), which ends a
    /// replay.
    func performSkip(unit: SkipUnit, forward: Bool) {
        DiagnosticLog.trace(.playback, "performSkip unit=\(unit.rawValue) forward=\(forward) wpm=\(speechService.wordsPerMinute)")
        guard !(forward && cursorRestsAtEnd) else {
            DiagnosticLog.trace(.playback, "performSkip: the book rests at its end; a forward skip stays there")
            return
        }
        // Taken before the skip: a structural skip jumps (`navigateTo`),
        // which itself leaves the finished state, and a replay, behind.
        let wasFinished = hasFinishedBook
        let wasReplayingFinishedEnd = replaysFinishedEnd
        let before = (chapter: currentChapterIndex, offset: currentCharacterOffset)
        switch unit {
        case .sentence:
            if forward { nextSentence() } else { previousSentence() }
        case .paragraph:
            if forward { nextParagraph() } else { previousParagraph() }
        case .page:
            if forward { nextPage() } else { previousPage() }
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
        // A replay of the finished end that goes on after the skip, playing
        // or paused, is still that replay. One the skip brought to the end,
        // which rests finished again and took the mark, or stopped, is over.
        let isPaused = isAudioBook ? audioPlaybackService.isPaused : speechService.isPaused
        if wasReplayingFinishedEnd, !hasFinishedBook, isPlaybackUnderWay || isPaused {
            replaysFinishedEnd = true
        }
        // The finished book plays again from where a backward skip landed,
        // while nothing else plays.
        guard wasFinished, !forward,
              before != (chapter: currentChapterIndex, offset: currentCharacterOffset) else { return }
        guard nowPlayingService.isActiveOwner else {
            // Another reader is the active owner, as the one playing is:
            // this book's cursor has moved, as any stopped reader's does,
            // and it rests at its end no longer.
            DiagnosticLog.trace(.playback, "performSkip: another reader is the active owner; the finished book's cursor moved only")
            hasFinishedBook = false
            return
        }
        DiagnosticLog.trace(.playback, "performSkip: the finished book plays again from where the skip landed")
        // The end this play reaches replays the finished end (TODO P07).
        replaysFinishedEnd = true
        play()
    }

    /// Jump to the next subheading (level >= 2) after the current position,
    /// saying every heading that begins there
    /// (`headingAnnouncement(arrivingAt:in:)`).
    func nextSubheading() {
        guard content != nil else { return }
        // `headings` is the book's headings (`content`'s didSet), kept as an
        // array, so the book's index need not rebuild them for each jump.
        let allHeadings = headings
        if let nextIndex = allHeadings.firstIndex(where: {
            $0.level >= 2 && (
                $0.chapterIndex > currentChapterIndex ||
                ($0.chapterIndex == currentChapterIndex && $0.characterOffset > currentCharacterOffset)
            )
        }) {
            let heading = allHeadings[nextIndex]
            navigateTo(chapterIndex: heading.chapterIndex, characterOffset: heading.characterOffset)
            announceToVoiceOver(Self.headingAnnouncement(arrivingAt: heading, in: allHeadings))
        }
    }

    /// Jump to the previous subheading (level >= 2) before the current
    /// position, saying every heading that begins there
    /// (`headingAnnouncement(arrivingAt:in:)`).
    func previousSubheading() {
        guard content != nil else { return }
        let allHeadings = headings
        if let prevIndex = allHeadings.lastIndex(where: {
            $0.level >= 2 && (
                $0.chapterIndex < currentChapterIndex ||
                ($0.chapterIndex == currentChapterIndex && $0.characterOffset < currentCharacterOffset - 10)
            )
        }) {
            let heading = allHeadings[prevIndex]
            navigateTo(chapterIndex: heading.chapterIndex, characterOffset: heading.characterOffset)
            announceToVoiceOver(Self.headingAnnouncement(arrivingAt: heading, in: allHeadings))
        }
    }

    /// What VoiceOver hears on arriving at `heading`, one of `headings`, by a
    /// heading or subheading jump: every heading that begins at its place,
    /// the outermost first, as in "Heading: Season Two, Where Is
    /// Everybody?", where a group heading of an audiobook's manifest and
    /// its first track's heading begin together. A heading alone at its
    /// place is said as it always was, "Heading: Elegy". Blank headings are
    /// left out of a place they share; one alone is said as before.
    nonisolated static func headingAnnouncement(arrivingAt heading: Heading, in headings: [Heading]) -> String {
        let words = headingsSharingPlace(with: heading, in: headings).compactMap(\.text.nonBlank)
        return "Heading: " + (words.isEmpty ? heading.text : words.joined(separator: ", "))
    }

    /// The headings of `headings` that begin where `heading` begins, itself
    /// among them: the outermost (the lowest level) first, and headings of
    /// one level in the order the list gives them.
    nonisolated static func headingsSharingPlace(with heading: Heading, in headings: [Heading]) -> [Heading] {
        headings.enumerated()
            .filter { $0.element.chapterIndex == heading.chapterIndex && $0.element.characterOffset == heading.characterOffset }
            .sortedStably { ($0.element.level, $0.offset) < ($1.element.level, $1.offset) }
            .map(\.element)
    }

    // MARK: - Sentence Navigation

    /// Jump forward to the start of the next sentence after the current position.
    /// Scans for sentence-ending punctuation (. ! ?) followed by whitespace.
    /// Crosses chapter boundaries if no next sentence is found in the current chapter.
    func nextSentence() {
        guard let content = content,
              currentChapterIndex < content.chapters.count else { return }

        let text = content.chapters[currentChapterIndex].text
        if let newOffset = Self.nextSentenceStart(in: text, after: currentCharacterOffset) {
            navigateTo(chapterIndex: currentChapterIndex, characterOffset: newOffset)
            announceToVoiceOver("Next sentence")
            return
        }

        // No next sentence in current chapter — advance to start of next non-empty chapter
        var nextChapter = currentChapterIndex + 1
        while nextChapter < content.chapters.count &&
              content.chapters[nextChapter].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            nextChapter += 1
        }
        if nextChapter < content.chapters.count {
            navigateTo(chapterIndex: nextChapter, characterOffset: 0)
            announceSectionCrossing(forward: true)
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
            let prevOffset = findSentenceStart(in: prevText, before: prevText.utf16Length)
            navigateTo(chapterIndex: prevChapter, characterOffset: prevOffset)
            announceSectionCrossing(forward: false)
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
        if let newOffset = Self.nextParagraphStart(in: text, after: currentCharacterOffset) {
            navigateTo(chapterIndex: currentChapterIndex, characterOffset: newOffset)
            announceToVoiceOver("Next paragraph")
            return
        }

        // No next paragraph in current chapter — advance to next non-empty chapter
        var nextChapter = currentChapterIndex + 1
        while nextChapter < content.chapters.count &&
              content.chapters[nextChapter].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            nextChapter += 1
        }
        if nextChapter < content.chapters.count {
            navigateTo(chapterIndex: nextChapter, characterOffset: 0)
            announceSectionCrossing(forward: true)
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
            let prevOffset = findParagraphStart(in: prevText, before: prevText.utf16Length)
            navigateTo(chapterIndex: prevChapter, characterOffset: prevOffset)
            announceSectionCrossing(forward: false)
        }
    }

    // MARK: - Section Crossing Announcements

    /// Announce a sentence or paragraph move that crossed into another content
    /// unit. Call after navigating, so the announcement describes where the
    /// cursor landed.
    private func announceSectionCrossing(forward: Bool) {
        announceToVoiceOver(Self.sectionCrossingAnnouncement(
            in: headings,
            chapterIndex: currentChapterIndex,
            characterOffset: currentCharacterOffset,
            forward: forward
        ))
    }

    /// Wording for a sentence or paragraph move that crossed a content-unit
    /// boundary. Content units (spine files, audio files) are internal and
    /// their count means nothing to the listener, so this names the heading
    /// at or before the new position, as the headings panel would, or says
    /// "Next section" / "Previous section" when no heading precedes it.
    nonisolated static func sectionCrossingAnnouncement(
        in headings: [Heading],
        chapterIndex: Int,
        characterOffset: Int,
        forward: Bool
    ) -> String {
        HeadingPosition(in: headings, chapterIndex: chapterIndex, characterOffset: characterOffset).headingText
            ?? (forward ? "Next section" : "Previous section")
    }

    /// Find the next sentence start using the reader's persisted UTF-16 offsets.
    nonisolated static func nextSentenceStart(in text: String, after offset: Int) -> Int? {
        guard offset >= 0, offset < text.utf16Length else { return nil }
        let sentenceEnders: Set<Character> = [".", "!", "?"]
        var position = text.index(atUTF16Offset: offset)

        while position < text.endIndex {
            if sentenceEnders.contains(text[position]) {
                var start = text.index(after: position)
                while start < text.endIndex && text[start].isWhitespace {
                    start = text.index(after: start)
                }
                let result = text.utf16Offset(of: start)
                if result > offset && start < text.endIndex { return result }
            }
            position = text.index(after: position)
        }
        return nil
    }

    /// Find the sentence containing the cursor, or the chapter start when none precedes it.
    nonisolated static func sentenceStart(in text: String, before offset: Int) -> Int {
        guard offset > 0, offset <= text.utf16Length else { return 0 }
        let sentenceEnders: Set<Character> = [".", "!", "?"]
        var position = text.index(atUTF16Offset: min(offset - 1, text.utf16Length - 1))

        while position > text.startIndex {
            position = text.index(before: position)
            if sentenceEnders.contains(text[position]) {
                var start = text.index(after: position)
                while start < text.endIndex && text[start].isWhitespace {
                    start = text.index(after: start)
                }
                return text.utf16Offset(of: start)
            }
        }
        return 0
    }

    /// Find the next paragraph start after a double-newline boundary.
    nonisolated static func nextParagraphStart(in text: String, after offset: Int) -> Int? {
        guard offset >= 0, offset < text.utf16Length - 1 else { return nil }
        var position = text.index(atUTF16Offset: offset)

        while position < text.endIndex {
            let nextPosition = text.index(after: position)
            if nextPosition < text.endIndex && text[position] == "\n" && text[nextPosition] == "\n" {
                var start = text.index(after: nextPosition)
                while start < text.endIndex && text[start].isWhitespace && text[start] != "\n" {
                    start = text.index(after: start)
                }
                while start < text.endIndex && text[start] == "\n" {
                    start = text.index(after: start)
                }
                let result = text.utf16Offset(of: start)
                if result > offset && start < text.endIndex { return result }
            }
            position = nextPosition
        }
        return nil
    }

    /// Find the paragraph containing the cursor, or the chapter start when none precedes it.
    nonisolated static func paragraphStart(in text: String, before offset: Int) -> Int {
        guard offset > 1, offset <= text.utf16Length else { return 0 }
        var position = text.index(atUTF16Offset: min(offset - 1, text.utf16Length - 1))

        while position > text.startIndex {
            let previous = text.index(before: position)
            if text[position] == "\n" && text[previous] == "\n" {
                var start = text.index(after: position)
                while start < text.endIndex && text[start].isWhitespace && text[start] != "\n" {
                    start = text.index(after: start)
                }
                return text.utf16Offset(of: start)
            }
            position = previous
        }
        return 0
    }

    /// Skip forward or backward by a number of words, scanning actual word boundaries
    /// in the text. Handles cross-chapter boundaries.
    func skipWords(count: Int) {
        guard let content = content,
              currentChapterIndex < content.chapters.count else { return }
        // A skip to or past where the heading this reader's End of heading
        // sleep timer waits for ends, ends the timer (finding #787).
        defer { endSleepTimerIfMoveReachedHeadingEnd() }

        let wasPlaying = speechService.isSpeaking && !speechService.isPaused

        DiagnosticLog.trace(.playback, "skipWords count=\(count) currentOffset=\(currentCharacterOffset) chapter=\(currentChapterIndex)")

        var chapIdx = currentChapterIndex
        var remainingWords = abs(count)
        let forward = count > 0

        // Start from current position and scan word boundaries, crossing chapters as needed
        var charOffset = currentCharacterOffset

        while remainingWords > 0 {
            let chapterText = content.chapters[chapIdx].text

            if forward {
                // Scan forward through word boundaries in this chapter
                let newOffset = Self.offsetAfterSkippingWords(in: chapterText, from: charOffset, wordCount: remainingWords)
                let wordsSkipped = Self.countWordsBetween(in: chapterText, from: charOffset, to: newOffset)
                remainingWords -= wordsSkipped

                if remainingWords > 0 {
                    // Hit end of chapter — advance to next
                    if chapIdx + 1 < content.chapters.count {
                        chapIdx += 1
                        charOffset = 0
                    } else {
                        // At last chapter — clamp to end
                        charOffset = max(0, chapterText.utf16Length - 1)
                        break
                    }
                } else {
                    charOffset = newOffset
                }
            } else {
                // Scan backward through word boundaries in this chapter
                let newOffset = Self.offsetAfterSkippingWords(in: chapterText, from: charOffset, wordCount: -remainingWords)
                let wordsSkipped = Self.countWordsBetween(in: chapterText, from: newOffset, to: charOffset)
                remainingWords -= wordsSkipped

                if remainingWords > 0 && newOffset == 0 {
                    // Hit start of chapter — go to previous
                    if chapIdx > 0 {
                        chapIdx -= 1
                        charOffset = content.chapters[chapIdx].text.utf16Length
                    } else {
                        charOffset = 0
                        break
                    }
                } else {
                    charOffset = newOffset
                }
            }
        }

        let seeksInPlace = canSeekLoadedSpeech(toChapter: chapIdx, offset: charOffset, whilePlaying: wasPlaying)

        DiagnosticLog.trace(.playback, "skipWords result -> chapter=\(chapIdx) offset=\(charOffset) seeksInPlace=\(seeksInPlace)")

        // Whether speech still plays after the skip. Restarting it ends the
        // book instead when nothing speakable remains from the new cursor.
        var isStillPlaying = wasPlaying
        if seeksInPlace {
            // Same chapter: seek without re-rendering.
            // If engine has rendered audio, this is an instant buffer seek.
            // If still in direct mode, this restarts direct speech from the new offset
            // without cancelling the in-progress engine render.
            currentCharacterOffset = charOffset
            seekSpeechService(toOriginalOffset: charOffset)
        } else {
            // Different chapter, or silent text after the new cursor while
            // playing — invalidate stale callbacks before changing state
            chapterPlaybackGeneration += 1
            // Cancel stale pre-rendered chapter
            discardLookAhead()

            speechService.stop()

            // Now safe to update chapter/offset — no stale callback can overwrite
            currentChapterIndex = chapIdx
            currentCharacterOffset = charOffset

            if wasPlaying {
                isStillPlaying = speakCurrentChapter()
            }
        }

        if isStillPlaying {
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
        guard let charDelta = Self.timeSkipCharacterDelta(
            seconds: seconds,
            totalCharacterCount: content.totalCharacterCount,
            totalTime: totalTime
        ) else { return }
        // A skip to or past where the heading this reader's End of heading
        // sleep timer waits for ends, ends the timer (finding #787).
        defer { endSleepTimerIfMoveReachedHeadingEnd() }

        DiagnosticLog.trace(.playback, "skipByTime seconds=\(seconds) totalTime=\(totalTime) totalChars=\(content.totalCharacterCount) charDelta=\(charDelta)")

        let wasPlaying = speechService.isSpeaking && !speechService.isPaused

        var chapIdx = currentChapterIndex
        var charOffset = currentCharacterOffset + charDelta

        // Handle cross-chapter navigation
        if charOffset < 0 {
            while charOffset < 0 && chapIdx > 0 {
                chapIdx -= 1
                charOffset += content.chapters[chapIdx].text.utf16Length
            }
            charOffset = max(0, charOffset)
        } else {
            while chapIdx < content.chapters.count && charOffset >= content.chapters[chapIdx].text.utf16Length {
                charOffset -= content.chapters[chapIdx].text.utf16Length
                chapIdx += 1
            }
            if chapIdx >= content.chapters.count {
                chapIdx = content.chapters.count - 1
                charOffset = max(0, content.chapters[chapIdx].text.utf16Length - 1)
            }
        }

        // Snap to nearest word boundary so playback doesn't start mid-word
        let text = content.chapters[chapIdx].text
        charOffset = Self.snappedWordStart(in: text, at: charOffset)

        let seeksInPlace = canSeekLoadedSpeech(toChapter: chapIdx, offset: charOffset, whilePlaying: wasPlaying)

        // Whether speech still plays after the skip. Restarting it ends the
        // book instead when nothing speakable remains from the new cursor.
        var isStillPlaying = wasPlaying
        if seeksInPlace {
            currentCharacterOffset = charOffset
            seekSpeechService(toOriginalOffset: charOffset)
        } else {
            chapterPlaybackGeneration += 1
            discardLookAhead()

            speechService.stop()
            currentChapterIndex = chapIdx
            currentCharacterOffset = charOffset

            if wasPlaying {
                isStillPlaying = speakCurrentChapter()
            }
        }

        if isStillPlaying {
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
        // A skip to or past where the heading this reader's End of heading
        // sleep timer waits for ends, ends the timer (finding #787).
        defer { endSleepTimerIfMoveReachedHeadingEnd() }

        let wasPlaying = audioPlaybackService.isPlaying && !audioPlaybackService.isPaused

        var chapIdx = currentChapterIndex
        var charOffset = currentCharacterOffset + count

        // Handle cross-chapter navigation
        if charOffset < 0 {
            while charOffset < 0 && chapIdx > 0 {
                chapIdx -= 1
                charOffset += content.chapters[chapIdx].text.utf16Length
            }
            charOffset = max(0, charOffset)
        } else {
            while chapIdx < content.chapters.count && charOffset >= content.chapters[chapIdx].text.utf16Length {
                charOffset -= content.chapters[chapIdx].text.utf16Length
                chapIdx += 1
            }
            if chapIdx >= content.chapters.count {
                chapIdx = content.chapters.count - 1
                charOffset = max(0, content.chapters[chapIdx].text.utf16Length - 1)
            }
        }

        if chapIdx != currentChapterIndex {
            audioPlaybackService.stop()
            // Pre-rendered next-chapter engine is meaningless once we
            // jump away — discard it so a stale render doesn't get
            // adopted later. Same cleanup pattern as skipByTime() and
            // navigateTo().
            discardLookAhead()

            currentChapterIndex = chapIdx
            currentCharacterOffset = charOffset
            if wasPlaying {
                playAudioChapter()
            }
        } else {
            currentCharacterOffset = charOffset
            // Translate chapter-relative offset to absolute seek target
            // via chapterStartTime — handles segmented DAISY, m4b with
            // chapter markers, multi-file, and single-file uniformly.
            // Without this every layout other than multi-file/single-
            // file landed at the wrong absolute time when the user did
            // a same-chapter skip. A segmented chapter's time counts from
            // its start; the audio service finds the clip, and loads its
            // file, for a time in another of the chapter's clips.
            let timeOffset = Double(charOffset) / Self.audioCharsPerSecond
                + chapterStartTime(currentChapterIndex)
            audioPlaybackService.seek(to: timeOffset)
        }

        savePosition()
    }

    /// Jump to the next heading after the current position, of any level,
    /// saying every heading that begins there
    /// (`headingAnnouncement(arrivingAt:in:)`). Headings that share a place
    /// are one stop: the next jump goes on to the next place.
    func nextHeading() {
        guard content != nil else { return }
        let allHeadings = headings
        if let heading = Self.nextHeading(
            in: allHeadings,
            chapterIndex: currentChapterIndex,
            characterOffset: currentCharacterOffset
        ) {
            navigatePreservingReturnPosition(
                chapterIndex: heading.chapterIndex,
                characterOffset: heading.characterOffset
            )
            announceToVoiceOver(Self.headingAnnouncement(arrivingAt: heading, in: allHeadings))
        }
    }

    /// Jump to the previous heading before the current position, of any
    /// level, saying every heading that begins there
    /// (`headingAnnouncement(arrivingAt:in:)`).
    func previousHeading() {
        guard content != nil else { return }
        let allHeadings = headings
        if let heading = Self.previousHeading(
            in: allHeadings,
            chapterIndex: currentChapterIndex,
            characterOffset: currentCharacterOffset
        ) {
            navigatePreservingReturnPosition(
                chapterIndex: heading.chapterIndex,
                characterOffset: heading.characterOffset
            )
            announceToVoiceOver(Self.headingAnnouncement(arrivingAt: heading, in: allHeadings))
        }
    }

    /// Navigate to a specific heading (from table of contents), saving current position for return.
    func navigateToHeading(_ heading: Heading) {
        navigatePreservingReturnPosition(
            chapterIndex: heading.chapterIndex,
            characterOffset: heading.characterOffset
        )
        autoPlayIfEnabled()
    }

    /// Navigate to a specific chapter and character offset.
    /// Handles both TTS and audio book playback, with same-chapter seek optimization.
    /// Every jump goes through here: to a heading, a bookmark, a search
    /// result, a place in the book, or the next sentence or paragraph. A
    /// jump to or past where the heading this reader's End of heading sleep
    /// timer waits for ends, ends the timer there once the jump is made
    /// (`endSleepTimerIfMoveReachedHeadingEnd()`, finding #787).
    ///
    /// A jump while Where Am I? has the book in hand ends the announcement
    /// first, as a skip does (`cancelWhereAmIIfActive()`): the book it paused
    /// plays again, or the Play it held starts, so the jump moves a book that
    /// plays, and it plays on from where the jump lands. Before, the jump
    /// found the book paused, stopped its speech, or an audiobook's player
    /// for another chapter, and the announcement's end then had nothing to
    /// resume, leaving the book silent; with Auto-play on navigate, the
    /// play that follows the jump only ended the announcement (REV12).
    func navigateTo(chapterIndex: Int, characterOffset: Int) {
        guard let content = content, !content.chapters.isEmpty else { return }
        cancelWhereAmIIfActive()
        defer { endSleepTimerIfMoveReachedHeadingEnd() }
        // A jump leaves a finished book's end behind: the reader then rests
        // where the jump lands, as any stopped reader does, and its skips
        // move the cursor without playing until Play (`hasFinishedBook`). A
        // backward skip that jumps plays all the same, having asked first
        // (`performSkip(unit:forward:)`). A replay of the finished end ends
        // too: the end reached after a jump is a new one (TODO P07), as a
        // listener who jumps to the end asked to hear it.
        hasFinishedBook = false
        replaysFinishedEnd = false

        let clampedPosition = Self.clampedNavigationPosition(
            in: content,
            chapterIndex: chapterIndex,
            characterOffset: characterOffset
        )
        let chapterIndex = clampedPosition.chapterIndex
        let characterOffset = clampedPosition.characterOffset

        if isAudioBook {
            // During the pause between two chapters nothing plays, so a jump
            // moves only the cursor, and the chapter waiting out the pause
            // starts from wherever the jump went once the pause is over
            // (`startCursorChapter(afterPause:)`).
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
                // Translate chapter-relative offset to absolute via
                // chapterStartTime, which knows about all four audio
                // layouts (multi-file, segmented DAISY, m4b chapter
                // markers, single-file). This was the same bug as in
                // skipCharacters — same-chapter seeks landed at the
                // wrong global time on m4b chapter books. A segmented
                // chapter's clips are found by the audio service.
                let timeOffset = Double(characterOffset) / Self.audioCharsPerSecond
                    + chapterStartTime(currentChapterIndex)
                audioPlaybackService.seek(to: timeOffset)
            }
            savePosition()
            return
        }

        let wasPlaying = speechService.isSpeaking && !speechService.isPaused

        if wasPlaying && canSeekLoadedSpeech(toChapter: chapterIndex, offset: characterOffset, whilePlaying: true) {
            // Same chapter: instant seek, no re-rendering.
            // Convert original-text offset to modified-text offset for the speech service.
            currentCharacterOffset = characterOffset
            seekSpeechService(toOriginalOffset: characterOffset)
        } else {
            // Different chapter, not playing, or silent text after the new
            // position — invalidate stale callbacks first
            chapterPlaybackGeneration += 1
            discardLookAhead()

            speechService.stop()
            currentChapterIndex = chapterIndex
            currentCharacterOffset = characterOffset
            // Restarting speech ends the book instead when nothing speakable
            // remains from the new position; Now Playing must not then claim
            // that playback continues.
            if wasPlaying && speakCurrentChapter() {
                nowPlayingService.updateNowPlayingInfo(
                    title: book.title, author: book.author, isPlaying: true
                )
            }
        }

        savePosition()
    }

    // MARK: - Word Boundary Scanning

    /// Clamp a requested reader position to the document's valid UTF-16
    /// coordinates. Keeping this pure prevents bookmark, search, and heading
    /// navigation from drifting into subtly different boundary rules.
    nonisolated static func clampedNavigationPosition(
        in content: DocumentContent,
        chapterIndex: Int,
        characterOffset: Int
    ) -> (chapterIndex: Int, characterOffset: Int) {
        guard !content.chapters.isEmpty else { return (0, 0) }
        let chapterIndex = min(max(0, chapterIndex), content.chapters.count - 1)
        let chapterLength = content.chapters[chapterIndex].text.utf16Length
        let characterOffset = min(max(0, characterOffset), max(0, chapterLength - 1))
        return (chapterIndex, characterOffset)
    }

    /// Find the character offset after skipping a given number of words forward (positive)
    /// or backward (negative) from a starting offset. Scans actual word boundaries in the text
    /// rather than using a fixed chars-per-word estimate.
    nonisolated static func offsetAfterSkippingWords(in text: String, from startOffset: Int, wordCount: Int) -> Int {
        guard !text.isEmpty else { return 0 }
        let clampedStart = max(0, min(startOffset, text.utf16Length))

        if wordCount > 0 {
            // Scan forward: find the start of the Nth next word
            var idx = text.index(atUTF16Offset: clampedStart)
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
            return text.utf16Offset(of: idx)
        } else {
            // Scan backward: find the start of the Nth previous word
            let targetWords = abs(wordCount)
            var idx = text.index(atUTF16Offset: clampedStart)
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
            return text.utf16Offset(of: idx)
        }
    }

    /// Count the number of word boundaries between two offsets in a text.
    /// Used to determine how many words were actually skipped within a chapter.
    nonisolated static func countWordsBetween(in text: String, from startOffset: Int, to endOffset: Int) -> Int {
        guard !text.isEmpty, startOffset < endOffset else { return 0 }
        let start = text.index(atUTF16Offset: max(0, min(startOffset, text.utf16Length)))
        let end = text.index(atUTF16Offset: max(0, min(endOffset, text.utf16Length)))
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

    /// Convert a time skip into the character delta used by the reader's
    /// remaining-time model. Nil indicates content with no usable duration.
    nonisolated static func timeSkipCharacterDelta(
        seconds: Double,
        totalCharacterCount: Int,
        totalTime: TimeInterval
    ) -> Int? {
        guard totalTime > 0, totalCharacterCount > 0 else { return nil }
        return Int(seconds / totalTime * Double(totalCharacterCount))
    }

    /// Snap a UTF-16 offset backward to the beginning of its current word.
    /// Out-of-range offsets are clamped so navigation never creates an invalid index.
    nonisolated static func snappedWordStart(in text: String, at offset: Int) -> Int {
        guard !text.isEmpty else { return 0 }
        let clampedOffset = min(max(0, offset), text.utf16Length)
        guard clampedOffset > 0, clampedOffset < text.utf16Length else { return clampedOffset }

        var wordStart = text.index(atUTF16Offset: clampedOffset)
        while wordStart > text.startIndex && !text[text.index(before: wordStart)].isWhitespace {
            wordStart = text.index(before: wordStart)
        }
        return text.utf16Offset(of: wordStart)
    }

    /// Return the heading at or immediately before the current reading position.
    /// Delegates to `HeadingPosition` so heading lookups and the spoken
    /// "Heading N of M" numbering can never disagree.
    nonisolated static func currentHeading(
        in headings: [Heading],
        chapterIndex: Int,
        characterOffset: Int
    ) -> Heading? {
        HeadingPosition(in: headings, chapterIndex: chapterIndex, characterOffset: characterOffset).heading
    }

    /// The first heading after the cursor, where the heading the cursor is
    /// in ends; nil after the last heading.
    var headingAfterCursor: Heading? {
        Self.nextHeading(in: headings, chapterIndex: currentChapterIndex, characterOffset: currentCharacterOffset)
    }

    /// Return the first heading strictly after the current reading position.
    nonisolated static func nextHeading(
        in headings: [Heading],
        chapterIndex: Int,
        characterOffset: Int
    ) -> Heading? {
        headings.first(where: {
            $0.chapterIndex > chapterIndex ||
            ($0.chapterIndex == chapterIndex && $0.characterOffset > characterOffset)
        })
    }

    /// Return the prior heading, ignoring a heading immediately behind the cursor
    /// so repeated Previous commands continue moving instead of selecting itself.
    nonisolated static func previousHeading(
        in headings: [Heading],
        chapterIndex: Int,
        characterOffset: Int,
        graceZone: Int = 10
    ) -> Heading? {
        headings.last(where: {
            $0.chapterIndex < chapterIndex ||
            ($0.chapterIndex == chapterIndex && $0.characterOffset < characterOffset - graceZone)
        })
    }
}
