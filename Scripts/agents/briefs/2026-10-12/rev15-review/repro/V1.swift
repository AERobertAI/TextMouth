import Foundation

// V1 verifier probe (independent of the finders' probes).
//
// Claim: PlaceRelocator.heldInOldText holds a place saved WITHOUT an anchor
// whose chapter is past the old text's last chapter at old.endPlace; the
// words read there mark the end of the book, so rule 1 sends the place to
// the NEW text's end (.movedByTheDiff(.endOfBook)) and moved(_:to:) stores
// globalCharacterOffset == the new book's length: Book.restsAtEnd reads it
// Finished. The reader's own rule (ReaderViewModel.openingPlace) opens such
// a place at the last chapter's START unless its global offset was at the end.

// MARK: - A realistic four-chapter book (original text)

let kettle = """
CHAPTER I. The Kettle

The repair café opened in the church hall on the second Saturday of every month, between the jumble sale and the choir's rehearsal. Odile Fennimore brought a kettle whose switch had stopped clicking off, and stood over the volunteer while he took it apart, explaining that it had belonged to her aunt.

The fault was a bimetallic disc no larger than a shirt button. Barnaby Quist found a replacement in a biscuit tin of spares, fitted it in four minutes, and spent the next twenty listening to the history of the aunt.
"""
let sewing = """
CHAPTER II. The Sewing Machine

Mrs. Tadros arrived with a treadle sewing machine on a sack trolley, having pushed it up the hill from the bus stop. Its belt had perished, and the needle bar was seized with forty years of lint and dried oil.

Two volunteers worked on it all afternoon. By four o'clock it was stitching a straight seam through denim, and Mrs. Tadros had taken orders for three pairs of curtains from people waiting in the toaster queue.
"""
let radioA = """
CHAPTER III. The Radio

The valve radio came in a laundry basket, wrapped in a bath towel, carried by a teenager who said it was his grandfather's and that nobody was to know he had brought it. The dial lamp worked, but nothing else did.
"""
let radioB = """
Wendel Okafor traced the fault to a capacitor that had burst and leaked wax down the inside of the case. He had no exact match, so he built one out of two smaller ones twisted together, and at ten past five the hall filled with the shipping forecast.
"""
let closingA = """
CHAPTER IV. Closing Time

At half past five the choir began arriving and the volunteers packed the tools into crates. The tally on the whiteboard read nineteen items mended, six beyond help, and one umbrella nobody had claimed.
"""
let closingB = """
Barnaby Quist took the umbrella home, fixed its spoke over the following week, and brought it back the next month, where it stood by the door for another year before anyone asked about it.
"""
let radio = radioA + "\n\n" + radioB
let closing = closingA + "\n\n" + closingB

/// The old content.md as this build reads it: four chapters.
let old = [kettle, sewing, radio, closing]

// MARK: - The app's own rules, copied (they live on ReaderViewModel / Book)

/// ReaderViewModel+SavedPlaces.swift:132-148 `openingPlace(of:savedGlobalOffset:in:)`,
/// line for line, over chapter texts (content.totalCharacterCount is the sum of
/// the chapters' UTF-16 lengths; utf16Length is utf16.count).
func openingPlace(of saved: TextPlace, savedGlobalOffset: Int?, in texts: [String]) -> TextPlace {
    guard let last = texts.indices.last, saved.chapter >= 0 else { return TextPlace(chapter: 0, offset: 0) }
    guard saved.chapter <= last else {
        let total = texts.reduce(0) { $0 + $1.utf16.count }
        let wasAtTheEnd = savedGlobalOffset.map { total > 0 && $0 >= total } ?? false
        return TextPlace(chapter: last, offset: wasAtTheEnd ? texts[last].utf16.count : 0)
    }
    let length = texts[saved.chapter].utf16.count
    return TextPlace(chapter: saved.chapter, offset: min(max(saved.offset, 0), length))
}

/// ReaderViewModel+Navigation.swift:934-944 `clampedNavigationPosition`, line
/// for line: where a jump to a bookmark lands today.
func clampedNavigation(_ chapterIndex: Int, _ characterOffset: Int, in texts: [String]) -> TextPlace {
    guard !texts.isEmpty else { return TextPlace(chapter: 0, offset: 0) }
    let chapter = min(max(0, chapterIndex), texts.count - 1)
    let length = texts[chapter].utf16.count
    return TextPlace(chapter: chapter, offset: min(max(0, characterOffset), max(0, length - 1)))
}

/// Book.swift:758-762 `restsAtEnd` and 737-743 `percentComplete`, with the
/// book's total the new text's length (what the rebuild measures).
func restsAtEnd(_ p: ReadingPosition, total: Int) -> Bool {
    total > 0 && (p.globalCharacterOffset ?? p.characterOffset) >= total
}
func percent(_ p: ReadingPosition, total: Int) -> String {
    let g = min(max(p.globalCharacterOffset ?? p.characterOffset, 0), total)
    return String(format: "%.1f%%", Double(g) / Double(total) * 100)
}

func show(_ label: String, _ relocator: PlaceRelocator, position: ReadingPosition, openIn: [String]) {
    let saved = TextPlace(chapter: position.chapterIndex, offset: position.characterOffset)
    let outcome = relocator.relocate(PlaceRelocator.Places(position: position))
    let moved = outcome.places.position!
    let total = relocator.new.totalLength
    print("[\(label)]")
    print("  saved (anchor nil) at \(saved), global \(position.globalCharacterOffset.map(String.init) ?? "nil") of old total \(relocator.old.totalLength) (\(percent(position, total: relocator.old.totalLength)))")
    print("  relocator -> \(TextPlace(chapter: moved.chapterIndex, offset: moved.characterOffset)) finding \(outcome.positionFinding!); new.endPlace \(relocator.new.endPlace)")
    print("  stored global \(moved.globalCharacterOffset.map(String.init) ?? "nil") / new total \(total); anchor.marksEndOfBook \(moved.anchor?.marksEndOfBook ?? false)")
    print("  Book.restsAtEnd -> \(restsAtEnd(moved, total: total)) (Finished), percentComplete \(percent(moved, total: total))")
    print("  reader's openingPlace for the same saved place, in the old text: \(openingPlace(of: saved, savedGlobalOffset: position.globalCharacterOffset, in: openIn))")
}

// MARK: - What savedWords reads for such a place (PlaceRelocator.swift:275)

do {
    let r = PlaceRelocator(oldTexts: old, newTexts: old)
    // heldInOldText((5, 140)) is old.endPlace (line 296); the anchor read there:
    let read = TextAnchor(capturingAt: r.old.endPlace, in: r.old, measuredIn: nil)!
    print("[read at old.endPlace \(r.old.endPlace)] after.isEmpty \(read.after.isEmpty), fraction \(read.fraction), marksEndOfBook \(read.marksEndOfBook)")
}

// MARK: - S1: the main trigger (one word edited in chapter II; place mid-book)

let edited = [kettle, sewing.replacingOccurrences(of: "forty years", with: "fifty years"), radio, closing]
let total = old.reduce(0) { $0 + $1.utf16.count }
let midBook = total * 55 / 100
show("S1 one-word edit, place in chapter 5 of an older 6-chapter reading, 55% in",
     PlaceRelocator(oldTexts: old, newTexts: edited),
     position: ReadingPosition(chapterIndex: 5, characterOffset: 140, globalCharacterOffset: midBook),
     openIn: old)

// MARK: - S2: a rebuild that changes no text at all

show("S2 new text identical to the old",
     PlaceRelocator(oldTexts: old, newTexts: old),
     position: ReadingPosition(chapterIndex: 5, characterOffset: 140, globalCharacterOffset: midBook),
     openIn: old)

// MARK: - S3: the rebuild restores the chapter split the place was saved in

// The place was saved in a 6-chapter reading (chapters III and IV split at
// their paragraph breaks); this build's reading of the old content.md has 4;
// the rebuild splits them again. (4, 30) is "...packed" in "CHAPTER IV. Closing
// Time" in both the saved reading and the new text: its own words are there.
let split = [kettle, sewing, radioA, radioB, closingA, closingB]
let savedAt = TextPlace(chapter: 4, offset: 30)
let globalInSplit = split[0..<4].reduce(0) { $0 + $1.utf16.count } + 30
print("  (S3: the words at (4, 30) in the saved reading and the new text: \"\((split[4] as NSString).substring(with: NSRange(location: 30, length: 30)))\")")
show("S3 rebuild restores the 6-chapter split; numbers point at the same words",
     PlaceRelocator(oldTexts: old, newTexts: split),
     position: ReadingPosition(chapterIndex: savedAt.chapter, characterOffset: savedAt.offset, globalCharacterOffset: globalInSplit),
     openIn: old)

// MARK: - S4: a bookmark saved without an anchor in a chapter the old text lacks

do {
    let r = PlaceRelocator(oldTexts: old, newTexts: edited)
    let outcome = r.relocate(PlaceRelocator.Places(bookmarks: [Bookmark(number: 1, chapterIndex: 4, characterOffset: 60, label: "the capacitor")]))
    let b = outcome.places.bookmarks[0]
    print("[S4 bookmark (4, 60), anchor nil]")
    print("  relocator -> \(TextPlace(chapter: b.chapterIndex, offset: b.characterOffset)) finding \(outcome.bookmarkFindings[0]); new.endPlace \(r.new.endPlace); anchor marks end \(b.anchor?.marksEndOfBook ?? false)")
    print("  a jump to it today (clampedNavigationPosition in the old text): \(clampedNavigation(4, 60, in: old))")
}

// MARK: - S5 (control): the same place, but its global offset WAS at the end

show("S5 control: same place, saved global offset at/after the end (a finished book)",
     PlaceRelocator(oldTexts: old, newTexts: edited),
     position: ReadingPosition(chapterIndex: 5, characterOffset: 140, globalCharacterOffset: total + 400),
     openIn: old)

// MARK: - S6 (control): an anchorless place in a chapter the old text HAS

do {
    let r = PlaceRelocator(oldTexts: old, newTexts: edited)
    let at = TextPlace(chapter: 2, offset: (radio as NSString).range(of: "Wendel").location)
    let result = r.relocate(nil, savedAt: at)
    let word = (r.new.texts[result.place.chapter] as NSString).substring(with: NSRange(location: result.place.offset, length: 6))
    print("[S6 control: anchorless at \(at) (\"Wendel\")] -> \(result.place) \(result.finding), word there \"\(word)\"")
}
