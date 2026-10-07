import AVFoundation
import Foundation

// Offline probe of when the Mac's speech engine refuses an utterance queued
// behind another on the same synthesizer (fix/speech-refusal-followups,
// October 7, 2026). Direct speech queues each chunk behind the one speaking
// (`SpeechService.queueNextDirectChunk()`), and treats a cancel as the
// engine's refusal only when it is for the chunk speaking; a refusal of the
// queued chunk heard before the chunk ahead of it ended would be taken for
// one of the app's own stops. This renders a plain text, then, queued on the
// same synthesizer, a text the engine refuses (a closing tag with no opening
// one), with `AVSpeechSynthesizer.write(_:toBufferCallback:)`, which plays
// nothing, and prints every delegate callback in the order it came.
//
//     swiftc -O Scripts/agents/probes/speech-refusal-probe-queue.swift -o "$TMPDIR/queue"
//     "$TMPDIR/queue" [voice identifier]
//
// The result recorded on October 7, 2026 is at the end of this file.

/// Hears every callback, on the main thread where `write` is called.
/// `@unchecked Sendable`: the delegate protocol is Sendable, and the probe's
/// state is used only on the main thread, where the callbacks arrive.
final class QueueProbe: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    let synthesizer = AVSpeechSynthesizer()
    var events: [String] = []
    var frames: [String: Int] = [:]
    var ended = Set<String>()

    /// The probe's name for `utterance`: its first word.
    func name(of utterance: AVSpeechUtterance) -> String {
        String(utterance.speechString.prefix { $0 != " " })
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) { events.append("start \(name(of: u))") }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        events.append("finish \(name(of: u)) after \(frames[name(of: u)] ?? 0) frames")
        ended.insert(name(of: u))
    }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        events.append("cancel \(name(of: u)) after \(frames[name(of: u)] ?? 0) frames")
        ended.insert(name(of: u))
    }

    /// Queue `texts` on the one synthesizer and wait for each to end.
    func run(_ texts: [String], voice: AVSpeechSynthesisVoice) {
        synthesizer.delegate = self
        for text in texts {
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice
            utterance.prefersAssistiveTechnologySettings = false
            let label = name(of: utterance)
            synthesizer.write(utterance) { [self] buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    events.append("last buffer \(label)")
                } else if frames[label] == nil {
                    events.append("first buffer \(label)")
                }
                frames[label, default: 0] += Int(pcm.frameLength)
            }
        }
        let deadline = Date().addingTimeInterval(20)
        while ended.count < texts.count, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if ended.count < texts.count { events.append("timed out with \(ended.count) of \(texts.count) ended") }
    }
}

let voiceIdentifier = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "com.apple.voice.compact.en-US.Samantha"
guard let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) else {
    print("The voice \(voiceIdentifier) is not installed")
    exit(1)
}
let probe = QueueProbe()
probe.run([
    "Plain: the reader went on with the story, and every word of it should be heard to the end.",
    "Refused: could recruit, Alfred?</sm> Alfred didn't reply directly.",
    "Third: a plain text queued after the refused one, on the same synthesizer.",
], voice: voice)
print("voice \(voiceIdentifier)")
probe.events.forEach { print($0) }

// MARK: - Result, October 7, 2026
//
// macOS 26.3.1, in com.apple.voice.compact.en-US.Samantha and in
// com.apple.speech.synthesis.voice.Alex alike, twice in Samantha:
//
//     start Plain:
//     first buffer Plain:
//     last buffer Plain:
//     last buffer Plain:
//     finish Plain: after 97749 frames      (122464 in Alex)
//     cancel Refused: after 0 frames
//     timed out with 2 of 3 ended
//
// - The refused utterance is cancelled only once the one ahead of it has finished, never
//   while it plays, so by the time direct speech hears the cancel, the queued chunk has
//   become the live one (`promoteQueuedDirectChunk()` at the finish), and the cancel is
//   taken for a refusal, as it must be.
// - The utterance queued behind the refused one never starts, finishes, or is cancelled:
//   the synthesizer drops everything queued after a refusal without a word. A sleep fade's
//   quieter segments queued behind a refused one would never report, which is why the
//   service plans the fade anew on a fresh synthesizer instead of waiting for them.
// - The plain utterance's last, empty buffer came twice. A render's wait
//   (`AudioEngineService.render`) and the voice warm-up (`VoiceWarmUp.reportingOnce`) act on
//   the first and ignore the second.
