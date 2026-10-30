import AVFoundation
import XCTest
@testable import TextMouth

/// Speaking a chapter of a speech export (FMT43) into buffers through the
/// synthesizer seam (`SpeechBufferSynthesizing`).
///
/// Every test uses `FakeSpeechBufferSynthesizer`, which makes a quiet tone
/// in memory, or gives the Mac's synthesizer a voice it refuses before any
/// synthesizer exists: no test runs a real synthesizer or makes a sound.
final class SpeechChapterRendererTests: XCTestCase {

    /// The voice every utterance names: no voice has it, and no test speaks
    /// in one.
    private static let voice = "com.textmouth.tests.voice.speech-export"

    /// `text` as an utterance in the tests' voice at the rate for 250 words
    /// a minute and the pitch 1.3.
    private static func utterance(_ text: String) -> SpeechExportUtterance {
        SpeechExportUtterance(
            text: text,
            voiceIdentifier: voice,
            rate: SpeechService.rateForWPM(250),
            pitchMultiplier: Float(SpeechService.clampedPitch(1.3))
        )
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
}
