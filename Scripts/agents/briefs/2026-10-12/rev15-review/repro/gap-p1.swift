import Foundation
// Gap probe 1: a skip that WAITS after rebuild 1 (its section removed) is
// handed to the next section of its level by the very next relocator run,
// because placeInOldText accepts the before-words-only search hit in the
// old text (which already lacks the section).
let opening = "CHAPTER I. The Millrace\n\nThe volunteers met at the mill on the first dry Saturday of March, with spades and a flask.\n\n"
let pump = "The Pump\n\nThe borrowed pump ran on paraffin and had to be primed with a kettle of water every half hour.\n\n"
let soup = "The Soup\n\nThe flask held leek and potato, poured into enamel mugs with the solemnity of a verger."
let t0 = [opening + pump + soup]
let t1 = [opening + soup]
let pumpHeading = Heading(level: 2, text: "The Pump", chapterIndex: 0, characterOffset: opening.utf16.count)
let soupHeading = Heading(level: 2, text: "The Soup", chapterIndex: 0, characterOffset: opening.utf16.count)
let chapterHeading = Heading(level: 1, text: "CHAPTER I. The Millrace", chapterIndex: 0, characterOffset: 0)
let start = TextPlace(chapter: 0, offset: pumpHeading.characterOffset)
let skipped = SkippedHeading(pumpHeading, anchor: TextAnchor(capturingAt: start, in: BookWords(texts: t0)))

// Rebuild 1: T0 -> T1 (the pump section removed). The skip should wait.
let r1 = PlaceRelocator(oldTexts: t0, newTexts: t1, newHeadings: [chapterHeading, soupHeading])
let o1 = r1.relocate(PlaceRelocator.Places(skippedHeadings: [skipped]))
print("rebuild 1 findings:", o1.skippedHeadingFindings, "skips:", o1.places.skippedHeadings.map(\.id))
let kept = o1.places.skippedHeadings

// Rebuild 2: T1 -> T1 (nothing changed, e.g. a cache-version rebuild).
let r2 = PlaceRelocator(oldTexts: t1, newTexts: t1, newHeadings: [chapterHeading, soupHeading])
let o2 = r2.relocate(PlaceRelocator.Places(skippedHeadings: kept))
print("rebuild 2 (unchanged text) findings:", o2.skippedHeadingFindings, "skips:", o2.places.skippedHeadings.map(\.id))

// Rebuild 3: T1 -> T1' (an unrelated edit in the opening paragraph).
let t1b = [t1[0].replacingOccurrences(of: "first dry Saturday", with: "first fine Saturday")]
let soupB = Heading(level: 2, text: "The Soup", chapterIndex: 0, characterOffset: (t1b[0] as NSString).range(of: "The Soup").location)
let r3 = PlaceRelocator(oldTexts: t1, newTexts: t1b, newHeadings: [chapterHeading, soupB])
let o3 = r3.relocate(PlaceRelocator.Places(skippedHeadings: kept))
print("rebuild 3 (unrelated edit) findings:", o3.skippedHeadingFindings, "skips:", o3.places.skippedHeadings.map(\.id))

// For comparison: the finder alone at load (branch E's known #2091 gap).
let f = TextAnchorFinder(texts: t1, headings: [chapterHeading, soupHeading])
print("finder alone:", f.findHeading(level: 2, label: "The Pump", anchor: kept[0].anchor!, savedAt: start) as Any)

// How rebuild 2 finds the waiting skip in its old text (T1, which already lacks the pump section).
let oldFinder = TextAnchorFinder(texts: t1)
print("old-text find:", oldFinder.find(kept[0].anchor!, savedAt: start))
print("anchor after-quote:", kept[0].anchor!.after.prefix(30).debugDescription)
print("counts rebuild 2:", o2.counts.logLine(title: "Mill"))
// Within one Edit Text session: edit 1 removes the pump section (skip waits);
// edit 2 fixes a typo elsewhere; the session's copy is the edit-1 text.
