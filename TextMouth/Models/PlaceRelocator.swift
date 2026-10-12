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
///    numbers in the new text stays.
/// 2. **The old text.** The place is found in the old text: at its numbers
///    when its saved words stand there, or else by its saved words, for
///    certain. A place saved without words is taken to stand at its numbers
///    there, and its words are read there.
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
///      it.
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
///    - **The end:** a place with no words after it in the old text goes to
///      the end of the new one (P07); a place at its chapter's end stands
///      just after the word before it, as the saved-words search lands it.
/// 4. **The saved words.** What the diff cannot decide goes to the saved
///    words' search in the new text (`TextAnchorFinder`), except that a weak
///    match far from the diff's own unsure answer does not overrule it.
/// 5. **A best guess, silently:** the diff's own answer when it was unsure,
///    else the saved words' guess (the nearest of equal spots, the spot near
///    where the place was, or the same share of its chapter).
///
/// A skipped heading is carried like a place to the heading of its level
/// that starts where it lands; failing that, it is found by level, label,
/// and words (`TextAnchorFinder.findHeading`); failing that, the skip waits,
/// applying to no heading, so no section is skipped by mistake. A heading
/// whose text went with a passage the new text removed keeps its skip only
/// on a heading of its level with its label.
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
        /// word before it, where what replaced its word begins.
        case wordReplaced
        /// Its words went with a longer passage the new text removed or
        /// replaced: it goes where the text after the removal begins, or
        /// where what replaced the passage begins.
        case passageRemoved
        /// Its words moved: the diff found them gone from their spot, and
        /// its saved words' one best spot lies in text the diff found put in.
        case followedMovedText
        /// It was at the end of the book (its saved words mark the end, or no
        /// word followed it in the old text), and it stays at the end of the
        /// new text, whatever was added or removed there (P07).
        case endOfBook
    }

    /// Why a place's spot is a best guess.
    enum Guess: Equatable, Sendable {
        /// The diff's own answer where it was unsure (a removal at an edge of
        /// the book, with solid matches on one side only), when the saved
        /// words found nothing surer.
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
    /// The new text's headings, in order.
    let newHeadings: [Heading]
    /// For each old word, the index of the new word the diff lines it up
    /// with, or -1 (`PatienceDiff`).
    private let partners: [Int]
    /// For each new word, the index of the old word the diff lines up with
    /// it, or -1: a new word without one is text the diff found put in.
    private let sources: [Int]
    /// The saved-words search in the old text, for a place whose words do
    /// not stand at its numbers there.
    private let oldFinder: TextAnchorFinder
    /// The saved-words search in the new text.
    private let newFinder: TextAnchorFinder

    /// A relocator from the book `old` reads to the book `new` reads, whose
    /// headings are `newHeadings`: it lines the two up by the diff once, and
    /// indexes each one's words for the saved-words search.
    init(old: BookWords, new: BookWords, newHeadings: [Heading] = []) {
        let partners = PatienceDiff.partners(of: old.keys, in: new.keys)
        var sources = [Int](repeating: -1, count: new.count)
        for (word, partner) in partners.enumerated() where partner >= 0 && partner < sources.count {
            sources[partner] = word
        }
        self.old = old
        self.new = new
        self.newHeadings = newHeadings
        self.partners = partners
        self.sources = sources
        self.oldFinder = TextAnchorFinder(words: old)
        self.newFinder = TextAnchorFinder(words: new, headings: newHeadings)
    }

    /// A relocator from a book whose chapters' reading texts were `oldTexts`
    /// to one whose are `newTexts`, with `newHeadings`.
    init(oldTexts: [String], newTexts: [String], newHeadings: [Heading] = []) {
        self.init(old: BookWords(texts: oldTexts), new: BookWords(texts: newTexts), newHeadings: newHeadings)
    }

    /// A relocator from a loaded book's old text to its new text and
    /// headings.
    init(old: DocumentContent, new: DocumentContent) {
        self.init(oldTexts: old.chapters.map(\.text), newTexts: new.chapters.map(\.text), newHeadings: new.allHeadings)
    }

    // MARK: - Moving a Place

    /// Where a place saved at `saved` with `anchor` (nil for a place saved
    /// before anchors) is in the new text, and how it was found; the rules
    /// are the type's.
    func relocate(_ anchor: TextAnchor?, savedAt saved: TextPlace) -> Result {
        let words = savedWords(anchor, savedAt: saved)
        // Rule 1: the end of the book, and the direct check.
        if let settled = newFinder.settled(words.anchor, savedAt: saved) {
            return Result(place: settled.place, finding: Self.finding(settled.finding))
        }
        // Rules 2 and 3: the old text, then the diff.
        var unsure: Unsure?
        if let start = words.readInOldText ?? placeInOldText(of: words.anchor, savedAt: saved) {
            switch carry(from: start, anchor: words.anchor) {
            case .placed(let result):
                return result
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
    /// at its numbers (held within that text), with where they were read;
    /// and with no old text to read them in, words that hold nothing, which
    /// keep the place's numbers where its chapter still is (`TextAnchor`).
    /// (Every place the measured program moved had saved words; a place
    /// saved before anchors, which T06's branch B captures at load and at
    /// launch, can still reach a rebuild without them.)
    private func savedWords(_ anchor: TextAnchor?, savedAt saved: TextPlace) -> SavedWords {
        if let anchor {
            return SavedWords(anchor: anchor, readInOldText: nil)
        }
        if let held = heldInOldText(saved), let read = TextAnchor(capturingAt: held, in: old, measuredIn: nil) {
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

    /// `place` held within the old text: in its chapter, no further than
    /// the chapter's end; past the last chapter, the old text's end; nil
    /// for an old text without chapters.
    private func heldInOldText(_ place: TextPlace) -> TextPlace? {
        guard old.chapterCount > 0 else { return nil }
        guard place.chapter < old.chapterCount else { return old.endPlace }
        let chapter = max(place.chapter, 0)
        return TextPlace(chapter: chapter, offset: min(max(place.offset, 0), old.length(ofChapter: chapter)))
    }

    // MARK: - Moving a Skipped Heading

    /// The heading a skipped heading names in the new text, and how it was
    /// found; nil when nothing names it, so the skip waits, applying to no
    /// heading, rather than skip another section and hide text the listener
    /// meant to hear.
    ///
    /// The heading's start is carried like a place. When the diff finds the
    /// heading's own text still there (its first word lined up or replaced
    /// in place, and the word after it lined up just after, or replaced in
    /// place too), the heading of its level that starts where it lands is
    /// it, with the label the new text gives it ("[]CHAPTER I." became
    /// "CHAPTER I. Down the Rabbit-Hole" on October 3). Otherwise the finder
    /// decides by level, label, and saved words (`TextAnchorFinder.findHeading`):
    /// its direct check, which needs the label too (a cover's saved words,
    /// which hold none, stand anywhere), its scores, the one heading of its
    /// level with its label, or the nearest such heading as a guess.
    ///
    /// When the diff finds the heading's text gone with a passage the new
    /// text removed, only a heading of its level with its label can still be
    /// it. The heading that now begins where the passage was ("CHAPTER IV."
    /// after chapter III is left out, whose "CHAPTER" the diff lines up with
    /// it), or whose words before it are the skipped heading's words before
    /// it, is another section's, and skipping it would hide text the
    /// listener meant to hear. (The measured rules would carry such a skip to
    /// that heading; no measured case had a skipped heading in removed text.)
    func relocate(_ skipped: SkippedHeading) -> HeadingResult? {
        let saved = TextPlace(chapter: skipped.chapterIndex, offset: skipped.characterOffset)
        let words = savedWords(skipped.anchor, savedAt: saved)
        var labelRequired = false
        switch carriedHeadingStart(words, savedAt: saved) {
        case .standing(let carried)?:
            if let heading = heading(ofLevel: skipped.level, startingAt: carried.place) {
                return HeadingResult(heading: heading, finding: carried.finding)
            }
        case .removed?:
            labelRequired = true
        case nil:
            break
        }
        guard let found = newFinder.findHeading(level: skipped.level, label: skipped.label, anchor: words.anchor, savedAt: saved),
              !labelRequired || found.heading.text == skipped.label
        else { return nil }
        return HeadingResult(heading: found.heading, finding: Self.finding(found.finding))
    }

    /// What the diff makes of a skipped heading's start.
    private enum CarriedHeading {
        /// The heading's own text stands in the new text, where its start
        /// landed: the heading of its level that starts there is it.
        case standing(Result)
        /// The heading's text went with a passage the new text removed.
        case removed
    }

    /// What the diff makes of a skipped heading's start. Nil, leaving the
    /// heading to the finder, when its saved words still stand at its numbers
    /// or mark the end of the book, when it is not found for certain in the
    /// old text, when no word follows its start in its chapter there (a
    /// cover's heading: the diff could only carry the next chapter's first
    /// word, whose heading is another), and when the diff followed moved
    /// text, is unsure, or has nothing to go by.
    private func carriedHeadingStart(_ words: SavedWords, savedAt saved: TextPlace) -> CarriedHeading? {
        guard newFinder.settled(words.anchor, savedAt: saved) == nil,
              let start = words.readInOldText ?? placeInOldText(of: words.anchor, savedAt: saved)
        else { return nil }
        let word = old.word(at: start)
        guard word < old.count, old.chapter(ofWord: word) == start.chapter,
              case .placed(let carried) = carry(from: start, anchor: words.anchor)
        else { return nil }
        switch carried.finding {
        case .movedByTheDiff(.linedUp), .movedByTheDiff(.wordReplaced):
            return headingTextStands(after: word, landedBefore: new.word(at: carried.place)) ? .standing(carried) : .removed
        case .movedByTheDiff(.passageRemoved):
            return .removed
        default:
            return nil
        }
    }

    /// Whether the text of a heading whose first word is old word `word`,
    /// and whose start landed before new word `landed`, still stands there:
    /// the old word after its first word lines up just after the landing, or
    /// was replaced in local editing ("CHAPTER III." became "CHAPTER 3.").
    /// It doesn't when that word went with a removed passage: a chapter left
    /// out, whose "CHAPTER" alone the diff lined up with the next chapter's.
    private func headingTextStands(after word: Int, landedBefore landed: Int) -> Bool {
        let following = word + 1
        guard following < old.count else { return true }
        if partners[following] >= 0 { return partners[following] == landed + 1 }
        if case .replaced = verdict(forOldWord: following) { return true }
        return false
    }

    /// The new heading of `level` that starts where `place` lands: in the
    /// chapter of the word it stands before, before that same word; the first
    /// in the book's order when two do.
    private func heading(ofLevel level: Int, startingAt place: TextPlace) -> Heading? {
        let word = new.word(at: place)
        guard word < new.count else { return nil }
        let chapter = new.chapter(ofWord: word)
        return newHeadings.first { heading in
            heading.level == level && heading.chapterIndex == chapter
                && new.word(at: TextPlace(chapter: chapter, offset: heading.characterOffset)) == word
        }
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
        let word = old.word(at: start)
        // No word follows the place in the old text: it was at the end, and
        // the end of the new text is where it goes (P07).
        guard word < old.count else {
            return .placed(Result(place: new.endPlace, finding: .movedByTheDiff(.endOfBook)))
        }
        // Whether no word follows the place in its own chapter: the word
        // after it begins a later chapter.
        let nothingAfter = old.chapter(ofWord: word) != start.chapter
        // A place at its chapter's end stands just after the word before it,
        // so the diff carries that word, when it lines up, and the place
        // lands just after it: at the end of its chapter in the new text when
        // nothing follows there (a chapter restored after it does not take
        // it), or before what was added after it. The saved-words search
        // lands such a place the same way (`BookWords.landing`); the measured
        // program carried the next chapter's first word instead, and so put
        // the place at the next chapter's start (it sampled no such place).
        if nothingAfter, word > 0, old.chapter(ofWord: word - 1) == start.chapter,
           case .linedUp(let before) = verdict(forOldWord: word - 1) {
            return .placed(Result(place: new.landing(beforeWord: before + 1, nothingAfter: true), finding: .movedByTheDiff(.linedUp)))
        }
        // A place inside a word (as a bookmark nudged clear of another can
        // be) keeps how far into it it was, as the saved-words search keeps
        // it; the measured program moved it to the word's start.
        let inside: (key: UInt64, offset: Int)? = !nothingAfter && old.starts[word] < start.offset
            ? (old.keys[word], start.offset - old.starts[word])
            : nil
        let landing = { (newWord: Int) in self.new.landing(beforeWord: newWord, inside: inside, nothingAfter: nothingAfter) }
        let gone: (newWord: Int, evidence: DiffEvidence, sure: Bool)
        switch verdict(forOldWord: word) {
        case .linedUp(let newWord):
            return .placed(Result(place: landing(newWord), finding: .movedByTheDiff(.linedUp)))
        case .replaced(let newWord):
            gone = (newWord, .wordReplaced, true)
        case .removed(let newWord, let sure):
            gone = (newWord, .passageRemoved, sure)
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
    /// a solid match.
    private func isSolid(_ word: Int) -> Bool {
        guard word >= 0, word < old.count, partners[word] >= 0 else { return false }
        var length = 1
        var k = word - 1
        while k >= 0, length < Self.solidRun, partners[k] >= 0, partners[k] == partners[k + 1] - 1 {
            length += 1
            k -= 1
        }
        k = word + 1
        while k < old.count, length < Self.solidRun, partners[k] >= 0, partners[k] == partners[k - 1] + 1 {
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
        case .guessed:
            if let unsure { return Result(place: unsure.place, finding: .guessed(.diffUnsure)) }
            return Result(place: found.place, finding: Self.finding(found.finding))
        case .unchanged, .found:
            // Settled by rule 1 before the diff; kept as the finder says.
            return Result(place: found.place, finding: Self.finding(found.finding))
        }
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
        /// it kept one. A move is not a read: a position's time and heading
        /// index, and a bookmark's identity, number, note, and date, stay as
        /// they were. A skipped heading takes its heading's place and label;
        /// one that waits stays as it was, with the words it was read by, so
        /// a later rebuild may find its heading; two skips that now name one
        /// heading are one.
        let places: Places
        /// How the position was found; nil for a book without one.
        let positionFinding: Finding?
        /// How each bookmark was found, in order.
        let bookmarkFindings: [Finding]
        /// How each skipped heading was found, in order; nil for a skip that
        /// waits.
        let skippedHeadingFindings: [Finding?]
        /// The counts, for the debug log's line.
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

    /// Moves a book's places from the old text to the new by the type's
    /// rules: the position, each bookmark, and each skipped heading.
    func relocate(_ places: Places) -> Outcome {
        var counts = Counts()
        var moved = places

        var positionFinding: Finding?
        if let position = places.position {
            let result = relocate(position.anchor, savedAt: TextPlace(chapter: position.chapterIndex, offset: position.characterOffset))
            moved.position = self.moved(position, to: result)
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

        var skippedHeadingFindings: [Finding?] = []
        // Each heading ID once: two skips that now name one heading are one.
        var namedIDs = Set<String>()
        moved.skippedHeadings = places.skippedHeadings.compactMap { skipped in
            let result = relocate(skipped)
            skippedHeadingFindings.append(result?.finding)
            counts.count(result?.finding)
            let movedSkip = result.map { self.skip(of: $0.heading, keeping: skipped) } ?? waiting(skipped)
            return namedIDs.insert(movedSkip.id).inserted ? movedSkip : nil
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
    /// there; its time and heading index as they were.
    private func moved(_ position: ReadingPosition, to result: Result) -> ReadingPosition {
        var moved = position
        moved.chapterIndex = result.place.chapter
        moved.characterOffset = result.place.offset
        moved.globalCharacterOffset = position.globalCharacterOffset.map { _ in new.globalOffset(of: result.place) }
        moved.anchor = TextAnchor(capturingAt: result.place, in: new) ?? position.anchor
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
        let start = TextPlace(chapter: heading.chapterIndex, offset: heading.characterOffset)
        return SkippedHeading(heading, anchor: TextAnchor(capturingAt: start, in: new) ?? skipped.anchor)
    }

    /// A skip that waits: as it was, with the words it was read by (for a
    /// skip saved without words, those read in the old text at its numbers),
    /// so that a later rebuild may find its heading by them.
    private func waiting(_ skipped: SkippedHeading) -> SkippedHeading {
        var waiting = skipped
        if waiting.anchor == nil {
            let read = savedWords(nil, savedAt: TextPlace(chapter: skipped.chapterIndex, offset: skipped.characterOffset))
            if read.readInOldText != nil { waiting.anchor = read.anchor }
        }
        return waiting
    }
}
