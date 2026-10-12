import Foundation

/// Moves a book's saved places from its old text to its new one (T06):
/// reading positions, bookmarks, and skipped headings, when TextMouth
/// rebuilds the book's text while the old text is still at hand (a rebuild
/// of the text cache, Edit Text). Pure: the caller reads both texts, and
/// writes back what moved.
///
/// The old text is the old content.md as this build reads it, which need
/// not be the text the places were saved in: an older build may have read
/// the same file differently (TEXT-ANCHORS-ADDENDUM-2026-10-10.md, section
/// 1, "What a snapshot can hold"). So a place is first found in the old
/// text, and only then carried across.
///
/// For each place, in order (the measured rules, addendum sections 1 and 9):
///
/// 1. **The end of the book, and the direct check** (`TextAnchorFinder.settled`):
///    a place at the end of the book stays at the end of the new one (P07),
///    and a place whose saved words still stand exactly around its saved
///    numbers in the new text stays. Saved words that hold no word (a place
///    in a chapter without words, or an anchor read back empty) stand
///    anywhere, so they are no evidence by themselves: such a place stays
///    only when the old text and the diff put it back where it was.
/// 2. **The old text.** The place is found in the old text: at its numbers
///    when its saved words stand there, or else by its saved words, for
///    certain. A place saved without words is taken to stand at its numbers
///    there, held within that text as the reader opens a saved place
///    (`TextPlace.opening`: a chapter past the last at the last chapter's
///    start, or at the end only when its offset in the whole book was at
///    the end), and its words are read there.
/// 3. **The diff.** The old text's words are lined up with the new text's by
///    a patience diff (`PatienceDiff`) over fine words (`FineWords`), once
///    for the whole book, and the place is carried across:
///    - **A solid match:** the place's word, lined up within 4 or more words
///      in a row lined up alike, is there.
///    - **A place keeps the words that follow it:** when its match is weak,
///      or its run breaks before the next solid match, and every old word
///      from it to that match stands in order just before that match (a few
///      words put in among them allowed), it goes to its own word there. So
///      text put in before a place that begins with the place's own words
///      ("CHAPTER" before "CHAPTER XIX." when chapter XVIII comes back, or
///      "BOOK ONE. CHAPTER" before "BOOK ONE. CHAPTER III.") does not take
///      it, as Git slides a change to a better boundary. A kept place never
///      jumps back across a solid match, nor before its own.
///    - **A like-for-like stretch** (as long in both texts, give or take,
///      between solid matches) is local editing: the place's own word if it
///      is lined up there, else just after the nearest lined-up word before
///      it. A stretch the diff left unmatched for its size (a long
///      repetitive passage) is not: the diff can only suppose the place is
///      at the same share of it in the new text, an unsure answer.
///    - **Words gone:** after a removal, the place goes where the text after
///      the removal begins, slid back over words the removal ends with that
///      also end the text before it, as Git slides a change, though never
///      out of the chapter where the text after the removal begins; in a
///      replaced stretch, where what replaced it begins.
///    - **Moved text:** a place whose words are gone from their spot follows
///      them, however far, when its saved words' one best spot in the new
///      text holds its own word (the first after it) and lies in text the
///      diff found put in: text that moved is a removal there and the same
///      words put in here. The words before a place alone say only where
///      the text before it went. Words met in text the
///      diff kept (a refrain's other verse, a second contents list) are a
///      second copy, and the place stays with the diff.
///    - **The end:** a place at the end of the old text goes to the end of
///      the new one (P07); a place short of the end, however near, is not
///      the end (`TextPlace.restsAtEnd`). A place with no word after it in
///      its chapter stays at the end of that chapter in the new text: just
///      after the chapter's last word when that is a solid match, as the
///      saved-words search lands it, else at the end of the new chapter that
///      holds the chapter's last solid match, so a chapter restored after it
///      does not take it, though the chapter's last words were edited or
///      match the restored chapter's.
///    - **Chapters without words:** a place in a chapter without words (a
///      cover, a plate, "* * *") goes to the chapter without words, in the
///      same order, between where its neighbours with words went; failing
///      one, to the start of the chapter after where the one before it went.
/// 4. **The saved words.** What the diff cannot decide goes to the saved
///    words' search in the new text (`TextAnchorFinder`), except that a weak
///    match far from the diff's own unsure answer does not overrule it.
/// 5. **A best guess, silently:** the diff's own answer when it was unsure,
///    else the saved words' guess (the nearest of equal spots, the spot near
///    where the place was, or the same share of its chapter).
///
/// A reading position at the very start of the book (never begun, or begun
/// over) stays at the start of the new text, whatever was put in before its
/// old first words, as the end of the book stays the end; a bookmark there
/// follows its words like any other.
///
/// A skipped heading is found first in the old text, by the heading its ID
/// names there, or by its level and label when only one heading has them
/// (or at its place, where its saved words still stand exactly); never by
/// its saved words alone, nor at its numbers alone. That heading's start is
/// carried like a place, and a new heading there takes the skip when the
/// diff's account proves it the same section: no other old heading that
/// lent it words, or whose section goes on in it, has a label more like its
/// own, or as like with its section going on there instead; and its label
/// is the skip's, or most of the old heading's words went into it. Among
/// several, the label decides. Failing that, the one new heading of its level with its label
/// takes the skip, unless the diff makes it another section; failing that,
/// the skip waits, applying to no heading, so no section is skipped by
/// mistake. A guess never moves a skip onto a heading.
///
/// These are the measured program's rules, ported and checked against its
/// exact truth by compiling these files in a standalone harness: every place
/// of the real extraction changes on its own words (57,472 places in 26
/// comparisons), and of 222,037 places in the synthetic cases, 161 on wrong
/// words (142 of them in moved paragraphs) and 432 a few words off, exactly
/// as the program. Where a rule here differs from it, the comment at the
/// rule says why.
///
/// The relocator is built once per rebuild of a book's text, off the main
/// thread: it reads both texts' words, lines them up, and indexes each
/// text's words. In optimized code that took about 20 ms for a novel of
/// 750,000 UTF-16 units and 100 to 130 ms for a book of 3.8 million, holding
/// 25 to 130 MB with the texts; moving a place then takes a few
/// microseconds. Nothing is said or shown; the counts go to the debug log
/// (`Counts.logLine`).
struct PlaceRelocator: Sendable {
    // MARK: - What a Move Comes To

    /// How a place was moved.
    enum Finding: Equatable, Sendable {
        /// Its saved words still stand exactly around its saved numbers in
        /// the new text, so it stays (for a skipped heading: its heading
        /// still starts there, with its label).
        case unchanged
        /// Carried across by the diff of the old text with the new, for
        /// `DiffEvidence`.
        case movedByTheDiff(DiffEvidence)
        /// The diff could not decide, and the saved words found it for
        /// certain in the new text, by `TextAnchorFinder.Evidence` (its saved
        /// words, or for a skipped heading the one heading of its level with
        /// its label).
        case foundBySavedWords(TextAnchorFinder.Evidence)
        /// A best guess, made silently, for the `Guess` reason.
        case guessed(Guess)

        /// Whether the place is a best guess.
        var isGuess: Bool {
            if case .guessed = self { return true }
            return false
        }
    }

    /// What carried a place across by the diff.
    enum DiffEvidence: Equatable, Sendable {
        /// Its word lined up with a word of the new text (for a place at its
        /// chapter's end, the word before it did).
        case linedUp
        /// Its word was replaced or dropped in local editing (a stretch about
        /// as long in both texts): it goes just after the nearest lined-up
        /// word before it, where what replaced its word begins. (For a place
        /// at its chapter's end whose chapter's last word is no solid match,
        /// edited or lined up only by chance: it goes to the end of its
        /// chapter in the new text.)
        case wordReplaced
        /// Its words went with a longer passage the new text removed or
        /// replaced: it goes where the text after the removal begins, or
        /// where what replaced the passage begins.
        case passageRemoved
        /// Its words moved: the diff found them gone from their spot, and
        /// its saved words' one best spot lies in text the diff found put in.
        case followedMovedText
        /// It was at the end of the book (its saved words mark the end, or it
        /// stood at the old text's end, `TextPlace.restsAtEnd`), and it stays
        /// at the end of the new text, whatever was added or removed there
        /// (P07).
        case endOfBook
        /// It was a reading position at the very start of the book (never
        /// begun, or begun over), and it stays at the start of the new text,
        /// whatever was put in before its old first words, which were not
        /// yet heard either.
        case startOfBook
    }

    /// Why a place's spot is a best guess.
    enum Guess: Equatable, Sendable {
        /// The diff's own answer where it was unsure (a removal at an edge of
        /// the book, with solid matches on one side only, or a stretch it
        /// left unmatched for its size), when the saved words found nothing
        /// surer.
        case diffUnsure
        /// The saved words' own guess (`TextAnchorFinder.Guess`).
        case savedWords(TextAnchorFinder.Guess)
    }

    /// Where a saved place is in the new text, and how it was found.
    struct Result: Equatable, Sendable {
        /// Where the place is now.
        let place: TextPlace
        /// How it was found.
        let finding: Finding
    }

    /// The heading a skipped heading names in the new text, and how it was
    /// found.
    struct HeadingResult: Equatable, Sendable {
        /// The heading, with its label as the new text gives it.
        let heading: Heading
        /// How it was found.
        let finding: Finding
    }

    // MARK: - The Rules' Numbers

    /// How many words in a row, each lined up just after the one before,
    /// make a solid match. A lone match is often a common word ("the",
    /// "and") paired by chance inside text the new version removed or
    /// rewrote.
    static let solidRun = 4
    /// The most old words between a place and the next solid match across
    /// which the place keeps the words that follow it.
    static let keepingLimit = 64
    /// How many new words put in among those words the rule allows, besides
    /// a quarter of their number.
    static let keepingSlack = 4
    /// How many times longer one side of a changed stretch may be than the
    /// other, `likeForLikeSlack` words more, and the stretch still be like
    /// for like.
    static let likeForLikeFactor = 2
    /// See `likeForLikeFactor`.
    static let likeForLikeSlack = 8
    /// The saved words' score (2 a word after the place, 1 a word before
    /// it; about 30 at most) that overrules the diff's unsure answer from
    /// however far away.
    static let strongScore = 20
    /// How many words from the diff's unsure answer a weaker find of the
    /// saved words may lie and still be taken.
    static let nearTheDiff = 500

    // MARK: - The Two Texts

    /// The old text's words: the old content.md as this build reads it.
    let old: BookWords
    /// The new text's words.
    let new: BookWords
    /// The old text's headings, in order: where a skipped heading's
    /// heading is found first.
    let oldHeadings: [Heading]
    /// The new text's headings, in order.
    let newHeadings: [Heading]
    /// For each old word, the index of the new word the diff lines it up
    /// with, or -1 (`PatienceDiff`).
    private let partners: [Int]
    /// For each old word, whether the diff left it unmatched for its
    /// stretch's size (`PatienceDiff.Alignment.leftForSize`).
    private let leftForSize: [Bool]
    /// For each new word, the index of the old word the diff lines up with
    /// it, or -1: a new word without one is text the diff found put in.
    private let sources: [Int]
    /// Each old heading's own words (`ownWords(of:in:)`), in the order of
    /// `oldHeadings`.
    private let oldHeadingWords: [Range<Int>]
    /// The saved-words search in the old text, for a place whose words do
    /// not stand at its numbers there.
    private let oldFinder: TextAnchorFinder
    /// The saved-words search in the new text.
    private let newFinder: TextAnchorFinder

    /// A relocator from the book `old` reads, whose headings are
    /// `oldHeadings`, to the book `new` reads, whose headings are
    /// `newHeadings`: it lines the two up by the diff once, and indexes each
    /// one's words for the saved-words search.
    init(old: BookWords, new: BookWords, oldHeadings: [Heading] = [], newHeadings: [Heading] = []) {
        let alignment = PatienceDiff.alignment(of: old.keys, in: new.keys)
        let partners = alignment.partners
        var sources = [Int](repeating: -1, count: new.count)
        for (word, partner) in partners.enumerated() where partner >= 0 && partner < sources.count {
            sources[partner] = word
        }
        self.old = old
        self.new = new
        self.oldHeadings = oldHeadings
        self.newHeadings = newHeadings
        self.oldHeadingWords = oldHeadings.map { Self.ownWords(of: $0, in: old) }
        self.partners = partners
        self.leftForSize = alignment.leftForSize
        self.sources = sources
        self.oldFinder = TextAnchorFinder(words: old)
        self.newFinder = TextAnchorFinder(words: new)
    }

    /// A relocator from a book whose chapters' reading texts were `oldTexts`,
    /// with `oldHeadings`, to one whose are `newTexts`, with `newHeadings`.
    init(oldTexts: [String], newTexts: [String], oldHeadings: [Heading] = [], newHeadings: [Heading] = []) {
        self.init(old: BookWords(texts: oldTexts), new: BookWords(texts: newTexts), oldHeadings: oldHeadings, newHeadings: newHeadings)
    }

    /// A relocator from a loaded book's old text and headings to its new
    /// text and headings.
    init(old: DocumentContent, new: DocumentContent) {
        self.init(
            oldTexts: old.chapters.map(\.text),
            newTexts: new.chapters.map(\.text),
            oldHeadings: old.allHeadings,
            newHeadings: new.allHeadings
        )
    }

    // MARK: - Moving a Place

    /// Where a place saved at `saved` with `anchor` (nil for a place saved
    /// before anchors) is in the new text, and how it was found; the rules
    /// are the type's. `savedGlobalOffset` is a reading position's offset in
    /// the whole book, which says, for a place saved without words in a
    /// chapter the old text no longer has, whether it was at the end (nil
    /// for a bookmark, which keeps none).
    func relocate(_ anchor: TextAnchor?, savedAt saved: TextPlace, savedGlobalOffset: Int? = nil) -> Result {
        let words = savedWords(anchor, savedAt: saved, savedGlobalOffset: savedGlobalOffset)
        // Rule 1: the end of the book, and the direct check. Saved words
        // that hold no word (a place in a chapter without words, or an
        // anchor read back empty) stand anywhere, so the direct check alone
        // is no evidence for them: the old text and the diff place such a
        // place, and it stays only when they put it back where it was. Words
        // that mark the end of the book settle it whatever they hold.
        let settled = newFinder.settled(words.anchor, savedAt: saved)
        let standsAnywhere = settled?.finding == .unchanged && !words.anchor.marksEndOfBook && Self.holdsNoWords(words.anchor)
        if let settled, !standsAnywhere {
            return Result(place: settled.place, finding: Self.finding(settled.finding))
        }
        // Rules 2 and 3: the old text, then the diff.
        var unsure: Unsure?
        if let start = words.readInOldText ?? placeInOldText(of: words.anchor, savedAt: saved) {
            switch carry(from: start, anchor: words.anchor) {
            case .placed(let result):
                return standsAnywhere && result.place == saved ? Result(place: saved, finding: .unchanged) : result
            case .unsure(let answer):
                unsure = answer
            case .undecided:
                break
            }
        }
        // Rules 4 and 5: the saved words, then a guess.
        return bySavedWords(words.anchor, savedAt: saved, unsure: unsure)
    }

    /// A place's saved words as the relocator reads them: its anchor as
    /// saved; for a place saved without one, its words read in the old text
    /// at its numbers (held within that text as the reader opens a saved
    /// place, by `savedGlobalOffset`, its offset in the whole book, when it
    /// kept one), with where they were read;
    /// and with no old text to read them in, words that hold nothing, which
    /// keep the place's numbers where its chapter still is (`TextAnchor`).
    /// (Every place the measured program moved had saved words; a place
    /// saved before anchors, which T06's branch B captures at load and at
    /// launch, can still reach a rebuild without them.)
    private func savedWords(_ anchor: TextAnchor?, savedAt saved: TextPlace, savedGlobalOffset: Int? = nil) -> SavedWords {
        if let anchor {
            return SavedWords(anchor: anchor, readInOldText: nil)
        }
        if let held = heldInOldText(saved, savedGlobalOffset: savedGlobalOffset), let read = TextAnchor(capturingAt: held, in: old, measuredIn: nil) {
            return SavedWords(anchor: read, readInOldText: held)
        }
        return SavedWords(anchor: TextAnchor(before: "", after: "", fraction: 0), readInOldText: nil)
    }

    /// Where a place saved at `saved` with `anchor` stands in the old text:
    /// at its numbers when its saved words stand there, or where they find it
    /// there for certain; nil when they find it only by a guess, or not at
    /// all. (The old text's end of the book is where an anchor marking the
    /// end stands, though rule 1 has settled such a place already.)
    private func placeInOldText(of anchor: TextAnchor, savedAt saved: TextPlace) -> TextPlace? {
        let found = oldFinder.find(anchor, savedAt: saved)
        return found.isGuess ? nil : found.place
    }

    /// `place` held within the old text as the reader opens a saved place
    /// (`TextPlace.opening`): in its chapter, no further than the chapter's
    /// end; past the last chapter, the old text's end when
    /// `savedGlobalOffset` rests at the end, else the last chapter's start;
    /// nil for an old text without chapters.
    private func heldInOldText(_ place: TextPlace, savedGlobalOffset: Int?) -> TextPlace? {
        guard old.chapterCount > 0 else { return nil }
        return place.opening(
            savedGlobalOffset: savedGlobalOffset,
            chapterCount: old.chapterCount,
            bookLength: old.totalLength,
            chapterLength: old.length(ofChapter:)
        )
    }

    // MARK: - Moving a Skipped Heading

    /// The heading a skipped heading names in the new text, and how it was
    /// found; nil when nothing names it, so the skip waits, applying to no
    /// heading, rather than skip another section and hide text the listener
    /// meant to hear. A skip moves only on proof: a guess never moves a skip
    /// onto a heading, and a skip whose heading plainly still stands,
    /// relabelled or re-levelled, keeps it.
    ///
    /// 1. **Its heading stands.** A new heading with its ID (its level,
    ///    label, and place) is it, unchanged, when the skip's saved words, if
    ///    it has them, still stand at its place.
    /// 2. **Its heading in the old text** (`oldHeading(of:)`): the heading its
    ///    ID names there; else the one old heading of its level with its
    ///    label; else the old heading of its level at its place where its
    ///    saved words still stand exactly (the same heading, labelled anew by
    ///    this build's reading). Never by its saved words alone, nor at its
    ///    numbers alone: a skip saved before T06, rebuilt from an ID that
    ///    names nothing now, would take whatever heading stands there.
    /// 3. **The diff** (`carried(_:label:level:)`): that heading's start is
    ///    carried like a place, and a new heading there is it when the diff's
    ///    account of the new heading's own words proves it the same section
    ///    (`isSameSection`). Among several proven, the one with the skip's
    ///    label, then with its level, then the first. A heading re-levelled
    ///    by a new reading (Edit Text's "##" become "###", or a PDF's font
    ///    sizes read anew) keeps its skip at its new level, as a relabelled
    ///    one takes its new label: the listener skipped that section, and the
    ///    new reading only names it anew.
    /// 4. **Its label.** Failing that, the one new heading of its level with
    ///    its label, unless the diff's account makes it another section
    ///    (another chapter's "Notes", whose words the diff lined up with that
    ///    chapter's own "Notes").
    ///
    /// The measured rules carried a skip by its saved words and judged a
    /// heading's text by the one old word after its first; no measured case
    /// had a skipped heading in changed text. REV15 found that those rules
    /// handed a skip to the next section, to another chapter's section of
    /// the same label, or to the first of a pile of headings, and dropped
    /// the skip of a heading whose label gained or lost a word.
    func relocate(_ skipped: SkippedHeading) -> HeadingResult? {
        let saved = TextPlace(chapter: skipped.chapterIndex, offset: skipped.characterOffset)
        // 1. Its heading stands.
        if let same = newHeadings.first(where: { $0.id == skipped.id }),
           skipped.anchor.map({ $0.stands(at: saved, in: new.texts) }) ?? true {
            return HeadingResult(heading: same, finding: .unchanged)
        }
        // 2 and 3. Its heading in the old text, carried by the diff.
        let oldIndex = oldHeading(of: skipped)
        if let oldIndex, let carried = carried(oldIndex, label: skipped.label, level: skipped.level) {
            return carried
        }
        // 4. Its label.
        let labelled = newHeadings.filter { $0.level == skipped.level && $0.text == skipped.label }
        guard labelled.count == 1, let only = labelled.first, isSameSection(only, as: oldIndex, label: skipped.label) else { return nil }
        return HeadingResult(heading: only, finding: .foundBySavedWords(.onlyHeadingWithItsLabel))
    }

    /// The index in `oldHeadings` of a skipped heading's heading in the old
    /// text (rule 2 of `relocate(_:)` for a skipped heading): the heading its
    /// ID names there; else the one old heading of its level with its label,
    /// or, of several with them (a title page's lines printed again at the
    /// book's end), the one where the words saved with the skip find it for
    /// certain; else the old heading of its level that starts at its place,
    /// where the words saved with the skip (not words read there) still
    /// stand exactly, so its numbers are not stale; nil when none is.
    private func oldHeading(of skipped: SkippedHeading) -> Int? {
        if let named = oldHeadings.firstIndex(where: { $0.id == skipped.id }) { return named }
        let labelled = oldHeadings.indices.filter { oldHeadings[$0].level == skipped.level && oldHeadings[$0].text == skipped.label }
        if labelled.count == 1 { return labelled.first }
        let saved = TextPlace(chapter: skipped.chapterIndex, offset: skipped.characterOffset)
        guard let anchor = skipped.anchor, !Self.holdsNoWords(anchor) else { return nil }
        if labelled.count > 1 {
            let found = oldFinder.find(anchor, savedAt: saved)
            return found.isGuess ? nil : labelled.first { Self.start(of: oldHeadings[$0]) == found.place }
        }
        guard anchor.stands(at: saved, in: old.texts) else { return nil }
        return oldHeadings.indices.first { oldHeadings[$0].level == skipped.level && Self.start(of: oldHeadings[$0]) == saved }
    }

    /// Where `heading` starts.
    private static func start(of heading: Heading) -> TextPlace {
        TextPlace(chapter: heading.chapterIndex, offset: heading.characterOffset)
    }

    /// The new heading the old heading at `oldIndex` is by the diff (rule 3
    /// of `relocate(_:)` for a skipped heading): its start carried like a
    /// place, and among the new headings in the chapter where it lands that
    /// start at the word it lands on, or whose own words take that word in,
    /// those the diff's account proves the same section (`isSameSection`):
    /// the one with `label`, then with `level`, then the first. Nil when its
    /// start is not carried for certain (a cover's heading, with no word
    /// after its start in its chapter, so that the next word carried would
    /// be another heading's; or a start the diff is unsure of), or when no
    /// heading there is proven.
    private func carried(_ oldIndex: Int, label: String, level: Int) -> HeadingResult? {
        let heading = oldHeadings[oldIndex]
        let start = Self.start(of: heading)
        let word = old.word(at: start)
        guard word < old.count, old.chapter(ofWord: word) == heading.chapterIndex,
              let anchor = TextAnchor(capturingAt: start, in: old),
              case .placed(let result) = carry(from: start, anchor: anchor)
        else { return nil }
        let landed = new.word(at: result.place)
        guard landed < new.count else { return nil }
        let chapter = new.chapter(ofWord: landed)
        let proven = newHeadings.filter { candidate in
            guard candidate.chapterIndex == chapter else { return false }
            let own = Self.ownWords(of: candidate, in: new)
            return (own.lowerBound == landed || own.contains(landed)) && isSameSection(candidate, as: oldIndex, label: label)
        }
        let chosen = proven.first { $0.text == label && $0.level == level }
            ?? proven.first { $0.text == label }
            ?? proven.first { $0.level == level }
            ?? proven.first
        return chosen.map { HeadingResult(heading: $0, finding: result.finding) }
    }

    /// Whether the new heading `heading` is the section of the old heading
    /// at `oldIndex` (nil for a skip whose heading the old text does not
    /// have), by the diff's account (rule 3 of `relocate(_:)` for a skipped
    /// heading): no rival old heading makes a better claim to it, and either
    /// its label is the skip's, `label`, or more than half of the old
    /// heading's own words went into its own words (`ownWords(of:in:)`).
    ///
    /// A rival is another old heading that lent the new heading words of
    /// its own label, or whose section goes on in it (`sectionGoesOn`). A
    /// rival whose label is more like the new heading's (by words shared in
    /// order, `commonWords`) claims it; one whose label is as like claims it
    /// unless the old heading's section goes on in it and the rival's does
    /// not; one whose label is less like does not.
    ///
    /// So "BOOK ONE. CHAPTER III." is not the section of "BOOK ONE. CHAPTER
    /// II.", left out, though the diff lined up "BOOK ONE. CHAPTER" of the
    /// two: III's heading, whose label is its own, lent it "III"; nor "Notes
    /// on the Soup" that of "Notes on the Pump"; nor the "Notes" that slid
    /// into a removed "Notes" section's numbers that of the removed one,
    /// though the diff lined their words up: the section that goes on in it
    /// is the second's. Nor is an interlude that replaced a chapter its
    /// section, though the diff paired a word of the two by chance. But
    /// "CHAPTER V." is still the section of "CHAPTER V." when chapter IV,
    /// left out before it, lent it its "CHAPTER"; "Prologue: Before the
    /// Spring Flood" is the section of "Prologue"; and "III. The Stones"
    /// that of "CHAPTER III. The Stones". One word after a heading's first
    /// is not enough to decide.
    private func isSameSection(_ heading: Heading, as oldIndex: Int?, label: String) -> Bool {
        let own = Self.ownWords(of: heading, in: new)
        let labelWords = FineWords.keys(in: heading.text)
        let likeness = { (index: Int) in Self.commonWords(FineWords.keys(in: self.oldHeadings[index].text), labelWords) }
        let ownLikeness = oldIndex.map(likeness) ?? 0
        let ownGoesOn = oldIndex.map { sectionGoesOn(from: $0, into: own) } ?? false
        for rival in oldHeadings.indices where rival != oldIndex {
            let lent = own.contains { sources[$0] >= 0 && oldHeadingWords[rival].contains(sources[$0]) }
            let rivalGoesOn = sectionGoesOn(from: rival, into: own)
            guard lent || rivalGoesOn else { continue }
            let rivalLikeness = likeness(rival)
            if rivalLikeness > ownLikeness || (rivalLikeness == ownLikeness && !(ownGoesOn && !rivalGoesOn)) {
                return false
            }
        }
        if heading.text == label { return true }
        guard let oldIndex else { return false }
        let oldOwn = oldHeadingWords[oldIndex]
        let carriedIn = oldOwn.filter { own.contains(partners[$0]) }.count
        return 2 * carriedIn > oldOwn.count
    }

    /// Whether the section of the old heading at `oldIndex` goes on in the
    /// new heading whose own words are `newOwn`: the words that follow the
    /// old heading's own words (`solidRun` of them, or as many as its
    /// chapter has) line up, in order, with the words that follow the new
    /// heading's.
    private func sectionGoesOn(from oldIndex: Int, into newOwn: Range<Int>) -> Bool {
        let after = oldHeadingWords[oldIndex].upperBound
        let chapter = oldHeadings[oldIndex].chapterIndex
        guard chapter >= 0, chapter < old.chapterCount else { return false }
        let count = min(Self.solidRun, old.chapterFirstWords[chapter + 1] - after)
        guard count > 0 else { return false }
        return (0..<count).allSatisfy { partners[after + $0] == newOwn.upperBound + $0 }
    }

    /// How many words two labels' words share in order: their longest
    /// common subsequence (`PatienceDiff.lineUpExactly`).
    private static func commonWords(_ first: [UInt64], _ second: [UInt64]) -> Int {
        var partners = [Int](repeating: -1, count: first.count)
        PatienceDiff.lineUpExactly(first, first.indices, second, second.indices, into: &partners)
        return partners.filter { $0 >= 0 }.count
    }

    /// The words of `heading`'s label as they stand at its start in the text
    /// `words` reads: from the first word at or after its start, as long as
    /// they agree in order with the label's fine words, within its chapter
    /// (`TextAnchorFinder.maximumQuoteWords` at most). Empty, at that first
    /// word, for a heading whose label the text does not hold there (a
    /// cover's, or one of a pile of headings before the same words).
    private static func ownWords(of heading: Heading, in words: BookWords) -> Range<Int> {
        let start = words.word(at: Self.start(of: heading))
        guard heading.chapterIndex >= 0, heading.chapterIndex < words.chapterCount else { return start..<start }
        let chapterEnd = words.chapterFirstWords[heading.chapterIndex + 1]
        var end = start
        for key in FineWords.keys(in: heading.text).prefix(TextAnchorFinder.maximumQuoteWords) {
            guard end < chapterEnd, words.keys[end] == key else { break }
            end += 1
        }
        return start..<end
    }

    // MARK: - The Diff's Rules

    /// What the diff makes of a place.
    private enum Carried {
        /// The diff placed it.
        case placed(Result)
        /// The diff's own answer, unsure: a guess unless the saved words find
        /// something surer.
        case unsure(Unsure)
        /// The diff found nothing to go by.
        case undecided
    }

    /// The diff's unsure answer for a place: the new word it stands before,
    /// and where it lands there.
    private struct Unsure {
        let word: Int
        let place: TextPlace
    }

    /// Carries a place standing at `start` in the old text across to the new
    /// text by the diff (rule 3); `anchor` is its saved words, for the
    /// moved-text rule.
    private func carry(from start: TextPlace, anchor: TextAnchor) -> Carried {
        // A text without words (an extraction that read none) says nothing
        // of where a place was. (The measured program sent every place in an
        // old text without words to the new text's end; it met none.)
        guard old.count > 0, new.count > 0 else { return .undecided }
        // A place at the end of the old text goes to the end of the new one
        // (P07). A place short of the end, however near, is not the end
        // (`TextPlace.restsAtEnd`), though nothing but a closing full stop,
        // or chapters without words, follow it.
        if TextPlace.restsAtEnd(globalOffset: old.globalOffset(of: start), bookLength: old.totalLength) {
            return .placed(Result(place: new.endPlace, finding: .movedByTheDiff(.endOfBook)))
        }
        let word = old.word(at: start)
        // No word follows the place in its own chapter: the word after it,
        // if any, begins a later chapter.
        if word >= old.count || old.chapter(ofWord: word) != start.chapter {
            return atChapterEnd(start)
        }
        // A place inside a word (as a bookmark nudged clear of another can
        // be) keeps how far into it it was, as the saved-words search keeps
        // it, when it lands on its own word lined up; the measured program
        // moved it to the word's start. Anywhere else (where what replaced
        // its word or passage begins, or the diff's unsure answer) it lands
        // at a word's start: another word that merely has the same key ("The"
        // beginning the text after a removal, for a place inside "the") is
        // not its word.
        let inside: (key: UInt64, offset: Int)? = old.starts[word] < start.offset
            ? (old.keys[word], start.offset - old.starts[word])
            : nil
        let landing = { (newWord: Int) in self.new.start(ofWord: newWord) }
        let gone: (newWord: Int, evidence: DiffEvidence, sure: Bool)
        switch verdict(forOldWord: word) {
        case .linedUp(let newWord):
            let place = new.landing(beforeWord: newWord, inside: inside)
            return .placed(Result(place: place, finding: .movedByTheDiff(.linedUp)))
        case .replaced(let newWord):
            gone = (newWord, .wordReplaced, true)
        case .removed(let newWord, let sure):
            gone = (newWord, .passageRemoved, sure)
        case .unlined(let newWord):
            return .unsure(Unsure(word: newWord, place: landing(newWord)))
        case .undecided:
            return .undecided
        }
        // Its words are gone from their spot. Moved text: the saved words'
        // one best spot, however far, in text the diff found put in.
        if let moved = newFinder.onlyBestSpot(for: anchor), isPutIn(moved.word) {
            return .placed(Result(place: moved.place, finding: .movedByTheDiff(.followedMovedText)))
        }
        guard gone.sure else { return .unsure(Unsure(word: gone.newWord, place: landing(gone.newWord))) }
        return .placed(Result(place: landing(gone.newWord), finding: .movedByTheDiff(gone.evidence)))
    }

    /// Carries a place standing at `start` in the old text with no word
    /// after it in its chapter (at the chapter's end, or before nothing but
    /// punctuation there): it stands just after the chapter's last word, and
    /// stays at the end of its chapter in the new text, so a chapter
    /// restored after it does not take it (rule 3, the end).
    ///
    /// When the chapter's last word is a solid match (by its run within the
    /// chapter), the place lands just after its partner: at the end of its
    /// chapter, or before what was
    /// added after it there. The saved-words search lands such a place the
    /// same way (`BookWords.landing`). Otherwise the chapter's last words
    /// were edited ("…went home." became "…went away."), or its last word is
    /// lined up only by chance, as with the like last word of a chapter
    /// restored after it ("…to come home."): the place goes to the end of
    /// the new chapter that holds the chapter's last solid match. The
    /// measured program carried the next chapter's first word instead, and
    /// so put such a place at the next chapter's start (it sampled none).
    /// A chapter with no solid match is left to the saved words.
    private func atChapterEnd(_ start: TextPlace) -> Carried {
        let first = old.chapterFirstWords[start.chapter]
        let last = old.chapterFirstWords[start.chapter + 1] - 1
        guard last >= first else { return inChapterWithoutWords(start) }
        // The chapter's last solid match, by runs within the chapter: the
        // common end of a restored chapter and the next ("…come home." and
        // "CHAPTER III.") lines the chapter's last word up with the restored
        // chapter's, in a run that is solid only past the chapter's end.
        var solid = last
        while solid >= first, !isSolid(solid, within: first..<(last + 1)) { solid -= 1 }
        guard solid >= first else { return .undecided }
        if solid == last {
            return .placed(Result(place: new.landing(beforeWord: partners[last] + 1, nothingAfter: true), finding: .movedByTheDiff(.linedUp)))
        }
        let chapter = new.chapter(ofWord: partners[solid])
        return .placed(Result(place: TextPlace(chapter: chapter, offset: new.length(ofChapter: chapter)), finding: .movedByTheDiff(.wordReplaced)))
    }

    /// Carries a place standing at `start` in a chapter without words (a
    /// cover, a plate, an ornament page "* * *", an image page an older
    /// build read as "[]") to the chapter of the new text that matches it:
    /// among the chapters without words between where the diff carries its
    /// neighbours with words (the end of the one before it, the start of
    /// the one after), the one in the same order, at its offset held within
    /// it. With none there (its page left out), it goes to the start of the
    /// chapter after where the one before it went, so that a chapter
    /// restored there is not skipped, or where the text after it begins
    /// (rule 3, chapters without words). The measured program met no such
    /// place.
    private func inChapterWithoutWords(_ start: TextPlace) -> Carried {
        // The first word after the chapter (the next chapter with words
        // begins with it), or the number of words when none follows.
        let nextWord = old.chapterFirstWords[start.chapter]
        let chapterBefore = nextWord > 0 ? old.chapter(ofWord: nextWord - 1) : -1
        // Where the chapter before it ends in the new text.
        var newBefore = -1
        if chapterBefore >= 0 {
            let end = TextPlace(chapter: chapterBefore, offset: old.length(ofChapter: chapterBefore))
            guard case .placed(let carried) = atChapterEnd(end) else { return .undecided }
            newBefore = carried.place.chapter
        }
        // Where the chapter after it begins in the new text.
        var newAfter = new.chapterCount
        var afterWord: Int?
        if nextWord < old.count {
            switch verdict(forOldWord: nextWord) {
            case .linedUp(let word), .replaced(let word), .removed(let word, sure: true):
                afterWord = word
                newAfter = word < new.count ? new.chapter(ofWord: word) : new.chapterCount
            case .removed, .unlined, .undecided:
                return .undecided
            }
        }
        // Its own chapter among the chapters without words between them.
        let rank = start.chapter - chapterBefore - 1
        let between = newBefore + 1 < newAfter ? Array((newBefore + 1)..<newAfter) : []
        let withoutWords = between.filter { new.chapterFirstWords[$0] == new.chapterFirstWords[$0 + 1] }
        if !withoutWords.isEmpty {
            let chapter = withoutWords[min(rank, withoutWords.count - 1)]
            let offset = min(max(start.offset, 0), new.length(ofChapter: chapter))
            return .placed(Result(place: TextPlace(chapter: chapter, offset: offset), finding: .movedByTheDiff(.linedUp)))
        }
        if let first = between.first {
            return .placed(Result(place: TextPlace(chapter: first, offset: 0), finding: .movedByTheDiff(.passageRemoved)))
        }
        guard let afterWord else { return .undecided }
        return .placed(Result(place: new.start(ofWord: afterWord), finding: .movedByTheDiff(.passageRemoved)))
    }

    /// What the diff says of one old word.
    private enum Verdict {
        /// It lines up with this new word.
        case linedUp(Int)
        /// It was replaced or dropped in local editing: a place before it
        /// goes before this new word.
        case replaced(Int)
        /// It went with a longer passage the new text removed or replaced: a
        /// place before it goes before this new word. `sure` is false where
        /// solid matches bound the change on one side only (a removal at an
        /// edge of the book), whose other side the diff can only suppose.
        case removed(Int, sure: Bool)
        /// It lies in a stretch the diff left unmatched for its size
        /// (`PatienceDiff.Alignment.leftForSize`), which says nothing of
        /// where it went: the diff can only suppose a place before it goes
        /// before this new word, at the same share of the stretch.
        case unlined(Int)
        /// No solid match on either side: the texts share nothing near it.
        case undecided
    }

    /// The diff's rules for old word `word` (rule 3, the type's list): a
    /// solid match, the place keeping the words that follow it, a
    /// like-for-like stretch, and words gone, with the slide back.
    private func verdict(forOldWord word: Int) -> Verdict {
        let own = partners[word]
        let solid = isSolid(word)
        // A place keeps the words that follow it, when its own match is weak
        // or its run breaks before the next solid match.
        if let kept = keepingTheWordsAfter(word, solid: solid) {
            return .linedUp(kept)
        }
        if solid { return .linedUp(own) }
        // The nearest solid match after the word: the changed stretch's far
        // end.
        let next = nearestSolid(after: word)
        // The word is in a changed stretch, between the nearest solid
        // matches before and after it.
        let previous = nearestSolid(before: word)
        let boundedBefore = previous >= 0
        let boundedAfter = next < old.count
        let stretchStart = boundedBefore ? partners[previous] + 1 : 0
        let stretchEnd = boundedAfter ? partners[next] : new.count
        // A like-for-like stretch (about as long in the new text as in the
        // old) is local editing: words replaced, dropped, or added here and
        // there, whose lone matches are real and guide the place. In a long
        // stretch the new text dropped, a lone match is a common word paired
        // by chance, and only the stretch's ends can be believed.
        let oldLength = next - previous - 1
        let newLength = stretchEnd - stretchStart
        // A stretch the diff left unmatched for its size (a long repetitive
        // passage, whose words stand too often to be fixed points) is no
        // local editing, however alike its two sides' lengths: the diff can
        // only suppose the place is at the same share of the stretch in the
        // new text, an unsure answer that the saved words may overrule.
        if leftForSize[word] {
            guard boundedBefore || boundedAfter else { return .undecided }
            let share = Double(word - previous - 1) / Double(max(oldLength, 1))
            return .unlined(stretchStart + min(Int(share * Double(newLength)), max(newLength - 1, 0)))
        }
        if boundedBefore, boundedAfter,
           newLength <= Self.likeForLikeFactor * oldLength + Self.likeForLikeSlack,
           oldLength <= Self.likeForLikeFactor * newLength + Self.likeForLikeSlack {
            if own >= 0 { return .linedUp(own) }
            // Its own word is gone: just after the nearest lined-up word
            // before it, or at the nearest after it when nothing came in.
            var before = word - 1
            while before > previous, partners[before] < 0 { before -= 1 }
            var after = word + 1
            while after < next, partners[after] < 0 { after += 1 }
            return .replaced(min(partners[before] + 1, partners[after]))
        }
        // The place's own words are gone: what replaced them begins at the
        // stretch's start, and after a plain removal the next word kept is
        // there too. With solid matches on one side only, that side still
        // says where the removed text was, as an unsure answer.
        guard boundedBefore || boundedAfter else { return .undecided }
        var target = boundedBefore ? min(stretchStart, stretchEnd) : stretchEnd
        // A plain removal slides back: when the removed text ends with the
        // words that end the text before it ("CHAPTER" ending a removed
        // chapter XVIII, before "CHAPTER XIX."), a diff may keep the first
        // copy and drop the second. Slid back, the place goes where the text
        // after the removal begins ("CHAPTER XIX."), not a word into it.
        // The slide stays within the chapter where the text after the
        // removal begins: a chapter left out that ends as the chapter before
        // it ends ("…Ffion said.") does not send its places to the end of
        // that chapter. Nor does it pass the new text's first word.
        if boundedBefore, boundedAfter, stretchStart == stretchEnd {
            let chapter = new.chapter(ofWord: stretchStart)
            var back = 0
            while previous - back >= 0, next - 1 - back > previous,
                  stretchStart - 1 - back >= 0, new.chapter(ofWord: stretchStart - 1 - back) == chapter,
                  partners[previous - back] == stretchStart - 1 - back,
                  old.keys[previous - back] == old.keys[next - 1 - back] {
                back += 1
            }
            target -= back
        }
        return .removed(target, sure: boundedBefore && boundedAfter)
    }

    /// Whether old word `word` lines up within a run of `solidRun` or more
    /// words lined up alike, each one's partner just after the one before's:
    /// a solid match. With `bounds`, only the run's old words within them
    /// count (a chapter's: a run that goes on into the next chapter's words
    /// does not make the chapter's last word solid).
    private func isSolid(_ word: Int, within bounds: Range<Int>? = nil) -> Bool {
        let low = bounds?.lowerBound ?? 0
        let high = bounds?.upperBound ?? old.count
        guard word >= low, word < high, word >= 0, word < old.count, partners[word] >= 0 else { return false }
        var length = 1
        var k = word - 1
        while k >= max(low, 0), length < Self.solidRun, partners[k] >= 0, partners[k] == partners[k + 1] - 1 {
            length += 1
            k -= 1
        }
        k = word + 1
        while k < min(high, old.count), length < Self.solidRun, partners[k] >= 0, partners[k] == partners[k - 1] + 1 {
            length += 1
            k += 1
        }
        return length >= Self.solidRun
    }

    /// The nearest old word after `word` that is a solid match; the number
    /// of old words when none is.
    private func nearestSolid(after word: Int) -> Int {
        var next = word + 1
        while next < old.count, !isSolid(next) { next += 1 }
        return next
    }

    /// The nearest old word before `word` that is a solid match; -1 when
    /// none is.
    private func nearestSolid(before word: Int) -> Int {
        var previous = word - 1
        while previous >= 0, !isSolid(previous) { previous -= 1 }
        return previous
    }

    /// The rule that a place keeps the words that follow it: when every old
    /// word from `word` up to the next solid match (`keepingLimit` words at
    /// most) stands, in order, just before that match's partner in the new
    /// text, with `keepingSlack` and a quarter of their number in new words
    /// allowed among them, the new word that `word` stands for there. The
    /// words are matched as late as they can be, so they keep to what
    /// follows them. Nil when they don't all stand there.
    ///
    /// The next solid match is the first after the place's own run of
    /// matches breaks: right away when the place's word is no solid match
    /// (`solid` says whether it is), else where a word's match no longer
    /// follows the one before's. So text put in before a place that begins
    /// with two or more of the place's words ("BOOK ONE. CHAPTER" before
    /// "BOOK ONE. CHAPTER III." when chapter II comes back) does not take
    /// it, though the diff lines those words up with the text put in.
    ///
    /// A kept place never jumps back across a solid match: the words passed
    /// over among those it keeps may be words put in, or lone matches the
    /// diff made by chance, but never a solid match (a line said twice, with
    /// words kept between the copies, whose second copy the new text
    /// removes, does not send a place in that copy back to the first). And
    /// a place whose own word is a solid match lands past it: text put in
    /// before a place only moves it on.
    private func keepingTheWordsAfter(_ word: Int, solid: Bool) -> Int? {
        // Where the place's run of matches breaks, within the rule's reach.
        var runBreak = word
        if solid {
            runBreak += 1
            while runBreak < old.count, runBreak - word <= Self.keepingLimit,
                  partners[runBreak] >= 0, partners[runBreak] == partners[runBreak - 1] + 1 {
                runBreak += 1
            }
        }
        let next = nearestSolid(after: max(runBreak - 1, word))
        guard next < old.count else { return nil }
        let count = next - word
        guard count <= Self.keepingLimit else { return nil }
        let end = partners[next]
        let floor = solid ? partners[word] + 1 : 0
        let start = max(floor, end - count - Self.keepingSlack - count / 4)
        guard end - start >= count else { return nil }
        var candidate = end - 1
        var first: Int?
        for oldWord in stride(from: next - 1, through: word, by: -1) {
            while candidate >= start, new.keys[candidate] != old.keys[oldWord] {
                // A solid match is never passed over: the place would jump
                // back across text it came after.
                guard !isSolid(newWord: candidate) else { return nil }
                candidate -= 1
            }
            guard candidate >= start else { return nil }
            first = candidate
            candidate -= 1
        }
        return first
    }

    /// Whether new word `word` is text the diff found put in: no old word
    /// lines up with it.
    private func isPutIn(_ word: Int) -> Bool {
        word >= 0 && word < sources.count && sources[word] < 0
    }

    /// Whether new word `word` is lined up with an old word that is a solid
    /// match.
    private func isSolid(newWord word: Int) -> Bool {
        word >= 0 && word < sources.count && isSolid(sources[word])
    }

    // MARK: - The Saved Words, and the Guess

    /// Rules 4 and 5: where the saved words find a place the diff could not
    /// decide (`unsure` is the diff's own unsure answer, if any), or a best
    /// guess. A weak match far from the diff's answer (a common phrase met
    /// elsewhere, as when the place's own text is gone) does not overrule
    /// it; the diff's answer is the guess before the saved words' own.
    private func bySavedWords(_ anchor: TextAnchor, savedAt saved: TextPlace, unsure: Unsure?) -> Result {
        // The last guess takes the same share of the place's chapter; the old
        // text, read as this build reads it, gives the chapter's old length.
        let chapterLength = saved.chapter >= 0 && saved.chapter < old.chapterCount ? old.length(ofChapter: saved.chapter) : nil
        let found = newFinder.find(anchor, savedAt: saved, savedChapterLength: chapterLength)
        switch found.finding {
        case .found(.savedWords(let score)):
            if let unsure, score < Self.strongScore, abs(new.word(at: found.place) - unsure.word) > Self.nearTheDiff {
                return Result(place: unsure.place, finding: .guessed(.diffUnsure))
            }
            return Result(place: found.place, finding: Self.finding(found.finding))
        case .guessed, .unchanged:
            // A guess; or saved words that hold no word, which stand
            // anywhere and so keep the place's numbers only as a guess. The
            // diff's unsure answer comes first.
            if let unsure { return Result(place: unsure.place, finding: .guessed(.diffUnsure)) }
            return Result(place: found.place, finding: found.isGuess ? Self.finding(found.finding) : .guessed(.savedWords(.sameShare)))
        case .found:
            // The end of the book, which rule 1 settled before the diff.
            return Result(place: found.place, finding: Self.finding(found.finding))
        }
    }

    /// Whether `anchor`'s quotes hold no fine word: saved words that stand
    /// anywhere, and so are no evidence of where a place is.
    private static func holdsNoWords(_ anchor: TextAnchor) -> Bool {
        var none = true
        FineWords.forEachWord(in: anchor.before + anchor.after) { _, _, _ in none = false }
        return none
    }

    /// The relocator's finding for one of the finder's. The end of the book
    /// counts with the diff's moves: whichever way the relocator learns a
    /// place was at the old text's end, it goes to the new text's end.
    private static func finding(_ finding: TextAnchorFinder.Finding) -> Finding {
        switch finding {
        case .unchanged: return .unchanged
        case .found(.endOfBook): return .movedByTheDiff(.endOfBook)
        case .found(let evidence): return .foundBySavedWords(evidence)
        case .guessed(let guess): return .guessed(.savedWords(guess))
        }
    }

    /// A place's saved words as the relocator reads them (`savedWords`).
    private struct SavedWords {
        /// Its anchor: as saved, or read in the old text.
        let anchor: TextAnchor
        /// Where the anchor was read in the old text, for a place saved
        /// without one; nil for an anchor as saved.
        let readInOldText: TextPlace?
    }
}

// MARK: - Moving a Book's Places

extension PlaceRelocator {
    /// A book's saved places in its text, as the relocator moves them
    /// together.
    struct Places: Equatable, Sendable {
        /// The reading position; nil for a book without one.
        var position: ReadingPosition?
        /// The bookmarks, in order.
        var bookmarks: [Bookmark] = []
        /// The skipped headings, in order.
        var skippedHeadings: [SkippedHeading] = []
    }

    /// What moving a book's places came to.
    struct Outcome: Equatable, Sendable {
        /// The places as they should now be saved: each at its place in the
        /// new text, with its anchor captured there anew (for a place that
        /// stayed too, since the book around it may have grown or shrunk),
        /// and a position's offset across the whole book worked out anew when
        /// it kept one. A position whose chapter or offset changed is dated
        /// at the move (`relocate(_:movedAt:)`), so it wins over an older
        /// copy elsewhere; one that stayed keeps its time. A move is not a
        /// read otherwise: a position's heading index, and a bookmark's
        /// identity, number, note, and date, stay as they were. A skipped heading takes its heading's place, level,
        /// and label; one that waits stays exactly as it was (words read in
        /// the old text at its numbers would only be the words of whatever
        /// stands there now); two skips that now name one heading are one,
        /// the first kept, and a skip that names a heading is kept over one
        /// that waits whose saved ID that heading now has.
        let places: Places
        /// How the position was found; nil for a book without one.
        let positionFinding: Finding?
        /// How each bookmark was found, in order.
        let bookmarkFindings: [Finding]
        /// How each skipped heading kept in `places` was found, in their
        /// order; nil for a skip that waits. A skip dropped as one with
        /// another has no finding here.
        let skippedHeadingFindings: [Finding?]
        /// The counts, for the debug log's line: the position, the
        /// bookmarks, and the skipped headings kept in `places`.
        let counts: Counts
    }

    /// How a book's places were found, counted for the debug log's line
    /// (`logLine(title:)`).
    struct Counts: Equatable, Sendable {
        /// Places whose saved words still stood around their numbers.
        var unchanged = 0
        /// Places the diff carried across, the end of the book among them.
        var movedByTheDiff = 0
        /// Places the saved words found where the diff could not decide.
        var foundBySavedWords = 0
        /// Places put at a best guess.
        var guessed = 0
        /// Skipped headings that nothing names now, whose skips wait.
        var waiting = 0

        /// How many places were counted.
        var total: Int { unchanged + movedByTheDiff + foundBySavedWords + guessed + waiting }

        /// Whether any place moved, or any skip now waits: the debug log
        /// gets a line only then.
        var anythingMoved: Bool { unchanged < total }

        /// Counts one place found as `finding`; nil is a skip that waits.
        mutating func count(_ finding: Finding?) {
            switch finding {
            case .unchanged?: unchanged += 1
            case .movedByTheDiff?: movedByTheDiff += 1
            case .foundBySavedWords?: foundBySavedWords += 1
            case .guessed?: guessed += 1
            case nil: waiting += 1
            }
        }

        /// The debug log's line for the book titled `title`, an event line
        /// (which may name a book) of counts only, never text
        /// (`DiagnosticLog`): "PLACES_RELOCATED: <title>: unchanged U, moved
        /// by the diff D, by the saved words W, guessed G", and ", waiting S"
        /// when a skip waits.
        func logLine(title: String) -> String {
            var line = "PLACES_RELOCATED: \(title): unchanged \(unchanged), moved by the diff \(movedByTheDiff), "
                + "by the saved words \(foundBySavedWords), guessed \(guessed)"
            if waiting > 0 { line += ", waiting \(waiting)" }
            return line
        }
    }

    /// Whether `position` is at the very start of the book, as a book never
    /// begun or begun over keeps it: nothing of its saved words before it,
    /// and nothing of the old text before it, held there as the reader opens
    /// it. Such a position stays at the start of the new text (REV15,
    /// finding 14): text put in before its old first words, a preface or a
    /// title page restored, was not heard either, and the book's row should
    /// not read begun. A bookmark there follows its words like any other:
    /// the listener marked those words, not the start.
    private func isAtTheStart(_ position: ReadingPosition) -> Bool {
        guard position.anchor?.before.isEmpty ?? true,
              let held = heldInOldText(TextPlace(chapter: position.chapterIndex, offset: position.characterOffset),
                                       savedGlobalOffset: position.globalCharacterOffset)
        else { return false }
        return old.globalOffset(of: held) == 0
    }

    /// Moves a book's places from the old text to the new by the type's
    /// rules: the position, each bookmark, and each skipped heading. A
    /// position at the very start of the book stays at the start of the new
    /// text (`isAtTheStart`). `date` is when the places are moved, which a
    /// position that moved takes as its time; the relocator reads no clock.
    func relocate(_ places: Places, movedAt date: Date) -> Outcome {
        var counts = Counts()
        var moved = places

        var positionFinding: Finding?
        if let position = places.position {
            var result = relocate(
                position.anchor,
                savedAt: TextPlace(chapter: position.chapterIndex, offset: position.characterOffset),
                savedGlobalOffset: position.globalCharacterOffset
            )
            // A position at the very start of the book stays at the start.
            if result.finding != .unchanged, isAtTheStart(position) {
                result = Result(place: TextPlace(chapter: 0, offset: 0), finding: .movedByTheDiff(.startOfBook))
            }
            moved.position = self.moved(position, to: result, at: date)
            positionFinding = result.finding
            counts.count(result.finding)
        }

        var bookmarkFindings: [Finding] = []
        moved.bookmarks = places.bookmarks.map { bookmark in
            let result = relocate(bookmark.anchor, savedAt: TextPlace(chapter: bookmark.chapterIndex, offset: bookmark.characterOffset))
            bookmarkFindings.append(result.finding)
            counts.count(result.finding)
            return self.moved(bookmark, to: result)
        }

        // Each skip as it now is, with how it was found (nil while it waits).
        let skips = places.skippedHeadings.map { skipped -> (skip: SkippedHeading, finding: Finding?) in
            let result = relocate(skipped)
            return (result.map { self.skip(of: $0.heading, keeping: skipped) } ?? skipped, result?.finding)
        }
        // Each heading ID once: two skips that now name one heading are one,
        // the first kept; and a skip that names a heading wins over one that
        // waits whose saved ID that heading now has (the waiting skip's
        // section was removed, and the next one slid into its numbers).
        let namingIDs = Set(skips.filter { $0.finding != nil }.map(\.skip.id))
        var keptIDs = Set<String>()
        var skippedHeadingFindings: [Finding?] = []
        moved.skippedHeadings = skips.compactMap { skip, finding in
            guard finding != nil || !namingIDs.contains(skip.id), keptIDs.insert(skip.id).inserted else { return nil }
            skippedHeadingFindings.append(finding)
            counts.count(finding)
            return skip
        }

        return Outcome(
            places: moved,
            positionFinding: positionFinding,
            bookmarkFindings: bookmarkFindings,
            skippedHeadingFindings: skippedHeadingFindings,
            counts: counts
        )
    }

    /// `position` at `result`'s place: its chapter and offset, its offset
    /// across the whole book when it kept one, and its anchor captured
    /// there; dated `date` when its chapter or offset changed, as
    /// `AudioEditPlaces.follow` dates a moved position, so that it wins over
    /// an older copy in the checkpoint journal's adoption or another Mac's
    /// index (TEXT-ANCHORS-RESEARCH-2026-10-10.md); its time as it was when
    /// it stayed, and its heading index as it was.
    private func moved(_ position: ReadingPosition, to result: Result, at date: Date) -> ReadingPosition {
        var moved = position
        moved.chapterIndex = result.place.chapter
        moved.characterOffset = result.place.offset
        moved.globalCharacterOffset = position.globalCharacterOffset.map { _ in new.globalOffset(of: result.place) }
        moved.anchor = TextAnchor(capturingAt: result.place, in: new) ?? position.anchor
        if result.place != TextPlace(chapter: position.chapterIndex, offset: position.characterOffset) {
            moved.lastUpdated = date
        }
        return moved
    }

    /// `bookmark` at `result`'s place, with its anchor captured there; its
    /// identity, number, note, and date as they were.
    private func moved(_ bookmark: Bookmark, to result: Result) -> Bookmark {
        var moved = bookmark
        moved.chapterIndex = result.place.chapter
        moved.characterOffset = result.place.offset
        moved.anchor = TextAnchor(capturingAt: result.place, in: new) ?? bookmark.anchor
        return moved
    }

    /// The skip of `heading` in the new text, with the anchor at its start;
    /// `skipped`'s own anchor when none can be captured there.
    private func skip(of heading: Heading, keeping skipped: SkippedHeading) -> SkippedHeading {
        let start = Self.start(of: heading)
        return SkippedHeading(heading, anchor: TextAnchor(capturingAt: start, in: new) ?? skipped.anchor)
    }
}
