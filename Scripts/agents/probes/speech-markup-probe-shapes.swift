import AVFoundation
import Foundation

// Offline probe of the shapes of text that the Mac's speech engine may read
// as markup, for `SpeechMarkupGuard` (fix/speech-refusal-followups, October 7,
// 2026). Every text is rendered with `AVSpeechSynthesizer.write(_:toBufferCallback:)`,
// which renders audio into buffers and plays nothing, and the frames each
// render produced are counted.
//
// Each shape sits inside one long sentence, so that a shape which swallows
// the words after it shows as missing frames: compare a shape's `raw` render
// with `none`, the same sentence without the shape. A render that ends
// `cancelled` with 0 frames is a refusal, which `SpeechService` hears as an
// unexpected cancel; a render that finishes short of `none` swallowed words
// silently, which nothing in the app hears.
//
// Forms of each shape:
// - `raw`: the shape as a book holds it.
// - `quoted`: its first `<` and last `>` as U+2039 and U+203A, which is what
//   the default guard makes of a tag-shaped run.
// - `strict`: every `<` and `>` replaced by those marks, one UTF-16 unit for
//   one, as `SpeechMarkupGuard.neutralizedStrictly(_:)` does for a refused
//   chunk.
// - For a shape with `&`: `fullwidth-amp` and `small-amp`, the brackets as in
//   `strict` and every `&` as U+FF06 or U+FE60, and `no-amp`, every `&` as a
//   space, to tell whether the engine speaks or parses the ampersand.
//
// Build once and run every variant, each in a process of its own, so that a
// synthesizer the engine refused cannot affect the next render:
//
//     swiftc -O Scripts/agents/probes/speech-markup-probe-shapes.swift -o "$TMPDIR/shapes"
//     "$TMPDIR/shapes" all                      # every variant, compact Samantha
//     "$TMPDIR/shapes" all com.apple.speech.synthesis.voice.Alex
//     "$TMPDIR/shapes" one <label> [voice]     # one variant
//
// The results recorded on October 7, 2026 are at the end of this file.

/// The voice the user reads with, which every refusal so far was measured in.
let defaultVoiceIdentifier = "com.apple.voice.compact.en-US.Samantha"

/// The words before each shape.
let lead = "The reader went on with the story"
/// The words after each shape: long, so that swallowing them is plain.
let tail = "and every word after it should still be heard, all the way to the very end of this rather long sentence."

/// The sentence holding `shape`, or the sentence alone when it is empty.
func sentence(_ shape: String) -> String {
    shape.isEmpty ? "\(lead) \(tail)" : "\(lead) \(shape) \(tail)"
}

/// `shape` with its first `<` and its last `>` replaced by the single angle
/// quotation marks, as the default guard replaces a tag-shaped run's brackets.
func quoted(_ shape: String) -> String {
    var units = Array(shape.utf16)
    if let first = units.firstIndex(of: 0x3C) { units[first] = 0x2039 }
    if let last = units.lastIndex(of: 0x3E) { units[last] = 0x203A }
    return String(utf16CodeUnits: units, count: units.count)
}

/// `shape` with every `<` and `>` replaced by the angle quotation marks, one
/// unit for one, and, when `ampersand` is given, every `&` by it.
func strict(_ shape: String, ampersand: UInt16? = nil) -> String {
    let units = shape.utf16.map { unit -> UInt16 in
        switch unit {
        case 0x3C: return 0x2039
        case 0x3E: return 0x203A
        case 0x26: return ampersand ?? unit
        default: return unit
        }
    }
    return String(utf16CodeUnits: units, count: units.count)
}

/// The shapes the review of October 7 asked for, then a few more of the
/// same families, each with a short label.
let shapes: [(label: String, shape: String)] = [
    ("ellipsis", "the omitted <...> passage"),
    ("spaceship", "a <=> b"),
    ("double-arrow", "x <-> y"),
    ("perl-handle", "<$fh>"),
    ("star", "<*>"),
    ("dash-aside", "<-- aside -->"),
    ("comment", "<!-- comment -->"),
    ("xml-declaration", "<?xml version=\"1.0\"?>"),
    ("doctype", "<!DOCTYPE html>"),
    ("fish-and-chips", "fish & chips"),
    ("amp-entity", "&amp;"),
    ("lt-entity", "&#60;"),
    ("at-and-t", "AT&T"),
    // More of the same families.
    ("empty", "<>"),
    ("space-only", "< >"),
    ("hash", "<#>"),
    ("at-name", "<@reader>"),
    ("dot-name", "<.x>"),
    ("dash-name", "<-x>"),
    ("equals-name", "<=x>"),
    ("digit-dash", "<3-4>"),
    ("autolink", "<https://example.com/page>"),
    ("mail-link", "<reader@example.com>"),
    ("closing-empty", "</>"),
    ("bang-only", "<!>"),
    ("question-only", "<?>"),
    ("lt-entity-named", "&lt;sm&gt;"),
    ("unknown-entity", "&nbsp;"),
    ("bare-amp-word", "R&D"),
    ("amp-with-tag", "fish & chips <p>here</p>"),
    ("amp-entity-with-tag", "&amp; <p>here</p>"),
    // Names the widened rule takes, and runs it must leave alone.
    ("equals-inside", "<a=b>"),
    ("spaced-equals", "< = >"),
    ("sql-not-equal", "a <> b"),
    ("double-quoted", "<\"x\">"),
    ("single-quoted", "<'x'>"),
    ("backslash", "<\\>"),
    ("emoji", "<\u{1F642}>"),
    ("slash-inside", "<a/b>"),
    ("self-closing", "<a/>"),
    ("bare-after-attribute", "<x y=1 z>"),
    ("bare-before-attribute", "see <a b c=\"d\"> here"),
    ("two-bare-words", "x < y z > w"),
    ("line-break-bare", "write a <sm\nclass> message"),
    ("generic", "Array<Int>"),
    ("generic-pair", "Map<String, Int>"),
    ("heart", "I <3 this book"),
]

/// Renders one text offline and counts the frames written. The delegate
/// protocol is Sendable, so the compiler checks the class's properties;
/// `@unchecked Sendable` because the synthesizer, which is not Sendable, is
/// used only on the main thread, where `write` was called and where the
/// callbacks arrive (38 of 38 in an October 3 probe).
final class Probe: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    let synthesizer = AVSpeechSynthesizer()
    var frames = 0
    var outcome = "pending"

    /// Render `text` in `voice`, waiting at most `seconds` for the end;
    /// the callbacks arrive on the main thread, which this run loop turns.
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

/// The forms of the shape `label` names, in order, with their texts.
func forms(of label: String) -> [(form: String, text: String)] {
    if label == "none" { return [("none", sentence(""))] }
    guard let shape = shapes.first(where: { $0.label == label })?.shape else { return [] }
    var result = [("raw", sentence(shape)), ("quoted", sentence(quoted(shape))), ("strict", sentence(strict(shape)))]
    if shape.contains("&") {
        // One-unit stand-ins a strict guard could give the ampersand, the
        // fullwidth and the small ampersand, and a space in its place.
        result.append(("fullwidth-amp", sentence(strict(shape, ampersand: 0xFF06))))
        result.append(("small-amp", sentence(strict(shape, ampersand: 0xFE60))))
        result.append(("no-amp", sentence(shape.replacingOccurrences(of: "&", with: " "))))
    }
    return result
}

let arguments = CommandLine.arguments
let mode = arguments.count > 1 ? arguments[1] : "all"

if mode == "render" {
    // Render one text given on the command line: the child of `all`.
    let voice = AVSpeechSynthesisVoice(identifier: arguments[3])!
    // Held in a constant, so the probe outlives the render it waits for.
    let probe = Probe()
    print(probe.run(arguments[2], voice: voice))
} else {
    let voiceIdentifier = (mode == "one" ? (arguments.count > 3 ? arguments[3] : nil) : (arguments.count > 2 ? arguments[2] : nil))
        ?? defaultVoiceIdentifier
    guard AVSpeechSynthesisVoice(identifier: voiceIdentifier) != nil else {
        print("The voice \(voiceIdentifier) is not installed")
        exit(1)
    }
    let labels = mode == "one" ? [arguments[2]] : ["none"] + shapes.map(\.label)
    print("voice \(voiceIdentifier)")
    for label in labels {
        for (form, text) in forms(of: label) {
            // Each render in a process of its own.
            let child = Process()
            child.executableURL = URL(fileURLWithPath: arguments[0])
            child.arguments = ["render", text, voiceIdentifier]
            let pipe = Pipe()
            child.standardOutput = pipe
            try child.run()
            child.waitUntilExit()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            print("\(label)\t\(form)\t\(output)\t\(text.utf16.count)\t\(text.debugDescription)")
        }
    }
}

// MARK: - Results, October 7, 2026
//
// macOS 26.3.1 (25D2128), Xcode 26.0.1. Voices: com.apple.voice.compact.en-US.Samantha,
// the user's own, and com.apple.speech.synthesis.voice.Alex, the one other English voice
// installed on this Mac, a legacy enhanced voice; no premium or Siri voice was installed,
// so those are unmeasured. Frames at 22,050 Hz. The sentence without any shape rendered
// 145,418 frames in Samantha and 176,867 in Alex; "The reader went on with the story" alone,
// which is what a shape that swallows everything after it leaves, rendered 33,802 and 43,491.
// A verdict compares the raw render with the sentence alone: REFUSED is a cancel with no
// frame (direct speech's recovery hears it), SWALLOWED finished under 60 percent of it
// (nothing hears it), spoken is everything else.
//
// What the results say, the same in both voices:
// - Every bracketed run whose content is one run of characters other than spaces and
//   slashes, empty or not, swallows the rest of the utterance, whatever those characters
//   are: `<>`, `< >`, `<...>`, `<=>`, `<->`, `<$fh>`, `<*>`, `<#>`, `<@reader>`, `<.x>`,
//   `<-x>`, `<=x>`, `<a=b>`, `< = >`, `<"x">`, `<'x'>`, `<\>`, `a <> b`, `<!>`, `<?>`,
//   besides the letter and digit names the first guard knew (`<3-4>`, `Array<Int>`,
//   `<reader@example.com>`). So the guard's opening tag takes any name of characters other
//   than brackets, spaces, and slashes, empty included, where the first guard wanted a
//   letter, digit, underscore, or colon first; with name=value attributes after it, as
//   before.
// - Runs with bare words after the name are spoken, brackets and all: `<-- aside -->`,
//   `<!-- comment -->`, `<!DOCTYPE html>`, `<?xml version="1.0"?>` (its `?` before `>` is no
//   attribute), `<x y=1 z>`, `<a b c="d">`, `x < y z > w`, `<sm\nclass>`, `Map<String, Int>`.
//   So are `<a/b>` and `<https://example.com/page>` (a slash inside the name ends it) and
//   `<🙂>` (the engine seems to read the emoji's name, words with spaces, first). `<a/>`
//   closes itself and is silent, swallowing nothing. The guard leaves the bare-word runs and
//   the inner slashes alone; it still silences the brackets of `<!...>` and `<?...>`, as
//   the first guard did, and of `<🙂>`, which costs those only a spoken "less than".
// - `</>` is refused, as every closing tag without an opening one was.
// - The ampersand never stopped or swallowed anything, bare (`fish & chips`, `AT&T`,
//   `R&D`) or in an entity (`&amp;`, `&#60;`, `&lt;sm&gt;`, `&nbsp;`), with balanced tags
//   beside it or not. The engine does read entities (`&amp;` rendered about as long as a
//   bare `&`, which is spoken "and"), but a decoded `&lt;sm&gt;` is spoken, never taken as
//   a tag. A bare `&` falls silent as U+FF06 or U+FE60 (fullwidth, small), so the strict
//   guard leaves the ampersand as it is.
// - The `quoted` and `strict` forms of every shape rendered in full: the angle quotation
//   marks are never markup, and they are silent.
//
// label                  Samantha: raw / quoted / strict      verdict    | Alex: raw / quoted       verdict
// none (no shape)           145,418                                  |    176,867
// ellipsis               46,602/174,602/174,602               SWALLOWED  | 54,755/209,379           SWALLOWED
// spaceship              39,434/160,778/160,778               SWALLOWED  | 45,539/201,443           SWALLOWED
// double-arrow           41,482/156,426/156,426               SWALLOWED  | 48,099/198,627           SWALLOWED
// perl-handle            33,802/170,762/170,762               SWALLOWED  | 43,491/206,307           SWALLOWED
// star                   33,802/145,418/145,418               SWALLOWED  | 43,491/196,579           SWALLOWED
// dash-aside             168,202/168,202/168,202              spoken     | 234,979/207,843          spoken
// comment                167,434/167,434/167,434              spoken     | 246,543/219,407          spoken
// xml-declaration        211,978/203,786/203,786              spoken     | 295,695/268,559          spoken
// doctype                183,818/174,858/174,858              spoken     | 245,007/224,527          spoken
// fish-and-chips         161,802/161,802/161,802              spoken     | 192,227/192,227          spoken
// amp-entity             148,490/148,490/148,490              spoken     | 179,427/179,427          spoken
// lt-entity              174,346/174,346/174,346              spoken     | 210,147/210,147          spoken
// at-and-t               161,546/161,546/161,546              spoken     | 191,203/191,203          spoken
// empty                  33,802/145,418/145,418               SWALLOWED  | 43,491/181,731           SWALLOWED
// space-only             33,802/145,418/145,418               SWALLOWED  | 43,491/181,731           SWALLOWED
// hash                   33,802/145,418/145,418               SWALLOWED  | 43,491/193,763           SWALLOWED
// at-name                33,802/157,450/157,450               SWALLOWED  | 43,491/197,347           SWALLOWED
// dot-name               33,802/157,450/157,450               SWALLOWED  | 43,491/195,811           SWALLOWED
// dash-name              33,802/151,050/151,050               SWALLOWED  | 43,491/189,923           SWALLOWED
// equals-name            33,802/161,802/161,802               SWALLOWED  | 43,491/201,187           SWALLOWED
// digit-dash             33,802/157,962/157,962               SWALLOWED  | 43,491/200,675           SWALLOWED
// autolink               272,906/258,570/258,570              spoken     | 275,683/279,011          spoken
// mail-link              33,802/202,506/202,506               SWALLOWED  | 43,491/232,419           SWALLOWED
// closing-empty          cancelled 0/145,418/145,418          REFUSED    | cancelled 0/181,731      REFUSED
// bang-only              33,802/145,418/145,418               SWALLOWED  | 43,491/192,015           SWALLOWED
// question-only          33,802/145,418/145,418               SWALLOWED  | 43,491/192,015           SWALLOWED
// lt-entity-named        167,434/167,434/167,434              spoken     | 186,520/186,520          spoken
// unknown-entity         173,578/173,578/173,578              spoken     | 209,891/209,891          spoken
// bare-amp-word          155,658/155,658/155,658              spoken     | 188,131/188,131          spoken
// amp-with-tag           166,410/190,218/176,138              spoken     | 198,371/243,939          spoken
// amp-entity-with-tag    153,098/178,442/164,106              spoken     | 187,363/232,675          spoken
// equals-inside          33,802/160,778/160,778               SWALLOWED  | 43,491/204,259           SWALLOWED
// spaced-equals          33,802/156,426/156,426               SWALLOWED  | 43,491/194,019           SWALLOWED
// sql-not-equal          39,434/151,050/151,050               SWALLOWED  | 45,539/189,155           SWALLOWED
// double-quoted          33,802/151,050/151,050               SWALLOWED  | 43,491/194,275           SWALLOWED
// single-quoted          33,802/151,050/151,050               SWALLOWED  | 43,491/194,275           SWALLOWED
// backslash              33,802/145,418/145,418               SWALLOWED  | 43,491/181,731           SWALLOWED
// emoji                  193,034/186,890/186,890              spoken     | 242,147/224,995          spoken
// slash-inside           165,642/151,050/151,050              spoken     | 196,504/194,787          spoken
// self-closing           145,418/148,234/148,234              spoken     | 176,867/187,107          spoken
// bare-after-attribute   189,706/173,834/173,834              spoken     | 231,139/216,803          spoken
// bare-before-attribute  195,850/180,490/180,490              spoken     | 252,643/233,187          spoken
// two-bare-words         187,914/170,506/170,506              spoken     | 230,371/215,779          spoken
// line-break-bare        188,170/177,930/177,930              spoken     | 237,795/223,971          spoken
// generic                42,250/154,890/154,890               SWALLOWED  | 48,867/194,275           SWALLOWED
// generic-pair           186,122/169,994/169,994              spoken     | 228,323/210,147          spoken
// heart                  173,066/164,362/164,362              spoken     | 208,355/201,443          spoken
// fish-and-chips         raw/fullwidth/small/no-amp: 161,802/158,986/158,986/158,986
// amp-entity             raw/fullwidth/small/no-amp: 148,490/159,498/159,498/159,498
// lt-entity              raw/fullwidth/small/no-amp: 174,346/170,506/170,506/170,506
// at-and-t               raw/fullwidth/small/no-amp: 161,546/149,514/149,514/152,330
// lt-entity-named        raw/fullwidth/small/no-amp: 167,434/187,658/187,658/187,658
// unknown-entity         raw/fullwidth/small/no-amp: 173,578/170,506/170,506/170,506
// bare-amp-word          raw/fullwidth/small/no-amp: 155,658/150,794/150,794/153,354
// amp-with-tag           raw/fullwidth/small/no-amp: 166,410/173,066/173,066/163,594
// amp-entity-with-tag    raw/fullwidth/small/no-amp: 153,098/172,810/172,810/164,106
//
// amp-with-tag and amp-entity-with-tag hold two tags, `<p>` and `</p>`: their `quoted` form
// changed only the first `<` and the last `>`, which is not what the guard makes of them, and
// their `strict` form (every bracket) is. Every row of both runs finished, refused only where
// marked; none timed out.
