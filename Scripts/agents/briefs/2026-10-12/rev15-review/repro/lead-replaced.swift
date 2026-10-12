import Foundation
// Probe: a word replaced in local editing, mid-chapter, with plenty of words
// before it. Which finding does the relocator report?
let text = "The volunteers met at the mill on the first dry Saturday of March, with spades, a borrowed pump, and a flask of soup that Hesketh guarded as if it were the parish silver. The millrace had silted to the height of a boot, and frogspawn floated in the shallows by the sluice."
let edited = text.replacingOccurrences(of: "frogspawn floated", with: "duckweed floated")
let r = PlaceRelocator(oldTexts: [text], newTexts: [edited])
let off = (text as NSString).range(of: "frogspawn").location
let saved = TextPlace(chapter: 0, offset: off)
let a = TextAnchor(capturingAt: saved, in: r.old)!
let res = r.relocate(a, savedAt: saved)
print("replaced word:", res, " expected offset", (edited as NSString).range(of: "duckweed").location)
// A mid-chapter section heading whose first word is replaced ("Notes" -> "Endnotes")
let body = text + "\n\nNotes\n\nThe pump belonged to the angling club and went back with a new washer."
let body2 = text + "\n\nEndnotes\n\nThe pump belonged to the angling club and went back with a new washer."
let hOff = (body as NSString).range(of: "Notes").location
let hOld = Heading(level: 2, text: "Notes", chapterIndex: 0, characterOffset: hOff)
let hNew = Heading(level: 2, text: "Endnotes", chapterIndex: 0, characterOffset: (body2 as NSString).range(of: "Endnotes").location)
let r2 = PlaceRelocator(oldTexts: [body], newTexts: [body2], newHeadings: [hNew])
let skip = SkippedHeading(hOld, anchor: TextAnchor(capturingAt: TextPlace(chapter: 0, offset: hOff), in: r2.old))
print("relabelled mid-chapter heading:", r2.relocate(skip) as Any)
