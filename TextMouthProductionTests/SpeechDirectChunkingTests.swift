import AVFoundation
import os
import XCTest
@testable import TextMouth

/// Direct speech hands the synthesizer a short first chunk, so the first
/// word comes quickly, and queues each next chunk as the one before it
/// starts, so the synthesizer goes straight on (PERF06). Every callback is
/// still checked against the utterance it is for.
///
/// The speech services here hand their utterances to a recorder standing in
/// for the synthesizer, and the tests deliver the synthesizer's callbacks
/// themselves, so nothing is heard. Their texts are longer than the render
/// limit, so nothing is rendered either. Each test ends well within the
/// second after which the direct-speech watchdog would look at the idle
/// synthesizer. Only the opt-in benchmark uses the synthesizer, muted.
@MainActor
final class SpeechDirectChunkingTests: XCTestCase {

    // MARK: - Chunks

    /// The first chunk holds about a thousand UTF-16 units and ends after a
    /// whole word; a text no longer than that is one chunk.
    func testTheFirstChunkIsShortAndEndsAfterAWord() {
        let text = Self.longText
        let chunk = DirectSpeechChunk.starting(at: 0, in: text, maximumLength: SpeechService.directModeFirstChunkSize)

        XCTAssertTrue(chunk.isPartial)
        XCTAssertGreaterThanOrEqual(chunk.end, SpeechService.directModeFirstChunkSize)
        XCTAssertLessThan(chunk.end, SpeechService.directModeFirstChunkSize + 40, "only the word cut is added")
        XCTAssertTrue(text[text.index(atUTF16Offset: chunk.end)].isWhitespace)

        let short = "Lamps came on along the pier."
        XCTAssertEqual(
            DirectSpeechChunk.starting(at: 0, in: short, maximumLength: SpeechService.directModeFirstChunkSize),
            DirectSpeechChunk(start: 0, end: short.utf16.count, isPartial: false)
        )
    }

    /// Chunk after chunk, from any offset, a text is spoken whole and in
    /// order: each chunk begins where the one before ended, ends after a
    /// word or at the text's end, and together they hold the rest of the
    /// text exactly, emoji and combining marks included.
    func testChunksTileTheTextExactly() throws {
        var random = BenchmarkProse(seed: 0xC4_0C5)
        for trial in 0..<200 {
            let text = (0..<(50 + random.roll(400))).map { _ in Self.alphabet[random.roll(Self.alphabet.count)] }.joined()
            let first = random.roll(60) + 1
            let later = random.roll(200) + 1
            var offset = random.roll(text.utf16.count)
            let label = "trial \(trial), first \(first), later \(later), from \(offset): \(text.debugDescription)"
            let startIndex = text.index(atUTF16Offset: offset)
            var spoken = ""
            var maximumLength = first

            var steps = 0
            while true {
                steps += 1
                let chunk = DirectSpeechChunk.starting(at: offset, in: text, maximumLength: maximumLength)
                XCTAssertEqual(chunk.start, text.utf16Offset(of: text.index(atUTF16Offset: offset)), label)
                XCTAssertTrue(
                    chunk.end == text.utf16.count || text[text.index(atUTF16Offset: chunk.end)].isWhitespace,
                    label
                )
                spoken += chunk.words(of: text)
                guard chunk.isPartial, chunk.end < text.utf16.count, steps < 1_000 else { break }
                offset = chunk.end
                maximumLength = later
            }
            XCTAssertTrue(haveIdenticalBytes(spoken, String(text[startIndex...])), label)
        }
    }

    /// At the old chunk size, a chunk is exactly the one direct speech cut
    /// before PERF06, from every offset of a generated chapter.
    func testAChunkIsCutAsBeforeAtTheOldSize() {
        var prose = BenchmarkProse(seed: 59)
        let text = prose.text(utf16Length: 30_000)
        var random = BenchmarkProse(seed: 61)
        for _ in 0..<300 {
            let offset = random.roll(text.utf16.count + 10)
            let expected = legacyChunk(of: text, from: offset, chunkSize: SpeechService.directModeChunkSize)
            let chunk = DirectSpeechChunk.starting(at: offset, in: text, maximumLength: SpeechService.directModeChunkSize)

            XCTAssertEqual(chunk.start, expected.start, "from \(offset)")
            XCTAssertEqual(chunk.end, expected.end, "from \(offset)")
            XCTAssertEqual(chunk.isPartial, expected.chunked, "from \(offset)")
            XCTAssertTrue(haveIdenticalBytes(chunk.words(of: text), expected.text), "from \(offset)")
        }
    }

    // MARK: - Queueing

    /// Speech hands over the short first chunk, and the next chunk as soon
    /// as the first starts, once however often its start is reported.
    func testTheNextChunkIsQueuedWhenTheFirstStarts() throws {
        let (speech, recorder) = makeDirectSpeech()
        defer { speech.stop() }

        speech.speak(Self.longText)
        let first = try handedOver(0, by: recorder)
        let firstChunk = chunk(at: 0, size: SpeechService.directModeFirstChunkSize)
        XCTAssertEqual(first.speechString, firstChunk.words(of: Self.longText))
        XCTAssertEqual(recorder.utterances.count, 1)

        report(start: first, to: speech)
        report(start: first, to: speech)

        XCTAssertEqual(recorder.utterances.count, 2)
        let second = try handedOver(1, by: recorder)
        XCTAssertEqual(second.speechString, chunk(at: firstChunk.end, size: SpeechService.directModeChunkSize).words(of: Self.longText))
    }

    /// When a chunk ends, the queued chunk speaks on without anything new
    /// handed over, its words are placed at its own offsets, and its start
    /// queues the chunk after it.
    func testTheQueuedChunkGoesOnWhenTheOneBeforeEnds() throws {
        let (speech, recorder) = makeDirectSpeech()
        defer { speech.stop() }
        var finishes = 0
        speech.onUtteranceFinished = { finishes += 1 }
        speech.speak(Self.longText)
        let first = try handedOver(0, by: recorder)
        report(start: first, to: speech)
        let second = try handedOver(1, by: recorder)
        let secondChunk = chunk(at: chunk(at: 0, size: SpeechService.directModeFirstChunkSize).end, size: SpeechService.directModeChunkSize)

        report(finish: first, to: speech)
        XCTAssertEqual(recorder.utterances.count, 2, "nothing new is handed over")
        XCTAssertEqual(finishes, 0)

        report(word: NSRange(location: 4, length: 5), of: second, to: speech)
        XCTAssertEqual(speech.currentWordRange, NSRange(location: secondChunk.start + 4, length: 5))

        report(start: second, to: speech)
        XCTAssertEqual(recorder.utterances.count, 3)
        XCTAssertEqual(
            try handedOver(2, by: recorder).speechString,
            chunk(at: secondChunk.end, size: SpeechService.directModeChunkSize).words(of: Self.longText)
        )
    }

    /// The queued chunk may report its start before the chunk before it
    /// reports its end. It speaks on from its start, and the late end, for a
    /// chunk no longer speaking, ends nothing.
    func testAQueuedChunkThatStartsBeforeTheEndBeforeItGoesOn() throws {
        let (speech, recorder) = makeDirectSpeech()
        defer { speech.stop() }
        var finishes = 0
        speech.onUtteranceFinished = { finishes += 1 }
        speech.speak(Self.longText)
        let first = try handedOver(0, by: recorder)
        report(start: first, to: speech)
        let second = try handedOver(1, by: recorder)
        let secondStart = chunk(at: 0, size: SpeechService.directModeFirstChunkSize).end

        report(start: second, to: speech)
        report(finish: first, to: speech)
        report(word: NSRange(location: 0, length: 3), of: second, to: speech)

        XCTAssertEqual(finishes, 0)
        XCTAssertEqual(recorder.utterances.count, 3, "the third chunk is queued once the second starts")
        XCTAssertEqual(speech.currentWordRange, NSRange(location: secondStart, length: 3))
        XCTAssertTrue(speech.isSpeaking)
    }

    /// Spoken to its end, a text is handed over whole, in order, and its end
    /// is reported once, after the last chunk.
    func testATextIsSpokenInOrderToItsEnd() throws {
        let (speech, recorder) = makeDirectSpeech()
        defer { speech.stop() }
        var finishes = 0
        speech.onUtteranceFinished = { finishes += 1 }
        let start = Self.longText.utf16.count - 12_000
        speech.speak(Self.longText, fromCharOffset: start)

        var spoken = 0
        while spoken < recorder.utterances.count, spoken < 20 {
            let utterance = try handedOver(spoken, by: recorder)
            report(start: utterance, to: speech)
            report(finish: utterance, to: speech)
            spoken += 1
        }

        XCTAssertEqual(finishes, 1)
        XCTAssertGreaterThan(spoken, 2, "the rest of the text took several chunks")
        let rest = Self.longText[Self.longText.index(atUTF16Offset: start)...]
        XCTAssertTrue(haveIdenticalBytes(recorder.utterances.map(\.speechString).joined(), String(rest)))
        XCTAssertFalse(speech.isSpeaking)
    }

    /// A seek drops the queued chunk with the one speaking and starts a
    /// short chunk at the new place; callbacks for the dropped chunks then
    /// change nothing.
    func testASeekDropsTheQueuedChunk() throws {
        let (speech, recorder) = makeDirectSpeech()
        defer { speech.stop() }
        var finishes = 0
        speech.onUtteranceFinished = { finishes += 1 }
        speech.speak(Self.longText)
        let first = try handedOver(0, by: recorder)
        report(start: first, to: speech)
        let dropped = try handedOver(1, by: recorder)

        speech.seek(toCharOffset: 50_000)
        let afterSeek = try handedOver(2, by: recorder)
        report(start: dropped, to: speech)
        report(finish: first, to: speech)
        report(finish: dropped, to: speech)

        XCTAssertEqual(afterSeek.speechString, chunk(at: 50_000, size: SpeechService.directModeFirstChunkSize).words(of: Self.longText))
        XCTAssertEqual(recorder.utterances.count, 3, "nothing is queued for a dropped chunk")
        XCTAssertEqual(finishes, 0)
        XCTAssertEqual(speech.currentWordRange, NSRange(location: 50_000, length: 0))
    }

    // MARK: - Markup

    /// A text with tag-shaped markup, which the Mac's speech engine reads
    /// as markup, is handed over guarded (`SpeechMarkupGuard`): each chunk
    /// at exactly the chunk's length, its brackets angle quotation marks
    /// and every other unit the text's own. The words the synthesizer
    /// reports for a guarded chunk land where they land in the same text
    /// with the markup blanked out, so the guard moves no offset.
    func testMarkupIsHandedOverGuardedWithoutMovingAnyWord() throws {
        var prose = BenchmarkProse(seed: 0x5A_FE)
        let lead = prose.text(utf16Length: 1_200)
        let sentence = SpeechMarkupGuardTests.rainbowsEndSentence
        // The same text with the markup's brackets as spaces: the same
        // length, no markup.
        let blanked = sentence.replacingOccurrences(of: "<", with: " ").replacingOccurrences(of: ">", with: " ")
        let marked = lead + " " + sentence + " " + Self.longText
        let plain = lead + " " + blanked + " " + Self.longText
        XCTAssertEqual(marked.utf16.count, plain.utf16.count)
        let firstChunk = DirectSpeechChunk.starting(at: 0, in: marked, maximumLength: SpeechService.directModeFirstChunkSize)
        let secondChunk = DirectSpeechChunk.starting(at: firstChunk.end, in: marked, maximumLength: SpeechService.directModeChunkSize)
        XCTAssertLessThan(firstChunk.end, lead.utf16.count, "the sentence lies in the second chunk")

        let (speech, recorder) = makeDirectSpeech()
        defer { speech.stop() }
        let (twin, twinRecorder) = makeDirectSpeech()
        defer { twin.stop() }
        var words: [String] = []
        speech.onWordSpoken = { _, word in words.append(word) }
        speech.speak(marked)
        twin.speak(plain)
        let first = try handedOver(0, by: recorder)
        let twinFirst = try handedOver(0, by: twinRecorder)
        report(start: first, to: speech)
        report(start: twinFirst, to: twin)

        // The first chunk, without markup, is handed over as it is; the
        // second, with the sentence, guarded and at its own length.
        XCTAssertEqual(first.speechString, firstChunk.words(of: marked))
        let second = try handedOver(1, by: recorder)
        let secondWords = secondChunk.words(of: marked)
        XCTAssertEqual(second.speechString, SpeechMarkupGuard.neutralized(secondWords))
        XCTAssertNotEqual(second.speechString, secondWords, "the chunk held markup")
        XCTAssertFalse(second.speechString.contains("<"))
        XCTAssertEqual(second.speechString.utf16.count, secondChunk.end - secondChunk.start)
        let twinSecond = try handedOver(1, by: twinRecorder)
        XCTAssertEqual(twinSecond.speechString, secondChunk.words(of: plain))
        XCTAssertEqual(twinSecond.speechString.utf16.count, second.speechString.utf16.count)

        // Once the first chunk ends, the second is the one speaking, and a
        // word before the markup, one between the tags, and one after the
        // closing tag land at the same place for both texts.
        report(finish: first, to: speech)
        report(finish: twinFirst, to: twin)
        for word in ["Braun", "recruit", "reply"] {
            let local = (secondWords as NSString).range(of: word)
            XCTAssertNotEqual(local.location, NSNotFound, word)
            report(word: local, of: second, to: speech)
            report(word: local, of: twinSecond, to: twin)
            let expected = NSRange(location: secondChunk.start + local.location, length: local.length)
            XCTAssertEqual(speech.currentWordRange, expected, word)
            XCTAssertEqual(twin.currentWordRange, expected, word)
            XCTAssertEqual((marked as NSString).substring(with: expected), word)
        }
        XCTAssertEqual(words, ["Braun", "recruit", "reply"])
    }

    // MARK: - Benchmark

    /// What the synthesizer itself does with the two changes, muted: the
    /// first word of a 1,000-unit utterance against a 5,000-unit one (the
    /// review measured 66 and 111 ms), and the silence between two
    /// utterances when the second is queued while the first speaks against
    /// when it is handed over once the first one's end reached the main
    /// queue, as before.
    ///
    /// Opt-in, since it uses the system synthesizer: pass
    /// `TEST_RUNNER_TEXTMOUTH_LARGE_BENCHMARKS=1`.
    func testBenchmarkTheFirstWordAndTheChunkBoundary() throws {
        guard largeBenchmarksRequested else {
            throw XCTSkip("Uses the synthesizer; set TEST_RUNNER_TEXTMOUTH_LARGE_BENCHMARKS=1")
        }
        let voice = SpeechService(userDefaults: makeSandboxedPreferences("direct-chunking-benchmark")).currentVoice
        var prose = BenchmarkProse(seed: 67)
        let passage = prose.text(utf16Length: 6_000)
        // Warm the voice first, so neither measurement pays for loading it.
        _ = mutedTimings(of: [String(passage.prefix(40))], voice: voice, queued: true)

        var firstWords: [String: [Double]] = [:]
        for length in [1_000, 5_000] {
            let piece = String(passage[..<passage.index(atUTF16Offset: length)])
            firstWords["\(length)"] = (0..<3).compactMap { _ in
                mutedTimings(of: [piece], voice: voice, queued: true, stopAfterFirstWord: true).firstWords.first ?? nil
            }
        }
        // Two short utterances, about two seconds each at 500 words a minute.
        let pair = [String(passage.prefix(120)), String(passage.dropFirst(120).prefix(120))]
        let queued = mutedTimings(of: pair, voice: voice, queued: true)
        let afterTheEnd = mutedTimings(of: pair, voice: voice, queued: false)

        reportBenchmark("PERF06 direct speech", [
            "firstWordMillisecondsByFirstChunkLength": firstWords,
            "silenceBetweenChunksQueuedMilliseconds": queued.gap ?? -1,
            "silenceBetweenChunksHandedOverAfterTheEndMilliseconds": afterTheEnd.gap ?? -1,
        ])
    }

    // MARK: - The old chunking

    /// How `SpeechService.speakDirect` cut a chunk before PERF06, line for
    /// line: where it starts and ends, whether it was cut short, and its
    /// words.
    private func legacyChunk(of text: String, from charOffset: Int, chunkSize: Int) -> (start: Int, end: Int, chunked: Bool, text: String) {
        let startOffset = max(0, min(charOffset, text.utf16Length))
        let startIdx = text.index(atUTF16Offset: startOffset)
        let normalizedStartOffset = text.utf16Offset(of: startIdx)
        let remainingCount = text.utf16Length - normalizedStartOffset
        if remainingCount > chunkSize {
            var endIdx = text.index(atUTF16Offset: normalizedStartOffset + chunkSize)
            while endIdx < text.endIndex && !text[endIdx].isWhitespace {
                endIdx = text.index(after: endIdx)
            }
            return (normalizedStartOffset, text.utf16Offset(of: endIdx), true, String(text[startIdx..<endIdx]))
        } else if normalizedStartOffset > 0 {
            return (normalizedStartOffset, text.utf16Length, false, String(text[startIdx...]))
        } else {
            return (0, text.utf16Length, false, text)
        }
    }

    // MARK: - Helpers

    /// A text longer than the render limit, so speech never renders it.
    private static let longText: String = {
        var prose = BenchmarkProse(seed: 71)
        return prose.text(utf16Length: SpeechRenderCoordinator.maximumTextLength + 20_000)
    }()

    /// The pieces random chunking texts are made of: words, spaces, line
    /// breaks, emoji, and accents written with combining marks.
    private static let alphabet = ["harbour", "quay", " ", " ", "\n", "🙂", "👍🏽", "e\u{0301}", "Caf\u{00E9}", "\t", "—", "a"]

    /// The chunk of `longText` at `offset` of at most `size` units.
    private func chunk(at offset: Int, size: Int) -> DirectSpeechChunk {
        DirectSpeechChunk.starting(at: offset, in: Self.longText, maximumLength: size)
    }

    /// A speech service with preferences of its own whose direct utterances
    /// go to the returned recorder instead of the synthesizer.
    private func makeDirectSpeech() -> (SpeechService, UtteranceRecorder) {
        let speech = SpeechService(userDefaults: makeSandboxedPreferences("direct-chunking"))
        let recorder = UtteranceRecorder()
        speech._directUtteranceRecorderForTesting = { recorder.utterances.append($0) }
        return (speech, recorder)
    }

    /// The utterance `recorder` received in position `index`, failing the
    /// test without stopping it when there is none.
    private func handedOver(
        _ index: Int,
        by recorder: UtteranceRecorder,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> AVSpeechUtterance {
        try XCTUnwrap(
            recorder.utterances.indices.contains(index) ? recorder.utterances[index] : nil,
            "no utterance \(index) was handed over",
            file: file,
            line: line
        )
    }

    /// Tell `speech`, as the synthesizer would, that `utterance` started, and
    /// let the main queue handle it.
    private func report(start utterance: AVSpeechUtterance, to speech: SpeechService) {
        speech.speechSynthesizer(AVSpeechSynthesizer(), didStart: utterance)
        handleQueuedCallbacks()
    }

    /// Tell `speech`, as the synthesizer would, that `utterance` finished.
    private func report(finish utterance: AVSpeechUtterance, to speech: SpeechService) {
        speech.speechSynthesizer(AVSpeechSynthesizer(), didFinish: utterance)
        handleQueuedCallbacks()
    }

    /// Tell `speech`, as the synthesizer would, that it will speak `range`
    /// of `utterance`.
    private func report(word range: NSRange, of utterance: AVSpeechUtterance, to speech: SpeechService) {
        speech.speechSynthesizer(AVSpeechSynthesizer(), willSpeakRangeOfSpeechString: range, utterance: utterance)
        handleQueuedCallbacks()
    }

    /// Returns once the main queue has run every block queued on it so far:
    /// the speech service handles each of the synthesizer's callbacks there.
    private func handleQueuedCallbacks(file: StaticString = #filePath, line: UInt = #line) {
        var handled = false
        DispatchQueue.main.async { handled = true }
        XCTAssertTrue(waitUntil(timeout: 5) { handled }, "The callbacks were never handled", file: file, line: line)
    }

    /// Speak `texts` muted in `voice` with a synthesizer of its own: all at
    /// once when `queued`, or each after the one before finished, handed
    /// over from the main queue as direct speech did before PERF06. Returns
    /// each utterance's first-word time from when speaking began, and the
    /// silence between the first's end and the second's first word.
    private func mutedTimings(
        of texts: [String],
        voice: AVSpeechSynthesisVoice?,
        queued: Bool,
        stopAfterFirstWord: Bool = false
    ) -> (firstWords: [Double?], gap: Double?) {
        let synthesizer = AVSpeechSynthesizer()
        let probe = SpeechEventProbe()
        synthesizer.delegate = probe
        let utterances = texts.map { text -> AVSpeechUtterance in
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice
            utterance.rate = SpeechService.rateForWPM(500)
            utterance.volume = 0
            utterance.prefersAssistiveTechnologySettings = false
            return utterance
        }
        guard let first = utterances.first else { return ([], nil) }
        let began = ContinuousClock.now
        if queued {
            utterances.forEach(synthesizer.speak)
        } else {
            // As before: the next utterance is handed over once the end of
            // the one before has reached the main queue.
            for (previous, next) in zip(utterances, utterances.dropFirst()) {
                probe.handOver(next, to: synthesizer, after: previous)
            }
            synthesizer.speak(first)
        }
        let last = utterances.last.map(ObjectIdentifier.init)
        _ = waitUntil(timeout: 30) {
            stopAfterFirstWord ? probe.firstWord(of: first) != nil : probe.finish(of: last) != nil
        }
        synthesizer.stopSpeaking(at: .immediate)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        synthesizer.delegate = nil

        func milliseconds(_ from: ContinuousClock.Instant, _ to: ContinuousClock.Instant) -> Double {
            let elapsed = from.duration(to: to)
            return Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
        }
        let firstWords = utterances.map { probe.firstWord(of: $0).map { milliseconds(began, $0) } }
        var gap: Double?
        if let second = utterances.dropFirst().first,
           let firstEnd = probe.finish(of: ObjectIdentifier(first)),
           let secondWord = probe.firstWord(of: second) {
            gap = milliseconds(firstEnd, secondWord)
        }
        return (firstWords, gap)
    }
}

// MARK: - Test doubles

/// Keeps every utterance direct speech hands over, in place of the
/// synthesizer, in order. Used only on the main thread.
private final class UtteranceRecorder {
    var utterances: [AVSpeechUtterance] = []
}

/// A synthesizer and the utterance the benchmark hands it on the main
/// queue, as direct speech did before PERF06. `@unchecked Sendable`: carried
/// from the synthesizer's thread to the main queue, which alone uses them
/// from then on.
private struct HandOff: @unchecked Sendable {
    let synthesizer: AVSpeechSynthesizer
    let utterance: AVSpeechUtterance
}

/// Hears, on whatever thread the synthesizer calls it, when each utterance
/// says its first word and when it finishes, by utterance identity, and
/// hands the synthesizer the utterance registered to follow one that
/// finishes, from the main queue. Holds nothing but its locks.
private final class SpeechEventProbe: NSObject, AVSpeechSynthesizerDelegate {
    /// First words and finishes so far, kept under this lock.
    private let events = OSAllocatedUnfairLock<(words: [ObjectIdentifier: ContinuousClock.Instant], finishes: [ObjectIdentifier: ContinuousClock.Instant])>(
        initialState: ([:], [:])
    )
    /// What to hand over when an utterance finishes, by its identity.
    private let followUps = OSAllocatedUnfairLock<[ObjectIdentifier: HandOff]>(initialState: [:])

    /// Hand `next` to `synthesizer` from the main queue once `previous`
    /// finishes, as direct speech did before PERF06.
    func handOver(_ next: AVSpeechUtterance, to synthesizer: AVSpeechSynthesizer, after previous: AVSpeechUtterance) {
        let handOff = HandOff(synthesizer: synthesizer, utterance: next)
        let previousID = ObjectIdentifier(previous)
        followUps.withLock { $0[previousID] = handOff }
    }

    /// When `utterance` said its first word, if it has.
    func firstWord(of utterance: AVSpeechUtterance) -> ContinuousClock.Instant? {
        let id = ObjectIdentifier(utterance)
        return events.withLock { $0.words[id] }
    }

    /// When the utterance `id` names finished, if it has.
    func finish(of id: ObjectIdentifier?) -> ContinuousClock.Instant? {
        guard let id else { return nil }
        return events.withLock { $0.finishes[id] }
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let now = ContinuousClock.now
        let id = ObjectIdentifier(utterance)
        events.withLock { if $0.words[id] == nil { $0.words[id] = now } }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let now = ContinuousClock.now
        let id = ObjectIdentifier(utterance)
        events.withLock { $0.finishes[id] = now }
        if let handOff = followUps.withLock({ $0.removeValue(forKey: id) }) {
            DispatchQueue.main.async { handOff.synthesizer.speak(handOff.utterance) }
        }
    }
}
