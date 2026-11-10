import AVFoundation
import Foundation

// Offline probe of what a soft hyphen (U+00AD) inside a word does to the Mac's speech engine
// (readers/kf8-followups, November 9, 2026). Every text is rendered with
// `AVSpeechSynthesizer.write(_:toBufferCallback:)`, which renders audio into buffers and plays nothing, and the
// frames each render produced are counted, as the probes beside this one do.
//
// Each sentence is rendered in four forms, each in a synthesizer of its own so that no render can affect the next:
//   - `plain`: the words as they are;
//   - `soft`: a soft hyphen in the middle of each long word;
//   - `space`: a space where each soft hyphen was (what a split word sounds like, for comparison);
//   - `hyphen`: a visible hyphen-minus where each soft hyphen was (what a listener would hear for a hyphenated word).
// A soft hyphen the engine ignores renders the same frames as `plain`; one it takes for a word break renders
// the frames of `space`.
//
//     swiftc -O Scripts/agents/probes/speech-soft-hyphen-probe.swift -o "$TMPDIR/shy"
//     "$TMPDIR/shy" [voice identifier]
//
// The results recorded on November 9, 2026 are at the end of this file.

/// The voice the user reads with.
let defaultVoiceIdentifier = "com.apple.voice.compact.en-US.Samantha"

/// The sentences, each with the words that a soft hyphen goes inside (at the position given).
let sentences: [(text: String, words: [String])] = [
    ("The hyphenation of typesetting is an extraordinary accomplishment of international communication.",
     ["hyphenation", "typesetting", "extraordinary", "accomplishment", "international", "communication"]),
    ("Nobody expected the unbelievable production of the productivity tools, nor their enormous popularity.",
     ["unbelievable", "production", "productivity", "enormous", "popularity"]),
]

/// `text` with `mark` inside each of `words` at its middle (every occurrence).
func marked(_ text: String, words: [String], with mark: String) -> String {
    var result = text
    for word in words {
        let middle = word.index(word.startIndex, offsetBy: word.count / 2)
        let split = String(word[..<middle]) + mark + String(word[middle...])
        result = result.replacingOccurrences(of: word, with: split)
    }
    return result
}

/// Renders one text offline and counts the frames written. `@unchecked Sendable` because the synthesizer, which is
/// not Sendable, is used only on the main thread, where `write` was called and where the callbacks arrive.
final class Probe: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    let synthesizer = AVSpeechSynthesizer()
    var frames = 0
    var outcome = "pending"

    /// Render `text` in `voice`, waiting at most `seconds` for the end.
    func run(_ text: String, voice: AVSpeechSynthesisVoice, seconds: Double = 15) -> String {
        synthesizer.delegate = self
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.prefersAssistiveTechnologySettings = false
        synthesizer.write(utterance) { [weak self] buffer in
            if let pcm = buffer as? AVAudioPCMBuffer { self?.frames += Int(pcm.frameLength) }
        }
        let deadline = Date().addingTimeInterval(seconds)
        while outcome == "pending", Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if outcome == "pending" {
            outcome = "timeout"
            synthesizer.stopSpeaking(at: .immediate)
        }
        return "\(outcome) \(frames)"
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { outcome = "finished" }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { outcome = "cancelled" }
}

let identifier = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : defaultVoiceIdentifier
guard let voice = AVSpeechSynthesisVoice(identifier: identifier) else {
    print("no voice \(identifier)")
    exit(2)
}
print("voice \(identifier)")
for (text, words) in sentences {
    print("sentence: \(text)")
    for (form, mark) in [("plain", ""), ("soft", "\u{AD}"), ("space", " "), ("hyphen", "-")] {
        let spoken = marked(text, words: words, with: mark)
        // A synthesizer of its own for each render, kept alive until the render has ended.
        let probe = Probe()
        let result = probe.run(spoken, voice: voice)
        print("  \(form): \(result)")
    }
}

// Results, November 9, 2026, this Mac (Darwin 25.3.0), compact Samantha (the frames each render produced):
//
//   sentence 1 (hyphenation, typesetting, extraordinary, accomplishment, international, communication)
//     plain 115,466    soft 118,026    space 122,634    hyphen 118,026
//   sentence 2 (unbelievable, production, productivity, enormous, popularity)
//     plain 128,611    soft 136,035    space 139,619    hyphen 136,035
//
// Every render finished. A soft hyphen in a word renders exactly the frames a visible hyphen-minus does (2.2% and 5.8%
// more than the same words whole), and fewer than a space (a split word): the engine does not ignore the character, it
// reads the word as a hyphenated one, with a break in it. So the soft hyphens a publisher put inside words are heard,
// as pauses, wherever the book is read aloud, and they are left out of the text instead (`ParserUtilities.removingSoftHyphens`).
