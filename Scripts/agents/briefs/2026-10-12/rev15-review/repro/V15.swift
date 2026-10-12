import Foundation

// V15 verifier probe (independent of the finder's angleE/p3).
//
// Question: does PlaceRelocator.keepingTheWordsAfter (PlaceRelocator.swift
// 607-623), whose window is `max(0, end - count - keepingSlack - count / 4)`
// with no lower bound at the partner of the solid match before the place,
// send a place in a REMOVED copy of a repeated phrase BACK across a solid run
// of kept text onto an earlier copy the diff kept?
//
// The documented answer for a removal (type doc, "Words gone"; addendum
// section 1, "A removed stretch") is where the text after the removal begins,
// slid back only over words the removal ends with that also end the text
// before it. None of these removals can slide, so that is the expected place.

// MARK: - Helpers

/// The UTF-16 offset of the `occurrence`-th (0-based) copy of `needle` in `text`.
func offset(of needle: String, in text: String, occurrence: Int = 0) -> Int {
    let ns = text as NSString
    var from = 0
    var found = NSNotFound
    for _ in 0...occurrence {
        let range = ns.range(of: needle, options: .literal, range: NSRange(location: from, length: ns.length - from))
        precondition(range.location != NSNotFound, "no copy \(occurrence) of \(needle)")
        found = range.location
        from = range.location + range.length
    }
    return found
}

/// A short excerpt of `texts` starting at `place`, with newlines shown as "/".
func excerpt(_ place: TextPlace, in texts: [String], length: Int = 24) -> String {
    let ns = texts[place.chapter] as NSString
    let end = min(ns.length, place.offset + length)
    return ns.substring(with: NSRange(location: place.offset, length: end - place.offset))
        .replacingOccurrences(of: "\n", with: "/")
}

/// The module prefix Swift puts on printed type names ("v15."), stripped for brevity.
let modulePrefix = String(reflecting: PlaceRelocator.self).replacingOccurrences(of: "PlaceRelocator", with: "")

/// A finding without its module and type prefixes.
func describe(_ finding: PlaceRelocator.Finding?) -> String {
    guard let finding else { return "nil" }
    return "\(finding)"
        .replacingOccurrences(of: modulePrefix + "PlaceRelocator.", with: "")
        .replacingOccurrences(of: "Finding.", with: "")
        .replacingOccurrences(of: "DiffEvidence.", with: "")
}

/// The diff's pairing of old words `range` (each "word:old->new", "-" when unpaired).
func alignment(_ relocator: PlaceRelocator, oldWords range: ClosedRange<Int>) -> String {
    let partners = PatienceDiff.partners(of: relocator.old.keys, in: relocator.new.keys)
    let old = relocator.old
    return range.map { w in
        let text = (old.texts[old.chapter(ofWord: w)] as NSString)
            .substring(with: NSRange(location: old.starts[w], length: old.ends[w] - old.starts[w]))
        return "\(text):\(w)->\(partners[w] >= 0 ? String(partners[w]) : "-")"
    }.joined(separator: " ")
}

/// Relocates a place saved at `saved` (its anchor captured in the old text, as
/// every place saved since anchors has one) and prints it beside `expected`,
/// tagging a landing before the expected place "BACK".
@discardableResult
func check(_ label: String, _ relocator: PlaceRelocator, saved: TextPlace, expected: TextPlace) -> PlaceRelocator.Result {
    let anchor = TextAnchor(capturingAt: saved, in: relocator.old)!
    let result = relocator.relocate(anchor, savedAt: saved)
    let got = relocator.new.globalOffset(of: result.place)
    let want = relocator.new.globalOffset(of: expected)
    let tag = got == want ? "OK  " : (got < want ? "BACK" : "FWD ")
    print("  [\(tag)] \(label): old (\(saved.chapter),\(saved.offset)) <\(excerpt(saved, in: relocator.old.texts))>")
    print("         -> new (\(result.place.chapter),\(result.place.offset)) <\(excerpt(result.place, in: relocator.new.texts))> \(describe(result.finding))")
    print("         expected (\(expected.chapter),\(expected.offset)) <\(excerpt(expected, in: relocator.new.texts))>")
    return result
}

// MARK: - S1: a line of dialogue said twice, the second time removed

// "Nobody in the queue moved." (5 words) stays between the two copies; with a
// 4-word phrase the window reaches 4 + 4 + 1 = 9 new words back from the next
// solid match, which covers those 5 words and the kept copy.
let ferryLead = "The ferry from the island was forty minutes late, and the queue at the ticket hut had stretched past the chandler's door. The harbourmaster came out at last with a clipboard pressed to his chest. "
let twenty = "\"Twenty minutes,\" he said."
let ferryTail = "A woman with a crate of laying hens laughed out loud and sat down on the crate. The boy beside her unscrewed a flask of tea and offered it round."

/// One scenario of S1: `between` stands between the two copies, and the second copy is removed.
func ferry(between: String) {
    let old = [ferryLead + twenty + between + twenty + " " + ferryTail]
    let new = [ferryLead + twenty + between + ferryTail]
    let relocator = PlaceRelocator(oldTexts: old, newTexts: new)
    let removedCopy = offset(of: twenty, in: old[0], occurrence: 1)
    let expected = TextPlace(chapter: 0, offset: offset(of: "A woman", in: new[0]))
    let firstRemovedWord = relocator.old.word(at: TextPlace(chapter: 0, offset: removedCopy))
    print("  diff: \(alignment(relocator, oldWords: (firstRemovedWord - 10)...(firstRemovedWord + 6)))")
    // Every place in the removed copy: its opening quote and each of its words
    // (label, then the text that begins at the place within the copy).
    for (label, needle) in [("opening quote", "\"Twenty"), ("Twenty", "Twenty"), ("minutes", "minutes"), ("he", "he said"), ("said", "said")] {
        let at = removedCopy + (twenty as NSString).range(of: needle).location
        check("removed copy at <\(label)>", relocator, saved: TextPlace(chapter: 0, offset: at), expected: expected)
    }
}

print("S1  dialogue said twice, second copy removed, 5 kept words between the copies")
ferry(between: " Nobody in the queue moved. ")
print("S1c control: the same with 6 kept words between the copies (outside the window)")
ferry(between: " Nobody in the whole queue moved. ")

// MARK: - S2: a longer sentence read out twice, the second reading removed

// The removed passage is a lead-in and a 20-word quotation; "The wind took the
// last words away." (7 kept words) stands between the two quotations. The
// window for the quotation's first word reaches 20 + 4 + 5 = 29 words back.
let notice = "\"Walkers must keep to the marked path, because the bog beyond the stile does not give back what it takes.\""
let lane = "At the top of the lane the path forked, and a tin sign had been wired to the gate. She read the notice aloud: " + notice + " The wind took the last words away."
let secondReading = " She read it again, louder: " + notice
let climb = " Then she climbed the stile anyway and set off across the tussocks toward the cairn on the ridge."
do {
    print("S2  a sentence read out twice, the second reading (lead-in + quotation) removed, 7 kept words between")
    let old = [lane + secondReading + climb]
    let new = [lane + climb]
    let relocator = PlaceRelocator(oldTexts: old, newTexts: new)
    let leadIn = offset(of: "She read it again", in: old[0])
    let quote = offset(of: "Walkers", in: old[0], occurrence: 1)
    let expected = TextPlace(chapter: 0, offset: offset(of: " Then she climbed", in: new[0]) + 1)
    check("removed lead-in at <She>", relocator, saved: TextPlace(chapter: 0, offset: leadIn), expected: expected)
    check("removed quotation at <Walkers>", relocator, saved: TextPlace(chapter: 0, offset: quote), expected: expected)
    check("removed quotation at <bog>", relocator, saved: TextPlace(chapter: 0, offset: offset(of: "bog", in: old[0], occurrence: 1)), expected: expected)
    // The same two places as bookmarks, moved together as a rebuild will move them.
    let mark = { (number: Int, at: Int) -> Bookmark in
        let place = TextPlace(chapter: 0, offset: at)
        return Bookmark(number: number, chapterIndex: 0, characterOffset: at, anchor: TextAnchor(capturingAt: place, in: relocator.old))
    }
    let outcome = relocator.relocate(PlaceRelocator.Places(bookmarks: [mark(1, leadIn), mark(2, quote)]))
    for bookmark in outcome.places.bookmarks {
        print("  bookmark \(bookmark.number): new offset \(bookmark.characterOffset) <\(excerpt(TextPlace(chapter: 0, offset: bookmark.characterOffset), in: new))>")
    }
    print("  findings: \(outcome.bookmarkFindings.map { describe($0) })")
    let inverted = outcome.places.bookmarks[0].characterOffset > outcome.places.bookmarks[1].characterOffset
    print("  bookmark 1 was before bookmark 2 in the old text; after the move it is \(inverted ? "AFTER" : "before") it")
}

// MARK: - S3: a chapter that opens with the line the chapter before closes on

// The kept run between the copies is the heading "CHAPTER TWO. Low Water"
// (4 words, a solid run); the opening line of chapter two is removed.
let chapterOne = "CHAPTER ONE. The Barge Fair\n\nShe bolted the scullery door, pinched out the candle, and stood a long time at the window watching the barges tie up below the lock. Somewhere downriver a dog was barking at the water. \"Tomorrow, then,\" she said."
let chapterTwoHead = "CHAPTER TWO. Low Water\n\n"
let chapterTwoBody = "The river had dropped in the night, and the barges lay canted in the mud like boots kicked off at a door. By seven the whole street was out on the towpath to look."
do {
    print("S3  chapter two's opening line repeats chapter one's last line and is removed")
    let old = [chapterOne, chapterTwoHead + "\"Tomorrow, then,\" she said. " + chapterTwoBody]
    let new = [chapterOne, chapterTwoHead + chapterTwoBody]
    let relocator = PlaceRelocator(oldTexts: old, newTexts: new)
    let expected = TextPlace(chapter: 1, offset: offset(of: "The river", in: new[1]))
    let tomorrow = TextPlace(chapter: 1, offset: offset(of: "Tomorrow", in: old[1]))
    check("removed line at <Tomorrow>", relocator, saved: tomorrow, expected: expected)
    check("removed line at <she>", relocator, saved: TextPlace(chapter: 1, offset: offset(of: "she said", in: old[1])), expected: expected)
    // As the reading position, moved with the book's places.
    let position = ReadingPosition(chapterIndex: 1, characterOffset: tomorrow.offset,
                                   globalCharacterOffset: relocator.old.globalOffset(of: tomorrow),
                                   anchor: TextAnchor(capturingAt: tomorrow, in: relocator.old))
    let outcome = relocator.relocate(PlaceRelocator.Places(position: position))
    let moved = outcome.places.position!
    print("  position: chapter \(position.chapterIndex) -> chapter \(moved.chapterIndex), offset \(moved.characterOffset), global \(moved.globalCharacterOffset!), \(describe(outcome.positionFinding))")
}

// MARK: - Controls: what the keeping rule is for (must not change under a fix)

// C1: link text written twice with nothing between the copies, written once
// (testLinkTextNoLongerWrittenTwice's shape): a place in the removed copy lands
// word for word in the kept copy.
do {
    print("C1  control: adjacent copies (\"the granary wall the granary wall\"), one removed")
    let lead = "In the photograph the two brothers leaned against the granary wall"
    let tail = " and squinted at whoever held the camera, caps pushed back and sleeves rolled to the elbow."
    let old = [lead + " the granary wall" + tail]
    let new = [lead + tail]
    let relocator = PlaceRelocator(oldTexts: old, newTexts: new)
    let removed = offset(of: "the granary wall", in: old[0], occurrence: 1)
    let kept = offset(of: "the granary wall", in: new[0])
    for (label, into) in [("the", 0), ("granary", 4), ("wall", 12)] {
        check("removed copy at <\(label)>", relocator, saved: TextPlace(chapter: 0, offset: removed + into), expected: TextPlace(chapter: 0, offset: kept + into))
    }
}

// C2: a chapter restored before a chapter whose heading starts with the same
// word: the place at "CHAPTER XIX." keeps the words that follow it.
do {
    print("C2  control: chapter XVIII restored before \"CHAPTER XIX.\"")
    let seventeen = "CHAPTER XVII. The Sluice\n\nThe sluice gate had rusted half open, and the leat ran brown with the week's rain. Nobody had oiled the rack since the spring."
    let eighteen = "CHAPTER XVIII. The Flood\n\nBy midnight the water was over the lower meadow and still rising, and the geese had gone up onto the cart shed roof."
    let nineteen = "CHAPTER XIX. The Auction\n\nThe auctioneer set his table up in the yard because the barn was still ankle deep, and the bidding started late."
    let relocator = PlaceRelocator(oldTexts: [seventeen, nineteen], newTexts: [seventeen, eighteen, nineteen])
    check("<CHAPTER> of XIX", relocator, saved: TextPlace(chapter: 1, offset: 0), expected: TextPlace(chapter: 2, offset: 0))
    check("<XIX>", relocator, saved: TextPlace(chapter: 1, offset: 8), expected: TextPlace(chapter: 2, offset: 8))
}
