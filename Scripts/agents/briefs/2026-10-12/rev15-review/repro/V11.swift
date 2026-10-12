import Foundation

// V11 verifier probe: a place with no fine word after it anywhere in the old
// text (PlaceRelocator.swift:436-441) is sent to the NEW text's end, even
// when it sits in an EARLIER chapter followed only by a wordless chapter
// (a "[]" back cover, as caches before 3.0.5 wrote a named-anchor image
// page). Compare with the relocator's own chapter-end rule (453-456), the
// saved-words search alone (TextAnchorFinder.find / BookWords.landing), and
// Book.restsAtEnd ("A place short of the end, however near, is not the end").

// MARK: - A small book: three chapters of prose, then a back-cover page.

let one = "CHAPTER I. The Timetable\n\n"
    + "The night bus left the depot at a quarter past eleven, whatever the weather, and Ottoline Pargeter drove it for nineteen years. "
    + "She knew every pothole on the ring road by its sound, and she kept a tin of barley sugar under the ticket machine for passengers who looked lost."
let two = "CHAPTER II. The Depot\n\n"
    + "The depot was a tin shed behind the cattle market, heated by a paraffin stove that smoked whenever the wind came from the east. "
    + "Dov Abernathy, who swept it, claimed to have found a ferret living in the spare tyre and named it after the transport minister."
let three = "CHAPTER III. Night Service\n\n"
    + "On her final shift the passengers brought cake, a card signed by forty strangers, and a cushion embroidered with the route number. "
    + "She drove the loop twice, once for the timetable and once for herself, and parked the bus facing the hills."
let backCover = "[]"   // a back-cover image page, as a pre-3.0.5 cache wrote it

// Extra chapters a rebuild (a new extraction, or Edit Text) might bring.
let titlePage = "THE NIGHT BUS\n\nA story of the number nine route, told by the people who rode it after midnight."
let afterword = "AFTERWORD\n\nThe route was withdrawn the following spring, and the shed is now a garden centre that sells ferret food."

let old = [one, two, three, backCover]
let oldWords = BookWords(texts: old)

/// What `Book.restsAtEnd` would say of a position saved at `place` in `words`
/// (its global offset at or past the book's total).
func restsAtEnd(_ place: TextPlace, in words: BookWords) -> Bool {
    words.globalOffset(of: place) >= words.totalLength
}

func describe(_ place: TextPlace, in words: BookWords) -> String {
    let chapterText = words.texts[place.chapter]
    let head = String(chapterText.prefix(14)).replacingOccurrences(of: "\n", with: " ")
    return "(ch \(place.chapter) \"\(head)\", off \(place.offset)/\(words.length(ofChapter: place.chapter))) global \(words.globalOffset(of: place))/\(words.totalLength) restsAtEnd=\(restsAtEnd(place, in: words))"
}

/// Runs one case: relocates `saved` (captured in `oldTexts`) to `newTexts`,
/// and the saved-words search alone over `newTexts`.
func run(_ title: String, saved: TextPlace, oldTexts: [String], newTexts: [String]) {
    let oldW = BookWords(texts: oldTexts)
    let newW = BookWords(texts: newTexts)
    let anchor = TextAnchor(capturingAt: saved, in: oldW)!
    let relocator = PlaceRelocator(oldTexts: oldTexts, newTexts: newTexts)
    let moved = relocator.relocate(anchor, savedAt: saved)
    let found = TextAnchorFinder(texts: newTexts).find(anchor, savedAt: saved)
    print("== \(title)")
    print("   saved      \(describe(saved, in: oldW))  anchor.after=\(String(reflecting: anchor.after)) marksEndOfBook=\(anchor.marksEndOfBook)")
    print("   old.word(at: saved) = \(oldW.word(at: saved)) of old.count \(oldW.count)")
    print("   relocator  \(describe(moved.place, in: newW))  \(moved.finding)")
    print("   finder     \(describe(found.place, in: newW))  \(found.finding)")
}

// MARK: - The trigger: the place is in chapter III, an EARLIER chapter; only
// the wordless back cover follows it.

let endOfThree = TextPlace(chapter: 2, offset: three.utf16.count)
let beforeStop = TextPlace(chapter: 2, offset: three.utf16.count - 1)   // on the closing "."

// A1: the rebuild reads a title page the old extraction dropped (so chapter
// numbers shift and the direct check fails) and an afterword chapter before
// the back cover.
run("A1 end of ch III; new text adds a title page and an AFTERWORD chapter", saved: endOfThree,
    oldTexts: old, newTexts: [titlePage, one, two, three, afterword, backCover])
run("A2 on ch III's closing full stop; same new text", saved: beforeStop,
    oldTexts: old, newTexts: [titlePage, one, two, three, afterword, backCover])

// B: Edit Text fixes a word in ch III's last sentence; nothing is added.
let threeEdited = three.replacingOccurrences(of: "facing the hills", with: "facing the moors")
run("B  end of ch III; only ch III's last sentence edited, nothing added", saved: endOfThree,
    oldTexts: old, newTexts: [one, two, threeEdited, backCover])

// MARK: - Controls.

// C1: the same place, but the chapter after ch III has words ("ABOUT THE
// AUTHOR"): the chapter-end rule keeps it at ch III's end, past the restored
// afterword ("a chapter restored after it does not take it").
let aboutAuthor = "ABOUT THE AUTHOR\n\nThe author drove buses in three counties before writing this, her first book."
run("C1 control: end of ch III, a WORDED last chapter instead of the back cover", saved: endOfThree,
    oldTexts: [one, two, three, aboutAuthor], newTexts: [titlePage, one, two, three, afterword, aboutAuthor])

// C2: no back cover at all: the place IS the end of the book (P07), and it
// goes to the new end by design.
run("C2 control: end of ch III with no back cover (the true end, P07)", saved: endOfThree,
    oldTexts: [one, two, three], newTexts: [titlePage, one, two, three, afterword])

// C3: a "* * *" ornament page instead of "[]".
run("C3 end of ch III, a \"* * *\" ornament page last", saved: endOfThree,
    oldTexts: [one, two, three, "* * *"], newTexts: [titlePage, one, two, three, afterword, "* * *"])

// MARK: - The stored position and a bookmark, as branch D would save them.

let newText = [titlePage, one, two, three, afterword, backCover]
let newW = BookWords(texts: newText)
let relocator = PlaceRelocator(oldTexts: old, newTexts: newText)
let position = ReadingPosition(
    chapterIndex: endOfThree.chapter, characterOffset: endOfThree.offset,
    globalCharacterOffset: oldWords.globalOffset(of: endOfThree),
    anchor: TextAnchor(capturingAt: endOfThree, in: oldWords))
let bookmark = Bookmark(number: 1, chapterIndex: endOfThree.chapter, characterOffset: endOfThree.offset,
                        label: "the end of the story", anchor: TextAnchor(capturingAt: endOfThree, in: oldWords))
let outcome = relocator.relocate(PlaceRelocator.Places(position: position, bookmarks: [bookmark]))
let p = outcome.places.position!
let b = outcome.places.bookmarks[0]
print("== D  Places API, old [I, II, III, []] -> new [title, I, II, III, AFTERWORD, []]")
print("   before: position global \(position.globalCharacterOffset!) of old total \(oldWords.totalLength): restsAtEnd=\(position.globalCharacterOffset! >= oldWords.totalLength)")
print("   after:  position (ch \(p.chapterIndex), off \(p.characterOffset)) global \(p.globalCharacterOffset!) of new total \(newW.totalLength): restsAtEnd=\(p.globalCharacterOffset! >= newW.totalLength); finding \(outcome.positionFinding!)")
print("           new anchor marksEndOfBook=\(p.anchor!.marksEndOfBook) (sticky: every later rebuild keeps it at the end)")
print("   bookmark \"\(b.label)\" -> (ch \(b.chapterIndex), off \(b.characterOffset)) = the back-cover page, after the AFTERWORD; finding \(outcome.bookmarkFindings[0])")
print("   the AFTERWORD is chapter 4, global \(newW.chapterStarts[4])..<\(newW.chapterStarts[5]); ch III's end in the new text is (ch 3, off \(three.utf16.count)) global \(newW.globalOffset(of: TextPlace(chapter: 3, offset: three.utf16.count)))")

// E: a new reading now extracts the back cover's text (its blurb) where the
// old cache wrote "[]", and reads a title page that shifts the chapters.
let blurb = "Praise for The Night Bus: a funny, tender account of a rural route and the driver who kept it running past midnight."
run("E  end of ch III; the old \"[]\" back cover now reads as a blurb, title page added", saved: endOfThree,
    oldTexts: old, newTexts: [titlePage, one, two, three, blurb])
