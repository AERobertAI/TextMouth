import AVFoundation
import XCTest
@testable import TextMouth

/// Speaking a chapter of a speech export (FMT43) into a 16-bit CAF through
/// the synthesizer seam (`SpeechBufferSynthesizing`): one file of the
/// chapter's speech and silence, the reader's chunks, the markup guard and
/// its one strict retry, Stop, the failures and their words, and the
/// progress heard after each buffer.
///
/// Every test uses `FakeSpeechBufferSynthesizer`, which makes a quiet tone
/// in memory, or gives the Mac's synthesizer a voice it refuses before any
/// synthesizer exists: no test runs a real synthesizer or makes a sound,
/// except the opt-in last one, skipped unless
/// `TEXTMOUTH_REAL_SPEECH_EXPORT=1`, which writes a real voice into a file
/// and plays nothing. Every file goes in a sandbox folder.
final class SpeechChapterRendererTests: XCTestCase {

    /// The voice every utterance names: no voice has it, and no test speaks
    /// in one.
    private static let voice = "com.textmouth.tests.voice.speech-export"
    /// The title of the chapter every test renders.
    private static let title = "4. Tolls on the Old Causeway"

    /// `text` as an utterance in the tests' voice at the rate for 250 words
    /// a minute and the pitch 1.3, as every render here speaks.
    private static func utterance(_ text: String) -> SpeechExportUtterance {
        SpeechExportUtterance(
            text: text,
            voiceIdentifier: voice,
            rate: SpeechService.rateForWPM(250),
            pitchMultiplier: Float(SpeechService.clampedPitch(1.3))
        )
    }

    /// `text` guarded as every render begins.
    private static func markup(_ text: String) -> String {
        AudioEngineService.RenderGuard.markup.apply(to: text)
    }

    /// `text` guarded with every bracket silent, as a refused render is
    /// tried again.
    private static func strict(_ text: String) -> String {
        AudioEngineService.RenderGuard.everyBracket.apply(to: text)
    }

    /// `texts` rendered as the chapter `title` into `url`, in the tests'
    /// voice at 250 words a minute and the pitch 1.3. Static, so a test can
    /// render on a queue of its own.
    private static func render(
        _ texts: [String],
        with synthesizer: any SpeechBufferSynthesizing,
        to url: URL,
        trailingSilence: TimeInterval = 0,
        maximumUtteranceLength: Int = SpeechRenderCoordinator.maximumTextLength,
        cancellation: BookExportCancellation = BookExportCancellation(),
        framesWritten: @escaping (Int64) -> Void = { _ in }
    ) throws -> RenderedSpeechChapter {
        try SpeechChapterRenderer.render(
            title: title,
            texts: texts,
            voiceIdentifier: voice,
            wordsPerMinute: 250,
            pitch: 1.3,
            trailingSilence: trailingSilence,
            to: url,
            synthesizer: synthesizer,
            maximumUtteranceLength: maximumUtteranceLength,
            cancellation: cancellation,
            framesWritten: framesWritten
        )
    }

    /// Where a chapter's file goes: a CAF path in a new sandbox folder, with
    /// nothing there yet.
    private func makeChapterURL() throws -> URL {
        try makeSandboxDirectory("SpeechChapterRenderer").appendingPathComponent("chapter.caf")
    }

    /// Every frame of the one-channel audio file at `url`, as 16-bit
    /// samples.
    private func sixteenBitSamples(at url: URL) throws -> [Int16] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        )
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.int16ChannelData?.pointee)
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    /// The loudest of `samples`, as a magnitude.
    private static func peak(of samples: some Sequence<Int16>) -> Int {
        samples.map { abs(Int($0)) }.max() ?? 0
    }

    /// Asserts that nothing is at `url`.
    private func assertNoFile(at url: URL, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "nothing is left at \(url.lastPathComponent)", file: file, line: line)
    }

    // MARK: - The Seam

    /// The fake hands over `framesPerUnit` frames of tone for each UTF-16
    /// unit, in pieces of the size asked for and of the kind and rate asked
    /// for; hands over nothing for an utterance it refuses; and records every
    /// utterance, refused ones too.
    func testTheFakeSpeaksItsToneInPiecesAndRecordsEveryUtterance() throws {
        let refusedText = "Refused at the gate."
        let fake = FakeSpeechBufferSynthesizer(
            framesPerUnit: 10,
            pieceFrameCount: 40,
            commonFormat: .pcmFormatInt16,
            sampleRate: { _ in 16_000 },
            refuses: { $0.text == refusedText }
        )
        // Ten units: 100 frames, in pieces of 40, 40, and 20.
        let spoken = Self.utterance("Ninety-one")
        var pieces: [AVAudioPCMBuffer] = []
        let spokenEnd = try fake.write(spoken, cancellation: BookExportCancellation()) { pieces.append($0) }
        XCTAssertEqual(spokenEnd, .finished)
        XCTAssertEqual(pieces.map(\.frameLength), [40, 40, 20])
        XCTAssertTrue(pieces.allSatisfy { $0.format.commonFormat == .pcmFormatInt16 && $0.format.sampleRate == 16_000 })
        XCTAssertTrue(pieces.allSatisfy { $0.format.channelCount == 1 })

        let refused = Self.utterance(refusedText)
        let refusedEnd = try fake.write(refused, cancellation: BookExportCancellation()) { _ in
            XCTFail("a refused utterance hands over no buffer")
        }
        XCTAssertEqual(refusedEnd, .refused)
        XCTAssertEqual(fake.written, [spoken, refused])
    }

    /// Stop pressed before a write or between its buffers ends the fake's
    /// write with `CancellationError`.
    func testTheFakeStopsAtTheCancellationBetweenItsBuffers() throws {
        let cancellation = BookExportCancellation()
        let fake = FakeSpeechBufferSynthesizer(framesPerUnit: 10, pieceFrameCount: 40)
        var pieceCount = 0
        XCTAssertThrowsError(
            try fake.write(Self.utterance("Ninety-one"), cancellation: cancellation) { _ in
                pieceCount += 1
                cancellation.cancel()
            }
        ) { error in
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(pieceCount, 1, "Stop is noticed before the next buffer")

        XCTAssertThrowsError(
            try fake.write(Self.utterance("Ninety-two"), cancellation: cancellation) { _ in
                XCTFail("a write after Stop hands over no buffer")
            }
        ) { error in
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    /// The Mac's synthesizer refuses a voice that is not installed before it
    /// makes any synthesizer, so nothing can speak, and never hands a buffer
    /// on.
    func testTheMacsSynthesizerRefusesAVoiceThatIsNotInstalled() {
        let utterance = SpeechExportUtterance(
            text: "Nothing is said.",
            voiceIdentifier: "com.textmouth.tests.voice.not-installed",
            rate: 0.5,
            pitchMultiplier: 1
        )
        XCTAssertThrowsError(
            try SystemSpeechBufferSynthesizer().write(utterance, cancellation: BookExportCancellation()) { _ in
                XCTFail("no buffer comes for a voice that is not installed")
            }
        ) { error in
            XCTAssertEqual(error as? SpeechWriteFailure, .unusableVoice)
        }
    }

    // MARK: - The Chapter's File

    /// Two texts make one CAF of 16-bit integer linear PCM at the voice's
    /// 22,050 Hz, one channel, holding the fake's tone and then half a
    /// second of silence; the result says so; and each utterance is its text
    /// guarded, in the voice, at the rate for 250 words a minute and the
    /// pitch 1.3.
    func testTwoTextsMakeOneSixteenBitFileOfTheirSpeechAndTheSilence() throws {
        let first = "Tolls rose twice on the causeway this winter."
        let second = "The clerk stamped </sm> on every docket and waved the carts through."
        XCTAssertNotEqual(Self.markup(second), second, "the guard makes the stray closing tag harmless")
        let fake = FakeSpeechBufferSynthesizer()
        let url = try makeChapterURL()

        let rendered = try Self.render([first, second], with: fake, to: url, trailingSilence: 0.5)

        XCTAssertEqual(fake.written, [Self.utterance(Self.markup(first)), Self.utterance(Self.markup(second))])
        // The guard keeps every length, so the fake made 40 frames a unit of
        // the texts themselves; half a second at 22,050 Hz is 11,025 frames.
        let speechFrames = Int64((first.utf16.count + second.utf16.count) * 40)
        let silenceFrames: Int64 = 11_025
        XCTAssertEqual(
            rendered,
            RenderedSpeechChapter(frameCount: speechFrames + silenceFrames, sampleRate: 22_050, channelCount: 1)
        )

        let file = try AVAudioFile(forReading: url)
        let stored = file.fileFormat.streamDescription.pointee
        XCTAssertEqual(stored.mFormatID, kAudioFormatLinearPCM)
        XCTAssertEqual(stored.mBitsPerChannel, 16)
        XCTAssertNotEqual(stored.mFormatFlags & kAudioFormatFlagIsSignedInteger, 0, "integer samples")
        XCTAssertEqual(stored.mFormatFlags & kAudioFormatFlagIsFloat, 0, "not float samples")
        XCTAssertEqual(stored.mFormatFlags & kAudioFormatFlagIsBigEndian, 0, "little-endian")
        XCTAssertEqual(file.fileFormat.commonFormat, .pcmFormatInt16)
        XCTAssertEqual(file.fileFormat.sampleRate, 22_050)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.length, speechFrames + silenceFrames)

        // The speech is the fake's quiet tone, a tenth of full scale, and
        // the silence is silent.
        let samples = try sixteenBitSamples(at: url)
        XCTAssertEqual(Int64(samples.count), speechFrames + silenceFrames)
        XCTAssertTrue((3_000...3_400).contains(Self.peak(of: samples.prefix(Int(speechFrames)))))
        XCTAssertTrue(samples.suffix(Int(silenceFrames)).allSatisfy { $0 == 0 }, "the silence is zeroed")
    }

    /// Buffers of 16-bit samples, as some voices write, make the same file;
    /// a quarter of a second of silence at 22,050 Hz, 5,512.5 frames, is
    /// rounded to 5,513.
    func testSixteenBitBuffersAreWrittenToo() throws {
        let text = "Weighbridge tickets are kept for a year."
        let fake = FakeSpeechBufferSynthesizer(commonFormat: .pcmFormatInt16)
        let url = try makeChapterURL()

        let rendered = try Self.render([text], with: fake, to: url, trailingSilence: 0.25)

        let speechFrames = Int64(text.utf16.count * 40)
        XCTAssertEqual(rendered, RenderedSpeechChapter(frameCount: speechFrames + 5_513, sampleRate: 22_050, channelCount: 1))
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.commonFormat, .pcmFormatInt16)
        XCTAssertEqual(file.length, speechFrames + 5_513)
        let samples = try sixteenBitSamples(at: url)
        XCTAssertTrue((3_000...3_400).contains(Self.peak(of: samples.prefix(Int(speechFrames)))))
        XCTAssertTrue(samples.suffix(5_513).allSatisfy { $0 == 0 }, "the silence is zeroed")
    }

    /// A silence of no length, a negative one, or one that is not a number
    /// adds no frames.
    func testASilenceThatIsNotAPositiveLengthAddsNoFrames() throws {
        let text = "The barrier lifts."
        for silence: TimeInterval in [0, -1, .nan] {
            let url = try makeChapterURL()
            let rendered = try Self.render([text], with: FakeSpeechBufferSynthesizer(), to: url, trailingSilence: silence)
            XCTAssertEqual(rendered.frameCount, Int64(text.utf16.count * 40), "a silence of \(silence) seconds")
            XCTAssertEqual(try AVAudioFile(forReading: url).length, Int64(text.utf16.count * 40), "\(silence)")
        }
    }

    // MARK: - Utterances

    /// A text longer than the utterance limit is spoken in exactly the
    /// reader's chunks (`DirectSpeechChunk`), no word cut; a chunk of white
    /// space alone, and a text of none or nothing but white space, is not
    /// spoken.
    func testALongTextIsSpokenInTheReadersChunksAndWhiteSpaceAloneIsNotSpoken() throws {
        // 120 units of white space between the sentences: more than two
        // chunks' worth, so one chunk holds white space alone.
        let long = "Harbour dues rose twice this winter, and the ferrymen grumbled about it in the queue at the weighbridge."
            + String(repeating: " \n", count: 60)
            + "Nobody expected the timetable to change before the thaw, least of all the toll keeper."
        let fake = FakeSpeechBufferSynthesizer()
        let url = try makeChapterURL()

        _ = try Self.render(["", " \n\t ", long], with: fake, to: url, maximumUtteranceLength: 50)

        // The reader's chunks of the long text, made by the reader's own
        // chunking, going on from each chunk's end.
        var chunks: [String] = []
        var offset = 0
        var chunk: DirectSpeechChunk
        repeat {
            chunk = DirectSpeechChunk.starting(at: offset, in: long, maximumLength: 50)
            chunks.append(chunk.words(of: long))
            offset = chunk.end
        } while chunk.isPartial
        let speakable = chunks.filter { ReaderViewModel.hasSpeakableText($0) }
        XCTAssertGreaterThan(chunks.count, speakable.count, "a chunk holds white space alone")
        XCTAssertGreaterThan(speakable.count, 3)

        XCTAssertEqual(fake.written, speakable.map { Self.utterance(Self.markup($0)) })
        // No word is cut: the words spoken are the text's words, whole and in
        // order.
        XCTAssertEqual(
            fake.written.flatMap { $0.text.split(whereSeparator: \.isWhitespace) },
            long.split(whereSeparator: \.isWhitespace)
        )
    }

    /// A white-space character longer than the utterance limit, here a
    /// carriage return and line feed, which is one character of two units,
    /// against a limit of one unit, is passed over rather than ending a
    /// chunk where it began and holding the render there forever.
    func testAWhiteSpaceCharacterLongerThanTheLimitIsPassedOver() throws {
        let fake = FakeSpeechBufferSynthesizer()
        let url = try makeChapterURL()
        let finished = expectation(description: "the render ends")
        finished.assertForOverFulfill = false

        // On a queue of its own, so that a render held forever fails this
        // test rather than holding the whole run.
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? Self.render(["Ab\r\ncd"], with: fake, to: url, maximumUtteranceLength: 1)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 30)

        XCTAssertEqual(fake.written.map(\.text), ["Ab", "cd"])
    }

    // MARK: - Refusals

    /// An utterance the speech engine refuses before any of its audio is
    /// written once more with every bracket silent, and the chapter is made
    /// of both texts.
    func testARefusedUtteranceIsWrittenOnceMoreWithEveryBracketSilent() throws {
        let plain = "The ferry waited at the slip."
        let bracketed = "The tide stood at 3 < 4 metres by the quay."
        XCTAssertEqual(Self.markup(bracketed), bracketed, "a lone bracket is not tag-shaped")
        XCTAssertNotEqual(Self.strict(bracketed), bracketed, "the strict guard silences every bracket")
        let fake = FakeSpeechBufferSynthesizer(refuses: { $0.text == bracketed })
        let url = try makeChapterURL()

        let rendered = try Self.render([plain, bracketed], with: fake, to: url)

        XCTAssertEqual(
            fake.written,
            [Self.utterance(Self.markup(plain)), Self.utterance(bracketed), Self.utterance(Self.strict(bracketed))]
        )
        let frames = Int64((plain.utf16.count + bracketed.utf16.count) * 40)
        XCTAssertEqual(rendered.frameCount, frames)
        XCTAssertEqual(try AVAudioFile(forReading: url).length, frames)
    }

    /// An utterance refused with every bracket silent too fails the chapter,
    /// and the file its first text was written to is removed.
    func testAnUtteranceRefusedTwiceFailsTheChapterAndLeavesNoFile() throws {
        let plain = "The ferry waited at the slip."
        let bracketed = "The tide stood at 3 < 4 metres by the quay."
        let fake = FakeSpeechBufferSynthesizer(refuses: { $0.text.contains("metres") })
        let url = try makeChapterURL()

        XCTAssertThrowsError(try Self.render([plain, bracketed], with: fake, to: url)) { error in
            XCTAssertEqual(error as? SpeechRenderFailure, .refused(Self.title))
        }
        XCTAssertEqual(fake.written.map(\.text), [Self.markup(plain), Self.markup(bracketed), Self.strict(bracketed)])
        assertNoFile(at: url)
    }

    /// An utterance refused after some of its audio was written is not
    /// tried again, since that audio cannot be taken back out of the file:
    /// the chapter fails, and its file is removed.
    func testARefusalAfterSomeAudioFailsTheChapterWithoutARetry() throws {
        let synthesizer = SpeakThenEnd(ending: { .refused })
        let url = try makeChapterURL()

        XCTAssertThrowsError(try Self.render(["The gate closed at dusk."], with: synthesizer, to: url)) { error in
            XCTAssertEqual(error as? SpeechRenderFailure, .refused(Self.title))
        }
        XCTAssertEqual(synthesizer.fake.written.count, 1, "no retry")
        assertNoFile(at: url)
    }

    // MARK: - Stop and Failures

    /// Stop pressed as the second utterance begins ends the chapter with
    /// `CancellationError`, and the file its first text was written to is
    /// removed; Stop pressed before the chapter begins hands the synthesizer
    /// nothing.
    func testStopEndsTheChapterAndLeavesNoFile() throws {
        let second = "A second cart crossed."
        let cancellation = BookExportCancellation()
        let fake = FakeSpeechBufferSynthesizer(beforeWrite: { utterance in
            if utterance.text == second {
                cancellation.cancel()
            }
        })
        let url = try makeChapterURL()

        XCTAssertThrowsError(
            try Self.render(["One cart crossed.", second, "A third cart waited."], with: fake, to: url, cancellation: cancellation)
        ) { error in
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(fake.written.map(\.text), ["One cart crossed.", second])
        assertNoFile(at: url)

        let untouched = FakeSpeechBufferSynthesizer()
        let laterURL = try makeChapterURL()
        XCTAssertThrowsError(try Self.render(["Nobody crossed."], with: untouched, to: laterURL, cancellation: cancellation)) { error in
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(untouched.written, [])
        assertNoFile(at: laterURL)
    }

    /// A voice that makes no sound for any utterance fails the chapter, once
    /// every utterance was tried.
    func testAVoiceThatMakesNoSoundFailsTheChapter() throws {
        let fake = FakeSpeechBufferSynthesizer(framesPerUnit: 0)
        let url = try makeChapterURL()

        XCTAssertThrowsError(try Self.render(["Gulls circle.", "The tide turns."], with: fake, to: url)) { error in
            XCTAssertEqual(error as? SpeechRenderFailure, .noSound(Self.title))
        }
        XCTAssertEqual(fake.written.count, 2)
        assertNoFile(at: url)
    }

    /// A second utterance at 24,000 Hz after one at 22,050 fails the chapter,
    /// and the file is removed: `AVAudioFile` would have written its frames
    /// as if they were at the first rate.
    func testAChangeOfSampleRatePartwayFailsTheChapterAndLeavesNoFile() throws {
        let faster = "The second text came out at another rate."
        let fake = FakeSpeechBufferSynthesizer(sampleRate: { $0.text == faster ? 24_000 : 22_050 })
        let url = try makeChapterURL()

        XCTAssertThrowsError(try Self.render(["The first text is ordinary.", faster], with: fake, to: url)) { error in
            XCTAssertEqual(error as? SpeechRenderFailure, .formatChanged(Self.title))
        }
        assertNoFile(at: url)
    }

    /// A synthesizer's stall after some audio becomes the chapter's own,
    /// and the file is removed; the Mac's synthesizer refusing the book's
    /// voice becomes the export's words about it.
    func testASynthesizersFailuresBecomeTheChaptersOwn() throws {
        let stalled = try makeChapterURL()
        XCTAssertThrowsError(
            try Self.render(["The gate closed at dusk."], with: SpeakThenEnd(ending: { throw SpeechWriteFailure.stalled }), to: stalled)
        ) { error in
            XCTAssertEqual(error as? SpeechRenderFailure, .stalled(Self.title))
        }
        assertNoFile(at: stalled)

        // No voice has the tests' identifier: refused before any synthesizer
        // exists, so nothing speaks.
        let unusable = try makeChapterURL()
        XCTAssertThrowsError(try Self.render(["Nothing is said."], with: SystemSpeechBufferSynthesizer(), to: unusable)) { error in
            XCTAssertEqual(error as? SpeechRenderFailure, .unusableVoice)
        }
        assertNoFile(at: unusable)
    }

    /// Every failure's words, exactly.
    func testEveryFailureSaysWhatHappenedInItsOwnWords() {
        let title = "The Weighbridge"
        let expected: [(SpeechRenderFailure, String)] = [
            (.refused(title), "The Mac's speech engine refused to speak part of “The Weighbridge”, even with its brackets made silent."),
            (.noSound(title), "The voice made no sound for “The Weighbridge”. Check that the book's voice speaks the book's language."),
            (.stalled(title), "The voice stopped partway through “The Weighbridge” and made no sound for a minute."),
            (.formatChanged(title), "The voice changed its kind of audio partway through “The Weighbridge”."),
            (
                .unusableVoice,
                "The book's voice can't be recorded to a file. "
                    + "Choose another voice for this book with the Voice button in its reader, then export again."
            ),
        ]
        for (failure, words) in expected {
            XCTAssertEqual(failure.errorDescription, words)
            XCTAssertEqual((failure as any Error).localizedDescription, words)
        }
    }

    // MARK: - Progress

    /// `framesWritten` hears the chapter's frames of speech after each
    /// buffer, rising across utterances, and ends at the speech's frames:
    /// the silence after them is in the file but not in the reports.
    func testFramesWrittenRisesWithEachBufferAndEndsAtTheSpeech() throws {
        // 25 units, 250 frames, in pieces of 100, 100, and 50; then 12 units,
        // 120 frames, in pieces of 100 and 20.
        let first = "Ropes are coiled by noon."
        let second = "Gulls circle"
        XCTAssertEqual(first.utf16.count, 25)
        XCTAssertEqual(second.utf16.count, 12)
        let fake = FakeSpeechBufferSynthesizer(framesPerUnit: 10, pieceFrameCount: 100)
        let url = try makeChapterURL()
        var reports: [Int64] = []

        let rendered = try Self.render([first, second], with: fake, to: url, trailingSilence: 1, framesWritten: { reports.append($0) })

        XCTAssertEqual(reports, [100, 200, 250, 350, 370])
        XCTAssertEqual(rendered.frameCount, 370 + 22_050)
    }

    // MARK: - The Mac's Voice (opt-in)

    /// Opt-in, with `TEXTMOUTH_REAL_SPEECH_EXPORT=1`: the Mac's synthesizer
    /// writes a sentence in the first installed US English voice that is
    /// neither a Personal Voice nor a novelty voice into a CAF, through the
    /// renderer, off the main thread, and the test prints how many seconds
    /// of audio a second of rendering made. Writing into buffers plays
    /// nothing aloud.
    func testTheMacsSynthesizerWritesASentenceIntoAFile() async throws {
        guard ProcessInfo.processInfo.environment["TEXTMOUTH_REAL_SPEECH_EXPORT"] == "1" else {
            throw XCTSkip("Set TEXTMOUTH_REAL_SPEECH_EXPORT=1 to write a real voice into a file; nothing is played.")
        }
        guard let voice = AVSpeechSynthesisVoice.speechVoices().first(where: { voice in
            voice.language == "en-US"
                && !voice.voiceTraits.contains(.isPersonalVoice)
                && !voice.voiceTraits.contains(.isNoveltyVoice)
        }) else {
            throw XCTSkip("No US English voice is installed that is neither a Personal Voice nor a novelty voice.")
        }
        let identifier = voice.identifier
        let url = try makeChapterURL()
        let clock = ContinuousClock()
        let start = clock.now

        let rendered = try await Self.offTheMainThread {
            try SpeechChapterRenderer.render(
                title: "The Mac's voice",
                texts: ["TextMouth wrote this sentence to a file."],
                voiceIdentifier: identifier,
                wordsPerMinute: 200,
                pitch: 1,
                trailingSilence: 0,
                to: url,
                synthesizer: SystemSpeechBufferSynthesizer(),
                cancellation: BookExportCancellation()
            )
        }

        let elapsed = (clock.now - start) / .seconds(1)
        XCTAssertGreaterThan(rendered.frameCount, 0)
        XCTAssertEqual(try AVAudioFile(forReading: url).length, rendered.frameCount)
        let audioSeconds = Double(rendered.frameCount) / rendered.sampleRate
        print(
            "SpeechChapterRendererTests: \(voice.name) wrote \(audioSeconds) s of audio in \(elapsed) s, "
                + "\(audioSeconds / max(elapsed, 0.001)) s of audio a second of rendering"
        )
    }

    /// `body`'s result, worked out on a queue of its own, off the main
    /// thread, as a synthesizer's write must be.
    private static func offTheMainThread<Value: Sendable>(
        _ body: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try body() })
            }
        }
    }
}

// MARK: - A Synthesizer That Ends Badly

/// A synthesizer that speaks as the fake does, then ends its write as
/// `ending` says: refused after its audio was written, as the speech engine
/// can refuse partway, or failing, as the Mac's synthesizer can.
private struct SpeakThenEnd: SpeechBufferSynthesizing {
    /// What speaks first.
    let fake = FakeSpeechBufferSynthesizer()
    /// How each write ends once the fake has spoken.
    let ending: @Sendable () throws -> SpeechWriteEnd

    func write(
        _ utterance: SpeechExportUtterance,
        cancellation: BookExportCancellation,
        onBuffer: @escaping (AVAudioPCMBuffer) throws -> Void
    ) throws -> SpeechWriteEnd {
        _ = try fake.write(utterance, cancellation: cancellation, onBuffer: onBuffer)
        return try ending()
    }
}
