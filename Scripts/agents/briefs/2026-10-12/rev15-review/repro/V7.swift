import Foundation

// V7 verifier probe (scratch; the repository is not touched).
//
// PlaceRelocator.heading(ofLevel:startingAt:) (PlaceRelocator.swift:398-406)
// returns the FIRST new heading of the skip's level whose start maps to the
// word the skip landed before, whatever its label. Two heading shapes that the
// app's own MarkdownParser produces today from the user's live library (cache
// format 3.0.7, see scan/scan-output.txt) are modelled here with new words:
//
//   A. The MaddAddam omnibus, chapter 69: three TOC headings of level 1,
//      "Cover", "Title Page", "Copyright", whose only text is an empty-alt
//      image's space and a paragraph break, so all three start before the
//      copyright page's first word.
//   B. The Merchant's War, chapter 5: an h1 "€§" (no letter or digit) right
//      before the h1 "BREAKTHROUGHS".
//
// In each, the listener skipped the real section; the rebuilt text moves its
// numbers (a word added before it, or a chapter put in before it), so the
// direct check fails and the diff carries the skip.

/// The UTF-16 offset of `needle` in `text`.
func offset(of needle: String, in text: String) -> Int {
    let location = (text as NSString).range(of: needle).location
    precondition(location != NSNotFound, "missing \(needle)")
    return location
}

/// The ranges SkippedSectionFilter.apply removes from a chapter's speech:
/// its loop at ReaderViewModel+VoiceAndSpeed.swift:227-239, copied verbatim
/// (each skipped heading's start up to the next heading of the chapter).
func excludedRanges(textLength: Int, headings: [Heading], skippedIDs: Set<String>) -> [Range<Int>] {
    var excludeRanges: [Range<Int>] = []
    let sortedHeadings = headings.sorted { $0.characterOffset < $1.characterOffset }
    for (i, heading) in sortedHeadings.enumerated() {
        guard skippedIDs.contains(heading.id) else { continue }
        let start = min(max(0, heading.characterOffset), textLength)
        let end: Int
        if i + 1 < sortedHeadings.count {
            end = min(max(start, sortedHeadings[i + 1].characterOffset), textLength)
        } else {
            end = textLength
        }
        if start < end { excludeRanges.append(start..<end) }
    }
    return excludeRanges
}

/// Runs one case: relocates `skip` from `oldTexts` to `newTexts` with
/// `newHeadings`, and reports what the skip names, what the label-aware
/// finder alone would name, and what speech would then leave out of the
/// skip's chapter.
func run(_ title: String, oldTexts: [String], newTexts: [String], newHeadings: [Heading], skip: SkippedHeading) {
    print("== \(title)")
    let r = PlaceRelocator(oldTexts: oldTexts, newTexts: newTexts, newHeadings: newHeadings)
    let result = r.relocate(skip)
    print("  skipped:        \(skip.id)")
    print("  relocate(skip): \(result.map { "\($0.heading.id)  \($0.finding)" } ?? "nil (waits)")")

    // The whole-book path, which writes the skips back (relocate(_ places:)).
    let outcome = r.relocate(PlaceRelocator.Places(skippedHeadings: [skip]))
    let savedIDs = Set(outcome.places.skippedHeadings.map(\.id))
    print("  saved skip IDs: \(savedIDs.sorted())")

    // The label-aware saved-words search alone, for comparison.
    let finder = TextAnchorFinder(texts: newTexts, headings: newHeadings)
    let alone = finder.findHeading(level: skip.level, label: skip.label, anchor: skip.anchor!,
                                   savedAt: TextPlace(chapter: skip.chapterIndex, offset: skip.characterOffset))
    print("  findHeading alone: \(alone.map { "\($0.heading.id)  \($0.finding)" } ?? "nil")")

    // What the reader's filter then removes from the chapter that holds the
    // section the listener skipped.
    if let named = outcome.places.skippedHeadings.first {
        let chapter = named.chapterIndex
        let text = newTexts[chapter]
        let chapterHeadings = newHeadings.filter { $0.chapterIndex == chapter }
        let ranges = excludedRanges(textLength: text.utf16.count, headings: chapterHeadings, skippedIDs: savedIDs)
        let removed = ranges.map { (text as NSString).substring(with: NSRange(location: $0.lowerBound, length: $0.count)) }
        print("  speech leaves out: \(ranges) = \(removed.map(\.debugDescription))")
        if let real = chapterHeadings.first(where: { $0.text == skip.label }) {
            let start = real.characterOffset
            let isSkipped = ranges.contains { $0.contains(start) }
            let sample = (text as NSString).substring(with: NSRange(location: start, length: min(60, text.utf16.count - start)))
            print("  section \"\(skip.label)\" at \(start) left out of speech? \(isSkipped); its text: \(sample.debugDescription)")
        }
    }
    print("")
}

// MARK: - A. TOC headings over a copyright page (MaddAddam's shape)

let previousChapter = "Book One\n\nThe ferry left the island at dawn, and the families who had waited on the jetty all night carried their bundles down the slipway in silence."
let aboutOld = "About the Author\n\nThe author lives in a lakeside town and keeps a notebook of every heron she sees on the morning walk along the shore road.\n\n"
let aboutNew = aboutOld.replacingOccurrences(of: "keeps a notebook", with: "keeps a pocket notebook")
let pile = " \n\n"   // the empty-alt cover and title images leave a space and a break
let copyright = "SECOND HARBOUR BOOKS EDITION, MAY 2011\n\nThis edition is published by arrangement with the author. All rights reserved, and no part of it may be copied without written permission, except for short quotations in a review.\n\nThe tide tables at the back were checked against the harbour office ledgers for that spring."
let chapterOld = aboutOld + pile + copyright
let chapterNew = aboutNew + pile + copyright

/// The new chapter's headings, as MarkdownParser numbers them: "About the
/// Author" at 0, then the three TOC headings piled before "SECOND".
func omnibusHeadings(chapter: Int, text: String, about: String) -> [Heading] {
    let cover = about.utf16.count
    return [
        Heading(level: 1, text: "About the Author", chapterIndex: chapter, characterOffset: 0),
        Heading(level: 1, text: "Cover", chapterIndex: chapter, characterOffset: cover),
        Heading(level: 1, text: "Title Page", chapterIndex: chapter, characterOffset: cover + 1),
        Heading(level: 1, text: "Copyright", chapterIndex: chapter, characterOffset: offset(of: "SECOND", in: text)),
    ]
}

let oldA = [previousChapter, chapterOld]
let newA = [previousChapter, chapterNew]
let headingsA = omnibusHeadings(chapter: 1, text: chapterNew, about: aboutNew)
let oldWordsA = BookWords(texts: oldA)
let copyrightOld = offset(of: "SECOND", in: chapterOld)
let skipCopyright = SkippedHeading(level: 1, label: "Copyright", chapterIndex: 1, characterOffset: copyrightOld,
                                   anchor: TextAnchor(capturingAt: TextPlace(chapter: 1, offset: copyrightOld), in: oldWordsA))
run("A1. Copyright skipped; a word added earlier in its chapter", oldTexts: oldA, newTexts: newA, newHeadings: headingsA, skip: skipCopyright)

// The same, the text unchanged but a chapter put in before it by the
// rebuild (the chapter index moves).
let newA2 = ["Contents\n\nBook One. Book Two. About the Author. The tide tables and the ferry timetable follow the last chapter.", previousChapter, chapterOld]
let headingsA2 = omnibusHeadings(chapter: 2, text: chapterOld, about: aboutOld)
run("A2. Copyright skipped; a chapter put in before it", oldTexts: oldA, newTexts: newA2, newHeadings: headingsA2, skip: skipCopyright)

// Control: the same as A1 without the two TOC headings piled before it.
run("A1 control: no piled headings", oldTexts: oldA, newTexts: newA,
    newHeadings: headingsA.filter { $0.text != "Cover" && $0.text != "Title Page" }, skip: skipCopyright)

// MARK: - B. A symbol-only h1 before the real one (The Merchant's War's shape)

let before = "The guard admitted, wheezing, that he had not seen the two figures run along the platform, and the train pulled out without them in view.\n\n"
let section = "€§\n\nBREAKTHROUGHS\n\nIt was all very simple, the courier told himself. The knotwork would take them somewhere new, or it would not, and the archive in the cellar would tell them which by the morning."
let oldB = ["Part Two\n\nThe winter storms closed the passes early that year, and the clans waited in their halls for the thaw.", before + section]
let newB = ["Contents\n\nPart Two. Breakthroughs. Acknowledgments and the map of the trade routes follow the last chapter.", oldB[0], oldB[1]]
let textB = newB[2]
let headingsB = [
    Heading(level: 1, text: "Part Two", chapterIndex: 1, characterOffset: 0),
    Heading(level: 1, text: "€§", chapterIndex: 2, characterOffset: offset(of: "€§", in: textB)),
    Heading(level: 1, text: "BREAKTHROUGHS", chapterIndex: 2, characterOffset: offset(of: "BREAKTHROUGHS", in: textB)),
]
let oldWordsB = BookWords(texts: oldB)
let breakthroughsOld = offset(of: "BREAKTHROUGHS", in: oldB[1])
let skipBreakthroughs = SkippedHeading(level: 1, label: "BREAKTHROUGHS", chapterIndex: 1, characterOffset: breakthroughsOld,
                                       anchor: TextAnchor(capturingAt: TextPlace(chapter: 1, offset: breakthroughsOld), in: oldWordsB))
run("B. BREAKTHROUGHS skipped; a chapter put in before it", oldTexts: oldB, newTexts: newB, newHeadings: headingsB, skip: skipBreakthroughs)
