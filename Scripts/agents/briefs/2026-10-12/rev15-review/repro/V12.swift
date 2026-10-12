import Foundation

// V12 verifier probe (scratch, not part of the app).
//
// Claim: a place in a chapter whose text has no fine words ("* * *", or "[]"
// as pre-3.0.5 caches wrote an image page) gets nothingAfter = true in
// PlaceRelocator.carry (line 444); the chapter-end rule's guard fails because
// the word before it lies in an EARLIER chapter (line 453); so the place is
// carried by the NEXT chapter's first word and landed with nothingAfter
// (lines 463-467): at the END of the PREVIOUS chapter, as a certain
// .movedByTheDiff(.linedUp).
//
// Every scenario below makes sure rule 1 (the new finder's `settled`) does
// NOT settle the place, by checking it directly, so the diff must decide.

// MARK: - The Book (realistic, multi-sentence chapters)

let ferry = """
CHAPTER I. The Ferry

The ferryman kept a ledger of every crossing, and in the dry months he wrote down the depth of the river at noon. His daughter read the figures aloud each evening while the lamp smoked, and the drovers argued over the fares.
"""

let toll = """
CHAPTER II. The Toll

When the county raised the toll to fourpence, the drovers took their cattle upstream to the shallows instead. The ledger shows forty empty days that spring, and a note in the margin about a lame horse.
"""

let bridge = """
CHAPTER III. The Bridge

A stone bridge was finished in the autumn of the next year, and the ferry was sold to a timber merchant from the coast for eleven pounds.
"""

let preface = """
PREFACE

This edition restores the ferryman's ledger, which turned up in a chest at the county archive, and adds notes on each crossing he recorded.
"""

/// A chapter a newer extraction restores (as T06's "restored chapter" cases).
let interlude = """
INTERLUDE. A Winter Crossing

In January the river froze from bank to bank, and for nine days people walked across without paying anything. The ledger is blank for that week except for one word, written twice: ice.
"""

// MARK: - Helpers

/// A short name for chapter `index` of `texts`: its first line, quoted.
func chapterName(_ index: Int, _ texts: [String]) -> String {
    guard index >= 0, index < texts.count else { return "<no chapter>" }
    let first = texts[index].split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
    return "ch\(index) \(first.debugDescription)"
}

/// `place` described: its numbers, its chapter's name, whether it is that
/// chapter's end, and its offset in the whole book.
func describe(_ place: TextPlace, in words: BookWords) -> String {
    let length = words.length(ofChapter: place.chapter)
    let edge = place.offset == length ? " (END of that chapter)" : (place.offset == 0 ? " (start of that chapter)" : "")
    return "(\(place.chapter),\(place.offset)) in \(chapterName(place.chapter, words.texts))\(edge), global \(words.globalOffset(of: place))"
}

/// Runs one scenario: captures the anchor at `saved` in `old`, proves rule 1
/// does not settle it in `new`, then prints the relocator's answer, the
/// finder's answer alone, and the expected place.
func scenario(_ title: String, old: [String], new: [String], saved: TextPlace, expected: TextPlace) {
    print("=== \(title)")
    let relocator = PlaceRelocator(oldTexts: old, newTexts: new)
    guard let anchor = TextAnchor(capturingAt: saved, in: relocator.old) else {
        print("  no anchor"); return
    }
    print("  saved   : \(describe(saved, in: relocator.old))  [old text]")
    print("  anchor  : before \(String(anchor.before.suffix(16)).debugDescription), after \(String(anchor.after.prefix(16)).debugDescription), fine words in quotes: \(FineWords.keys(in: anchor.before + anchor.after).count)")
    let newFinder = TextAnchorFinder(texts: new)
    let rule1 = newFinder.settled(anchor, savedAt: saved)
    print("  rule 1  : settled = \(rule1.map { "\($0)" } ?? "nil (does not settle it)")")
    let result = relocator.relocate(anchor, savedAt: saved)
    print("  RELOC   : \(describe(result.place, in: relocator.new))  finding \(result.finding)")
    let alone = newFinder.find(anchor, savedAt: saved, savedChapterLength: relocator.old.length(ofChapter: saved.chapter))
    print("  finder  : \(describe(alone.place, in: relocator.new))  finding \(alone.finding)")
    print("  expected: \(describe(expected, in: relocator.new))")
    let verdict = result.place == expected ? "matches expected" : "WRONG: chapter \(result.place.chapter) instead of \(expected.chapter), global off by \(relocator.new.globalOffset(of: result.place) - relocator.new.globalOffset(of: expected))"
    print("  -> \(verdict)\n")
}

// MARK: - Scenarios

// S1 (the brief's trigger): a "* * *" scene-break chapter; the new text
// inserts a preface before everything, so the ornament is now chapter 2.
scenario("S1a '* * *' chapter, preface inserted before; place at its start",
         old: [ferry, "* * *", toll, bridge], new: [preface, ferry, "* * *", toll, bridge],
         saved: TextPlace(chapter: 1, offset: 0), expected: TextPlace(chapter: 2, offset: 0))
scenario("S1b same, place 2 units in (a bookmark nudged clear of another)",
         old: [ferry, "* * *", toll, bridge], new: [preface, ferry, "* * *", toll, bridge],
         saved: TextPlace(chapter: 1, offset: 2), expected: TextPlace(chapter: 2, offset: 2))

// S2: the ornament itself changed (no chapter moved): the chapter index is
// the same, yet the place leaves its chapter.
scenario("S2 '* * *' became '⁂', nothing else changed",
         old: [ferry, "* * *", toll, bridge], new: [ferry, "⁂", toll, bridge],
         saved: TextPlace(chapter: 1, offset: 0), expected: TextPlace(chapter: 1, offset: 0))

// S3: an image page as a pre-3.0.5 cache wrote it ("[]"), rebuilt by a
// 3.0.5+ cache, whose named anchors add no "[]" (MarkdownCacheService:16-18).
scenario("S3 image page '[]' became '' (pre-3.0.5 cache rebuilt)",
         old: [ferry, "[]", toll, bridge], new: [ferry, "", toll, bridge],
         saved: TextPlace(chapter: 1, offset: 0), expected: TextPlace(chapter: 1, offset: 0))

// S4: the same rebuild also restores a chapter right after the image page.
// The carry comment promises "a chapter restored after it does not take it".
scenario("S4 '[]' became '' AND a chapter restored right after it",
         old: [ferry, "[]", toll, bridge], new: [ferry, "", interlude, toll, bridge],
         saved: TextPlace(chapter: 1, offset: 0), expected: TextPlace(chapter: 1, offset: 0))
scenario("S4b '* * *' became '⁂' AND a chapter restored right after it",
         old: [ferry, "* * *", toll, bridge], new: [ferry, "⁂", interlude, toll, bridge],
         saved: TextPlace(chapter: 1, offset: 0), expected: TextPlace(chapter: 1, offset: 0))

// S5: a wordless cover as chapter 0.
scenario("S5 cover '[]' (chapter 0) became ''",
         old: ["[]", ferry, toll], new: ["", ferry, toll],
         saved: TextPlace(chapter: 0, offset: 0), expected: TextPlace(chapter: 0, offset: 0))

// MARK: - Controls

// C1: a place at the end of a chapter WITH words (the documented chapter-end
// rule): a word inside its 64-unit quote edited so rule 1 fails, its last
// seven words left as they were (so its last word is a solid match), and a
// chapter restored after it. It stays at the end of its OWN chapter.
// (A first version edited "argued", leaving only "over the fares" lined up,
// under the 4-word solid run: that reproduced V8(a) instead.)
let ferryEdited = ferry.replacingOccurrences(of: "the lamp smoked", with: "the lamp guttered")
scenario("C1 control: end of ch0 (has words), a word in its quote edited, chapter restored after",
         old: [ferry, toll, bridge], new: [ferryEdited, interlude, toll, bridge],
         saved: TextPlace(chapter: 0, offset: ferry.utf16.count), expected: TextPlace(chapter: 0, offset: ferryEdited.utf16.count))

// C2: a place at the start of a chapter WITH words, preface inserted.
scenario("C2 control: start of ch1 (has words), preface inserted",
         old: [ferry, toll, bridge], new: [preface, ferry, toll, bridge],
         saved: TextPlace(chapter: 1, offset: 0), expected: TextPlace(chapter: 2, offset: 0))

// MARK: - What the Book Saves

// The book-level API (branch D's caller): a bookmark and the reading
// position on the image page of S4; what gets written back.
do {
    print("=== BOOK: bookmark + position on the '[]' image page, rebuilt as in S4")
    let old = [ferry, "[]", toll, bridge]
    let new = [ferry, "", interlude, toll, bridge]
    let relocator = PlaceRelocator(oldTexts: old, newTexts: new)
    let page = TextPlace(chapter: 1, offset: 0)
    let anchor = TextAnchor(capturingAt: page, in: relocator.old)
    let bookmark = Bookmark(number: 1, chapterIndex: 1, characterOffset: 0, label: "the map of the crossing", anchor: anchor)
    let position = ReadingPosition(chapterIndex: 1, characterOffset: 0, globalCharacterOffset: relocator.old.globalOffset(of: page), anchor: anchor)
    let outcome = relocator.relocate(PlaceRelocator.Places(position: position, bookmarks: [bookmark]))
    let movedMark = outcome.places.bookmarks[0]
    let movedPos = outcome.places.position!
    print("  bookmark -> chapterIndex \(movedMark.chapterIndex), offset \(movedMark.characterOffset) = \(describe(TextPlace(chapter: movedMark.chapterIndex, offset: movedMark.characterOffset), in: relocator.new))")
    print("             finding \(outcome.bookmarkFindings[0]); new anchor before \(String(movedMark.anchor!.before.suffix(24)).debugDescription), after \(movedMark.anchor!.after.debugDescription)")
    print("  position -> chapterIndex \(movedPos.chapterIndex), offset \(movedPos.characterOffset), global \(movedPos.globalCharacterOffset!) (old global \(position.globalCharacterOffset!)); finding \(outcome.positionFinding!)")
    print("  counts   : \(outcome.counts.logLine(title: "Ferry Ledger"))")
    print("  interlude spans global \(relocator.new.chapterStarts[2])..<\(relocator.new.chapterStarts[3]); a reader resuming at the position starts after it")
}
