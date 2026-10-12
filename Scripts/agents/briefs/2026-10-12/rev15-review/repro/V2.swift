import Foundation

// V2 verifier probe: a skipped heading saved before anchors (an ID alone),
// whose ID went stale in an earlier extraction change, reaches a rebuild
// without words. Does PlaceRelocator give it to another section?
//
// Story (the measured real step "alice-sibling.epub, 3.0.3 to 3.0.4: a
// chapter restored"): the listener skipped chapter IV in a reading that had
// lost chapter III, so the skip was saved as "2-0-1-CHAPTER IV. ...". A later
// extraction restored chapter III; IV is now unit 3, so the ID names no
// heading, the reader's filter skips nothing, and branch B's capture gives
// the skip no words (TextAnchorCapture.swift 80-83, 111). The text cache is
// then rebuilt (branch D), with the current content.md as the old text.

// MARK: - Verbatim copies of Book.swift's SkippedHeading.init?(id:) and inStep
// (the harness stub lacks them), so the skip is made exactly as the app makes it.
extension SkippedHeading {
    init?(id: String) {
        let parts = id.split(separator: "-", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4,
              let chapterIndex = Int(parts[0]),
              let characterOffset = Int(parts[1]),
              let level = Int(parts[2])
        else { return nil }
        self.init(level: level, label: String(parts[3]), chapterIndex: chapterIndex, characterOffset: characterOffset)
        guard self.id == id else { return nil }
    }

    static func inStep(with ids: [String]?, keeping kept: [SkippedHeading]?) -> [SkippedHeading]? {
        guard let ids, !ids.isEmpty else { return nil }
        var keptByID: [String: SkippedHeading] = [:]
        for heading in kept ?? [] where keptByID[heading.id] == nil {
            keptByID[heading.id] = heading
        }
        let headings = ids.compactMap { keptByID[$0] ?? SkippedHeading(id: $0) }
        return headings.isEmpty ? nil : headings
    }
}

// MARK: - The book

let one = "CHAPTER I. The Press\n\n"
    + "The press arrived on a flatbed lorry in October, wrapped in tarpaulin and smelling of machine oil and damp cardboard. "
    + "Wilf Okonedo had bought it from a closing print shop in Rochdale for the price of its scrap weight.\n\n"
    + "It took six of them and a borrowed engine hoist to lower it through the cellar doors without cracking the platen."
let two = "CHAPTER II. The Type Cases\n\n"
    + "The type came separately, in eleven shallow wooden cases that had been stacked face down in a garage for thirty years. "
    + "Half the lowercase e's were missing, and someone had filed the remaining ampersands into crude asterisks.\n\n"
    + "Hettie Prowse sorted every sort by hand over a fortnight, with a jeweller's loupe and a muffin tin for the strays."
let three = "CHAPTER III. The Ink\n\n"
    + "Nobody could agree on the ink. The old foreman swore by a linseed varnish he mixed himself in a jam jar, "
    + "while the treasurer ordered a rubber-based tin from Leeds because it would not skin over between Saturdays.\n\n"
    + "They settled it with a test sheet run in both, pinned to the cellar wall, and voted with drawing pins."
let four = "CHAPTER IV. The First Sheet\n\n"
    + "The first sheet they printed was the parish notice for the harvest supper, set in twelve-point Caslon with a crooked rule. "
    + "Wilf kept the spoiled proofs in a biscuit tin under the bench and showed them to anyone who stayed longer than an hour.\n\n"
    + "By spring the shop was taking orders for wedding invitations, and the cellar had a waiting list of apprentices."

/// Each chapter that begins "CHAPTER" has a level-1 heading at its start,
/// labelled with its first line, as the app's readers make them.
func headings(of texts: [String]) -> [Heading] {
    texts.enumerated().compactMap { index, text in
        guard text.hasPrefix("CHAPTER"), let label = text.components(separatedBy: "\n").first else { return nil }
        return Heading(level: 1, text: label, chapterIndex: index, characterOffset: 0)
    }
}
func content(_ texts: [String]) -> DocumentContent {
    DocumentContent(title: "The Press at Garth Lane", author: "Garth Lane Printers", chapters: texts.enumerated().map { index, text in
        Chapter(title: "", text: text, headings: headings(of: texts).filter { $0.chapterIndex == index })
    })
}

/// Branch B's rule for skipped headings (TextAnchorCapture.swift 103-114):
/// only a wordless skip whose ID names a heading of the current text gets words.
func branchBGivesWords(_ skipped: SkippedHeading, in current: DocumentContent) -> Bool {
    var byID: [String: Heading] = [:]
    for heading in current.allHeadings where byID[heading.id] == nil { byID[heading.id] = heading }
    return skipped.anchor == nil && byID[skipped.id] != nil
}

/// Which headings the reader's filter skips: those whose ID is in the skip set
/// (ReaderViewModel+VoiceAndSpeed.swift 180-187, SkippedSectionFilter).
func filtered(_ skips: [SkippedHeading], _ texts: [String]) -> [String] {
    let ids = Set(skips.map(\.id))
    return content(texts).allHeadings.filter { ids.contains($0.id) }.map(\.text)
}

func describe(_ label: String, old: [String], new: [String], ids: [String]) {
    let book = SkippedHeading.inStep(with: ids, keeping: nil) ?? []
    let relocator = PlaceRelocator(old: content(old), new: content(new))
    let outcome = relocator.relocate(PlaceRelocator.Places(skippedHeadings: book))
    print("== \(label)")
    for (index, skip) in book.enumerated() {
        print("   in : \(skip.id)  anchor nil: \(skip.anchor == nil)  branch B gives words: \(branchBGivesWords(skip, in: content(old)))")
        print("   finding: \(String(describing: outcome.skippedHeadingFindings[index]))")
    }
    print("   out: \(outcome.places.skippedHeadings.map(\.id))")
    let waitingWords = outcome.places.skippedHeadings.compactMap { $0.anchor?.after }.map { String($0.prefix(40)) }
    print("   out anchors' words after: \(waitingWords)")
    print("   reader skips BEFORE rebuild (old text): \(filtered(book, old))")
    print("   reader skips AFTER  rebuild (new text): \(filtered(outcome.places.skippedHeadings, new))")
}

let current = [one, two, three, four]       // content.md as this build reads it (III restored)
let edited = [one.replacingOccurrences(of: "six of them", with: "seven of them"), two, three, four]  // the rebuild changes one word in chapter I

// S1: the stale ID of chapter IV (saved when III was missing), rebuild that changes nothing.
describe("S1 stale skip of IV, saved as unit 2; rebuild changes nothing", old: current, new: current,
         ids: ["2-0-1-CHAPTER IV. The First Sheet"])
// S2: the same, rebuild that changes one word in chapter I.
describe("S2 same stale skip; rebuild changes one word in chapter I", old: current, new: edited,
         ids: ["2-0-1-CHAPTER IV. The First Sheet"])
// S3 control: the same skip with today's ID (names IV), saved without words.
describe("S3 control: wordless skip whose ID names IV now", old: current, new: edited,
         ids: ["3-0-1-CHAPTER IV. The First Sheet"])
// S4 control: a label-only drift at the right numbers ("[]" placeholder dropped), the case the mechanism serves.
describe("S4 control: label-only drift at IV's own numbers", old: current, new: edited,
         ids: ["3-0-1-[]CHAPTER IV."])
// S5: the waiting path: stale skip of II saved as unit 2 (a cover was dropped), new text leaves out III.
describe("S5 stale skip of II at unit 2; new text leaves out III", old: current, new: [one, two, four],
         ids: ["2-0-1-CHAPTER II. The Type Cases"])
// S6: a stale level-2 ID mid-chapter that lands on no heading: what the waiting skip stores.
describe("S6 stale skip of II at unit 2 with III removed AND II relabelled", old: current,
         new: [one, two.replacingOccurrences(of: "CHAPTER II. The Type Cases", with: "CHAPTER II. Sorts and Cases"), four],
         ids: ["2-0-1-CHAPTER II. The Type Cases"])

// S7: S6's waiting skip (now holding chapter III's words) meets a second
// rebuild in which chapter III comes back.
do {
    let firstNew = [one, two.replacingOccurrences(of: "CHAPTER II. The Type Cases", with: "CHAPTER II. Sorts and Cases"), four]
    let first = PlaceRelocator(old: content(current), new: content(firstNew))
        .relocate(PlaceRelocator.Places(skippedHeadings: SkippedHeading.inStep(with: ["2-0-1-CHAPTER II. The Type Cases"], keeping: nil) ?? []))
    let secondNew = [firstNew[0], firstNew[1], three, four]
    let second = PlaceRelocator(old: content(firstNew), new: content(secondNew)).relocate(PlaceRelocator.Places(skippedHeadings: first.places.skippedHeadings))
    print("== S7 second rebuild restores III: waiting skip \(first.places.skippedHeadings.map(\.id)) -> \(second.places.skippedHeadings.map(\.id)) \(second.skippedHeadingFindings)")
    print("   reader skips AFTER second rebuild: \(filtered(second.places.skippedHeadings, secondNew))")
}

// S8: front matter. The skip of the contents list was saved as "1-0-1-Contents"
// while a cover unit stood at 0; this build reads no cover, so Contents is
// unit 0 and the ID names no heading. Rebuild changes one word in chapter IV.
do {
    let contents = "Contents\n\nCHAPTER I. The Press\nCHAPTER II. The Type Cases\nCHAPTER III. The Ink\nCHAPTER IV. The First Sheet"
    let old = [contents, one, two, three, four]
    let new = [contents, one, two, three, four.replacingOccurrences(of: "crooked rule", with: "bent rule")]
    let heads = { (texts: [String]) in [Heading(level: 1, text: "Contents", chapterIndex: 0, characterOffset: 0)] + headings(of: texts) }
    let skips = SkippedHeading.inStep(with: ["1-0-1-Contents"], keeping: nil) ?? []
    let relocator = PlaceRelocator(oldTexts: old, newTexts: new, newHeadings: heads(new))
    let outcome = relocator.relocate(PlaceRelocator.Places(skippedHeadings: skips))
    let filter = { (s: [SkippedHeading], h: [Heading]) in h.filter { Set(s.map(\.id)).contains($0.id) }.map(\.text) }
    print("== S8 stale \"1-0-1-Contents\" (cover dropped since): -> \(outcome.places.skippedHeadings.map(\.id)) \(outcome.skippedHeadingFindings)")
    print("   reader skips BEFORE: \(filter(skips, heads(old)))  AFTER: \(filter(outcome.places.skippedHeadings, heads(new)))")
}
