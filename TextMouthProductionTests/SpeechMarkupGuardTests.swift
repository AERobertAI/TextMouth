import AVFoundation
import os
import XCTest
@testable import TextMouth

/// `SpeechMarkupGuard` makes tag-shaped text harmless to the Mac's speech
/// engine, which reads it as markup (refusing a closing tag with no opening
/// tag, and swallowing everything after an opening tag with no closing
/// tag), by replacing the brackets of every tag-shaped run with angle
/// quotation marks, one UTF-16 unit for one, and changing nothing else.
///
/// The tests are string in, string out, apart from the offline renders at
/// the end, which use the system synthesizer's `write`, which plays
/// nothing, in the compact Samantha voice the engine's behaviour was
/// measured in, and skip when that voice is not installed.
@MainActor
final class SpeechMarkupGuardTests: XCTestCase {

    // MARK: - Fixtures

    /// The sentence of *Rainbows End* that stopped the user's reading on
    /// October 7, 2026, a silent message marked up as the book marks them.
    static let rainbowsEndSentence =
        "Braun: <sm>This is the best you could recruit, Alfred?</sm> Alfred didn't reply directly."

    /// A direct-speech chunk that begins after the opening tag and so holds
    /// a closing tag with no opening one: the engine refused it, cancelled
    /// with 0 frames.
    static let chunkAfterOpeningTag = "could recruit, Alfred?</sm> Alfred didn't reply directly."

    /// The replacements, as they read in an expectation.
    private static let open = SpeechMarkupGuard.openingBracketReplacement
    private static let close = SpeechMarkupGuard.closingBracketReplacement

    /// Texts the guard changes, with what each becomes.
    private static let changedTexts: [(input: String, output: String)] = [
        (rainbowsEndSentence,
         "Braun: \(open)sm\(close)This is the best you could recruit, Alfred?\(open)/sm\(close) Alfred didn't reply directly."),
        (chunkAfterOpeningTag, "could recruit, Alfred?\(open)/sm\(close) Alfred didn't reply directly."),
        ("Mitsuri: <sm>In fact, I'm in my office, admiring the moonlight.",
         "Mitsuri: \(open)sm\(close)In fact, I'm in my office, admiring the moonlight."),
        // The engine's own closing-tag pattern allows spaces, an empty
        // name, and a line break.
        ("odd text </ > here", "odd text \(open)/ \(close) here"),
        ("odd text < /sm> here", "odd text \(open) /sm\(close) here"),
        ("odd </\nsm> text", "odd \(open)/\nsm\(close) text"),
        ("a paragraph <p>inside</p> the text", "a paragraph \(open)p\(close)inside\(open)/p\(close) the text"),
        // A single name between spaced brackets swallowed what followed.
        ("x < y > z", "x \(open) y \(close) z"),
        ("x < 5 > y", "x \(open) 5 \(close) y"),
        ("value <5> next", "value \(open)5\(close) next"),
        ("x << 2 >> 1 done", "x <\(open) 2 \(close)> 1 done"),
        ("see < a href=\"x\" > here", "see \(open) a href=\"x\" \(close) here"),
        // Attributes, quoted, bare, and a self-closing slash.
        ("see <a href=\"x\">here</a> now", "see \(open)a href=\"x\"\(close)here\(open)/a\(close) now"),
        ("see <a href='x'>here</a> now", "see \(open)a href='x'\(close)here\(open)/a\(close) now"),
        ("cell <td colspan=2> wide", "cell \(open)td colspan=2\(close) wide"),
        ("a line <br/> break <br /> here", "a line \(open)br/\(close) break \(open)br /\(close) here"),
        ("write a <sm\n> message", "write a \(open)sm\n\(close) message"),
        // Declarations, comments, and processing instructions.
        ("start <!DOCTYPE html> page", "start \(open)!DOCTYPE html\(close) page"),
        ("note <!-- aside --> end", "note \(open)!-- aside --\(close) end"),
        ("<?xml version=\"1.0\"?> then", "\(open)?xml version=\"1.0\"?\(close) then"),
        ("x<y>z", "x\(open)y\(close)z"),
        ("Caf\u{00E9} <été> fin", "Caf\u{00E9} \(open)été\(close) fin"),
    ]

    /// Texts the guard leaves exactly as they are: brackets the engine
    /// speaks as "less than" and "greater than", and brackets that are no
    /// run at all.
    private static let untouchedTexts: [String] = [
        "x < y and y > z, so 3 < 4.",
        "3 < 4.",
        "a<b",
        "the sign < stands alone here",
        "the sign > stands alone here",
        "I <3 this book",
        "a <= b and c >= d",
        "a<b and c>d",
        "see <a b c> here",
        "see <a b> here",
        "see <a b c=\"d\"> here",
        "x <- 5 and y > 2",
        "x < y z > w",
        "write a <sm\nclass> message",
        "<<",
        "<",
        ">",
        "",
        "Lamps came on along the pier.",
        "the quote \u{2039}sm\u{203A} is already harmless",
    ]

    // MARK: - What changes

    /// The sentence that stopped the reading keeps every word and loses
    /// only its four brackets.
    func testTheRainbowsEndSentenceKeepsItsWordsAndLosesItsBrackets() {
        let guarded = SpeechMarkupGuard.neutralized(Self.rainbowsEndSentence)

        XCTAssertEqual(guarded, Self.changedTexts[0].output)
        XCTAssertFalse(guarded.contains("<"))
        XCTAssertFalse(guarded.contains(">"))
        XCTAssertTrue(guarded.contains("This is the best you could recruit, Alfred?"))
    }

    /// A chunk that begins after the opening tag holds a closing tag with
    /// no opening one, which the engine refuses; guarded, it holds none.
    func testAChunkThatBeginsAfterAnOpeningTagHasItsClosingTagNeutralized() {
        XCTAssertEqual(
            SpeechMarkupGuard.neutralized(Self.chunkAfterOpeningTag),
            "could recruit, Alfred?\(Self.open)/sm\(Self.close) Alfred didn't reply directly."
        )
    }

    /// Every tag-shaped run becomes its quotation marks: the engine's
    /// loosely written closing tags, balanced tags, a single name between
    /// spaced brackets, attributes, and declarations.
    func testEveryTagShapedRunLosesItsBrackets() {
        for (input, output) in Self.changedTexts {
            XCTAssertEqual(SpeechMarkupGuard.neutralized(input), output, input.debugDescription)
        }
    }

    /// The ranges found run from each `<` to its `>`, in text order.
    func testTagRangesRunFromEachOpeningBracketToItsClosingBracket() {
        let text = Self.rainbowsEndSentence as NSString
        let ranges = SpeechMarkupGuard.tagRanges(in: Self.rainbowsEndSentence)

        XCTAssertEqual(ranges.map { text.substring(with: $0) }, ["<sm>", "</sm>"])
        XCTAssertEqual(ranges.map(\.location), [7, 54])
        XCTAssertEqual(SpeechMarkupGuard.tagRanges(in: "x < y and y > z"), [])
    }

    // MARK: - What stays

    /// Math and code keep their brackets, so "less than" and "greater than"
    /// are still spoken: brackets with spaces on both sides and more than
    /// one word between them, a `<` with no `>` after it, a lone `>`,
    /// `<=`, `<-`, and bracketed words without `name=value` attributes,
    /// which the engine speaks as text too.
    func testBracketsThatAreNoTagStayAsTheyAre() {
        for text in Self.untouchedTexts {
            XCTAssertEqual(SpeechMarkupGuard.neutralized(text), text, text.debugDescription)
            XCTAssertEqual(SpeechMarkupGuard.tagRanges(in: text), [], text.debugDescription)
        }
    }

    /// A text without brackets comes back as it is.
    func testATextWithoutBracketsIsReturnedIdentical() {
        let text = "Lamps came on along the pier, and nobody looked up."

        XCTAssertEqual(SpeechMarkupGuard.neutralized(text), text)
        XCTAssertEqual(SpeechMarkupGuard.neutralized(""), "")
    }

    // MARK: - Invariants

    /// Every output has exactly the UTF-16 length of its input, so every
    /// offset the synthesizer reports for the guarded text is an offset into
    /// the original.
    func testEveryOutputHasItsInputsLength() {
        let inputs = Self.changedTexts.map(\.input) + Self.untouchedTexts
        for input in inputs {
            XCTAssertEqual(
                SpeechMarkupGuard.neutralized(input).utf16.count,
                input.utf16.count,
                input.debugDescription
            )
        }
        XCTAssertEqual(SpeechMarkupGuard.openingBracketReplacement.utf16.count, 1)
        XCTAssertEqual(SpeechMarkupGuard.closingBracketReplacement.utf16.count, 1)
    }

    /// Only brackets change, unit for unit: every other UTF-16 unit of the
    /// output is the input's, and each changed unit was a `<` or a `>`.
    func testOnlyBracketsChange() {
        for (input, _) in Self.changedTexts {
            let guarded = SpeechMarkupGuard.neutralized(input)
            for (before, after) in zip(input.utf16, guarded.utf16) where before != after {
                XCTAssertTrue(
                    (before == 0x3C && after == 0x2039) || (before == 0x3E && after == 0x203A),
                    "\(input.debugDescription) changed \(before) to \(after)"
                )
            }
        }
    }

    /// Guarding is idempotent: a guarded text has no tag-shaped run left.
    func testAGuardedTextIsLeftAlone() {
        for (input, _) in Self.changedTexts {
            let guarded = SpeechMarkupGuard.neutralized(input)
            XCTAssertEqual(SpeechMarkupGuard.neutralized(guarded), guarded, input.debugDescription)
        }
    }

    /// A chapter's worth of prose with a few tags is guarded quickly enough
    /// to run on every utterance, and the tags are found wherever they are.
    func testALongTextIsGuardedQuicklyAndCompletely() {
        var prose = BenchmarkProse(seed: 0x5E_ED)
        let body = prose.text(utf16Length: 100_000)
        let text = "<sm>" + body + "</sm> x < y and y > z <p>end</p>"
        let began = ContinuousClock.now
        let guarded = SpeechMarkupGuard.neutralized(text)
        let elapsed = began.duration(to: .now)

        XCTAssertEqual(guarded.utf16.count, text.utf16.count)
        XCTAssertEqual(SpeechMarkupGuard.tagRanges(in: text).count, 4)
        XCTAssertTrue(guarded.hasPrefix("\(Self.open)sm\(Self.close)"))
        XCTAssertTrue(guarded.hasSuffix("\(Self.open)/sm\(Self.close) x < y and y > z \(Self.open)p\(Self.close)end\(Self.open)/p\(Self.close)"))
        XCTAssertLessThan(elapsed, .seconds(1), "guarding 100,000 units took \(elapsed)")
    }

    // MARK: - The engine itself, offline

    /// The voice the engine's behaviour was measured in.
    static let probeVoiceIdentifier = "com.apple.voice.compact.en-US.Samantha"

    /// The chunk with an unmatched closing tag renders in full once
    /// guarded, where the engine refused it raw (cancelled, 0 frames, on
    /// October 7, 2026). Rendered offline: nothing is heard. What the engine
    /// does with the raw chunk on this Mac is printed for the record, not
    /// asserted, since the guard must render whatever the engine does.
    func testAChunkWithAnUnmatchedClosingTagRendersOnceGuarded() throws {
        let voice = try Self.probeVoice()
        let raw = OfflineRenderProbe(Self.chunkAfterOpeningTag, voice: voice)
        let rawEnd = render(raw)
        let guarded = OfflineRenderProbe(SpeechMarkupGuard.neutralized(Self.chunkAfterOpeningTag), voice: voice)
        let guardedEnd = render(guarded)

        print("SpeechMarkupGuard: the raw chunk \(rawEnd.map { "\($0)" } ?? "timed out") with \(raw.frames) frames; "
            + "the guarded chunk \(guardedEnd.map { "\($0)" } ?? "timed out") with \(guarded.frames) frames")
        XCTAssertEqual(guardedEnd, .finished, "the guarded chunk did not render")
        XCTAssertGreaterThan(guarded.frames, 0)
        XCTAssertGreaterThanOrEqual(guarded.frames, raw.frames, "the guard lost audio")
    }

    /// After the engine refuses an utterance, a fresh synthesizer speaks at
    /// once, which is why `SpeechService` replaces its synthesizer after an
    /// unexpected cancel instead of speaking again on the one that refused
    /// (which waited 10 s for nothing in the October 7 probe). Rendered
    /// offline: nothing is heard. Skips when the engine on this Mac does
    /// not refuse the chunk, since there is then no refusal to recover from.
    func testAFreshSynthesizerSpeaksAfterARefusal() throws {
        let voice = try Self.probeVoice()
        let refused = OfflineRenderProbe(Self.chunkAfterOpeningTag, voice: voice)
        guard render(refused) == .cancelled, refused.frames == 0 else {
            throw XCTSkip("The engine on this Mac did not refuse the chunk; there is no refusal to recover from")
        }

        let fresh = OfflineRenderProbe("could recruit, Alfred? Alfred didn't reply directly.", voice: voice)
        let end = render(fresh)

        XCTAssertEqual(end, .finished, "the fresh synthesizer did not speak")
        XCTAssertGreaterThan(fresh.frames, 0)
    }

    /// The compact Samantha voice, or a skip when it is not installed.
    static func probeVoice() throws -> AVSpeechSynthesisVoice {
        guard let voice = AVSpeechSynthesisVoice(identifier: Self.probeVoiceIdentifier) else {
            throw XCTSkip("The voice \(Self.probeVoiceIdentifier) is not installed")
        }
        return voice
    }

    /// Render `probe`'s text offline in its turn on the app's render queue,
    /// so that it overlaps no render of the app's, and return how it ended
    /// within `timeout` seconds, or nil when it did not end. The turn ends
    /// at the timeout whatever the synthesizer does, so a synthesizer that
    /// never answers cannot hold the queue.
    @discardableResult
    func render(_ probe: OfflineRenderProbe, timeout: TimeInterval = 10) -> OfflineRenderProbe.End? {
        let reported = OSAllocatedUnfairLock(initialState: false)
        SpeechRenderCoordinator.shared.enqueue(
            textLength: probe.textLength,
            shouldStart: { true },
            start: { finish in
                let report = VoiceWarmUp.reportingOnce(finish)
                probe.begin(reportingEnd: report)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    report(false)
                }
            },
            completion: { _ in reported.withLock { $0 = true } }
        )
        XCTAssertTrue(
            eventually(within: timeout + 5) { reported.withLock { $0 } },
            "the render never reported"
        )
        probe.stop()
        return probe.end
    }
}

// MARK: - Test doubles

/// Renders one text offline (`write`, no sound) with a synthesizer of its
/// own, counts the frames it writes, and hears how the render ended, on
/// whatever thread the synthesizer reports. `@unchecked Sendable`: its
/// counts are under a lock, and its synthesizer and utterance are used only
/// by `begin` and `stop`, from the main thread.
final class OfflineRenderProbe: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    /// How a render ended.
    enum End: Equatable {
        /// The synthesizer finished the utterance.
        case finished
        /// The synthesizer cancelled it: a refusal when no frame was written.
        case cancelled
    }

    /// The synthesizer the render uses: a fresh one unless given.
    private let synthesizer: AVSpeechSynthesizer
    /// The utterance rendered.
    private let utterance: AVSpeechUtterance
    /// The text's length in UTF-16 units, for the render queue.
    let textLength: Int
    /// How the render ended, the frames written so far, and whom to tell
    /// of the end.
    private let state = OSAllocatedUnfairLock<(end: End?, frames: Int, report: (@Sendable (Bool) -> Void)?)>(
        initialState: (nil, 0, nil)
    )

    init(_ text: String, voice: AVSpeechSynthesisVoice, synthesizer: AVSpeechSynthesizer = AVSpeechSynthesizer()) {
        self.synthesizer = synthesizer
        textLength = text.utf16.count
        utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.prefersAssistiveTechnologySettings = false
        super.init()
        synthesizer.delegate = self
    }

    /// How the render ended, or nil while it has not.
    var end: End? { state.withLock { $0.end } }

    /// The frames written so far.
    var frames: Int { state.withLock { $0.frames } }

    /// Start the render, telling `report` once the synthesizer finishes or
    /// cancels the utterance. The buffer callback is formed here, outside
    /// the main actor, since the synthesizer may call it on any thread.
    func begin(reportingEnd report: @escaping @Sendable (Bool) -> Void) {
        state.withLock { $0.report = report }
        synthesizer.write(utterance) { [self] buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            // Read outside the lock: the buffer is not Sendable.
            let frames = Int(pcm.frameLength)
            state.withLock { $0.frames += frames }
        }
    }

    /// Stop the synthesizer, should it still be rendering.
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// Record how the render ended and tell whoever waits for it.
    private func ended(_ end: End) {
        let report = state.withLock { state -> (@Sendable (Bool) -> Void)? in
            if state.end == nil { state.end = end }
            return state.report
        }
        report?(true)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        ended(.finished)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        ended(.cancelled)
    }
}
