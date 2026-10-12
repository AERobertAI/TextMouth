import Foundation
// Gap probe 4: one-chapter text (a .txt book): skipped "CHAPTER XVIII." removed.
let seventeen = "CHAPTER XVII.\n\nThe treasurer bought a second-hand anemometer for the roof, though nobody could say why a mill needed one.\n\n"
let eighteen = "CHAPTER XVIII.\n\nThe county archaeologist visited in a borrowed van and photographed the wheel pit from every side.\n\n"
let nineteen = "CHAPTER XIX.\n\nThe last job of the year was oiling the gears, which took two people, a ladder, and most of a Sunday."
func headings(_ text: String) -> [Heading] {
    ["CHAPTER XVII.", "CHAPTER XVIII.", "CHAPTER XIX."].compactMap { label in
        let r = (text as NSString).range(of: label + "\n")
        return r.location == NSNotFound ? nil : Heading(level: 1, text: label, chapterIndex: 0, characterOffset: r.location)
    }
}
let t0 = [seventeen + eighteen + nineteen]
let t1 = [seventeen + nineteen]
let h18 = headings(t0[0])[1]
let skip = SkippedHeading(h18, anchor: TextAnchor(capturingAt: TextPlace(chapter: 0, offset: h18.characterOffset), in: BookWords(texts: t0)))
let o1 = PlaceRelocator(oldTexts: t0, newTexts: t1, newHeadings: headings(t1[0])).relocate(PlaceRelocator.Places(skippedHeadings: [skip]))
print("rebuild 1:", o1.skippedHeadingFindings, o1.places.skippedHeadings.map(\.id))
let o2 = PlaceRelocator(oldTexts: t1, newTexts: t1, newHeadings: headings(t1[0])).relocate(PlaceRelocator.Places(skippedHeadings: o1.places.skippedHeadings))
print("rebuild 2 (same text):", o2.skippedHeadingFindings, o2.places.skippedHeadings.map(\.id))
