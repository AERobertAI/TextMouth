import Foundation
// Probe: a skipped section REPLACED by a different section (not removed outright).
let opening = "CHAPTER I. The Millrace\n\nThe volunteers met at the mill on the first dry Saturday of March, with spades and a flask.\n\n"
let pump = "Pump Repairs\n\nThe borrowed pump ran on paraffin and had to be primed with a kettle of water every half hour.\n\n"
let bellows = "Bellows\n\nA blacksmith in Ludlow lent them a forge, whose leather lungs wheezed like a church harmonium on a damp Sunday morning, and nobody dared ask its age.\n\n"
let soup = "The Soup\n\nThe flask held leek and potato, poured into enamel mugs with the solemnity of a verger."
let old = [opening + pump + soup]
let new = [opening + bellows + soup]
let pumpH = Heading(level: 2, text: "Pump Repairs", chapterIndex: 0, characterOffset: opening.utf16.count)
let bellowsH = Heading(level: 2, text: "Bellows", chapterIndex: 0, characterOffset: opening.utf16.count)
let soupNew = Heading(level: 2, text: "The Soup", chapterIndex: 0, characterOffset: (opening + bellows).utf16.count)
let r = PlaceRelocator(oldTexts: old, newTexts: new, newHeadings: [bellowsH, soupNew])
let start = TextPlace(chapter: 0, offset: pumpH.characterOffset)
let a = TextAnchor(capturingAt: start, in: r.old)!
print("place at the replaced section's heading:", r.relocate(a, savedAt: start))
let skip = SkippedHeading(pumpH, anchor: a)
print("skip of the replaced section ->", r.relocate(skip) as Any)

// Same, but the replacement is about as long (like-for-like)
let bellows2 = "Bellows\n\nA blacksmith lent them a forge whose leather lungs wheezed like a church harmonium.\n\n"
let new2 = [opening + bellows2 + soup]
let bellowsH2 = Heading(level: 2, text: "Bellows", chapterIndex: 0, characterOffset: opening.utf16.count)
let soupNew2 = Heading(level: 2, text: "The Soup", chapterIndex: 0, characterOffset: (opening + bellows2).utf16.count)
let r2 = PlaceRelocator(oldTexts: old, newTexts: new2, newHeadings: [bellowsH2, soupNew2])
print("like-for-like place:", r2.relocate(a, savedAt: start))
print("like-for-like skip ->", r2.relocate(skip) as Any)

// Control: pure removal (the existing test's shape)
let new3 = [opening + soup]
let soupNew3 = Heading(level: 2, text: "The Soup", chapterIndex: 0, characterOffset: opening.utf16.count)
let r3 = PlaceRelocator(oldTexts: old, newTexts: new3, newHeadings: [soupNew3])
print("pure removal skip ->", r3.relocate(skip) as Any)
// Non-like-for-like: the replacement is far longer than the section it replaced.
let forge = "Forge Work\n\nA blacksmith in Ludlow lent them a portable forge, whose leather lungs wheezed like a church harmonium on a damp Sunday morning. He showed them how to draw out a bar, upset its end, and punch a hole while the iron glowed cherry red. Nobody dared ask the forge's age, and nobody dared ask his. By evening the volunteers had made twelve new hinges for the granary door, two pokers, and a hook that nobody could find a use for.\n\n"
let new4 = [opening + forge + soup]
let forgeH = Heading(level: 2, text: "Forge Work", chapterIndex: 0, characterOffset: opening.utf16.count)
let soupNew4 = Heading(level: 2, text: "The Soup", chapterIndex: 0, characterOffset: (opening + forge).utf16.count)
let r4 = PlaceRelocator(oldTexts: old, newTexts: new4, newHeadings: [forgeH, soupNew4])
print("long replacement place:", r4.relocate(a, savedAt: start))
print("long replacement skip ->", r4.relocate(skip) as Any)
