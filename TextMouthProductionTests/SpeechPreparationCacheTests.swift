import AVFoundation
import Foundation
import XCTest
@testable import TextMouth

/// A reader prepares each chapter's speech once while everything it is
/// prepared from stays the same, carries the look-ahead's speech to the
/// chapter's end, prepares a long chapter for the look-ahead off the main
/// actor, and refreshes the look-ahead for another voice only (PERF02). It
/// prepares the chapter a book opens at off the main actor too, and Play
/// waits for that preparation when the chapter is long.
///
/// The oracle (`legacyPreparedSpeech`) is the pipeline as it was before,
/// with nothing kept: whatever was changed, and in whatever order, what the
/// reader hands the speech engine is exactly what that pipeline makes from
/// the settings in force.
///
/// Look-ahead renders wait in a stand-in queue, and speech a test starts is
/// stopped before the main run loop turns, so nothing is heard. A test of
/// Play waiting for a preparation hands the preparation's result over
/// itself (`finishPreparingInBackground(_:)`), so speech starts only then.
@MainActor
final class SpeechPreparationCacheTests: XCTestCase {

    // MARK: - Kept while the inputs stay the same

    /// A chapter asked for again with nothing changed is not prepared again,
    /// and is the same speech.
    func testAChapterIsPreparedOnceWhileItsInputsStayTheSame() throws {
        try withReader { reader, _ in
            let first = try XCTUnwrap(reader.preparedSpeech(forChapterAt: 1))
            let misses = reader.chapterSpeechCache.misses

            let second = try XCTUnwrap(reader.preparedSpeech(forChapterAt: 1))

            XCTAssertEqual(reader.chapterSpeechCache.misses, misses)
            assertSameSpeech(second, first)
        }
    }

    /// Every change to what a chapter is prepared from prepares it again,
    /// and the new speech is exactly what the old pipeline makes: the pause
    /// level, each kind of substitution change, each repeated-symbol
    /// setting, a section skipped in the chapter, and a new text, even one
    /// Swift calls equal because it spells an accent another way.
    func testEveryChangeToWhatAChapterIsPreparedFromPreparesItAgain() throws {
        let changes: [(name: String, change: (ReaderViewModel) throws -> Void)] = [
            ("pause level", { $0.settingsViewModel.punctuationPauseLevel = 2 }),
            ("rule added", { $0.substitutionService.rules.append(Self.seabirdsForGulls) }),
            ("rule edited", { reader in
                _ = try XCTUnwrap(reader.substitutionService.rules[safe: 0], "the service has no first rule")
                reader.substitutionService.rules[0].replacement = "port"
            }),
            ("rule switched off", { reader in
                _ = try XCTUnwrap(reader.substitutionService.rules[safe: 0], "the service has no first rule")
                reader.substitutionService.rules[0].isEnabled = false
            }),
            ("rules reordered", { reader in
                _ = try XCTUnwrap(reader.substitutionService.rules[safe: 1], "the service has no second rule")
                reader.substitutionService.rules.swapAt(0, 1)
            }),
            ("substitutions off", { $0.substitutionService.isEnabled = false }),
            ("symbol style", { $0.substitutionService.repeatedSymbolStyle = .leaveOut }),
            ("symbol threshold", { $0.substitutionService.repeatedSymbolThreshold = -1 }),
            ("symbol set", { $0.substitutionService.repeatedSymbolSet = "-=" }),
            ("section skipped", { reader in
                reader.toggleHeadingSkip(try XCTUnwrap(reader.headings.first { $0.text == "Market" }))
            }),
            ("text replaced", { reader in
                reader.content = Self.content(replacingInChapterOne: "nine", with: "ten")
            }),
            ("accent respelled", { reader in
                reader.content = Self.content(replacingInChapterOne: "Caf\u{00E9}", with: "Cafe\u{0301}")
            }),
        ]
        for (name, change) in changes {
            try withReader(substitutions: [Self.harbourSpelling, Self.quayToPier]) { reader, _ in
                _ = try XCTUnwrap(reader.preparedSpeech(forChapterAt: 1), name)
                let misses = reader.chapterSpeechCache.misses

                try change(reader)
                let after = try XCTUnwrap(reader.preparedSpeech(forChapterAt: 1), name)

                XCTAssertEqual(reader.chapterSpeechCache.misses, misses + 1, "\(name): not prepared again")
                assertSameSpeech(after, try legacyPreparedSpeech(reader, chapterIndex: 1), name)
            }
        }
    }

    /// Changes that leave a chapter's inputs alone keep its speech: a
    /// section skipped in another chapter, another voice, which shapes the
    /// rendered audio and not the speech, and new speed and pitch.
    func testChangesThatLeaveAChaptersInputsAloneKeepItsSpeech() throws {
        try withReader(substitutions: [Self.harbourSpelling]) { reader, _ in
            _ = try XCTUnwrap(reader.preparedSpeech(forChapterAt: 1))
            let misses = reader.chapterSpeechCache.misses

            reader.toggleHeadingSkip(try XCTUnwrap(reader.headings.first { $0.text == "Crossing" }))
            reader.speechService.currentVoice = nil
            reader.adjustSpeed(delta: 25)
            reader.adjustPitch(to: 1.4)
            let after = try XCTUnwrap(reader.preparedSpeech(forChapterAt: 1))

            XCTAssertEqual(reader.chapterSpeechCache.misses, misses)
            assertSameSpeech(after, try legacyPreparedSpeech(reader, chapterIndex: 1))
        }
    }

    /// However settings change, and in whatever order chapters are asked
    /// for, a chapter's speech is exactly what the old pipeline makes from
    /// the settings in force: nothing stale is ever handed out.
    func testRandomChangesNeverHandOutStaleSpeech() throws {
        try withReader(substitutions: [Self.harbourSpelling, Self.quayToPier]) { reader, _ in
            var random = BenchmarkProse(seed: 0xCAC4E)
            let changes: [(ReaderViewModel) throws -> Void] = [
                { $0.settingsViewModel.punctuationPauseLevel = $0.settingsViewModel.punctuationPauseLevel == 3 ? 0 : 3 },
                { $0.substitutionService.isEnabled.toggle() },
                { reader in
                    _ = try XCTUnwrap(reader.substitutionService.rules[safe: 0], "the service has no first rule")
                    reader.substitutionService.rules[0].isEnabled.toggle()
                },
                { reader in
                    _ = try XCTUnwrap(reader.substitutionService.rules[safe: 1], "the service has no second rule")
                    reader.substitutionService.rules.swapAt(0, 1)
                },
                { $0.substitutionService.repeatedSymbolStyle = $0.substitutionService.repeatedSymbolStyle == .sayCount ? .leaveOut : .sayCount },
                { $0.substitutionService.repeatedSymbolThreshold = $0.substitutionService.repeatedSymbolThreshold == 4 ? 9 : 4 },
                { reader in reader.toggleHeadingSkip(try XCTUnwrap(reader.headings.first { $0.text == "Market" })) },
                { reader in reader.toggleHeadingSkip(try XCTUnwrap(reader.headings.first { $0.text == "Departure" })) },
                { $0.speechService.currentVoice = nil },
                { _ in },
            ]
            for step in 0..<150 {
                try changes[random.roll(changes.count)](reader)
                let chapterIndex = random.roll(Self.chapters.count)

                let speech = try XCTUnwrap(reader.preparedSpeech(forChapterAt: chapterIndex), "step \(step)")

                assertSameSpeech(speech, try legacyPreparedSpeech(reader, chapterIndex: chapterIndex), "step \(step)")
            }
            XCTAssertGreaterThan(reader.chapterSpeechCache.misses, 20, "the changes should have prepared chapters again")
        }
    }

    // MARK: - The look-ahead's speech

    /// The chapter's end takes the speech the look-ahead chose without
    /// preparing it again, even when more chapters than the cache keeps were
    /// prepared meanwhile; only the chapter after it is prepared, for the
    /// next look-ahead.
    func testTheChapterEndUsesTheLookAheadsSpeech() throws {
        var chapters = Self.chapters
        for number in 4...9 {
            chapters.append(Chapter(title: "Part \(number)", text: "Notes for part \(number)."))
        }
        try withReader(chapters: chapters) { reader, _ in
            reader.speechService.isSpeaking = true
            reader.preRenderNextChapter()
            let carried = try XCTUnwrap(reader.chapterSpeechCache.lookAheadSpeech)
            for chapterIndex in 3..<chapters.count {
                _ = reader.preparedSpeech(forChapterAt: chapterIndex)
            }
            let misses = reader.chapterSpeechCache.misses

            reader.speechService.stop()
            reader.speechService.onUtteranceFinished?()
            let started = reader.currentTransformation?.modifiedText
            let chapter = reader.currentChapterIndex
            silence(reader)

            XCTAssertEqual(chapter, 1)
            XCTAssertEqual(carried.chapterIndex, 1)
            XCTAssertTrue(haveIdenticalBytes(try XCTUnwrap(started), carried.text))
            XCTAssertEqual(reader.chapterSpeechCache.misses, misses + 1, "only the chapter after it is prepared")
        }
    }

    /// A speed or pitch step in Settings, which every playing reader hears,
    /// prepares nothing and keeps the look-ahead rendering in the voice in
    /// effect; another voice renders the next chapter again.
    func testOnlyAnotherVoiceRefreshesTheLookAhead() throws {
        try withReader { reader, renders in
            reader.speechService.isSpeaking = true
            reader.preRenderNextChapter()
            let misses = reader.chapterSpeechCache.misses

            reader.notificationCenter.post(name: .speechSettingsChanged, object: nil)
            reader.applyLocalSpeechOverrides()

            XCTAssertEqual(reader.chapterSpeechCache.misses, misses)
            XCTAssertEqual(renders.requested.count, 1)

            reader.speechService.currentVoice = nil
            reader.notificationCenter.post(name: .speechSettingsChanged, object: nil)

            XCTAssertEqual(renders.requested.count, 2, "another voice renders the next chapter again")
            XCTAssertEqual(reader.chapterSpeechCache.misses, misses, "the speech is the same in any voice")
            XCTAssertNil(renders.requested.last?.request.voice)
            silence(reader)
        }
    }

    // MARK: - Long chapters

    /// The look-ahead leaves a chapter too long to render ahead to be
    /// prepared off the main actor: nothing is prepared before it returns.
    /// Once the speech is ready it is carried to the chapter's start, and is
    /// never rendered ahead, since it is too long.
    func testALongChapterIsPreparedOffTheMainActor() throws {
        var prose = BenchmarkProse(seed: 29)
        let long = Chapter(title: "Long", text: prose.text(utf16Length: SpeechRenderCoordinator.maximumTextLength + 20_000))
        try withReader(chapters: [Self.chapters[0], long, Self.chapters[2]]) { reader, renders in
            reader.speechService.isSpeaking = true
            let inputs = try XCTUnwrap(reader.speechInputs(forChapterAt: 1))

            reader.preRenderNextChapter()

            XCTAssertTrue(reader.chapterSpeechCache.isPreparingInBackground(inputs))
            XCTAssertNil(reader.chapterSpeechCache.lookAheadSpeech)
            XCTAssertTrue(
                waitUntil(timeout: Self.backgroundPreparationTimeout) { reader.chapterSpeechCache.lookAheadSpeech != nil },
                "the speech never arrived"
            )
            let carried = try XCTUnwrap(reader.chapterSpeechCache.lookAheadSpeech)
            XCTAssertFalse(reader.chapterSpeechCache.isPreparingInBackground(inputs))
            XCTAssertEqual(carried.chapterIndex, 1)
            assertSameSpeech(carried, try legacyPreparedSpeech(reader, chapterIndex: 1))
            XCTAssertTrue(renders.requested.isEmpty, "a chapter this long is never rendered ahead")
            silence(reader)
        }
    }

    /// A long chapter whose speech fits the render limit, because most of it
    /// is skipped, is rendered ahead once it has been prepared.
    func testALongChapterThatSpeaksShortIsRenderedAheadOnceReady() throws {
        var prose = BenchmarkProse(seed: 31)
        let skipped = prose.text(utf16Length: SpeechRenderCoordinator.maximumTextLength + 20_000)
        let long = Self.chapter(sections: [("Opening", "Gulls circled the harbour wall."), ("Appendix", skipped)])
        try withReader(chapters: [Self.chapters[0], long, Self.chapters[2]], skipping: ["Appendix"]) { reader, renders in
            reader.speechService.isSpeaking = true

            reader.preRenderNextChapter()

            XCTAssertTrue(renders.requested.isEmpty, "not rendered before it is prepared")
            XCTAssertTrue(
                waitUntil(timeout: Self.backgroundPreparationTimeout) { !renders.requested.isEmpty },
                "never rendered ahead"
            )
            XCTAssertEqual(reader.lookAhead?.chapterIndex, 1)
            XCTAssertEqual(renders.requested.first?.request.signature, reader.currentRenderSignature(forChapterAt: 1))
            silence(reader)
        }
    }

    /// Speech prepared in the background from settings that changed while it
    /// was being prepared is not kept, and the look-ahead waits for the
    /// preparation from the settings in force.
    func testALongChapterPreparedFromChangedSettingsIsNotKept() throws {
        var prose = BenchmarkProse(seed: 37)
        let long = Chapter(title: "Long", text: prose.text(utf16Length: SpeechRenderCoordinator.maximumTextLength + 20_000))
        try withReader(chapters: [Self.chapters[0], long, Self.chapters[2]]) { reader, _ in
            reader.speechService.isSpeaking = true
            reader.preRenderNextChapter()

            reader.settingsViewModel.punctuationPauseLevel = 3
            reader.refreshLookAhead()

            XCTAssertTrue(waitUntil(timeout: Self.backgroundPreparationTimeout) {
                reader.chapterSpeechCache.lookAheadSpeech?.inputs.punctuationPauseLevel == 3
            }, "the speech from the settings in force never arrived")
            let carried = try XCTUnwrap(reader.chapterSpeechCache.lookAheadSpeech)
            assertSameSpeech(carried, try legacyPreparedSpeech(reader, chapterIndex: 1))
            silence(reader)
        }
    }

    // MARK: - The chapter a book opens at

    /// A book that has loaded has the speech of the chapter it opened at
    /// prepared off the main actor, and Play finds it kept: finding where
    /// speech starts from the cursor, the first thing Play does, prepares
    /// nothing on the main thread, even for a chapter too long to render.
    func testTheOpenedChapterIsPreparedOffTheMainActorForPlay() throws {
        var prose = BenchmarkProse(seed: 47)
        let long = Chapter(title: "Long", text: prose.text(utf16Length: SpeechRenderCoordinator.maximumTextLength + 20_000))
        try withReader(chapters: [Self.chapters[0], long, Self.chapters[2]], substitutions: [Self.harbourSpelling]) { reader, _ in
            let inputs = try XCTUnwrap(reader.speechInputs(forChapterAt: 1))

            try showLoaded(reader, atChapter: 1)

            XCTAssertTrue(reader.chapterSpeechCache.isPreparingInBackground(inputs), "prepared off the main actor")
            XCTAssertEqual(reader.chapterSpeechCache.misses, 0, "nothing prepared on the main thread yet")
            XCTAssertTrue(
                waitUntil(timeout: Self.backgroundPreparationTimeout) { !reader.chapterSpeechCache.isPreparingInBackground(inputs) },
                "the speech never arrived"
            )

            let start = try XCTUnwrap(reader.speechStartFromCursor())

            XCTAssertEqual(reader.chapterSpeechCache.misses, 0, "Play prepared the chapter on the main thread")
            XCTAssertEqual(start.offset, 0)
            assertSameSpeech(start.speech, try legacyPreparedSpeech(reader, chapterIndex: 1))
        }
    }

    /// A change to what the opened chapter is prepared from before Play,
    /// once its speech is ready or while it is still being prepared, is
    /// never missed: Play prepares the chapter from the settings in force,
    /// exactly as the old pipeline makes it, and speech prepared from the
    /// settings before the change is not kept.
    func testAChangeBeforePlayPreparesTheOpenedChapterFromTheSettingsInForce() throws {
        let changes: [(name: String, change: (ReaderViewModel) throws -> Void)] = [
            ("rule added", { $0.substitutionService.rules.append(Self.seabirdsForGulls) }),
            ("substitutions off", { $0.substitutionService.isEnabled = false }),
            ("symbol style", { $0.substitutionService.repeatedSymbolStyle = .leaveOut }),
            ("pause level", { $0.settingsViewModel.punctuationPauseLevel = 2 }),
            ("section skipped", { reader in
                reader.toggleHeadingSkip(try XCTUnwrap(reader.headings.first { $0.text == "Market" }))
            }),
        ]
        for (name, change) in changes {
            for whilePreparing in [false, true] {
                let label = "\(name)\(whilePreparing ? ", while preparing" : "")"
                try withReader(substitutions: [Self.harbourSpelling]) { reader, _ in
                    let opened = try XCTUnwrap(reader.speechInputs(forChapterAt: 1), label)
                    try showLoaded(reader, atChapter: 1)
                    if !whilePreparing {
                        XCTAssertTrue(waitUntil(timeout: Self.backgroundPreparationTimeout) {
                            !reader.chapterSpeechCache.isPreparingInBackground(opened)
                        }, "\(label): the speech never arrived")
                    }

                    try change(reader)
                    XCTAssertTrue(waitUntil(timeout: Self.backgroundPreparationTimeout) {
                        !reader.chapterSpeechCache.isPreparingInBackground(opened)
                    }, "\(label): the speech never arrived")
                    let start = try XCTUnwrap(reader.speechStartFromCursor(), label)

                    XCTAssertEqual(reader.chapterSpeechCache.misses, 1, "\(label): not prepared from the settings in force")
                    assertSameSpeech(start.speech, try legacyPreparedSpeech(reader, chapterIndex: 1), label)
                }
            }
        }
    }

    /// A book that opens at a chapter without words, as an EPUB opens at its
    /// cover page, has the speech of the next chapter with words prepared
    /// instead, since Play passes on to it: at Play only the empty chapter,
    /// which takes no time, is prepared.
    func testABookOpeningAtACoverPageHasItsFirstWordsPrepared() throws {
        var prose = BenchmarkProse(seed: 53)
        let cover = Chapter(title: "Cover", text: "")
        let long = Chapter(title: "Long", text: prose.text(utf16Length: SpeechRenderCoordinator.maximumTextLength + 20_000))
        try withReader(chapters: [cover, long, Self.chapters[2]]) { reader, _ in
            let inputs = try XCTUnwrap(reader.speechInputs(forChapterAt: 1))

            try showLoaded(reader, atChapter: 0)

            XCTAssertTrue(reader.chapterSpeechCache.isPreparingInBackground(inputs), "the chapter after the cover")
            XCTAssertTrue(
                waitUntil(timeout: Self.backgroundPreparationTimeout) { !reader.chapterSpeechCache.isPreparingInBackground(inputs) },
                "the speech never arrived"
            )
            let start = try XCTUnwrap(reader.speechStartFromCursor())

            XCTAssertEqual(start.speech.chapterIndex, 1)
            XCTAssertEqual(reader.chapterSpeechCache.misses, 1, "only the empty cover was prepared at Play")
            assertSameSpeech(start.speech, try legacyPreparedSpeech(reader, chapterIndex: 1))
        }
    }

    /// Nothing is prepared again for a chapter whose speech is already kept,
    /// and a closed reader prepares nothing.
    func testTheOpenedChapterIsNotPreparedTwice() throws {
        try withReader { reader, _ in
            _ = try XCTUnwrap(reader.preparedSpeech(forChapterAt: 0))
            let inputs = try XCTUnwrap(reader.speechInputs(forChapterAt: 0))

            reader.prepareOpenedChapterSpeech()

            XCTAssertFalse(reader.chapterSpeechCache.isPreparingInBackground(inputs))
            reader.close()
            reader.prepareOpenedChapterSpeech()
            XCTAssertFalse(reader.chapterSpeechCache.isPreparingInBackground(inputs))
        }
    }

    // MARK: - Play during the opened chapter's preparation

    /// Play pressed while the chapter it starts in, a long one, is still
    /// being prepared in the background waits for that preparation instead
    /// of preparing the chapter again on the main thread: Playing shows at
    /// once, nothing is spoken until the speech is ready, and then exactly
    /// that speech is spoken, with nothing prepared on the main thread.
    /// Play pressed again while it waits changes nothing.
    ///
    /// The preparation is one the test finishes, so speech starts only when
    /// the test hands its result over, never while the run loop turns.
    func testPlayDuringTheOpenedChaptersPreparationWaitsForItAndSpeaksItsResult() throws {
        try withReader(chapters: Self.chaptersEndingInALongOne(seed: 59), substitutions: [Self.harbourSpelling]) { reader, _ in
            reader.currentChapterIndex = 1
            let inputs = try XCTUnwrap(reader.speechInputs(forChapterAt: 1))
            XCTAssertTrue(inputs.isLong)
            XCTAssertTrue(reader.chapterSpeechCache.beginPreparingInBackground(inputs))

            reader.play()

            XCTAssertTrue(reader.isWaitingForChapterSpeech, "Play did not wait for the speech")
            XCTAssertTrue(reader.isCurrentlyPlaying, "Playing does not show while Play waits")
            XCTAssertFalse(reader.isCurrentlyPaused)
            XCTAssertFalse(reader.speechService.isSpeaking, "speech started before it was ready")
            reader.play()
            reader.playOrResume()
            XCTAssertTrue(reader.isWaitingForChapterSpeech)
            XCTAssertFalse(reader.speechService.isSpeaking)

            let prepared = inputs.prepare()
            reader.finishPreparingInBackground(prepared)

            XCTAssertFalse(reader.isWaitingForChapterSpeech)
            assertSpeaks(reader, (prepared.text, prepared.offsetMap))
            assertSpeaks(reader, try legacyPreparedSpeech(reader, chapterIndex: 1))
            XCTAssertEqual(reader.chapterSpeechCache.misses, 0, "the chapter was prepared on the main thread")
            silence(reader)
        }
    }

    /// An End of heading timer set while Play waits for a long chapter's
    /// speech, after a cover, took the cursor's heading, which is the first
    /// of the chapter Play was about to start in: when the speech was ready,
    /// speech began there and the first refresh stopped the book at once, in
    /// silence ("Sleep timer expired at the end of the heading"). Play now
    /// settles the heading as it starts, so playback goes on and stops where
    /// the next heading begins.
    ///
    /// The preparation is one the test finishes, so speech starts only when
    /// the test hands its result over.
    func testAnEndOfHeadingTimerSetWhilePlayWaitsForALongChapterStopsWhereTheNextHeadingBegins() throws {
        preserveSleepTimers()
        try withReader(chapters: Self.coverBeforeALongChapter(seed: 67)) { reader, _ in
            // The timer of the reader's window.
            let timer = reader.sleepTimerService
            let inputs = try XCTUnwrap(reader.speechInputs(forChapterAt: 1))
            XCTAssertTrue(inputs.isLong)
            XCTAssertTrue(reader.chapterSpeechCache.beginPreparingInBackground(inputs))
            let market = try XCTUnwrap(reader.headings.first { $0.text == "Market" }, "No Market heading")
            reader.play()
            XCTAssertTrue(reader.isWaitingForChapterSpeech, "Play did not wait for the speech")

            reader.startSleepTimer(duration: .endOfHeading)
            XCTAssertEqual(reader.sleepTimerNextHeading?.text, "Harbour", "The provisional choice is the cursor's heading")
            reader.finishPreparingInBackground(inputs.prepare())
            XCTAssertEqual([reader.currentChapterIndex, reader.currentCharacterOffset], [1, 0], "Speech did not start in the long chapter")

            var timerInEffectAtStart = false
            var spokeAtStart = false
            var spokeIntoMarket = true
            let recorder = recordingAnnouncements {
                // The reader's first refresh of its view of the cursor.
                reader.stopForSleepTimerIfPlaybackReachedHeadingEnd()
                timerInEffectAtStart = timer.isActive
                spokeAtStart = reader.speechService.isSpeaking
                let spokenOffset = reader.currentOffsetMap?.toModified(market.characterOffset) ?? market.characterOffset
                reader.speechService.onWordSpoken?(NSRange(location: spokenOffset, length: 1), "x")
                reader.stopForSleepTimerIfPlaybackReachedHeadingEnd()
                spokeIntoMarket = reader.speechService.isSpeaking
            }
            silence(reader)

            XCTAssertTrue(timerInEffectAtStart, "The timer ended as the awaited speech started, in silence")
            XCTAssertTrue(spokeAtStart, "Playback was stopped as it started")
            XCTAssertFalse(spokeIntoMarket, "Speech went on into the Market heading")
            XCTAssertEqual(
                recorder.announcements.map(\.message),
                ["Sleep timer expired at the end of the heading. Playback paused."],
                "The listener must hear the timer end once, at the heading"
            )
            XCTAssertEqual(reader.currentCharacterOffset, market.characterOffset, "The cursor is not at Market")
        }
    }

    /// Choosing the heading an End of heading timer waits for never prepares
    /// speech on the main actor, which Play's own wait for a preparation
    /// under way never does: setting the timer, and the refreshes a loaded
    /// book and an edited text make (`refreshSleepTimerHeading()`), leave a
    /// long chapter that is not kept alone, and start no preparation. The
    /// cursor's heading stands in until Play starts.
    func testChoosingTheTimersHeadingNeverPreparesALongChapterOnTheMainActor() throws {
        preserveSleepTimers()
        let cases: [(name: String, beingPrepared: Bool)] = [
            ("a chapter being prepared in the background", true),
            ("a chapter nobody has begun preparing", false),
        ]
        for testCase in cases {
            try withReader(chapters: Self.coverBeforeALongChapter(seed: 71)) { reader, _ in
                let inputs = try XCTUnwrap(reader.speechInputs(forChapterAt: 1), testCase.name)
                XCTAssertTrue(inputs.isLong, testCase.name)
                if testCase.beingPrepared {
                    XCTAssertTrue(reader.chapterSpeechCache.beginPreparingInBackground(inputs), testCase.name)
                }

                reader.startSleepTimer(duration: .endOfHeading)
                reader.refreshSleepTimerHeading()

                XCTAssertFalse(
                    reader.chapterSpeechCache.isKept(inputs),
                    "\(testCase.name): the long chapter was prepared on the main actor"
                )
                XCTAssertEqual(
                    reader.chapterSpeechCache.isPreparingInBackground(inputs),
                    testCase.beingPrepared,
                    "\(testCase.name): a preparation was started or ended"
                )
                XCTAssertEqual(
                    reader.sleepTimerNextHeading?.text,
                    "Harbour",
                    "\(testCase.name): the provisional heading"
                )
            }
        }
    }

    /// A change to what the chapter is prepared from, made while Play
    /// waits, is never missed: the speech the preparation then hands over,
    /// made from the settings before the change, is neither kept nor
    /// spoken, and Play prepares the chapter afresh from the settings in
    /// force, exactly as the old pipeline makes it.
    func testAChangeWhilePlayWaitsPreparesTheChapterAfresh() throws {
        let changes: [(name: String, change: (ReaderViewModel) throws -> Void)] = [
            ("rule added", { $0.substitutionService.rules.append(Self.seabirdsForGulls) }),
            ("substitutions off", { $0.substitutionService.isEnabled = false }),
            ("symbol style", { $0.substitutionService.repeatedSymbolStyle = .leaveOut }),
            ("pause level", { $0.settingsViewModel.punctuationPauseLevel = 2 }),
            ("section skipped", { reader in
                reader.toggleHeadingSkip(try XCTUnwrap(reader.headings.first { $0.text == "Market" }))
            }),
        ]
        for (name, change) in changes {
            try withReader(chapters: Self.chaptersEndingInALongOne(seed: 61), substitutions: [Self.harbourSpelling]) { reader, _ in
                reader.currentChapterIndex = 1
                let awaited = try XCTUnwrap(reader.speechInputs(forChapterAt: 1), name)
                XCTAssertTrue(reader.chapterSpeechCache.beginPreparingInBackground(awaited), name)
                reader.play()
                XCTAssertTrue(reader.isWaitingForChapterSpeech, name)

                try change(reader)
                reader.finishPreparingInBackground(awaited.prepare())

                XCTAssertFalse(reader.isWaitingForChapterSpeech, name)
                XCTAssertEqual(reader.chapterSpeechCache.misses, 1, "\(name): not prepared afresh from the settings in force")
                assertSpeaks(reader, try legacyPreparedSpeech(reader, chapterIndex: 1), name)
                silence(reader)
            }
        }
    }

    /// Play on a short chapter whose speech is being prepared in the
    /// background is unchanged: it prepares the chapter at once, which
    /// takes a few milliseconds, and speaks without waiting. The chapter
    /// ends the book, so no look-ahead prepares another.
    func testPlayOnAShortChapterPreparesItAtOnce() throws {
        try withReader(chapters: Array(Self.chapters.prefix(2)), substitutions: [Self.harbourSpelling]) { reader, _ in
            reader.currentChapterIndex = 1
            let inputs = try XCTUnwrap(reader.speechInputs(forChapterAt: 1))
            XCTAssertFalse(inputs.isLong)
            XCTAssertTrue(reader.chapterSpeechCache.beginPreparingInBackground(inputs))

            reader.play()

            XCTAssertFalse(reader.isWaitingForChapterSpeech, "Play waited for a short chapter")
            XCTAssertEqual(reader.chapterSpeechCache.misses, 1, "the chapter was not prepared at once")
            assertSpeaks(reader, try legacyPreparedSpeech(reader, chapterIndex: 1))
            silence(reader)
        }
    }

    /// A book opening at a chapter without words has the next chapter with
    /// words prepared in the background; Play, finding nothing to say in
    /// the cover, waits for that chapter's speech and speaks it from its
    /// start. Only the empty cover is prepared on the main thread.
    func testPlayAtACoverPageWaitsForTheFirstChapterWithWords() throws {
        var chapters = Self.chaptersEndingInALongOne(seed: 79)
        chapters[0] = Chapter(title: "Cover", text: "")
        try withReader(chapters: chapters) { reader, _ in
            let inputs = try XCTUnwrap(reader.speechInputs(forChapterAt: 1))
            XCTAssertTrue(reader.chapterSpeechCache.beginPreparingInBackground(inputs))

            reader.play()

            XCTAssertTrue(reader.isWaitingForChapterSpeech, "Play did not wait for the chapter after the cover")
            XCTAssertEqual(reader.chapterSpeechCache.misses, 1, "only the empty cover is prepared at Play")
            reader.finishPreparingInBackground(inputs.prepare())

            XCTAssertEqual(reader.currentChapterIndex, 1)
            XCTAssertEqual(reader.currentCharacterOffset, 0)
            assertSpeaks(reader, try legacyPreparedSpeech(reader, chapterIndex: 1))
            XCTAssertEqual(reader.chapterSpeechCache.misses, 1, "the chapter was prepared on the main thread")
            silence(reader)
        }
    }

    /// Play/Pause pressed while Play waits ends the wait: the reader shows
    /// nothing playing, and nothing is spoken when the speech is ready.
    /// The speech is kept, so the next Play speaks it at once without
    /// preparing it on the main thread. The preparation here is the real
    /// one a finished load starts.
    func testPausingWhilePlayWaitsEndsTheWaitAndKeepsTheSpeechForTheNextPlay() throws {
        try withReader(chapters: Self.chaptersEndingInALongOne(seed: 67), substitutions: [Self.harbourSpelling]) { reader, _ in
            let inputs = try XCTUnwrap(reader.speechInputs(forChapterAt: 1))
            try showLoaded(reader, atChapter: 1)
            XCTAssertTrue(reader.chapterSpeechCache.isPreparingInBackground(inputs), "prepared off the main actor")
            reader.play()
            XCTAssertTrue(reader.isWaitingForChapterSpeech, "Play did not wait for the speech")

            reader.togglePlayPause()

            XCTAssertFalse(reader.isWaitingForChapterSpeech, "Play/Pause did not end the wait")
            XCTAssertFalse(reader.isCurrentlyPlaying)
            XCTAssertFalse(reader.isCurrentlyPaused)
            XCTAssertTrue(
                waitUntil(timeout: Self.backgroundPreparationTimeout) { !reader.chapterSpeechCache.isPreparingInBackground(inputs) },
                "the speech never arrived"
            )
            XCTAssertFalse(reader.speechService.isSpeaking, "the speech started after the wait ended")
            XCTAssertFalse(reader.isCurrentlyPlaying, "Playing shows after the wait ended")

            reader.play()

            XCTAssertEqual(reader.chapterSpeechCache.misses, 0, "the next Play prepared the chapter on the main thread")
            assertSpeaks(reader, try legacyPreparedSpeech(reader, chapterIndex: 1))
            silence(reader)
        }
    }

    /// Stopping the reader, or closing it, while Play waits ends the wait,
    /// and nothing is spoken when the speech is ready.
    func testStoppingOrClosingWhilePlayWaitsSpeaksNothing() throws {
        for closing in [false, true] {
            let label = closing ? "closed" : "stopped"
            try withReader(chapters: Self.chaptersEndingInALongOne(seed: 73)) { reader, _ in
                reader.currentChapterIndex = 1
                let inputs = try XCTUnwrap(reader.speechInputs(forChapterAt: 1), label)
                XCTAssertTrue(reader.chapterSpeechCache.beginPreparingInBackground(inputs), label)
                reader.play()
                XCTAssertTrue(reader.isWaitingForChapterSpeech, label)

                if closing {
                    reader.close()
                } else {
                    reader.stop()
                }

                XCTAssertFalse(reader.isWaitingForChapterSpeech, label)
                XCTAssertFalse(reader.isCurrentlyPlaying, label)
                reader.finishPreparingInBackground(inputs.prepare())
                XCTAssertFalse(reader.speechService.isSpeaking, "\(label): the speech started")
                XCTAssertFalse(reader.isCurrentlyPlaying, "\(label): Playing shows")
            }
        }
    }

    /// A move made while Play waits keeps Playing showing, although it
    /// stops the idle speech service, and the speech starts from wherever
    /// the cursor is when the speech is ready.
    func testAMoveWhilePlayWaitsKeepsPlayingAndSpeaksFromTheNewPlace() throws {
        try withReader(chapters: Self.chaptersEndingInALongOne(seed: 71)) { reader, _ in
            reader.currentChapterIndex = 1
            let inputs = try XCTUnwrap(reader.speechInputs(forChapterAt: 1))
            XCTAssertTrue(reader.chapterSpeechCache.beginPreparingInBackground(inputs))
            let market = try XCTUnwrap(reader.headings.first { $0.text == "Market" })
            reader.play()

            reader.navigateTo(chapterIndex: 1, characterOffset: market.characterOffset)
            // The speech service's stop reaches the reader's Playing state
            // on the main queue's next turn. The preparation is the test's
            // own, so nothing can start meanwhile.
            settle()

            XCTAssertTrue(reader.isWaitingForChapterSpeech, "the move ended the wait")
            XCTAssertTrue(reader.isCurrentlyPlaying, "Playing no longer shows")
            XCTAssertFalse(reader.speechService.isSpeaking)
            reader.finishPreparingInBackground(inputs.prepare())

            XCTAssertTrue(reader.speechService.isSpeaking, "the speech did not start")
            XCTAssertEqual(reader.currentChapterIndex, 1)
            XCTAssertEqual(reader.currentCharacterOffset, market.characterOffset)
            silence(reader)
        }
    }

    // MARK: - Play waiting while Where Am I speaks

    /// Speech that is ready while a Where Am I announcement speaks is not
    /// spoken over it, and the play does not end: it goes on waiting,
    /// showing Playing, and when the announcement ends by itself, the
    /// speech starts once the end sound has had its moment, exactly the
    /// speech prepared in the background.
    ///
    /// The speech starts while the run loop turns, so the speech service
    /// hands its utterances to a recorder instead of the synthesizer, and
    /// nothing is heard.
    func testSpeechReadyWhileWhereAmISpeaksStartsOnceTheAnnouncementEnds() throws {
        try withReader(chapters: Self.chaptersEndingInALongOne(seed: 83)) { reader, _ in
            let inputs = try waitingPlay(of: reader, whileWhereAmISpeaks: true)
            let prepared = inputs.prepare()

            reader.finishPreparingInBackground(prepared)

            XCTAssertFalse(reader.speechService.isSpeaking, "the speech started over Where Am I")
            XCTAssertTrue(reader.isWaitingForChapterSpeech, "the play stopped waiting while Where Am I spoke")
            XCTAssertTrue(reader.isCurrentlyPlaying, "Playing no longer shows while Where Am I speaks")
            XCTAssertFalse(reader.isCurrentlyPaused)
            let endSound = WhereAmIEndSoundClock(holdingFor: reader)

            reader.whereAmIAnnouncementFinished()

            XCTAssertFalse(reader.isWhereAmISpeaking)
            XCTAssertFalse(reader.speechService.isSpeaking, "the speech started before the end sound")
            endSound.passEndSound()
            XCTAssertTrue(reader.speechService.isSpeaking, "the speech never started after the announcement")
            XCTAssertFalse(reader.isWaitingForChapterSpeech)
            assertSpeaks(reader, (prepared.text, prepared.offsetMap))
            XCTAssertEqual(reader.chapterSpeechCache.misses, 0, "the chapter was prepared on the main thread")
            silence(reader)
        }
    }

    /// Speech that is ready while a Where Am I announcement's end sound
    /// plays, the announcement having ended by itself, is not spoken over
    /// the sound either (REV18a, item 7): the play goes on waiting, showing
    /// Playing, and the speech starts once the sound has had its moment,
    /// exactly the speech prepared in the background.
    func testSpeechReadyWhileWhereAmIsEndSoundPlaysStartsOnceItHasPassed() throws {
        try withReader(chapters: Self.chaptersEndingInALongOne(seed: 107)) { reader, _ in
            let inputs = try waitingPlay(of: reader, whileWhereAmISpeaks: true)
            let prepared = inputs.prepare()
            let endSound = WhereAmIEndSoundClock(holdingFor: reader)

            // The announcement ends by itself before the speech is ready.
            reader.whereAmIAnnouncementFinished()
            XCTAssertFalse(reader.isWhereAmISpeaking)
            XCTAssertTrue(reader.isWhereAmIEndSoundPlaying)

            reader.finishPreparingInBackground(prepared)

            XCTAssertFalse(reader.speechService.isSpeaking, "the speech started over the end sound")
            XCTAssertTrue(reader.isWaitingForChapterSpeech, "the play stopped waiting during the end sound")
            XCTAssertTrue(reader.isCurrentlyPlaying, "Playing no longer shows during the end sound")
            XCTAssertFalse(reader.isCurrentlyPaused)

            endSound.passEndSound()

            XCTAssertTrue(reader.speechService.isSpeaking, "the speech never started after the end sound")
            XCTAssertFalse(reader.isWaitingForChapterSpeech)
            assertSpeaks(reader, (prepared.text, prepared.offsetMap))
            XCTAssertEqual(reader.chapterSpeechCache.misses, 0, "the chapter was prepared on the main thread")
            silence(reader)
        }
    }

    /// An announcement ended by hand, by Where Am I pressed again or by a
    /// command that interrupts it, starts the play it held at once.
    func testWhereAmIEndedByHandStartsTheHeldPlayAtOnce() throws {
        let endings: [(name: String, end: (ReaderViewModel) -> Void)] = [
            ("Where Am I again", { $0.whereAmI() }),
            ("an interrupting command", { $0.cancelWhereAmIIfActive() }),
        ]
        for (number, ending) in endings.enumerated() {
            try withReader(chapters: Self.chaptersEndingInALongOne(seed: UInt64(89 + number))) { reader, _ in
                let inputs = try waitingPlay(of: reader, whileWhereAmISpeaks: true)
                let prepared = inputs.prepare()
                reader.finishPreparingInBackground(prepared)
                XCTAssertFalse(reader.speechService.isSpeaking, ending.name)

                ending.end(reader)

                XCTAssertFalse(reader.isWhereAmISpeaking, ending.name)
                XCTAssertFalse(reader.isWaitingForChapterSpeech, ending.name)
                assertSpeaks(reader, (prepared.text, prepared.offsetMap), ending.name)
                silence(reader)
            }
        }
    }

    /// Play/Pause pressed while Where Am I speaks ends the announcement and
    /// leaves the book paused, as it leaves a book the announcement paused:
    /// a play waiting for its chapter's speech stops waiting, whether the
    /// speech is ready or still being prepared, and nothing is spoken. Speech
    /// ready by then is kept, so the next Play speaks it without preparing
    /// it again.
    func testPlayPauseDuringWhereAmIPausesAWaitingPlay() throws {
        for speechIsReady in [true, false] {
            let label = speechIsReady ? "speech ready" : "speech still being prepared"
            try withReader(chapters: Self.chaptersEndingInALongOne(seed: speechIsReady ? 97 : 101)) { reader, _ in
                let inputs = try waitingPlay(of: reader, whileWhereAmISpeaks: true)
                if speechIsReady {
                    reader.finishPreparingInBackground(inputs.prepare())
                }

                reader.togglePlayPause()

                XCTAssertFalse(reader.isWhereAmISpeaking, label)
                XCTAssertFalse(reader.isWaitingForChapterSpeech, "\(label): the play still waits")
                XCTAssertFalse(reader.isCurrentlyPlaying, "\(label): Playing shows")
                if !speechIsReady {
                    reader.finishPreparingInBackground(inputs.prepare())
                }
                XCTAssertFalse(reader.speechService.isSpeaking, "\(label): the speech started")

                reader.play()

                XCTAssertEqual(reader.chapterSpeechCache.misses, 0, "\(label): the next Play prepared the chapter on the main thread")
                assertSpeaks(reader, try legacyPreparedSpeech(reader, chapterIndex: 1), label)
                silence(reader)
            }
        }
    }

    /// An announcement the system cancels on its own, as the speech engine
    /// does with a text it refuses, leaves a play waiting for its chapter's
    /// speech to start as the announcement's end would have started it
    /// (REV13): at once when the speech is ready, and as soon as it is
    /// ready when it is still being prepared, the reader showing Playing
    /// meanwhile. The speech spoken is the speech prepared in the
    /// background, never the chapter prepared again on the main thread.
    /// Before, the cancel paused the waiting play, as Play/Pause during the
    /// announcement does (#1296), and the Play pressed before the
    /// announcement was lost.
    func testAnAnnouncementTheSystemCancelsLeavesAWaitingPlayToStart() throws {
        for speechIsReady in [true, false] {
            let label = speechIsReady ? "speech ready" : "speech still being prepared"
            try withReader(chapters: Self.chaptersEndingInALongOne(seed: speechIsReady ? 107 : 109)) { reader, _ in
                var announcements: [AVSpeechUtterance] = []
                reader._whereAmIUtteranceRecorderForTesting = { announcements.append($0) }
                let inputs = try waitingPlay(of: reader, whileWhereAmISpeaks: false)
                reader.speakWhereAmI("Tide Tables.")
                let prepared = inputs.prepare()
                if speechIsReady {
                    reader.finishPreparingInBackground(prepared)
                    XCTAssertFalse(reader.speechService.isSpeaking, "\(label): the speech started over Where Am I")
                }
                let announcement = try XCTUnwrap(announcements.last, "\(label): no announcement was handed over")
                let delegate = try XCTUnwrap(reader.whereAmIDelegate, "\(label): nothing hears the synthesizer")

                delegate.speechSynthesizer(AVSpeechSynthesizer(), didCancel: announcement)

                XCTAssertTrue(waitUntil(timeout: 5) { !reader.isWhereAmISpeaking }, "\(label): the cancel was not heard")
                XCTAssertTrue(reader.isCurrentlyPlaying, "\(label): Playing no longer shows")
                XCTAssertFalse(reader.isCurrentlyPaused, "\(label): the cancel paused the play")
                if !speechIsReady {
                    XCTAssertTrue(reader.isWaitingForChapterSpeech, "\(label): the play stopped waiting")
                    XCTAssertFalse(reader.speechService.isSpeaking, "\(label): the speech started before it was ready")
                    reader.finishPreparingInBackground(prepared)
                }
                XCTAssertFalse(reader.isWaitingForChapterSpeech, "\(label): the play still waits")
                assertSpeaks(reader, (prepared.text, prepared.offsetMap), label)
                XCTAssertEqual(reader.chapterSpeechCache.misses, 0, "\(label): the chapter was prepared on the main thread")
                silence(reader)
            }
        }
    }

    /// An announcement that ends before the speech is ready leaves the play
    /// waiting for the speech, which starts it as soon as it is ready.
    func testAnAnnouncementEndingBeforeTheSpeechIsReadyLeavesThePlayWaiting() throws {
        try withReader(chapters: Self.chaptersEndingInALongOne(seed: 103)) { reader, _ in
            let inputs = try waitingPlay(of: reader, whileWhereAmISpeaks: true)
            let endSound = WhereAmIEndSoundClock(holdingFor: reader)

            reader.whereAmIAnnouncementFinished()
            // The end sound's moment passes with the speech still being
            // prepared: nothing starts.
            endSound.passEndSound()

            XCTAssertFalse(reader.speechService.isSpeaking, "speech started before it was ready")
            XCTAssertTrue(reader.isWaitingForChapterSpeech, "the play stopped waiting")
            let prepared = inputs.prepare()
            reader.finishPreparingInBackground(prepared)
            assertSpeaks(reader, (prepared.text, prepared.offsetMap))
            silence(reader)
        }
    }

    /// Has `reader`, over the long chapter of `chaptersEndingInALongOne`,
    /// wait for that chapter's speech after Play, as Play waits for a
    /// preparation the test finishes itself, with a Where Am I
    /// announcement speaking, or not, as `whileWhereAmISpeaks` says. The
    /// speech service hands what it would say to a recorder rather than
    /// the synthesizer, so speech that starts while the run loop turns is
    /// never heard.
    ///
    /// - Returns: The inputs the play waits for.
    private func waitingPlay(of reader: ReaderViewModel, whileWhereAmISpeaks: Bool) throws -> ChapterSpeechInputs {
        reader.speechService._directUtteranceRecorderForTesting = { _ in }
        reader.currentChapterIndex = 1
        let inputs = try XCTUnwrap(reader.speechInputs(forChapterAt: 1))
        XCTAssertTrue(inputs.isLong)
        XCTAssertTrue(reader.chapterSpeechCache.beginPreparingInBackground(inputs))
        reader.play()
        XCTAssertTrue(reader.isWaitingForChapterSpeech, "Play did not wait for the speech")
        // Where Am I pressed now, as an announcement starting would leave
        // it: nothing was playing to pause, and its synthesizer speaks
        // nothing in a test.
        reader.isWhereAmISpeaking = whileWhereAmISpeaks
        return inputs
    }

    /// Shows the reader's content as a finished load shows it, with the
    /// cursor at the start of chapter `chapterIndex`.
    private func showLoaded(_ reader: ReaderViewModel, atChapter chapterIndex: Int) throws {
        let content = try XCTUnwrap(reader.content)
        reader.currentChapterIndex = chapterIndex
        reader.currentCharacterOffset = 0
        reader.showLoadedContent(
            ReaderViewModel.LoadedContent(
                content: content,
                index: content.contentIndex,
                audioFiles: nil,
                audioSegments: nil,
                audioTags: nil,
                shouldPersistContentIndex: false,
                cacheFormatVersion: nil
            ),
            readFrom: reader.book.filePath
        )
    }

    // MARK: - Closing

    /// A closed reader keeps no prepared speech: SwiftUI may keep a closed
    /// window's reader alive.
    func testAClosedReaderKeepsNoPreparedSpeech() throws {
        try withReader { reader, _ in
            reader.speechService.isSpeaking = true
            reader.preRenderNextChapter()
            _ = reader.preparedSpeech(forChapterAt: 0)
            XCTAssertFalse(reader.chapterSpeechCache.isEmpty)

            reader.close()

            XCTAssertTrue(reader.chapterSpeechCache.isEmpty)
        }
    }

    // MARK: - Benchmarks

    /// Times a chapter boundary with the user's rules over chapters of
    /// 40,000 UTF-16 units, the 90th percentile of the library.
    ///
    /// Before PERF02 the next chapter was prepared afresh when the
    /// look-ahead chose it, when its render finished, at the chapter's end,
    /// and at every speed, pitch, or voice step; the review measured 16 ms
    /// for each (hosted Debug, before PERF01). Today the look-ahead prepares
    /// it once, and the chapter's end and a speed step find it kept.
    func testBenchmarkAChapterBoundary() throws {
        var prose = BenchmarkProse(seed: 41)
        let chapters = (1...3).map { Chapter(title: "Part \($0)", text: prose.text(utf16Length: 40_000)) }
        try withReader(chapters: chapters, substitutions: TextSubstitutionService.benchmarkRules) { reader, _ in
            let inputs = try XCTUnwrap(reader.speechInputs(forChapterAt: 1))
            // What each of the four requests cost before: a fresh preparation.
            let freshPreparation = benchmarkTiming { inputs.prepare() }

            reader.speechService.isSpeaking = true
            let lookAhead = benchmarkTiming { reader.preRenderNextChapter() }
            let chapterEnd = benchmarkTiming { reader.nextSpeakableChapterSpeech(from: 1) }
            let speedStep = benchmarkTiming { reader.applyLocalSpeechOverrides() }
            silence(reader)

            let speech = try XCTUnwrap(chapterEnd.value)
            assertSameSpeech(speech, freshPreparation.value)
            reportBenchmark("PERF02 chapter boundary", [
                "chapterUTF16Length": inputs.text.utf16Length,
                "oldPreparationsPerChapter": 4,
                "oldChapterEndMilliseconds": freshPreparation.milliseconds,
                "oldSpeedStepMilliseconds": freshPreparation.milliseconds,
                "newLookAheadMilliseconds": lookAhead.milliseconds,
                "newChapterEndMilliseconds": chapterEnd.milliseconds,
                "newSpeedStepMilliseconds": speedStep.milliseconds,
            ])
        }
    }

    /// Times reaching a chapter of a million UTF-16 units with the user's
    /// rules: before PERF02 the chapter's end prepared it on the main thread
    /// (3.4 s in the review, before PERF01); today the look-ahead prepares it
    /// off the main actor, and the chapter's end finds it kept.
    func testBenchmarkALongChapterBoundary() throws {
        var prose = BenchmarkProse(seed: 43)
        let long = Chapter(title: "Long", text: prose.text(utf16Length: 1_000_000))
        try withReader(
            chapters: [Self.chapters[0], long, Self.chapters[2]],
            substitutions: TextSubstitutionService.benchmarkRules
        ) { reader, _ in
            let inputs = try XCTUnwrap(reader.speechInputs(forChapterAt: 1))
            let freshPreparation = benchmarkTiming { inputs.prepare() }

            reader.speechService.isSpeaking = true
            let lookAhead = benchmarkTiming { reader.preRenderNextChapter() }
            let ready = benchmarkTiming {
                waitUntil(timeout: Self.backgroundPreparationTimeout) { reader.chapterSpeechCache.lookAheadSpeech != nil }
            }
            let chapterEnd = benchmarkTiming { reader.nextSpeakableChapterSpeech(from: 1) }
            silence(reader)

            XCTAssertTrue(ready.value, "the speech never arrived")
            assertSameSpeech(try XCTUnwrap(chapterEnd.value), freshPreparation.value)
            reportBenchmark("PERF02 long chapter boundary", [
                "chapterUTF16Length": inputs.text.utf16Length,
                "oldChapterEndMainThreadMilliseconds": freshPreparation.milliseconds,
                "newLookAheadMainThreadMilliseconds": lookAhead.milliseconds,
                "newBackgroundPreparationWaitMilliseconds": ready.milliseconds,
                "newChapterEndMainThreadMilliseconds": chapterEnd.milliseconds,
            ])
        }
    }

    // MARK: - The old pipeline

    /// `ReaderViewModel.preparedSpeech(forChapterAt:)` as it was before
    /// PERF02, line for line, with nothing kept: each stage run on the
    /// chapter's text with the settings in force, the skipped sections
    /// filtered with the whole book's skipped headings.
    private func legacyPreparedSpeech(
        _ reader: ReaderViewModel,
        chapterIndex: Int
    ) throws -> (text: String, offsetMap: ComposedOffsetMap) {
        let content = try XCTUnwrap(reader.content)
        let text = try XCTUnwrap(content.chapters[safe: chapterIndex], "the book has no chapter \(chapterIndex)").text
        let skippedIDs = reader.skippedHeadingIDs
        let (filteredText, filterMap) = skippedIDs.isEmpty
            ? (text, OffsetMap.identity)
            : SkippedSectionFilter.apply(
                text: text,
                headings: reader.headings.filter { $0.chapterIndex == chapterIndex },
                skippedIDs: skippedIDs
            )
        let (symbolText, symbolMap) = reader.substitutionService.repeatedSymbolRule.apply(to: filteredText)
        let (pausedText, pauseMap) = ReaderViewModel.applyPunctuationPauses(
            symbolText,
            level: reader.settingsViewModel.punctuationPauseLevel
        )
        let transformation = reader.substitutionService.transform(pausedText)
        return (
            transformation.modifiedText,
            ComposedOffsetMap(stages: [filterMap, symbolMap, pauseMap] + transformation.offsetMap.stages)
        )
    }

    // MARK: - Assertions

    /// Checks that `speech` is exactly `expected`: the same characters,
    /// byte for byte, and the same map.
    private func assertSameSpeech(
        _ speech: ReaderViewModel.ChapterSpeech,
        _ expected: (text: String, offsetMap: ComposedOffsetMap),
        _ label: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(haveIdenticalBytes(speech.text, expected.text), "text \(label)", file: file, line: line)
        XCTAssertEqual(speech.offsetMap, expected.offsetMap, "map \(label)", file: file, line: line)
    }

    /// Checks that `reader` is speaking exactly `expected`: the text it
    /// handed the speech engine, byte for byte, and the map it converts
    /// offsets with.
    private func assertSpeaks(
        _ reader: ReaderViewModel,
        _ expected: (text: String, offsetMap: ComposedOffsetMap),
        _ label: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(reader.speechService.isSpeaking, "not speaking \(label)", file: file, line: line)
        XCTAssertTrue(
            haveIdenticalBytes(reader.currentTransformation?.modifiedText ?? "", expected.text),
            "text \(label)",
            file: file,
            line: line
        )
        XCTAssertEqual(reader.currentOffsetMap, expected.offsetMap, "map \(label)", file: file, line: line)
    }

    /// Checks that two prepared speeches are exactly the same.
    private func assertSameSpeech(
        _ speech: ReaderViewModel.ChapterSpeech,
        _ expected: ReaderViewModel.ChapterSpeech,
        _ label: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(speech.chapterIndex, expected.chapterIndex, "chapter \(label)", file: file, line: line)
        assertSameSpeech(speech, (expected.text, expected.offsetMap), label, file: file, line: line)
    }

    /// How long a test waits for a chapter prepared in the background.
    private static let backgroundPreparationTimeout: TimeInterval = 30

    // MARK: - Fixtures

    /// Respells "harbour", which the middle chapter says.
    private static let harbourSpelling = SubstitutionRule(name: "Harbour spelling", pattern: "harbour", replacement: "harbor")

    /// Replaces a word only the first chapter says.
    private static let quayToPier = SubstitutionRule(name: "Pier", pattern: "quay", replacement: "pier")

    /// Replaces a word only the middle chapter says.
    private static let seabirdsForGulls = SubstitutionRule(name: "Seabirds", pattern: "Gulls", replacement: "Seabirds")

    /// Three chapters of headed sections. The middle one has sentence and
    /// comma punctuation for the pauses, a separator line for the
    /// repeated-symbol rule, words for the substitution rules, and a
    /// precomposed accent.
    private static let chapters: [Chapter] = [
        chapter(sections: [
            ("Departure", "The ferry left the quay at noon."),
            ("Crossing", "Spray rose over the bow."),
        ]),
        chapter(sections: middleChapterSections),
        chapter(sections: [("Evening", "Lamps came on along the pier.")]),
    ]

    /// The middle chapter's sections.
    private static let middleChapterSections: [(heading: String, body: String)] = [
        ("Harbour", "Gulls circled the harbour wall. Then rain came, briefly.\n\n* * * * * * *"),
        ("Market", "Fish sold out by nine at the Caf\u{00E9} Brennan."),
    ]

    /// The first of `chapters`, then the middle one made too long to render
    /// ahead: its sections as before, the last followed by prose from
    /// `seed`, so that everything that shapes the middle chapter's speech
    /// shapes this one's too. It ends the book, so a play of it looks ahead
    /// to nothing, and every chapter prepared on the main thread is counted
    /// by Play alone.
    private static func chaptersEndingInALongOne(seed: UInt64) -> [Chapter] {
        var prose = BenchmarkProse(seed: seed)
        var sections = middleChapterSections
        let length = SpeechRenderCoordinator.maximumTextLength + 20_000
        sections[sections.count - 1].body += "\n\n" + prose.text(utf16Length: length)
        return [chapters[0], chapter(sections: sections)]
    }

    /// A cover, a chapter of no words at all, then the long chapter of
    /// `chaptersEndingInALongOne(seed:)` with its headings Harbour and
    /// Market, so Play passes the cover over and waits for the long chapter's
    /// speech when it is being prepared.
    private static func coverBeforeALongChapter(seed: UInt64) -> [Chapter] {
        [Chapter(title: "Cover", text: ""), chaptersEndingInALongOne(seed: seed)[1]]
    }

    /// `chapters` with `old` replaced by `new` in the middle chapter, as a
    /// book read again with other text would hold it.
    private static func content(replacingInChapterOne old: String, with new: String) -> DocumentContent {
        var changed = chapters
        changed[1].text = changed[1].text.replacingOccurrences(of: old, with: new, options: .literal)
        return DocumentContent(title: "Tide Tables", author: "Test Author", chapters: changed)
    }

    /// A chapter made of sections that each start with a level-one heading,
    /// with heading offsets measured from the assembled text.
    private static func chapter(sections: [(heading: String, body: String)]) -> Chapter {
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
    private func silence(_ reader: ReaderViewModel) {
        reader.stop()
        reader.chapterPlaybackGeneration += 1
    }

    /// Let queued main-queue work run, such as the speech service's state
    /// reaching the reader's Playing state. Only for a test whose reader has
    /// nothing that could start speech meanwhile.
    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    /// Run `body` with a loaded, in-memory text reader over `chapters`, whose
    /// look-ahead renders wait in the `HeldRenderQueue` passed alongside it,
    /// then close it.
    ///
    /// The reader has a substitution service of its own, with no store, so
    /// a test's changes reach nothing else. Preferences live in a private
    /// sandboxed store, and the reader posts and observes on its own
    /// notification center. VoiceOver announcements are recorded instead of
    /// spoken.
    ///
    /// - Parameters:
    ///   - chapters: The book's chapters, in reading order.
    ///   - skippedHeadings: Text of every heading whose section is skipped.
    ///   - substitutions: The reader's text substitution rules.
    private func withReader(
        chapters: [Chapter] = SpeechPreparationCacheTests.chapters,
        skipping skippedHeadings: Set<String> = [],
        substitutions: [SubstitutionRule] = [],
        _ body: (ReaderViewModel, HeldRenderQueue) throws -> Void
    ) throws {
        let defaults = makeSandboxedPreferences("speech-preparation-cache")
        defaults.set(0.0, forKey: SettingsPolicy.punctuationPauseLevel.key)
        let settings = SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false,
            userDefaults: defaults
        )

        let content = DocumentContent(title: "Tide Tables", author: "Test Author", chapters: chapters)
        // A unique missing path keeps the reader's own loader from replacing
        // this content or sharing persisted state with another fixture.
        var book = Book(
            title: "Tide Tables",
            format: .txt,
            filePath: "/tmp/\(UUID().uuidString)-tide-tables.txt",
            md5Hash: UUID().uuidString
        )
        book.skippedHeadingIDs = content.allHeadings
            .filter { skippedHeadings.contains($0.text) }
            .map(\.id)
        let library = LibraryViewModel()
        library.library = Library(books: [book])

        let renders = HeldRenderQueue()
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: library,
            settingsViewModel: settings,
            substitutionService: TextSubstitutionService(rules: substitutions),
            notificationCenter: NotificationCenter(),
            renderScheduler: renders
        )
        reader.content = content
        reader.isLoading = false
        defer { reader.close() }
        try recordingAnnouncements {
            try body(reader, renders)
        }
    }
}
