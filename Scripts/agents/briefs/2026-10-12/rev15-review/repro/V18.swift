import Foundation

// V18 verifier probe: is PlaceRelocator.headingTextStands too strict, so a
// skipped heading whose text still stands (a one-word label that gains words
// right after it, or a label whose first word was dropped) is judged
// `.removed`, the label is then required, and the skip waits?
//
// Each case builds an old and a new book from the same realistic chapters,
// changes only the heading under test (plus, for the one-word label, an
// earlier sentence so the heading's numbers shift), and prints:
//   - that the skip's anchor does NOT stand at its numbers in the new text
//     (rule 1 / `settled` is nil, so the diff path is taken);
//   - where a reading position at the same spot, with the same anchor, goes
//     (it runs the same `carry` the skip's start does);
//   - `headingTextStands`' inputs, rebuilt through the public API
//     (`PatienceDiff.partners` is exactly the relocator's `partners`);
//   - what `findHeading` names on its own (the doc's "otherwise the finder
//     decides", which carries no label requirement);
//   - what `relocate(skip)` returns, and whether the moved skip's ID matches
//     the new heading's (the ID is what playback skips by).

/// The UTF-16 offset of the first `phrase` in `text`; traps when missing.
func offset(of phrase: String, in text: String) -> Int {
    let range = (text as NSString).range(of: phrase, options: .literal)
    precondition(range.location != NSNotFound, "missing phrase: \(phrase)")
    return range.location
}

// MARK: - The book: a short history of a print shop

let forewordOld = "Foreword\n\n"
    + "This account of the Garrow Lane press was put together from the shop's order books, which survive almost complete from 1902 onward, and from long afternoons with the two compositors still living. "
    + "Where the books and the compositors disagree, the books have been believed about money and the compositors about everything else.\n\n"
/// The foreword with one sentence put in mid-paragraph: every later offset in
/// chapter 0 shifts, while the words just before "Prologue" stay the same.
let forewordNew = forewordOld.replacingOccurrences(
    of: "still living. ",
    with: "still living. The county archive lent the order books for a whole summer and asked only that they come back dry. ")
let prologueBody = "The press arrived in pieces on a brewer's dray in the autumn of 1898, and it took the founder's nephew most of that winter to work out which bolt belonged where. "
    + "He kept a list of the parts in pencil, crossing each one out as it found its place, and the last line of the list reads: one spring, purpose unknown."

let chapterOne = "CHAPTER I. Type and Ink\n\n"
    + "1. Auction Bills\n\n"
    + "The first job the shop took was a run of auction bills for a cattle sale at Hexham, set in a wood type so worn that the capital R printed as a smudge. "
    + "The farmer paid in cheese, which the nephew sold on at a loss to a grocer who never paid at all.\n\n"
    + "2. An Apprentice\n\n"
    + "By the spring of 1899 the shop had three cases of metal type, a second-hand guillotine, and a boy named Wilf Abery who could set a line faster than anyone in the county and spell almost nothing."
let chapterTwo = "CHAPTER II. The Compositors\n\n"
    + "Wilf trained four apprentices over forty years, and each of them learned on the same brass composing stick, dented where he had once thrown it at a commercial traveller. "
    + "The order books record the traveller's complaint and, two lines lower, a standing order from the same man for letterheads.\n\n"
    + "The compositors worked by gaslight until 1931, and every one of them could tell a misprint by the sound the forme made when it was locked up."
let chapterThree = "CHAPTER III.\n\n"
    + "From 1940 the shop printed ration books for the Food Office on stock it was not otherwise allowed to buy. "
    + "The overrun was meant to be pulped under supervision; the order books list the supervisor's fee and, beside it, a gross of wedding invitations on suspiciously official cream laid.\n\n"
    + "After the war the shop never quite recovered its trade, and in 1958 the press was sold to a museum in Leeds, where it still prints a postcard of itself on open days."

let oldBook = [forewordOld + "Prologue\n\n" + prologueBody, chapterOne, chapterTwo, chapterThree]

/// The book's headings: "CHAPTER" lines at level 1, the rest at level 2.
func headings(of book: [String], labels: [(chapter: Int, label: String, level: Int)]) -> [Heading] {
    labels.map { Heading(level: $0.level, text: $0.label, chapterIndex: $0.chapter, characterOffset: offset(of: $0.label, in: book[$0.chapter])) }
}

/// The labels of a book whose changed labels are given; the rest as the old book has them.
func labels(foreword: String = "Foreword", prologue: String = "Prologue", bills: String = "1. Auction Bills",
            apprentice: String = "2. An Apprentice", two: String = "CHAPTER II. The Compositors",
            three: String = "CHAPTER III.") -> [(chapter: Int, label: String, level: Int)] {
    [(0, foreword, 2), (0, prologue, 2), (1, "CHAPTER I. Type and Ink", 1), (1, bills, 2), (1, apprentice, 2), (2, two, 1), (3, three, 1)]
}

let oldHeadings = headings(of: oldBook, labels: labels())

// MARK: - One case

/// Moves the skip of the old heading labelled `skippedLabel` to `newBook`,
/// whose headings carry `newLabels`, and prints what happens and why.
func run(_ name: String, newBook: [String], newLabels: [(chapter: Int, label: String, level: Int)], skippedLabel: String, expectedLabel: String) {
    let newHeadings = headings(of: newBook, labels: newLabels)
    let oldHeading = oldHeadings.first { $0.text == skippedLabel }!
    let expected = newHeadings.first { $0.text == expectedLabel }!
    let relocator = PlaceRelocator(oldTexts: oldBook, newTexts: newBook, newHeadings: newHeadings)
    let saved = TextPlace(chapter: oldHeading.chapterIndex, offset: oldHeading.characterOffset)
    let anchor = TextAnchor(capturingAt: saved, in: relocator.old)!
    let skip = SkippedHeading(oldHeading, anchor: anchor)
    let finder = TextAnchorFinder(words: relocator.new, headings: newHeadings)

    print("== \(name)")
    print("  old \"\(oldHeading.text)\" at \(saved.chapter):\(saved.offset)  ->  new \"\(expected.text)\" at \(expected.chapterIndex):\(expected.characterOffset)")
    print("  anchor stands at its numbers in the new text: \(anchor.stands(at: saved, in: relocator.new.texts)); settled: \(String(describing: finder.settled(anchor, savedAt: saved)))")

    // A reading position at the same spot, with the same anchor, runs the
    // same rule-1 check, old-text find, and `carry` as the skip's start.
    let position = relocator.relocate(anchor, savedAt: saved)
    print("  reading position at the same spot -> \(position.place.chapter):\(position.place.offset) \(position.finding)")

    // headingTextStands(after: word, landedBefore: landed), rebuilt.
    let partners = PatienceDiff.partners(of: relocator.old.keys, in: relocator.new.keys)
    let word = relocator.old.word(at: saved)
    let landed = relocator.new.word(at: position.place)
    print("  headingTextStands: partners[word+1] = \(partners[word + 1]), landed + 1 = \(landed + 1) -> \(partners[word + 1] == landed + 1) (old first word's partner \(partners[word]))")

    let alone = finder.findHeading(level: skip.level, label: skip.label, anchor: anchor, savedAt: saved)
    print("  findHeading on its own (no label requirement) -> \(alone.map { "\"\($0.heading.text)\" \($0.finding)" } ?? "nil")")

    let result = relocator.relocate(skip)
    print("  relocate(skip) -> \(result.map { "\"\($0.heading.text)\" \($0.finding)" } ?? "nil (the skip waits)")")

    let outcome = relocator.relocate(PlaceRelocator.Places(position: nil, bookmarks: [], skippedHeadings: [skip]))
    let skippedIDs = Set(outcome.places.skippedHeadings.map(\.id))
    print("  saved skip IDs \(skippedIDs.sorted()); new heading's ID \"\(expected.id)\" skipped in playback: \(skippedIDs.contains(expected.id)); log: \(outcome.counts.logLine(title: "Garrow Lane"))")
}

// MARK: - The cases

// A: a one-word heading gains words right after it, as a newer extraction
// that reads a subtitle (October 3's "[]CHAPTER I." -> "CHAPTER I. Down the
// Rabbit-Hole", but with a one-word label); an earlier sentence shifts it.
run("A  one-word label gains words right after it (numbers shifted)",
    newBook: [forewordNew + "Prologue: Bolts Without Instructions\n\n" + prologueBody, chapterOne, chapterTwo, chapterThree],
    newLabels: labels(prologue: "Prologue: Bolts Without Instructions"),
    skippedLabel: "Prologue", expectedLabel: "Prologue: Bolts Without Instructions")

// B1: a heading's first word dropped ("CHAPTER II." -> "II.").
run("B1 first word dropped at a chapter's start",
    newBook: [forewordNew + "Prologue\n\n" + prologueBody, chapterOne, chapterTwo.replacingOccurrences(of: "CHAPTER II.", with: "II."), chapterThree],
    newLabels: labels(two: "II. The Compositors"),
    skippedLabel: "CHAPTER II. The Compositors", expectedLabel: "II. The Compositors")

// B2: a numbered section loses its number mid-chapter (a build that no
// longer reads list numbering: "2. An Apprentice" -> "An Apprentice").
let chapterOneUnnumbered = chapterOne.replacingOccurrences(of: "1. Auction Bills", with: "Auction Bills")
    .replacingOccurrences(of: "2. An Apprentice", with: "An Apprentice")
run("B2 numbered section loses its number mid-chapter",
    newBook: [forewordNew + "Prologue\n\n" + prologueBody, chapterOneUnnumbered, chapterTwo, chapterThree],
    newLabels: labels(bills: "Auction Bills", apprentice: "An Apprentice"),
    skippedLabel: "2. An Apprentice", expectedLabel: "An Apprentice")

// Controls: the shapes the code accepts.
run("C1 control: first word replaced ('PART II.')",
    newBook: [forewordNew + "Prologue\n\n" + prologueBody, chapterOne, chapterTwo.replacingOccurrences(of: "CHAPTER II.", with: "PART II."), chapterThree],
    newLabels: labels(two: "PART II. The Compositors"),
    skippedLabel: "CHAPTER II. The Compositors", expectedLabel: "PART II. The Compositors")
run("C2 control: two-word label gains words after its second word",
    newBook: [forewordNew + "Prologue\n\n" + prologueBody, chapterOne, chapterTwo, chapterThree.replacingOccurrences(of: "CHAPTER III.", with: "CHAPTER III. Rationing and After")],
    newLabels: labels(three: "CHAPTER III. Rationing and After"),
    skippedLabel: "CHAPTER III.", expectedLabel: "CHAPTER III. Rationing and After")
run("C3 control: the same one-word label unchanged, numbers shifted",
    newBook: [forewordNew + "Prologue\n\n" + prologueBody, chapterOne, chapterTwo, chapterThree],
    newLabels: labels(),
    skippedLabel: "Prologue", expectedLabel: "Prologue")
