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

    // MARK: - Recovery after the system cancels the live utterance

    /// When the system cancels the live utterance on its own, as the speech
    /// engine does with a text it refuses, speech replaces its synthesizer
    /// with a fresh one, its delegate attached, and speaks the cancelled
    /// chunk again from the chunk's start; the chapter does not end.
    func testACancelledLiveUtteranceIsSpokenAgainOnAFreshSynthesizer() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let (speech, recorder) = makeDirectSpeech()
        defer { speech.stop() }
        var finishes = 0
        speech.onUtteranceFinished = { finishes += 1 }
        speech.speak(Self.longText)
        let first = try handedOver(0, by: recorder)
        report(start: first, to: speech)
        let second = try handedOver(1, by: recorder)
        let secondChunk = chunk(at: chunk(at: 0, size: SpeechService.directModeFirstChunkSize).end, size: SpeechService.directModeChunkSize)
        // The first chunk ends: the queued second is live, and never starts.
        report(finish: first, to: speech)
        let before = speech._directSynthesizerForTesting

        let lines = logLines(in: .speechTransitions) {
            report(cancel: second, to: speech)
        }

        let after = speech._directSynthesizerForTesting
        XCTAssertFalse(before === after, "the synthesizer was not replaced")
        XCTAssertTrue(after.delegate === speech, "the fresh synthesizer reports to speech")
        XCTAssertEqual(recorder.utterances.count, 3, "the chunk is handed over again")
        XCTAssertEqual(
            try handedOver(2, by: recorder).speechString,
            chunk(at: secondChunk.start, size: SpeechService.directModeFirstChunkSize).words(of: Self.longText)
        )
        XCTAssertTrue(speech.isSpeaking)
        XCTAssertFalse(speech.isPaused)
        XCTAssertEqual(finishes, 0)
        XCTAssertTrue(lines.contains { $0.contains("DIRECT_CANCEL_UNEXPECTED:") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("DIRECT_SYNTH_REPLACED:") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("DIRECT_RETRY offset=\(secondChunk.start) ") }, "\(lines)")
    }

    /// A chunk cancelled after some of its words were heard is spoken again
    /// from its last reported word, so nothing heard is heard twice.
    func testAChunkCancelledMidWayIsSpokenAgainFromItsLastWord() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let (speech, recorder) = makeDirectSpeech()
        defer { speech.stop() }
        speech.speak(Self.longText)
        let first = try handedOver(0, by: recorder)
        report(start: first, to: speech)
        report(word: NSRange(location: 300, length: 5), of: first, to: speech)
        XCTAssertEqual(recorder.utterances.count, 2, "the next chunk was queued at the start")

        let lines = logLines(in: .speechTransitions) {
            report(cancel: first, to: speech)
        }

        XCTAssertEqual(recorder.utterances.count, 3)
        XCTAssertEqual(
            try handedOver(2, by: recorder).speechString,
            chunk(at: 300, size: SpeechService.directModeFirstChunkSize).words(of: Self.longText)
        )
        XCTAssertTrue(lines.contains { $0.contains("DIRECT_RETRY offset=300 ") }, "\(lines)")
        XCTAssertTrue(speech.isSpeaking)
    }

    /// Cancelled again at the same place, on the fresh synthesizer, speech
    /// ends there: it shows itself stopped at the cursor, not paused, keeps
    /// its text for Play, the chapter neither ends nor moves on, the reader
    /// is told, and the listener hears why, in the pinned words.
    func testACancelOfTheRetryEndsSpeechWithTheAnnouncement() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let (speech, recorder) = makeDirectSpeech()
        defer { speech.stop() }
        var finishes = 0
        var refusals: [SpeechRefusal] = []
        var cursor: [NSRange] = []
        speech.onUtteranceFinished = { finishes += 1 }
        speech.onSpeechRefused = { refusals.append($0) }
        speech.onWordSpoken = { range, _ in cursor.append(range) }
        // The refused chunk never starts, so nothing is queued after it.
        let start = chunk(at: 20_000, size: SpeechService.directModeFirstChunkSize).start
        speech.speak(Self.longText, fromCharOffset: start)
        report(cancel: try handedOver(0, by: recorder), to: speech)
        let retry = try handedOver(1, by: recorder)
        XCTAssertTrue(speech.isSpeaking, "the first cancel is retried")

        var lines: [String] = []
        let announced = recordingAnnouncements {
            lines = logLines(in: .speechTransitions) {
                report(cancel: retry, to: speech)
            }
        }

        XCTAssertFalse(speech.isSpeaking)
        XCTAssertFalse(speech.isPaused)
        XCTAssertFalse(speech.isActive)
        XCTAssertEqual(speech.currentWordRange, NSRange(location: start, length: 0))
        XCTAssertEqual(cursor.last, NSRange(location: start, length: 0))
        XCTAssertEqual(speech.currentText, Self.longText, "the text is kept for Play")
        XCTAssertEqual(finishes, 0, "the chapter did not end")
        XCTAssertEqual(refusals.count, 1)
        XCTAssertEqual(refusals.first?.offset, start)
        XCTAssertEqual(recorder.utterances.count, 2, "nothing more is handed over")
        XCTAssertEqual(announced.announcements.map(\.message), [SpeechService.engineRefusedAnnouncement])
        XCTAssertEqual(SpeechService.engineRefusedAnnouncement, "Speech stopped: the Mac's speech engine refused this text.")
        XCTAssertTrue(lines.contains { $0.contains("DIRECT_RETRY_FAILED: offset=\(start) ") }, "\(lines)")
    }

    /// Speech that ends on a refusal tells its reader what was refused, for
    /// the report of the refusal (B05): where speech stopped; the retry the
    /// engine refused, exactly as it was handed over, strictly guarded, with
    /// its voice, rate, pitch, and volume; the speed; and the speech log's
    /// newest lines, which end with the stop and hold no words of the book.
    func testARefusalTellsTheReaderWhatWasRefused() throws {
        let text = Self.distinctText
        let (speech, recorder) = makeDirectSpeech()
        defer { speech.stop() }
        var refusals: [SpeechRefusal] = []
        speech.onSpeechRefused = { refusals.append($0) }
        let refusedChunk = DirectSpeechChunk.starting(at: 20_000, in: text, maximumLength: SpeechService.directModeFirstChunkSize)
        speech.speak(text, fromCharOffset: refusedChunk.start)
        report(cancel: try handedOver(0, by: recorder), to: speech)
        let retry = try handedOver(1, by: recorder)

        recordingAnnouncements {
            report(cancel: retry, to: speech)
        }

        XCTAssertEqual(refusals.count, 1)
        let refusal = try XCTUnwrap(refusals.first)
        XCTAssertEqual(refusal.offset, refusedChunk.start)
        XCTAssertEqual(refusal.refusedRange, refusedChunk.start..<refusedChunk.end, "the retry spoke the refused chunk again")
        XCTAssertEqual(refusal.refusedText, retry.speechString, "not the text as it was handed over")
        XCTAssertEqual(refusal.refusedText, SpeechMarkupGuard.neutralizedStrictly(refusedChunk.words(of: text)))
        XCTAssertEqual(refusal.strictlyGuardedRange, refusedChunk.start..<refusedChunk.end)
        XCTAssertEqual(refusal.voice, retry.voice.map { SpeechRefusal.Voice($0) })
        XCTAssertEqual(refusal.voice?.identifier, speech.currentVoice?.identifier)
        XCTAssertEqual(refusal.wordsPerMinute, speech.wordsPerMinute)
        XCTAssertEqual(refusal.rate, retry.rate)
        XCTAssertEqual(refusal.pitchMultiplier, retry.pitchMultiplier)
        XCTAssertEqual(refusal.volume, retry.volume)

        let messages = refusal.recentLines.map(\.message)
        XCTAssertLessThanOrEqual(messages.count, RecentTransitionLines.defaultCapacity)
        XCTAssertEqual(
            messages.last,
            "DIRECT_RETRY_FAILED: offset=\(refusedChunk.start) chunkStart=\(refusedChunk.start) "
                + "chunkEnd=\(refusedChunk.end); speech stopped, the listener told"
        )
        for tag in ["DIRECT_CANCEL_UNEXPECTED:", "DIRECT_SYNTH_REPLACED:", "DIRECT_RETRY offset=\(refusedChunk.start) "] {
            XCTAssertTrue(messages.contains { $0.hasPrefix(tag) }, "\(tag) is missing: \(messages)")
        }
        for word in Self.distinctWords {
            XCTAssertFalse(messages.contains { $0.contains(word) }, "\(word) reached the lines: \(messages)")
        }
    }

    /// A refusal heard while paused, at a place whose one retry was taken
    /// already, ends speech there at once, the pause notwithstanding, and
    /// the reader is told of the retry the engine refused.
    func testARefusalWhilePausedAfterTheRetryEndsSpeechThere() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let (speech, recorder) = makeDirectSpeech()
        defer { speech.stop() }
        var refusals: [SpeechRefusal] = []
        speech.onSpeechRefused = { refusals.append($0) }
        let start = chunk(at: 20_000, size: SpeechService.directModeFirstChunkSize).start
        speech.speak(Self.longText, fromCharOffset: start)
        report(cancel: try handedOver(0, by: recorder), to: speech)
        let retry = try handedOver(1, by: recorder)
        speech.pause()

        let lines = logLines(in: .speechTransitions) {
            _ = recordingAnnouncements {
                report(cancel: retry, to: speech)
            }
        }

        XCTAssertFalse(speech.isActive, "a refusal of the retry while paused did not end speech")
        XCTAssertEqual(recorder.utterances.count, 2, "something was handed over again")
        XCTAssertEqual(refusals.count, 1)
        XCTAssertEqual(refusals.first?.offset, start)
        XCTAssertEqual(refusals.first?.refusedText, retry.speechString)
        XCTAssertTrue(lines.contains { $0.contains("DIRECT_CANCEL_UNEXPECTED: live utterance cancelled while app was paused") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("DIRECT_RETRY_FAILED: offset=\(start) ") }, "\(lines)")
    }

    /// The retry speaks the refused chunk strictly guarded, every bracket
    /// silent, so that a shape the default guard misses is not refused
    /// twice; the chunk after it goes back to the default guard, which
    /// leaves a lone "less than" to be spoken. Every length, and so every
    /// word's place, stays.
    func testTheRetrySpeaksTheRefusedChunkStrictlyAndOnlyThatChunk() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let text = Self.bracketedText
        let (speech, recorder) = makeDirectSpeech()
        defer { speech.stop() }
        speech.speak(text)
        let refusedChunk = DirectSpeechChunk.starting(at: 0, in: text, maximumLength: SpeechService.directModeFirstChunkSize)
        let refused = try handedOver(0, by: recorder)
        XCTAssertEqual(refused.speechString, refusedChunk.words(of: text), "the default guard leaves lone brackets")
        XCTAssertTrue(refused.speechString.contains("<"))

        let lines = logLines(in: .speechTransitions) {
            report(cancel: refused, to: speech)
        }

        let retry = try handedOver(1, by: recorder)
        XCTAssertEqual(retry.speechString, SpeechMarkupGuard.neutralizedStrictly(refusedChunk.words(of: text)))
        XCTAssertFalse(retry.speechString.contains("<"))
        XCTAssertFalse(retry.speechString.contains(">"))
        XCTAssertEqual(retry.speechString.utf16.count, refusedChunk.end - refusedChunk.start)
        XCTAssertTrue(lines.contains { $0.contains("DIRECT_RETRY offset=0 ") }, "\(lines)")

        // The retry starts, which queues the chunk after it: that chunk is
        // guarded as usual, its lone brackets kept.
        report(start: retry, to: speech)
        let next = try handedOver(2, by: recorder)
        let nextChunk = DirectSpeechChunk.starting(at: refusedChunk.end, in: text, maximumLength: SpeechService.directModeChunkSize)
        XCTAssertEqual(next.speechString, nextChunk.words(of: text))
        XCTAssertTrue(next.speechString.contains("<"), "a later chunk lost its lone brackets")

        // A word of the retry lands at its own place in the text.
        let tide = (retry.speechString as NSString).range(of: "tide")
        report(word: tide, of: retry, to: speech)
        XCTAssertEqual(speech.currentWordRange, tide)
        XCTAssertEqual((text as NSString).substring(with: tide), "tide")
    }

    /// When a long chunk is refused, the whole rest of it is strictly
    /// guarded, though the retry speaks it in a short chunk and the one
    /// queued after it: that one is strict up to the refused chunk's end
    /// and guarded as usual after it. A new speech guards as usual again.
    func testTheRestOfALongRefusedChunkIsStrictAcrossTheRetrysChunks() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let text = Self.bracketedText
        let (speech, recorder) = makeDirectSpeech()
        defer { speech.stop() }
        speech.speak(text)
        let first = try handedOver(0, by: recorder)
        report(start: first, to: speech)
        let second = try handedOver(1, by: recorder)
        let firstChunk = DirectSpeechChunk.starting(at: 0, in: text, maximumLength: SpeechService.directModeFirstChunkSize)
        let secondChunk = DirectSpeechChunk.starting(at: firstChunk.end, in: text, maximumLength: SpeechService.directModeChunkSize)
        // The first chunk ends: the queued second is live, and never starts.
        report(finish: first, to: speech)
        report(cancel: second, to: speech)

        // The retry, a short chunk from where the refused one began: strict.
        let retry = try handedOver(2, by: recorder)
        let retryChunk = DirectSpeechChunk.starting(at: secondChunk.start, in: text, maximumLength: SpeechService.directModeFirstChunkSize)
        XCTAssertEqual(retry.speechString, SpeechMarkupGuard.neutralizedStrictly(retryChunk.words(of: text)))

        // The chunk queued at its start: strict to the refused chunk's end.
        report(start: retry, to: speech)
        let next = try handedOver(3, by: recorder)
        let nextChunk = DirectSpeechChunk.starting(at: retryChunk.end, in: text, maximumLength: SpeechService.directModeChunkSize)
        let strictLength = secondChunk.end - nextChunk.start
        XCTAssertEqual(
            next.speechString,
            SpeechMarkupGuard.neutralized(nextChunk.words(of: text), strictlyWithin: 0..<strictLength)
        )
        let units = Array(next.speechString.utf16)
        guard strictLength > 0, strictLength < units.count else {
            return XCTFail("the refused chunk should end inside the chunk after the retry, at \(strictLength) of \(units.count)")
        }
        XCTAssertFalse(units[..<strictLength].contains(0x3C), "the rest of the refused chunk kept a bracket")
        XCTAssertTrue(units[strictLength...].contains(0x3C), "the text after the refused chunk lost its lone brackets")

        // A new speech guards as usual from its first chunk.
        speech.speak(text, fromCharOffset: secondChunk.start)
        let again = try handedOver(4, by: recorder)
        XCTAssertEqual(again.speechString, retryChunk.words(of: text))
    }

    /// A refusal in a chapter's last chunk is spoken again, strictly, to
    /// the chapter's end, after which nothing is queued and the chapter
    /// ends once, as it would have without the refusal.
    func testARefusalInTheLastChunkStillEndsTheChapterOnce() throws {
        let text = Self.bracketedText
        let (speech, recorder) = makeDirectSpeech()
        defer { speech.stop() }
        var finishes = 0
        speech.onUtteranceFinished = { finishes += 1 }
        let lastChunk = DirectSpeechChunk.starting(
            at: text.utf16.count - 600, in: text, maximumLength: SpeechService.directModeFirstChunkSize
        )
        XCTAssertFalse(lastChunk.isPartial, "the chunk is not the chapter's last")
        speech.speak(text, fromCharOffset: lastChunk.start)

        report(cancel: try handedOver(0, by: recorder), to: speech)

        let retry = try handedOver(1, by: recorder)
        XCTAssertEqual(retry.speechString, SpeechMarkupGuard.neutralizedStrictly(lastChunk.words(of: text)))
        report(start: retry, to: speech)
        XCTAssertEqual(recorder.utterances.count, 2, "something was queued after the chapter's last chunk")
        XCTAssertEqual(finishes, 0)
        report(finish: retry, to: speech)
        XCTAssertEqual(finishes, 1)
        XCTAssertFalse(speech.isSpeaking)
    }

    /// A refusal heard while speech is paused, as when Pause is pressed
    /// just as the engine refuses a chunk, lets go of the refusing
    /// synthesizer at once and keeps the pause: nothing is heard until
    /// Play, which speaks the chunk again from its start on a fresh
    /// synthesizer, strictly guarded. That was the place's one retry:
    /// refused there again, speech ends with the announcement.
    func testARefusalWhilePausedIsSpokenAgainAtPlay() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let text = Self.bracketedText
        let (speech, recorder) = makeDirectSpeech()
        defer { speech.stop() }
        speech.speak(text)
        let refused = try handedOver(0, by: recorder)
        let refusing = try synthesizer(0, by: recorder)
        speech.pause()
        XCTAssertTrue(speech.isPaused)

        let lines = logLines(in: .speechTransitions) {
            report(cancel: refused, to: speech)
        }

        XCTAssertTrue(speech.isPaused, "the pause did not stand")
        XCTAssertTrue(speech.isActive)
        XCTAssertEqual(recorder.utterances.count, 1, "something was handed over while paused")
        XCTAssertFalse(speech._directSynthesizerForTesting === refusing, "the synthesizer that refused is kept")
        XCTAssertTrue(lines.contains { $0.contains("DIRECT_CANCEL_UNEXPECTED: live utterance cancelled while app was paused") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("DIRECT_RETRY_AT_RESUME offset=0 ") }, "\(lines)")

        XCTAssertTrue(speech.resume())
        XCTAssertFalse(speech.isPaused)
        XCTAssertTrue(speech.isSpeaking)
        let retry = try handedOver(1, by: recorder)
        let chunk = DirectSpeechChunk.starting(at: 0, in: text, maximumLength: SpeechService.directModeFirstChunkSize)
        XCTAssertEqual(retry.speechString, SpeechMarkupGuard.neutralizedStrictly(chunk.words(of: text)))
        XCTAssertFalse(try synthesizer(1, by: recorder) === refusing, "Play went to the synthesizer that refused")

        let announced = recordingAnnouncements {
            report(cancel: retry, to: speech)
        }
        XCTAssertFalse(speech.isActive, "a second refusal at the same place did not end speech")
        XCTAssertEqual(announced.announcements.map(\.message), [SpeechService.engineRefusedAnnouncement])
    }

    /// A sleep-fade segment the engine refuses lets go of the refusing
    /// synthesizer, which would leave the rest of the fade silent and the
    /// next Play too, and the fade goes on from the same place on a fresh
    /// one, no louder, the refused segment strictly guarded; refused there
    /// again, speech ends with the announcement.
    func testARefusedFadeSegmentGoesOnStrictlyOnAFreshSynthesizer() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let text = Self.bracketedText
        let (speech, recorder) = makeDirectSpeech()
        defer { speech.stop() }
        speech.speak(text)
        let first = try handedOver(0, by: recorder)
        report(start: first, to: speech)
        // The cursor on the "3" of "3 < 4", so the fade's first segment
        // holds a lone bracket.
        let three = (text as NSString).range(of: "3 < 4").location
        report(word: NSRange(location: three, length: 1), of: first, to: speech)
        let handedBeforeTheFade = recorder.utterances.count
        // No rendered audio: the fade queues quieter utterances, planned as
        // the service plans them, over the fade's duration times its volume.
        let fadeDuration = 10 * Double(Float(0.8))
        speech.setSleepTimerFadeVolume(0.8, duration: 10)
        let planned = DirectSpeechFadePlanner.segments(
            in: text, fromUTF16Offset: three, duration: fadeDuration, wordsPerMinute: speech.wordsPerMinute, startingVolume: 0.8
        )
        let firstPlanned = try XCTUnwrap(planned.first)
        XCTAssertEqual(recorder.utterances.count, handedBeforeTheFade + planned.count)
        let refused = try handedOver(handedBeforeTheFade, by: recorder)
        XCTAssertEqual(refused.speechString, firstPlanned.text, "the default guard leaves lone brackets")
        XCTAssertTrue(firstPlanned.text.contains("<"))
        let refusing = try synthesizer(handedBeforeTheFade, by: recorder)

        let lines = logLines(in: .speechTransitions) {
            report(cancel: refused, to: speech)
        }

        XCTAssertFalse(speech._directSynthesizerForTesting === refusing, "the synthesizer that refused is kept")
        XCTAssertTrue(speech.isSpeaking)
        XCTAssertTrue(lines.contains { $0.contains("SLEEP_FADE_DIRECT_SEGMENT_REFUSED: offset=\(three) ") }, "\(lines)")
        // The fade planned anew from the same place, no louder.
        let replanned = DirectSpeechFadePlanner.segments(
            in: text, fromUTF16Offset: three, duration: fadeDuration, wordsPerMinute: speech.wordsPerMinute, startingVolume: refused.volume
        )
        let firstReplanned = try XCTUnwrap(replanned.first)
        let goesOnIndex = handedBeforeTheFade + planned.count
        XCTAssertEqual(recorder.utterances.count, goesOnIndex + replanned.count, "the fade did not go on")
        let goesOn = try handedOver(goesOnIndex, by: recorder)
        XCTAssertEqual(
            goesOn.speechString,
            SpeechMarkupGuard.neutralized(firstReplanned.text, strictlyWithin: 0..<(firstPlanned.endUTF16Offset - three))
        )
        XCTAssertFalse(goesOn.speechString.contains("<"), "the refused segment kept a bracket")
        XCTAssertLessThanOrEqual(goesOn.volume, refused.volume, "the fade grew louder")
        XCTAssertFalse(try synthesizer(goesOnIndex, by: recorder) === refusing)

        var announced = AnnouncementRecorder()
        let ending = logLines(in: .speechTransitions) {
            announced = recordingAnnouncements {
                report(cancel: goesOn, to: speech)
            }
        }
        XCTAssertFalse(speech.isActive, "a second refusal at the same place did not end speech")
        XCTAssertEqual(announced.announcements.map(\.message), [SpeechService.engineRefusedAnnouncement])
        // What was refused is the segment, not the whole fade (B05).
        let segmentEnd = three + goesOn.speechString.utf16.count
        XCTAssertTrue(
            ending.contains { $0.contains("DIRECT_RETRY_FAILED: offset=\(three) chunkStart=\(three) chunkEnd=\(segmentEnd);") },
            "\(ending)"
        )
    }

    /// A sleep-fade segment cancelled by the app's own stop, as a pause
    /// during the fade makes, is no refusal: the synthesizer stays, and
    /// nothing more is handed over.
    func testAFadeSegmentTheAppStoppedIsNoRefusal() throws {
        let (speech, recorder) = makeDirectSpeech()
        defer { speech.stop() }
        speech.speak(Self.longText)
        report(start: try handedOver(0, by: recorder), to: speech)
        let handedBeforeTheFade = recorder.utterances.count
        speech.setSleepTimerFadeVolume(0.8, duration: 10)
        let segment = try handedOver(handedBeforeTheFade, by: recorder)
        let before = speech._directSynthesizerForTesting
        speech.pause()
        let handed = recorder.utterances.count

        report(cancel: segment, to: speech)

        XCTAssertTrue(speech._directSynthesizerForTesting === before, "a stop of the app's replaced the synthesizer")
        XCTAssertEqual(recorder.utterances.count, handed)
        XCTAssertTrue(speech.isPaused)
    }

    /// Speech that stopped after a refusal speaks again when asked, and
    /// not on the synthesizer that refused the retry, which would never
    /// speak again (October 7): Play goes to a fresh synthesizer, which
    /// reports to speech, and may be cancelled and retried once more there.
    /// The recorder notes the synthesizer each utterance would have reached.
    func testSpeechSpeaksAgainAfterARefusalEndedIt() throws {
        let (speech, recorder) = makeDirectSpeech()
        defer { speech.stop() }
        speech.speak(Self.longText, fromCharOffset: 20_000)
        let first = try synthesizer(0, by: recorder)
        report(cancel: try handedOver(0, by: recorder), to: speech)
        // The retry went to a fresh synthesizer, which refuses it too.
        let refusing = try synthesizer(1, by: recorder)
        XCTAssertFalse(refusing === first, "the retry went to the synthesizer that refused the chunk")
        try recordingAnnouncements {
            report(cancel: try handedOver(1, by: recorder), to: speech)
        }
        XCTAssertFalse(speech.isActive)
        XCTAssertFalse(speech._directSynthesizerForTesting === refusing, "the synthesizer that refused the retry is kept")
        XCTAssertTrue(speech._directSynthesizerForTesting.delegate === speech)

        speech.speak(Self.longText, fromCharOffset: 20_000)
        XCTAssertTrue(speech.isSpeaking)
        XCTAssertEqual(recorder.utterances.count, 3)
        let afterTheEnd = try synthesizer(2, by: recorder)
        XCTAssertFalse(afterTheEnd === refusing, "Play went to the synthesizer that refused, which never speaks again")
        XCTAssertFalse(afterTheEnd === first)
        XCTAssertTrue(afterTheEnd.delegate === speech, "the synthesizer Play went to reports to speech")
        report(cancel: try handedOver(2, by: recorder), to: speech)
        XCTAssertEqual(recorder.utterances.count, 4, "a new speech may be retried once again")
        XCTAssertTrue(speech.isSpeaking)
    }


    // MARK: - Switching to rendered audio

    // The engine plays silence installed as audio rendered from the text,
    // at volume 0, so nothing is heard.

    /// The watchdog, finding the synthesizer idle while speech should be
    /// heard, switches to audio rendered from this speech at the last word
    /// reported, and the engine plays. The recorder's synthesizer never had
    /// the utterance, so it is idle from the start.
    func testTheWatchdogSwitchesAnIdleSynthesizerToRenderedAudio() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let (speech, recorder) = makeDirectSpeech()
        defer { speech.stop() }
        speech.speak(Self.longText)
        installSilentRenderedAudio(of: Self.longText, in: speech)
        let first = try handedOver(0, by: recorder)
        report(start: first, to: speech)
        report(word: NSRange(location: 300, length: 5), of: first, to: speech)

        let lines = logLines(in: .speechTransitions) {
            XCTAssertTrue(waitUntil(timeout: 5) { !speech.usingDirectMode }, "the watchdog never switched")
        }

        XCTAssertTrue(speech.audioEngine.isPlaying, "the rendered audio did not start")
        XCTAssertTrue(speech.isSpeaking)
        XCTAssertEqual(recorder.utterances.count, 2, "direct speech went on")
        XCTAssertTrue(lines.contains { $0.contains("DIRECT_WATCHDOG_RECOVERY: synthesizer idle without usable didFinish; switching to rendered audio at offset=300 ") }, "\(lines)")
    }

    /// A sleep fade that begins during direct speech switches to audio
    /// rendered from it at the last word reported, whose volume the engine
    /// fades, instead of queuing quieter utterances.
    func testASleepFadeSwitchesDirectSpeechToRenderedAudio() throws {
        let (speech, recorder) = makeDirectSpeech()
        defer { speech.stop() }
        speech.speak(Self.longText)
        installSilentRenderedAudio(of: Self.longText, in: speech)
        let first = try handedOver(0, by: recorder)
        report(start: first, to: speech)
        report(word: NSRange(location: 300, length: 5), of: first, to: speech)

        speech.setSleepTimerFadeVolume(0.5, duration: 10)

        XCTAssertFalse(speech.usingDirectMode)
        XCTAssertTrue(speech.audioEngine.isPlaying, "the rendered audio did not start")
        XCTAssertEqual(speech.audioEngine.outputVolume, 0.5)
        XCTAssertEqual(recorder.utterances.count, 2, "fade segments were queued")
    }

    /// When the engine holds audio rendered from this speech in the current
    /// voice, a refused chunk is not spoken again directly: speech switches
    /// to that audio where the chunk began, where nothing is heard, as on
    /// October 7, when a chunk holding only a closing tag was refused while
    /// the whole chapter had rendered. The synthesizer that refused is let
    /// go, and the chapter goes on.
    func testARefusalSwitchesToRenderedAudioOfThisSpeech() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let (speech, recorder) = makeDirectSpeech()
        defer { speech.stop() }
        var finishes = 0
        speech.onUtteranceFinished = { finishes += 1 }
        speech.speak(Self.longText)
        installSilentRenderedAudio(of: Self.longText, in: speech)
        let first = try handedOver(0, by: recorder)
        report(start: first, to: speech)
        let second = try handedOver(1, by: recorder)
        let secondStart = chunk(at: 0, size: SpeechService.directModeFirstChunkSize).end
        // The first chunk ends: the queued second is live, and never starts.
        report(finish: first, to: speech)
        let refusing = try synthesizer(1, by: recorder)

        let lines = logLines(in: .speechTransitions) {
            report(cancel: second, to: speech)
        }

        XCTAssertFalse(speech.usingDirectMode, "the refused chunk was spoken again directly")
        XCTAssertTrue(speech.audioEngine.isPlaying, "the rendered audio did not start")
        XCTAssertTrue(speech.isSpeaking)
        XCTAssertFalse(speech.isPaused)
        XCTAssertEqual(finishes, 0)
        XCTAssertEqual(recorder.utterances.count, 2, "an utterance was handed to a synthesizer again")
        XCTAssertFalse(speech._directSynthesizerForTesting === refusing, "the synthesizer that refused is kept")
        XCTAssertTrue(
            lines.contains { $0.contains("DIRECT_RETRY_ENGINE: rendered audio of this speech plays on at offset=\(secondStart) ") },
            "\(lines)"
        )
        XCTAssertFalse(lines.contains { $0.contains("DIRECT_RETRY offset=") }, "\(lines)")
    }

    /// Audio rendered from another text is never switched to: the refused
    /// chunk is spoken again directly, strictly guarded, as without audio.
    func testARefusalNeverSwitchesToAnotherTextsAudio() throws {
        let (speech, recorder) = makeDirectSpeech()
        defer { speech.stop() }
        speech.speak(Self.longText)
        installSilentRenderedAudio(of: "Lamps came on along the pier.", in: speech)

        report(cancel: try handedOver(0, by: recorder), to: speech)

        XCTAssertTrue(speech.usingDirectMode)
        XCTAssertFalse(speech.audioEngine.isPlaying)
        XCTAssertEqual(recorder.utterances.count, 2, "the refused chunk was not spoken again")
        XCTAssertTrue(speech.isSpeaking)
    }

    /// A strict retry refused too ends speech only when there is nothing
    /// else to play: audio rendered from this speech since the first
    /// refusal is switched to instead, at the same place, with no
    /// announcement.
    func testARefusedRetrySwitchesToAudioRenderedSince() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let (speech, recorder) = makeDirectSpeech()
        defer { speech.stop() }
        var refusals = 0
        speech.onSpeechRefused = { _ in refusals += 1 }
        let start = chunk(at: 20_000, size: SpeechService.directModeFirstChunkSize).start
        speech.speak(Self.longText, fromCharOffset: start)
        report(cancel: try handedOver(0, by: recorder), to: speech)
        let retry = try handedOver(1, by: recorder)
        installSilentRenderedAudio(of: Self.longText, in: speech)

        var lines: [String] = []
        let announced = recordingAnnouncements {
            lines = logLines(in: .speechTransitions) {
                report(cancel: retry, to: speech)
            }
        }

        XCTAssertFalse(speech.usingDirectMode)
        XCTAssertTrue(speech.audioEngine.isPlaying, "the rendered audio did not start")
        XCTAssertTrue(speech.isSpeaking, "speech ended though rendered audio could go on")
        XCTAssertEqual(refusals, 0)
        XCTAssertEqual(announced.announcements.count, 0)
        XCTAssertTrue(lines.contains { $0.contains("DIRECT_RETRY_ENGINE: rendered audio of this speech plays on at offset=\(start) ") }, "\(lines)")
        XCTAssertFalse(lines.contains { $0.contains("DIRECT_RETRY_FAILED:") }, "\(lines)")
    }

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

    /// A text longer than the render limit made of words found nowhere in
    /// speech's log lines (`distinctWords`), so a line that held the book's
    /// words would show.
    private static let distinctText: String = {
        let sentence = "Quillwort edges the salt flats beyond the ferry slip. "
        return String(repeating: sentence, count: SpeechRenderCoordinator.maximumTextLength / sentence.utf16.count + 400)
    }()

    /// The words of `distinctText` that no log line may hold.
    private static let distinctWords = ["Quillwort", "edges", "flats", "ferry"]

    /// A text longer than the render limit with lone brackets all through
    /// it, which the default guard leaves to be spoken as "less than" and
    /// "greater than", and the strict guard makes silent.
    private static let bracketedText: String = {
        let sentence = "Count on it: 3 < 4 and 5 > 2 here, as the tide turns. "
        let repeats = SpeechRenderCoordinator.maximumTextLength / sentence.utf16.count + 400
        return String(repeating: sentence, count: repeats)
    }()

    /// The pieces random chunking texts are made of: words, spaces, line
    /// breaks, emoji, and accents written with combining marks.
    private static let alphabet = ["harbour", "quay", " ", " ", "\n", "🙂", "👍🏽", "e\u{0301}", "Caf\u{00E9}", "\t", "—", "a"]

    /// The chunk of `longText` at `offset` of at most `size` units.
    private func chunk(at offset: Int, size: Int) -> DirectSpeechChunk {
        DirectSpeechChunk.starting(at: offset, in: Self.longText, maximumLength: size)
    }

    /// A speech service with preferences of its own whose direct utterances
    /// go to the returned recorder instead of the synthesizer. The recorder
    /// notes, beside each utterance, the synthesizer speech would have
    /// handed it to, read through a seam no production code uses.
    private func makeDirectSpeech() -> (SpeechService, UtteranceRecorder) {
        let speech = SpeechService(userDefaults: makeSandboxedPreferences("direct-chunking"))
        let recorder = UtteranceRecorder()
        // Weak: speech holds this closure.
        speech._directUtteranceRecorderForTesting = { [weak speech] utterance in
            recorder.utterances.append(utterance)
            recorder.synthesizers.append(speech?._directSynthesizerForTesting)
        }
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

    /// The synthesizer the utterance in position `index` of `recorder`
    /// would have been handed to, failing the test without stopping it when
    /// there is none.
    private func synthesizer(
        _ index: Int,
        by recorder: UtteranceRecorder,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> AVSpeechSynthesizer {
        try XCTUnwrap(
            recorder.synthesizers.indices.contains(index) ? recorder.synthesizers[index] : nil,
            "no utterance \(index) was handed over",
            file: file,
            line: line
        )
    }

    /// Install in `speech`'s engine five seconds of silence as audio
    /// rendered from `text` in `speech`'s current voice, its frames spread
    /// evenly over the whole text, so that speech may switch to it. The
    /// engine plays at volume 0, and silence besides. Call it after
    /// `speak(_:)`, which lets go of earlier rendered audio.
    private func installSilentRenderedAudio(of text: String, in speech: SpeechService) {
        let engine = speech.audioEngine
        engine.setVolume(0)
        engine._installRenderedAudioForTesting(
            signature: SpeechRenderRequest(text: text, voice: speech.currentVoice).signature,
            lasting: 5
        )
        engine._configureFrameMapForTesting([(0, 0), (text.utf16.count, 110_250)], totalFrames: 110_250)
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

    /// Tell `speech`, as the synthesizer would, that `utterance` was
    /// cancelled.
    private func report(cancel utterance: AVSpeechUtterance, to speech: SpeechService) {
        speech.speechSynthesizer(AVSpeechSynthesizer(), didCancel: utterance)
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
/// synthesizer, in order, and beside each the synthesizer it would have
/// reached. Used only on the main thread.
private final class UtteranceRecorder {
    var utterances: [AVSpeechUtterance] = []
    /// The synthesizer each utterance would have been handed to, by
    /// position; nil when speech was gone, which no test lets happen.
    var synthesizers: [AVSpeechSynthesizer?] = []
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
