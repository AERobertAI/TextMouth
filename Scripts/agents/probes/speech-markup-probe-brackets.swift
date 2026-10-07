import AVFoundation
import Foundation
final class Probe: NSObject, AVSpeechSynthesizerDelegate {
    let synth = AVSpeechSynthesizer(); var frames = 0; var outcome = "pending"
    func run(_ text: String) -> String {
        synth.delegate = self
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(identifier: "com.apple.voice.compact.en-US.Samantha")
        u.prefersAssistiveTechnologySettings = false
        synth.write(u) { [weak self] b in if let p = b as? AVAudioPCMBuffer { self?.frames += Int(p.frameLength) } }
        let deadline = Date().addingTimeInterval(8)
        while outcome == "pending", Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        if outcome == "pending" { outcome = "timeout"; synth.stopSpeaking(at: .immediate) }
        return "\(outcome), frames=\(frames)"
    }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { outcome = "finished" }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { outcome = "cancelled" }
}
let v: [String: String] = [
    "bare": "the sign stands alone here",
    "lt": "the sign < stands alone here",
    "gt": "the sign > stands alone here",
    "sq-lt": "the sign \u{2039} stands alone here",
    "sq-gt": "the sign \u{203A} stands alone here",
    "fw-lt": "the sign \u{FF1C} stands alone here",
    "math-raw": "x < y and y > z, so 3 < 4.",
    "math-gutted": "x z, so 3 < 4.",
    "math-sq": "x \u{2039} y and y \u{203A} z, so 3 < 4.",
    "math-fw": "x \u{FF1C} y and y \u{FF1E} z, so 3 < 4.",
    "tag-sq": "Braun: \u{2039}sm\u{203A}This is the best you could recruit, Alfred?\u{2039}/sm\u{203A} Alfred didn't reply.",
    "tag-gutted": "Braun: This is the best you could recruit, Alfred? Alfred didn't reply.",
    "tag-fw": "Braun: \u{FF1C}sm\u{FF1E}This is the best you could recruit, Alfred?\u{FF1C}/sm\u{FF1E} Alfred didn't reply.",
]
let name = CommandLine.arguments[1]
print("\(name): \(Probe().run(v[name]!))")
