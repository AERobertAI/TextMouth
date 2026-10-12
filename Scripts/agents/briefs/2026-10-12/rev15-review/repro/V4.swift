import Foundation

// V4 verifier probe (independent of the finder's lead/replsec probe).
//
// Claim: a skipped level-2 section that the new text REPLACES with a
// different, much longer section is carried by carry()'s moved-text rule
// (PlaceRelocator.swift 477-479) as .followedMovedText, because the saved
// words' one best spot is found on the BEFORE-words alone and lands on the
// replacement's first word, which the diff left unpaired. carriedHeadingStart
// then returns nil (its `default:` at 376-377), so the removal guard
// (labelRequired, 336-343) is never armed and findHeading hands the skip to
// the replacement section's heading. The pure-removal control waits.
//
// The same main.swift is built twice: against the repo's PlaceRelocator.swift
// unchanged (build-probe.sh), and against a copy with only the moved-text
// rule disabled (cf/), to show that rule is the cause.

// MARK: - The book: a community orchard society's year

let chapterHeading = "CHAPTER IV. The Walled Orchard"
let opening = chapterHeading + "\n\nThe society took over the walled orchard behind the old rectory in October, when the brambles had reached the second rail of the fence and the pear trees leaned against the brickwork like commuters on a late train.\n\n"

/// The section the listener skipped (old text): 22 fine words with its heading.
let grafting = "Grafting Day\n\nIn February the members cut scion wood from the russets and bound each piece to its rootstock with raffia and grafting wax.\n\n"

/// What the new text puts where that section was: a different section about
/// four times as long, so the stretch is NOT like-for-like.
let wassail = "Wassail Night\n\nOn the twelfth night after Christmas the village climbed the lane with lanterns, a bucket of mulled cider, and a slice of toast soaked in it for the oldest tree. A retired tuba player from the silver band led the procession, playing something that might once have been a hymn. Children banged saucepans to wake the trees, the grown-ups poured cider over the roots, and the vicar, who had been warned it was a pagan rite, sang louder than anyone. Afterwards everyone crowded into the potting shed, where the stove smoked so badly that the minutes record only coughing.\n\n"

/// The section after it, unchanged in every version.
let pruning = "Pruning the Cookers\n\nBy March the work moved to the old trees, whose crossing branches had to come out before the buds broke, one cut at a time from a stepladder borrowed from the church hall."

/// A second chapter, unchanged, so the book is more than one chapter.
let press = "CHAPTER V. The Press\n\nIn September the society hired a rack-and-cloth press from a farm in the next valley and spent a weekend learning why nobody uses one any more. The pomace stuck to everything, the cloths tore, and the juice tasted faintly of the previous owner's pears."

// MARK: - Helpers

/// The headings of a chapter-0 text made of `sections` after `opening`
/// (each section's first line is its level-2 heading), plus chapter V's.
func headings(sections: [String]) -> [Heading] {
    var result = [Heading(level: 1, text: chapterHeading, chapterIndex: 0, characterOffset: 0)]
    var offset = opening.utf16.count
    for section in sections {
        let label = String(section.split(separator: "\n", maxSplits: 1)[0])
        result.append(Heading(level: 2, text: label, chapterIndex: 0, characterOffset: offset))
        offset += section.utf16.count
    }
    result.append(Heading(level: 1, text: "CHAPTER V. The Press", chapterIndex: 1, characterOffset: 0))
    return result
}

/// The text of new word `word` in `words`, for printing.
func wordText(_ word: Int, in words: BookWords) -> String {
    guard word >= 0, word < words.count else { return "<end>" }
    let place = words.start(ofWord: word)
    let text = words.texts[place.chapter] as NSString
    return text.substring(with: NSRange(location: words.starts[word], length: words.ends[word] - words.starts[word]))
}

/// Runs one scenario: the skip of "Grafting Day" (with its anchor, and
/// without one), the place at its heading, and the diagnostics behind them.
func run(_ title: String, newSections: [String], skippedSection: String = grafting) {
    let oldTexts = [opening + skippedSection + pruning, press]
    let newTexts = [opening + newSections.joined() + pruning, press]
    let oldHeadings = headings(sections: [skippedSection, pruning])
    let newHeadings = headings(sections: newSections + [pruning])
    let skippedHeading = oldHeadings[1]
    let relocator = PlaceRelocator(oldTexts: oldTexts, newTexts: newTexts, newHeadings: newHeadings)
    let start = TextPlace(chapter: 0, offset: skippedHeading.characterOffset)
    let anchor = TextAnchor(capturingAt: start, in: relocator.old)!

    print("=== \(title)")
    print("skipped heading: \(skippedHeading.id)")
    print("new level-2 headings: \(newHeadings.filter { $0.level == 2 }.map(\.id))")
    let removedWords = FineWords.keys(in: skippedSection).count
    let putInWords = newSections.map { FineWords.keys(in: $0).count }.reduce(0, +)
    print("fine words: removed section \(removedWords), put in \(putInWords) (like-for-like needs <= \(2 * removedWords + 8))")
    print("anchor.before = \(anchor.before.debugDescription)")
    print("anchor.after  = \(anchor.after.debugDescription)")

    // Diagnostics through the public API: the saved words' one best spot in
    // the new text, and whether the diff left that word unpaired (put in).
    let newFinder = TextAnchorFinder(words: relocator.new, headings: newHeadings)
    let partners = PatienceDiff.partners(of: relocator.old.keys, in: relocator.new.keys)
    let paired = Set(partners.filter { $0 >= 0 })
    if let spot = newFinder.onlyBestSpot(for: anchor) {
        print("onlyBestSpot: word \(spot.word) \"\(wordText(spot.word, in: relocator.new))\" at \(spot.place); put in (unpaired): \(!paired.contains(spot.word))")
    } else {
        print("onlyBestSpot: nil")
    }
    let oldFirst = relocator.old.word(at: start)
    print("old heading word \(oldFirst) \"\(wordText(oldFirst, in: relocator.old))\" partner \(partners[oldFirst]); next old word partner \(partners[oldFirst + 1])")

    // The place at the skipped heading's start, as a position would be moved.
    print("position at the heading -> \(relocator.relocate(anchor, savedAt: start))")
    // The finder alone (no old text), for comparison.
    print("finder alone findHeading -> \(String(describing: newFinder.findHeading(level: 2, label: skippedHeading.text, anchor: anchor, savedAt: start)))")
    // The relocator's answer for the skip, with its anchor and without one.
    let skip = SkippedHeading(skippedHeading, anchor: anchor)
    print("relocate(skip) -> \(String(describing: relocator.relocate(skip)))")
    print("relocate(skip saved without anchor) -> \(String(describing: relocator.relocate(SkippedHeading(skippedHeading))))")
    // What a caller would write back.
    let outcome = relocator.relocate(PlaceRelocator.Places(position: nil, bookmarks: [], skippedHeadings: [skip]))
    print("Outcome.skippedHeadings ids: \(outcome.places.skippedHeadings.map(\.id)); findings: \(outcome.skippedHeadingFindings)")
    print("counts: \(outcome.counts.logLine(title: "Orchard"))")
    print("")
}

// MARK: - Scenarios

// A: the skipped section replaced by a different section ~4x as long.
run("A. 'Grafting Day' REPLACED by 'Wassail Night' (about 4x longer)", newSections: [wassail])

// B: the control, a pure removal (the shape the existing tests pin).
run("B. CONTROL: 'Grafting Day' REMOVED outright", newSections: [])

// C: a replacement whose heading starts with the same common word as the
// skipped one ("The ..."), to see whether a chance pairing changes the path.
let theGrafting = grafting.replacingOccurrences(of: "Grafting Day", with: "The Grafting")
let theWassail = wassail.replacingOccurrences(of: "Wassail Night", with: "The Wassail")
run("C. 'The Grafting' REPLACED by 'The Wassail' (common first word)", newSections: [theWassail], skippedSection: theGrafting)

// D: the candidate's side claim: a one-word in-place replacement of a
// position's own word is labelled .followedMovedText, not .wordReplaced.
do {
    let oldTexts = [opening + grafting + pruning, press]
    let newTexts = [opening + grafting + pruning.replacingOccurrences(of: "stepladder", with: "trestle"), press]
    let relocator = PlaceRelocator(oldTexts: oldTexts, newTexts: newTexts)
    let offset = (opening + grafting).utf16.count + (pruning as NSString).range(of: "stepladder").location
    let place = TextPlace(chapter: 0, offset: offset)
    let anchor = TextAnchor(capturingAt: place, in: relocator.old)!
    let result = relocator.relocate(anchor, savedAt: place)
    let landedWord = relocator.new.word(at: result.place)
    print("=== D. one-word replacement 'stepladder' -> 'trestle', position at 'stepladder'")
    print("relocate -> \(result) (lands on \"\(wordText(landedWord, in: relocator.new))\")")
}
