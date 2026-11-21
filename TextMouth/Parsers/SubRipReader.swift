import Foundation

/// Reads a SubRip file (.srt) as timed text (FMT23): numbered cues, each a
/// number, a timing line (`00:00:01,000 --> 00:00:02,500`), and the cue's
/// text, separated by blank lines.
///
/// SubRip has no standard, so the reader takes what real files hold: cue
/// numbers out of order or missing, a missing blank line between two cues,
/// coordinates after the times (`X1:40 X2:600`), the tags and overrides of
/// subtitle editors (`<i>`, `<font color="red">`, `{\an8}`), and any text
/// encoding (`TimedTextMarkup.lines(of:format:)`). Only the timing lines
/// structure the file: whatever lies outside a cue is passed over.
///
/// The file is third-party data: it is never trusted, and the reader never
/// logs (its callers do, without the file's words).
enum SubRipReader {

    /// The cues of the SubRip file whose bytes are `data`, with the count of
    /// those that could not be used (`TimedTextDocument`).
    ///
    /// Each line holding "-->" begins a cue, which is passed over when its
    /// times do not read (`TimedTextMarkup.cue(timingLine:textLines:removingOverrides:)`);
    /// the lines before the first, and between a cue's text and the next,
    /// are ignored, cue numbers among them.
    /// - Parameter maximumCues: the most cues the file may hold.
    /// - Throws: `TimedTextError.notTimedText(.subRip)` when the file is not
    ///   text; `.noCues(.subRip)` when it holds no cue that can be used; and
    ///   `.tooManyCues` as soon as it holds more than `maximumCues`.
    static func read(_ data: Data, maximumCues: Int = TimedTextLimits.maximumCues) throws -> TimedTextDocument {
        let lines = try TimedTextMarkup.lines(of: data, format: .subRip)
        var cues = TimedTextCueList(format: .subRip, maximumCues: maximumCues)
        var index = 0
        while index < lines.count {
            guard TimedTextMarkup.holdsArrow(lines[index]) else {
                index += 1
                continue
            }
            let textEnd = endOfText(after: index, in: lines)
            try cues.read(timingLine: lines[index], textLines: lines[(index + 1)..<textEnd])
            index = textEnd
        }
        return try cues.document()
    }

    /// The index just past the last line of the cue whose timing line is
    /// at `timingLine`: its text runs to the first blank line, the next line
    /// holding "-->", or the next cue's number written without the blank
    /// line before it (a line of digits alone directly followed by a timing
    /// line whose times read). A cue's number is never its text, and a line
    /// of digits followed by anything else is: "We counted to" and "3".
    /// The lines after a timing line whose times do not read end the same
    /// way, so one broken cue never takes the next cue's lines with it.
    private static func endOfText(after timingLine: Int, in lines: TimedTextMarkup.Lines) -> Int {
        var index = timingLine + 1
        while index < lines.count {
            let line = lines[index]
            if TimedTextMarkup.isBlank(line) || TimedTextMarkup.holdsArrow(line) {
                break
            }
            if isCueNumber(line), index + 1 < lines.count, isReadableTimingLine(lines[index + 1]) {
                break
            }
            index += 1
        }
        return index
    }

    /// Whether `line` is a cue's number: digits alone, with spaces or tabs
    /// around them allowed.
    private static func isCueNumber(_ line: TimedTextMarkup.Line) -> Bool {
        let number = TimedTextMarkup.trimmingSpacesAndTabs(line)
        return !number.isEmpty && number.allSatisfy(TimedTextMarkup.Byte.isDigit)
    }

    /// Whether `line` is a timing line whose start and end both read.
    private static func isReadableTimingLine(_ line: TimedTextMarkup.Line) -> Bool {
        TimedTextMarkup.timing(of: line)?.reads ?? false
    }
}
