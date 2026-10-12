import Foundation

// V21 probe: relocate(_ places:) dedups skipped headings by ID, keeping the
// FIRST in input order, while skippedHeadingFindings and counts keep one
// entry per INPUT skip. Question: when a WAITING skip (old ID) collides with
// a MOVED skip (new ID), whose anchor survives, and what does a later rebuild
// make of the survivor?
//
// Book (one chapter): an intro, a "Notes" section A, a "Notes" section B, a
// paragraph, and an end "NOTES" section G that reprints A's first note.
// The edit removes section A, so B's "Notes" heading slides up into A's exact
// offset (same chapter, offset, level, label => same ID as A had).

let intro = "The mill at the ford had stood idle for most of a decade before the parish council found money to repair it. "
    + "Volunteers cleared the race of silt and fallen alder, and a retired engineer from the waterworks drew up a plan "
    + "for the sluice gates. By the second summer the wheel turned again, slowly at first, then with a steady knock "
    + "that could be heard from the lane."
let sectionA = "Notes\n\nThe pump belonged to the angling club and went back with a new washer. Its owners asked only "
    + "that the loan be recorded in the minutes, which it duly was, under any other business."
let sectionB = "Notes\n\nA carpenter in the next village turned the replacement spoons from seasoned oak. He charged for "
    + "the timber alone and would not hear of a fee for his labour, though the work took him three weekends."
let between = "Since the reopening, school parties have come every term to watch the stones dress grain, and the "
    + "visitors' book records callers from as far as Aberdeen and Lisbon. The council intends to publish a short "
    + "history of the site next spring."
let sectionG = "NOTES\n\nThe pump belonged to the angling club and went back with a new washer. A second pump, bought "
    + "outright from a farm sale, now stands by the tail race in case of flood."

let oldText = [intro, sectionA, sectionB, between, sectionG].joined(separator: "\n\n")
let newText = [intro, sectionB, between, sectionG].joined(separator: "\n\n")

/// UTF-16 offset of `needle`'s n-th occurrence (0-based) in `text`.
func offset(of needle: String, in text: String, occurrence: Int = 0) -> Int {
    var searchStart = text.startIndex
    var found: Range<String.Index>?
    for _ in 0...occurrence {
        found = text.range(of: needle, range: searchStart..<text.endIndex)
        searchStart = found!.upperBound
    }
    return text.utf16.distance(from: text.utf16.startIndex, to: found!.lowerBound.samePosition(in: text.utf16)!)
}

let oldA = Heading(level: 2, text: "Notes", chapterIndex: 0, characterOffset: offset(of: "Notes\n\nThe pump", in: oldText))
let oldB = Heading(level: 2, text: "Notes", chapterIndex: 0, characterOffset: offset(of: "Notes\n\nA carpenter", in: oldText))
let newH = Heading(level: 2, text: "Notes", chapterIndex: 0, characterOffset: offset(of: "Notes\n\nA carpenter", in: newText))
let newG = Heading(level: 2, text: "NOTES", chapterIndex: 0, characterOffset: offset(of: "NOTES", in: newText))
let newHeadings = [newH, newG]

let oldWords = BookWords(texts: [oldText])
let newWords = BookWords(texts: [newText])

/// A skip as the reader saves it: the heading, with the words at its start.
func skip(of heading: Heading, in words: BookWords) -> SkippedHeading {
    SkippedHeading(heading, anchor: TextAnchor(capturingAt: TextPlace(chapter: heading.chapterIndex, offset: heading.characterOffset), in: words)!)
}
let skipA = skip(of: oldA, in: oldWords)
let skipB = skip(of: oldB, in: oldWords)

print("old A id: \(skipA.id)   old B id: \(skipB.id)")
print("new H id: \(newH.id)   new G id: \(newG.id)   (lengths old \(oldText.utf16.count), new \(newText.utf16.count))")
print("A's old ID == H's new ID: \(skipA.id == newH.id)")

let relocator = PlaceRelocator(oldTexts: [oldText], newTexts: [newText], newHeadings: newHeadings)

print("\n== Each skip alone ==")
print("relocate(A) -> \(relocator.relocate(skipA).map { "\($0.heading.id) \($0.finding)" } ?? "nil (waits)")")
print("relocate(B) -> \(relocator.relocate(skipB).map { "\($0.heading.id) \($0.finding)" } ?? "nil (waits)")")

/// Short description of a skip's anchor: whose words it holds, and whether
/// they stand at the skip's own numbers in `texts`.
func describe(_ s: SkippedHeading, in texts: [String]) -> String {
    let after = s.anchor.map { String($0.after.prefix(34)).replacingOccurrences(of: "\n", with: "/") } ?? "-"
    let stands = s.anchor?.stands(at: TextPlace(chapter: s.chapterIndex, offset: s.characterOffset), in: texts) ?? false
    return "id=\(s.id) anchor.after=\"\(after)\" standsAtItsHeading=\(stands)"
}

var outcomes: [String: PlaceRelocator.Outcome] = [:]
for (name, order) in [("[A, B]", [skipA, skipB]), ("[B, A]", [skipB, skipA])] {
    let outcome = relocator.relocate(PlaceRelocator.Places(skippedHeadings: order))
    outcomes[name] = outcome
    print("\n== relocate(Places(skippedHeadings: \(name))) ==")
    for s in outcome.places.skippedHeadings { print("  kept: \(describe(s, in: [newText]))") }
    print("  places.skippedHeadings.count=\(outcome.places.skippedHeadings.count)  skippedHeadingFindings=\(outcome.skippedHeadingFindings)")
    print("  counts=\(outcome.counts)  total=\(outcome.counts.total)")
    print("  log: \(outcome.counts.logLine(title: "The Mill"))")
}

// A later rebuild whose text does not change (e.g. a cache rebuild): what
// becomes of each survivor?
print("\n== Next rebuild, text unchanged (new -> new) ==")
let again = PlaceRelocator(oldTexts: [newText], newTexts: [newText], newHeadings: newHeadings)
for name in ["[A, B]", "[B, A]"] {
    let survivors = outcomes[name]!.places.skippedHeadings
    let next = again.relocate(PlaceRelocator.Places(skippedHeadings: survivors))
    print("  from \(name): findings=\(next.skippedHeadingFindings)")
    for s in next.places.skippedHeadings {
        print("    now skips: \(s.id)  (H is \(newH.id), G is \(newG.id))")
    }
}

// The same, when the next rebuild does change the text, but only after G
// (a paragraph added at the end), so H's and G's numbers and IDs stand.
print("\n== Next rebuild, a paragraph added at the book's end ==")
let laterText = newText + "\n\nThe wheel was painted again in the autumn, a dark green chosen by a vote of the volunteers."
let later = PlaceRelocator(oldTexts: [newText], newTexts: [laterText], newHeadings: newHeadings)
for name in ["[A, B]", "[B, A]"] {
    let survivors = outcomes[name]!.places.skippedHeadings
    let next = later.relocate(PlaceRelocator.Places(skippedHeadings: survivors))
    print("  from \(name): findings=\(next.skippedHeadingFindings)  now skips: \(next.places.skippedHeadings.map(\.id))")
}
