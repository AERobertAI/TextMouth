import Foundation

// V5 verifier probe (scratch, not part of the app).
//
// Claim: PlaceRelocator.headingTextStands (PlaceRelocator.swift:391) counts a
// `.replaced` verdict for the word after a heading's first word as "the
// heading still stands". `.replaced` also comes out of
//   (a) a short PURE removal, since the like-for-like test (530-532) passes
//       for a new stretch of 0 words when the old one is <= 8 words
//       (likeForLikeSlack), and
//   (b) a section replaced wholesale by a different one of similar length.
// Either way the skip is handed to the heading of its level that now starts
// where the removed or replaced section began, hiding a section the listener
// never chose to skip.

// MARK: - The mill book (copied from TextMouthProductionTests/PlaceRelocatorTestSupport.swift)

let millrace = "CHAPTER I. The Millrace\n\n"
    + "The volunteers met at the mill on the first dry Saturday of March, with spades, a borrowed pump, and a flask of soup that Hesketh guarded as if it were the parish silver. "
    + "The millrace had silted to the height of a boot, and frogspawn floated in the shallows by the sluice.\n\n"
    + "By noon they had cleared forty yards of channel. Nell measured the fall with a spirit level and a length of string, and wrote the figures on the back of a seed packet, which she lost by teatime."
let wheel = "CHAPTER II. The Wheel\n\n"
    + "The wheel itself was oak, eleven feet across, its paddles split where the frost had worked into them. "
    + "A carpenter from the valley came on Tuesdays to fit new ones, steaming each plank over a tin bath until it would bend.\n\n"
    + "He charged nothing, but asked to keep the offcuts, which he turned into spoons and sold at the Thursday market under a hand-painted sign."
let stones = "CHAPTER III. The Stones\n\n"
    + "Nobody knew where the upper millstone had gone. The parish records listed a pair of French burrs bought in 1871, "
    + "and a photograph from the war showed both of them leaning against the granary wall.\n\n"
    + "In June a farmer ploughing above the weir struck something that rang like a dropped pan. It was the missing stone, face down in the clay, with a hawthorn growing through its eye."
let flour = "CHAPTER IV. First Flour\n\n"
    + "They ground their first sack of wheat on the longest day of the year. The flour came out warm and speckled, and Hesketh baked it into loaves as heavy as paving slabs, which were gone within the hour.\n\n"
    + "The miller's grandson, who was ninety, sat on an upturned crate by the hopper and told them, kindly, that they were running the stones too close."

// MARK: - Helpers

/// The heading labelled `label`, of `level`, where `label` first stands in `texts`.
func heading(_ label: String, level: Int, in texts: [String]) -> Heading {
    for (index, text) in texts.enumerated() {
        let range = (text as NSString).range(of: label)
        if range.location != NSNotFound {
            return Heading(level: level, text: label, chapterIndex: index, characterOffset: range.location)
        }
    }
    fatalError("no heading \"\(label)\" in the texts")
}

/// One heading of `level` at the start of each chapter, labelled with its first line.
func chapterHeadings(of texts: [String], level: Int = 1) -> [Heading] {
    texts.enumerated().map { index, text in
        Heading(level: level, text: text.components(separatedBy: "\n").first ?? "", chapterIndex: index, characterOffset: 0)
    }
}

/// The skip of `heading`, with its anchor captured at its start as the app captures one.
func skip(of heading: Heading, in words: BookWords) -> SkippedHeading {
    let start = TextPlace(chapter: heading.chapterIndex, offset: heading.characterOffset)
    return SkippedHeading(heading, anchor: TextAnchor(capturingAt: start, in: words)!)
}

/// The text of word `index` of `words`.
func wordText(_ index: Int, in words: BookWords) -> String {
    let text = words.texts[words.chapter(ofWord: index)] as NSString
    return text.substring(with: NSRange(location: words.starts[index], length: words.ends[index] - words.starts[index]))
}

/// PlaceRelocator.isSolid, copied for display only (it is private): old word
/// `word` lines up within a run of 4 words lined up alike.
func isSolid(_ word: Int, _ partners: [Int]) -> Bool {
    guard word >= 0, word < partners.count, partners[word] >= 0 else { return false }
    var length = 1
    var k = word - 1
    while k >= 0, length < 4, partners[k] >= 0, partners[k] == partners[k + 1] - 1 { length += 1; k -= 1 }
    k = word + 1
    while k < partners.count, length < 4, partners[k] >= 0, partners[k] == partners[k - 1] + 1 { length += 1; k += 1 }
    return length >= 4
}

/// The changed stretch the verdict for old word `word` reads (lines 518-532),
/// recomputed for display: its old and new lengths and whether it is like for like.
func stretchReport(around word: Int, old: BookWords, new: BookWords) -> String {
    let partners = PatienceDiff.partners(of: old.keys, in: new.keys)
    var previous = word - 1
    while previous >= 0, !isSolid(previous, partners) { previous -= 1 }
    var next = word + 1
    while next < old.count, !isSolid(next, partners) { next += 1 }
    let oldLength = next - previous - 1
    let stretchStart = previous >= 0 ? partners[previous] + 1 : 0
    let stretchEnd = next < old.count ? partners[next] : new.count
    let newLength = stretchEnd - stretchStart
    let likeForLike = previous >= 0 && next < old.count && newLength <= 2 * oldLength + 8 && oldLength <= 2 * newLength + 8
    let shown = (previous + 1..<next).prefix(10).map { "\(wordText($0, in: old))\(partners[$0] >= 0 ? "=" : "-")" }
    return "word after the heading's first: \"\(wordText(word, in: old))\" partner \(partners[word]); "
        + "old stretch \(oldLength) words [\(shown.joined(separator: " "))\(oldLength > 10 ? " ..." : "")], new stretch \(newLength) words, like-for-like \(likeForLike)"
}

/// A heading result in a line.
func describe(_ result: PlaceRelocator.HeadingResult?) -> String {
    guard let result else { return "nil (the skip waits)" }
    return "\"\(result.heading.text)\" at (\(result.heading.chapterIndex),\(result.heading.characterOffset)), \(result.finding)"
}

/// Moves the skip of `skipped` (a heading of the old text) and prints how.
func run(_ name: String, old: [String], new: [String], skipped oldHeading: Heading, newHeadings: [Heading]) {
    let relocator = PlaceRelocator(oldTexts: old, newTexts: new, newHeadings: newHeadings)
    let skipped = skip(of: oldHeading, in: relocator.old)
    let start = TextPlace(chapter: oldHeading.chapterIndex, offset: oldHeading.characterOffset)
    let first = relocator.old.word(at: start)
    let carried = relocator.relocate(skipped.anchor, savedAt: start)
    print("== \(name)")
    print("   skipped: \"\(oldHeading.text)\" (level \(oldHeading.level)) at (\(start.chapter),\(start.offset)); new headings of its level: "
        + newHeadings.filter { $0.level == oldHeading.level }.map { "\"\($0.text)\"" }.joined(separator: ", "))
    print("   \(stretchReport(around: first + 1, old: relocator.old, new: relocator.new))")
    print("   its start carried as a place: (\(carried.place.chapter),\(carried.place.offset)) \(carried.finding)")
    print("   relocate(skip) -> \(describe(relocator.relocate(skipped)))")
    let outcome = relocator.relocate(PlaceRelocator.Places(position: nil, bookmarks: [], skippedHeadings: [skipped]))
    print("   saved skips after the rebuild: \(outcome.places.skippedHeadings.map(\.id)); \(outcome.counts.logLine(title: "probe"))")
}

// MARK: - (a) A short section removed

let titlePage = "The Mill at Hollins Ford\n\nA restoration diary, written up by the volunteers of the Hollins Ford Mill Trust over three summers, with the treasurer's accounts.\n\n"
let shortDedication = "Dedication\n\nFor Nell, who kept the notebook.\n\n"                          // 7 fine words
let longDedication = "Dedication\n\nFor Nell, who kept the notebook, and for every volunteer who carried a bucket.\n\n" // 15 fine words

// A1: title page, dedication, and chapter I in one chapter's text; the new text drops the dedication.
do {
    let old = [titlePage + shortDedication + millrace, wheel]
    let new = [titlePage + millrace, wheel]
    let newHeadings = [heading("CHAPTER I. The Millrace", level: 1, in: new), heading("CHAPTER II. The Wheel", level: 1, in: new)]
    run("A1 short Dedication (7 words) removed, one chapter text", old: old, new: new,
        skipped: heading("Dedication", level: 1, in: old), newHeadings: newHeadings)
}

// A1 control: the same with a 15-word dedication.
do {
    let old = [titlePage + longDedication + millrace, wheel]
    let new = [titlePage + millrace, wheel]
    let newHeadings = [heading("CHAPTER I. The Millrace", level: 1, in: new), heading("CHAPTER II. The Wheel", level: 1, in: new)]
    run("A1 control: long Dedication (15 words) removed, one chapter text", old: old, new: new,
        skipped: heading("Dedication", level: 1, in: old), newHeadings: newHeadings)
}

// A2: each part its own chapter, as an EPUB's spine gives them; the new text drops the dedication's chapter.
do {
    let old = [titlePage, shortDedication, millrace, wheel]
    let new = [titlePage, millrace, wheel]
    run("A2 short Dedication chapter removed (EPUB-like chapters)", old: old, new: new,
        skipped: Heading(level: 1, text: "Dedication", chapterIndex: 1, characterOffset: 0),
        newHeadings: [Heading(level: 1, text: "Title", chapterIndex: 0, characterOffset: 0)] + Array(chapterHeadings(of: new).dropFirst()))
}

// A3: the pinned test's own fixture (testASkippedSectionLeftOutWaitsRatherThanSkipTheNext), with the pump section short.
do {
    let opening = "CHAPTER I. The Millrace\n\nThe volunteers met at the mill on the first dry Saturday of March, with spades and a flask.\n\n"
    let soup = "The Soup\n\nThe flask held leek and potato, poured into enamel mugs with the solemnity of a verger."
    for (label, pump) in [("A3 test fixture, pump section as the test has it (22 words)", "The Pump\n\nThe borrowed pump ran on paraffin and had to be primed with a kettle of water every half hour.\n\n"),
                          ("A3 test fixture, pump section short (6 words)", "The Pump\n\nIt ran on paraffin.\n\n")] {
        let old = [opening + pump + soup]
        let new = [opening + soup]
        run(label, old: old, new: new, skipped: heading("The Pump", level: 2, in: old),
            newHeadings: [Heading(level: 1, text: "CHAPTER I. The Millrace", chapterIndex: 0, characterOffset: 0), heading("The Soup", level: 2, in: new)])
    }
}

// MARK: - (b) A section replaced wholesale by a different one

let interlude = "INTERLUDE. A Letter from the Chapel\n\n"
    + "Dear committee, the deacons have voted to lend you our trestle tables for the open day, provided they come back by Whitsun. "
    + "Mrs Pargeter asks whether the tea urn you borrowed in April might be returned at the same time, since the Sunday school misses it.\n\n"
    + "We enclose a postal order for two pounds towards the roof, raised by the sale of a quilt, and our prayers for dry weather."
let longInterlude = interlude + "\n\n" + Array(repeating: "The deacons also wish it recorded that the chapel organ, which was tuned last winter by a man from Leeds, has not been the same since, and that they hold the mill trust in no way responsible for this.", count: 6).joined(separator: " ")

// B1: chapter III replaced by an interlude of about the same length (chapter start: no words before the heading in its chapter).
do {
    let old = [millrace, wheel, stones, flour]
    let new = [millrace, wheel, interlude, flour]
    run("B1 chapter III replaced wholesale by an interlude of similar length", old: old, new: new,
        skipped: chapterHeadings(of: old)[2], newHeadings: chapterHeadings(of: new))
}

// B1 control: the replacement much longer, so not like for like.
do {
    let old = [millrace, wheel, stones, flour]
    let new = [millrace, wheel, longInterlude, flour]
    run("B1 control: chapter III replaced by a much longer interlude", old: old, new: new,
        skipped: chapterHeadings(of: old)[2], newHeadings: chapterHeadings(of: new))
}

// MARK: - The rule's intended cases (tests testAHeadingRenumberedInPlaceKeepsItsSkip, testARelabelledHeadingKeepsItsSkip)

do {
    let old = [millrace, wheel, stones, flour]
    let renumbered = [millrace, wheel, stones.replacingOccurrences(of: "CHAPTER III.", with: "CHAPTER 3."), flour]
    run("C1 intended: CHAPTER III. renumbered CHAPTER 3. (pinned: keeps its skip, .linedUp)", old: old, new: renumbered,
        skipped: chapterHeadings(of: old)[2], newHeadings: chapterHeadings(of: renumbered))
    let relabelled = [millrace, wheel, stones.replacingOccurrences(of: "CHAPTER III.", with: "PART III."), flour]
    run("C2 intended: CHAPTER III. relabelled PART III. (pinned: keeps its skip, .wordReplaced)", old: old, new: relabelled,
        skipped: chapterHeadings(of: old)[2], newHeadings: chapterHeadings(of: relabelled))
    run("C3 control: chapter III left out (pinned: waits)", old: old, new: [millrace, wheel, flour],
        skipped: chapterHeadings(of: old)[2], newHeadings: chapterHeadings(of: [millrace, wheel, flour]))
}
