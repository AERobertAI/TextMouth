import Foundation

// V16 verifier probe. Question: does PatienceDiff.partners
// (TextMouth/Models/PatienceDiff.swift:40-85) do quadratic work when the
// fixed points of every stretch fall only at its edges, and does any input a
// book could plausibly hold reach that case?
//
// Every subcommand runs in its own process (kept under ~60 s and ~1 GB):
//   words <k>           word-level crossing: old x0 x1 .. xk W, new x1 x0 x2 x1 .. xk x(k-1) Z
//   prose <P> <change>  the first P paragraphs of Pride and Prejudice (real prose) with
//                       change = crossing  new text: each paragraph followed by the one before it
//                                          (P1 P0 P2 P1 P3 P2 ...)
//                                numbered  as crossing, each paragraph numbered "17. " in both
//                                dense     every paragraph's first word dropped in the new text
//                                rolling   old text holds each paragraph twice in place
//                                          (P0 P0 P1 P1 ...), the new text once
//   book <copies> <name> the corpus' v3.0.2 reading of <name> -> its current reading, as
//                       <copies> letter-shifted copies (a real reader change, scaled)
//   pantoum <S>         a pantoum of S stanzas (lines 2 and 4 of a stanza are lines 1 and 3
//                       of the next), its stanzas numbered "12." in the old text only

// MARK: - Measuring

/// Nanoseconds on the monotonic clock.
func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

/// Runs `body`, returning its result and how long it took in milliseconds.
func timed<T>(_ body: () -> T) -> (T, Double) {
    let start = now()
    let result = body()
    return (result, Double(now() - start) / 1e6)
}

/// Peak resident memory of this process so far, in MB.
func peakMB() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_maxrss) / 1_048_576
}

/// The work one run of the diff did: the stretches whose words rule 2
/// counted, how many words those counts read (old and new together), and
/// the deepest stretch counted (the top stretch is depth 0).
struct Work {
    var stretches = 0
    var words = 0
    var deepest = 0
}

/// PatienceDiff.partners line for line, calling the repo's own helpers
/// (wordsOnceInEach, longestRisingChain, lineUpExactly), with work counters
/// and, when `budgeted`, the work bound of TranscriptEditAlignment.matches
/// (TextMouth/Services/TranscriptEditAlignment.swift:260, 278-279): forty
/// passes over both texts, after which a stretch is left unmatched. Without
/// the bound the caller checks its result equals PatienceDiff.partners'.
func countedPartners(of old: [UInt64], in new: [UInt64], budgeted: Bool, work: inout Work) -> [Int] {
    var partners = [Int](repeating: -1, count: old.count)
    var budget = 40 * (old.count + new.count + 1)
    var stretches: [(old: Range<Int>, new: Range<Int>, depth: Int)] = [(0..<old.count, 0..<new.count, 0)]
    while let stretch = stretches.popLast() {
        var oldLow = stretch.old.lowerBound
        var oldHigh = stretch.old.upperBound
        var newLow = stretch.new.lowerBound
        var newHigh = stretch.new.upperBound
        // Rule 1: common start, then common end.
        while oldLow < oldHigh, newLow < newHigh, old[oldLow] == new[newLow] {
            partners[oldLow] = newLow
            oldLow += 1
            newLow += 1
        }
        while oldLow < oldHigh, newLow < newHigh, old[oldHigh - 1] == new[newHigh - 1] {
            partners[oldHigh - 1] = newHigh - 1
            oldHigh -= 1
            newHigh -= 1
        }
        guard oldLow < oldHigh, newLow < newHigh else { continue }
        // TranscriptEditAlignment's bound, charged before the stretch is counted.
        if budgeted {
            budget -= (oldHigh - oldLow) + (newHigh - newLow)
            guard budget > 0 else { continue }
        }
        let oldRange = oldLow..<oldHigh
        let newRange = newLow..<newHigh
        work.stretches += 1
        work.words += oldRange.count + newRange.count
        work.deepest = max(work.deepest, stretch.depth)
        // Rules 2 and 4.
        let fixed = PatienceDiff.longestRisingChain(of: PatienceDiff.wordsOnceInEach(old, oldRange, new, newRange))
        guard !fixed.isEmpty else {
            PatienceDiff.lineUpExactly(old, oldRange, new, newRange, into: &partners)
            continue
        }
        // Rule 3.
        var oldNext = oldLow
        var newNext = newLow
        for point in fixed {
            partners[point.old] = point.new
            stretches.append((oldNext..<point.old, newNext..<point.new, stretch.depth + 1))
            oldNext = point.old + 1
            newNext = point.new + 1
        }
        stretches.append((oldNext..<oldHigh, newNext..<newHigh, stretch.depth + 1))
    }
    return partners
}

/// Whether to time the repo's diff alone (one run, for inputs whose diff
/// takes most of the minute a run may take): set by a trailing "quick".
let quickOnly = CommandLine.arguments.last == "quick"

/// Diffs `old` against `new` with the repo's PatienceDiff.partners (timed),
/// checks the counted copy agrees, and prints one line for `label`, then the
/// budgeted variant's time and how much it matched.
func report(_ label: String, old: [UInt64], new: [UInt64]) {
    let (repo, repoMS) = timed { PatienceDiff.partners(of: old, in: new) }
    if quickOnly {
        print(String(format: "%@: old %d words, new %d words | PatienceDiff.partners %.1f ms, matched %d | peak %.0f MB",
                     label, old.count, new.count, repoMS, repo.filter { $0 >= 0 }.count, peakMB()))
        return
    }
    var work = Work()
    let counted = countedPartners(of: old, in: new, budgeted: false, work: &work)
    precondition(counted == repo, "the counted copy must agree with PatienceDiff.partners")
    var budgetWork = Work()
    let (bounded, boundedMS) = timed { countedPartners(of: old, in: new, budgeted: true, work: &budgetWork) }
    let matched = repo.filter { $0 >= 0 }.count
    print(String(format: "%@: old %d words, new %d words | PatienceDiff.partners %.1f ms, matched %d | rule 2 counted %d words in %d stretches, deepest %d (%.1f x the two texts) | with a 40-pass bound: %.1f ms, matched %d | peak %.0f MB",
                 label, old.count, new.count, repoMS, matched, work.words, work.stretches, work.deepest,
                 Double(work.words) / Double(old.count + new.count), boundedMS, bounded.filter { $0 >= 0 }.count, peakMB()))
}

// MARK: - Texts

/// The corpus the finder copied from the measured program (each reading's
/// chapters joined by a form feed, paragraphs by a blank line).
let textsDirectory = "/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/review/angleEff/texts"

/// The text of a reading in the corpus.
func reading(_ name: String) -> String {
    try! String(contentsOfFile: "\(textsDirectory)/\(name).txt", encoding: .utf8)
}

/// The non-empty paragraphs of a reading.
func paragraphs(of name: String) -> [String] {
    reading(name).replacingOccurrences(of: "\u{0C}", with: "\n\n")
        .components(separatedBy: "\n\n")
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// The fine-word keys of paragraphs joined as one chapter's text.
func keys(of paragraphs: [String]) -> [UInt64] {
    FineWords.keys(in: paragraphs.joined(separator: "\n\n"))
}

/// `text` with its basic Latin letters rotated by `shift`, so that copies of
/// one book share (almost) no words and each copy's rare words stay rare.
func shifted(_ text: String, by shift: Int) -> String {
    guard shift % 26 != 0 else { return text }
    var scalars = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
        let value = scalar.value
        let base: UInt32? = (0x61...0x7A).contains(value) ? 0x61 : (0x41...0x5A).contains(value) ? 0x41 : nil
        if let base, let moved = Unicode.Scalar(base + (value - base + UInt32(shift)) % 26) {
            scalars.append(moved)
        } else {
            scalars.append(scalar)
        }
    }
    return String(scalars)
}

/// A word made only of letters for `number` ("ba", "bb", ...), so that
/// FineWords reads it as one word (digits next to letters would split it).
func letterName(_ number: Int) -> String {
    var n = number + 26
    var letters: [Character] = []
    while n > 0 {
        letters.append(Character(Unicode.Scalar(UInt8(0x61 + n % 26))))
        n /= 26
    }
    return "q" + String(letters.reversed())
}

// MARK: - Experiments

/// The word-level crossing input: each word but the two ends stands twice in
/// the new text, after its successor's first copy.
func words(k: Int) {
    var old: [UInt64] = (0...k).map { UInt64(1_000 + $0) }
    old.append(7)
    var new: [UInt64] = []
    for index in 0..<k {
        new.append(UInt64(1_000 + index + 1))
        new.append(UInt64(1_000 + index))
    }
    new.append(9)
    report("words k=\(k)", old: old, new: new)
}

/// Real prose, changed as `change` says (see the header).
func prose(count: Int, change: String) {
    var base = Array(paragraphs(of: "pride-current").prefix(count))
    if change == "numbered" {
        base = base.enumerated().map { "\($0.offset + 1). \($0.element)" }
    }
    var newParagraphs: [String] = []
    var oldParagraphs = base
    switch change {
    case "crossing", "numbered":
        for index in 0..<(base.count - 1) {
            newParagraphs.append(base[index + 1])
            newParagraphs.append(base[index])
        }
    case "dense":
        newParagraphs = base.map { paragraph in
            // Drop the paragraph's first fine word (and what precedes it).
            guard let space = paragraph.firstIndex(of: " ") else { return paragraph }
            return String(paragraph[paragraph.index(after: space)...])
        }
    case "rolling":
        oldParagraphs = base.flatMap { [$0, $0] }
        newParagraphs = base
    default:
        fatalError("unknown change \(change)")
    }
    report("prose P=\(count) \(change)", old: keys(of: oldParagraphs), new: keys(of: newParagraphs))
}

/// The finder's "prevnum" input exactly (angleEff/main.swift): pride-v304's
/// paragraphs as split from its chapters joined by a blank line (empty ones
/// kept), each numbered "17. ", the new text each paragraph followed by the
/// one before it, then a closing paragraph the old text lacks.
func finderPrevnum() {
    let joined = reading("pride-v304").components(separatedBy: "\u{0C}").joined(separator: "\n\n")
    let numbered = joined.components(separatedBy: "\n\n").enumerated().map { "\($0.offset + 1). \($0.element)" }
    var newParagraphs: [String] = []
    for index in 0..<(numbered.count - 1) {
        newParagraphs.append(numbered[index + 1])
        newParagraphs.append(numbered[index])
    }
    newParagraphs.append("A closing paragraph the old text never had.")
    report("finder prevnum (\(numbered.count) paragraphs)", old: keys(of: numbered), new: keys(of: newParagraphs))
}

/// A real reader change (the corpus' v3.0.2 reading -> current), scaled by
/// letter-shifted copies.
func book(copies: Int, name: String) {
    let oldText = reading("\(name)-v302")
    let newText = reading("\(name)-current")
    let old = (0..<copies).flatMap { FineWords.keys(in: shifted(oldText, by: $0)) }
    let new = (0..<copies).flatMap { FineWords.keys(in: shifted(newText, by: $0)) }
    report("book \(name) x\(copies) v302->current", old: old, new: new)
}

/// The lines given out so far, so that every line has a word of its own.
nonisolated(unsafe) var linesMade = 0

/// A fresh line of verse, with a word no other line has.
func freshLine() -> String {
    defer { linesMade += 1 }
    return "And \(letterName(linesMade)) went down beside the water, slow."
}

/// The old and new paragraphs of one pantoum of `stanzas` stanzas: stanza j
/// is lines a b c d, and the next stanza's lines a and c are this one's b
/// and d. The old text numbers its stanzas ("12."), the new one does not;
/// a `title`, when given, heads the poem in both.
func pantoumParagraphs(stanzas: Int, title: String?) -> (old: [String], new: [String]) {
    var a = freshLine()
    var c = freshLine()
    var oldParagraphs = title.map { [$0] } ?? []
    var newParagraphs = oldParagraphs
    for stanza in 0..<stanzas {
        let b = freshLine()
        let d = freshLine()
        let verse = [a, b, c, d].joined(separator: "\n")
        oldParagraphs.append("\(stanza + 1).")
        oldParagraphs.append(verse)
        newParagraphs.append(verse)
        a = b
        c = d
    }
    return (oldParagraphs, newParagraphs)
}

/// One pantoum of `stanzas` stanzas.
func pantoum(stanzas: Int) {
    let poem = pantoumParagraphs(stanzas: stanzas, title: nil)
    report("pantoum S=\(stanzas)", old: keys(of: poem.old), new: keys(of: poem.new))
}

/// A collection of `poems` pantoums of `stanzas` stanzas each, each under a
/// title of its own ("Pantoum for <word>"), as a book of poems holds them.
func pantoums(poems: Int, stanzas: Int) {
    var old: [String] = []
    var new: [String] = []
    for poem in 0..<poems {
        let one = pantoumParagraphs(stanzas: stanzas, title: "Pantoum for \(letterName(1_000_000 + poem))")
        old += one.old
        new += one.new
    }
    report("pantoums \(poems) x S=\(stanzas)", old: keys(of: old), new: keys(of: new))
}

// MARK: - Main

let arguments = CommandLine.arguments
switch arguments.count > 1 ? arguments[1] : "" {
case "words": words(k: Int(arguments[2])!)
case "prose": prose(count: Int(arguments[2])!, change: arguments[3])
case "book": book(copies: Int(arguments[2])!, name: arguments[3])
case "pantoum": pantoum(stanzas: Int(arguments[2])!)
case "finder": finderPrevnum()
case "pantoums": pantoums(poems: Int(arguments[2])!, stanzas: Int(arguments[3])!)
default: print("usage: v16 words <k> | prose <P> crossing|numbered|dense|rolling | book <copies> <name> | pantoum <S>")
}
