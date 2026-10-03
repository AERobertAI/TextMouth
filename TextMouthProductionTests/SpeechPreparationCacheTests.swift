import Foundation
import XCTest
@testable import TextMouth

/// A reader prepares each chapter's speech once while everything it is
/// prepared from stays the same, carries the look-ahead's speech to the
/// chapter's end, prepares a long chapter for the look-ahead off the main
/// actor, and refreshes the look-ahead for another voice only (PERF02).
///
/// The oracle (`legacyPreparedSpeech`) is the pipeline as it was before,
/// with nothing kept: whatever was changed, and in whatever order, what the
/// reader hands the speech engine is exactly what that pipeline makes from
/// the settings in force.
///
/// Look-ahead renders wait in a stand-in queue, and speech a test starts is
/// stopped before the main run loop turns, so nothing is heard.
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
            ("rule edited", { $0.substitutionService.rules[0].replacement = "port" }),
            ("rule switched off", { $0.substitutionService.rules[0].isEnabled = false }),
            ("rules reordered", { $0.substitutionService.rules.swapAt(0, 1) }),
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
                { $0.substitutionService.rules[0].isEnabled.toggle() },
                { $0.substitutionService.rules.swapAt(0, 1) },
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
                fileMetadata: nil,
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
        let text = content.chapters[chapterIndex].text
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
        chapter(sections: [
            ("Harbour", "Gulls circled the harbour wall. Then rain came, briefly.\n\n* * * * * * *"),
            ("Market", "Fish sold out by nine at the Caf\u{00E9} Brennan."),
        ]),
        chapter(sections: [("Evening", "Lamps came on along the pier.")]),
    ]

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
