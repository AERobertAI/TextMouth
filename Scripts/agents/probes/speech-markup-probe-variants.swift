import AVFoundation
import Foundation

/// One variant per process, named by the first argument: renders it
/// offline (no sound) and reports finished/cancelled/timeout and the
/// frames produced. "recover" renders an unbalanced tag first, then a
/// plain text on a NEW synthesizer instance, to see whether a fresh
/// instance speaks again after a refusal.
final class Probe: NSObject, AVSpeechSynthesizerDelegate {
    var synth = AVSpeechSynthesizer()
    var frames = 0
    var outcome = "pending"
    func run(_ text: String, seconds: Double = 8) -> String {
        frames = 0; outcome = "pending"
        synth.delegate = self
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: "com.apple.voice.compact.en-US.Samantha")
        utterance.prefersAssistiveTechnologySettings = false
        synth.write(utterance) { [weak self] buffer in
            if let pcm = buffer as? AVAudioPCMBuffer { self?.frames += Int(pcm.frameLength) }
        }
        let deadline = Date().addingTimeInterval(seconds)
        while outcome == "pending", Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if outcome == "pending" { outcome = "timeout"; synth.stopSpeaking(at: .immediate) }
        return "\(outcome), frames=\(frames)"
    }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { outcome = "finished" }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { outcome = "cancelled" }
}
let unbalanced = "could recruit, Alfred?</sm> Alfred didn't reply directly."
let variants: [String: String] = [
    "balanced": "Braun: <sm>This is the best you could recruit, Alfred?</sm> Alfred didn't reply.",
    "opening-only": "Mitsuri: <sm>In fact, I'm in my office, admiring the moonlight.",
    "angle-quotes": unbalanced.replacingOccurrences(of: "<", with: "\u{2039}").replacingOccurrences(of: ">", with: "\u{203A}"),
    "fullwidth": unbalanced.replacingOccurrences(of: "<", with: "\u{FF1C}").replacingOccurrences(of: ">", with: "\u{FF1E}"),
    "zwsp-after-lt": unbalanced.replacingOccurrences(of: "<", with: "<\u{200B}"),
    "space-after-lt": unbalanced.replacingOccurrences(of: "<", with: "< "),
    "entity": unbalanced.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;"),
    "lt-only": "the sign < stands alone here",
    "close-no-name": "odd text </ > here",
    "lt-word": "write a <sm> message",
    "lt-space-word": "write a < sm > message",
    "html-p": "a paragraph <p>inside</p> the text",
]
let name = CommandLine.arguments[1]
let probe = Probe()
if name == "recover" {
    let first = probe.run(unbalanced, seconds: 4)
    probe.synth = AVSpeechSynthesizer()
    let second = probe.run("could recruit, Alfred? Alfred didn't reply directly.", seconds: 8)
    print("recover: first=\(first); fresh-instance plain=\(second)")
} else if name == "recover-same" {
    let first = probe.run(unbalanced, seconds: 4)
    let second = probe.run("could recruit, Alfred? Alfred didn't reply directly.", seconds: 8)
    print("recover-same: first=\(first); same-instance plain=\(second)")
} else {
    print("\(name): \(probe.run(variants[name]!))")
}
