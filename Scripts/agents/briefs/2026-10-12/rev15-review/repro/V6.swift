import Foundation

// V6 verifier probe (independent of the finder's angleE/p6).
//
// Claim: PlaceRelocator.headingTextStands(after:landedBefore:) looks only at
// the ONE old word after a skipped heading's first word. When a skipped
// section is removed and the next heading of its level begins with the same
// two (or more) words, PatienceDiff's "common start first" rule pairs the
// removed heading's leading words with the next heading's, the check passes,
// and the skip moves onto the next section (hiding it) as a sure
// .movedByTheDiff(.linedUp), instead of waiting as the type's doc promises.

// MARK: - Helpers

/// The text of fine word `index` of `words`, for printing the diff's pairing.
func wordText(_ words: BookWords, _ index: Int) -> String {
    guard index >= 0, index < words.count else { return "<none>" }
    let text = words.texts[words.chapter(ofWord: index)] as NSString
    return text.substring(with: NSRange(location: words.starts[index], length: words.ends[index] - words.starts[index]))
}

/// Level-`level` headings for chapters whose first line is their label.
func chapterHeadings(_ texts: [String], level: Int = 1) -> [Heading] {
    texts.enumerated().map { index, text in
        Heading(level: level, text: text.components(separatedBy: "\n").first!, chapterIndex: index, characterOffset: 0)
    }
}

/// A skip of `heading` with its anchor captured at its start in `texts`, as the
/// repo's SavedPlace.skip(of:in:) test helper makes one.
func skip(of heading: Heading, in texts: [String], withAnchor: Bool = true) -> SkippedHeading {
    let start = TextPlace(chapter: heading.chapterIndex, offset: heading.characterOffset)
    let anchor = withAnchor ? TextAnchor(capturingAt: start, in: BookWords(texts: texts)) : nil
    return SkippedHeading(heading, anchor: anchor)
}

/// Runs one case: prints what the relocator makes of the skip, and what the
/// old heading's first few words were paired with by the diff.
func runCase(_ title: String, old: [String], new: [String], newHeadings: [Heading], skipped: SkippedHeading) {
    let relocator = PlaceRelocator(oldTexts: old, newTexts: new, newHeadings: newHeadings)
    let result = relocator.relocate(skipped)
    print("== \(title)")
    print("   skipped label : \(skipped.label)  (anchor: \(skipped.anchor == nil ? "none" : "captured"))")
    if let result {
        print("   relocate ->   : \(result.heading.text)  [chapter \(result.heading.chapterIndex), offset \(result.heading.characterOffset)]  finding: \(result.finding)")
    } else {
        print("   relocate ->   : nil (the skip waits)")
    }
    // The diff's pairing of the skipped heading's first four words.
    let partners = PatienceDiff.partners(of: relocator.old.keys, in: relocator.new.keys)
    let first = relocator.old.word(at: TextPlace(chapter: skipped.chapterIndex, offset: skipped.characterOffset))
    let pairs = (first..<min(first + 4, relocator.old.count)).map { index -> String in
        let partner = partners[index]
        guard partner >= 0 else { return "\(wordText(relocator.old, index))->(none)" }
        let chapter = relocator.new.chapter(ofWord: partner)
        return "\(wordText(relocator.old, index))->new#\(partner)'\(wordText(relocator.new, partner))'(ch\(chapter))"
    }
    print("   diff pairs    : " + pairs.joined(separator: "  "))
}

// MARK: - The book (original text, realistic multi-sentence chapters)

let frameBody = "The signal box at Coldharbour Halt had stood empty since the branch closed, its windows boarded and its lever frame seized with rust. "
    + "Ottoline Pargeter bought the lease for a pound and a promise to keep the roof sound.\n\n"
    + "On the first wet Sunday of April she brought a tin of penetrating oil, a stepladder, and her nephew Benedek, who was fourteen and claimed to understand machinery. "
    + "By evening they had freed three of the twenty levers; the fourth snapped at the pivot, and Benedek wrapped the pieces in newspaper like a casualty."
let blockBody = "The block instruments had gone to a collector in Shrewsbury decades before. Ottoline traced them through an auction catalogue and wrote three letters, each politer than the last, before he agreed to lend them back. "
    + "They arrived in a hay-lined crate with a typed inventory and a warning that the bells must never be polished with anything stronger than a soft cloth.\n\n"
    + "Benedek polished them with toothpaste that afternoon, and the collector, visiting in May, said nothing but looked for a long time at the brass."
let registerBody = "Every movement through the box had once been written in the train register, a ledger as heavy as a paving slab. The final volume turned up in the parish hall, propping open a fire door. "
    + "Its closing entry, in pencil, recorded a goods train of eleven wagons and a brake van, followed by the words line closed and a drawing of a cat.\n\n"
    + "Ottoline copied the entry onto a card and pinned it beside the frame, where visitors read it aloud as though it were scripture."
let openingBody = "The box opened to the public on a Saturday in late September. A brass band from the colliery village played under the footbridge, slightly out of tune, "
    + "and Mr. Ffoulkes from the county archive cut a ribbon with dressmaking shears.\n\n"
    + "Benedek pulled lever nine to clear the distant signal for a train that would never come, and the crowd cheered as the arm dropped with a clank."

/// The four chapters with the given heading labels.
func chapters(_ labels: [String]) -> [String] {
    zip(labels, [frameBody, blockBody, registerBody, openingBody]).map { "\($0)\n\n\($1)" }
}

// MARK: - 1. Chapter headings sharing TWO leading words, chapter 2 removed

let twoWordLabels = ["Chapter the First. The Lever Frame", "Chapter the Second. The Block Instruments",
                     "Chapter the Third. The Train Register", "Chapter the Fourth. Opening Day"]
let oldA = chapters(twoWordLabels)
let newA = [oldA[0], oldA[2], oldA[3]]
runCase("1. 'Chapter the Second' removed; next heading 'Chapter the Third' (2 shared words)",
        old: oldA, new: newA, newHeadings: chapterHeadings(newA), skipped: skip(of: chapterHeadings(oldA)[1], in: oldA))

// Control: the same book with one shared word ("CHAPTER II." / "CHAPTER III."), as the repo's test.
let oneWordLabels = ["CHAPTER I. The Lever Frame", "CHAPTER II. The Block Instruments",
                     "CHAPTER III. The Train Register", "CHAPTER IV. Opening Day"]
let oldB = chapters(oneWordLabels)
let newB = [oldB[0], oldB[2], oldB[3]]
runCase("1c. CONTROL: 'CHAPTER II.' removed; next heading 'CHAPTER III.' (1 shared word)",
        old: oldB, new: newB, newHeadings: chapterHeadings(newB), skipped: skip(of: chapterHeadings(oldB)[1], in: oldB))

// MARK: - 2. The candidate's own shape: "BOOK ONE. CHAPTER II." / "BOOK ONE. CHAPTER III."

let bookLabels = oneWordLabels.map { "BOOK ONE. " + $0 }
let oldC = chapters(bookLabels)
let newC = [oldC[0], oldC[2], oldC[3]]
runCase("2. 'BOOK ONE. CHAPTER II.' removed; next 'BOOK ONE. CHAPTER III.'",
        old: oldC, new: newC, newHeadings: chapterHeadings(newC), skipped: skip(of: chapterHeadings(oldC)[1], in: oldC))

// MARK: - 3. An unrelated edit earlier in the book (the top-level common start stops early)

let oldD = oldA
let newD = [oldA[0].replacingOccurrences(of: "a tin of penetrating oil", with: "a can of penetrating oil"), oldA[2], oldA[3]]
runCase("3. as case 1, plus an earlier edit in chapter 1 ('tin' -> 'can')",
        old: oldD, new: newD, newHeadings: chapterHeadings(newD), skipped: skip(of: chapterHeadings(oldD)[1], in: oldD))

// 3b: an edit only AFTER the removal (in the last chapter): the common start runs up to the removal again.
let editedLast = oldA[3].replacingOccurrences(of: "slightly out of tune", with: "badly out of tune")
let newD2 = [oldA[0], oldA[2], editedLast]
runCase("3b. as case 1, plus a later edit in chapter 4 ('slightly' -> 'badly')",
        old: oldA, new: newD2, newHeadings: chapterHeadings(newD2), skipped: skip(of: chapterHeadings(oldA)[1], in: oldA))

// 3c: edits on BOTH sides of the removal: the stretch around it starts at a fixed point and its common start runs to it.
let newD3 = [newD[0], oldA[2], editedLast]
runCase("3c. as case 1, plus edits before ('tin' -> 'can') and after ('slightly' -> 'badly')",
        old: oldA, new: newD3, newHeadings: chapterHeadings(newD3), skipped: skip(of: chapterHeadings(oldA)[1], in: oldA))

// MARK: - 4. A skip saved without an anchor (before anchors), same removal as case 1

runCase("4. as case 1, the skip saved without an anchor",
        old: oldA, new: newA, newHeadings: chapterHeadings(newA), skipped: skip(of: chapterHeadings(oldA)[1], in: oldA, withAnchor: false))

// MARK: - 5. Level-2 sections inside one chapter

let appendixOpening = "Chapter the Fifth. Appendices\n\nWhat follows are the working notes the restoration kept in a school exercise book, copied out as written.\n\n"
let frameNotes = "Notes on the Frame\n\nThe frame is a Stevens pattern of 1889, with tappet locking under the floor and a cast plate naming the foundry in Southwark.\n\n"
let bellNotes = "Notes on the Bells\n\nEach bell has its own pitch, so a signalman could tell by ear which neighbouring box was calling without lifting his head from the register.\n\n"
let ledgerNotes = "Notes on the Ledger\n\nThe register's paper is foxed at the edges but sound, and the ink of the last decade has faded to the colour of weak tea."
let oldE = [appendixOpening + frameNotes + bellNotes + ledgerNotes]
let newE = [appendixOpening + frameNotes + ledgerNotes]
let sectionStart = (appendixOpening + frameNotes).utf16.count
let bellHeading = Heading(level: 2, text: "Notes on the Bells", chapterIndex: 0, characterOffset: sectionStart)
let newSectionHeadings = [Heading(level: 1, text: "Chapter the Fifth. Appendices", chapterIndex: 0, characterOffset: 0),
                          Heading(level: 2, text: "Notes on the Frame", chapterIndex: 0, characterOffset: appendixOpening.utf16.count),
                          Heading(level: 2, text: "Notes on the Ledger", chapterIndex: 0, characterOffset: sectionStart)]
runCase("5. section 'Notes on the Bells' removed; next section 'Notes on the Ledger'",
        old: oldE, new: newE, newHeadings: newSectionHeadings, skipped: skip(of: bellHeading, in: oldE))

// Control: the repo test's shape, sections sharing only "The".
let oldF = [oldE[0].replacingOccurrences(of: "Notes on the ", with: "The ")]
let newF = [newE[0].replacingOccurrences(of: "Notes on the ", with: "The ")]
let sectionStartF = (appendixOpening + frameNotes.replacingOccurrences(of: "Notes on the ", with: "The ")).utf16.count
let bellHeadingF = Heading(level: 2, text: "The Bells", chapterIndex: 0, characterOffset: sectionStartF)
let newSectionHeadingsF = [newSectionHeadings[0],
                           Heading(level: 2, text: "The Frame", chapterIndex: 0, characterOffset: appendixOpening.utf16.count),
                           Heading(level: 2, text: "The Ledger", chapterIndex: 0, characterOffset: sectionStartF)]
runCase("5c. CONTROL: section 'The Bells' removed; next 'The Ledger' (1 shared word)",
        old: oldF, new: newF, newHeadings: newSectionHeadingsF, skipped: skip(of: bellHeadingF, in: oldF))

// MARK: - 6. Numbered sections: "Section 3.1" / "Section 3.2" (fine words: section, 3, 1 / section, 3, 2)

let reportOpening = "3. Method\n\nThe survey ran over two summers on the disused branch, walking the formation from the junction to the buffer stops.\n\n"
let sectionOne = "Section 3.1 Sampling\n\nWe sampled ballast every two hundred yards, bagging a kilogram at each point and noting the depth at which clay appeared.\n\n"
let sectionTwo = "Section 3.2 Drainage\n\nCulverts were rodded and photographed; four of the eleven had collapsed, and two carried a stream the maps did not show.\n\n"
let sectionThree = "Section 3.3 Fencing\n\nThe boundary fence survives as concrete posts along most of the cutting, with the wire long since taken for farm use."
let oldG = [reportOpening + sectionOne + sectionTwo + sectionThree]
let newG = [reportOpening + sectionOne + sectionThree]
let twoStart = (reportOpening + sectionOne).utf16.count
let newReportHeadings = [Heading(level: 2, text: "Section 3.1 Sampling", chapterIndex: 0, characterOffset: reportOpening.utf16.count),
                         Heading(level: 2, text: "Section 3.3 Fencing", chapterIndex: 0, characterOffset: twoStart)]
runCase("6. 'Section 3.2 Drainage' removed; next 'Section 3.3 Fencing'",
        old: oldG, new: newG, newHeadings: newReportHeadings,
        skipped: skip(of: Heading(level: 2, text: "Section 3.2 Drainage", chapterIndex: 0, characterOffset: twoStart), in: oldG))

// MARK: - 7. What a caller writes back: the whole-book API (branch D's entry point)

let book = PlaceRelocator(oldTexts: oldA, newTexts: newA, newHeadings: chapterHeadings(newA))
let outcome = book.relocate(PlaceRelocator.Places(position: nil, bookmarks: [],
                                                  skippedHeadings: [skip(of: chapterHeadings(oldA)[1], in: oldA)]))
print("== 7. relocate(Places) for case 1")
for skipped in outcome.places.skippedHeadings {
    print("   saved skip    : label '\(skipped.label)', chapter \(skipped.chapterIndex), offset \(skipped.characterOffset), id \(skipped.id)")
}
print("   findings      : \(outcome.skippedHeadingFindings)")
print("   log line      : \(outcome.counts.logLine(title: "Coldharbour"))")
print("   new chapter 1 : \(newA[1].components(separatedBy: "\n").first!)  <- the chapter the saved skip now hides")
