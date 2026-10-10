import Foundation

/// Moves a book's saved places from its old text to its new one (T06):
/// reading positions and bookmarks, when TextMouth rebuilds the book's text
/// while the old text is still at hand (a rebuild of the text cache, Edit
/// Text). Pure: the caller reads both texts, and writes back what moved.
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
///      or its run breaks right after it, and every old word from it to the
///      next solid match stands in order just before that match (a few words
///      put in among them allowed), it goes to its own word there. So text
///      put in before a place that begins with the place's own words
///      ("CHAPTER" before "CHAPTER XIX." when chapter XVIII comes back) does
///      not take it, as Git slides a change to a better boundary.
///    - **A like-for-like stretch** (as long in both texts, give or take,
///      between solid matches) is local editing: the place's own word if it
///      is lined up there, else just after the nearest lined-up word before
///      it.
///    - **Words gone:** after a removal, the place goes where the text after
///      the removal begins, slid back over words the removal ends with that
///      also end the text before it, as Git slides a change; in a replaced
///      stretch, where what replaced it begins.
///    - **Moved text:** a place whose words are gone from their spot follows
///      them, however far, when its saved words' one best spot in the new
///      text lies in text the diff found put in: text that moved is a
///      removal there and the same words put in here. Words met in text the
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
/// microseconds. Nothing is said or shown.
struct PlaceRelocator: Sendable {
    // MARK: - What a Move Comes To

    /// How a place was moved.
    enum Finding: Equatable, Sendable {
        /// Its saved words still stand exactly around its saved numbers in
        /// the new text, so it stays.
        case unchanged
        /// Carried across by the diff of the old text with the new, for
        /// `DiffEvidence`.
        case movedByTheDiff(DiffEvidence)
        /// The diff could not decide, and the saved words found it for
        /// certain in the new text, by `TextAnchorFinder.Evidence`.
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
    /// For each old word, the index of the new word the diff lines it up
    /// with, or -1 (`PatienceDiff`).
    private let partners: [Int]
    /// For each new word, whether the diff lined an old word up with it; a
    /// new word without one is text the diff found put in.
    private let paired: [Bool]
    /// The saved-words search in the old text, for a place whose words do
    /// not stand at its numbers there.
    private let oldFinder: TextAnchorFinder
    /// The saved-words search in the new text.
    private let newFinder: TextAnchorFinder

    /// A relocator from the book `old` reads to the book `new` reads: it
    /// lines the two up by the diff once, and indexes each one's words for
    /// the saved-words search.
    init(old: BookWords, new: BookWords) {
        let partners = PatienceDiff.partners(of: old.keys, in: new.keys)
        var paired = [Bool](repeating: false, count: new.count)
        for partner in partners where partner >= 0 && partner < paired.count {
            paired[partner] = true
        }
        self.old = old
        self.new = new
        self.partners = partners
        self.paired = paired
        self.oldFinder = TextAnchorFinder(words: old)
        self.newFinder = TextAnchorFinder(words: new)
    }

    /// A relocator from a book whose chapters' reading texts were `oldTexts`
    /// to one whose are `newTexts`.
    init(oldTexts: [String], newTexts: [String]) {
        self.init(old: BookWords(texts: oldTexts), new: BookWords(texts: newTexts))
    }

    /// A relocator from a loaded book's old text to its new text.
    init(old: DocumentContent, new: DocumentContent) {
        self.init(oldTexts: old.chapters.map(\.text), newTexts: new.chapters.map(\.text))
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
        // The nearest solid match after the word: where the words that
        // follow a place are found, and the changed stretch's far end.
        let next = nearestSolid(after: word)
        // A place keeps the words that follow it, when its own match is weak
        // or its run breaks right after it.
        if own < 0 || !solid || word + 1 >= old.count || partners[word + 1] != own + 1,
           let kept = keepingTheWordsAfter(word, nextSolid: next) {
            return .linedUp(kept)
        }
        if own >= 0, solid { return .linedUp(own) }
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
        if boundedBefore, boundedAfter, stretchStart == stretchEnd {
            var back = 0
            while previous - back >= 0, next - 1 - back > previous,
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
    /// word from `word` up to the solid match `next` (`keepingLimit` words
    /// at most) stands, in order, just before that match's partner in the
    /// new text, with `keepingSlack` and a quarter of their number in new
    /// words allowed among them, the new word that `word` stands for there.
    /// The words are matched as late as they can be, so they keep to what
    /// follows them. Nil when they don't all stand there.
    private func keepingTheWordsAfter(_ word: Int, nextSolid next: Int) -> Int? {
        guard next < old.count else { return nil }
        let count = next - word
        guard count <= Self.keepingLimit else { return nil }
        let end = partners[next]
        let start = max(0, end - count - Self.keepingSlack - count / 4)
        guard end - start >= count else { return nil }
        var candidate = end - 1
        var first: Int?
        for oldWord in stride(from: next - 1, through: word, by: -1) {
            while candidate >= start, new.keys[candidate] != old.keys[oldWord] { candidate -= 1 }
            guard candidate >= start else { return nil }
            first = candidate
            candidate -= 1
        }
        return first
    }

    /// Whether new word `word` is text the diff found put in: no old word
    /// lines up with it.
    private func isPutIn(_ word: Int) -> Bool {
        word >= 0 && word < paired.count && !paired[word]
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
