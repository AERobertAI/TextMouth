import Foundation

// V23 verification probe (build.sh says what is compiled).
//
// Question: is PatienceDiff.partners (TextMouth/Models/PatienceDiff.swift:40)
// the same algorithm as TranscriptEditAlignment.matches
// (TextMouth/Services/TranscriptEditAlignment.swift:254), so that one helper
// could serve both callers?
//
// On Pride and Prejudice with realistic edits, under both tokenizations
// (FineWords keys, and TranscriptEditAlignment's own keys), it checks:
//   1. PatienceDiff.partners == TranscriptEditAlignment.matches at PD's limits
//   2. SharedPatience at PD's tunables == PatienceDiff.partners
//   3. SharedPatience at TEA's tunables == TranscriptEditAlignment.matches as
//      shipped, on whole texts and on sub-ranges (as alignedWords calls it)
//   4. how often the shipped TEA differs from PD (the drift), and which
//      tunable explains each difference.
// Usage: v23probe <path/to/pride.txt>

// MARK: - Seeded randomness

/// SplitMix64, so every run builds the same texts.
struct Seeded: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A number in 0..<bound (0 when bound < 1).
    mutating func pick(_ bound: Int) -> Int {
        bound < 1 ? 0 : Int(next() % UInt64(bound))
    }
}

// MARK: - The corpus

/// The book's chapters, each a list of paragraphs with its heading first,
/// read from the Gutenberg text between its START and END markers. Lines of
/// a paragraph are joined by spaces; blank (or blank-looking) lines part
/// paragraphs.
func loadChapters(_ path: String) -> [[String]] {
    guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { fatalError("cannot read \(path)") }
    let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
    guard let start = text.range(of: "*** START OF"), let end = text.range(of: "*** END OF") else {
        fatalError("no Gutenberg markers in \(path)")
    }
    // The body, from the line after the START marker.
    let body = text[start.upperBound..<end.lowerBound].drop { $0 != "\n" }
    var paragraphs: [String] = []
    var current: [String] = []
    for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
            current = []
        } else {
            current.append(trimmed)
        }
    }
    if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
    // A chapter starts at each "CHAPTER ..." paragraph; the front matter and
    // chapter I (headed only by an illustration caption) form the first.
    var chapters: [[String]] = [[]]
    for paragraph in paragraphs {
        if paragraph.hasPrefix("CHAPTER "), !chapters[chapters.count - 1].isEmpty { chapters.append([]) }
        chapters[chapters.count - 1].append(paragraph)
    }
    return chapters
}

/// A run of chapters as one text, paragraphs parted by blank lines.
func joined(_ chapters: [[String]]) -> String {
    chapters.map { $0.joined(separator: "\n\n") }.joined(separator: "\n\n")
}

// MARK: - Realistic edits

/// The kinds of change a rebuilt or user-edited text shows.
enum Edit: CaseIterable {
    case insertNote, removeParagraph, removeSentence, replaceWord, moveParagraph,
         duplicateParagraph, rewriteSentence, restoreChapter, removeChapter, respell
}

/// Short notes an edition or a reader might put in (original text).
let notes = [
    "A note on this edition: the punctuation of the first printing has been kept, along with its spelling of a few proper names.",
    "The passage below was set in smaller type in the second printing; the compositor's slips in it are corrected here.",
    "Some early copies print the following letter twice. It appears once below, as the author's manuscript has it.",
    "Illustration: the drawing room at Longbourn, after a pen sketch found in the margin of an early copy.",
]

/// Spelling changes a later edition or another converter makes.
let respellings = [("to-morrow", "tomorrow"), ("to-day", "today"), ("Mrs.", "Mrs"), ("Mr.", "Mr"), ("any thing", "anything")]

/// Applies seeded, realistic edits to a run of chapters.
struct Editor {
    var rng: Seeded
    /// The whole book: restored chapters come from it.
    let book: [[String]]
    /// Every word of the book: replacement words come from it.
    let vocabulary: [String]

    /// A paragraph that is not a chapter's heading, when the chapters hold one.
    mutating func spot(in chapters: [[String]]) -> (chapter: Int, paragraph: Int)? {
        let candidates = chapters.indices.filter { chapters[$0].count > 1 }
        guard !candidates.isEmpty else { return nil }
        let chapter = candidates[rng.pick(candidates.count)]
        return (chapter, 1 + rng.pick(chapters[chapter].count - 1))
    }

    /// Applies one edit of kind `edit` to `chapters`.
    mutating func apply(_ edit: Edit, to chapters: inout [[String]]) {
        switch edit {
        case .insertNote:
            let chapter = rng.pick(chapters.count)
            chapters[chapter].insert(notes[rng.pick(notes.count)], at: 1 + rng.pick(chapters[chapter].count))
        case .removeParagraph:
            if let at = spot(in: chapters) { chapters[at.chapter].remove(at: at.paragraph) }
        case .removeSentence:
            guard let at = spot(in: chapters) else { return }
            var sentences = chapters[at.chapter][at.paragraph].components(separatedBy: ". ")
            guard sentences.count > 1 else { return }
            sentences.remove(at: rng.pick(sentences.count))
            chapters[at.chapter][at.paragraph] = sentences.joined(separator: ". ")
        case .replaceWord:
            guard let at = spot(in: chapters) else { return }
            var words = chapters[at.chapter][at.paragraph].split(separator: " ").map(String.init)
            words[rng.pick(words.count)] = vocabulary[rng.pick(vocabulary.count)]
            chapters[at.chapter][at.paragraph] = words.joined(separator: " ")
        case .moveParagraph:
            guard let from = spot(in: chapters) else { return }
            let moved = chapters[from.chapter].remove(at: from.paragraph)
            let chapter = rng.pick(chapters.count)
            chapters[chapter].insert(moved, at: min(chapters[chapter].count, 1 + rng.pick(chapters[chapter].count)))
        case .duplicateParagraph:
            if let at = spot(in: chapters) {
                chapters[at.chapter].insert(chapters[at.chapter][at.paragraph], at: at.paragraph + 1)
            }
        case .rewriteSentence:
            // The clauses of one sentence put in another order.
            guard let at = spot(in: chapters) else { return }
            var sentences = chapters[at.chapter][at.paragraph].components(separatedBy: ". ")
            let which = rng.pick(sentences.count)
            let clauses = sentences[which].components(separatedBy: ", ")
            guard clauses.count > 1 else { return }
            let turn = 1 + rng.pick(clauses.count - 1)
            sentences[which] = (clauses[turn...] + clauses[..<turn]).joined(separator: ", ")
            chapters[at.chapter][at.paragraph] = sentences.joined(separator: ". ")
        case .restoreChapter:
            chapters.insert(book[rng.pick(book.count)], at: rng.pick(chapters.count + 1))
        case .removeChapter:
            if chapters.count > 1 { chapters.remove(at: rng.pick(chapters.count)) }
        case .respell:
            let chapter = rng.pick(chapters.count)
            let (from, to) = respellings[rng.pick(respellings.count)]
            chapters[chapter] = chapters[chapter].map { $0.replacingOccurrences(of: from, with: to) }
        }
    }

    /// A random run of up to `maxChapters` chapters, and that run with up to
    /// `maxEdits` random edits.
    mutating func pair(maxChapters: Int, maxEdits: Int) -> (old: String, new: String) {
        let start = rng.pick(book.count)
        let window = Array(book[start..<min(book.count, start + 1 + rng.pick(maxChapters))])
        var edited = window
        for _ in 0...rng.pick(maxEdits) {
            apply(Edit.allCases[rng.pick(Edit.allCases.count)], to: &edited)
        }
        return (joined(window), joined(edited))
    }
}

// MARK: - Keys under both tokenizations

/// The same two texts as UInt64 keys (for PatienceDiff) and String keys (for
/// TranscriptEditAlignment), related one to one, so both algorithms see the
/// same words as equal.
struct KeyedPair {
    let oldU: [UInt64], newU: [UInt64]
    let oldS: [String], newS: [String]

    /// FineWords keys, and their decimal spellings as the String keys.
    static func fine(_ old: String, _ new: String) -> KeyedPair {
        let oldU = FineWords.keys(in: old)
        let newU = FineWords.keys(in: new)
        return KeyedPair(oldU: oldU, newU: newU, oldS: oldU.map { String($0) }, newS: newU.map { String($0) })
    }

    /// TranscriptEditAlignment's keys, and each distinct key's number as
    /// the UInt64 keys.
    static func transcript(_ old: String, _ new: String) -> KeyedPair {
        let oldS = TranscriptEditAlignment.words(in: old).map(\.key)
        let newS = TranscriptEditAlignment.words(in: new).map(\.key)
        var ids: [String: UInt64] = [:]
        func id(_ key: String) -> UInt64 {
            if let known = ids[key] { return known }
            let fresh = UInt64(ids.count)
            ids[key] = fresh
            return fresh
        }
        return KeyedPair(oldU: oldS.map(id), newU: newS.map(id), oldS: oldS, newS: newS)
    }
}

// MARK: - Comparing

/// Pairs (old, new), sorted by old, as a partners array over `count` old words.
func partners(_ pairs: [(Int, Int)], count: Int) -> [Int] {
    var result = [Int](repeating: -1, count: count)
    for (old, new) in pairs { result[old] = new }
    return result
}

/// Whether two lists of pairs are the same pairs in the same order.
func samePairs(_ a: [(Int, Int)], _ b: [(Int, Int)]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
}

/// The shared helper at chosen tunables, as a partners array over all of `old`.
func shared<Key: Hashable>(_ old: [Key], _ new: [Key], limit: Int, budget: Int?) -> [Int] {
    var result = [Int](repeating: -1, count: old.count)
    SharedPatience.lineUp(old, 0..<old.count, new, 0..<new.count, exactLimit: limit, budget: budget, into: &result)
    return result
}

/// How many old words have a partner.
func matched(_ partners: [Int]) -> Int { partners.filter { $0 >= 0 }.count }

/// The running totals of every check.
struct Tally {
    var trials = 0
    var words = 0
    var pdEqualsTEAAtPDLimits = 0
    var sharedEqualsPD = 0
    var sharedEqualsShippedTEA = 0
    var subRanges = 0
    var subRangeSharedEqualsShippedTEA = 0
    var subRangeSharedEqualsTEAAtPDLimits = 0
    var shippedTEADiffersFromPD = 0
    var driftExplainedByLimit = 0
    var driftExplainedByBudget = 0
    var driftNeedsBoth = 0
    var failures: [String] = []

    /// Runs every check on one pair of texts.
    mutating func check(_ k: KeyedPair, label: String, rng: inout Seeded) {
        trials += 1
        words += k.oldU.count + k.newU.count
        let n = k.oldS.count
        let m = k.newS.count
        let pd = PatienceDiff.partners(of: k.oldU, in: k.newU)
        let teaAtPD = partners(TEAAtPDLimits.matches(k.oldS, 0..<n, k.newS, 0..<m), count: n)
        let teaShipped = partners(TranscriptEditAlignment.matches(k.oldS, 0..<n, k.newS, 0..<m), count: n)
        let teaBudget = 40 * (n + m + 1)
        if pd == teaAtPD { pdEqualsTEAAtPDLimits += 1 } else { failures.append("\(label): PD != TEA at PD's limits") }
        if shared(k.oldU, k.newU, limit: PatienceDiff.largestExactStretch, budget: nil) == pd {
            sharedEqualsPD += 1
        } else { failures.append("\(label): shared(PD tunables) != PD") }
        if shared(k.oldS, k.newS, limit: TranscriptEditAlignment.wordByWordLimit, budget: teaBudget) == teaShipped {
            sharedEqualsShippedTEA += 1
        } else { failures.append("\(label): shared(TEA tunables) != shipped TEA") }
        // Which tunable explains a difference between the shipped two.
        if teaShipped != pd {
            shippedTEADiffersFromPD += 1
            if shared(k.oldU, k.newU, limit: TranscriptEditAlignment.wordByWordLimit, budget: nil) == teaShipped {
                driftExplainedByLimit += 1
            } else if shared(k.oldU, k.newU, limit: PatienceDiff.largestExactStretch, budget: teaBudget) == teaShipped {
                driftExplainedByBudget += 1
            } else {
                driftNeedsBoth += 1
            }
        }
        // Sub-ranges, as alignedWords calls matches between whole sentences.
        for _ in 0..<3 where n > 0 && m > 0 {
            let low = rng.pick(n)
            let high = low + rng.pick(n - low + 1)
            let rangeA = low..<high
            let rangeB = (low * m / n)..<max(low * m / n, min(m, high * m / n + rng.pick(5)))
            subRanges += 1
            if samePairs(transcriptMatchesViaShared(k.oldS, rangeA, k.newS, rangeB),
                         TranscriptEditAlignment.matches(k.oldS, rangeA, k.newS, rangeB)) {
                subRangeSharedEqualsShippedTEA += 1
            } else { failures.append("\(label): sub-range shared != shipped TEA") }
            var viaShared = [Int](repeating: -1, count: n)
            SharedPatience.lineUp(k.oldS, rangeA, k.newS, rangeB, exactLimit: PatienceDiff.largestExactStretch,
                                  budget: nil, into: &viaShared)
            if viaShared == partners(TEAAtPDLimits.matches(k.oldS, rangeA, k.newS, rangeB), count: n) {
                subRangeSharedEqualsTEAAtPDLimits += 1
            } else { failures.append("\(label): sub-range shared(PD tunables) != TEA at PD's limits") }
        }
    }

    /// The totals, one check a line.
    func report(_ title: String) {
        print("== \(title): \(trials) text pairs, \(words) words in all")
        print("   PatienceDiff.partners == TEA.matches at PD's limits ......... \(pdEqualsTEAAtPDLimits)/\(trials)")
        print("   shared helper (4,000,000, no budget) == PatienceDiff ......... \(sharedEqualsPD)/\(trials)")
        print("   shared helper (90,000, 40-pass budget) == shipped TEA ....... \(sharedEqualsShippedTEA)/\(trials)")
        print("   sub-ranges: shared == shipped TEA ............................ \(subRangeSharedEqualsShippedTEA)/\(subRanges)")
        print("   sub-ranges: shared (PD tunables) == TEA at PD's limits ....... \(subRangeSharedEqualsTEAAtPDLimits)/\(subRanges)")
        print("   drift: shipped TEA != PatienceDiff ........................... \(shippedTEADiffersFromPD)/\(trials)"
              + " (limit alone \(driftExplainedByLimit), budget alone \(driftExplainedByBudget), both \(driftNeedsBoth))")
        for failure in failures.prefix(5) { print("   FAILURE: \(failure)") }
    }
}

// MARK: - The probe

/// Runs every phase and prints its results.
func runProbe() {
    guard CommandLine.arguments.count > 1 else { fatalError("usage: v23probe <pride.txt>") }
    let book = loadChapters(CommandLine.arguments[1])
    let vocabulary = Array(Set(joined(book).split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))).sorted()
    print("corpus: \(book.count) chapters, \(book.map(\.count).reduce(0, +)) paragraphs, \(FineWords.keys(in: joined(book)).count) fine words")
    var editor = Editor(rng: Seeded(state: 20_261_012), book: book, vocabulary: vocabulary)
    var rng = Seeded(state: 23)

    // Phase 1: runs of 1-4 chapters with 1-12 edits, under both tokenizations.
    var fine = Tally()
    var transcript = Tally()
    for trial in 0..<300 {
        let (old, new) = editor.pair(maxChapters: 4, maxEdits: 12)
        fine.check(.fine(old, new), label: "chapters #\(trial) fine", rng: &rng)
        transcript.check(.transcript(old, new), label: "chapters #\(trial) transcript", rng: &rng)
    }
    fine.report("Chapter runs, FineWords keys")
    transcript.report("Chapter runs, TranscriptEditAlignment keys")

    // Phase 2: the whole book with 20-60 edits (a rebuild), both tokenizations.
    var whole = Tally()
    for trial in 0..<4 {
        var edited = book
        for _ in 0..<(20 + rng.pick(41)) { editor.apply(Edit.allCases[rng.pick(Edit.allCases.count)], to: &edited) }
        whole.check(.fine(joined(book), joined(edited)), label: "whole book #\(trial) fine", rng: &rng)
        whole.check(.transcript(joined(book), joined(edited)), label: "whole book #\(trial) transcript", rng: &rng)
    }
    whole.report("Whole book, both tokenizations")

    // Phase 3a: an anchorless stretch between the two exact limits. A
    // paragraph printed twice (every word then stands at least twice, so no
    // fixed point), with its first two and last two words swapped in the new
    // text so that almost nothing is trimmed as common ends.
    var constructed = Tally()
    let paragraph = book.joined().first { (150...220).contains(TranscriptEditAlignment.words(in: $0).count) }!
    var words = paragraph.split(separator: " ").map(String.init)
    let original = words.joined(separator: " ")
    words.swapAt(0, 1)
    let swappedStart = words.joined(separator: " ")
    words = original.split(separator: " ").map(String.init)
    words.swapAt(words.count - 1, words.count - 2)
    let swappedEnd = words.joined(separator: " ")
    let echoOld = original + "\n\n" + original
    let echoNew = swappedStart + "\n\n" + swappedEnd
    for (name, k) in [("FineWords", KeyedPair.fine(echoOld, echoNew)), ("TEA keys", KeyedPair.transcript(echoOld, echoNew))] {
        let n = k.oldS.count
        let m = k.newS.count
        let pd = PatienceDiff.partners(of: k.oldU, in: k.newU)
        let teaShipped = partners(TranscriptEditAlignment.matches(k.oldS, 0..<n, k.newS, 0..<m), count: n)
        print("== Echoed paragraph (\(name)): \(n) x \(m) = \(n * m) pairs, no fixed point;"
              + " matched words: PatienceDiff \(matched(pd)), shipped TEA \(matched(teaShipped)),"
              + " TEA at PD's limits \(matched(partners(TEAAtPDLimits.matches(k.oldS, 0..<n, k.newS, 0..<m), count: n)))")
        constructed.check(k, label: "echo \(name)", rng: &rng)
    }

    // Phase 3b: each paragraph followed by the one before it (P1 P0 P2 P1
    // ...), each numbered ("17. ") so every paragraph holds a word of its
    // own: the diff then peels two paragraphs a level, re-reading the rest,
    // which trips TEA's work budget.
    let paragraphs = book[1..<12].joined().enumerated().map { "\($0.offset + 1). \($0.element)" }
    var overlapping: [String] = []
    for i in 0..<(paragraphs.count - 1) {
        overlapping.append(paragraphs[i + 1])
        overlapping.append(paragraphs[i])
    }
    overlapping.append("A closing paragraph the old text never had.")
    let lappedOld = paragraphs.joined(separator: "\n\n")
    let lappedNew = overlapping.joined(separator: "\n\n")
    for (name, k) in [("FineWords", KeyedPair.fine(lappedOld, lappedNew)), ("TEA keys", KeyedPair.transcript(lappedOld, lappedNew))] {
        let n = k.oldS.count
        let m = k.newS.count
        let clock = ContinuousClock()
        var pd: [Int] = []
        var teaShipped: [Int] = []
        let pdTime = clock.measure { pd = PatienceDiff.partners(of: k.oldU, in: k.newU) }
        let teaTime = clock.measure { teaShipped = partners(TranscriptEditAlignment.matches(k.oldS, 0..<n, k.newS, 0..<m), count: n) }
        print("== Overlapping paragraphs (\(name)), \(paragraphs.count) paragraphs, \(n) -> \(m) words:"
              + " matched PatienceDiff \(matched(pd)) in \(pdTime), shipped TEA \(matched(teaShipped)) in \(teaTime)")
        constructed.check(k, label: "overlap \(name)", rng: &rng)
    }

    // Phase 3c: edge cases.
    let edges: [(String, String)] = [
        ("", ""), ("", "Mr. Bennet"), ("Mr. Bennet was among the earliest", ""),
        (paragraph, paragraph),
        (Array(repeating: "the", count: 50).joined(separator: " "), Array(repeating: "the", count: 70).joined(separator: " ")),
        (paragraph, "Something else entirely, with no word in common whatsoever."),
    ]
    for (index, (old, new)) in edges.enumerated() {
        constructed.check(.fine(old, new), label: "edge #\(index) fine", rng: &rng)
        constructed.check(.transcript(old, new), label: "edge #\(index) transcript", rng: &rng)
    }
    constructed.report("Constructed cases (echo, overlapping paragraphs, edges)")

    // Phase 4: a stress test of the two tunables, not realistic prose: texts
    // over a small vocabulary (so few words stand once and stretches go
    // anchorless) with inserts, removals, replacements and moved runs.
    var stress = Tally()
    for trial in 0..<400 {
        let vocabulary = (0..<[4, 8, 16, 64][rng.pick(4)]).map { "w\($0)" }
        let length = [100, 400, 1500][rng.pick(3)]
        let old = (0..<length).map { _ in vocabulary[min(rng.pick(vocabulary.count), rng.pick(vocabulary.count))] }
        var new = old
        for _ in 0..<(5 + rng.pick(56)) {
            let at = rng.pick(new.count)
            switch rng.pick(4) {
            case 0: new.insert(vocabulary[rng.pick(vocabulary.count)], at: at)
            case 1: if !new.isEmpty { new.remove(at: at) }
            case 2: if !new.isEmpty { new[at] = vocabulary[rng.pick(vocabulary.count)] }
            default:
                // A run of up to 30 words moved elsewhere.
                guard new.count > 40 else { continue }
                let run = 1 + rng.pick(30)
                let start = rng.pick(new.count - run)
                let moved = Array(new[start..<(start + run)])
                new.removeSubrange(start..<(start + run))
                new.insert(contentsOf: moved, at: rng.pick(new.count + 1))
            }
        }
        stress.check(.transcript(old.joined(separator: " "), new.joined(separator: " ")), label: "stress #\(trial)", rng: &rng)
    }
    stress.report("Stress: small vocabularies (tunables exercised)")
}

runProbe()
