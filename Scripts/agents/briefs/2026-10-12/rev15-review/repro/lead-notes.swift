import Foundation
// Probe: a skipped "Notes" section that Edit Text removes; another chapter's
// "Notes" section, NOT skipped, has the same level and label.
let ch1 = "CHAPTER I. The Millrace\n\nThe volunteers met at the mill on the first dry Saturday of March, with spades, a borrowed pump, and a flask of soup that Hesketh guarded as if it were the parish silver. By noon they had cleared forty yards of channel."
let notes1 = "\n\nNotes\n\nThe pump belonged to the angling club and went back with a new washer and a jar of honey for the secretary."
let ch2 = "CHAPTER II. The Wheel\n\nThe wheel itself was oak, eleven feet across, its paddles split where the frost had worked into them. A carpenter from the valley came on Tuesdays to fit new ones."
let notes2 = "\n\nNotes\n\nThe carpenter's spoons are now in the county museum, in a case by the door, beside a ledger of the mill's last accounts."
let old = [ch1 + notes1, ch2 + notes2]
let new = [ch1, ch2 + notes2]
let n1 = Heading(level: 2, text: "Notes", chapterIndex: 0, characterOffset: ch1.utf16.count + 2)
let n2new = Heading(level: 2, text: "Notes", chapterIndex: 1, characterOffset: ch2.utf16.count + 2)
let h1 = Heading(level: 1, text: "CHAPTER I. The Millrace", chapterIndex: 0, characterOffset: 0)
let h2 = Heading(level: 1, text: "CHAPTER II. The Wheel", chapterIndex: 1, characterOffset: 0)
let r = PlaceRelocator(oldTexts: old, newTexts: new, newHeadings: [h1, h2, n2new])
let start = TextPlace(chapter: 0, offset: n1.characterOffset)
let skip = SkippedHeading(n1, anchor: TextAnchor(capturingAt: start, in: r.old))
print("removed Notes skip ->", r.relocate(skip) as Any)
// Only chapter I's Notes was skipped:
let outcome = r.relocate(PlaceRelocator.Places(skippedHeadings: [skip]))
print("outcome skips:", outcome.places.skippedHeadings.map(\.id), outcome.skippedHeadingFindings)
// Three chapters with Notes; chapter I's (skipped) removed; two others remain, neither skipped.
let ch3 = "CHAPTER III. The Stones\n\nNobody knew where the upper millstone had gone. The parish records listed a pair of French burrs bought in 1871."
let notes3 = "\n\nNotes\n\nThe burrs were quarried near La Ferte-sous-Jouarre and shipped in pieces, bound with iron hoops, to Bristol."
let old3 = [ch1 + notes1, ch2 + notes2, ch3 + notes3]
let new3 = [ch1, ch2 + notes2, ch3 + notes3]
let n3new = Heading(level: 2, text: "Notes", chapterIndex: 2, characterOffset: ch3.utf16.count + 2)
let h3 = Heading(level: 1, text: "CHAPTER III. The Stones", chapterIndex: 2, characterOffset: 0)
let r3 = PlaceRelocator(oldTexts: old3, newTexts: new3, newHeadings: [h1, h2, n2new, h3, n3new])
let skip3 = SkippedHeading(n1, anchor: TextAnchor(capturingAt: start, in: r3.old))
print("three chapters, removed Notes skip ->", r3.relocate(skip3) as Any)
