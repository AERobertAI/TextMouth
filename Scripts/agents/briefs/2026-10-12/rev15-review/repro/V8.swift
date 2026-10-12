import Foundation

// V8 verifier probe: carry's chapter-end rule (PlaceRelocator.swift 442-456).
//
// A place at the end of chapter I ("nothing after it in its chapter") is
// relocated into a new text where chapter II, missing from the old text,
// is restored right after chapter I. The code comment promises "a chapter
// restored after it does not take it": the place should stay at the end of
// chapter I, so the listener goes on into the restored chapter II.
//
// Each scenario prints the relocator's answer next to TextAnchorFinder's
// answer alone (the saved-words search the app runs today), plus the text
// just before and after each landing so the chapter is plain to read.

// MARK: - The book (original text, several sentences a chapter)

/// Chapter I, ending "...gave up and went home."
let ferry = "CHAPTER I. The Ferry\n\n"
    + "The ferry left the north landing at six, whether or not anyone was aboard. Odile kept the tide tables in a biscuit tin and argued with them every morning, as though the moon could be talked round.\n\n"
    + "On the first crossing of the season the engine coughed twice, and the passengers pretended not to notice. A dog in a red harness stood at the bow the whole way and barked at the gulls until they gave up and went home."

/// Chapter II, the chapter the old reading lost and the new one restores.
/// Its last words never include "home".
let island = "CHAPTER II. The Island\n\n"
    + "The island had one shop, one church, and a post box that was emptied on Thursdays if the boat came. Fenwick ran the shop and sold paraffin, stamps, and tinned peaches at prices nobody questioned.\n\n"
    + "In winter the crossings stopped altogether, and the islanders lived on what they had laid by: salt cod, potatoes, and a great deal of gossip, which kept longer than either."

/// Chapter III, after the restored chapter.
let crossing = "CHAPTER III. The Crossing Back\n\n"
    + "By March the channel buoys had dragged their moorings and the harbour master spent a week re-laying them from a rowing boat. Odile went out with him on the last day and came back soaked to the knees.\n\n"
    + "The first sailing of spring carried a piano, two goats, and a schoolteacher who had answered an advertisement without looking at a map."

/// A short preface a new reading can restore before chapter I.
let preface = "Preface\n\nThese pages were written up from the log the ferry kept for forty years, with the spelling mended and the weather left alone."

// MARK: - Helpers

/// `place` with the text just around it, and its chapter's length.
func show(_ place: TextPlace, in texts: [String]) -> String {
    guard place.chapter >= 0, place.chapter < texts.count else { return "(\(place.chapter), \(place.offset)) <no such chapter>" }
    let text = texts[place.chapter] as NSString
    let offset = min(max(place.offset, 0), text.length)
    let lead = text.substring(with: NSRange(location: max(0, offset - 28), length: offset - max(0, offset - 28)))
    let tail = text.substring(with: NSRange(location: offset, length: min(18, text.length - offset)))
    let firstLine = (texts[place.chapter].components(separatedBy: "\n").first ?? "")
    let atEnd = offset == text.length ? "  <= END of this chapter" : ""
    return "(\(place.chapter), \(place.offset)) in \"\(firstLine)\" [len \(text.length)]  ...\(lead.replacingOccurrences(of: "\n", with: "/"))|\(tail.replacingOccurrences(of: "\n", with: "/"))\(atEnd)"
}

/// Runs one scenario: a place at `saved` in `old` relocated to `new`.
func scenario(_ title: String, old: [String], new: [String], saved: TextPlace, expect: String) {
    print("=== \(title)")
    let oldWords = BookWords(texts: old)
    guard let anchor = TextAnchor(capturingAt: saved, in: oldWords) else { print("no anchor"); return }
    print("  saved (old):   \(show(saved, in: old))")
    print("  anchor:        before=\"…\(anchor.before.suffix(40).replacingOccurrences(of: "\n", with: "/"))\" after=\"\(anchor.after.prefix(20))\" fraction=\(String(format: "%.3f", anchor.fraction))")
    let relocator = PlaceRelocator(oldTexts: old, newTexts: new)
    let moved = relocator.relocate(anchor, savedAt: saved)
    print("  relocator:     \(show(moved.place, in: new))")
    print("                 finding = \(moved.finding)")
    let alone = TextAnchorFinder(texts: new).find(anchor, savedAt: saved, savedChapterLength: oldWords.length(ofChapter: saved.chapter))
    print("  finder alone:  \(show(alone.place, in: new))")
    print("                 finding = \(alone.finding)")
    // The same place as a reading position, through the book-level API a
    // rebuild will call (branch D), to show what would be saved.
    var position = ReadingPosition(chapterIndex: saved.chapter, characterOffset: saved.offset, globalCharacterOffset: oldWords.globalOffset(of: saved), anchor: anchor)
    position.lastUpdated = Date(timeIntervalSince1970: 0)
    let outcome = relocator.relocate(PlaceRelocator.Places(position: position))
    if let p = outcome.places.position {
        print("  saved position after the rebuild: chapter \(p.chapterIndex), offset \(p.characterOffset), global \(p.globalCharacterOffset ?? -1) of \(relocator.new.totalLength)")
    }
    print("  expected:      \(expect)")
    print("")
}

// MARK: - Scenarios

let endOfFerry = TextPlace(chapter: 0, offset: ferry.utf16.count)

// Control: an EARLIER word of chapter I edited (so the direct check fails),
// its last word untouched; chapter II restored after it. The special case
// applies and the place stays at the end of chapter I, as documented.
let ferryEarlyEdit = ferry.replacingOccurrences(of: "at six, whether", with: "at half past six, whether")
scenario("CONTROL: early word edited, last word kept, chapter II restored",
         old: [ferry, crossing], new: [ferryEarlyEdit, island, crossing], saved: endOfFerry,
         expect: "end of chapter I (0, \(ferryEarlyEdit.utf16.count))")

// Trigger (a1): chapter I's LAST word edited ("home" -> "away"), chapter II
// restored after it.
let ferryLastEdit = ferry.replacingOccurrences(of: "went home.", with: "went away.")
scenario("(a1) last word edited home->away, chapter II restored",
         old: [ferry, crossing], new: [ferryLastEdit, island, crossing], saved: endOfFerry,
         expect: "end of chapter I (0, \(ferryLastEdit.utf16.count))")

// Trigger (a2): the old reading kept a footnote reference after the last
// sentence ("home.12"); the new reading drops it and restores chapter II.
let ferryWithNote = ferry + "12"
scenario("(a2) old reading's trailing footnote number dropped, chapter II restored",
         old: [ferryWithNote, crossing], new: [ferry, island, crossing], saved: TextPlace(chapter: 0, offset: ferryWithNote.utf16.count),
         expect: "end of chapter I (0, \(ferry.utf16.count))")

// Trigger (b1): chapter I's last word unedited (an early edit only, so the
// direct check fails), and the restored chapter II also ends with "home":
// the keeping rule's late match pairs chapter I's last word with it.
let islandHome = island.replacingOccurrences(of: "which kept longer than either.", with: "and waited for the boats to come home.")
scenario("(b1) last word kept; restored chapter II also ends with 'home'",
         old: [ferry, crossing], new: [ferryEarlyEdit, islandHome, crossing], saved: endOfFerry,
         expect: "end of chapter I (0, \(ferryEarlyEdit.utf16.count))")

// Trigger (b2): as (b1), but "home" is three words before chapter II's end:
// the place lands inside chapter II's last sentence.
let islandHomeAtLast = island.replacingOccurrences(of: "which kept longer than either.", with: "and waited for the boats to come home at last.")
scenario("(b2) restored chapter II ends 'come home at last.'",
         old: [ferry, crossing], new: [ferryEarlyEdit, islandHomeAtLast, crossing], saved: endOfFerry,
         expect: "end of chapter I (0, \(ferryEarlyEdit.utf16.count))")

// Trigger (b3): chapter I itself wholly unchanged; the new reading restores
// a preface before it (indices shift, so the direct check fails) and
// chapter II after it, which ends with "home".
scenario("(b3) chapter I unchanged; preface and chapter II (ending 'home') restored",
         old: [ferry, crossing], new: [preface, ferry, islandHome, crossing], saved: endOfFerry,
         expect: "end of chapter I, now chapter 1: (1, \(ferry.utf16.count))")

// Trigger (b4): the patience diff's common suffix. Chapter I's tail edited
// before its last two words, and the restored chapter II ends "...walked
// home.": the common suffix pairs chapter I's "home" with chapter II's.
let ferryTailEdit = ferry.replacingOccurrences(of: "until they gave up and went home.", with: "until they tired and went home.")
let islandWalkedHome = island.replacingOccurrences(of: "which kept longer than either.", with: "and the last of the islanders walked home.")
scenario("(b4) diff's common suffix: chapter I tail edited, chapter II ends 'walked home.'",
         old: [ferry, crossing], new: [ferryTailEdit, islandWalkedHome, crossing], saved: endOfFerry,
         expect: "end of chapter I (0, \(ferryTailEdit.utf16.count))")

// MARK: - Mechanism: what the diff itself pairs chapter I's last word with

/// Prints the new chapter the patience diff lines chapter I's last word
/// ("home") up with: its own chapter means the keeping rule's late match
/// moved the place (b1), the restored chapter means the diff did (b4).
func lastWordPartner(_ title: String, old: [String], new: [String]) {
    let oldWords = BookWords(texts: old)
    let newWords = BookWords(texts: new)
    let partners = PatienceDiff.partners(of: oldWords.keys, in: newWords.keys)
    let last = oldWords.chapterFirstWords[1] - 1
    let next = last + 1
    let partner = partners[last]
    let where_ = partner >= 0 ? "new word \(partner), chapter \(newWords.chapter(ofWord: partner)) (\(newWords.texts[newWords.chapter(ofWord: partner)].components(separatedBy: "\n").first ?? ""))" : "none"
    print("PARTNER \(title): chapter I's last word -> \(where_); the next old word (chapter III's first) -> new word \(partners[next]), chapter \(newWords.chapter(ofWord: partners[next]))")
}
lastWordPartner("(b1)", old: [ferry, crossing], new: [ferryEarlyEdit, islandHome, crossing])
lastWordPartner("(b4)", old: [ferry, crossing], new: [ferryTailEdit, islandWalkedHome, crossing])
lastWordPartner("(a1)", old: [ferry, crossing], new: [ferryLastEdit, island, crossing])
lastWordPartner("(b2)", old: [ferry, crossing], new: [ferryEarlyEdit, islandHomeAtLast, crossing])

// Trigger (b5): the keeping rule's late match alone. A later edit in
// chapter III stops the diff's common suffix short of chapter I, so the
// diff pairs chapter I's "home" with its own; the restored chapter II
// ends with "home" too.
let crossingEdited = crossing.replacingOccurrences(of: "without looking at a map.", with: "without once looking at a map.")
lastWordPartner("(b5)", old: [ferry, crossing], new: [ferryEarlyEdit, islandHome, crossingEdited])
scenario("(b5) keeping rule only: later edit in chapter III; chapter II ends 'come home.'",
         old: [ferry, crossing], new: [ferryEarlyEdit, islandHome, crossingEdited], saved: endOfFerry,
         expect: "end of chapter I (0, \(ferryEarlyEdit.utf16.count))")
