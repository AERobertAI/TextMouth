import Foundation
// Verify sweep candidate S1: a skip that correctly waits after its section was removed is handed to
// the next section on the NEXT relocation, even when the text does not change again.
// Fixture: PlaceRelocatorHeadingTests.testASkippedSectionLeftOutWaitsRatherThanSkipTheNext.
let opening = "CHAPTER I. The Millrace\n\nThe volunteers met at the mill on the first dry Saturday of March, with spades and a flask.\n\n"
let pump = "The Pump\n\nThe borrowed pump ran on paraffin and had to be primed with a kettle of water every half hour.\n\n"
let soup = "The Soup\n\nThe flask held leek and potato, poured into enamel mugs with the solemnity of a verger."
let t0 = [opening + pump + soup]
let t1 = [opening + soup]
let pumpH = Heading(level: 2, text: "The Pump", chapterIndex: 0, characterOffset: opening.utf16.count)
let soupH = Heading(level: 2, text: "The Soup", chapterIndex: 0, characterOffset: opening.utf16.count)
let skip = SkippedHeading(pumpH, anchor: TextAnchor(capturingAt: TextPlace(chapter: 0, offset: pumpH.characterOffset), in: BookWords(texts: t0)))
// Rebuild 1: T0 -> T1 (the pump section removed). The skip should wait.
let first = PlaceRelocator(oldTexts: t0, newTexts: t1, newHeadings: [soupH]).relocate(PlaceRelocator.Places(skippedHeadings: [skip]))
print("rebuild 1:", first.places.skippedHeadings.map(\.id), first.skippedHeadingFindings)
// Rebuild 2: T1 -> T1 (Redo Text Extraction, nothing changed). The waiting skip goes back in.
let second = PlaceRelocator(oldTexts: t1, newTexts: t1, newHeadings: [soupH]).relocate(PlaceRelocator.Places(skippedHeadings: first.places.skippedHeadings))
print("rebuild 2:", second.places.skippedHeadings.map(\.id), second.skippedHeadingFindings)
