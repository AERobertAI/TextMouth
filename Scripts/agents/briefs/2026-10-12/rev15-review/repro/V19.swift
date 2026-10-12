import Foundation

// V19 verification probe: a place in a chapter WITHOUT text (an image plate,
// a cover) carries an anchor whose quotes are both empty. Such an anchor
// "stands" at offset 0 of any chapter, so PlaceRelocator's rule 1
// (TextAnchorFinder.settled, PlaceRelocator.swift:244) keeps the old numbers
// even when a chapter was put in before it, although the relocator holds the
// old text and the diff that says where the plate went.

// MARK: - The book (realistic multi-sentence chapters)

let ropewalk = """
CHAPTER I. The Ropewalk

The ropewalk ran four hundred yards behind the tannery, a long shed with a tarred roof and a floor of packed cinders. \
Every morning the spinners walked backwards down its length, paying out hemp from bundles tied at their waists, while a boy \
turned the great wheel at the far end. By noon the shed smelled of tar and sweat, and the finished cables lay coiled along the north wall.
"""

let leith = """
CHAPTER II. The Order from Leith

In March a letter came from a shipping agent in Leith asking for twelve hawsers of a weight the walk had never laid. \
Bertram Pell read it twice at the counting-house window and then carried it out to the shed, where Ludmila Okafor was splicing \
an eye into a mooring line. She said the walk was too short for cables that heavy, and that the wheel would crack before the third strand was twisted.
"""

let lengthening = """
CHAPTER III. Lengthening the Walk

They knocked out the end wall in April and ran the walk across the tannery yard on trestles, under sailcloth, so that the \
spinners could keep their pace in the rain. The tanners complained about the noise and the hemp dust in their pits. By the end \
of the month the walk was six hundred yards long, and the first of the Leith hawsers lay curing in the drying loft.
"""

let preface = """
PREFACE TO THE SECOND EDITION

This edition restores the account of the Leith order from the counting-house letter books, which were thought lost when the \
tannery burned. The plates are printed from the original glass negatives, now held by the county record office, and the \
spelling of the spinners' names follows the parish registers.
"""

let interlude = """
INTERLUDE. The Tar Copper

The tar copper stood in a brick hearth at the near end of the walk, and it had to be lit two hours before the spinners came in. \
Whoever lit it was paid a penny extra and allowed to sleep in the loft, which in winter was the warmest place in the parish. \
Nobody who worked the copper for long kept the skin on the backs of their hands.
"""

/// An image-only plate page: no reading text at all.
let plate = ""

// MARK: - Helpers

/// Prints a place with the first words of the chapter it is in, so a reader
/// of the output can see which chapter it fell in.
func describe(_ place: TextPlace, in words: BookWords) -> String {
    guard place.chapter >= 0, place.chapter < words.chapterCount else { return "(\(place.chapter),\(place.offset)) <no such chapter>" }
    let text = words.texts[place.chapter]
    let head = text.isEmpty ? "<empty chapter: the plate>" : String(text.prefix(34)).debugDescription
    return "(\(place.chapter),\(place.offset)) in chapter \(place.chapter) = \(head), chapter length \(words.length(ofChapter: place.chapter))"
}

/// Relocates `saved` (its anchor captured in the old text, or nil) and prints the result.
func show(_ label: String, _ r: PlaceRelocator, _ saved: TextPlace, captured: Bool = true, anchor given: TextAnchor? = nil) {
    let anchor = given ?? (captured ? TextAnchor(capturingAt: saved, in: r.old) : nil)
    let result = r.relocate(anchor, savedAt: saved)
    let a = anchor.map { "before: \($0.before.suffix(10).debugDescription), after: \($0.after.prefix(10).debugDescription), fraction: \(String(format: "%.3f", $0.fraction))" } ?? "nil"
    print("  \(label)")
    print("    saved \(describe(saved, in: r.old)) [old]  anchor(\(a))")
    print("    ->    \(describe(result.place, in: r.new)) [new]  finding: \(result.finding)")
}

// MARK: - S1: a preface put in before everything

print("S1. old [I, plate, II, III] -> new [preface, I, plate, II, III] (a preface chapter put in at the front)")
do {
    let r = PlaceRelocator(oldTexts: [ropewalk, plate, leith, lengthening], newTexts: [preface, ropewalk, plate, leith, lengthening])
    show("the place on the plate, anchored (expected the plate's new index: (2,0))", r, TextPlace(chapter: 1, offset: 0))
    show("the place on the plate, saved without an anchor", r, TextPlace(chapter: 1, offset: 0), captured: false)
    show("neighbor before it: end of chapter I", r, TextPlace(chapter: 0, offset: ropewalk.utf16.count))
    show("neighbor after it: start of chapter II", r, TextPlace(chapter: 2, offset: 0))
    show("neighbor after it: 'Bertram Pell' in chapter II", r, TextPlace(chapter: 2, offset: (leith as NSString).range(of: "Bertram Pell").location))

    // What the diff knows: where the plate's neighbors' words went.
    let partners = PatienceDiff.partners(of: r.old.keys, in: r.new.keys)
    let lastOfI = r.old.chapterFirstWords[1] - 1            // old chapter I's last word
    let firstOfII = r.old.chapterFirstWords[2]              // old chapter II's first word (the plate holds none)
    print("    diff: old chapter I's last word (old word \(lastOfI)) -> new word \(partners[lastOfI]) in new chapter \(r.new.chapter(ofWord: partners[lastOfI]))")
    print("    diff: old chapter II's first word (old word \(firstOfII)) -> new word \(partners[firstOfII]) in new chapter \(r.new.chapter(ofWord: partners[firstOfII]))")
    print("    so the only chapter between them in the new text is chapter 2: \(describe(TextPlace(chapter: 2, offset: 0), in: r.new))")

    // What rules 2-3 (the diff) give for this same place when rule 1 cannot
    // fire: a place saved without an anchor whose saved offset lies past the
    // new chapter 1's length is read at (1,0) in the old text (held within
    // the empty chapter) and carried by the diff.
    show("same plate place, nil anchor, saved offset past new ch.1 so rule 1 cannot fire (what the diff says)", r,
         TextPlace(chapter: 1, offset: ropewalk.utf16.count + 1), captured: false)

    // The finder alone (today's load path, with no old text) does the same as
    // the relocator: the relocator's old text and diff add nothing here.
    let anchor = TextAnchor(capturingAt: TextPlace(chapter: 1, offset: 0), in: r.old)!
    let alone = TextAnchorFinder(words: r.new).find(anchor, savedAt: TextPlace(chapter: 1, offset: 0))
    print("    TextAnchorFinder alone (no old text): \(alone.place) \(alone.finding)")
}

// MARK: - S2: a chapter restored in the middle of the book

print("\nS2. old [I, II, plate, III] -> new [I, interlude, II, plate, III] (a chapter restored before chapter II)")
do {
    let r = PlaceRelocator(oldTexts: [ropewalk, leith, plate, lengthening], newTexts: [ropewalk, interlude, leith, plate, lengthening])
    show("the place on the plate (after chapter II; expected (3,0))", r, TextPlace(chapter: 2, offset: 0))
    show("neighbor before it: end of chapter II", r, TextPlace(chapter: 1, offset: leith.utf16.count))
    show("neighbor after it: start of chapter III", r, TextPlace(chapter: 3, offset: 0))
}

// MARK: - S3: the whole book's places, as branch D would save them

print("\nS3. relocate(Places) for S1's edit: a position and a bookmark on the plate")
do {
    let oldTexts = [ropewalk, plate, leith, lengthening]
    let newTexts = [preface, ropewalk, plate, leith, lengthening]
    let r = PlaceRelocator(oldTexts: oldTexts, newTexts: newTexts)
    let onPlate = TextPlace(chapter: 1, offset: 0)
    let anchor = TextAnchor(capturingAt: onPlate, in: r.old)
    let position = ReadingPosition(chapterIndex: 1, characterOffset: 0, globalCharacterOffset: r.old.globalOffset(of: onPlate), anchor: anchor)
    let bookmark = Bookmark(number: 1, chapterIndex: 1, characterOffset: 0, label: "the 1887 photograph", anchor: anchor)
    let outcome = r.relocate(PlaceRelocator.Places(position: position, bookmarks: [bookmark]))
    let p = outcome.places.position!
    let b = outcome.places.bookmarks[0]
    print("    old position: chapter 1 offset 0, global \(position.globalCharacterOffset!) (old book length \(r.old.totalLength); chapter I is 0..<\(ropewalk.utf16.count))")
    print("    new position: chapter \(p.chapterIndex) offset \(p.characterOffset), global \(p.globalCharacterOffset!), finding \(outcome.positionFinding!)")
    print("      new chapter \(p.chapterIndex) is: \(describe(TextPlace(chapter: p.chapterIndex, offset: p.characterOffset), in: r.new))")
    print("      its anchor captured anew: before \(p.anchor!.before.debugDescription), after \(p.anchor!.after.prefix(40).debugDescription)")
    print("    new bookmark '\(b.label)': chapter \(b.chapterIndex) offset \(b.characterOffset), finding \(outcome.bookmarkFindings[0])")

    // A later rebuild (say a third edition that adds a dedication up front)
    // now carries the place as chapter I's start: the error is permanent.
    let dedication = "For the spinners of the Hollins walk, who were paid by the fathom and never by the hour, and who taught the trade to their children."
    let later = PlaceRelocator(oldTexts: newTexts, newTexts: [dedication] + newTexts)
    let again = later.relocate(p.anchor, savedAt: TextPlace(chapter: p.chapterIndex, offset: p.characterOffset))
    print("    a later rebuild (dedication added at the front): \(describe(again.place, in: later.new)), finding \(again.finding)")
    print("      the plate is now new chapter 3; the place stays with chapter I's words")
}

// MARK: - S4: a damaged anchor (both quotes empty) in a chapter WITH text

print("\nS4. extension: a damaged anchor (decoded as before \"\", after \"\", fraction 0) in a chapter with text")
do {
    let r = PlaceRelocator(oldTexts: [ropewalk, leith, lengthening], newTexts: [preface, ropewalk, leith, lengthening])
    let saved = TextPlace(chapter: 1, offset: (leith as NSString).range(of: "Bertram Pell").location)
    show("damaged anchor at 'Bertram Pell' in chapter II", r, saved, anchor: TextAnchor(before: "", after: "", fraction: 0))
    show("the same place saved with no anchor at all", r, saved, captured: false)
    show("the same place with its real anchor", r, saved)
}
