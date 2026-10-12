import Foundation
// Gap probe 3: a position at the very start of the book (never begun, or
// "Start Over") when a rebuild puts text in at the book's start, and the
// counts/anythingMoved for an unchanged place whose global offset changed.
let c0 = "CHAPTER I. The Millrace\n\nThe volunteers met at the mill on the first dry Saturday of March, with spades, a borrowed pump, and a flask of soup."
let c1 = "CHAPTER II. The Wheel\n\nThe wheel itself was oak, eleven feet across, its paddles split where the frost had worked into them."
let c2 = "CHAPTER III. The Stones\n\nNobody knew where the upper millstone had gone. The parish records listed a pair of French burrs bought in 1871."
let old = [c0, c1, c2]
// (a) Text put in at the start of chapter 0 (a title line restored).
let newA = ["The Mill at Hollins Ford\n\nA restoration diary\n\n" + c0, c1, c2]
let oldWords = BookWords(texts: old)
let start = TextPlace(chapter: 0, offset: 0)
let r = PlaceRelocator(oldTexts: old, newTexts: newA)
let pos = ReadingPosition(chapterIndex: 0, characterOffset: 0, globalCharacterOffset: 0, anchor: TextAnchor(capturingAt: start, in: oldWords))
let o = r.relocate(PlaceRelocator.Places(position: pos))
let p = o.places.position!
print("(a) start-of-book position ->", p.chapterIndex, p.characterOffset, "global", p.globalCharacterOffset as Any, o.positionFinding as Any,
      "percent", Double(p.globalCharacterOffset ?? 0) / Double(BookWords(texts: newA).totalLength) * 100)
// (b) A whole front-matter chapter put in before chapter 0.
let newB = ["The Mill at Hollins Ford\n\nA restoration diary by the Hollins Ford Mill Society."] + old
let rB = PlaceRelocator(oldTexts: old, newTexts: newB)
let oB = rB.relocate(PlaceRelocator.Places(position: pos))
let pB = oB.places.position!
print("(b) start-of-book position ->", pB.chapterIndex, pB.characterOffset, "global", pB.globalCharacterOffset as Any, oB.positionFinding as Any)

// (c) Unchanged finding but changed global offset: counts say nothing moved.
let newC = [c0.replacingOccurrences(of: "a flask of soup.", with: "a flask of soup, and nothing else whatever for the whole long cold day."), c1, c2]
let late = TextPlace(chapter: 2, offset: (c2 as NSString).range(of: "French burrs").location)
let posC = ReadingPosition(chapterIndex: 2, characterOffset: late.offset, globalCharacterOffset: oldWords.globalOffset(of: late), anchor: TextAnchor(capturingAt: late, in: oldWords))
let oC = PlaceRelocator(oldTexts: old, newTexts: newC).relocate(PlaceRelocator.Places(position: posC))
print("(c) finding", oC.positionFinding as Any, "anythingMoved", oC.counts.anythingMoved, "places changed", oC.places != PlaceRelocator.Places(position: posC),
      "global old", posC.globalCharacterOffset as Any, "-> new", oC.places.position?.globalCharacterOffset as Any)
