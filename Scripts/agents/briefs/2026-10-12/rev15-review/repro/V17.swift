import Foundation

// V17 verifier probe (independent of the finder's angleAltitude/p7).
//
// Claim: when a new reading re-levels (or demotes to plain text) a skipped
// heading whose own text the diff proves still stands where its start lands
// (`CarriedHeading.standing`), `PlaceRelocator.relocate(_ skipped:)` finds no
// heading of the skip's level at the landing (line 333) and falls out of the
// switch with `labelRequired == false` into `TextAnchorFinder.findHeading`,
// which searches the whole book by level and label and hands the skip to
// ANOTHER section with the same label.
//
// The book: a surveying primer whose chapters each end in a level-2
// "Exercises" section. The listener skipped chapter I's exercises.

// MARK: - The texts

let chainOpening = "CHAPTER I. Chain and Offset\n\n"
let chainBody = "A surveyor's chain is sixty-six feet long and divided into one hundred links, so that ten square chains make an acre. "
    + "The chainman at the rear holds the handle over the station while the leader pulls the chain taut and pins its far end. "
    + "Offsets are measured at right angles from the chain line to each fence, ditch, or wall, and booked on the left or right of a central column.\n\n"
/// The same body after an edit early in chapter I, which shifts every offset
/// after it, so the skip's saved words no longer stand at its saved numbers
/// and the diff (not the direct check) decides.
let chainBodyEdited = chainBody.replacingOccurrences(of: "sixty-six feet long", with: "sixty-six feet (about twenty metres) long")
let chainExercises = "Exercises\n\nWork these in the field book before checking them against the tables at the back. "
    + "A hedge is chained at 12.40 chains; give its length in feet and in links. Explain why offsets longer than one chain are avoided on rough ground."

let levelOpening = "CHAPTER II. The Level and Staff\n\n"
let levelBody = "The dumpy level is set up on its tripod roughly midway between the two staff positions, so that errors in collimation cancel. "
    + "A backsight is read to the staff on a point of known height, then a foresight to the next point, and the difference gives the rise or fall between them.\n\n"
let levelExercises = "Exercises\n\nTake a backsight of 1.425 and a foresight of 2.110 and state whether the ground rises or falls, and by how much. "
    + "Describe how a two-peg test reveals a collimation error."

let traverseOpening = "CHAPTER III. The Closed Traverse\n\n"
let traverseBody = "A closed traverse returns to the station it began from, so the sum of its interior angles can be checked against the rule for a polygon. "
    + "Any misclosure in the bearings is shared out among the angles before the latitudes and departures are worked.\n\n"
let traverseExercises = "Exercises\n\nA five-sided traverse has interior angles that sum to 540 degrees and 40 seconds. "
    + "Distribute the error, and say what a misclosure of several minutes would suggest about the fieldwork."

// MARK: - Helpers

/// One chapter's reading text: opening, body, then its closing section.
func chapter(_ opening: String, _ body: String, _ closing: String) -> String { opening + body + closing }

/// The heading of `level` labelled `label` where `closingStart` begins in
/// chapter `index` (the closing section starts after opening + body).
func closingHeading(level: Int, label: String, chapter index: Int, opening: String, body: String) -> Heading {
    Heading(level: level, text: label, chapterIndex: index, characterOffset: (opening + body).utf16.count)
}

/// A level-1 chapter heading at the start of chapter `index`.
func chapterHeading(_ opening: String, _ index: Int) -> Heading {
    Heading(level: 1, text: opening.trimmingCharacters(in: .whitespacesAndNewlines), chapterIndex: index, characterOffset: 0)
}

/// Describes a heading result for the output.
func describe(_ result: PlaceRelocator.HeadingResult?) -> String {
    guard let result else { return "nil (the skip waits)" }
    return "level \(result.heading.level) \"\(result.heading.text)\" at \(result.heading.chapterIndex):\(result.heading.characterOffset) by \(result.finding)"
}

/// Describes branch A's findHeading result for the output.
func describe(_ result: TextAnchorFinder.HeadingResult?) -> String {
    guard let result else { return "nil (the skip waits)" }
    return "level \(result.heading.level) \"\(result.heading.text)\" at \(result.heading.chapterIndex):\(result.heading.characterOffset) by \(result.finding)"
}

/// Runs one scenario: prints where a PLACE at the skipped heading's start is
/// carried (the diff's own answer), the diff's proof that the heading's text
/// stands there (its first word and the word after it lined up in a row, the
/// `headingTextStands` test), what the relocator does with the SKIP, and what
/// branch A's findHeading alone does with the same saved words.
func run(_ title: String, old: [String], new: [String], newHeadings: [Heading], skipped: Heading) {
    print("== \(title)")
    let oldWords = BookWords(texts: old)
    let newWords = BookWords(texts: new)
    let saved = TextPlace(chapter: skipped.chapterIndex, offset: skipped.characterOffset)
    let anchor = TextAnchor(capturingAt: saved, in: oldWords)!
    let relocator = PlaceRelocator(oldTexts: old, newTexts: new, newHeadings: newHeadings)

    // The saved words' direct check in the new text (rule 1 / settled).
    print("  saved words stand at the saved numbers in the new text: \(anchor.stands(at: saved, in: new))")

    // Where the diff carries a place standing at the heading's start.
    let carried = relocator.relocate(anchor, savedAt: saved)
    print("  a place at the skipped heading's start is carried to \(carried.place.chapter):\(carried.place.offset) by \(carried.finding)")

    // The diff's proof that the heading's own text stands at the landing:
    // headingTextStands needs partners[word + 1] == landed + 1.
    let partners = PatienceDiff.partners(of: oldWords.keys, in: newWords.keys)
    let word = oldWords.word(at: saved)
    let landed = newWords.word(at: carried.place)
    print("  diff: old word \(word) -> new \(partners[word]); old word \(word + 1) -> new \(partners[word + 1]); landed before new word \(landed); headingTextStands = \(partners[word + 1] == landed + 1)")

    // Which new headings start where it landed, of any level.
    let atLanding = newHeadings.filter { $0.chapterIndex == carried.place.chapter && newWords.word(at: TextPlace(chapter: $0.chapterIndex, offset: $0.characterOffset)) == landed }
    print("  new headings starting at the landing: \(atLanding.map { "level \($0.level) \"\($0.text)\"" })")

    // The relocator (new in this diff) and branch A's findHeading alone.
    print("  PlaceRelocator.relocate(skip)            -> \(describe(relocator.relocate(SkippedHeading(skipped, anchor: anchor))))")
    let finder = TextAnchorFinder(words: newWords, headings: newHeadings)
    print("  TextAnchorFinder.findHeading (branch A)  -> \(describe(finder.findHeading(level: skipped.level, label: skipped.text, anchor: anchor, savedAt: saved)))")
}

// MARK: - The book, old and new

let oldTwo = [chapter(chainOpening, chainBody, chainExercises), chapter(levelOpening, levelBody, levelExercises)]
let newTwo = [chapter(chainOpening, chainBodyEdited, chainExercises), chapter(levelOpening, levelBody, levelExercises)]
let skippedExercisesI = closingHeading(level: 2, label: "Exercises", chapter: 0, opening: chainOpening, body: chainBody)
let newExercisesIOffset = (chainOpening + chainBodyEdited).utf16.count
let exercisesII = closingHeading(level: 2, label: "Exercises", chapter: 1, opening: levelOpening, body: levelBody)

// 1. NEW PATH: an edit early in chapter I, and the new reading makes
//    chapter I's Exercises level 3 (".standing" then fall-through).
run("1. re-levelled to 3, edit before it (the .standing fall-through)",
    old: oldTwo, new: newTwo,
    newHeadings: [chapterHeading(chainOpening, 0),
                  Heading(level: 3, text: "Exercises", chapterIndex: 0, characterOffset: newExercisesIOffset),
                  chapterHeading(levelOpening, 1), exercisesII],
    skipped: skippedExercisesI)

// 2. NEW PATH: same edit, the new reading demotes chapter I's Exercises to
//    plain text (no heading there at all).
run("2. demoted to text, edit before it (the .standing fall-through)",
    old: oldTwo, new: newTwo,
    newHeadings: [chapterHeading(chainOpening, 0), chapterHeading(levelOpening, 1), exercisesII],
    skipped: skippedExercisesI)

// 3. NEW PATH, three chapters: two other "Exercises" sections, so findHeading
//    falls to its nearest-with-its-label guess.
let oldThree = oldTwo + [chapter(traverseOpening, traverseBody, traverseExercises)]
let newThree = newTwo + [chapter(traverseOpening, traverseBody, traverseExercises)]
run("3. re-levelled to 3, edit before it, two other Exercises sections",
    old: oldThree, new: newThree,
    newHeadings: [chapterHeading(chainOpening, 0),
                  Heading(level: 3, text: "Exercises", chapterIndex: 0, characterOffset: newExercisesIOffset),
                  chapterHeading(levelOpening, 1), exercisesII,
                  chapterHeading(traverseOpening, 2),
                  closingHeading(level: 2, label: "Exercises", chapter: 2, opening: traverseOpening, body: traverseBody)],
    skipped: skippedExercisesI)

// Control A: same edit, level kept at 2: the .standing path finds it (right).
run("A. control: level kept at 2, edit before it",
    old: oldTwo, new: newTwo,
    newHeadings: [chapterHeading(chainOpening, 0),
                  Heading(level: 2, text: "Exercises", chapterIndex: 0, characterOffset: newExercisesIOffset),
                  chapterHeading(levelOpening, 1), exercisesII],
    skipped: skippedExercisesI)

// Control B: re-levelled, edit before it, but chapter II's section is
// labelled "Problems": nothing else has the label, so the skip waits.
let problemsII = "Problems\n\n" + levelExercises.dropFirst("Exercises\n\n".count)
run("B. control: re-levelled, edit before it, no other section labelled Exercises",
    old: [chapter(chainOpening, chainBody, chainExercises), chapter(levelOpening, levelBody, problemsII)],
    new: [chapter(chainOpening, chainBodyEdited, chainExercises), chapter(levelOpening, levelBody, problemsII)],
    newHeadings: [chapterHeading(chainOpening, 0),
                  Heading(level: 3, text: "Exercises", chapterIndex: 0, characterOffset: newExercisesIOffset),
                  chapterHeading(levelOpening, 1),
                  closingHeading(level: 2, label: "Problems", chapter: 1, opening: levelOpening, body: levelBody)],
    skipped: skippedExercisesI)

// Control C (branch A's own path, NOT the .standing fall-through): no edit
// before it, so the saved words stand at the saved numbers; settled != nil,
// carriedHeadingStart is nil, and findHeading decides alone (its direct
// check needs level 2 there, finds level 3, and moves on).
run("C. re-levelled to 3, NO edit before it (case nil: findHeading alone)",
    old: oldTwo, new: oldTwo,
    newHeadings: [chapterHeading(chainOpening, 0),
                  Heading(level: 3, text: "Exercises", chapterIndex: 0, characterOffset: skippedExercisesI.characterOffset),
                  chapterHeading(levelOpening, 1), exercisesII],
    skipped: skippedExercisesI)

// MARK: - What the caller would store (scenario 1, whole book)

// The whole-book move a rebuild runs (branch D's caller will save
// `outcome.places`): the stored skip and the debug log's line.
do {
    print("== 1W. scenario 1 through relocate(Places): the skip a caller would save")
    let newHeadings = [chapterHeading(chainOpening, 0),
                       Heading(level: 3, text: "Exercises", chapterIndex: 0, characterOffset: newExercisesIOffset),
                       chapterHeading(levelOpening, 1), exercisesII]
    let saved = TextPlace(chapter: 0, offset: skippedExercisesI.characterOffset)
    let anchor = TextAnchor(capturingAt: saved, in: BookWords(texts: oldTwo))!
    let skip = SkippedHeading(skippedExercisesI, anchor: anchor)
    let outcome = PlaceRelocator(oldTexts: oldTwo, newTexts: newTwo, newHeadings: newHeadings)
        .relocate(PlaceRelocator.Places(position: nil, bookmarks: [], skippedHeadings: [skip]))
    print("  skip saved before: \(skip.id)")
    print("  skip saved after:  \(outcome.places.skippedHeadings.map(\.id))  finding \(outcome.skippedHeadingFindings)")
    print("  isGuess: \(outcome.skippedHeadingFindings.first??.isGuess ?? true)")
    print("  log: \(outcome.counts.logLine(title: "Surveying Primer"))")

    // A later rebuild whose reading restores chapter I's Exercises to level
    // 2: the stored skip now carries chapter II's words, so it stays there.
    let restored = [chapterHeading(chainOpening, 0),
                    Heading(level: 2, text: "Exercises", chapterIndex: 0, characterOffset: newExercisesIOffset),
                    chapterHeading(levelOpening, 1), exercisesII]
    let again = PlaceRelocator(oldTexts: newTwo, newTexts: newTwo, newHeadings: restored)
        .relocate(outcome.places)
    print("  next rebuild, chapter I's Exercises level 2 again: \(again.places.skippedHeadings.map(\.id))  finding \(again.skippedHeadingFindings)")
}
