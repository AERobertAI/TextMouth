import Foundation

// MARK: - Style

/// How TextMouth's own speech reads a run of one repeated symbol, such as a
/// separator line of asterisks (Text settings, Repeated Symbols).
///
/// Only the text handed to the speech engine changes. The displayed text,
/// the text cache, and what VoiceOver and a braille display read stay
/// exactly as the book has them.
///
/// The raw values are the words config.json holds (`repeatedSymbolStyle`).
enum RepeatedSymbolStyle: String, CaseIterable, Codable, Sendable {
    /// Read every symbol as written: "asterisk asterisk asterisk".
    case repeatEach = "repeat"
    /// Read a run at least as long as the threshold as a count: "7 asterisks".
    case sayCount = "count"
    /// Leave out a run at least as long as the threshold, pausing in its place.
    case leaveOut = "omit"
}

// MARK: - Rule

/// The repeated-symbol setting, applied to a chapter's text as speech
/// prepares it.
///
/// A run is one symbol from `symbols` written two or more times in a row,
/// with nothing or a single space between neighbours: `* * * * * * *` is one
/// run of 7 asterisks and `====` one run of 4 equals signs. A different
/// symbol, a letter or digit, a line break, or two spaces in a row end a
/// run. Under `.sayCount` or `.leaveOut`, a run of at least `threshold`
/// symbols is rewritten; shorter runs, and every run under `.repeatEach` or
/// with the threshold switched off (-1), are read as written.
struct RepeatedSymbolRule: Equatable, Sendable {
    /// What happens to a run long enough to be collapsed.
    let style: RepeatedSymbolStyle
    /// The fewest symbols a run must have to be collapsed, from 2 to 99, or
    /// `SettingsPolicy.repeatedSymbolThreshold.offValue` (-1) to collapse none.
    let threshold: Int
    /// The symbols that can form runs, each once, in the order listed.
    let symbols: String
    /// `symbols` as a set, for the scan.
    private let symbolSet: Set<Character>

    /// A rule with these settings, each validated as `SettingsPolicy`
    /// validates a stored one: the threshold is clamped (any negative value
    /// switches it off), and the symbols keep only the first copy of each
    /// character that can form runs.
    init(style: RepeatedSymbolStyle, threshold: Int, symbols: String) {
        self.style = style
        self.threshold = SettingsPolicy.repeatedSymbolThreshold.validated(threshold)
        self.symbols = SettingsPolicy.repeatedSymbolSet.validated(symbols)
        symbolSet = Set(self.symbols)
    }

    /// The rule until the user changes it: runs of 4 or more of the default
    /// symbols are read as a count.
    static let standard = RepeatedSymbolRule(
        style: SettingsPolicy.repeatedSymbolStyle.defaultValue,
        threshold: SettingsPolicy.repeatedSymbolThreshold.defaultValue,
        symbols: SettingsPolicy.repeatedSymbolSet.defaultValue
    )

    /// Whether the rule can change any text at all: it cannot while it
    /// repeats each symbol, while it never collapses, or with no symbols.
    var collapsesRuns: Bool {
        style != .repeatEach
            && threshold != SettingsPolicy.repeatedSymbolThreshold.offValue
            && !symbolSet.isEmpty
    }

    /// Whether `character` can be one of the symbols that form runs: a
    /// punctuation mark or a symbol, judged by the Unicode general category
    /// of its first scalar. Letters, digits, spaces, line breaks, and
    /// invisible format characters never can.
    static func canFormRuns(_ character: Character) -> Bool {
        guard let first = character.unicodeScalars.first else { return false }
        switch first.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }

    // MARK: Applying the rule

    /// `text` as speech should read it, with every run long enough rewritten
    /// in this rule's style, and the map between offsets in `text` and in the
    /// result.
    ///
    /// Outside the runs it rewrote, the map converts offsets exactly. Inside
    /// one, it keeps every offset inside the matching span of the other text:
    /// a position anywhere in a run of 80 equals signs maps into the words
    /// "80 equals signs", and a word of those maps back into the run. Seeking
    /// into the middle of a long separator therefore never skips the text
    /// after it, and a word spoken from a count is highlighted on its run.
    ///
    /// Text with nothing to rewrite comes back unchanged with an identity
    /// map, as the other speech preparation stages return it.
    func apply(to text: String) -> (text: String, offsetMap: OffsetMap) {
        guard collapsesRuns else { return (text, .identity) }
        let runs = Self.runs(in: text, of: symbolSet, minimumCount: threshold)
        guard !runs.isEmpty else { return (text, .identity) }

        // The pause left for an omitted run is only needed while speech goes
        // on after it, which it does up to the last character that is not
        // white space.
        let lastSpeakable = text.lastIndex { !$0.isWhitespace }
        var spoken = ""
        spoken.reserveCapacity(text.utf8.count)
        var map = SpanReplacementMap()
        var copiedUpTo = text.startIndex
        var hasSpokenWords = false

        for run in runs {
            let unchanged = text[copiedUpTo..<run.range.lowerBound]
            spoken += unchanged
            hasSpokenWords = hasSpokenWords || ReaderViewModel.hasSpeakableText(unchanged)

            let speechContinues = lastSpeakable.map { run.range.upperBound <= $0 } ?? false
            let words = replacementWords(
                for: run,
                in: text,
                afterSpokenWords: hasSpokenWords,
                beforeMoreSpeech: speechContinues
            )
            let replacement = Self.padded(
                words,
                after: spoken.last,
                before: run.range.upperBound < text.endIndex ? text[run.range.upperBound] : nil
            )
            map.replace(sourceRange: run.utf16Range, withLength: replacement.utf16.count)
            spoken += replacement
            hasSpokenWords = hasSpokenWords || !words.isEmpty
            copiedUpTo = run.range.upperBound
        }
        spoken += text[copiedUpTo...]
        return (spoken, map.offsetMap)
    }

    /// The words that take `run`'s place, before any spacing is added.
    ///
    /// - Parameters:
    ///   - run: A run long enough to be collapsed.
    ///   - text: The text the run is in.
    ///   - afterSpokenWords: Whether anything speakable comes before the run.
    ///   - beforeMoreSpeech: Whether anything speakable follows the run.
    private func replacementWords(
        for run: Run,
        in text: String,
        afterSpokenWords: Bool,
        beforeMoreSpeech: Bool
    ) -> String {
        switch style {
        case .repeatEach:
            // `apply` rewrites nothing in this style; reading the run as
            // written keeps this answer right even so.
            return String(text[run.range])
        case .sayCount:
            return "\(run.count) \(RepeatedSymbolNames.plural(of: run.symbol))"
        case .leaveOut:
            // A lone period is the sentence boundary the speech engine
            // pauses at without saying a word, the same mark the punctuation
            // pauses add. It is left only between pieces of speech, so a
            // chapter of nothing but separators stays silent and is passed
            // over, and no chapter begins or ends on a stray pause.
            return afterSpokenWords && beforeMoreSpeech ? "." : ""
        }
    }

    /// `words` with a space in front when the speech so far ends in a
    /// character that is not white space, and a space after when the text
    /// after the run begins with such a character, so the words never run
    /// into their neighbours: "Name:________" becomes "Name: 8 underscores".
    /// Nothing is added to an empty replacement.
    static func padded(_ words: String, after previous: Character?, before next: Character?) -> String {
        guard !words.isEmpty else { return words }
        let leading = previous.map { !$0.isWhitespace } ?? false ? " " : ""
        let trailing = next.map { !$0.isWhitespace } ?? false ? " " : ""
        return leading + words + trailing
    }

    // MARK: Finding runs

    /// One run of a repeated symbol in a text.
    struct Run: Equatable {
        /// The symbol repeated.
        let symbol: Character
        /// How many times it is written.
        let count: Int
        /// Where the run is, from its first symbol to its last; the single
        /// spaces between symbols belong to it.
        let range: Range<String.Index>
        /// The same span in UTF-16 offsets, the units of every offset map.
        let utf16Range: Range<Int>
    }

    /// Every run in `text` of a symbol in `symbols` that has at least
    /// `minimumCount` symbols, in text order. A shorter run is passed over
    /// whole, so none of its symbols starts another run.
    static func runs(in text: String, of symbols: Set<Character>, minimumCount: Int) -> [Run] {
        var runs: [Run] = []
        var index = text.startIndex
        var offset = 0
        while index < text.endIndex {
            let symbol = text[index]
            let symbolEnd = text.index(after: index)
            let symbolLength = symbol.utf16.count
            guard symbols.contains(symbol) else {
                index = symbolEnd
                offset += symbolLength
                continue
            }
            // Extend the run over each further copy of the symbol, written
            // straight after the last one or after a single space.
            var count = 1
            var runEnd = symbolEnd
            var runEndOffset = offset + symbolLength
            while let copy = nextCopy(of: symbol, in: text, at: runEnd) {
                count += 1
                runEnd = copy.end
                runEndOffset += copy.utf16Length
            }
            if count >= max(minimumCount, 2) {
                runs.append(Run(
                    symbol: symbol,
                    count: count,
                    range: index..<runEnd,
                    utf16Range: offset..<runEndOffset
                ))
            }
            index = runEnd
            offset = runEndOffset
        }
        return runs
    }

    /// The end of the next copy of `symbol` when one begins at `start`,
    /// directly or after a single space, with the UTF-16 length of the space
    /// and the copy; nil when the run ends at `start`.
    private static func nextCopy(
        of symbol: Character,
        in text: String,
        at start: String.Index
    ) -> (end: String.Index, utf16Length: Int)? {
        guard start < text.endIndex else { return nil }
        var position = start
        var length = 0
        if isGap(text[position]) {
            length += text[position].utf16.count
            position = text.index(after: position)
            guard position < text.endIndex else { return nil }
        }
        guard text[position] == symbol else { return nil }
        length += text[position].utf16.count
        return (text.index(after: position), length)
    }

    /// Whether `character` may stand between two symbols of one run: a
    /// single space of any width, including a no-break space or a tab, but
    /// never a line break.
    static func isGap(_ character: Character) -> Bool {
        character.isWhitespace && !character.isNewline
    }
}

// MARK: - Offset map for replaced spans

/// Builds the `OffsetMap` of a stage that replaces spans of a text with
/// other text, keeping offsets inside each replaced span inside the matching
/// span of the other text, in both directions.
///
/// `OffsetMap` shifts offsets by a constant between breakpoints, so a single
/// breakpoint after a replacement, as the substitution and filter stages
/// use, maps the inside of a span linearly: the middle of an 80-symbol run
/// would land 50 characters past its 15-character replacement, inside the
/// next sentence. Here the inside of the longer span is folded onto the
/// shorter one in pieces, each starting again just after the shorter span's
/// first character, so every offset stays within the replacement or its run.
///
/// Each span keeps its start and end exactly: the start of a run maps to the
/// start of its replacement and back, and so does the end. An empty
/// replacement's start is its end, so it maps back to the run's end.
struct SpanReplacementMap {
    /// The breakpoints so far, in target order, as `OffsetMap` takes them.
    private(set) var points: [(targetPos: Int, cumulativeDelta: Int)] = []
    /// Source offset minus target offset after the last replacement.
    private var delta = 0

    /// The finished map.
    var offsetMap: OffsetMap {
        OffsetMap(points: points)
    }

    /// Records that `sourceRange` of the source text is replaced by
    /// `length` UTF-16 units of target text. Replacements must be recorded
    /// in text order and must not overlap.
    mutating func replace(sourceRange: Range<Int>, withLength length: Int) {
        let sourceStart = sourceRange.lowerBound
        let sourceLength = sourceRange.count
        let targetStart = sourceStart - delta
        if length < sourceLength {
            foldLongerSource(
                sourceStart: sourceStart,
                sourceLength: sourceLength,
                targetStart: targetStart,
                targetLength: length
            )
        } else if length > sourceLength {
            foldLongerTarget(
                sourceStart: sourceStart,
                sourceLength: sourceLength,
                targetStart: targetStart,
                targetLength: length
            )
        }
        // Equal lengths map one to one, with no breakpoint at all.
        delta += sourceLength - length
    }

    /// A breakpoint from which target offset `target` maps to source offset
    /// `source`, and on by one for one.
    private mutating func addPoint(target: Int, source: Int) {
        points.append((targetPos: target, cumulativeDelta: source - target))
    }

    /// Maps a source span longer than its replacement.
    ///
    /// The source span after its first character is cut into pieces, each
    /// mapped onto the replacement after its first character, so no source
    /// offset lands past the replacement; the span's first character keeps
    /// mapping to the replacement's start. The last piece is aligned with the
    /// span's end, which therefore maps exactly. Every breakpoint sits just
    /// after the replacement's first character, so in the target direction
    /// that character maps to the span's start and the rest, as the last
    /// piece decides, onto the span's end. Every source offset after the
    /// first character of a span replaced by one character or none maps to
    /// the replacement's end.
    private mutating func foldLongerSource(
        sourceStart: Int,
        sourceLength: Int,
        targetStart: Int,
        targetLength: Int
    ) {
        let target = targetStart + min(targetLength, 1)
        let pieceLength = max(targetLength - 1, 1)
        let lastSource = sourceStart + sourceLength - max(targetLength - 1, 0)
        var source = sourceStart + 1
        while source < lastSource {
            addPoint(target: target, source: source)
            source += pieceLength
        }
        addPoint(target: target, source: lastSource)
    }

    /// Maps a replacement longer than its source span.
    ///
    /// The replacement's first characters map one to one onto the span. The
    /// rest is cut into pieces no longer than the span less its first
    /// character, each mapped onto the span after its first character, so no
    /// target offset lands outside the span; the last piece is aligned with
    /// the replacement's end, which therefore maps exactly. Every breakpoint
    /// starts at the span's second character, so in the source direction the
    /// span's first character maps to the replacement's start and the rest,
    /// as the last piece decides, onto the replacement's end.
    private mutating func foldLongerTarget(
        sourceStart: Int,
        sourceLength: Int,
        targetStart: Int,
        targetLength: Int
    ) {
        let source = sourceStart + 1
        let pieceLength = max(sourceLength - 1, 1)
        let lastTarget = targetStart + targetLength - max(sourceLength - 1, 0)
        var target = targetStart + sourceLength
        while target < lastTarget {
            addPoint(target: target, source: source)
            target += pieceLength
        }
        addPoint(target: lastTarget, source: source)
    }
}
