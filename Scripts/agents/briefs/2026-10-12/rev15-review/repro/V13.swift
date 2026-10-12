import Foundation

// V13 verification probe: the like-for-like rule (PlaceRelocator.swift
// 528-540) has no length cap, so a huge changed stretch of similar length on
// both sides counts as "local editing".
//
// Usage: probe <directory holding the prose slices>
//
// Scenario A: a guided-breathing book whose practice chapter repeats one
// 22-word cycle 120 times. An Edit Text session fixes the same typo
// ("Breath out" -> "Breathe out") in cycle 5 and in cycle 115, ~2,400 words
// apart. Nothing between them changes. The patience diff finds no fixed point
// between the typos (every word there repeats) and the stretch is larger than
// largestExactStretch, so it stays unmatched.
// Control A2: the same fix in cycles 5 and 85 (~1,760 words apart), small
// enough for the exact LCS.
//
// Scenario B: old and new share only the first and last paragraphs; the
// middle is unrelated prose of similar length.

let directory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

// MARK: - Helpers

/// A relocation result, compactly: (chapter,offset) and the finding.
func describe(_ place: TextPlace) -> String { "(\(place.chapter),\(place.offset))" }

/// The finding without the module prefix, for short output lines.
func describe(_ finding: PlaceRelocator.Finding) -> String {
    switch finding {
    case .unchanged: return "unchanged"
    case .movedByTheDiff(let evidence): return "movedByTheDiff(.\(evidence))"
    case .foundBySavedWords(let evidence): return "foundBySavedWords(\(evidence))"
    case .guessed(let guess): return "guessed(\(guess))"
    }
}

// MARK: - Scenario A: a long repetitive practice, two typos fixed

/// One cycle of the practice, as the new (corrected) text has it.
let cycle = "Breathe in, and count to four. Hold, and count to four. Breathe out, and count to four. Hold, and count to four."
/// The same cycle with the transcription typo the edit fixes.
let typoCycle = "Breathe in, and count to four. Hold, and count to four. Breath out, and count to four. Hold, and count to four."

let chapterOne = """
Chapter One. Why Count the Breath

Most people who come to the Tuesday class have tried meditation before and given up within a week, usually because nobody told them what to do with their attention once they had closed their eyes. Counting gives the attention a job. It is dull on purpose: a mind that is counting cannot also be rehearsing an argument with the landlord.
"""
let introTwo = """
Chapter Two. The Square Breath

Sit on a firm chair with both feet flat on the floor and your hands resting on your thighs. The practice below is read aloud slowly, one line at a time, and the listener follows it without hurrying or skipping ahead.


"""
let outroTwo = """


When the last cycle ends, stay seated for a minute and notice how the room sounds. Then stand up slowly and drink a glass of water before you go on with your day.
"""
let chapterThree = """
Chapter Three. Walking Practice

Walking practice uses the same count, but the feet keep it instead of the lungs. Choose a corridor or a garden path about twenty paces long, where nobody will need you to step aside.
"""

/// The practice chapter's lines: `cycles` cycles, with the typo in `typos`.
func practiceLines(cycles: Int, typos: Set<Int>) -> [String] {
    (0..<cycles).map { typos.contains($0) ? typoCycle : cycle }
}

/// The three-chapter book with the practice in chapter 1.
func book(cycles: Int, typos: Set<Int>) -> [String] {
    [chapterOne, introTwo + practiceLines(cycles: cycles, typos: typos).joined(separator: "\n") + outroTwo, chapterThree]
}

/// Offset in chapter 1 of the start of practice line `line`, plus `within` units into it.
func offset(ofLine line: Int, within: Int = 0, cycles: Int, typos: Set<Int>) -> Int {
    let lines = practiceLines(cycles: cycles, typos: typos)
    return introTwo.utf16.count + lines[..<line].reduce(0) { $0 + $1.utf16.count + 1 } + within
}

/// Runs scenario A for typos at `typos`, sampling places at `samples` (line, units into the line).
func runScenarioA(title: String, typos: Set<Int>, samples: [(line: Int, within: Int)], patchNote: String) {
    let cycles = 120
    let oldTexts = book(cycles: cycles, typos: typos)
    let newTexts = book(cycles: cycles, typos: [])
    let relocator = PlaceRelocator(oldTexts: oldTexts, newTexts: newTexts)
    let partners = PatienceDiff.partners(of: relocator.old.keys, in: relocator.new.keys)
    let unmatched = partners.filter { $0 < 0 }.count
    print("== \(title) \(patchNote)")
    print("   old words \(relocator.old.count), new words \(relocator.new.count), old words the diff left unmatched: \(unmatched)")
    // The saved-words search alone (rules 4-5 with no diff answer), for comparison.
    let finderAlone = TextAnchorFinder(words: relocator.new)
    var landings = Set<TextPlace>()
    for sample in samples {
        let saved = TextPlace(chapter: 1, offset: offset(ofLine: sample.line, within: sample.within, cycles: cycles, typos: typos))
        // The same spot in the corrected text: the same line, same units into it.
        let truth = TextPlace(chapter: 1, offset: offset(ofLine: sample.line, within: sample.within, cycles: cycles, typos: []))
        guard let anchor = TextAnchor(capturingAt: saved, in: relocator.old) else {
            print("   no anchor at \(describe(saved))")
            continue
        }
        let result = relocator.relocate(anchor, savedAt: saved)
        landings.insert(result.place)
        let alone = finderAlone.find(anchor, savedAt: saved, savedChapterLength: relocator.old.length(ofChapter: 1))
        let missWords = relocator.new.word(at: truth) - relocator.new.word(at: result.place)
        print("   line \(sample.line)+\(sample.within): saved \(describe(saved)) -> \(describe(result.place)) \(describe(result.finding)) isGuess=\(result.finding.isGuess); truth \(describe(truth)); miss \(missWords) words; saved words alone -> \(describe(alone.place)) \(alone.finding)")
    }
    print("   distinct landings: \(landings.count) of \(samples.count) places")
}

/// Places across the stretch: line starts, and one place on "out" mid-line.
let outOffset = (cycle as NSString).range(of: "out,").location
let samplesA: [(line: Int, within: Int)] = [(10, 0), (30, 0), (50, 0), (60, outOffset), (70, 0), (90, 0), (110, 0)]
runScenarioA(title: "A1: typo fixed in cycles 5 and 115 (stretch > largestExactStretch)", typos: [4, 114], samples: samplesA, patchNote: "")
runScenarioA(title: "A2 control: typo fixed in cycles 5 and 85 (stretch small enough to line up exactly)", typos: [4, 84], samples: samplesA.filter { $0.line < 84 }, patchNote: "")

// MARK: - Scenario B: only the first and last paragraphs shared

let firstParagraph = "Editor's note. The passage below was transcribed from a damaged reel, and the second transcription replaces the first wholesale; only this note and the closing note were kept as they were."
let lastParagraph = "Closing note. Readers who want the original wording should ask at the front desk, where the first transcription is kept in a grey box under the counter."

/// Reads a prose slice from the probe directory.
func slice(_ name: String) -> String {
    (try? String(contentsOfFile: directory + "/" + name, encoding: .utf8)) ?? ""
}

/// Runs scenario B with old middle `oldName` and new middle `newName`, sampling `sampleCount` places.
func runScenarioB(oldName: String, newName: String, sampleCount: Int) {
    let oldMiddle = slice(oldName)
    let newMiddle = slice(newName)
    guard !oldMiddle.isEmpty, !newMiddle.isEmpty else {
        print("== B: prose slices missing in \(directory)")
        return
    }
    let oldText = firstParagraph + "\n\n" + oldMiddle + "\n\n" + lastParagraph
    let newText = firstParagraph + "\n\n" + newMiddle + "\n\n" + lastParagraph
    let relocator = PlaceRelocator(oldTexts: [oldText], newTexts: [newText])
    let partners = PatienceDiff.partners(of: relocator.old.keys, in: relocator.new.keys)
    // The old middle's words, and where the new middle lies.
    let oldFirst = relocator.old.word(at: TextPlace(chapter: 0, offset: firstParagraph.utf16.count + 2))
    let oldLast = relocator.old.word(at: TextPlace(chapter: 0, offset: firstParagraph.utf16.count + 2 + oldMiddle.utf16.count))
    let newLow = firstParagraph.utf16.count + 2
    let newHigh = newLow + newMiddle.utf16.count
    let middlePaired = partners[oldFirst..<oldLast].filter { $0 >= 0 }.count
    var findings: [String: Int] = [:]
    var landings = Set<TextPlace>()
    var insideReplacement = 0
    var atReplacementStart = 0
    let replacementStart = relocator.new.landing(beforeWord: relocator.new.word(at: TextPlace(chapter: 0, offset: newLow)))
    let span = oldLast - oldFirst
    for index in 0..<sampleCount {
        let word = oldFirst + index * span / sampleCount
        let saved = TextPlace(chapter: 0, offset: relocator.old.starts[word])
        guard let anchor = TextAnchor(capturingAt: saved, in: relocator.old) else { continue }
        let result = relocator.relocate(anchor, savedAt: saved)
        findings[describe(result.finding), default: 0] += 1
        landings.insert(result.place)
        if result.place.offset >= newLow, result.place.offset <= newHigh { insideReplacement += 1 }
        if result.place == replacementStart { atReplacementStart += 1 }
    }
    print("== B: \(oldName) -> \(newName): old middle \(span) words, of which the diff paired \(middlePaired) (chance pairs)")
    print("   \(sampleCount) places -> \(landings.count) distinct landings; inside the replacement: \(insideReplacement); at its start: \(atReplacementStart)")
    for (finding, count) in findings.sorted(by: { $0.value > $1.value }) {
        print("   \(count) x \(finding)")
    }
}

runScenarioB(oldName: "alice1800.txt", newName: "frank1800.txt", sampleCount: 1000)
runScenarioB(oldName: "alice3000.txt", newName: "frank3000.txt", sampleCount: 1000)
