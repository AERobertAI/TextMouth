import Foundation
// Probe: a skipped chapter at a chapter start (no words before it, so the moved-text rule
// cannot fire) whose whole text the new version replaces with a different chapter of
// about the same length. Does the skip move to the other chapter's heading?
let one = "CHAPTER I. The Millrace\n\nThe volunteers met at the mill on the first dry Saturday of March, with spades, a borrowed pump, and a flask of soup that Hesketh guarded as if it were the parish silver."
let three = "CHAPTER III. The Stones\n\nNobody knew where the upper millstone had gone. The parish records listed a pair of French burrs bought in 1871, and a photograph showed both of them leaning against the granary wall."
let letter = "INTERLUDE. A Letter\n\nDear committee, I enclose a cheque for the roof and a recipe for damson jam, which my late husband swore by, though he never once made it himself."
let four = "CHAPTER IV. First Flour\n\nThey ground their first sack of wheat on the longest day of the year, and the flour came out warm and speckled."
let old = [one, three, four]
let new = [one, letter, four]
let h = { (t: [String]) in t.enumerated().map { Heading(level: 1, text: $0.element.components(separatedBy: "\n").first!, chapterIndex: $0.offset, characterOffset: 0) } }
let r = PlaceRelocator(oldTexts: old, newTexts: new, newHeadings: h(new))
let skipped = h(old)[1]
let skip = SkippedHeading(skipped, anchor: TextAnchor(capturingAt: TextPlace(chapter: 1, offset: 0), in: r.old))
print("replaced chapter skip ->", r.relocate(skip) as Any)
