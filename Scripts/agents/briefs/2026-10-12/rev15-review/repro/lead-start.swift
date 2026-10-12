import Foundation
// Verify sweep candidate S2: a position at the very start of the book (never begun, or Start Over)
// when the rebuild restores a preface chapter before chapter 0.
let one = "CHAPTER I. The Millrace\n\nThe volunteers met at the mill on the first dry Saturday of March, with spades, a borrowed pump, and a flask of soup that Hesketh guarded as if it were the parish silver."
let two = "CHAPTER II. The Wheel\n\nThe wheel itself was oak, eleven feet across, its paddles split where the frost had worked into them."
let preface = "PREFACE\n\nThis diary was kept by the volunteers of the Hollins Ford mill between March and November, and is printed here as they wrote it."
let old = [one, two]
let new = [preface, one, two]
let r = PlaceRelocator(oldTexts: old, newTexts: new)
let start = TextPlace(chapter: 0, offset: 0)
let a = TextAnchor(capturingAt: start, in: r.old)!
let pos = ReadingPosition(chapterIndex: 0, characterOffset: 0, globalCharacterOffset: 0, anchor: a)
let out = r.relocate(PlaceRelocator.Places(position: pos))
print("start-of-book position ->", out.places.position.map { ($0.chapterIndex, $0.characterOffset, $0.globalCharacterOffset as Any) } as Any, out.positionFinding as Any)
// For contrast, the end of the book is kept at the end by rule 1 (P07):
let end = r.old.endPlace
print("end-of-book place ->", r.relocate(TextAnchor(capturingAt: end, in: r.old)!, savedAt: end))
