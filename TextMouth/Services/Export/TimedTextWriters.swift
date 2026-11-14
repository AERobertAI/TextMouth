import Foundation

// MARK: - The Formats a Transcript Is Exported In (FMT23)

/// The formats Export writes a transcript in (FMT23): captions, one file for
/// the book, timed from the start of its audio, which a player shows, and a
/// screen reader can follow, beside the audio. The Transcript checkbox's
/// Convert transcript to picker offers them after JSON and Markdown, the
/// transcript as TextMouth keeps it.
enum TranscriptExportFormat: String, CaseIterable, Sendable {
    /// WebVTT (W3C), which web browsers and most players read.
    case webVTT
    /// SubRip (.srt), which nearly every player reads.
    case subRip

    /// The picker's tag for its first choice, its default: JSON and
    /// Markdown, the transcript as TextMouth keeps it, exported as it always
    /// was, with no conversion. No format's `choiceID` is this.
    static let jsonAndMarkdownChoiceID = "transcript-json"

    /// The format whose picker tag is `choiceID`; nil for JSON and Markdown,
    /// and for a tag the picker does not list.
    init?(choiceID: String) {
        guard let format = Self.allCases.first(where: { $0.choiceID == choiceID }) else { return nil }
        self = format
    }

    /// The format's tag in the picker.
    var choiceID: String {
        switch self {
        case .webVTT: return "transcript-webvtt"
        case .subRip: return "transcript-srt"
        }
    }

    /// The timed-text format of the file written, which gives the format its
    /// name and the file its extension.
    var timedTextFormat: TimedTextFormat {
        switch self {
        case .webVTT: return .webVTT
        case .subRip: return .subRip
        }
    }

    /// The format's name, as the picker lists it and VoiceOver speaks it:
    /// "WebVTT", "SubRip".
    var name: String {
        timedTextFormat.name
    }

    /// The extension of the file written, without its dot: "vtt", "srt".
    var fileExtension: String {
        timedTextFormat.fileExtension
    }

    /// The bytes of a file of `cues` in the format: its text in UTF-8.
    /// SubRip's begins with the UTF-8 byte-order mark, since a SubRip file
    /// names no encoding and Windows players rely on the mark to read UTF-8;
    /// WebVTT's has none, WebVTT being UTF-8 by definition.
    func fileBytes(of cues: [TimedTextCue]) -> Data {
        switch self {
        case .webVTT:
            return Data(WebVTTWriter.text(of: cues).utf8)
        case .subRip:
            return Self.utf8ByteOrderMark + Data(SubRipWriter.text(of: cues).utf8)
        }
    }

    /// The UTF-8 byte-order mark: U+FEFF in UTF-8.
    private static let utf8ByteOrderMark = Data([0xEF, 0xBB, 0xBF])
}

// MARK: - WebVTT

/// Writes cues as a WebVTT file (W3C, "WebVTT: The Web Video Text Tracks
/// Format"): the `WEBVTT` line, then each cue after a blank line, as its
/// timing line, `HH:MM:SS.mmm --> HH:MM:SS.mmm`, over its text on one line.
/// It writes no identifiers, no settings, and no voice tags: a transcript's
/// sentence already says its speaker, as "Ana: ".
enum WebVTTWriter {
    /// The text of a WebVTT file of `cues`, in their order: "WEBVTT\n"
    /// alone for none.
    ///
    /// A cue's text is written on one line (`TimedTextCue.plainText`),
    /// escaped as XML escapes text (`XMLEscaping.text`): `&` as `&amp;`, `<`
    /// as `&lt;`, and `>` as `&gt;`, so that it can hold neither a tag nor
    /// the `-->` of a timing line, with the control characters XML forbids
    /// left out. A cue left with no text is passed over. WebVTT requires a
    /// cue to end after it begins, so one that would end where it begins is
    /// written ending a millisecond later.
    static func text(of cues: [TimedTextCue]) -> String {
        var text = "WEBVTT\n"
        for cue in cues {
            // Escaped first, so that a control character left out leaves no
            // run of spaces behind it.
            let words = TimedTextCue.plainText(XMLEscaping.text(cue.text))
            guard !words.isEmpty else { continue }
            let timing = CueTiming.line(of: cue, fractionSeparator: ".", shortestMilliseconds: 1)
            text += "\n\(timing)\n\(words)\n"
        }
        return text
    }
}

// MARK: - SubRip

/// Writes cues as a SubRip file (.srt), as SubRip's Windows tools write one:
/// each cue as its number, its timing line, `HH:MM:SS,mmm --> HH:MM:SS,mmm`,
/// and its text on one line, the cues apart by a blank line, and every line
/// ended by CR LF. SubRip has no standard escapes, but the few strings that
/// players and readers take for structure or styling are written as
/// character references (`cueText(_:)`), which the readers decode.
enum SubRipWriter {
    /// The text of a SubRip file of `cues`, in their order: "" for none.
    ///
    /// A cue's text is written on one line (`cueText(_:)`). A cue left with
    /// no text is passed over, and the numbers, from 1, count only the cues
    /// written. A cue that would end before it begins is written ending
    /// where it begins.
    static func text(of cues: [TimedTextCue]) -> String {
        var blocks: [String] = []
        for cue in cues {
            let words = cueText(cue.text)
            guard !words.isEmpty else { continue }
            let timing = CueTiming.line(of: cue, fractionSeparator: ",", shortestMilliseconds: 0)
            blocks.append("\(blocks.count + 1)\r\n\(timing)\r\n\(words)\r\n")
        }
        return blocks.joined(separator: "\r\n")
    }

    /// `raw` as the one line of a SubRip cue's text: each run of white space
    /// one space (`TimedTextCue.plainText`), a control character no player
    /// shows left out (a NUL would make a reader take the file for UTF-16),
    /// and what a reader or player would take for something else written as
    /// a character reference, which TextMouth's reader decodes
    /// (`TimedTextMarkup`), so the cue reads back as the words it holds:
    /// - the `>` of a "-->", which would begin a timing line and lose the
    ///   cue, as `&gt;`;
    /// - a `<` with a `>` after it, which would be taken for a tag (`<i>`),
    ///   as `&lt;`;
    /// - the `{` of a `{\`, which would be taken for an override (`{\an8}`),
    ///   as `&#123;`;
    /// - an `&` that begins what a reader would decode (`&amp;`, `&#65;`),
    ///   as `&amp;`, so the words are not changed by being read.
    /// Any other character is written as it is.
    static func cueText(_ raw: String) -> String {
        // White space controls (a form feed) stay, for the spacing to turn
        // into one space; every other control goes.
        let shown = String(String.UnicodeScalarView(raw.unicodeScalars.filter {
            $0.properties.generalCategory != .control || $0.properties.isWhitespace
        }))
        let scalars = Array(TimedTextCue.plainText(shown).unicodeScalars)
        // Where the last ">" lies: a "<" after it opens no tag.
        let lastGreaterThan = scalars.lastIndex(of: ">")
        var written = String.UnicodeScalarView()
        for (index, scalar) in scalars.enumerated() {
            let replacement: String?
            switch scalar {
            case ">":
                // The ">" ending a "-->".
                replacement = index >= 2 && scalars[index - 1] == "-" && scalars[index - 2] == "-" ? "&gt;" : nil
            case "<":
                replacement = lastGreaterThan.map { index < $0 } == true ? "&lt;" : nil
            case "{":
                replacement = index + 1 < scalars.count && scalars[index + 1] == "\\" ? "&#123;" : nil
            case "&":
                replacement = beginsReference(scalars[(index + 1)...]) ? "&amp;" : nil
            default:
                replacement = nil
            }
            if let replacement {
                written.append(contentsOf: replacement.unicodeScalars)
            } else {
                written.append(scalar)
            }
        }
        return String(written)
    }

    /// The names a reader decodes between an "&" and a ";"
    /// (`TimedTextMarkup`), with the ";".
    private static let decodedNames = ["amp;", "lt;", "gt;", "quot;", "apos;", "nbsp;", "lrm;", "rlm;"]

    /// Whether `rest`, the scalars after an "&", begin what a reader decodes
    /// as a character reference: one of the names it knows, or a "#", which
    /// begins a numeric one. Any "#" counts, whether or not the reference is
    /// whole, since a reference written needlessly changes no word.
    private static func beginsReference(_ rest: ArraySlice<Unicode.Scalar>) -> Bool {
        if rest.first == "#" { return true }
        // Compared scalar by scalar, as the reader compares bytes: a
        // combining mark after the ";" must not hide the name, as it would
        // in Swift's characters.
        return decodedNames.contains { rest.starts(with: $0.unicodeScalars) }
    }
}

// MARK: - Timing Lines

/// The timing line both writers give a cue, in the form each format names.
private enum CueTiming {
    /// The timing line of `cue`: when it begins and when it ends, as
    /// `timestamp(_:fractionSeparator:)` writes them, with " --> " between,
    /// as in "00:00:01.500 --> 00:00:02.940". A time before 0 is written as
    /// 0, and the end at least `shortestMilliseconds` after the beginning.
    static func line(of cue: TimedTextCue, fractionSeparator: String, shortestMilliseconds: Int) -> String {
        let start = max(0, cue.startMilliseconds)
        let end = max(cue.endMilliseconds, start.clampedPlus(shortestMilliseconds))
        let from = timestamp(start, fractionSeparator: fractionSeparator)
        let to = timestamp(end, fractionSeparator: fractionSeparator)
        return "\(from) --> \(to)"
    }

    /// `milliseconds`, not below 0, as a cue file writes a time: hours in two
    /// digits or more ("100" from the hundredth hour), minutes and seconds in
    /// two, apart by colons, then `fractionSeparator` and the milliseconds in
    /// three, as in "01:02:03.004".
    static func timestamp(_ milliseconds: Int, fractionSeparator: String) -> String {
        let hours = padded(milliseconds / 3_600_000, toDigits: 2)
        let minutes = padded(milliseconds / 60_000 % 60, toDigits: 2)
        let seconds = padded(milliseconds / 1_000 % 60, toDigits: 2)
        let thousandths = padded(milliseconds % 1_000, toDigits: 3)
        return "\(hours):\(minutes):\(seconds)\(fractionSeparator)\(thousandths)"
    }

    /// `number`, not below 0, in `count` digits or more: zeros before it
    /// when it has fewer.
    private static func padded(_ number: Int, toDigits count: Int) -> String {
        let digits = String(number)
        return String(repeating: "0", count: max(0, count - digits.count)) + digits
    }
}

// MARK: - A Transcript on the Book's Timeline

extension Transcript {
    /// The transcript as cues timed from the start of the book's audio
    /// (FMT23), as Export writes it as captions: each file's sentences, the
    /// files in the order the book plays them, moved along by how long the
    /// files before it play (`TranscriptFile.durationMilliseconds`), so a
    /// book of one file keeps that file's times. Each cue is its sentence's
    /// text and times alone: no voice, since a sentence already names its
    /// speaker ("Ana: …"), and no words.
    ///
    /// The cues are in the order they begin, as a WebVTT file lists them;
    /// cues that begin together keep the transcript's order. The two orders
    /// differ only where a file's sentences begin after its recorded length,
    /// as those of a transcript from outside may, by a few seconds
    /// (`TimedTextLimits.pastTheEndMarginMilliseconds`). A time too large
    /// for an `Int`, which only a damaged transcript.json could make, stays
    /// at the largest one rather than trapping.
    var bookTimelineCues: [TimedTextCue] {
        var cues: [TimedTextCue] = []
        // Where the file being read begins on the book's timeline.
        var fileStart = 0
        for file in files {
            for sentence in file.sentences {
                cues.append(TimedTextCue(
                    startMilliseconds: sentence.startMilliseconds.clampedPlus(fileStart),
                    endMilliseconds: sentence.endMilliseconds.clampedPlus(fileStart),
                    text: sentence.text
                ))
            }
            fileStart = fileStart.clampedPlus(file.durationMilliseconds)
        }
        // Sorted by start, then by place, so cues beginning together keep
        // their order whatever the sort does with equal elements.
        return cues.enumerated()
            .sortedStably { ($0.element.startMilliseconds, $0.offset) < ($1.element.startMilliseconds, $1.offset) }
            .map(\.element)
    }

    /// The transcript `bytes` hold, read from a book's transcript.json for
    /// Export to write as captions (FMT23): decoded as `TranscriptStore`
    /// decodes it, and used only when it passes validation
    /// (`validationFailure()`), as the store uses only one that does.
    /// - Throws: `TranscriptExportError.unusable` for bytes that hold no
    ///   transcript, or one that fails validation.
    static func exportable(from bytes: Data) throws -> Transcript {
        guard let transcript = try? TranscriptStore.decoded(bytes), transcript.validationFailure() == nil else {
            throw TranscriptExportError.unusable
        }
        return transcript
    }
}

// MARK: - Why a Transcript Is Not Exported

/// Why Export could not write a book's transcript as captions (FMT23), in
/// words the export's summary names with the file, the same on screen, in
/// VoiceOver, and in braille. A reason never quotes the transcript, which is
/// the book's text.
enum TranscriptExportError: LocalizedError, Equatable {
    /// The book's transcript.json holds no transcript TextMouth can read, or
    /// one that fails validation, as a write cut short on another Mac or a
    /// hand edit can leave it.
    case unusable

    var errorDescription: String? {
        switch self {
        case .unusable:
            return "The book's transcript couldn't be read, so it wasn't exported."
        }
    }
}
