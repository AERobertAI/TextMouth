import AVFoundation
import Foundation

// Offline probe of how fast the Mac renders a chapter's speech ahead of time
// (perf/playback-idle, audit C11, November 15, 2026). The reader renders the
// next chapter with `AVSpeechSynthesizer.write(_:toBufferCallback:)` at rate
// 0.7, as `AudioEngineService.write` does, and since C11 starts that render
// only a lead before the current chapter's end. The lead must be several
// times the render's own time, so this measures it: for each voice and each
// text length, the wall-clock seconds of the write, the seconds of audio it
// made, and what that audio weighs as the 16-bit samples the app keeps.
//
// It writes to buffers only and keeps none of them, so nothing is heard and
// the probe's memory stays small. Build and run it under the heavy-work lock:
//
//     python3 -I Scripts/agents/run_locked.py NAME swiftc -O \
//         Scripts/agents/probes/speech-render-speed-probe.swift -o SCRATCH/render-speed
//     python3 -I Scripts/agents/run_locked.py NAME SCRATCH/render-speed [voice identifier ...]
//
// With no arguments it measures Samantha, the Eloquence voice Eddy, and every
// installed English voice of enhanced or premium quality.
//
// The result recorded on November 15, 2026 is at the end of this file.

/// The lengths measured, in UTF-16 units: a short chapter, a novel's chapter,
/// and the longest text the app renders (`SpeechRenderCoordinator.maximumTextLength`).
let lengths = [2_000, 20_000, 100_000]

/// Plain English prose of exactly `length` UTF-16 units, made from a fixed
/// word list with a fixed generator, so every run measures the same text.
func prose(ofLength length: Int) -> String {
    let words = [
        "the", "harbour", "ferry", "left", "before", "noon", "and", "nobody", "counted", "gulls",
        "along", "wall", "while", "a", "clerk", "wrote", "down", "every", "crate", "of", "salted",
        "fish", "that", "came", "ashore", "from", "northern", "boats", "in", "late", "autumn",
        "weather", "she", "remembered", "how", "her", "uncle", "mended", "nets", "beside", "stove",
    ]
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    var text = ""
    var wordsInSentence = 0
    while text.utf16.count < length {
        // A small linear congruential generator: the same words every run.
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let word = words[Int(state >> 33) % words.count]
        text += wordsInSentence == 0 ? word.capitalized : " " + word
        wordsInSentence += 1
        if wordsInSentence >= 9 + Int(state >> 60) {
            text += ". "
            wordsInSentence = 0
        }
    }
    return String(decoding: Array(text.utf16.prefix(length)), as: UTF16.self)
}

/// What one write came to.
struct Measurement {
    let seconds: Double
    let frames: Int
    let sampleRate: Double
    let finished: Bool
}

/// Counts the frames one write delivers and signals at its last piece.
/// `@unchecked Sendable`: the callback's queue is the only writer until the
/// semaphore is signalled, after which the waiting thread reads.
final class FrameCounter: @unchecked Sendable {
    var frames = 0
    var sampleRate = 0.0
    let finished = DispatchSemaphore(value: 0)
}

/// Write `text` in `voice` at the app's render rate, keeping no audio, and
/// wait for the last piece or `limit` seconds.
func measure(_ text: String, voice: AVSpeechSynthesisVoice, limit: Double) -> Measurement {
    let synthesizer = AVSpeechSynthesizer()
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = voice
    utterance.rate = 0.7
    utterance.prefersAssistiveTechnologySettings = false
    let counter = FrameCounter()
    let began = Date()
    synthesizer.write(utterance) { buffer in
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        if pcm.frameLength > 0 {
            counter.frames += Int(pcm.frameLength)
            counter.sampleRate = pcm.format.sampleRate
        } else {
            counter.finished.signal()
        }
    }
    let result = counter.finished.wait(timeout: .now() + limit)
    if result != .success { synthesizer.stopSpeaking(at: .immediate) }
    return Measurement(
        seconds: Date().timeIntervalSince(began),
        frames: counter.frames,
        sampleRate: counter.sampleRate,
        finished: result == .success
    )
}

/// The voices to measure: those named on the command line, or the defaults.
func voicesToMeasure() -> [AVSpeechSynthesisVoice] {
    let named = CommandLine.arguments.dropFirst().compactMap { AVSpeechSynthesisVoice(identifier: $0) }
    if !named.isEmpty { return Array(named) }
    var chosen: [AVSpeechSynthesisVoice] = []
    for identifier in ["com.apple.voice.compact.en-US.Samantha", "com.apple.eloquence.en-US.Eddy"] {
        if let voice = AVSpeechSynthesisVoice(identifier: identifier) { chosen.append(voice) }
    }
    let better = AVSpeechSynthesisVoice.speechVoices().filter {
        $0.language.hasPrefix("en") && $0.quality != .default
    }
    return chosen + better
}

// The writes run off the main thread, as the app's do, while the main run
// loop turns for whatever the synthesizer posts to it.
DispatchQueue.global(qos: .userInitiated).async {
    for voice in voicesToMeasure() {
        let quality = voice.quality == .premium ? "premium" : voice.quality == .enhanced ? "enhanced" : "default"
        print("voice \(voice.identifier) (\(quality))")
        // One word first, so the voice's loading is not counted in a render.
        _ = measure("Ready.", voice: voice, limit: 60)
        for length in lengths {
            let m = measure(prose(ofLength: length), voice: voice, limit: 600)
            let audioSeconds = m.sampleRate > 0 ? Double(m.frames) / m.sampleRate : 0
            let megabytes = Double(m.frames * 2) / 1_048_576
            print(String(
                format: "  %7d units: %7.2f s to render, %8.1f s of audio at %.0f Hz, %6.1f MB, "
                    + "%6.0f units/s, %5.1fx real time%@",
                length, m.seconds, audioSeconds, m.sampleRate, megabytes,
                Double(length) / max(m.seconds, 0.001), audioSeconds / max(m.seconds, 0.001),
                m.finished ? "" : "  (DID NOT FINISH)"
            ))
        }
    }
    exit(0)
}
RunLoop.main.run()

// Result, November 15, 2026 (macOS 26.3, an 8 GB Mac with other agents' work
// running beside it):
//
//     voice com.apple.voice.compact.en-US.Samantha (default)
//          2000 units:    0.65 s to render,     50.0 s of audio at 22050 Hz,    2.1 MB,   3056 units/s,  76.4x real time
//         20000 units:    6.26 s to render,    493.5 s of audio at 22050 Hz,   20.8 MB,   3193 units/s,  78.8x real time
//        100000 units:  108.67 s to render,   2472.3 s of audio at 22050 Hz,  104.0 MB,    920 units/s,  22.8x real time
//     voice com.apple.eloquence.en-US.Eddy (default)
//          2000 units:    0.25 s to render,     48.7 s of audio at 16000 Hz,    1.5 MB,   7846 units/s, 191.0x real time
//         20000 units:    5.86 s to render,    479.6 s of audio at 16000 Hz,   14.6 MB,   3413 units/s,  81.8x real time
//        100000 units:  127.92 s to render,   2472.3 s of audio at 22050 Hz,  104.0 MB,    782 units/s,  19.3x real time
//     voice com.apple.speech.synthesis.voice.Alex (enhanced)
//          2000 units:    1.16 s to render,     38.9 s of audio at 22050 Hz,    1.6 MB,   1719 units/s,  33.5x real time
//         20000 units:   12.33 s to render,    383.0 s of audio at 22050 Hz,   16.1 MB,   1622 units/s,  31.1x real time
//        100000 units:  134.18 s to render,   1914.0 s of audio at 22050 Hz,   80.5 MB,    745 units/s,  14.3x real time
//
// What it shows:
// - A novel's chapter (20,000 units) renders in 6 to 12 seconds and weighs 15
//   to 21 MB; the longest chapter rendered (100,000) takes 109 to 134 seconds
//   and weighs 80 to 104 MB. Rendering slows as the text grows: a third of
//   the rate at five times the length.
// - `LookAheadLead` assumes 400 units a second, about half the slowest rate
//   here, and takes four times that render time, never under five minutes.
// - `AudioEngineService.write` gives a render two minutes. Two of the three
//   longest renders here took longer, so on a busy Mac a chapter near the
//   limit may not be rendered at all, and plays on in direct speech.
// - Eddy's longest render came back at Samantha's sample rate and Samantha's
//   exact length (2472.3 s at 22,050 Hz, where Eddy's shorter renders are at
//   16,000 Hz): the system seems to have rendered that text in another voice.
//   Not looked into here.
// - No premium voice is installed on this Mac, so none was measured.
