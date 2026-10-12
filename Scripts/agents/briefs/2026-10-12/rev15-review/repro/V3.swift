import Foundation

// V3 verifier probe (independent of the finders' probes).
//
// Claim: after the diff proves a skipped section REMOVED (carriedHeadingStart
// -> .removed -> labelRequired), PlaceRelocator.relocate(_ skipped:) accepts
// any heading of the skip's level whose label matches, anywhere in the book,
// through TextAnchorFinder.findHeading's label-only fallbacks
// (onlyHeadingWithItsLabel / nearestHeadingWithItsLabel), so the skip moves
// to ANOTHER chapter's same-labelled section that the listener never skipped.

// MARK: - The book: a village bakery's history, each chapter ending in "Notes"

let ch1 = "CHAPTER I. The Ovens\n\nThe bakehouse on Tanner Street had two brick ovens, the older of them built in 1840 by a mason who signed his work with a thumbprint in the mortar. Each morning the fires were lit at three, and by five the first batch of cottage loaves was cooling on racks by the open door. Neighbours brought their Sunday joints to roast in the falling heat once the bread was out."
let notes1 = "\n\nNotes\n\nThe mason's thumbprint can still be seen above the left-hand oven door. The roasting fee was a penny a dish until 1914, when it doubled."
let ch2 = "CHAPTER II. The Flour Ledger\n\nEvery sack that came up from the mill at Ebbsfleet was entered in a cloth-bound ledger, with its weight, its price, and the carter's initials. The ledger runs without a gap from 1862 to 1931, and its last pages are in a different hand. Prices climbed sharply in the war years and never came back down."
let notes2 = "\n\nNotes\n\nThe ledger was given to the county record office by the baker's granddaughter in 1977. A photocopy is kept behind the counter of the present shop."
let ch3 = "CHAPTER III. The Delivery Round\n\nA pony called Admiral pulled the bread cart along a round of eleven miles, through four hamlets and back by the turnpike. The roundsman was paid by the dozen loaves and kept a slate of debts that he settled on quarter days. In hard winters the cart was swapped for a sledge."
let notes3 = "\n\nNotes\n\nAdmiral's harness hangs in the village hall. The slate of debts was wiped clean, by custom, on the morning of each Christmas Eve."

/// The headings of a book whose chapters are `texts`: each chapter's first
/// line at level 1, and every "Notes" line at level 2.
func headings(of texts: [String]) -> [Heading] {
    var result: [Heading] = []
    for (index, text) in texts.enumerated() {
        let ns = text as NSString
        let firstLineEnd = ns.range(of: "\n\n").location
        let title = firstLineEnd == NSNotFound ? text : ns.substring(to: firstLineEnd)
        result.append(Heading(level: 1, text: title, chapterIndex: index, characterOffset: 0))
        var from = 0
        while true {
            let r = ns.range(of: "\n\nNotes\n\n", options: .literal, range: NSRange(location: from, length: ns.length - from))
            if r.location == NSNotFound { break }
            result.append(Heading(level: 2, text: "Notes", chapterIndex: index, characterOffset: r.location + 2))
            from = NSMaxRange(r)
        }
    }
    return result
}

/// The skip of `heading`, its anchor captured at its start in `old` (as the
/// app captures a skip's words, and as the tests' SavedPlace.skip does).
func skip(of heading: Heading, in old: BookWords) -> SkippedHeading {
    SkippedHeading(heading, anchor: TextAnchor(capturingAt: TextPlace(chapter: heading.chapterIndex, offset: heading.characterOffset), in: old))
}

/// The new headings a set of skip IDs hides from playback (the reader's own
/// test: `skippedHeadingIDs.contains(heading.id)`).
func hidden(by skips: [SkippedHeading], among newHeadings: [Heading]) -> [String] {
    let ids = Set(skips.map(\.id))
    return newHeadings.filter { ids.contains($0.id) }.map(\.id)
}

func notesHeading(_ hs: [Heading], chapter: Int) -> Heading {
    hs.first { $0.level == 2 && $0.chapterIndex == chapter }!
}

// MARK: - A. Two chapters; Edit Text deletes chapter I's skipped Notes; chapter II's Notes was NOT skipped

do {
    print("=== A. old [I+Notes, II+Notes] -> new [I, II+Notes]; only chapter I's Notes skipped ===")
    let old = [ch1 + notes1, ch2 + notes2]
    let new = [ch1, ch2 + notes2]
    let oldH = headings(of: old), newH = headings(of: new)
    let r = PlaceRelocator(oldTexts: old, newTexts: new, newHeadings: newH)
    let skipped = skip(of: notesHeading(oldH, chapter: 0), in: r.old)
    print("skipped (old):", skipped.id)
    print("relocate(skip) ->", r.relocate(skipped).map { "\($0.heading.id)  \($0.finding)" } ?? "nil (waits)")

    // The diff's verdict for the same spot, as a place: it proves the section removed.
    let start = TextPlace(chapter: 0, offset: skipped.characterOffset)
    print("a POSITION at the same spot ->", r.relocate(skipped.anchor, savedAt: start))

    // The diff pairs new chapter II's "Notes" with OLD chapter II's "Notes": provably another section.
    let partners = PatienceDiff.partners(of: r.old.keys, in: r.new.keys)
    let oldNotes2 = r.old.word(at: TextPlace(chapter: 1, offset: notesHeading(oldH, chapter: 1).characterOffset))
    let newNotes2 = r.new.word(at: TextPlace(chapter: 1, offset: notesHeading(newH, chapter: 1).characterOffset))
    print("diff: old chapter II 'Notes' word \(oldNotes2) -> new word \(partners[oldNotes2]); new chapter II 'Notes' word = \(newNotes2)")

    // The finder alone (no old text) gives the same: the relocator's labelRequired adds nothing here.
    let alone = TextAnchorFinder(texts: new, headings: newH).findHeading(level: 2, label: "Notes", anchor: skipped.anchor!, savedAt: start)
    print("TextAnchorFinder.findHeading alone ->", alone.map { "\($0.heading.id)  \($0.finding)" } ?? "nil")

    // What the book saves, and what playback then hides.
    let outcome = r.relocate(PlaceRelocator.Places(skippedHeadings: [skipped]))
    print("outcome skips:", outcome.places.skippedHeadings.map(\.id), "findings:", outcome.skippedHeadingFindings)
    print("counts:", outcome.counts, " log:", outcome.counts.logLine(title: "The Bakehouse"))
    print("new headings now hidden from playback:", hidden(by: outcome.places.skippedHeadings, among: newH))
    print("chapter II Notes was skipped before the edit?", hidden(by: [skipped], among: oldH).contains(notesHeading(oldH, chapter: 1).id))
}

// MARK: - B. Three chapters; chapter I's Notes removed; II's and III's remain, neither skipped

do {
    print("\n=== B. old [I+N, II+N, III+N] -> new [I, II+N, III+N]; only chapter I's Notes skipped ===")
    let old = [ch1 + notes1, ch2 + notes2, ch3 + notes3]
    let new = [ch1, ch2 + notes2, ch3 + notes3]
    let oldH = headings(of: old), newH = headings(of: new)
    let r = PlaceRelocator(oldTexts: old, newTexts: new, newHeadings: newH)
    let skipped = skip(of: notesHeading(oldH, chapter: 0), in: r.old)
    let outcome = r.relocate(PlaceRelocator.Places(skippedHeadings: [skipped]))
    print("outcome skips:", outcome.places.skippedHeadings.map(\.id), "findings:", outcome.skippedHeadingFindings)
    print("new headings now hidden from playback:", hidden(by: outcome.places.skippedHeadings, among: newH))
}

// MARK: - C. Control (the pinned test's case): chapter II's Notes was skipped too -> the two merge

do {
    print("\n=== C. control: as A, but chapter II's Notes skipped too (testTwoSkipsThatNowNameOneHeadingAreOne) ===")
    let old = [ch1 + notes1, ch2 + notes2]
    let new = [ch1, ch2 + notes2]
    let oldH = headings(of: old), newH = headings(of: new)
    let r = PlaceRelocator(oldTexts: old, newTexts: new, newHeadings: newH)
    let skips = [skip(of: notesHeading(oldH, chapter: 0), in: r.old), skip(of: notesHeading(oldH, chapter: 1), in: r.old)]
    let outcome = r.relocate(PlaceRelocator.Places(skippedHeadings: skips))
    print("outcome skips:", outcome.places.skippedHeadings.map(\.id), "findings:", outcome.skippedHeadingFindings)
}

// MARK: - D. Control: no other "Notes" in the book -> the skip waits

do {
    print("\n=== D. control: old [I+Notes, II] -> new [I, II]; nothing else labelled Notes ===")
    let old = [ch1 + notes1, ch2]
    let new = [ch1, ch2]
    let oldH = headings(of: old), newH = headings(of: new)
    let r = PlaceRelocator(oldTexts: old, newTexts: new, newHeadings: newH)
    let skipped = skip(of: notesHeading(oldH, chapter: 0), in: r.old)
    print("relocate(skip) ->", r.relocate(skipped).map { "\($0.heading.id)  \($0.finding)" } ?? "nil (waits)")
}

// MARK: - E. A whole chapter removed (a rebuild or Edit Text drops chapter II); its Notes skip moves to a neighbour's

do {
    print("\n=== E. old [I+N, II+N, III+N] -> new [I+N, III+N]; only chapter II's Notes skipped ===")
    let old = [ch1 + notes1, ch2 + notes2, ch3 + notes3]
    let new = [ch1 + notes1, ch3 + notes3]
    let oldH = headings(of: old), newH = headings(of: new)
    let r = PlaceRelocator(oldTexts: old, newTexts: new, newHeadings: newH)
    let skipped = skip(of: notesHeading(oldH, chapter: 1), in: r.old)
    let outcome = r.relocate(PlaceRelocator.Places(skippedHeadings: [skipped]))
    print("outcome skips:", outcome.places.skippedHeadings.map(\.id), "findings:", outcome.skippedHeadingFindings)
    print("new headings now hidden from playback:", hidden(by: outcome.places.skippedHeadings, among: newH))
    // The level-1 skip of the same removed chapter waits (the documented case):
    let chapterSkip = skip(of: oldH.first { $0.level == 1 && $0.chapterIndex == 1 }!, in: r.old)
    print("control, chapter II's level-1 skip ->", r.relocate(chapterSkip).map { "\($0.heading.id)  \($0.finding)" } ?? "nil (waits)")
}

// MARK: - F. Notes that open with the same boilerplate: found "for certain" by saved words

do {
    print("\n=== F. as A, but each Notes opens 'Sources for this chapter are listed at the back of the book.' ===")
    let boiler = "\n\nNotes\n\nSources for this chapter are listed at the back of the book. "
    let n1 = boiler + "The mason's thumbprint can still be seen above the left-hand oven door."
    let n2 = boiler + "A photocopy of the ledger is kept behind the counter of the present shop."
    let old = [ch1 + n1, ch2 + n2]
    let new = [ch1, ch2 + n2]
    let oldH = headings(of: old), newH = headings(of: new)
    let r = PlaceRelocator(oldTexts: old, newTexts: new, newHeadings: newH)
    let skipped = skip(of: notesHeading(oldH, chapter: 0), in: r.old)
    let outcome = r.relocate(PlaceRelocator.Places(skippedHeadings: [skipped]))
    print("outcome skips:", outcome.places.skippedHeadings.map(\.id), "findings:", outcome.skippedHeadingFindings)
    print("new headings now hidden from playback:", hidden(by: outcome.places.skippedHeadings, among: newH))
}
