import Foundation
@testable import TextMouth

// Shared support for the speech-preparation benchmarks and oracle tests
// (PERF01, PERF02, PERF05): generated prose, a stopwatch, and the line each
// benchmark prints, so the time before and after each change can be read
// from the test log.

// MARK: - Generated Prose

/// Prose like the books TextMouth reads aloud, generated deterministically
/// so every run measures the same text.
///
/// Sentences of common words carry the punctuation real books carry: commas,
/// em dashes joining two words as typesetters set them, curly quotes and
/// apostrophes, the abbreviations the standard substitution rules expand, an
/// occasional footnote mark, and now and then a separator line of spaced
/// asterisks, a run for the repeated-symbol rule. Its curly quotes and em
/// dashes make it non-ASCII text, as nearly every book is, which is what
/// exposes work that grows with the square of a chapter's length.
///
/// It is a random number generator too, so random oracle trials can shuffle
/// with it and repeat exactly.
struct BenchmarkProse: RandomNumberGenerator {
    /// The SplitMix64 state.
    private var state: UInt64

    /// Prose from `seed`; the same seed always gives the same prose.
    init(seed: UInt64) {
        state = seed
    }

    /// The next pseudo-random number (SplitMix64).
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }

    /// A number from 0 up to, but not including, `bound`.
    mutating func roll(_ bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }

    /// True `percent` times in a hundred.
    mutating func chance(_ percent: Int) -> Bool {
        roll(100) < percent
    }

    /// The words sentences are made of.
    private static let words: [String] = """
    the a of and to in was it that he she they we you his her their with for on at by from as \
    harbour ledger quay rope crate barrel tide gull net hull mast deck cabin chart \
    morning evening market bridge window kettle letter ticket station platform carriage \
    walked waited counted folded carried opened closed noticed remembered listened answered \
    slowly quietly nearly almost perhaps already still again never always often \
    old narrow crowded patient careful heavy small distant familiar \
    mapmaker clerk ferryman baker surveyor printer engineer porter tailor archivist \
    because although while until before after since unless whether \
    seventeen eleven forty twelve ninety three hundred thousand
    """.split(separator: " ").map(String.init)

    /// Contractions written with a curly apostrophe.
    private static let contractions = ["don’t", "it’s", "wasn’t", "they’d", "we’ll", "couldn’t", "she’s", "isn’t"]
    /// Titles the standard substitution rules expand.
    private static let titles = ["Mr.", "Mrs.", "Dr.", "Prof.", "St."]
    /// Names that follow a title.
    private static let surnames = ["Halloran", "Lindqvist", "Okafor", "Varga", "Brennan", "Szabo", "Achebe", "Moreau"]

    /// One sentence of 8 to 22 words, ending with a space.
    mutating func sentence() -> String {
        var words: [String] = []
        if chance(4) {
            words.append(Self.titles[roll(Self.titles.count)])
            words.append(Self.surnames[roll(Self.surnames.count)])
        }
        let count = 8 + roll(15)
        while words.count < count {
            var word = chance(8)
                ? Self.contractions[roll(Self.contractions.count)]
                : Self.words[roll(Self.words.count)]
            if chance(6) { word += "," }
            words.append(word)
        }
        // An em dash joins two words, as typesetters set it.
        if chance(12), words.count > 4 {
            let place = 2 + roll(words.count - 3)
            words[place] = words[place] + "—" + words[place + 1]
            words.remove(at: place + 1)
        }
        var body = words.joined(separator: " ")
        body = body.prefix(1).uppercased() + body.dropFirst()
        if chance(1) { body += " [\(1 + roll(40))]" }
        let ending = chance(8) ? "?" : (chance(4) ? "!" : ".")
        if chance(15) {
            return "“" + body + ending + "” "
        }
        return body + ending + " "
    }

    /// One paragraph of 3 to 7 sentences, or now and then a separator line.
    mutating func paragraph() -> String {
        if chance(1) { return "* * * * *" }
        var text = ""
        for _ in 0..<(3 + roll(5)) {
            text += sentence()
        }
        return String(text.dropLast())
    }

    /// Paragraphs separated by blank lines, at least `utf16Length` UTF-16
    /// units long in all.
    mutating func text(utf16Length: Int) -> String {
        var paragraphs: [String] = []
        var length = 0
        while length < utf16Length {
            let paragraph = paragraph()
            length += paragraph.utf16.count + 2
            paragraphs.append(paragraph)
        }
        return paragraphs.joined(separator: "\n\n")
    }

    /// The first `utf16Length` UTF-16 units of `text`, in new storage of its
    /// own (see `freshCopy(of:)`), cut back to the character boundary at or
    /// before that length.
    static func prefix(of text: String, utf16Length: Int) -> String {
        freshCopy(of: text[..<text.index(atUTF16Offset: utf16Length)])
    }
}

// MARK: - Measuring

/// The chapter lengths a benchmark times, in UTF-16 units: `standard`, which
/// keeps the suite quick, plus `large` when `TEXTMOUTH_LARGE_BENCHMARKS` is
/// set in the test runner's environment (pass
/// `TEST_RUNNER_TEXTMOUTH_LARGE_BENCHMARKS=1` to xcodebuild).
func benchmarkSizes(_ standard: [Int], large: [Int]) -> [Int] {
    let wantsLarge = ProcessInfo.processInfo.environment["TEXTMOUTH_LARGE_BENCHMARKS"] != nil
    return wantsLarge ? standard + large : standard
}

/// `text` copied into new storage.
///
/// A string remembers where its UTF-16 offsets fall once something has asked
/// (its breadcrumbs), which makes later lookups cheap. Every timed run gets a
/// copy of its own, so no run is faster because an earlier run on the same
/// string paid for that.
func freshCopy(of text: some StringProtocol) -> String {
    String(decoding: Array(text.utf8), as: UTF8.self)
}

/// The value `body` returns and how many milliseconds it took.
func benchmarkTiming<T>(_ body: () throws -> T) rethrows -> (value: T, milliseconds: Double) {
    let start = ContinuousClock.now
    let value = try body()
    let elapsed = start.duration(to: .now)
    let milliseconds = Double(elapsed.components.seconds) * 1_000
        + Double(elapsed.components.attoseconds) / 1e15
    return (value, (milliseconds * 100).rounded() / 100)
}

/// Prints one benchmark result to the test log as a line beginning
/// `PERF_SPEECH`, then the result as JSON with sorted keys, so the times
/// before and after a change can be found with one search of the log.
func reportBenchmark(_ name: String, _ fields: [String: Any]) {
    var all = fields
    all["benchmark"] = name
    let data = (try? JSONSerialization.data(withJSONObject: all, options: [.sortedKeys])) ?? Data()
    print("PERF_SPEECH \(String(decoding: data, as: UTF8.self))")
}

/// Whether two texts hold exactly the same characters, compared by their
/// UTF-8 bytes. Swift's `==` treats canonically equivalent spellings as
/// equal, but the synthesizer is handed the exact characters, so an oracle
/// must tell them apart.
func haveIdenticalBytes(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.elementsEqual(rhs.utf8)
}

// MARK: - Rules

extension TextSubstitutionService {
    /// The developer's own substitution rules, as substitutions.json held
    /// them when the performance review measured: the standard rules plus a
    /// rule that reads an OCR'd " | " as " I ".
    static var benchmarkRules: [SubstitutionRule] {
        defaultRules + [SubstitutionRule(name: "| OCR error to I", pattern: " | ", replacement: " I ")]
    }
}
