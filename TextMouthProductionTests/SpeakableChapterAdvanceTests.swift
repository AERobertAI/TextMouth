import Combine
import XCTest
@testable import TextMouth

/// Playback passes over chapters whose prepared speech has nothing to say
/// (every section skipped, or all text deleted by substitutions) exactly as
/// it passes over empty chapters. When nothing speakable remains, the book
/// ends through its end-of-book behavior without a Playing state or a
/// listening session, and Loop cannot restart a book with nothing to say.
///
/// Tests that start speech stop it before the main run loop turns, so the
/// synthesizer is never heard.
@MainActor
final class SpeakableChapterAdvanceTests: XCTestCase {

    // MARK: - Speakable text

    /// Whitespace and line breaks of every kind give the synthesizer nothing
    /// to say, including the no-break and wide spaces documents often carry.
    func testWhitespaceAndLineBreaksAloneAreNotSpeakable() {
        let silentTexts = [
            "", " ", "\n\n", "\t \r\n",
            "\u{00A0}\u{2003}\u{3000}",  // No-break, em, and ideographic spaces.
            "\u{2028}\u{2029}\u{0085}",  // Line and paragraph separators, next line.
        ]
        for text in silentTexts {
            XCTAssertFalse(ReaderViewModel.hasSpeakableText(text), text.debugDescription)
        }
    }

    /// Any other character counts, including punctuation, emoji, and
    /// non-Latin digits; a substring is judged exactly like a string.
    func testAnyOtherCharacterIsSpeakable() {
        for text in ["a", "  word  ", "\n.\n", "🎙️", "٣"] {
            XCTAssertTrue(ReaderViewModel.hasSpeakableText(text), text.debugDescription)
        }
        let sentence = "Spoken words.\n\n"
        XCTAssertTrue(ReaderViewModel.hasSpeakableText(sentence.prefix(6)))
        XCTAssertFalse(ReaderViewModel.hasSpeakableText(sentence.suffix(2)))
    }

    /// Pause marks never make blank text speakable: whitespace alone comes
    /// back unchanged, with no offset shifts, at every pause level, while
    /// text with words still gets its paragraph pause.
    func testPunctuationPausesLeaveBlankTextUnchanged() {
        let blank = " \n\n\t\n\n "
        for level in [1.0, 2, 3] {
            let result = ReaderViewModel.applyPunctuationPauses(blank, level: level)
            XCTAssertEqual(result.text, blank, "level \(level)")
            XCTAssertFalse(result.offsetMap.hasChanges, "level \(level)")
        }
        XCTAssertEqual(ReaderViewModel.applyPunctuationPauses("One\n\nTwo", level: 3).text, "One\n\n.\n\nTwo")
    }

    // MARK: - Next speakable chapter search

    /// A speakable starting chapter is found without looking further.
    func testSearchReturnsASpeakableStartingChapter() {
        var asked: [Int] = []
        let found = ReaderViewModel.nextSpeakableChapterIndex(from: 2, chapterCount: 5) { index in
            asked.append(index)
            return true
        }

        XCTAssertEqual(found, 2)
        XCTAssertEqual(asked, [2])
    }

    /// Silent chapters are passed over in order until a speakable one.
    func testSearchPassesOverSilentChapters() {
        let speakable = [false, false, false, true, true]
        var asked: [Int] = []
        let found = ReaderViewModel.nextSpeakableChapterIndex(from: 0, chapterCount: speakable.count) { index in
            asked.append(index)
            return speakable[index]
        }

        XCTAssertEqual(found, 3)
        XCTAssertEqual(asked, [0, 1, 2, 3])
    }

    /// When every remaining chapter is silent the search reports none,
    /// having asked about each remaining chapter exactly once.
    func testSearchAsksAboutEachRemainingChapterOnceThenReportsNone() {
        var asked: [Int] = []
        let found = ReaderViewModel.nextSpeakableChapterIndex(from: 1, chapterCount: 5) { index in
            asked.append(index)
            return false
        }

        XCTAssertNil(found)
        XCTAssertEqual(asked, [1, 2, 3, 4])
    }

    /// Speakable chapters before the start are never reached: the search
    /// does not wrap around to the beginning of the book.
    func testSearchNeverWrapsToEarlierChapters() {
        let speakable = [true, true, false, false]
        let found = ReaderViewModel.nextSpeakableChapterIndex(from: 2, chapterCount: speakable.count) {
            speakable[$0]
        }

        XCTAssertNil(found)
    }

    /// A negative start searches from the first chapter, and a start at or
    /// past the end (including an empty book) finds nothing without asking.
    func testSearchKeepsItsStartInsideTheBook() {
        XCTAssertEqual(ReaderViewModel.nextSpeakableChapterIndex(from: -3, chapterCount: 2) { _ in true }, 0)

        for (start, count) in [(2, 2), (7, 2), (0, 0), (-1, 0)] {
            var wasAsked = false
            let found = ReaderViewModel.nextSpeakableChapterIndex(from: start, chapterCount: count) { _ in
                wasAsked = true
                return true
            }
            XCTAssertNil(found, "start \(start) of \(count)")
            XCTAssertFalse(wasAsked, "start \(start) of \(count)")
        }
    }

    // MARK: - Speakable chapters in a reader

    /// A chapter entirely inside a skipped heading section is passed over,
    /// and the speech found is the next chapter's full text.
    func testChapterEntirelyInsideASkippedSectionIsPassedOver() throws {
        try withReader(
            chapters: [
                chapter(sections: [("Front Matter", "Copyright notice.")]),
                Chapter(title: "One", text: "The story begins."),
            ],
            skipping: ["Front Matter"]
        ) { reader in
            let speech = try XCTUnwrap(reader.nextSpeakableChapterSpeech(from: 0))

            XCTAssertEqual(speech.chapterIndex, 1)
            XCTAssertEqual(speech.text, "The story begins.")
        }
    }

    /// Skipping one of a chapter's sections leaves the rest speakable.
    func testPartlySkippedChapterStaysSpeakable() throws {
        try withReader(
            chapters: [chapter(sections: [("Prologue", "Opening words."), ("Acknowledgments", "Thanks.")])],
            skipping: ["Acknowledgments"]
        ) { reader in
            let speech = try XCTUnwrap(reader.nextSpeakableChapterSpeech(from: 0))

            XCTAssertEqual(speech.chapterIndex, 0)
            XCTAssertEqual(speech.text, "Prologue\n\nOpening words.\n\n")
        }
    }

    /// A substitution that deletes all of a chapter's text, such as
    /// removing illustration markers from a plate-only chapter, silences it.
    func testSubstitutionThatDeletesAllTextSilencesAChapter() throws {
        try withReader(
            chapters: [
                Chapter(title: "Plate", text: "[Illustration: The harbour at dawn]\n"),
                Chapter(title: "Two", text: "Words remain here."),
            ],
            substitutions: [Self.illustrationRemoval]
        ) { reader in
            let speech = try XCTUnwrap(reader.nextSpeakableChapterSpeech(from: 0))

            XCTAssertEqual(speech.chapterIndex, 1)
            XCTAssertNil(reader.nextSpeakableChapterSpeech(from: 2))
        }
    }

    /// Blank lines left in front of a skipped heading are not speakable, so
    /// the chapter counts as silent.
    func testBlankLinesBeforeASkippedSectionAreNotSpeakable() throws {
        try withReader(
            chapters: [chapterWithBlankLines(before: "Appendix", body: "Tables.")],
            skipping: ["Appendix"]
        ) { reader in
            XCTAssertEqual(reader.preparedSpeech(forChapterAt: 0)?.text, "\n\n")
            XCTAssertNil(reader.nextSpeakableChapterSpeech(from: 0))
        }
    }

    /// Heavy punctuation pauses do not turn those blank lines into a
    /// speakable pause mark, so the next chapter is still the one found.
    func testHeavyPausesLeaveASkippedChapterSilent() throws {
        try withReader(
            chapters: [
                chapterWithBlankLines(before: "Appendix", body: "Tables."),
                Chapter(title: "Index", text: "Entries follow."),
            ],
            skipping: ["Appendix"],
            punctuationPauseLevel: 3
        ) { reader in
            XCTAssertEqual(reader.preparedSpeech(forChapterAt: 0)?.text, "\n\n")
            XCTAssertEqual(reader.nextSpeakableChapterSpeech(from: 0)?.chapterIndex, 1)
        }
    }

    /// A book with no chapters has nothing to speak.
    func testEmptyBookHasNoSpeakableChapter() throws {
        try withReader(chapters: []) { reader in
            XCTAssertNil(reader.nextSpeakableChapterSpeech(from: 0))
        }
    }

    // MARK: - Starting playback

    /// A first chapter entirely inside a skipped heading section is passed
    /// over: speech starts at the top of the second chapter, and playback
    /// opens its listening session as usual.
    func testPlayStartsAfterAChapterEntirelyInsideASkippedSection() throws {
        try withReader(
            chapters: [
                chapter(sections: [("Front Matter", "Copyright notice.")]),
                Chapter(title: "One", text: "The story begins."),
            ],
            skipping: ["Front Matter"]
        ) { reader in
            reader.play()
            let startedSpeaking = reader.speechService.isSpeaking
            let openedSession = ReadingStatsService.shared.hasActiveSession
            silence(reader)

            XCTAssertTrue(startedSpeaking)
            XCTAssertTrue(openedSession)
            XCTAssertEqual(reader.currentChapterIndex, 1)
            XCTAssertEqual(reader.currentCharacterOffset, 0)
            XCTAssertEqual(reader.currentTransformation?.modifiedText, "The story begins.")
            XCTAssertNil(reader.lastAnnouncement)
        }
    }

    /// With every chapter skipped, Play ends the book through the configured
    /// Stop behavior at once. Nothing is spoken, the reader never shows
    /// Playing, no listening session starts, and the book rests at its end,
    /// as every book that stops there does (TODO P07).
    func testPlayWithEveryChapterSkippedEndsTheBookWithoutPlaying() throws {
        try withReader(
            chapters: [
                chapter(sections: [("Foreword", "Praise.")]),
                chapter(sections: [("Notes", "Citations.")]),
            ],
            skipping: ["Foreword", "Notes"]
        ) { reader in
            reader.play()
            settle()

            assertEndedWithoutPlaying(reader, announcement: "Finished: Quiet Pages")
            assertRestsAtItsEnd(reader)
            XCTAssertEqual(
                ReadingStatsService.shared.stats.finishedBooks.map(\.bookID),
                [reader.book.id.uuidString]
            )
        }
    }

    /// Continue to Next Book applies as configured: with no next book in the
    /// folder, a silent book ends with that behavior's own announcement.
    func testPlayOnASilentBookFollowsTheContinueBehavior() throws {
        try withReader(
            chapters: [chapter(sections: [("Notes", "Citations.")])],
            skipping: ["Notes"],
            endOfBook: .continueNext
        ) { reader in
            reader.play()
            settle()

            assertEndedWithoutPlaying(reader, announcement: "Finished: Quiet Pages. No more books in folder.")
        }
    }

    /// A substitution that deletes all of the book's text ends it exactly as
    /// skipping every section does.
    func testPlayEndsTheBookWhenSubstitutionsDeleteAllText() throws {
        try withReader(
            chapters: [
                Chapter(title: "Plate 1", text: "[Illustration: The harbour at dawn]"),
                Chapter(title: "Plate 2", text: "\n[Illustration]\n\n[Illustration: A map]\n"),
            ],
            substitutions: [Self.illustrationRemoval]
        ) { reader in
            reader.play()
            settle()

            assertEndedWithoutPlaying(reader, announcement: "Finished: Quiet Pages")
        }
    }

    /// Loop with nothing speakable anywhere ends in the stopped state after
    /// one pass over the book instead of restarting forever. Returning at
    /// all shows that it terminates.
    func testPlayWithLoopAndNothingSpeakableStopsAfterOnePass() throws {
        try withReader(
            chapters: [
                chapter(sections: [("Foreword", "Praise.")]),
                chapter(sections: [("Notes", "Citations.")]),
            ],
            skipping: ["Foreword", "Notes"],
            endOfBook: .loop
        ) { reader in
            reader.play()
            settle()

            assertEndedWithoutPlaying(reader, announcement: "Finished: Quiet Pages")
        }
    }

    /// When the rest of the book is silent but earlier text is not, Loop
    /// restarts and passes over the silent opening chapter to reach it.
    func testLoopRestartsAtTheFirstSpeakableChapter() throws {
        try withReader(
            chapters: [
                chapter(sections: [("Foreword", "Praise.")]),
                Chapter(title: "One", text: "The story begins."),
                chapter(sections: [("Notes", "Citations.")]),
            ],
            skipping: ["Foreword", "Notes"],
            endOfBook: .loop,
            at: ReadingPosition(chapterIndex: 2, characterOffset: 0)
        ) { reader in
            reader.play()
            let startedSpeaking = reader.speechService.isSpeaking
            silence(reader)

            XCTAssertTrue(startedSpeaking)
            XCTAssertEqual(reader.lastAnnouncement, "Restarting: Quiet Pages")
            XCTAssertEqual(reader.currentChapterIndex, 1)
            XCTAssertEqual(reader.currentTransformation?.modifiedText, "The story begins.")
        }
    }

    /// A cursor before a skipped section at the end of its chapter resumes
    /// in that chapter, at the cursor.
    func testCursorBeforeASkippedTailResumesInItsChapter() throws {
        let opening = chapter(sections: [("Opening", "First words."), ("Appendix", "Back matter.")])
        let firstWords = (opening.text as NSString).range(of: "First words.").location
        try withReader(
            chapters: [opening, Chapter(title: "Two", text: "Next chapter.")],
            skipping: ["Appendix"],
            at: ReadingPosition(chapterIndex: 0, characterOffset: firstWords)
        ) { reader in
            let start = try XCTUnwrap(reader.speechStartFromCursor())

            XCTAssertEqual(start.speech.chapterIndex, 0)
            XCTAssertEqual(start.offset, firstWords)
            XCTAssertEqual(start.speech.text, "Opening\n\nFirst words.\n\n")
        }
    }

    /// A cursor inside that skipped section has nothing left to say in its
    /// chapter, so speech resumes at the top of the next chapter.
    func testCursorInASkippedTailResumesAtTheNextChapter() throws {
        let opening = chapter(sections: [("Opening", "First words."), ("Appendix", "Back matter.")])
        let backMatter = (opening.text as NSString).range(of: "Back matter.").location
        try withReader(
            chapters: [opening, Chapter(title: "Two", text: "Next chapter.")],
            skipping: ["Appendix"],
            at: ReadingPosition(chapterIndex: 0, characterOffset: backMatter)
        ) { reader in
            let start = try XCTUnwrap(reader.speechStartFromCursor())

            XCTAssertEqual(start.speech.chapterIndex, 1)
            XCTAssertEqual(start.offset, 0)
            XCTAssertEqual(start.speech.text, "Next chapter.")
        }
    }

    /// A cursor in the last chapter's trailing blank lines has nothing left
    /// to say either, so the book ends instead of speaking blank lines.
    func testCursorInTrailingBlankLinesOfTheLastChapterEndsTheBook() throws {
        let text = "Final words.\n\n\n"
        try withReader(
            chapters: [Chapter(title: "Last", text: text)],
            at: ReadingPosition(chapterIndex: 0, characterOffset: text.utf16.count - 2)
        ) { reader in
            XCTAssertFalse(reader.speakCurrentChapter())
            settle()

            assertEndedWithoutPlaying(reader, announcement: "Finished: Quiet Pages")
        }
    }

    /// Resuming after an audio-route change restarts speech at the cursor.
    /// When the rest of the book was skipped while paused, the book ends
    /// instead, and Now Playing is not told that it is playing.
    func testResumeWithNothingLeftEndsTheBookWithoutClaimingPlayback() throws {
        try withReader(chapters: [chapter(sections: [("Only Section", "Brief text.")])]) { reader in
            reader.play()
            reader.pause()
            let pausedSpeech = reader.speechService.isPaused
            reader.toggleHeadingSkip(try XCTUnwrap(reader.headings.first))
            reader.invalidatePlaybackBackendForAudioRouteChange()

            reader.togglePlayPause()
            settle()

            XCTAssertTrue(pausedSpeech)
            assertEndedWithoutPlaying(reader, announcement: "Finished: Quiet Pages")
        }
    }

    // MARK: - Navigating while playing

    /// Navigating while playing onto silent text in another chapter ends the
    /// book, whether the move is by position, by words, or by time, and Now
    /// Playing is not told that playback continues.
    func testNavigatingWhilePlayingOntoSilentTextEndsTheBook() throws {
        let moves: [(name: String, move: (ReaderViewModel) -> Void)] = [
            ("position", { $0.navigateTo(chapterIndex: 1, characterOffset: 0) }),
            ("words", { $0.skipWords(count: 10) }),
            ("time", { $0.skipByTime(seconds: 3_600) }),
        ]
        for (name, move) in moves {
            try withReader(
                chapters: [
                    Chapter(title: "One", text: "First chapter."),
                    chapter(sections: [("Notes", "Citations.")]),
                ],
                skipping: ["Notes"]
            ) { reader in
                reader.play()
                let startedSpeaking = reader.speechService.isSpeaking
                move(reader)
                settle()

                XCTAssertTrue(startedSpeaking, name)
                XCTAssertEqual(reader.currentChapterIndex, 1, name)
                assertEndedWithoutPlaying(reader, announcement: "Finished: Quiet Pages", name)
            }
        }
    }

    // MARK: - Seeking onto silent text

    /// Speakability from an offset reads the text exactly as speech starting
    /// there would: past either end is clamped, and an offset inside a
    /// character starts at that character.
    func testSpeakableTextFromAnOffsetReadsLikeSpeechStartingThere() {
        let text = "Words 🎙️\n\n"
        let emoji = (text as NSString).range(of: "🎙️").location

        XCTAssertTrue(ReaderViewModel.hasSpeakableText(in: text, fromSpokenOffset: -4))
        XCTAssertTrue(ReaderViewModel.hasSpeakableText(in: text, fromSpokenOffset: emoji + 1))
        XCTAssertFalse(ReaderViewModel.hasSpeakableText(in: text, fromSpokenOffset: text.utf16.count - 2))
        XCTAssertFalse(ReaderViewModel.hasSpeakableText(in: text, fromSpokenOffset: text.utf16.count + 5))
    }

    /// Moving playing speech within its chapter onto a skipped section that
    /// closes the chapter, by position or by words, restarts speech at the
    /// next chapter instead of seeking to where nothing is left to say.
    func testMovingPlayingSpeechOntoASkippedClosingSectionContinuesAtTheNextChapter() throws {
        let opening = chapter(sections: [("Opening", "First words."), ("Appendix", "Back matter.")])
        let appendix = (opening.text as NSString).range(of: "Appendix").location
        let moves: [(name: String, move: (ReaderViewModel) -> Void)] = [
            ("position", { $0.navigateTo(chapterIndex: 0, characterOffset: appendix) }),
            ("words", { $0.skipWords(count: 3) }),
        ]
        for (name, move) in moves {
            try withReader(
                chapters: [opening, Chapter(title: "Two", text: "Next chapter.")],
                skipping: ["Appendix"]
            ) { reader in
                reader.play()
                move(reader)
                let continuedSpeaking = reader.speechService.isSpeaking
                silence(reader)

                XCTAssertTrue(continuedSpeaking, name)
                XCTAssertEqual(reader.currentChapterIndex, 1, name)
                XCTAssertEqual(reader.currentCharacterOffset, 0, name)
                XCTAssertEqual(reader.currentTransformation?.modifiedText, "Next chapter.", name)
            }
        }
    }

    /// With nothing speakable after that closing section, the move ends the
    /// book instead, and Now Playing is not told that playback continues.
    func testMovingPlayingSpeechOntoTheBooksSilentEndEndsTheBook() throws {
        let opening = chapter(sections: [("Opening", "First words."), ("Appendix", "Back matter.")])
        let appendix = (opening.text as NSString).range(of: "Appendix").location
        try withReader(chapters: [opening], skipping: ["Appendix"]) { reader in
            reader.play()
            reader.navigateTo(chapterIndex: 0, characterOffset: appendix)
            settle()

            assertEndedWithoutPlaying(reader, announcement: "Finished: Quiet Pages")
        }
    }

    /// A skip made while paused can land where the loaded speech has nothing
    /// left to say. Resuming then restarts from the cursor, which passes over
    /// the silent text to the next chapter.
    func testResumingAfterAPausedSkipOntoSilentTextContinuesAtTheNextChapter() throws {
        let opening = chapter(sections: [("Opening", "First words."), ("Appendix", "Back matter.")])
        let appendix = (opening.text as NSString).range(of: "Appendix").location
        try withReader(
            chapters: [opening, Chapter(title: "Two", text: "Next chapter.")],
            skipping: ["Appendix"]
        ) { reader in
            reader.play()
            reader.pause()
            reader.skipWords(count: 3)
            let skippedOntoSilence = reader.currentChapterIndex == 0 && reader.currentCharacterOffset >= appendix

            reader.togglePlayPause()
            let resumedSpeaking = reader.speechService.isSpeaking && !reader.speechService.isPaused
            silence(reader)

            XCTAssertTrue(skippedOntoSilence)
            XCTAssertTrue(resumedSpeaking)
            XCTAssertEqual(reader.currentChapterIndex, 1)
            XCTAssertEqual(reader.currentTransformation?.modifiedText, "Next chapter.")
        }
    }

    // MARK: - Chapter ends and look-ahead

    /// A book with one speakable chapter among skipped ones plays only that
    /// chapter: speech starts there, nothing is chosen to look ahead to, and
    /// when it finishes the book ends without playing a skipped chapter. The
    /// cursor then rests at the book's end, past the skipped chapter that
    /// closes it, where every book that stops there rests (TODO P07).
    func testOnlySpeakableChapterAmongSkippedOnesPlaysAlone() throws {
        try withReader(
            chapters: [
                chapter(sections: [("Foreword", "Praise.")]),
                chapter(sections: [("Preface", "Background.")]),
                Chapter(title: "One", text: "The only story."),
                chapter(sections: [("Notes", "Citations.")]),
            ],
            skipping: ["Foreword", "Preface", "Notes"]
        ) { reader in
            var visitedChapters: [Int] = []
            let visits = reader.$currentChapterIndex.sink { visitedChapters.append($0) }
            defer { visits.cancel() }

            reader.play()
            let spokenText = reader.currentTransformation?.modifiedText
            let lookAhead = reader.lookAhead?.chapterIndex
            finishChapter(reader)
            settle()

            XCTAssertEqual(spokenText, "The only story.")
            XCTAssertNil(lookAhead)
            // Speech visited the speakable chapter alone; the last chapter
            // is where the finished book rests.
            XCTAssertEqual(visitedChapters, [0, 2, 3])
            assertRestsAtItsEnd(reader)
            XCTAssertEqual(reader.lastAnnouncement, "Finished: Quiet Pages")
            XCTAssertFalse(reader.speechService.isSpeaking)
            XCTAssertFalse(reader.isCurrentlyPlaying)
            XCTAssertFalse(ReadingStatsService.shared.hasActiveSession)
        }
    }

    /// When a chapter finishes, a fully skipped next chapter is passed over
    /// exactly like an empty one: the look-ahead already chose the chapter
    /// after it, and speech continues there.
    func testFinishedChapterPassesOverAFullySkippedNextChapter() throws {
        try withReader(
            chapters: [
                Chapter(title: "One", text: "First chapter."),
                chapter(sections: [("Interlude", "Short scene.")]),
                Chapter(title: "Three", text: "Third chapter."),
            ],
            skipping: ["Interlude"]
        ) { reader in
            var visitedChapters: [Int] = []
            let visits = reader.$currentChapterIndex.sink { visitedChapters.append($0) }
            defer { visits.cancel() }

            reader.play()
            let lookAhead = reader.lookAhead?.chapterIndex
            finishChapter(reader)
            let continuedSpeaking = reader.speechService.isSpeaking
            silence(reader)

            XCTAssertEqual(lookAhead, 2)
            XCTAssertTrue(continuedSpeaking)
            XCTAssertEqual(visitedChapters, [0, 2])
            XCTAssertEqual(reader.currentChapterIndex, 2)
            XCTAssertEqual(reader.currentTransformation?.modifiedText, "Third chapter.")
        }
    }

    /// A look-ahead chosen before a section was skipped is forgotten when the
    /// next one is chosen: its engine is dropped instead of being paired
    /// with the new chapter, and the new choice passes over the now-silent
    /// chapter.
    func testLookAheadForgetsAnEngineChosenBeforeASkip() throws {
        try withReader(
            chapters: [
                Chapter(title: "One", text: "First chapter."),
                chapter(sections: [("Interlude", "Short scene.")]),
                Chapter(title: "Three", text: "Third chapter."),
            ]
        ) { reader in
            let earlierEngine = AudioEngineService()
            reader.lookAhead = ReaderViewModel.LookAhead(
                chapterIndex: 1,
                signature: try XCTUnwrap(reader.currentRenderSignature(forChapterAt: 1)),
                engine: earlierEngine
            )
            reader.toggleHeadingSkip(try XCTUnwrap(reader.headings.first))

            reader.preRenderNextChapter()
            // Keep the newly queued render from starting.
            reader.chapterPlaybackGeneration += 1

            XCTAssertFalse(reader.lookAhead?.engine === earlierEngine)
            XCTAssertEqual(reader.lookAhead?.chapterIndex, 2)
        }
    }

    /// With nothing speakable after the current chapter, no look-ahead is
    /// kept at all.
    func testLookAheadIsClearedWhenNothingSpeakableFollows() throws {
        try withReader(
            chapters: [
                Chapter(title: "One", text: "First chapter."),
                chapter(sections: [("Notes", "Citations.")]),
            ],
            skipping: ["Notes"]
        ) { reader in
            reader.lookAhead = ReaderViewModel.LookAhead(
                chapterIndex: 1,
                signature: try XCTUnwrap(reader.currentRenderSignature(forChapterAt: 1)),
                engine: AudioEngineService()
            )

            reader.preRenderNextChapter()

            XCTAssertNil(reader.lookAhead)
        }
    }

    /// A finished look-ahead render is kept only for the chapter that is
    /// still chosen, in the playback generation the render started in.
    func testLookAheadRenderIsKeptOnlyForTheChosenChapterInItsGeneration() {
        XCTAssertTrue(ReaderViewModel.isCurrentLookAhead(
            capturedGeneration: 4, currentGeneration: 4, renderedChapterIndex: 2, chosenChapterIndex: 2
        ))
        // Navigation has moved playback on.
        XCTAssertFalse(ReaderViewModel.isCurrentLookAhead(
            capturedGeneration: 4, currentGeneration: 5, renderedChapterIndex: 2, chosenChapterIndex: 2
        ))
        // A newer look-ahead chose another chapter, or found none.
        XCTAssertFalse(ReaderViewModel.isCurrentLookAhead(
            capturedGeneration: 4, currentGeneration: 4, renderedChapterIndex: 2, chosenChapterIndex: 3
        ))
        XCTAssertFalse(ReaderViewModel.isCurrentLookAhead(
            capturedGeneration: 4, currentGeneration: 4, renderedChapterIndex: 2, chosenChapterIndex: nil
        ))
    }

    // MARK: - End of book

    /// Reaching the end closes this book's listening session, and only this
    /// book's: a session that another window owns keeps running.
    func testEndOfBookClosesOnlyThisBooksListeningSession() throws {
        try withReader(chapters: [Chapter(title: "One", text: "Words.")]) { reader in
            let statistics = ReadingStatsService.shared
            statistics.startSession(bookID: reader.book.id)

            reader.handleEndOfBook()

            XCTAssertFalse(statistics.hasActiveSession)

            statistics.startSession(bookID: UUID())

            reader.handleEndOfBook()

            XCTAssertTrue(statistics.hasActiveSession)
        }
    }

    /// Looping a book with nothing speakable anywhere would end it again at
    /// once, forever. It stops instead, exactly as the Stop behavior does,
    /// resting at its end (TODO P07).
    func testLoopWithNothingSpeakableStopsInsteadOfRestarting() throws {
        try withReader(
            chapters: [
                chapter(sections: [("Foreword", "Praise.")]),
                chapter(sections: [("Notes", "Citations.")]),
            ],
            skipping: ["Foreword", "Notes"],
            endOfBook: .loop,
            at: ReadingPosition(chapterIndex: 1, characterOffset: 3)
        ) { reader in
            reader.handleEndOfBook()

            XCTAssertEqual(reader.lastAnnouncement, "Finished: Quiet Pages")
            assertRestsAtItsEnd(reader)
            XCTAssertFalse(reader.speechService.isSpeaking)
            XCTAssertFalse(reader.isCurrentlyPlaying)
            XCTAssertFalse(ReadingStatsService.shared.hasActiveSession)
            XCTAssertEqual(
                ReadingStatsService.shared.stats.finishedBooks.map(\.bookID),
                [reader.book.id.uuidString]
            )
        }
    }

    /// A book whose last section is skipped, as a Project Gutenberg book's
    /// licence often is, ends where speech has nothing left to say, and
    /// rests exactly at its end, past the skipped section (TODO P07): its
    /// row reads 100 percent. It once rested at its last spoken word,
    /// 90 percent through alice.epub with its licence skipped.
    func testABookWhoseLastSectionIsSkippedRestsAtItsEndPastIt() throws {
        let story = Chapter(title: "One", text: "The story ends here.")
        try withReader(
            chapters: [story, chapter(sections: [("Licence", "The terms of use, at length.")])],
            skipping: ["Licence"],
            at: ReadingPosition(chapterIndex: 0, characterOffset: story.text.utf16.count)
        ) { reader in
            reader.play()
            settle()

            assertEndedWithoutPlaying(reader, announcement: "Finished: Quiet Pages")
            assertRestsAtItsEnd(reader)
        }
    }

    /// The last chapter spoken to its end leaves the book exactly at its
    /// end (TODO P07), not at the last word speech reported, where the
    /// cursor stood as speech finished: 4 to 9 characters short of the end
    /// in every fixture the design note measured.
    func testALastChapterSpokenToItsEndRestsAtTheBooksEnd() throws {
        let text = "These are the final words."
        try withReader(chapters: [Chapter(title: "Last", text: text)]) { reader in
            reader.play()
            // Speech reports the last word as it speaks it.
            reader.currentCharacterOffset = (text as NSString).range(of: "words.").location
            finishChapter(reader)
            settle()

            XCTAssertEqual(reader.lastAnnouncement, "Finished: Quiet Pages")
            assertRestsAtItsEnd(reader)
        }
    }

    /// With "Stop, and Play Starts Over", Play on a finished book starts it
    /// over (TODO P07): it says "Starting again: <title>", and speaks from
    /// the first chapter with anything to say, past a silent cover, as Play
    /// does from the beginning.
    func testPlayStartsAFinishedBookOverFromItsFirstChapterWithWords() throws {
        let story = Chapter(title: "One", text: "The story begins.")
        try withReader(
            chapters: [chapter(sections: [("Cover", "Cover image.")]), story],
            skipping: ["Cover"],
            endOfBook: .stopAndPlayStartsOver,
            at: ReadingPosition(chapterIndex: 1, characterOffset: story.text.utf16.count)
        ) { reader in
            XCTAssertTrue(reader.cursorRestsAtEnd, "The book does not rest at its end")
            reader.play()
            let startedSpeaking = reader.speechService.isSpeaking
            silence(reader)

            XCTAssertTrue(startedSpeaking, "Play did not start the book over")
            XCTAssertEqual(reader.lastAnnouncement, "Starting again: Quiet Pages")
            XCTAssertEqual(reader.currentChapterIndex, 1)
            XCTAssertEqual(reader.currentCharacterOffset, 0)
            XCTAssertEqual(reader.currentTransformation?.modifiedText, "The story begins.")
        }
    }

    /// With anything speakable, looping still restarts from the beginning.
    func testLoopRestartsFromTheBeginningWhenAnythingIsSpeakable() throws {
        try withReader(
            chapters: [
                Chapter(title: "One", text: "Opening chapter."),
                chapter(sections: [("Notes", "Citations.")]),
            ],
            skipping: ["Notes"],
            endOfBook: .loop,
            at: ReadingPosition(chapterIndex: 1, characterOffset: 0)
        ) { reader in
            reader.handleEndOfBook()
            let startedSpeaking = reader.speechService.isSpeaking
            silence(reader)

            XCTAssertTrue(startedSpeaking)
            XCTAssertEqual(reader.lastAnnouncement, "Restarting: Quiet Pages")
            XCTAssertEqual(reader.currentChapterIndex, 0)
            XCTAssertEqual(reader.currentTransformation?.modifiedText, "Opening chapter.")
        }
    }

    // MARK: - Fixtures

    /// Deletes every illustration marker, the kind of rule a listener adds
    /// for scanned books whose plates are captioned in brackets.
    private static let illustrationRemoval = SubstitutionRule(
        name: "Illustrations",
        pattern: "\\[Illustration[^\\]]*\\]",
        replacement: "",
        isRegex: true
    )

    /// A chapter made of sections that each start with a level-one heading.
    /// Heading offsets are measured from the assembled text, so a fixture's
    /// headings always sit exactly where its text says they do.
    private func chapter(sections: [(heading: String, body: String)]) -> Chapter {
        var text = ""
        var headings: [Heading] = []
        for section in sections {
            if !text.isEmpty { text += "\n\n" }
            headings.append(Heading(level: 1, text: section.heading, characterOffset: text.utf16.count))
            text += "\(section.heading)\n\n\(section.body)"
        }
        return Chapter(title: sections.first?.heading ?? "", text: text, headings: headings)
    }

    /// Stop the reader's speech before the main run loop turns, so a test
    /// that starts speech is never audible. Advancing the playback
    /// generation also keeps a queued look-ahead render from starting.
    /// Record anything the test checks about the speech first.
    private func silence(_ reader: ReaderViewModel) {
        reader.stop()
        reader.chapterPlaybackGeneration += 1
    }

    /// Finish the chapter being spoken the way the speech service does when
    /// an utterance ends: speech stops, then completion is reported.
    /// Stopping first also keeps the test from ever being audible.
    private func finishChapter(_ reader: ReaderViewModel) {
        reader.speechService.stop()
        reader.speechService.onUtteranceFinished?()
    }

    /// Let queued main-queue work run. The reader mirrors the speech
    /// service's playing state asynchronously, so a Playing state that was
    /// wrongly set would only show after this.
    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    /// Check that the book ended with `announcement` without ever playing:
    /// nothing is speaking, the reader shows neither Playing nor Paused, no
    /// listening session is open or recorded, and Now Playing does not list
    /// this reader as playing. `context` names the case in failure messages.
    private func assertEndedWithoutPlaying(
        _ reader: ReaderViewModel,
        announcement: String,
        _ context: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let statistics = ReadingStatsService.shared
        XCTAssertEqual(reader.lastAnnouncement, announcement, context, file: file, line: line)
        XCTAssertFalse(reader.speechService.isSpeaking, "\(context) speaking", file: file, line: line)
        XCTAssertFalse(reader.isCurrentlyPlaying, "\(context) Playing state", file: file, line: line)
        XCTAssertFalse(reader.isCurrentlyPaused, "\(context) Paused state", file: file, line: line)
        XCTAssertFalse(statistics.hasActiveSession, "\(context) open listening session", file: file, line: line)
        XCTAssertEqual(
            statistics.stats.totalListeningSeconds, 0, "\(context) recorded listening", file: file, line: line
        )
        XCTAssertNotEqual(
            NowPlayingService.shared.playingOwnerID,
            reader.nowPlayingService.ownerID,
            "\(context) Now Playing claimed",
            file: file,
            line: line
        )
    }

    /// Check that `reader`'s book rests exactly at its end (TODO P07): the
    /// cursor at its last chapter's full length, which the reader itself
    /// reads as the end, and the library row saved there, with the book's
    /// total as its global offset, which the row reads as finished and 100
    /// percent once the book is measured, as the library measures every
    /// book.
    private func assertRestsAtItsEnd(
        _ reader: ReaderViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let end = reader.endOfBookPlace, let content = reader.content else {
            XCTFail("The reader holds no book", file: file, line: line)
            return
        }
        XCTAssertEqual(reader.currentChapterIndex, end.chapterIndex, "The cursor is in another chapter", file: file, line: line)
        XCTAssertEqual(reader.currentCharacterOffset, end.characterOffset, "The cursor is short of the end", file: file, line: line)
        XCTAssertTrue(reader.cursorRestsAtEnd, "The reader does not read its cursor as the end", file: file, line: line)
        var row = reader.libraryViewModel.bookByID(reader.book.id)
        let saved = row?.readingPosition
        XCTAssertEqual(saved?.chapterIndex, end.chapterIndex, "The row is saved in another chapter", file: file, line: line)
        XCTAssertEqual(saved?.characterOffset, end.characterOffset, "The row is saved short of the end", file: file, line: line)
        XCTAssertEqual(saved?.globalCharacterOffset, content.totalCharacterCount, "The row's place is not the book's end", file: file, line: line)
        row?.totalCharacterCount = content.totalCharacterCount
        XCTAssertEqual(row?.restsAtEnd, true, "The measured row is not finished", file: file, line: line)
        XCTAssertEqual(row?.percentComplete, 100, "The measured row does not read 100 percent", file: file, line: line)
    }

    /// A chapter whose only section follows two blank lines, as converted
    /// documents often begin; skipping the section leaves just those lines.
    private func chapterWithBlankLines(before heading: String, body: String) -> Chapter {
        Chapter(
            title: heading,
            text: "\n\n\(heading)\n\n\(body)",
            headings: [Heading(level: 1, text: heading, characterOffset: 2)]
        )
    }

    /// Run `body` with a loaded, in-memory text reader over `chapters`, then
    /// close it and put back everything the reader could have changed.
    ///
    /// Preferences live in a private suite, written before the settings
    /// model reads them, so neither the user's settings nor the shared
    /// config file are touched. Substitution rules are the reader's own.
    /// Listening statistics are process-wide, so each run starts from empty
    /// statistics with no open session and restores the user's afterwards.
    ///
    /// - Parameters:
    ///   - chapters: The book's chapters, in reading order.
    ///   - skippedHeadings: Text of every heading whose section is skipped.
    ///   - endOfBook: The global end-of-book behavior.
    ///   - punctuationPauseLevel: The global punctuation pause level.
    ///   - substitutions: The reader's text substitution rules.
    ///   - position: The saved reading position the reader opens at.
    private func withReader(
        chapters: [Chapter],
        skipping skippedHeadings: Set<String> = [],
        endOfBook: EndOfBookBehavior = .stop,
        punctuationPauseLevel: Double = 0,
        substitutions: [SubstitutionRule] = [],
        at position: ReadingPosition? = nil,
        _ body: (ReaderViewModel) throws -> Void
    ) throws {
        let defaults = makeSandboxedPreferences("speakable-chapters")
        defaults.set(endOfBook.rawValue, forKey: SettingsPolicy.endOfBookBehavior.key)
        defaults.set(punctuationPauseLevel, forKey: SettingsPolicy.punctuationPauseLevel.key)
        let settings = SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false,
            userDefaults: defaults
        )

        let content = DocumentContent(title: "Quiet Pages", author: "Test Author", chapters: chapters)
        // A unique missing path keeps the reader's own loader from replacing
        // this content or sharing persisted state with another fixture.
        var book = Book(
            title: "Quiet Pages",
            format: .txt,
            filePath: "/tmp/\(UUID().uuidString)-quiet-pages.txt",
            md5Hash: UUID().uuidString,
            readingPosition: position
        )
        book.skippedHeadingIDs = content.allHeadings
            .filter { skippedHeadings.contains($0.text) }
            .map(\.id)
        let library = LibraryViewModel()
        library.library = Library(books: [book])

        let statistics = ReadingStatsService.shared
        let savedStatistics = statistics.stats
        statistics.endSession()
        statistics.stats = ReadingStats()

        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: library,
            settingsViewModel: settings,
            substitutionService: TextSubstitutionService(rules: substitutions)
        )
        reader.content = content
        reader.isLoading = false
        defer {
            reader.close()
            statistics.endSession()
            statistics.stats = savedStatistics
            statistics.save()
        }
        try body(reader)
    }
}
