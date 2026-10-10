import AVFoundation
import Foundation

// Offline probe of the control characters a book's text can hold, for
// `SpeechMarkupGuard` (fix/now-playing-followups, October 9, 2026; board
// #1542). Every text is rendered with `AVSpeechSynthesizer.write(_:toBufferCallback:)`,
// which renders audio into buffers and plays nothing, and the frames each
// render produced are counted.
//
// Each control sits inside one long sentence, between two letters ("a", the
// control, "b"), so that a control which swallows the words after it shows
// as missing frames: compare a control's `raw` render with `none`, the same
// sentence without it. A render that ends `cancelled` with 0 frames is a
// refusal, which `SpeechService` hears as an unexpected cancel; one that
// finishes short of `none` swallowed words silently, which nothing in the
// app hears. The `space` form puts a space where the control was, one UTF-16
// unit for one, as the guard does with the controls it replaces.
//
// A control cannot travel in a command-line argument (a NUL ends one), so
// the child is given the code point in hexadecimal and builds the sentence.
//
// Build once and run every control, each render in a process of its own, so
// that a synthesizer the engine refused cannot affect the next render:
//
//     swiftc -O Scripts/agents/probes/speech-control-character-probe.swift -o "$TMPDIR/controls"
//     "$TMPDIR/controls" all                    # C0, DEL, and C1, compact Samantha
//     "$TMPDIR/controls" all com.apple.speech.synthesis.voice.Alex
//     "$TMPDIR/controls" one 0 [voice]          # one code point, in hexadecimal
//
// The results recorded on October 10, 2026 are at the end of this file.

/// The voice the user reads with, which every refusal so far was measured in.
let defaultVoiceIdentifier = "com.apple.voice.compact.en-US.Samantha"

/// The words before each control.
let lead = "The reader went on with the story a"
/// The words after each control: long, so that swallowing them is plain.
let tail = "b and every word after it should still be heard, all the way to the very end of this rather long sentence."

/// Every code point probed: the C0 controls, DEL, and the C1 controls.
let codePoints: [UInt32] = Array(0x00...0x1F) + [0x7F] + Array(0x80...0x9F)

/// The sentence for `form` of the control `codePoint`: `raw` holds the
/// control itself, `space` a space in its place, and `none` neither.
func sentence(form: String, codePoint: UInt32) -> String {
    switch form {
    case "raw":
        guard let scalar = Unicode.Scalar(codePoint) else { return "\(lead)\(tail)" }
        return "\(lead)\(Character(scalar))\(tail)"
    case "space":
        return "\(lead) \(tail)"
    default:
        return "\(lead)\(tail)"
    }
}

/// Renders one text offline and counts the frames written. `@unchecked
/// Sendable` because the synthesizer, which is not Sendable, is used only on
/// the main thread, where `write` was called and where the callbacks arrive.
final class Probe: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    let synthesizer = AVSpeechSynthesizer()
    var frames = 0
    var outcome = "pending"

    /// Render `text` in `voice`, waiting at most `seconds` for the end; the
    /// callbacks arrive on the main thread, which this run loop turns.
    func run(_ text: String, voice: AVSpeechSynthesisVoice, seconds: Double = 12) -> String {
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

/// Runs this program again as a child that renders `form` of `codePoint`
/// in `voiceIdentifier`, and returns what it printed: the outcome and the
/// frames, such as "finished 150000".
func renderInChild(form: String, codePoint: UInt32, voiceIdentifier: String) -> String {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["render", form, String(codePoint, radix: 16), voiceIdentifier]
    let output = Pipe()
    child.standardOutput = output
    do {
        try child.run()
    } catch {
        return "failed 0"
    }
    child.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// The frames in a child's report ("finished 150000" gives 150000).
func frames(of report: String) -> Int {
    Int(report.split(separator: " ").last ?? "") ?? 0
}

/// What a control did to its sentence, judged against `none`: refused,
/// swallowed (under nine tenths of the frames), or spoken in full.
func verdict(raw: String, none: Int) -> String {
    if raw.hasPrefix("cancelled"), frames(of: raw) == 0 { return "REFUSED" }
    if !raw.hasPrefix("finished") { return "ENDED \(raw)" }
    return frames(of: raw) * 10 < none * 9 ? "SWALLOWED" : "spoken"
}

let arguments = CommandLine.arguments
let mode = arguments.count > 1 ? arguments[1] : "all"

if mode == "render" {
    // The child: render one form of one code point.
    let form = arguments[2]
    let codePoint = UInt32(arguments[3], radix: 16) ?? 0
    let voice = AVSpeechSynthesisVoice(identifier: arguments[4])!
    // Held in a constant, so the probe outlives the render it waits for.
    let probe = Probe()
    print(probe.run(sentence(form: form, codePoint: codePoint), voice: voice))
} else {
    let voiceArgument = mode == "one" ? (arguments.count > 3 ? arguments[3] : nil) : (arguments.count > 2 ? arguments[2] : nil)
    let voiceIdentifier = voiceArgument ?? defaultVoiceIdentifier
    guard AVSpeechSynthesisVoice(identifier: voiceIdentifier) != nil else {
        print("The voice \(voiceIdentifier) is not installed")
        exit(1)
    }
    let probed = mode == "one" ? [UInt32(arguments[2], radix: 16) ?? 0] : codePoints
    let none = renderInChild(form: "none", codePoint: 0, voiceIdentifier: voiceIdentifier)
    let space = renderInChild(form: "space", codePoint: 0, voiceIdentifier: voiceIdentifier)
    print("voice \(voiceIdentifier)")
    print("none (no control) \(none); space in its place \(space)")
    for codePoint in probed {
        let raw = renderInChild(form: "raw", codePoint: codePoint, voiceIdentifier: voiceIdentifier)
        let label = String(format: "U+%04X", codePoint)
        print("\(label) raw \(raw) -> \(verdict(raw: raw, none: frames(of: none)))")
    }
}

// MARK: - Results, October 10, 2026 (macOS 26.3.1)
//
// Each render finished; "frames" is the audio rendered for the sentence.
//
// Compact Samantha (com.apple.voice.compact.en-US.Samantha), the user's voice:
//   none (no control)          finished 150282
//   space in its place         finished 151050
//   U+0000 (NUL)               finished  39434  SWALLOWED: every word after it lost, no cancel
//   U+0001 to U+0008           finished 150282  spoken
//   U+0009, U+000A, U+000D     finished 151050  spoken (heard as a space)
//   U+000B, U+000C             finished 150282  spoken
//   U+000E to U+001F           finished 150282  spoken
//   U+007F (DEL)               finished 151050  spoken
//   U+0080 to U+009F (C1)      finished 150282 to 153354  spoken
//
// Alex (com.apple.speech.synthesis.voice.Alex):
//   none 180963, space 185571; every code point probed, U+0000 included,
//   finished with 185059 to 207843 frames: nothing swallowed.
//
// So only the NUL loses words, and only in Samantha; `SpeechMarkupGuard`
// turns each NUL into a space, one UTF-16 unit for one, and leaves every
// other control character as it is.
