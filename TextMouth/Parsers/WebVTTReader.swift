import Foundation

/// Reads a WebVTT file (W3C) as timed text (FMT23): a `WEBVTT` line, a
/// header, then blocks separated by blank lines, each a cue, a comment
/// (`NOTE`), a style sheet (`STYLE`), or a region (`REGION`).
///
/// A cue's block is an optional identifier line, a timing line
/// (`00:01.000 --> 00:02.500 align:start`), and the cue's text, whose
/// markup and voices `TimedTextMarkup` reads. A line holding "-->" that
/// cannot be its block's timing line ends the block, and begins the next,
/// as it does in the W3C's own reader, so a file missing a blank line
/// between two cues reads as two cues, never as one whose text holds a
/// timing line, which a listener would hear read aloud.
///
/// The file is third-party data: it is never trusted, and the reader never
/// logs (its callers do, without the file's words).
enum WebVTTReader {

    /// The words that begin a block holding no cue: a comment, a style
    /// sheet, and a region's definition, each ignored.
    private static let ignoredBlockWords = ["NOTE", "STYLE", "REGION"]

    /// The cues of the WebVTT file whose bytes are `data`, with the count of
    /// those that could not be used (`TimedTextDocument`).
    /// - Parameter maximumCues: the most cues the file may hold.
    /// - Throws: `TimedTextError.notTimedText(.webVTT)` when the file does
    ///   not begin with its `WEBVTT` line, or is not text;
    ///   `.noCues(.webVTT)` when it holds no cue that can be used; and
    ///   `.tooManyCues` as soon as it holds more than `maximumCues`.
    static func read(_ data: Data, maximumCues: Int = TimedTextLimits.maximumCues) throws -> TimedTextDocument {
        let lines = try TimedTextMarkup.lines(of: data, format: .webVTT)
        guard let signature = lines.first, line(signature, isWord: "WEBVTT") else {
            throw TimedTextError.notTimedText(.webVTT)
        }
        var cues = TimedTextCueList(format: .webVTT, maximumCues: maximumCues)
        // The header: the lines after the signature, up to the first blank
        // line or the first line holding "-->", all ignored.
        var index = 1
        while index < lines.count, !TimedTextMarkup.isBlank(lines[index]), !TimedTextMarkup.holdsArrow(lines[index]) {
            index += 1
        }
        // The blocks, each begun by a line that is not blank.
        while index < lines.count {
            guard !TimedTextMarkup.isBlank(lines[index]) else {
                index += 1
                continue
            }
            let block = self.block(at: index, in: lines)
            if let timingLine = block.timingLine {
                try cues.read(timingLine: lines[timingLine], textLines: lines[(timingLine + 1)..<block.end])
            }
            index = block.end
        }
        return try cues.document()
    }

    /// The block that begins at `start`, a line that is not blank: its
    /// timing line, if it has one, and the index just past its last line.
    ///
    /// The timing line is the block's first line when that holds "-->",
    /// else its second when that does (the first is the cue's identifier,
    /// which is ignored). A comment, style sheet, or region has none, and a
    /// block without one is ignored. The block's lines after its timing
    /// line, or after its first line when it has none, run to the first
    /// blank line or the first line holding "-->", which begins the next
    /// block.
    private static func block(at start: Int, in lines: [TimedTextMarkup.Line]) -> (timingLine: Int?, end: Int) {
        let holdsNoCue = ignoredBlockWords.contains { line(lines[start], isWord: $0) }
        let timingLine = holdsNoCue ? nil : [start, start + 1].first { candidate in
            candidate < lines.count && TimedTextMarkup.holdsArrow(lines[candidate])
        }
        var end = (timingLine ?? start) + 1
        while end < lines.count, !TimedTextMarkup.isBlank(lines[end]), !TimedTextMarkup.holdsArrow(lines[end]) {
            end += 1
        }
        return (timingLine, end)
    }

    /// Whether `line` is `word` alone, or `word` followed by a space or a
    /// tab and anything (`WEBVTT - four tones`, `NOTE a comment`): how the
    /// signature line and the blocks holding no cue begin. `WEBVTTX` and
    /// `NOTES` are not.
    private static func line(_ line: TimedTextMarkup.Line, isWord word: String) -> Bool {
        guard line.starts(with: word.utf8) else { return false }
        guard let next = line.dropFirst(word.utf8.count).first else { return true }
        return TimedTextMarkup.Byte.isSpaceOrTab(next)
    }
}
