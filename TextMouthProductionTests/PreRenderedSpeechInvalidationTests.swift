import AVFoundation
import XCTest
@testable import TextMouth

/// Rendered speech carries a signature of everything its audio depends on:
/// the exact spoken text and the voice. Pre-rendered audio is played only for
/// speech with the same signature, so a change to the voice, a substitution
/// rule, the punctuation pauses, or the skipped sections after a chapter was
/// rendered ahead can never make it play audio that disagrees with the text,
/// offsets, and settings in effect.
///
/// Renders go through stand-ins, never the system speech synthesizer.
@MainActor
final class PreRenderedSpeechInvalidationTests: XCTestCase {

    // MARK: - Signature equality and hashing

    /// The same text rendered with the same voice has one signature, which
    /// hashes alike, so it works as a set member and dictionary key.
    func testSameTextAndVoiceShareOneSignature() {
        let first = SpeechRenderSignature(text: "The ferry left at noon.", voiceIdentifier: "voice.a")
        let second = SpeechRenderSignature(text: "The ferry left at noon.", voiceIdentifier: "voice.a")

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.hashValue, second.hashValue)
        XCTAssertEqual(Set([first, second]).count, 1)
    }

    /// Any change to the text changes the signature: a different character
    /// at the same length, and a different length.
    func testAnyChangeToTheTextChangesTheSignature() {
        let original = SpeechRenderSignature(text: "The ferry left at noon.", voiceIdentifier: "voice.a")
        let sameLength = SpeechRenderSignature(text: "The ferry left at nine.", voiceIdentifier: "voice.a")
        let longer = SpeechRenderSignature(text: "The ferry left at noon..", voiceIdentifier: "voice.a")

        XCTAssertNotEqual(original, sameLength)
        XCTAssertEqual(original.textUTF16Length, sameLength.textUTF16Length)
        XCTAssertNotEqual(original, longer)
        XCTAssertEqual(Set([original, sameLength, longer]).count, 3)
    }

    /// The text's length is counted in UTF-16 code units, the units of every
    /// offset into spoken text, so emoji and accents count as speech does.
    func testTextLengthIsCountedInUTF16CodeUnits() {
        let signature = SpeechRenderSignature(text: "Café 🎙️", voiceIdentifier: nil)

        XCTAssertEqual(signature.textUTF16Length, "Café 🎙️".utf16.count)
    }

    /// Two encodings of the same accented letters are equal Swift strings,
    /// yet the synthesizer receives different characters, so they sign
    /// differently, even when their UTF-16 lengths agree.
    func testCanonicallyEquivalentSpellingsSignDifferently() {
        // An "a" with two combining marks, in either order: Swift treats the
        // strings as equal, but their characters differ.
        let marksInOneOrder = "a\u{0301}\u{0316}"
        let marksInTheOtherOrder = "a\u{0316}\u{0301}"
        XCTAssertEqual(marksInOneOrder, marksInTheOtherOrder)

        let first = SpeechRenderSignature(text: marksInOneOrder, voiceIdentifier: "voice.a")
        let second = SpeechRenderSignature(text: marksInTheOtherOrder, voiceIdentifier: "voice.a")

        XCTAssertEqual(first.textUTF16Length, second.textUTF16Length)
        XCTAssertNotEqual(first, second)
        // A precomposed letter and its decomposed spelling differ too.
        XCTAssertNotEqual(
            SpeechRenderSignature(text: "\u{00E9}", voiceIdentifier: nil),
            SpeechRenderSignature(text: "e\u{0301}", voiceIdentifier: nil)
        )
    }

    /// The same text in another voice is other audio, and the system's
    /// default voice is a voice of its own.
    func testAnotherVoiceChangesTheSignature() {
        let text = "The ferry left at noon."
        let first = SpeechRenderSignature(text: text, voiceIdentifier: "voice.a")

        XCTAssertNotEqual(first, SpeechRenderSignature(text: text, voiceIdentifier: "voice.b"))
        XCTAssertNotEqual(first, SpeechRenderSignature(text: text, voiceIdentifier: nil))
        XCTAssertEqual(
            SpeechRenderSignature(text: text, voiceIdentifier: nil),
            SpeechRenderSignature(text: text, voiceIdentifier: nil)
        )
    }

    /// A render request signs exactly the text and voice it hands the
    /// synthesizer.
    func testRenderRequestSignsItsTextAndVoice() {
        let voice = AVSpeechSynthesisVoice.speechVoices().first
        let request = SpeechRenderRequest(text: "Harbour lights.", voice: voice)

        XCTAssertEqual(
            request.signature,
            SpeechRenderSignature(text: "Harbour lights.", voiceIdentifier: voice?.identifier)
        )
        XCTAssertEqual(
            SpeechRenderRequest(text: "Harbour lights.", voice: nil).signature,
            SpeechRenderSignature(text: "Harbour lights.", voiceIdentifier: nil)
        )
    }

    // MARK: - Look-ahead renders

    /// The look-ahead renders the next chapter's prepared speech, exactly as
    /// playback would speak it, in the voice chosen now.
    func testLookAheadRendersTheNextChaptersPreparedSpeech() throws {
        try withReader(punctuationPauseLevel: 2) { reader, renders in
            startSpeakingSilently(reader)

            let request = try XCTUnwrap(renders.requested.first?.request)
            XCTAssertEqual(renders.requested.count, 1)
            XCTAssertEqual(reader.lookAhead?.chapterIndex, 1)
            XCTAssertEqual(request.text, reader.preparedSpeech(forChapterAt: 1)?.text)
            XCTAssertEqual(request.voice?.identifier, reader.speechService.currentVoice?.identifier)
        }
    }

    /// Discarding the look-ahead abandons a render still running: the render
    /// installs no audio, and nothing is looked ahead to.
    func testDiscardingTheLookAheadAbandonsARenderStillRunning() throws {
        try withReader { reader, renders in
            startSpeakingSilently(reader)
            let running = try XCTUnwrap(renders.startNext())

            reader.discardLookAhead()
            renders.finishRunning()

            XCTAssertNil(reader.lookAhead)
            XCTAssertFalse(running.engine.hasRenderedAudio)
        }
    }

    /// Moving to another chapter discards the look-ahead the same way, even
    /// while its render is still running.
    func testNavigatingToAnotherChapterAbandonsTheLookAhead() throws {
        try withReader { reader, renders in
            startSpeakingSilently(reader)
            let running = try XCTUnwrap(renders.startNext())
            // Stopped, so moving to another chapter starts no speech.
            reader.speechService.isSpeaking = false

            reader.navigateTo(chapterIndex: 2, characterOffset: 0)
            renders.finishRunning()

            XCTAssertNil(reader.lookAhead)
            XCTAssertFalse(running.engine.hasRenderedAudio)
        }
    }

    /// A look-ahead chosen again is a new render even for the same chapter:
    /// the render it replaced never starts.
    func testAReplacedLookAheadNeverStartsEvenForTheSameChapter() throws {
        try withReader { reader, renders in
            startSpeakingSilently(reader)
            reader.preRenderNextChapter()

            let started = renders.startNext()

            XCTAssertEqual(renders.requested.count, 2)
            XCTAssertTrue(started?.engine === renders.requested[1].engine)
            XCTAssertTrue(reader.lookAhead?.engine === renders.requested[1].engine)
        }
    }

    /// With nothing changed, the finished look-ahead is adopted the moment
    /// its chapter begins: its audio plays at once, the offsets are those of
    /// the chapter's prepared speech, and the chapter after it is looked
    /// ahead to next.
    func testAFinishedLookAheadIsAdoptedWhenItsChapterBegins() throws {
        try withReader { reader, renders in
            startSpeakingSilently(reader)
            renders.renderNext()
            let expected = try XCTUnwrap(reader.preparedSpeech(forChapterAt: 1))

            let start = finishChapter(reader)

            XCTAssertEqual(start.chapterIndex, 1)
            XCTAssertTrue(start.isSpeaking)
            XCTAssertEqual(start.adoptedSignature, renders.requested[0].request.signature)
            XCTAssertEqual(start.spokenText, expected.text)
            XCTAssertEqual(start.offsetMap, expected.offsetMap)
            XCTAssertEqual(renders.requested.count, 2)
            XCTAssertEqual(renders.requested.last?.request.text, reader.preparedSpeech(forChapterAt: 2)?.text)
        }
    }

    // MARK: - Inputs changed after the next chapter was queued

    // Each test holds the look-ahead render, changes one setting that shapes
    // the next chapter's audio while the render runs or after it finished,
    // and then ends the chapter. Audio rendered before the change must never
    // play: the next chapter starts from its current text, with the offsets
    // of its prepared speech.

    /// A voice chosen for the book never plays the chapter in the old voice.
    func testChoosingAnotherVoiceNeverPlaysAudioInTheOldVoice() throws {
        for timing in ChangeTiming.allCases {
            try assertStaleLookAheadIsNotPlayed(when: timing) { reader in
                reader.setLocalVoice(try self.anotherVoice(than: reader))
            }
        }
    }

    /// A substitution rule added in Settings applies to the next chapter.
    func testAddingASubstitutionRuleNeverPlaysTheUnsubstitutedAudio() throws {
        for timing in ChangeTiming.allCases {
            try assertStaleLookAheadIsNotPlayed(when: timing) { reader in
                reader.substitutionService.rules.append(Self.seabirdsForGulls)
            }
        }
    }

    /// An edited replacement applies to the next chapter.
    func testEditingASubstitutionRuleNeverPlaysTheOldReplacement() throws {
        for timing in ChangeTiming.allCases {
            try assertStaleLookAheadIsNotPlayed(when: timing) { reader in
                reader.substitutionService.rules[0].replacement = "port"
            }
        }
    }

    /// A rule switched off no longer applies to the next chapter.
    func testDisablingASubstitutionRuleNeverPlaysTheSubstitutedAudio() throws {
        for timing in ChangeTiming.allCases {
            try assertStaleLookAheadIsNotPlayed(when: timing) { reader in
                reader.substitutionService.rules[0].isEnabled = false
            }
        }
    }

    /// A new punctuation pause level applies to the next chapter.
    func testChangingThePunctuationPausesNeverPlaysTheOldPauses() throws {
        for timing in ChangeTiming.allCases {
            try assertStaleLookAheadIsNotPlayed(when: timing) { reader in
                reader.settingsViewModel.punctuationPauseLevel = 2
            }
        }
    }

    /// A section skipped in the next chapter is not heard.
    func testSkippingASectionNeverPlaysTheSkippedSection() throws {
        for timing in ChangeTiming.allCases {
            try assertStaleLookAheadIsNotPlayed(when: timing) { reader in
                reader.toggleHeadingSkip(try XCTUnwrap(reader.headings.first { $0.text == "Market" }))
            }
        }
    }

    /// A section included again in the next chapter is heard.
    func testIncludingASectionAgainNeverPlaysTheChapterWithoutIt() throws {
        for timing in ChangeTiming.allCases {
            try assertStaleLookAheadIsNotPlayed(when: timing, skipping: ["Market"]) { reader in
                reader.toggleHeadingSkip(try XCTUnwrap(reader.headings.first { $0.text == "Market" }))
            }
        }
    }

    /// Speed is applied as the audio plays, not when it is rendered, so a
    /// speed chosen while the next chapter renders keeps its instant start,
    /// and the chapter plays at the new speed.
    func testChoosingASpeedWhileRenderingKeepsTheInstantStartAtTheNewSpeed() throws {
        try withReader { reader, renders in
            startSpeakingSilently(reader)
            let render = try XCTUnwrap(renders.startNext())
            let newSpeed: Double = reader.speechService.wordsPerMinute == 300 ? 400 : 300
            reader.adjustSpeed(delta: newSpeed - reader.speechService.wordsPerMinute)
            renders.finishRunning()

            let start = finishChapter(reader)

            XCTAssertEqual(reader.speechService.wordsPerMinute, newSpeed)
            XCTAssertEqual(start.adoptedSignature, render.request.signature)
            XCTAssertEqual(
                Double(start.playbackRate),
                AudioEngineService.speedMultiplier(
                    wpm: newSpeed,
                    renderWPM: reader.speechService.audioEngine.renderWPM
                ),
                accuracy: 0.0001
            )
        }
    }

    /// Pitch is applied as the audio plays as well, so a pitch chosen after
    /// the next chapter rendered keeps its instant start at the new pitch.
    func testChoosingAPitchAfterRenderingKeepsTheInstantStartAtTheNewPitch() throws {
        try withReader { reader, renders in
            startSpeakingSilently(reader)
            renders.renderNext()
            let newPitch = reader.speechService.pitchMultiplier < 1.5 ? 1.8 : 0.8
            reader.adjustPitch(to: newPitch)

            let start = finishChapter(reader)

            XCTAssertEqual(start.adoptedSignature, renders.requested[0].request.signature)
            XCTAssertEqual(
                Double(start.playbackPitchCents),
                AudioEngineService.pitchCents(for: newPitch),
                accuracy: 0.01
            )
        }
    }

    /// A render whose inputs changed while it ran is dropped as it finishes,
    /// although it produced audio, so it is never kept as the look-ahead.
    func testARenderWhoseInputsChangedWhileItRanIsDroppedWhenItFinishes() throws {
        try withReader { reader, renders in
            startSpeakingSilently(reader)
            let running = try XCTUnwrap(renders.startNext())
            reader.settingsViewModel.punctuationPauseLevel = 2

            renders.finishRunning()

            XCTAssertTrue(running.engine.hasRenderedAudio)
            XCTAssertNil(reader.lookAhead)
        }
    }

    /// A look-ahead render that fails leaves nothing to look ahead to, and
    /// its chapter starts from its text.
    func testAFailedRenderLeavesItsChapterToStartFromItsText() throws {
        try withReader { reader, renders in
            startSpeakingSilently(reader)
            renders.startNext()
            renders.finishRunning(succeeding: false)
            let current = try XCTUnwrap(reader.preparedSpeech(forChapterAt: 1))

            let start = finishChapter(reader)

            XCTAssertNil(start.adoptedSignature)
            XCTAssertEqual(start.chapterIndex, 1)
            XCTAssertEqual(start.spokenText, current.text)
            XCTAssertEqual(start.offsetMap, current.offsetMap)
        }
    }

    // MARK: - Fixtures

    /// When a setting changes relative to the look-ahead render.
    private enum ChangeTiming: String, CaseIterable, CustomStringConvertible {
        case whileRendering = "while rendering"
        case afterRendering = "after rendering"

        var description: String { rawValue }
    }

    /// Respells "harbour", which the next chapter says twice.
    private static let harbourSpelling = SubstitutionRule(
        name: "Harbour spelling",
        pattern: "harbour",
        replacement: "harbor"
    )

    /// Replaces a word only the next chapter contains.
    private static let seabirdsForGulls = SubstitutionRule(
        name: "Seabirds",
        pattern: "Gulls",
        replacement: "Seabirds"
    )

    /// An installed voice other than the one `reader` speaks with now; the
    /// test is skipped on a Mac with a single voice.
    private func anotherVoice(than reader: ReaderViewModel) throws -> AVSpeechSynthesisVoice {
        let current = reader.speechService.currentVoice?.identifier
        guard let voice = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.identifier != current }) else {
            throw XCTSkip("Changing voices needs a second installed voice")
        }
        return voice
    }

    /// Check the acceptance scenario for one setting that shapes the audio:
    /// hold the look-ahead render, apply `change` while it runs or after it
    /// finished, end the chapter, and require that the audio rendered before
    /// the change is not played and that the next chapter starts from its
    /// current text with the offsets of its prepared speech.
    ///
    /// Substitution rule `harbourSpelling` applies throughout.
    ///
    /// - Parameters:
    ///   - timing: Whether `change` is applied while the render runs or once
    ///     it has finished.
    ///   - skippedHeadings: Sections skipped before playback begins.
    ///   - change: Changes one setting, as the listener would.
    private func assertStaleLookAheadIsNotPlayed(
        when timing: ChangeTiming,
        skipping skippedHeadings: Set<String> = [],
        file: StaticString = #filePath,
        line: UInt = #line,
        _ change: (ReaderViewModel) throws -> Void
    ) throws {
        try withReader(skipping: skippedHeadings, substitutions: [Self.harbourSpelling]) { reader, renders in
            startSpeakingSilently(reader)
            let staleRender = try XCTUnwrap(renders.startNext(), file: file, line: line)
            if timing == .afterRendering {
                renders.finishRunning()
            }
            try change(reader)
            if timing == .whileRendering {
                renders.finishRunning()
            }
            XCTAssertNotEqual(
                reader.currentRenderSignature(forChapterAt: 1),
                staleRender.request.signature,
                "\(timing): the change should alter the next chapter's audio",
                file: file,
                line: line
            )
            let current = try XCTUnwrap(reader.preparedSpeech(forChapterAt: 1), file: file, line: line)

            let start = finishChapter(reader)

            XCTAssertEqual(start.chapterIndex, 1, "\(timing)", file: file, line: line)
            XCTAssertTrue(start.isSpeaking, "\(timing)", file: file, line: line)
            XCTAssertNil(
                start.adoptedSignature,
                "\(timing): audio rendered before the change was played",
                file: file,
                line: line
            )
            XCTAssertEqual(start.spokenText, current.text, "\(timing)", file: file, line: line)
            XCTAssertEqual(start.offsetMap, current.offsetMap, "\(timing)", file: file, line: line)
        }
    }

    /// Three chapters made of headed sections. The middle one, the first
    /// chapter's look-ahead, has sentence and comma punctuation for the pause
    /// levels and a word for a substitution rule to replace.
    private static let harbourChapters: [Chapter] = [
        chapter(sections: [
            ("Departure", "The ferry left the quay at noon."),
            ("Crossing", "Spray rose over the bow."),
        ]),
        chapter(sections: [
            ("Harbour", "Gulls circled the harbour wall. Then rain came, briefly."),
            ("Market", "Fish sold out by nine."),
        ]),
        chapter(sections: [("Evening", "Lamps came on along the pier.")]),
    ]

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

    /// Run `body` with a loaded, in-memory text reader over `chapters`, whose
    /// look-ahead renders wait in the `HeldRenderQueue` passed alongside it,
    /// then close the reader and remove its preferences and config file.
    ///
    /// Preferences live in a private suite mirrored to a config file of the
    /// test's own, and the reader posts and observes on its own notification
    /// center, so a setting a test changes never reaches the user's settings
    /// or the running app. VoiceOver announcements are recorded instead of
    /// spoken.
    ///
    /// - Parameters:
    ///   - chapters: The book's chapters, in reading order.
    ///   - skippedHeadings: Text of every heading whose section is skipped.
    ///   - punctuationPauseLevel: The global punctuation pause level.
    ///   - substitutions: The reader's text substitution rules.
    private func withReader(
        chapters: [Chapter] = PreRenderedSpeechInvalidationTests.harbourChapters,
        skipping skippedHeadings: Set<String> = [],
        punctuationPauseLevel: Double = 0,
        substitutions: [SubstitutionRule] = [],
        _ body: (ReaderViewModel, HeldRenderQueue) throws -> Void
    ) throws {
        let suiteName = "com.textmouth.tests.pre-rendered-speech.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(punctuationPauseLevel, forKey: SettingsPolicy.punctuationPauseLevel.key)
        let configFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("pre-rendered-speech-\(UUID().uuidString).json")
        let settings = SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false,
            userDefaults: defaults,
            configService: ConfigService(fileURL: configFile)
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
        defer {
            reader.close()
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: configFile)
        }
        try recordingAnnouncements {
            try body(reader, renders)
        }
    }

    /// Put `reader` in the state of speaking its first chapter without the
    /// synthesizer: its speech counts as active, and the chapter after it is
    /// chosen and queued to render ahead, as starting a chapter does.
    private func startSpeakingSilently(_ reader: ReaderViewModel) {
        reader.speechService.isSpeaking = true
        reader.preRenderNextChapter()
    }

    /// What the reader started when a chapter ended.
    private struct ChapterStart {
        /// The chapter that began.
        let chapterIndex: Int
        /// The text the speech service was given for it.
        let spokenText: String?
        /// The reader's map between that text and the chapter's own text.
        let offsetMap: ComposedOffsetMap?
        /// The signature of the pre-rendered audio the speech service adopted
        /// to play the chapter, or nil when the chapter began without any.
        let adoptedSignature: SpeechRenderSignature?
        /// Whether speech was active once the chapter began.
        let isSpeaking: Bool
        /// The time-pitch unit's rate and pitch, in cents, applied to that
        /// audio as it plays.
        let playbackRate: Float
        let playbackPitchCents: Float
    }

    /// End the chapter being spoken the way the speech service reports it,
    /// record what the reader started next, and silence it before the main
    /// run loop turns, so the synthesizer is never heard. Advancing the
    /// playback generation also keeps queued renders from starting.
    private func finishChapter(_ reader: ReaderViewModel) -> ChapterStart {
        reader.speechService.stop()
        reader.speechService.onUtteranceFinished?()
        let start = ChapterStart(
            chapterIndex: reader.currentChapterIndex,
            spokenText: reader.currentTransformation?.modifiedText,
            offsetMap: reader.currentOffsetMap,
            adoptedSignature: reader.speechService.audioEngine.renderedSignature,
            isSpeaking: reader.speechService.isSpeaking,
            playbackRate: reader.speechService.audioEngine.playbackRate,
            playbackPitchCents: reader.speechService.audioEngine.playbackPitchCents
        )
        reader.stop()
        reader.chapterPlaybackGeneration += 1
        return start
    }
}

// MARK: - Test doubles

/// Stands in for the shared render queue: it keeps every look-ahead render
/// the reader asks for until the test lets it start and finish, and renders
/// nothing itself.
///
/// Turns follow the shared queue's rules. When a render's turn comes it
/// starts only if it is still wanted, and otherwise reports failure without
/// starting. A finished render installs stand-in audio carrying its request's
/// signature, as a real render records it, unless its engine abandoned it
/// (`cancelRender`); it reports success only if it produced audio and is
/// still wanted when it finishes.
@MainActor
final class HeldRenderQueue: SpeechRenderScheduling {
    /// One render the reader asked for.
    struct Render {
        let request: SpeechRenderRequest
        let engine: AudioEngineService
        let shouldStart: @MainActor @Sendable () -> Bool
        let completion: @MainActor @Sendable (Bool) -> Void
    }

    /// Every render asked for, oldest first, whether or not it has run.
    private(set) var requested: [Render] = []
    /// Renders waiting for their turn, oldest first.
    private var waiting: [Render] = []
    /// The render that has started and not yet finished.
    private(set) var running: Render?

    /// Keep the render until the test gives it a turn.
    func render(
        _ request: SpeechRenderRequest,
        engine: AudioEngineService,
        shouldStart: @escaping @MainActor @Sendable () -> Bool,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        let render = Render(request: request, engine: engine, shouldStart: shouldStart, completion: completion)
        requested.append(render)
        waiting.append(render)
    }

    /// Give waiting renders their turns, oldest first, until one starts. A
    /// render no longer wanted reports failure and passes its turn on.
    ///
    /// - Returns: The render now running, or nil when none was still wanted.
    @discardableResult
    func startNext() -> Render? {
        XCTAssertNil(running, "The shared queue runs one render at a time")
        while !waiting.isEmpty {
            let render = waiting.removeFirst()
            guard render.shouldStart() else {
                render.completion(false)
                continue
            }
            // A real engine reports it is rendering until it finishes or its
            // render is abandoned, which clears this.
            render.engine.isRendering = true
            running = render
            return render
        }
        return nil
    }

    /// Finish the running render.
    ///
    /// - Parameter succeeding: Whether the synthesizer produced audio.
    func finishRunning(succeeding: Bool = true) {
        guard let render = running else {
            XCTFail("No render is running")
            return
        }
        running = nil
        let wasAbandoned = !render.engine.isRendering
        render.engine.isRendering = false
        let producedAudio = succeeding && !wasAbandoned
        if producedAudio {
            render.engine._installRenderedAudioForTesting(signature: render.request.signature)
        }
        render.completion(render.shouldStart() && producedAudio)
    }

    /// Start the oldest render still wanted and finish it successfully.
    func renderNext() {
        guard startNext() != nil else { return }
        finishRunning()
    }
}
