import Foundation

// MARK: - Inputs

/// Everything one chapter's speech is prepared from, as values: the
/// chapter's text, the sections of it that are skipped, how runs of a
/// repeated symbol are read, the punctuation pause level, and the
/// substitution rules.
///
/// Preparing speech reads nothing else, so speech prepared from equal inputs
/// is the same speech, and a reader uses what it prepared again for as long
/// as the inputs stay the same (`ChapterSpeechCache`). Being values, the
/// inputs can also be carried off the main actor, where a long chapter is
/// prepared. The voice is not among them: it shapes the audio rendered from
/// the speech, which its render signature covers, not the speech itself.
struct ChapterSpeechInputs: Equatable, Sendable {
    /// The chapter's index in its book.
    let chapterIndex: Int
    /// The chapter's text, as the book holds it.
    let text: String
    /// The chapter's headings while any of its sections is skipped, and
    /// otherwise none: without a skipped section they shape nothing, so a
    /// section skipped in another chapter leaves these inputs as they were.
    let headings: [Heading]
    /// The IDs of the chapter's skipped headings.
    let skippedHeadingIDs: Set<String>
    /// How runs of a repeated symbol are read.
    let repeatedSymbolRule: RepeatedSymbolRule
    /// The punctuation pause level, 0 for none.
    let punctuationPauseLevel: Double
    /// The substitution rules in force.
    let substitutions: SubstitutionPass

    /// The inputs of chapter `chapterIndex`, whose text is `text` and whose
    /// headings are `chapterHeadings`, in a book whose skipped headings are
    /// `bookSkippedHeadingIDs`.
    init(
        chapterIndex: Int,
        text: String,
        chapterHeadings: [Heading],
        bookSkippedHeadingIDs: Set<String>,
        repeatedSymbolRule: RepeatedSymbolRule,
        punctuationPauseLevel: Double,
        substitutions: SubstitutionPass
    ) {
        let skipped = bookSkippedHeadingIDs.intersection(chapterHeadings.lazy.map(\.id))
        self.chapterIndex = chapterIndex
        self.text = text
        self.headings = skipped.isEmpty ? [] : chapterHeadings
        self.skippedHeadingIDs = skipped
        self.repeatedSymbolRule = repeatedSymbolRule
        self.punctuationPauseLevel = punctuationPauseLevel
        self.substitutions = substitutions
    }

    /// Whether the chapter is too long to be rendered ahead, so that the
    /// look-ahead prepares its speech off the main actor instead of holding
    /// the main thread for the preparation, a quarter of a second or more
    /// per million UTF-16 units.
    var isLong: Bool {
        text.utf16Length > SpeechRenderCoordinator.maximumTextLength
    }

    /// The chapter's speech: skipped sections removed, runs of a repeated
    /// symbol rewritten, punctuation pauses added, then the substitution
    /// rules applied, with the map through every stage.
    ///
    /// Repeated symbols are rewritten before the pauses are added: the pause
    /// marks are periods and commas, which would lengthen runs of those
    /// symbols, and the substitution rules then see the counts.
    ///
    /// Pure: it reads nothing but these inputs, so it may run on any thread.
    func prepare() -> ReaderViewModel.ChapterSpeech {
        // Each stage reports how it shifted character offsets; composing the
        // stages converts between original chapter text and spoken text.
        let (filteredText, filterMap) = SkippedSectionFilter.apply(
            text: text,
            headings: headings,
            skippedIDs: skippedHeadingIDs
        )
        let (symbolText, symbolMap) = repeatedSymbolRule.apply(to: filteredText)
        let (pausedText, pauseMap) = ReaderViewModel.applyPunctuationPauses(symbolText, level: punctuationPauseLevel)
        let transformation = substitutions.transform(pausedText)
        return ReaderViewModel.ChapterSpeech(
            inputs: self,
            transformation: transformation,
            offsetMap: ComposedOffsetMap(stages: [filterMap, symbolMap, pauseMap] + transformation.offsetMap.stages)
        )
    }

    /// Whether two sets of inputs are the same. The texts must be the same
    /// bytes, not only equal as Swift compares strings: two spellings of an
    /// accented letter are equal strings, but their speech is spoken from
    /// other characters, at other offsets.
    static func == (lhs: ChapterSpeechInputs, rhs: ChapterSpeechInputs) -> Bool {
        lhs.chapterIndex == rhs.chapterIndex
            && lhs.punctuationPauseLevel == rhs.punctuationPauseLevel
            && lhs.repeatedSymbolRule == rhs.repeatedSymbolRule
            && lhs.skippedHeadingIDs == rhs.skippedHeadingIDs
            && lhs.headings == rhs.headings
            && lhs.substitutions == rhs.substitutions
            && haveSameBytes(lhs.text, rhs.text)
    }

    /// Whether two texts are the same bytes. A chapter's text and the inputs
    /// made from it share their storage, which is noticed without reading a
    /// byte; other texts of the same length are compared in one call.
    private static func haveSameBytes(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs.utf8.count == rhs.utf8.count else { return false }
        guard !lhs.isEmpty else { return true }
        let compared = lhs.utf8.withContiguousStorageIfAvailable { left in
            rhs.utf8.withContiguousStorageIfAvailable { right in
                guard let leftStart = left.baseAddress, let rightStart = right.baseAddress else { return false }
                return leftStart == rightStart || memcmp(leftStart, rightStart, left.count) == 0
            }
        }
        // A text bridged from Objective-C may keep no contiguous bytes.
        return (compared ?? nil) ?? lhs.utf8.elementsEqual(rhs.utf8)
    }
}

// MARK: - Cache

/// The speech a reader prepared, so each chapter is prepared once for as
/// long as everything it is prepared from stays the same (PERF02).
///
/// Speech used to be prepared afresh at Play, when the look-ahead chose the
/// next chapter, when its render finished, at the chapter's end, and at
/// every speed, pitch, or voice step in Settings: about 36 ms of silence at
/// each boundary of a 40,000-character chapter, and 3.4 s for a chapter of a
/// million. Each prepared chapter records the inputs it was prepared from
/// (`ChapterSpeechInputs`), and is used again only while they are all the
/// same, so no change to any of them, made anywhere, is ever missed.
///
/// The cache keeps the chapters prepared last, and, apart from them, the
/// speech the look-ahead chose for the next chapter, carried to the moment
/// that chapter begins however many other chapters are prepared meanwhile.
/// It also remembers which long chapters are being prepared in the
/// background, and which of them the look-ahead, or Play, waits for.
///
/// A value stored in its reader and changed only on the main actor, where
/// the reader lives.
struct ChapterSpeechCache {
    /// How many recently prepared chapters are kept besides the
    /// look-ahead's: room for the cursor's chapter, the next one, and the
    /// silent chapters a search passes over between them.
    static let capacity = 4

    /// The chapters prepared last, the one used most recently last; at most
    /// one for each chapter.
    private var recent: [ReaderViewModel.ChapterSpeech] = []

    /// The speech the look-ahead chose for the next chapter, kept until the
    /// look-ahead is forgotten whatever else is prepared meanwhile, so the
    /// chapter end finds it ready.
    var lookAheadSpeech: ReaderViewModel.ChapterSpeech?

    /// The inputs of the long chapter the look-ahead waits for while it is
    /// prepared in the background, or nil.
    var awaitedByLookAhead: ChapterSpeechInputs?

    /// The inputs of the long chapter Play waits for while it is prepared in
    /// the background, and, once prepared, while a Where Am I announcement
    /// holds the play, or nil (`ReaderViewModel.isWaitingForChapterSpeech`).
    var awaitedByPlay: ChapterSpeechInputs?

    /// The inputs of the long chapters being prepared in the background.
    private var preparingInBackground: [ChapterSpeechInputs] = []

    /// How many times speech was asked for and none was kept for its
    /// inputs: each such request is prepared. Read by the tests.
    private(set) var misses = 0

    /// Whether nothing is kept, being prepared, or waited for, as after
    /// `removeAll()`.
    var isEmpty: Bool {
        recent.isEmpty && lookAheadSpeech == nil && awaitedByLookAhead == nil && awaitedByPlay == nil
            && preparingInBackground.isEmpty
    }

    /// The speech prepared from exactly `inputs`, when it is kept; a miss
    /// otherwise.
    mutating func speech(for inputs: ChapterSpeechInputs) -> ReaderViewModel.ChapterSpeech? {
        if let carried = lookAheadSpeech, carried.inputs == inputs {
            return carried
        }
        guard let index = recent.lastIndex(where: { $0.inputs == inputs }) else {
            misses += 1
            return nil
        }
        // Used again, it becomes the most recent.
        let speech = recent.remove(at: index)
        recent.append(speech)
        return speech
    }

    /// Keep `speech` as the most recent, in place of any speech of its
    /// chapter prepared from other inputs, which those inputs' change made
    /// stale, and forget the chapter used longest ago beyond `capacity`.
    mutating func keep(_ speech: ReaderViewModel.ChapterSpeech) {
        recent.removeAll { $0.chapterIndex == speech.chapterIndex }
        recent.append(speech)
        if recent.count > Self.capacity {
            recent.removeFirst(recent.count - Self.capacity)
        }
    }

    /// Note that `inputs` are being prepared in the background. False, and
    /// nothing noted, when they already are, so they are never prepared
    /// twice at once.
    mutating func beginPreparingInBackground(_ inputs: ChapterSpeechInputs) -> Bool {
        guard !isPreparingInBackground(inputs) else { return false }
        preparingInBackground.append(inputs)
        return true
    }

    /// Note that the background preparation of `inputs` has ended.
    mutating func endPreparingInBackground(_ inputs: ChapterSpeechInputs) {
        if let index = preparingInBackground.firstIndex(of: inputs) {
            preparingInBackground.remove(at: index)
        }
    }

    /// Whether `inputs` are being prepared in the background.
    func isPreparingInBackground(_ inputs: ChapterSpeechInputs) -> Bool {
        preparingInBackground.contains(inputs)
    }

    /// Whether speech prepared from exactly `inputs` is kept, or is being
    /// prepared in the background, asked without counting a miss or making
    /// any kept speech the most recent, as `speech(for:)` would.
    func isKeptOrPreparing(_ inputs: ChapterSpeechInputs) -> Bool {
        isKept(inputs) || isPreparingInBackground(inputs)
    }

    /// Whether `inputs` are being prepared in the background while no
    /// speech is kept for them yet, so that a caller can wait for that
    /// preparation rather than prepare them again; asked without counting a
    /// miss, as `isKeptOrPreparing(_:)` is.
    func isOnlyBeingPreparedInBackground(_ inputs: ChapterSpeechInputs) -> Bool {
        isPreparingInBackground(inputs) && !isKept(inputs)
    }

    /// Whether speech prepared from exactly `inputs` is kept, asked without
    /// counting a miss or making any kept speech the most recent.
    func isKept(_ inputs: ChapterSpeechInputs) -> Bool {
        lookAheadSpeech?.inputs == inputs || recent.contains { $0.inputs == inputs }
    }

    /// Forget the look-ahead's speech and the preparation it waits for, as
    /// the look-ahead itself is forgotten. Its speech stays among the
    /// recent chapters.
    mutating func forgetLookAhead() {
        lookAheadSpeech = nil
        awaitedByLookAhead = nil
    }

    /// Forget all kept speech, and the preparations the look-ahead and Play
    /// wait for, as a closed reader does. Background preparations still
    /// running end as usual, and keep nothing.
    mutating func removeAll() {
        recent.removeAll()
        lookAheadSpeech = nil
        awaitedByLookAhead = nil
        awaitedByPlay = nil
        preparingInBackground.removeAll()
    }
}
