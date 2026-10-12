import Foundation

// V10 verifier probe (scratch, not part of the app).
//
// Claim: the keeping rule (PlaceRelocator.swift 511-513) is tried only when
// the place's own match is weak, or its run breaks RIGHT AFTER its own word.
// So text put in before a place that begins with the place's first TWO or
// more words is lined up with the place's words by the diff's common-prefix
// rule, the place's word is a solid match whose run continues one more word,
// and the place lands on the inserted text instead of its own words.
//
// Cases:
//   A1  one chapter text, "BOOK ONE. CHAPTER II." restored before "BOOK ONE. CHAPTER III."
//   A2  the same book with each chapter its own reading text (an EPUB's spine)
//   A0  control: the documented one-shared-word case ("CHAPTER II." before "CHAPTER III.")
//   B2  ordinary prose: a sentence starting "The captain" put in before "The captain waved..."
//   B3  ordinary prose: three shared words ("The captain waved")
//   BP  ordinary prose: a whole paragraph starting "It was" put in before "It was nearly dark..."
//   B1  control: one shared word ("The terrier..." before "The captain waved...")

// MARK: - Helpers

/// The UTF-16 offset of the `nth` (1-based) occurrence of `phrase` in `text`.
func offset(of phrase: String, in text: String, nth: Int = 1) -> Int {
    let ns = text as NSString
    var from = 0
    var found = NSRange(location: NSNotFound, length: 0)
    for _ in 0..<nth {
        found = ns.range(of: phrase, options: .literal, range: NSRange(location: from, length: ns.length - from))
        precondition(found.location != NSNotFound, "phrase not found: \(phrase)")
        from = found.location + found.length
    }
    return found.location
}

/// Up to `count` UTF-16 units of `texts` from `place`, newlines shown as " / ", for printing.
func snippet(at place: TextPlace, in texts: [String], count: Int = 44) -> String {
    let ns = texts[place.chapter] as NSString
    let length = max(0, min(count, ns.length - place.offset))
    return ns.substring(with: NSRange(location: place.offset, length: length)).replacingOccurrences(of: "\n", with: " / ")
}

/// The fine word `index` of `words` as text, for printing the diff's pairs.
func wordText(_ words: BookWords, _ index: Int) -> String {
    guard index >= 0, index < words.count else { return "-" }
    let chapter = words.chapter(ofWord: index)
    let ns = words.texts[chapter] as NSString
    return ns.substring(with: NSRange(location: words.starts[index], length: words.ends[index] - words.starts[index]))
}

/// Prints the diff's partners for the old words around the place: which new word each lines up with.
func printPairs(_ relocator: PlaceRelocator, around saved: TextPlace) {
    let partners = PatienceDiff.partners(of: relocator.old.keys, in: relocator.new.keys)
    let word = relocator.old.word(at: saved)
    var line = "    diff pairs (old word -> new word#):"
    for k in max(0, word - 2)...min(relocator.old.count - 1, word + 3) {
        let mark = k == word ? "*" : ""
        line += " \(mark)\(wordText(relocator.old, k))->\(partners[k])"
    }
    print(line)
    print("    the new word# where the place's own words stand: \(relocator.new.word(at: TextPlace(chapter: 0, offset: 0)))..; see 'expected' below")
}

/// Relocates a place saved at `saved` (anchor captured in the old text) and prints the
/// relocator's answer, the expected place (its own words in the new text), and the
/// saved-words search alone (TextAnchorFinder.find) for comparison.
@discardableResult
func position(_ label: String, old: [String], new: [String], at saved: TextPlace, expected: TextPlace,
              headings: [Heading] = [], showPairs: Bool = true) -> PlaceRelocator {
    let relocator = PlaceRelocator(oldTexts: old, newTexts: new, newHeadings: headings)
    let anchor = TextAnchor(capturingAt: saved, in: relocator.old)!
    let result = relocator.relocate(anchor, savedAt: saved)
    let alone = TextAnchorFinder(words: relocator.new, headings: headings).find(anchor, savedAt: saved)
    let verdict = result.place == expected ? "OK" : "WRONG"
    print("[\(label)] \(verdict)")
    print("    saved at \(saved): <\(snippet(at: saved, in: old))>")
    print("    relocator -> \(result.place) \(result.finding): <\(snippet(at: result.place, in: new))>")
    print("    expected  -> \(expected): <\(snippet(at: expected, in: new))>")
    print("    finder alone -> \(alone.place) \(alone.finding)")
    if showPairs {
        let partners = PatienceDiff.partners(of: relocator.old.keys, in: relocator.new.keys)
        let word = relocator.old.word(at: saved)
        var line = "    diff pairs, old word -> new word#:"
        for k in max(0, word - 2)...min(relocator.old.count - 1, word + 3) {
            line += " \(k == word ? "*" : "")\(wordText(relocator.old, k))->\(partners[k])"
        }
        print(line)
        print("    new word# landed on: \(relocator.new.word(at: result.place)); new word# of the place's own words: \(relocator.new.word(at: expected))")
    }
    return relocator
}

// MARK: - The book (original text)

let one = "BOOK ONE. CHAPTER I. The Press\n\nThe shop on Tanner Lane had printed handbills for forty years before Ottilie Kowalczyk bought it with her brother's insurance money. She kept the old platen press, oiled the treadle every Monday, and learned to set type by candlelight when the landlord cut the gas."
let two = "BOOK ONE. CHAPTER II. The Apprentice\n\nDesmond Ferreira arrived in March with a cardboard suitcase and a letter from the parish clerk. He could read upside down and backwards, which in a print shop is worth more than a diploma, and he slept on sacks of paper behind the guillotine."
let three = "BOOK ONE. CHAPTER III. The Strike\n\nWhen the dockers walked out in August, every union hall in the city wanted leaflets by morning. Ottilie ran the press for nineteen hours straight while Hamid Lindqvist folded, counted, and carried the bundles down to the quay in a borrowed pram."
let four = "BOOK ONE. CHAPTER IV. Proofs\n\nThe police came on the third day, polite and unhurried, and asked to see the proofs. She showed them a stack of church bulletins and a seed catalogue, and they left with two jars of her pickled beetroot."
let sep = "\n\n"

// MARK: - A1: one chapter text, chapter II restored

print("=== A1: one chapter text; old I, III, IV; new I, II (restored), III, IV ===")
let oldA1 = [one + sep + three + sep + four]
let newA1 = [one + sep + two + sep + three + sep + four]
let savedA1 = TextPlace(chapter: 0, offset: offset(of: "BOOK ONE. CHAPTER III.", in: oldA1[0]))
let expectedA1 = TextPlace(chapter: 0, offset: offset(of: "BOOK ONE. CHAPTER III.", in: newA1[0]))
let labelsA1 = ["BOOK ONE. CHAPTER I. The Press", "BOOK ONE. CHAPTER II. The Apprentice", "BOOK ONE. CHAPTER III. The Strike", "BOOK ONE. CHAPTER IV. Proofs"]
let headingsA1 = labelsA1.map { Heading(level: 1, text: $0, chapterIndex: 0, characterOffset: offset(of: $0, in: newA1[0])) }
let relocatorA1 = position("A1 position at BOOK ONE. CHAPTER III.", old: oldA1, new: newA1, at: savedA1, expected: expectedA1, headings: headingsA1)

// The skip of chapter III: with an anchor (as saved today) and without one (an older save).
let anchorA1 = TextAnchor(capturingAt: savedA1, in: relocatorA1.old)!
let skipIII = SkippedHeading(level: 1, label: "BOOK ONE. CHAPTER III. The Strike", chapterIndex: 0, characterOffset: savedA1.offset, anchor: anchorA1)
var skipIIINoAnchor = skipIII
skipIIINoAnchor.anchor = nil
for (name, skip) in [("with anchor", skipIII), ("without anchor", skipIIINoAnchor)] {
    let moved = relocatorA1.relocate(skip)
    print("    skip of III (\(name)) -> \(moved.map { "\"\($0.heading.text)\" at \($0.heading.characterOffset) \($0.finding)" } ?? "nil (waits)")")
}
print("    finder alone, skip of III -> \(TextAnchorFinder(words: relocatorA1.new, headings: headingsA1).findHeading(level: 1, label: skipIII.label, anchor: anchorA1, savedAt: savedA1).map { "\"\($0.heading.text)\" \($0.finding)" } ?? "nil")")

// The whole book's places, as branch D's rebuild would move them: a position, a bookmark, the skip.
let outcome = relocatorA1.relocate(PlaceRelocator.Places(
    position: ReadingPosition(chapterIndex: 0, characterOffset: savedA1.offset, globalCharacterOffset: savedA1.offset, anchor: anchorA1),
    bookmarks: [Bookmark(number: 1, chapterIndex: 0, characterOffset: savedA1.offset, label: "the strike", anchor: anchorA1)],
    skippedHeadings: [skipIII]))
if let moved = outcome.places.position {
    print("    Outcome position: chapter \(moved.chapterIndex) offset \(moved.characterOffset) global \(moved.globalCharacterOffset ?? -1) <\(snippet(at: TextPlace(chapter: moved.chapterIndex, offset: moved.characterOffset), in: newA1))>")
}
for mark in outcome.places.bookmarks {
    print("    Outcome bookmark: chapter \(mark.chapterIndex) offset \(mark.characterOffset) <\(snippet(at: TextPlace(chapter: mark.chapterIndex, offset: mark.characterOffset), in: newA1))>")
}
print("    Outcome skipped headings: \(outcome.places.skippedHeadings.map(\.label)); log: \(outcome.counts.logLine(title: "probe"))")

// MARK: - A2: each chapter its own reading text

print("\n=== A2: chapters as separate texts; old [I, III, IV]; new [I, II, III, IV] ===")
let oldA2 = [one, three, four]
let newA2 = [one, two, three, four]
let headingsA2 = labelsA1.enumerated().map { Heading(level: 1, text: $0.element, chapterIndex: $0.offset, characterOffset: 0) }
let relocatorA2 = position("A2 position at the start of chapter III", old: oldA2, new: newA2, at: TextPlace(chapter: 1, offset: 0), expected: TextPlace(chapter: 2, offset: 0), headings: headingsA2)
let skipA2 = SkippedHeading(level: 1, label: "BOOK ONE. CHAPTER III. The Strike", chapterIndex: 1, characterOffset: 0,
                            anchor: TextAnchor(capturingAt: TextPlace(chapter: 1, offset: 0), in: relocatorA2.old))
print("    skip of III -> \(relocatorA2.relocate(skipA2).map { "\"\($0.heading.text)\" in chapter \($0.heading.chapterIndex) \($0.finding)" } ?? "nil (waits)")")
// A place a few words into chapter III's prose, for contrast: it is carried correctly.
let deeper = TextPlace(chapter: 1, offset: offset(of: "When the dockers", in: three))
position("A2 control: a place in chapter III's first sentence", old: oldA2, new: newA2, at: deeper, expected: TextPlace(chapter: 2, offset: deeper.offset), headings: headingsA2, showPairs: false)

// MARK: - A0: control, the documented one-shared-word case

print("\n=== A0 control: headings without BOOK ONE (one shared word, CHAPTER) ===")
let strip = { (s: String) in String(s.dropFirst("BOOK ONE. ".count)) }
let oldA0 = [strip(one) + sep + strip(three) + sep + strip(four)]
let newA0 = [strip(one) + sep + strip(two) + sep + strip(three) + sep + strip(four)]
let labelsA0 = labelsA1.map(strip)
let headingsA0 = labelsA0.map { Heading(level: 1, text: $0, chapterIndex: 0, characterOffset: offset(of: $0, in: newA0[0])) }
let savedA0 = TextPlace(chapter: 0, offset: offset(of: "CHAPTER III.", in: oldA0[0]))
let relocatorA0 = position("A0 position at CHAPTER III.", old: oldA0, new: newA0, at: savedA0, expected: TextPlace(chapter: 0, offset: offset(of: "CHAPTER III.", in: newA0[0])), headings: headingsA0)
let skipA0 = SkippedHeading(level: 1, label: "CHAPTER III. The Strike", chapterIndex: 0, characterOffset: savedA0.offset, anchor: TextAnchor(capturingAt: savedA0, in: relocatorA0.old))
print("    skip of III -> \(relocatorA0.relocate(skipA0).map { "\"\($0.heading.text)\" \($0.finding)" } ?? "nil (waits)")")

// MARK: - B: ordinary prose

print("\n=== B: ordinary prose, a sentence put in before the place's sentence ===")
let ferryBefore = "The ferry left the pier at half past six, loaded with crates of onions and two bicycles. Odile counted the gulls on the railing while the engine coughed and settled. "
let placeSentence = "The captain waved once from the wheelhouse and then ignored everyone until the island showed itself. "
let ferryAfter = "By then the onions had begun to smell, and the bicycles had fallen over twice.\n\nIt was nearly dark when the ramp came down, and the harbour master counted the crates by lantern."
let oldB = [ferryBefore + placeSentence + ferryAfter]
let savedB = TextPlace(chapter: 0, offset: offset(of: "The captain waved once", in: oldB[0]))
for (name, inserted) in [
    ("B2 two shared words (The captain)", "The captain kept a terrier that slept on the coiled ropes and growled at anyone wearing a hat. "),
    ("B3 three shared words (The captain waved)", "The captain waved his cap at the harbour wall as if someone there owed him money. "),
    ("B1 control, one shared word (The)", "The terrier on the coiled ropes growled at anyone wearing a hat. "),
] {
    let newB = [ferryBefore + inserted + placeSentence + ferryAfter]
    position(name, old: oldB, new: newB, at: savedB, expected: TextPlace(chapter: 0, offset: offset(of: "The captain waved once", in: newB[0])))
}

// A whole paragraph put in, starting with the same two words as the place's paragraph.
let oldBP = [ferryBefore + placeSentence + ferryAfter]
let paragraph = "It was the cook who noticed the crates had shifted. She wedged them with a mop handle and a sack of potatoes, and said nothing to the captain, who would only have shouted.\n\n"
let newBP = [ferryBefore + placeSentence + "By then the onions had begun to smell, and the bicycles had fallen over twice.\n\n" + paragraph + "It was nearly dark when the ramp came down, and the harbour master counted the crates by lantern."]
let savedBP = TextPlace(chapter: 0, offset: offset(of: "It was nearly dark", in: oldBP[0]))
let expectedBP = TextPlace(chapter: 0, offset: offset(of: "It was nearly dark", in: newBP[0]))
position("BP paragraph put in, two shared words (It was)", old: oldBP, new: newBP, at: savedBP, expected: expectedBP)
print("    jump back: \(expectedBP.offset - (PlaceRelocator(oldTexts: oldBP, newTexts: newBP).relocate(TextAnchor(capturingAt: savedBP, in: BookWords(texts: oldBP))!, savedAt: savedBP).place.offset)) UTF-16 units")
