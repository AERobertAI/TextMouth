import Foundation

/// Finds saved places again in a book's reading text by the words their
/// anchors keep (T06): where each place goes, and how it was found.
///
/// These are the measured rules (TEXT-ANCHORS-RESEARCH-2026-10-10.md,
/// section 5, and TEXT-ANCHORS-ADDENDUM-2026-10-10.md, sections 1 and 9),
/// over fine words (`FineWords`):
///
/// 1. **The end of the book.** A place with nothing after it at the end of
///    the book stays at the end of the book, whatever was added or removed
///    there (P07's finished book).
/// 2. **The direct check.** When the anchor's text stands exactly around
///    the saved numbers, the place is unchanged (`TextAnchor.stands`).
/// 3. **The saved words.** Every spot where the first four words after the
///    place stand, and every spot the last four words before it end, is a
///    candidate. Each word after the place that agrees there, in order up to
///    the first that doesn't, counts 2, and each word before it counts 1:
///    the words after count double because they are what the listener was
///    about to hear, so text put in at the place leaves the place before its
///    own words. A candidate needs 8.
/// 4. **Ties and locality, as best guesses.** The one best candidate is the
///    place. When several score best alike, the one nearest where the place
///    was is a best guess. When the best lie far from where the place was
///    (more than 5% of the book, and more than 3,000 units) while a
///    candidate near it scores 8 or more, that near one is a best guess:
///    a place in a passage the book prints twice does not jump to the other
///    copy.
/// 5. **The tolerant second search.** When the first search finds nothing,
///    finds spots alike, or finds the words far from where the place was,
///    the quote's words are lined up with the book's words around every spot
///    where three of them stand together, so a word edited, added, or
///    dropped inside the quote no longer stops the search.
/// 6. **The last guess.** A place whose words are found nowhere goes to the
///    same share of its chapter, at a word start: its share when the
///    chapter's old length is known (a relocation that has the old text),
///    else its saved offset held within the chapter, and for a chapter the
///    book no longer has, its share of the whole book.
///
/// Skipped headings are found among the headings of their level, only on
/// proof (`findHeading`).
///
/// The finder is a value, built once per book's text and read from any
/// thread. Building it reads the whole book's words and indexes them: in
/// optimized code, about 10 ms for a novel of 750,000 UTF-16 units and 40
/// ms for a book of 3.7 million, against about a microsecond for a direct
/// check. So a caller first asks each place's anchor whether it still
/// stands (`TextAnchor.stands(at:in:)`) and builds the finder only when one
/// doesn't, off the main thread. A search then takes about 0.06 ms a place,
/// and a few milliseconds in a large book where the place's words stand
/// many times. Nothing is said or shown: a guess is silent, and only says
/// it was a guess so a caller can count it.
struct TextAnchorFinder: Sendable {
    // MARK: - What a Search Comes To

    /// How a place was found again.
    enum Finding: Equatable, Sendable {
        /// Its anchor's text still stands exactly around its saved numbers
        /// (for a heading: at the saved place, where a heading of its level
        /// and its label starts), so it stays.
        case unchanged
        /// Found for certain, by `Evidence`.
        case found(Evidence)
        /// A best guess, made silently, for the `Guess` reason.
        case guessed(Guess)

        /// Whether the place is a best guess.
        var isGuess: Bool {
            if case .guessed = self { return true }
            return false
        }
    }

    /// What found a place for certain.
    enum Evidence: Equatable, Sendable {
        /// Its saved words: the one best spot, and the score it reached.
        case savedWords(score: Int)
        /// It was at the end of the book, and stays at the end (P07).
        case endOfBook
        /// A skipped heading's heading found as the one heading of its level
        /// with its label, where the diff of the old text with the new
        /// proves it the same section (`PlaceRelocator.relocate(_:)`, rule
        /// 4): only a rebuild finds a heading so. With no old text, a label
        /// alone is no proof (`findHeading`).
        case onlyHeadingWithItsLabel
    }

    /// Why a place's spot is a best guess.
    enum Guess: Equatable, Sendable {
        /// Its saved words fit several spots equally well (a refrain, a
        /// contents list printed twice): the one nearest where it was.
        case nearestOfEqualSpots
        /// Its saved words fit best far from where it was, and well enough
        /// near it: the near spot, so a place in a passage printed twice
        /// stays in its own copy.
        case nearWhereItWas
        /// Its saved words fit nowhere: the same share of its chapter, at a
        /// word start.
        case sameShare
    }

    /// Where a saved place goes, and how it was found.
    struct Result: Equatable, Sendable {
        /// Where the place is now.
        let place: TextPlace
        /// How it was found.
        let finding: Finding

        /// Whether the place is a best guess.
        var isGuess: Bool { finding.isGuess }
    }

    /// The heading a skipped heading now names, and how it was found.
    struct HeadingResult: Equatable, Sendable {
        /// The heading as the text now gives it: its place, and its label,
        /// which a skipped heading takes ("[]CHAPTER I." became "CHAPTER I.
        /// Down the Rabbit-Hole" on October 3).
        let heading: Heading
        /// How it was found.
        let finding: Finding

        /// Whether the heading is a best guess.
        var isGuess: Bool { finding.isGuess }
    }

    // MARK: - The Rules' Numbers

    /// How many words in a row, just after the place or just before it, a
    /// candidate spot must hold.
    static let seedWords = 4
    /// The score a candidate needs.
    static let minimumScore = 8
    /// The share of the book within which a spot is near where the place
    /// was; `localityMinimum` UTF-16 units at least.
    static let localityShare = 0.05
    /// The fewest UTF-16 units within which a spot is near where the place
    /// was, for a short book.
    static let localityMinimum = 3_000
    /// How many of a skipped heading's saved words after it, past its
    /// label's words, must agree at a heading's start to prove that heading
    /// its section (`findHeading`): as many as a candidate spot must hold.
    static let sectionProofWords = seedWords
    /// How many of the quote's words in a row mark a spot for the tolerant
    /// search.
    static let tolerantSeedWords = 3
    /// The score a spot needs in the tolerant search: higher than the first
    /// search's, since a tolerant score lets common words meet by chance.
    static let tolerantMinimumScore = 12
    /// The tolerant score a spot near where the place was needs to stop the
    /// first search's spot far away from being taken. Strong, since places
    /// do move far when a chapter is restored before them, and common
    /// phrases near the old spot score some points.
    static let tolerantLocalScore = 16
    /// How many matched words in a row count toward a tolerant score: a lone
    /// common word met by chance does not.
    static let tolerantMinimumRun = 2
    /// How many of the book's words beyond the quote's length, on each side,
    /// the tolerant search lines the quote up with.
    static let tolerantMargin = 6
    /// The most words of each quote a search reads. A quote of 64 UTF-16
    /// units holds no more, so this only bounds the work an anchor from a
    /// damaged file could ask for.
    static let maximumQuoteWords = 64

    // MARK: - The Book

    /// The book's words.
    let words: BookWords
    /// The book's headings, in order.
    let headings: [Heading]
    /// Where each word key stands: the indices in `words.keys` of its words,
    /// in order.
    private let positions: [UInt64: [Int]]
    /// How far from where a place was a spot can be and still be near it,
    /// in UTF-16 units: 5% of the book, and 3,000 units at least.
    private let localityWindow: Double

    /// A finder over the book `words` reads, with its `headings`.
    init(words: BookWords, headings: [Heading] = []) {
        var positions: [UInt64: [Int]] = [:]
        positions.reserveCapacity(words.count / 8)
        for (index, key) in words.keys.enumerated() {
            positions[key, default: []].append(index)
        }
        self.words = words
        self.headings = headings
        self.positions = positions
        self.localityWindow = max(Self.localityShare * Double(words.totalLength), Double(Self.localityMinimum))
    }

    /// A finder over a book whose chapters' reading texts are `texts`, with
    /// its `headings`.
    init(texts: [String], headings: [Heading] = []) {
        self.init(words: BookWords(texts: texts), headings: headings)
    }

    /// A finder over a loaded book's text and headings.
    init(content: DocumentContent) {
        self.init(texts: content.chapters.map(\.text), headings: content.allHeadings)
    }

    // MARK: - Finding a Place

    /// Where a place saved at `saved` with `anchor` is now, and how it was
    /// found; the rules are the type's.
    ///
    /// - Parameter savedChapterLength: The length of the place's chapter in
    ///   the text it was saved in, when the caller knows it (a relocation
    ///   that has the old text), for the last guess: the same share of the
    ///   chapter. Without it, the guess keeps the saved offset, held within
    ///   the chapter.
    func find(_ anchor: TextAnchor, savedAt saved: TextPlace, savedChapterLength: Int? = nil) -> Result {
        if let settled = settled(anchor, savedAt: saved) { return settled }
        let quote = Quote(anchor)
        let expected = anchor.fraction * Double(words.totalLength)
        switch search(quote, expected: expected) {
        case .found(let spot):
            return Result(place: landing(beforeWord: spot.word, quote), finding: .found(.savedWords(score: spot.score)))
        case .guessed(let word, let guess):
            return Result(place: landing(beforeWord: word, quote), finding: .guessed(guess))
        case .notFound:
            return Result(
                place: sameShareGuess(saved: saved, savedChapterLength: savedChapterLength, fraction: anchor.fraction),
                finding: .guessed(.sameShare)
            )
        }
    }

    /// The first two rules, which settle a place without searching for it:
    /// the end of the book stays the end, and a place whose anchor's text
    /// still stands exactly around its saved numbers stays; nil when neither
    /// settles it. `find` begins with them, and so does the diff of an old
    /// text with the new one (`PlaceRelocator`), which tries the old text
    /// before any search.
    func settled(_ anchor: TextAnchor, savedAt saved: TextPlace) -> Result? {
        // The end of the book stays the end, whatever was added or removed
        // there. The anchor marks the end when its place was at or past the
        // book's length, as P07 measures a finished book
        // (`Book.restsAtEnd`). A place exactly at the end stays; one past
        // it, whose numbers point past the text, goes to the end itself.
        if anchor.marksEndOfBook {
            if words.isEnd(saved) { return Result(place: saved, finding: .unchanged) }
            return Result(place: words.endPlace, finding: .found(.endOfBook))
        }
        if anchor.stands(at: saved, in: words.texts) {
            return Result(place: saved, finding: .unchanged)
        }
        return nil
    }

    /// The first search's one best spot for `anchor`, wherever in the book it
    /// lies: the spot whose saved words score best, with 8 or more, when no
    /// other spot scores as well, and the place's own word stands there (the
    /// first word after it); nil otherwise. The tie and locality rules play
    /// no part, and the place's saved numbers none: this is the diff's
    /// question when a place's words are gone from their spot
    /// (`PlaceRelocator`). If the one best spot lies in text the diff found
    /// put in, the words moved there, however far, since a second copy the
    /// diff kept would have been lined up with them instead. The words before
    /// a place say only where the text before it went: when they alone score
    /// a spot (its own word replaced, "frogspawn floated" become "duckweed
    /// floated", or its whole section replaced), the place's text did not
    /// move there.
    ///
    /// Returns where the place lands there (as `find` would land it) and
    /// the word it stands before.
    func onlyBestSpot(for anchor: TextAnchor) -> (place: TextPlace, word: Int)? {
        let quote = Quote(anchor)
        let spots = candidateSpots(quote)
        guard let best = spots.map(\.score).max(), best >= Self.minimumScore else { return nil }
        let top = spots.filter { $0.score == best }
        guard top.count == 1, let only = top.first, !quote.after.isEmpty, agrees(quote.after.prefix(1), at: only.word) else { return nil }
        return (landing(beforeWord: only.word, quote), only.word)
    }

    // MARK: - Finding a Skipped Heading

    /// The heading a skipped heading of `level`, labelled `label`, saved at
    /// `saved` with `anchor` (its anchor at the heading's start) now names,
    /// and how it was found; nil when nothing proves which heading it is, so
    /// the skip waits, applying to no heading, rather than skip another
    /// section and hide text the listener meant to hear. A heading is named
    /// only on proof (REV16, finding F1):
    ///
    /// 1. **The direct check.** Its saved words still stand at its saved
    ///    place, where a heading of its level and its label starts. The label
    ///    is part of the check because a cover's anchor holds no words and so
    ///    stands anywhere: without it, a title page put in where the cover
    ///    was would take its skip.
    /// 2. **Its section's opening words** (`opensItsSection`). Every one of
    ///    its saved words after the heading agrees, in order, from a
    ///    heading's first word on, within that heading's chapter, and at
    ///    least `sectionProofWords` of them lie past the label's words. One
    ///    such heading of its level is it; of several (sections that open
    ///    alike), the one with its label, when exactly one has it.
    ///
    /// Nothing else names a heading. The measured rules
    /// (TEXT-ANCHORS-ADDENDUM-2026-10-10.md, section 5) also scored a heading
    /// by the words before it, added 3 for an unchanged label, and fell back
    /// on the label alone. REV16 found that with no old text to diff (the
    /// check at load, `PlaceRelocator.relocate(_:within:movedAt:)`, this
    /// function's one caller), those handed a removed section's skip to the
    /// section after it, whose words before are the removed one's, or to
    /// another chapter's section of the same label. A heading that only moved
    /// keeps every word after it, so it is still found. One moved and edited
    /// within its saved words waits, as does a cover that moved, whose skip
    /// holds no words: a rebuild, which diffs the old text with the new,
    /// still carries both (`PlaceRelocator.relocate(_:)`).
    func findHeading(level: Int, label: String, anchor: TextAnchor, savedAt saved: TextPlace) -> HeadingResult? {
        let candidates = headings.filter { $0.level == level }
        guard !candidates.isEmpty else { return nil }
        if anchor.stands(at: saved, in: words.texts),
           let same = candidates.first(where: { $0.text == label && place(of: $0) == saved }) {
            return HeadingResult(heading: same, finding: .unchanged)
        }
        let quote = Quote(anchor)
        let skippedLabel = FineWords.keys(in: label)
        let proven = candidates.filter { opensItsSection(quote, at: $0, skippedLabel: skippedLabel) }
        // One proven heading is it; of several that open alike, the one
        // with its label, when only one has it.
        let provenWithItsLabel = proven.filter { $0.text == label }
        guard let named = proven.count == 1 ? proven.first : (provenWithItsLabel.count == 1 ? provenWithItsLabel.first : nil) else {
            return nil
        }
        let savedWordsScore = score(at: words.word(at: place(of: named)), quote)
        return HeadingResult(heading: named, finding: .found(.savedWords(score: savedWordsScore)))
    }

    /// Whether `heading` opens the skipped heading's section, by `quote`, the
    /// skip's saved words (rule 2 of `findHeading`): every word of the quote
    /// after the heading agrees, in order, from the heading's first word on,
    /// within its chapter, and at least `sectionProofWords` of them lie past
    /// the label's words. The label's words are the longer run of them the
    /// quote begins with, by the skip's label (`skippedLabel`, its fine
    /// words) or by `heading`'s own, so a label alone never proves a section,
    /// however many of its words agree.
    private func opensItsSection(_ quote: Quote, at heading: Heading, skippedLabel: [UInt64]) -> Bool {
        let after = quote.after
        let labelWords = max(Self.leadingRun(of: skippedLabel, in: after), Self.leadingRun(of: FineWords.keys(in: heading.text), in: after))
        guard after.count - labelWords >= Self.sectionProofWords,
              heading.chapterIndex >= 0, heading.chapterIndex < words.chapterCount
        else { return false }
        let start = words.word(at: place(of: heading))
        return start + after.count <= words.chapterFirstWords[heading.chapterIndex + 1] && agrees(after[...], at: start)
    }

    /// How many of `label`'s words, in order, `run` begins with.
    private static func leadingRun(of label: [UInt64], in run: [UInt64]) -> Int {
        zip(label, run).prefix { $0 == $1 }.count
    }

    // MARK: - The Saved Words, as the Search Reads Them

    /// An anchor's quotes as the search reads them: their fine words before
    /// the place and from it on.
    ///
    /// The quotes were cut at `TextAnchor.quoteLength` units, so the word a
    /// cut falls in may be partial: the first run between spaces of the
    /// quote before, and the last of the quote after, are left out unless
    /// a space bounds them, as the measured rule does (a whole word may go
    /// with them; the rule doesn't know which). A place inside a word (as a
    /// bookmark nudged clear of another can be) reads that whole word as
    /// the first word after it, its own, and remembers how far into it the
    /// place was: the measured rule read the word as two halves the book
    /// doesn't hold, and so lost such a place to a guess.
    struct Quote {
        /// The keys of the words before the place, in order.
        var before: [UInt64] = []
        /// The keys of the words from the place on, in order: the word the
        /// place stands inside first, when it stands inside one.
        var after: [UInt64] = []
        /// The key of the word the place stands inside, and how many UTF-16
        /// units into it the place is; nil for a place between words.
        var inside: (key: UInt64, offset: Int)?

        /// Reads `anchor`'s quotes.
        init(_ anchor: TextAnchor) {
            let boundary = anchor.before.utf16.count
            let joined = anchor.before + anchor.after
            let units = Array(joined.utf16)
            // Words of the first run between spaces end before this, when
            // the quote before may have cut into it.
            var cutBefore = 0
            if boundary > 0, let first = units.first, !FineWords.isSpace(first) {
                cutBefore = units.firstIndex(where: FineWords.isSpace) ?? units.count
            }
            // Words of the last run between spaces end after this, when the
            // quote after may have cut into it.
            var cutAfter = units.count
            if boundary < units.count, let last = units.last, !FineWords.isSpace(last) {
                cutAfter = units.lastIndex(where: FineWords.isSpace).map { $0 + 1 } ?? 0
            }
            var before: [UInt64] = []
            var after: [UInt64] = []
            var inside: (key: UInt64, offset: Int)?
            FineWords.forEachWord(in: joined) { start, end, key in
                if end <= boundary {
                    if start >= cutBefore { before.append(key) }
                } else if end <= cutAfter {
                    after.append(key)
                    if start < boundary { inside = (key, boundary - start) }
                }
            }
            self.before = Array(before.suffix(TextAnchorFinder.maximumQuoteWords))
            self.after = Array(after.prefix(TextAnchorFinder.maximumQuoteWords))
            self.inside = inside
        }

        /// The words before the place and after it, as one run.
        var words: [UInt64] { before + after }
    }

    /// A spot the saved words point to: the word the place stands before
    /// there, and how well the words fit.
    private struct Spot {
        let word: Int
        let score: Int
    }

    /// What a search by the saved words came to.
    private enum Search {
        /// The one best spot.
        case found(Spot)
        /// A best guess: the word the place stands before, and why.
        case guessed(word: Int, Guess)
        /// No spot fits well enough.
        case notFound
    }

    // MARK: - The Searches

    /// The saved words' search: the first search, then the tolerant one
    /// when the first finds nothing, finds spots alike, or finds the words
    /// far from where the place was (`expected`, in UTF-16 units into the
    /// book), where a copy the book prints twice can stand while the
    /// place's own copy was edited.
    private func search(_ quote: Quote, expected: Double) -> Search {
        let first = choose(among: candidateSpots(quote), minimum: Self.minimumScore, localMinimum: Self.minimumScore, expected: expected).search
        if case .found(let spot) = first, isNear(spot.word, expected) { return first }
        let tolerant = choose(among: tolerantSpots(quote), minimum: Self.tolerantMinimumScore, localMinimum: Self.tolerantLocalScore, expected: expected)
        switch first {
        case .found:
            // The words were found far from where the place was: a spot near
            // it that the tolerant search scores strongly is taken instead.
            if let local = tolerant.local { return .guessed(word: local.word, .nearWhereItWas) }
            return first
        case .guessed, .notFound:
            if case .notFound = tolerant.search { return first }
            return tolerant.search
        }
    }

    /// The first search's candidates: every spot where the first
    /// `seedWords` words after the place stand, and every spot just after
    /// where the last `seedWords` words before it end, each with its score,
    /// in the book's order.
    private func candidateSpots(_ quote: Quote) -> [Spot] {
        let seed = Self.seedWords
        var scores: [Int: Int] = [:]
        if quote.after.count >= seed, let starts = positions[quote.after[0]] {
            for start in starts where agrees(quote.after.prefix(seed), at: start) {
                scores[start] = score(at: start, quote)
            }
        }
        if quote.before.count >= seed, let ends = positions[quote.before[quote.before.count - 1]] {
            for end in ends where end - seed + 1 >= 0 && agrees(quote.before.suffix(seed), at: end - seed + 1) {
                scores[end + 1] = score(at: end + 1, quote)
            }
        }
        return scores.map { Spot(word: $0.key, score: $0.value) }.sortedStably { $0.word < $1.word }
    }

    /// The tolerant search's candidates: the quote's words (before the
    /// place and after it) lined up with the book's words around every
    /// spot where `tolerantSeedWords` of them stand together, each spot
    /// with the best score any lining up gave it, in the book's order.
    private func tolerantSpots(_ quote: Quote) -> [Spot] {
        let quoteWords = quote.words
        let placeIndex = quote.before.count
        let seed = Self.tolerantSeedWords
        guard quoteWords.count >= seed else { return [] }
        // Where the place would be, by each run of the quote's words found
        // in the book.
        var estimates = Set<Int>()
        for first in 0...(quoteWords.count - seed) {
            guard let starts = positions[quoteWords[first]] else { continue }
            for start in starts where agrees(quoteWords[first..<(first + seed)], at: start) {
                estimates.insert(start - (first - placeIndex))
            }
        }
        // Each stretch of the book once: estimates a few words apart
        // describe the same stretch.
        var best: [Int: Int] = [:]
        var stretchesSeen = Set<Int>()
        var table: [Int32] = []
        for estimate in estimates.sortedStably() {
            let low = max(0, estimate - placeIndex - Self.tolerantMargin)
            let high = min(words.count, estimate + (quoteWords.count - placeIndex) + Self.tolerantMargin)
            guard low < high, stretchesSeen.insert(low / 4).inserted else { continue }
            if let spot = alignment(of: quoteWords, placeIndex: placeIndex, with: low..<high, table: &table) {
                best[spot.word] = max(best[spot.word] ?? 0, spot.score)
            }
        }
        return best.map { Spot(word: $0.key, score: $0.value) }.sortedStably { $0.word < $1.word }
    }

    /// Lines the quote's words up with the book's words in `stretch` (a
    /// longest common subsequence) and returns the spot it gives, with its
    /// score: the quote's words matched in runs of `tolerantMinimumRun` or
    /// more, side by side in both, each after the place counting 2 and each
    /// before it 1. The spot is the partner of the first word after the
    /// place, else just past the partner of the last word before it that
    /// has one, else the partner of the first word after it that has one.
    /// `table` is scratch space, reused from one stretch to the next.
    private func alignment(of quoteWords: [UInt64], placeIndex: Int, with stretch: Range<Int>, table: inout [Int32]) -> Spot? {
        let n = quoteWords.count
        let m = stretch.count
        let width = m + 1
        // table[i * width + j]: the longest common subsequence of the
        // quote's words from i and the stretch's from j.
        table.removeAll(keepingCapacity: true)
        table.append(contentsOf: repeatElement(0, count: (n + 1) * width))
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i * width + j] = quoteWords[i] == words.keys[stretch.lowerBound + j]
                    ? table[(i + 1) * width + j + 1] + 1
                    : max(table[(i + 1) * width + j], table[i * width + j + 1])
            }
        }
        // Each quote word's partner in the book, or -1.
        var partner = [Int](repeating: -1, count: n)
        var i = 0
        var j = 0
        while i < n && j < m {
            if quoteWords[i] == words.keys[stretch.lowerBound + j] {
                partner[i] = stretch.lowerBound + j
                i += 1
                j += 1
            } else if table[(i + 1) * width + j] >= table[i * width + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        var score = 0
        var runStart = 0
        while runStart < n {
            guard partner[runStart] >= 0 else {
                runStart += 1
                continue
            }
            var runEnd = runStart + 1
            while runEnd < n, partner[runEnd] >= 0, partner[runEnd] == partner[runEnd - 1] + 1 { runEnd += 1 }
            if runEnd - runStart >= Self.tolerantMinimumRun {
                for k in runStart..<runEnd { score += k >= placeIndex ? 2 : 1 }
            }
            runStart = runEnd
        }
        guard score > 0 else { return nil }
        if placeIndex < n, partner[placeIndex] >= 0 {
            return Spot(word: partner[placeIndex], score: score)
        }
        if let last = (0..<placeIndex).last(where: { partner[$0] >= 0 }) {
            return Spot(word: partner[last] + 1, score: score)
        }
        if let first = (placeIndex..<n).first(where: { partner[$0] >= 0 }) {
            return Spot(word: partner[first], score: score)
        }
        return nil
    }

    /// Chooses among `spots` (in the book's order) by the tie and locality
    /// rules: the best spot scoring `minimum` or more is found when it is
    /// the only one so scored; spots scored alike give the one nearest
    /// `expected` as a guess; and when none of the best is near `expected`
    /// while a spot near it scores `localMinimum` or more, that near spot
    /// (the best scored, then the nearest, of those) is the guess. Also
    /// returns that near spot, which the first search's far spot yields to.
    private func choose(among spots: [Spot], minimum: Int, localMinimum: Int, expected: Double) -> (search: Search, local: Spot?) {
        var local: Spot?
        for spot in spots where spot.score >= localMinimum && isNear(spot.word, expected) {
            guard let current = local else {
                local = spot
                continue
            }
            if spot.score > current.score
                || (spot.score == current.score && distance(ofWord: spot.word, from: expected) < distance(ofWord: current.word, from: expected)) {
                local = spot
            }
        }
        guard let best = spots.map(\.score).max(), best >= minimum else { return (.notFound, local) }
        let top = spots.filter { $0.score == best }
        if !top.contains(where: { isNear($0.word, expected) }), let local {
            return (.guessed(word: local.word, .nearWhereItWas), local)
        }
        // The nearest of the best, the earlier of two equally near.
        guard var nearest = top.first else { return (.notFound, local) }
        for spot in top.dropFirst() where distance(ofWord: spot.word, from: expected) < distance(ofWord: nearest.word, from: expected) {
            nearest = spot
        }
        return (top.count == 1 ? .found(nearest) : .guessed(word: nearest.word, .nearestOfEqualSpots), local)
    }

    // MARK: - Scores and Distances

    /// How well `quote` fits a place standing before word `word`: 2 for each
    /// word after the place that agrees, in order up to the first that
    /// doesn't, and 1 for each word before it likewise.
    private func score(at word: Int, _ quote: Quote) -> Int {
        guard word >= 0 else { return 0 }
        let keys = words.keys
        var score = 0
        var k = 0
        while k < quote.after.count, word + k < keys.count, keys[word + k] == quote.after[k] {
            score += 2
            k += 1
        }
        k = 0
        while k < quote.before.count, word - 1 - k >= 0, keys[word - 1 - k] == quote.before[quote.before.count - 1 - k] {
            score += 1
            k += 1
        }
        return score
    }

    /// Whether the book's words from `start` on are `run`, word for word.
    private func agrees(_ run: ArraySlice<UInt64>, at start: Int) -> Bool {
        guard start >= 0, start + run.count <= words.count else { return false }
        return zip(words.keys[start..<(start + run.count)], run).allSatisfy { $0 == $1 }
    }

    /// Whether a place standing before word `word` is near `expected`
    /// (UTF-16 units into the book).
    private func isNear(_ word: Int, _ expected: Double) -> Bool {
        distance(ofWord: word, from: expected) <= localityWindow
    }

    /// How far word `word` begins from `expected`, in UTF-16 units.
    private func distance(ofWord word: Int, from expected: Double) -> Double {
        abs(Double(words.globalStart(ofWord: word)) - expected)
    }

    /// Where `heading` starts.
    private func place(of heading: Heading) -> TextPlace {
        TextPlace(chapter: heading.chapterIndex, offset: heading.characterOffset)
    }

    // MARK: - Where a Found Place Lands

    /// The place a search found standing before word `word`, by the one
    /// landing rule (`BookWords.landing`): that word's start; a place that
    /// stood inside its own word keeps how far into it it was, when the word
    /// there is that word; and a place with no words after it in its quote
    /// (at its chapter's end, or before nothing but punctuation there)
    /// stands just after the word before it.
    private func landing(beforeWord word: Int, _ quote: Quote) -> TextPlace {
        words.landing(beforeWord: word, inside: quote.inside, nothingAfter: quote.after.isEmpty)
    }

    /// The last guess, for a place whose words are found nowhere: the same
    /// share of its chapter as it had when saved (when `savedChapterLength`
    /// is known), or else its saved offset held within the chapter, at the
    /// start of the word there; for a chapter the book no longer has, the
    /// same share of the whole book (`fraction`), at a word start.
    private func sameShareGuess(saved: TextPlace, savedChapterLength: Int?, fraction: Double) -> TextPlace {
        guard words.chapterCount > 0 else { return TextPlace(chapter: 0, offset: 0) }
        let place: TextPlace
        if saved.chapter >= 0, saved.chapter < words.chapterCount {
            let length = words.length(ofChapter: saved.chapter)
            let offset = max(saved.offset, 0)
            let target: Int
            if let savedChapterLength, savedChapterLength > 0 {
                target = Int(Double(min(offset, savedChapterLength)) / Double(savedChapterLength) * Double(length))
            } else {
                target = min(offset, length)
            }
            place = TextPlace(chapter: saved.chapter, offset: target)
        } else {
            place = words.place(atGlobalOffset: Int(fraction * Double(words.totalLength)))
        }
        return TextPlace(
            chapter: place.chapter,
            offset: ReaderViewModel.snappedWordStart(in: words.texts[place.chapter], at: place.offset)
        )
    }
}
