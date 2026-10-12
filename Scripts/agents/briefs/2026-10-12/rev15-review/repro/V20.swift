import Foundation

// V20 probe: PlaceRelocator.carry computes a place's in-word offset once
// (`inside`, PlaceRelocator.swift:460-462) and its `landing` closure (463)
// applies it to EVERY target, not only the place's own lined-up word. The
// guard in BookWords.landing (FineWords.swift:340) is only "same key", so a
// place inside a removed "the" lands inside whatever "The" begins the text
// after the removal. The documented rule (FineWords.swift:330-333, and the
// shared-rule test "another word: its start") is that the offset is kept only
// when the word landed before is that same word.

// MARK: - Helpers

/// UTF-16 offset of the first occurrence of `needle` in `text`, at or after `from`.
func offset(of needle: String, in text: String, from: Int = 0) -> Int {
    let ns = text as NSString
    let range = ns.range(of: needle, options: .literal, range: NSRange(location: from, length: ns.length - from))
    precondition(range.location != NSNotFound, "missing \(needle)")
    return range.location
}

/// The text around `place`, with a bar where the place stands.
func show(_ place: TextPlace, in texts: [String]) -> String {
    let ns = texts[place.chapter] as NSString
    let low = max(0, place.offset - 18)
    let high = min(ns.length, place.offset + 18)
    let left = ns.substring(with: NSRange(location: low, length: place.offset - low))
    let right = ns.substring(with: NSRange(location: place.offset, length: high - place.offset))
    return "\"\(left)|\(right)\"".replacingOccurrences(of: "\n", with: "\\n")
}

/// Relocates a place saved at `saved` in `old` (with an anchor captured there,
/// as the app saves one) into `new`, and prints the result beside the place
/// the documented rule gives (`expected`). Also prints what the saved-words
/// search alone (TextAnchorFinder.find over the new text) does.
func run(_ title: String, old: [String], new: [String], saved: TextPlace, expected: TextPlace) {
    let relocator = PlaceRelocator(oldTexts: old, newTexts: new)
    let anchor = TextAnchor(capturingAt: saved, in: relocator.old)!
    let result = relocator.relocate(anchor, savedAt: saved)
    let withoutAnchor = relocator.relocate(nil, savedAt: saved)
    let finderAlone = TextAnchorFinder(words: relocator.new).find(anchor, savedAt: saved)
    print("== \(title)")
    print("   saved    \(saved)  \(show(saved, in: old))")
    print("   result   \(result.place)  \(show(result.place, in: new))  \(result.finding)")
    print("   no anchor\(withoutAnchor.place)  \(show(withoutAnchor.place, in: new))  \(withoutAnchor.finding)")
    print("   expected \(expected)  \(show(expected, in: new))   (start of the word landed before)")
    print("   finder   \(finderAlone.place)  \(show(finderAlone.place, in: new))  \(finderAlone.finding)")
    print("   mid-word landing in a word that is not the place's own: \(result.place != expected ? "YES (bug)" : "no")")
}

// MARK: - The Book

let heading1 = "CHAPTER I. The Crossing\n\n"
let p1 = "The ferry left the north landing at seven, carrying two carts of turnips, a crate of hens, and the vicar's bicycle, which nobody had asked to bring along. "
let p2 = "Halfway across, the engine coughed twice, and the pilot swore at it in three languages before the current took the bow and swung the whole boat slowly toward the weir. "
let p3 = "The passengers kept their seats while the deckhand rowed a line to the willow on the far bank and made it fast with a knot his grandfather had taught him. "
let p4 = "By noon the turnips were in the market at Upper Swaile, and the hens were somebody else's worry."
let chapter2 = "CHAPTER II. Market Day\n\nThe stalls opened late because the mayor's dog had eaten the ribbon meant for the ceremony, and nobody would cut a plain string in front of the newspaper."

// MARK: - Case A: a paragraph removed mid-chapter (sure .passageRemoved)

do {
    let old = [heading1 + p1 + p2 + p3 + p4, chapter2]
    let new = [heading1 + p1 + p3 + p4, chapter2]
    // 2 units into the "the" of "before the current", deep in the removed paragraph.
    let theWord = offset(of: "before the current", in: old[0]) + "before ".utf16.count
    let saved = TextPlace(chapter: 0, offset: theWord + 2)
    // The documented landing: where the text after the removal begins, at the start of "The passengers".
    let expected = TextPlace(chapter: 0, offset: offset(of: "The passengers", in: new[0]))
    run("A: removed paragraph; the text after it begins with \"The\"", old: old, new: new, saved: saved, expected: expected)
}

// MARK: - Control A': the same, but the text after the removal begins with another word

do {
    let p3b = p3.replacingOccurrences(of: "The passengers", with: "Passengers")
    let old = [heading1 + p1 + p2 + p3b + p4, chapter2]
    let new = [heading1 + p1 + p3b + p4, chapter2]
    let theWord = offset(of: "before the current", in: old[0]) + "before ".utf16.count
    let saved = TextPlace(chapter: 0, offset: theWord + 2)
    let expected = TextPlace(chapter: 0, offset: offset(of: "Passengers", in: new[0]))
    run("A' (control): removed paragraph; the text after it begins with \"Passengers\"", old: old, new: new, saved: saved, expected: expected)
}

// MARK: - Case B: a foreword removed at the book's start (unsure answer, .guessed(.diffUnsure))

do {
    let foreword = "A NOTE ON THIS EDITION\n\nThis printing follows the parish copy, which the printer set from a damp manuscript, so a few of the place names are guesses and the ferry timetable has been left out altogether."
    let crossing = "The Crossing\n\n" + p1 + p3 + p4
    let old = [foreword, crossing, chapter2]
    let new = [crossing, chapter2]
    // 2 units into the "the" of "and the ferry timetable", deep in the removed foreword.
    let theWord = offset(of: "and the ferry timetable", in: old[0]) + "and ".utf16.count
    let saved = TextPlace(chapter: 0, offset: theWord + 2)
    let expected = TextPlace(chapter: 0, offset: 0)
    run("B: foreword removed at the book's start; the text after it begins with \"The\"", old: old, new: new, saved: saved, expected: expected)
}

// MARK: - Case C: a paragraph replaced by a longer, different one beginning with "The" (sure, not like for like)

do {
    let replacement = "The crossing itself was uneventful. A heron rode the rail as far as the middle of the river and then thought better of it, "
        + "the deckhand sang something about a drowned fiddler, the hens complained in a steady chorus, the pilot counted the buoys aloud, "
        + "a boy from the far bank waved a cap at nobody in particular, and the vicar read his newspaper upside down for twenty minutes without noticing, "
        + "while the turnips, stacked in their two carts, said nothing at all and smelled of the cellar they had wintered in. "
    let old = [heading1 + p1 + p2 + p3 + p4, chapter2]
    let new = [heading1 + p1 + replacement + p3 + p4, chapter2]
    let theWord = offset(of: "before the current", in: old[0]) + "before ".utf16.count
    let saved = TextPlace(chapter: 0, offset: theWord + 2)
    let expected = TextPlace(chapter: 0, offset: offset(of: "The crossing itself", in: new[0]))
    run("C: paragraph replaced by a longer one beginning with \"The\"", old: old, new: new, saved: saved, expected: expected)
}

// MARK: - Case D (intended behavior, for contrast): the place's own word lined up

do {
    let old = [heading1 + p1 + p2 + p3 + p4, chapter2]
    let new = [heading1 + p1.replacingOccurrences(of: "at seven", with: "at a quarter past seven") + p2 + p3 + p4, chapter2]
    let theWord = offset(of: "before the current", in: old[0]) + "before ".utf16.count
    let saved = TextPlace(chapter: 0, offset: theWord + 2)
    let newThe = offset(of: "before the current", in: new[0]) + "before ".utf16.count
    let expected = TextPlace(chapter: 0, offset: newThe + 2)   // its own word: keeps 2 units into it
    run("D (intended): text added before; the place's own \"the\" lines up", old: old, new: new, saved: saved, expected: expected)
}
