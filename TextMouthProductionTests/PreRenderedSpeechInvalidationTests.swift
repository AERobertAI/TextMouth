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
}
