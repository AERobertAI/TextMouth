import Foundation
import NaturalLanguage

/// One stretch of a recognizer's result: a word as the recognizer timed it,
/// with whatever spaces it wrote around it (" safety"), or text it gave no
/// usable time.
struct TranscribedPiece: Equatable, Sendable {
    /// The piece's text as the recognizer wrote it, spaces included.
    var text: String
    /// When the piece begins in its file, in seconds; nil when the
    /// recognizer gave it no time, or a time that is not a number.
    var start: TimeInterval?
    /// When the piece ends in its file, in seconds; nil with `start`.
    var end: TimeInterval?
    /// How sure the recognizer was of the piece, from 0 to 1, when it said.
    var confidence: Double?
}

/// One result the recognizer finalized: the stretch of the file it covers
/// and its pieces, in order. A result usually holds one sentence, and can
/// hold several.
struct TranscribedResult: Equatable, Sendable {
    /// When the result's stretch of the file begins, in seconds.
    var start: TimeInterval
    /// When it ends, in seconds.
    var end: TimeInterval
    /// The result's pieces, in the order they were spoken.
    var pieces: [TranscribedPiece]
}

/// Turns one file's recognizer results, in the order they arrive, into the
/// sentences a transcript keeps (`TranscriptSentence`).
///
/// Each result's text is written on one line, with one space wherever the
/// recognizer put any whitespace, and divided into sentences by the system's
/// sentence tokenizer for the transcript's language, which knows that
/// "Dr. Heinz" does not end a sentence. Each timed piece becomes a word of
/// the sentence its first character falls in. A sentence with no timed word
/// joins the sentence before it in its result, or the one after when it
/// comes first; a result with no timed word at all is one sentence spanning
/// the result's stretch of the file.
///
/// Times are kept as `Transcript` validates them: in whole milliseconds,
/// each sentence starting no earlier than the one before it, each word
/// inside its sentence and starting no earlier than the word before it. The
/// recognizer's own times already are, so this only guards against a
/// result that would make a transcript invalid.
struct TranscriptSentenceBuilder {
    /// The sentences built so far, in order.
    private(set) var sentences: [TranscriptSentence] = []
    /// Divides each result's line into sentences. Used only by this
    /// builder, which a single task owns, as NLTokenizer requires.
    private let tokenizer = NLTokenizer(unit: .sentence)

    /// A builder for results in the language `languageCode` names, such as
    /// "en"; nil lets the tokenizer judge the language from the text.
    init(languageCode: String?) {
        if let languageCode {
            tokenizer.setLanguage(NLLanguage(rawValue: languageCode))
        }
    }

    /// Adds the sentences of `result`, the next result of the file.
    mutating func add(_ result: TranscribedResult) {
        let line = Line(result.pieces)
        guard !line.text.isEmpty else { return }
        for sentence in sentenceSpans(of: line) {
            append(sentence, of: line, result: result)
        }
    }

    // MARK: - Lines

    /// A result's text written on one line, with its timed words.
    private struct Line {
        /// One word: its place in the line, in UTF-16 units, and its piece.
        struct Word {
            var offset: Int
            var count: Int
            var piece: TranscribedPiece
        }

        /// The text, with single spaces between its pieces' words and none
        /// at either end.
        private(set) var text = ""
        /// The text's length in UTF-16 units.
        private(set) var length = 0
        /// The timed pieces, in order, each where its words lie in `text`.
        private(set) var words: [Word] = []

        /// The line `pieces` make. A piece's own whitespace (spaces, tabs,
        /// line breaks) becomes single spaces, so the line, and every
        /// sentence cut from it, is one line of single-spaced text.
        init(_ pieces: [TranscribedPiece]) {
            var spaceIsPending = false
            for piece in pieces {
                let parts = piece.text.split(whereSeparator: \.isWhitespace)
                guard !parts.isEmpty else {
                    spaceIsPending = spaceIsPending || !piece.text.isEmpty
                    continue
                }
                if (spaceIsPending || piece.text.first?.isWhitespace == true) && length > 0 {
                    append(" ")
                }
                let core = parts.joined(separator: " ")
                let offset = length
                append(core)
                if piece.start != nil, piece.end != nil {
                    words.append(Word(offset: offset, count: length - offset, piece: piece))
                }
                spaceIsPending = piece.text.last?.isWhitespace == true
            }
        }

        /// Adds `string` to the end of the line.
        private mutating func append(_ string: String) {
            text += string
            length += string.utf16.count
        }
    }

    // MARK: - Sentences

    /// One sentence of a line: where it lies, in UTF-16 units, and its
    /// timed words.
    private struct Span {
        var range: Range<Int>
        var words: [Line.Word]
    }

    /// The sentences of `line`, in order, each with its words, after those
    /// without a timed word have joined a neighbor. A line with no timed
    /// word at all is one sentence without words.
    private func sentenceSpans(of line: Line) -> [Span] {
        var spans = sentenceRanges(in: line.text).map { Span(range: $0, words: []) }
        // Each word goes to the sentence its first character falls in, or,
        // were the tokenizer to leave it between sentences, to the one
        // before it, which then reaches to the word's end.
        for word in line.words {
            let index = spans.lastIndex { $0.range.lowerBound <= word.offset } ?? 0
            let range = spans[index].range
            spans[index].range = min(range.lowerBound, word.offset)..<max(range.upperBound, word.offset + word.count)
            spans[index].words.append(word)
        }

        var joined: [Span] = []
        // Untimed text before the first timed sentence, joining that one.
        var leadingUntimed: Range<Int>?
        for span in spans {
            if let last = joined.indices.last,
               span.words.isEmpty || span.range.lowerBound < joined[last].range.upperBound {
                // An untimed sentence joins the one before it, as does one
                // that a word reaching past its sentence's end overlaps.
                joined[last].range = joined[last].range.lowerBound..<max(joined[last].range.upperBound, span.range.upperBound)
                joined[last].words += span.words
            } else if span.words.isEmpty {
                leadingUntimed = (leadingUntimed?.lowerBound ?? span.range.lowerBound)..<span.range.upperBound
            } else {
                var span = span
                if let leading = leadingUntimed {
                    span.range = leading.lowerBound..<span.range.upperBound
                    leadingUntimed = nil
                }
                joined.append(span)
            }
        }
        if joined.isEmpty, let leading = leadingUntimed {
            joined.append(Span(range: leading, words: []))
        }
        return joined
    }

    /// The sentences of `text` as the tokenizer finds them, each trimmed of
    /// whitespace, as UTF-16 ranges; the whole text when it finds none.
    private func sentenceRanges(in text: String) -> [Range<Int>] {
        tokenizer.string = text
        var ranges: [Range<Int>] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { tokenRange, _ in
            let token = text[tokenRange]
            if let first = token.firstIndex(where: { !$0.isWhitespace }),
               let last = token.lastIndex(where: { !$0.isWhitespace }) {
                let start = text.utf16.distance(from: text.startIndex, to: first)
                let end = text.utf16.distance(from: text.startIndex, to: text.index(after: last))
                ranges.append(start..<end)
            }
            return true
        }
        return ranges.isEmpty ? [0..<text.utf16.count] : ranges
    }

    /// Appends the sentence `span` of `line`, a line of `result`, with its
    /// times kept in order.
    private mutating func append(_ span: Span, of line: Line, result: TranscribedResult) {
        let utf16 = line.text.utf16
        let text = String(utf16[utf16.index(utf16.startIndex, offsetBy: span.range.lowerBound)
            ..< utf16.index(utf16.startIndex, offsetBy: span.range.upperBound)]) ?? ""
        guard !text.isEmpty else { return }

        // No sentence starts before the one before it.
        let floor = sentences.last?.startMilliseconds ?? 0
        let firstStart = span.words.first?.piece.start ?? result.start
        let sentenceStart = max(Transcript.milliseconds(firstStart), floor)

        var words: [TranscriptWord] = []
        var latestEnd = sentenceStart
        for word in span.words {
            // Each word starts no earlier than the sentence and the word
            // before it, and ends no earlier than it starts.
            let start = max(Transcript.milliseconds(word.piece.start ?? 0), words.last?.startMilliseconds ?? sentenceStart)
            let end = max(Transcript.milliseconds(word.piece.end ?? 0), start)
            words.append(TranscriptWord(
                characterOffset: word.offset - span.range.lowerBound,
                characterCount: word.count,
                startMilliseconds: start,
                endMilliseconds: end,
                confidence: Transcript.confidence(word.piece.confidence)
            ))
            latestEnd = max(latestEnd, end)
        }
        let sentenceEnd = words.isEmpty ? max(Transcript.milliseconds(result.end), sentenceStart) : latestEnd
        sentences.append(TranscriptSentence(
            text: text,
            startMilliseconds: sentenceStart,
            endMilliseconds: sentenceEnd,
            words: words
        ))
    }
}
