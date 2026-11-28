import Foundation

// MARK: - Timestamps (FMT23)

/// The timestamps of WebVTT and SubRip cues (FMT23): `[H:]M:S` and a
/// fraction of a second, as both formats write them and as the tools that
/// make them bend them. The two readers share this one grammar, so a time
/// reads alike in either format.
///
/// - Two or three fields separated by colons, every one of ASCII digits
///   alone: no sign, no space.
/// - With three, the hours (1 to 3 digits, any value) and the minutes (1 or
///   2 digits, 0 to 59). With two, the minutes alone (1 to 4 digits, any
///   value, since some tools write "75:00.000").
/// - Last, the seconds (1 or 2 digits, 0 to 59), then optionally a "." or a
///   "," and a fraction of one or more digits, whose first three count as
///   thousandths: "5" is 500 milliseconds, "05" is 50, "005" and "0059"
///   are 5. Without a fraction the time is a whole second.
///
/// Anything else (an empty field, a fourth field, a letter, 60 seconds) is
/// no timestamp. The bounded digit counts keep every time under 1,000
/// hours, far from overflow.
enum TimedTextTimestamp {
    /// The milliseconds `text` names, or nil when it is not a timestamp.
    static func milliseconds(_ text: Substring) -> Int? {
        milliseconds(utf8: text.utf8)
    }

    /// The milliseconds the UTF-8 bytes `bytes` name, or nil when they are
    /// not a timestamp: `milliseconds(_:)` for the readers, which hold a
    /// file's lines as bytes.
    static func milliseconds(utf8 bytes: some Collection<UInt8>) -> Int? {
        // At most four pieces are made, however many colons the text holds:
        // a fourth refuses it anyway.
        let fields = bytes.split(separator: TimedTextMarkup.Byte.colon, maxSplits: 3, omittingEmptySubsequences: false)
        guard (2...3).contains(fields.count), let secondsField = fields.last,
              let seconds = secondsAndMilliseconds(of: secondsField) else { return nil }
        let hours: Int
        let minutes: Int
        if fields.count == 3 {
            guard let readHours = number(fields[0], digitCounts: 1...3),
                  let readMinutes = number(fields[1], digitCounts: 1...2), readMinutes < 60 else { return nil }
            (hours, minutes) = (readHours, readMinutes)
        } else {
            guard let readMinutes = number(fields[0], digitCounts: 1...4) else { return nil }
            (hours, minutes) = (0, readMinutes)
        }
        return ((hours * 60 + minutes) * 60 + seconds.whole) * 1_000 + seconds.milliseconds
    }

    /// The last field of a timestamp, `S`, `S.f`, or `S,f`, read as whole
    /// seconds and the thousandths of its fraction; nil when it does not
    /// read.
    private static func secondsAndMilliseconds(
        of field: some Collection<UInt8>
    ) -> (whole: Int, milliseconds: Int)? {
        let secondsDigits = field.prefix(while: TimedTextMarkup.Byte.isDigit)
        guard let whole = number(secondsDigits, digitCounts: 1...2), whole < 60 else { return nil }
        let rest = field[secondsDigits.endIndex...]
        guard let separator = rest.first else { return (whole, 0) }
        let fraction = rest.dropFirst()
        guard separator == TimedTextMarkup.Byte.period || separator == TimedTextMarkup.Byte.comma,
              !fraction.isEmpty, fraction.allSatisfy(TimedTextMarkup.Byte.isDigit) else { return nil }
        // The first three digits are tenths, hundredths, and thousandths;
        // any after them are finer than a transcript's times, and are dropped.
        let milliseconds = zip([100, 10, 1], fraction).reduce(0) { sum, pair in
            sum + pair.0 * Int(pair.1 - TimedTextMarkup.Byte.zero)
        }
        return (whole, milliseconds)
    }

    /// The value of `digits` when they are ASCII digits alone, as many as
    /// `digitCounts` allows; nil otherwise, an empty field included.
    private static func number(_ digits: some Collection<UInt8>, digitCounts: ClosedRange<Int>) -> Int? {
        guard digitCounts.contains(digits.count), digits.allSatisfy(TimedTextMarkup.Byte.isDigit) else { return nil }
        return digits.reduce(0) { $0 * 10 + Int($1 - TimedTextMarkup.Byte.zero) }
    }
}

// MARK: - What the Readers Share

/// What the WebVTT and SubRip readers share (FMT23): a file's lines, its
/// timing lines, and the markup and character references of a cue's text.
///
/// A file is read as UTF-8 bytes. Every character the formats give a
/// meaning ("-->", "<", "&", the digits of a time) is ASCII, and an ASCII
/// byte of UTF-8 is never part of another character, so the readers find
/// them without decoding the text around them. That keeps a combining mark
/// after a ">" from hiding the tag's end, as it would in Swift's
/// characters, where the two are one.
///
/// Every step is bounded by the text it reads: no character is examined more
/// than a few times, however the file is made, so a hostile file costs no
/// more than a long one.
enum TimedTextMarkup {
    /// One line of a file, as UTF-8 bytes, without its line feed.
    typealias Line = ArraySlice<UInt8>

    /// The ASCII characters the readers look for, as UTF-8 bytes.
    enum Byte {
        static let tab = UInt8(ascii: "\t")
        static let lineFeed = UInt8(ascii: "\n")
        static let space = UInt8(ascii: " ")
        static let numberSign = UInt8(ascii: "#")
        static let hyphen = UInt8(ascii: "-")
        static let ampersand = UInt8(ascii: "&")
        static let comma = UInt8(ascii: ",")
        static let period = UInt8(ascii: ".")
        static let zero = UInt8(ascii: "0")
        static let nine = UInt8(ascii: "9")
        static let colon = UInt8(ascii: ":")
        static let semicolon = UInt8(ascii: ";")
        static let lessThan = UInt8(ascii: "<")
        static let greaterThan = UInt8(ascii: ">")
        static let backslash = UInt8(ascii: "\\")
        static let lowercaseV = UInt8(ascii: "v")
        static let lowercaseX = UInt8(ascii: "x")
        static let uppercaseX = UInt8(ascii: "X")
        static let leftBrace = UInt8(ascii: "{")
        static let rightBrace = UInt8(ascii: "}")

        /// Whether `byte` is a space or a tab: the white space of a line
        /// that both formats allow around their parts.
        static func isSpaceOrTab(_ byte: UInt8) -> Bool {
            byte == space || byte == tab
        }

        /// Whether `byte` is an ASCII digit, "0" through "9".
        static func isDigit(_ byte: UInt8) -> Bool {
            (zero...nine).contains(byte)
        }
    }

    // MARK: Lines

    /// The lines of a file: its text as UTF-8 bytes, held once, and where
    /// each line begins, four bytes to a line.
    ///
    /// An array of one `ArraySlice` per line would take 32 bytes for each
    /// line, so a 20 MB file of nothing but line feeds (20 million empty
    /// lines) would take some 640 MB; this takes 80 MB, and a line is made
    /// only when the reader asks for it. It splits the text exactly as
    /// `split(separator: lineFeed, omittingEmptySubsequences: false)` does:
    /// a text holding n line feeds has n + 1 lines, the first and last
    /// possibly empty.
    struct Lines: RandomAccessCollection {
        /// The whole text, as UTF-8 bytes.
        private let bytes: [UInt8]
        /// Where each line begins in `bytes`: the first at 0, each other
        /// just after a line feed.
        private let starts: [UInt32]

        /// The lines of `bytes`; nil when they number more than a
        /// four-byte offset reaches (4 GB), far beyond a file TextMouth reads.
        init?(bytes: [UInt8]) {
            guard bytes.count < Int(UInt32.max) else { return nil }
            var starts: [UInt32] = [0]
            for (offset, byte) in bytes.enumerated() where byte == Byte.lineFeed {
                starts.append(UInt32(offset + 1))
            }
            self.bytes = bytes
            self.starts = starts
        }

        var startIndex: Int { 0 }
        var endIndex: Int { starts.count }

        /// The line at `index`, without its line feed.
        subscript(index: Int) -> Line {
            let start = Int(starts[index])
            // A line ends just before the next one begins, less the line
            // feed between them; the last ends with the text.
            let end = index + 1 < starts.count ? Int(starts[index + 1]) - 1 : bytes.count
            return bytes[start..<end]
        }
    }

    /// The lines of the timed-text file whose bytes are `data`, a file of
    /// `format`. The bytes are read by `TextFileDecoder` as a new text file
    /// is: leading byte-order marks dropped, UTF-8 and UTF-16 recognized, a
    /// legacy encoding guessed, Windows-1252 otherwise, and every line
    /// ending a line feed, at which the text is split.
    /// - Throws: `TimedTextError.notTimedText(format)` when the bytes cannot
    ///   be read as text: a UTF-16 or UTF-32 byte-order mark before bytes
    ///   that are not in its encoding.
    static func lines(of data: Data, format: TimedTextFormat) throws -> Lines {
        let decoded: DecodedText
        do {
            decoded = try TextFileDecoder.decode(
                data, fileName: "transcript.\(format.fileExtension)", format: .txt, policy: .guess
            )
        } catch {
            // The decoder throws only TextEncodingError, whose reason names
            // the file; a timed-text reader throws its own kind alone.
            throw TimedTextError.notTimedText(format)
        }
        guard let lines = Lines(bytes: Array(decoded.text.utf8)) else {
            throw TimedTextError.notTimedText(format)
        }
        return lines
    }

    /// Whether `line` is blank: empty, or nothing but spaces and tabs.
    static func isBlank(_ line: Line) -> Bool {
        line.allSatisfy(Byte.isSpaceOrTab)
    }

    /// `text` without the spaces and tabs at either end.
    static func trimmingSpacesAndTabs(_ text: Line) -> Line {
        let leading = text.drop(while: Byte.isSpaceOrTab)
        guard let last = leading.lastIndex(where: { !Byte.isSpaceOrTab($0) }) else {
            return leading[leading.endIndex...]
        }
        return leading[...last]
    }

    // MARK: Timing Lines

    /// The arrow between a cue's start and end.
    private static let arrow = Array("-->".utf8)

    /// The two times of a timing line, each as `TimedTextTimestamp` reads
    /// it: nil for a time that does not read.
    struct Timing {
        /// When the cue begins, in milliseconds.
        var start: Int?
        /// When the cue ends, in milliseconds.
        var end: Int?

        /// Whether both times read.
        var reads: Bool { start != nil && end != nil }
    }

    /// Whether `line` holds "-->", which makes it a timing line, readable or
    /// not.
    static func holdsArrow(_ line: Line) -> Bool {
        arrowStart(in: line) != nil
    }

    /// Where the first "-->" of `line` begins, or nil when it holds none.
    private static func arrowStart(in line: Line) -> Int? {
        var index = line.startIndex
        while let hyphen = line[index...].firstIndex(of: Byte.hyphen) {
            if line[hyphen...].starts(with: arrow) { return hyphen }
            index = hyphen + 1
        }
        return nil
    }

    /// The times of `line`, or nil when it holds no "-->". The start is the
    /// text before the first "-->", without the spaces and tabs around it;
    /// the end is the first run of characters after it that are neither.
    /// Whatever follows the end is ignored: WebVTT's cue settings
    /// (`align:start position:10%`) and SubRip's coordinates (`X1:40`).
    static func timing(of line: Line) -> Timing? {
        guard let arrowStart = arrowStart(in: line) else { return nil }
        let start = trimmingSpacesAndTabs(line[..<arrowStart])
        let end = line[(arrowStart + arrow.count)...]
            .drop(while: Byte.isSpaceOrTab)
            .prefix(while: { !Byte.isSpaceOrTab($0) })
        return Timing(
            start: TimedTextTimestamp.milliseconds(utf8: start),
            end: TimedTextTimestamp.milliseconds(utf8: end)
        )
    }

    // MARK: Cues

    /// The cue that `timingLine` and the lines of text after it make, or nil
    /// when it cannot be used: a time that does not read, an end before its
    /// start, an end past `TimedTextLimits.maximumCueMilliseconds` (exactly
    /// that is allowed), or text that is blank once its markup is gone. A
    /// time may run past a single file's 100 hours
    /// (`Transcript.maximumMilliseconds`): a book's transcript is timed on
    /// the whole book, whose files it is cut into afterwards
    /// (`OutsideTranscript.split(_:across:)`).
    /// `removingOverrides` removes SubRip's `{\...}` overrides as well.
    static func cue(
        timingLine: Line, textLines: some Collection<Line>, removingOverrides: Bool
    ) -> TimedTextCue? {
        // The times come first: a cue they refuse needs no text read.
        guard let timing = timing(of: timingLine),
              let start = timing.start, let end = timing.end,
              start <= end, end <= TimedTextLimits.maximumCueMilliseconds else { return nil }
        let (text, voice, lastVoice, wasCut) = cueText(of: textLines, removingOverrides: removingOverrides)
        guard !text.isEmpty else { return nil }
        return TimedTextCue(
            startMilliseconds: start, endMilliseconds: end, text: text, voice: voice, lastVoice: lastVoice,
            isCutShort: wasCut
        )
    }

    // MARK: Markup

    /// The text, voice, and last voice of a cue whose lines of text are `lines`, joined
    /// by line feeds and read once from start to end.
    ///
    /// - Every tag, from a "<" to the next ">", is removed, and its text
    ///   stays: `<b>`, `<i>`, `<c.x>`, `<lang en>`, a timestamp, a closing
    ///   tag. A "<" with no ">" after it is text.
    /// - A voice tag (`<v Ana>`, `<v.loud Ben>`) names the cue's `voice`, the
    ///   first time one names anybody; after that, one naming another voice
    ///   than the voice named last puts "Ben: " where it stood, after a
    ///   space, so the words before it never run into the name.
    /// - With `removingOverrides`, a SubRip override, `{\` up to the next
    ///   `}` (`{\an8}`), is removed too. A `{\` with no `}` after it is text.
    /// - Character references are decoded once the tags are gone (see
    ///   `appendDecodingReferences(_:to:)`), so `&lt;b&gt;` is the text
    ///   "<b>", never a tag.
    /// - Last, the text is finished with `TimedTextCue.plainText`, and kept to
    ///   `TimedTextLimits.maximumCueCharacters`: `wasCut` says whether it
    ///   was longer.
    private static func cueText(
        of lines: some Collection<Line>, removingOverrides: Bool
    ) -> (text: String, voice: String?, lastVoice: String?, wasCut: Bool) {
        var raw: [UInt8] = []
        for (number, line) in lines.enumerated() {
            if number > 0 { raw.append(Byte.lineFeed) }
            raw.append(contentsOf: line)
        }
        // Where the last ">" and the last "}" lie. A "<" or "{\" after its
        // closer has none, and is text at once: looking for the closer
        // each time would read the rest of the cue once for every such
        // character, which a hostile file could hold by the million.
        let lastTagEnd = raw.lastIndex(of: Byte.greaterThan) ?? -1
        let lastOverrideEnd = removingOverrides ? (raw.lastIndex(of: Byte.rightBrace) ?? -1) : -1
        var text = CueTextBuilder()
        var index = 0
        while index < raw.count {
            let byte = raw[index]
            if byte == Byte.lessThan, index < lastTagEnd,
               let tagEnd = raw[(index + 1)...].firstIndex(of: Byte.greaterThan) {
                text.readTag(raw[(index + 1)..<tagEnd])
                index = tagEnd + 1
            } else if byte == Byte.leftBrace, index + 1 < lastOverrideEnd, raw[index + 1] == Byte.backslash,
                      let overrideEnd = raw[(index + 2)...].firstIndex(of: Byte.rightBrace) {
                // A SubRip override, such as {\an8}, is removed.
                index = overrideEnd + 1
            } else {
                text.append(byte)
                index += 1
            }
        }
        return text.finished()
    }

    /// The annotation of a voice tag, given what lies between the tag's "<"
    /// and ">": what follows the first space or tab after the `v` and its
    /// classes (`<v.loud Ben>` gives "Ben"), empty when nothing does; nil
    /// when the tag is no voice tag, as one whose name is not `v` alone is
    /// not (`<vx>`, `<V Ana>`).
    fileprivate static func voiceAnnotation(ofTag content: ArraySlice<UInt8>) -> ArraySlice<UInt8>? {
        guard content.first == Byte.lowercaseV else { return nil }
        let afterName = content.dropFirst()
        // The name is `v` alone: a space, a tab, a class's ".", or the tag's
        // end comes next.
        if let next = afterName.first, !Byte.isSpaceOrTab(next), next != Byte.period { return nil }
        guard let gap = afterName.firstIndex(where: Byte.isSpaceOrTab) else {
            return afterName[afterName.endIndex...]
        }
        return afterName[(gap + 1)...]
    }

    // MARK: Character References

    /// The named character references a cue's text may hold, without their
    /// "&", and what each stands for: the marks of text direction stand for
    /// nothing, and are removed.
    private static let namedReferences: [(name: [UInt8], value: [UInt8])] = {
        let references: [(name: String, value: String)] = [
            ("amp;", "&"), ("lt;", "<"), ("gt;", ">"), ("quot;", "\""), ("apos;", "'"),
            ("nbsp;", "\u{00A0}"), ("lrm;", ""), ("rlm;", ""),
        ]
        return references.map { (Array($0.name.utf8), Array($0.value.utf8)) }
    }()

    /// The most digits a numeric character reference may hold.
    private static let maximumReferenceDigits = 7

    /// Appends `text` to `output` with its character references decoded:
    /// `&amp;`, `&lt;`, `&gt;`, `&quot;`, `&apos;`, and `&nbsp;` (a no-break
    /// space) become their characters, `&lrm;` and `&rlm;` are removed, and
    /// `&#233;` and `&#x1F600;` (or `&#X1F600;`) become the character they
    /// number, when that is a Unicode scalar other than U+0000, written in at
    /// most seven digits. Any other `&...;`, and an `&` with no `;`, stay as
    /// written. A decoded character is never read again, so `&amp;lt;` is
    /// the text "&lt;".
    fileprivate static func appendDecodingReferences(_ text: ArraySlice<UInt8>, to output: inout [UInt8]) {
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == Byte.ampersand, let reference = reference(after: text[(index + 1)...]) {
                output.append(contentsOf: reference.value)
                index += 1 + reference.length
            } else {
                output.append(text[index])
                index += 1
            }
        }
    }

    /// The character reference whose "&" comes just before `text`: what it
    /// stands for, as UTF-8, and how many bytes of `text` it takes; nil
    /// when `text` begins no reference.
    private static func reference(after text: ArraySlice<UInt8>) -> (value: [UInt8], length: Int)? {
        if let named = namedReferences.first(where: { text.starts(with: $0.name) }) {
            return (named.value, named.name.count)
        }
        guard let numbered = numberedReference(text) else { return nil }
        return (Array(String(numbered.scalar).utf8), numbered.length)
    }

    /// The numeric character reference `text` begins with, without its "&"
    /// ("#233;", "#x1F600;"): the character it numbers, and how many bytes
    /// it takes; nil when it begins none, or numbers no character it may
    /// (see `appendDecodingReferences(_:to:)`).
    private static func numberedReference(_ text: ArraySlice<UInt8>) -> (scalar: Unicode.Scalar, length: Int)? {
        guard text.first == Byte.numberSign else { return nil }
        var index = text.startIndex + 1
        var radix = 10
        if index < text.endIndex, text[index] == Byte.lowercaseX || text[index] == Byte.uppercaseX {
            radix = 16
            index += 1
        }
        let digitsStart = index
        var value = 0
        // At most seven digits are read, which keeps the value below 2^28;
        // an eighth leaves a digit where the ";" must be.
        while index < text.endIndex, index - digitsStart < maximumReferenceDigits,
              let digit = Character(Unicode.Scalar(text[index])).hexDigitValue, digit < radix {
            value = value * radix + digit
            index += 1
        }
        guard index > digitsStart, index < text.endIndex, text[index] == Byte.semicolon,
              value != 0, let scalar = Unicode.Scalar(UInt32(value)) else { return nil }
        return (scalar, index + 1 - text.startIndex)
    }
}

// MARK: - A Cue's Text

/// A cue's text as `TimedTextMarkup.cueText(of:removingOverrides:)` reads
/// its markup: the characters outside the tags, the names that voice tags
/// put in, and the cue's voice.
///
/// Character references are decoded in the runs of text between the names
/// put in, after the tags are gone, and a name is decoded on its own (as
/// the W3C's reader decodes an annotation), so a name is never decoded a
/// second time with the text around it.
private struct CueTextBuilder {
    /// The text since the cue's start or the last name put in, its
    /// character references not decoded yet.
    private var undecoded: [UInt8] = []
    /// The text before `undecoded`, its references decoded and its names
    /// put in.
    private var decoded: [UInt8] = []
    /// The cue's voice: the first name a voice tag gives.
    private var voice: String?
    /// The voice a voice tag named last in the cue.
    private var namedLast: String?

    /// Adds one byte of the cue's text, outside every tag.
    mutating func append(_ byte: UInt8) {
        undecoded.append(byte)
    }

    /// Reads a tag, given what lies between its "<" and ">". A voice tag
    /// naming somebody gives the cue its voice, the first time; after that,
    /// one naming a voice other than the voice named last puts its name in
    /// the text. Every other tag, and a voice tag naming nobody (`<v>`), is
    /// removed without a trace.
    mutating func readTag(_ content: ArraySlice<UInt8>) {
        guard let annotation = TimedTextMarkup.voiceAnnotation(ofTag: content) else { return }
        var annotationBytes: [UInt8] = []
        TimedTextMarkup.appendDecodingReferences(annotation, to: &annotationBytes)
        let name = TimedTextCue.voiceName(String(decoding: annotationBytes, as: UTF8.self))
        guard !name.isEmpty, name != namedLast else { return }
        if voice == nil {
            // The first voice is the cue's own, which a transcript names
            // before the cue's text (`TimedTextDocument.sentences`).
            voice = name
        } else {
            // A space first, which the finishing makes one with any white
            // space beside it, keeps "Hi.<v Ben>Hello" from running the
            // words into the name.
            decodeUndecoded()
            decoded.append(TimedTextMarkup.Byte.space)
            decoded.append(contentsOf: (name + ": ").utf8)
        }
        namedLast = name
    }

    /// The cue's text, finished with `TimedTextCue.plainText` and kept to
    /// `TimedTextLimits.maximumCueCharacters` (`wasCut` says whether it was
    /// longer), its voice, and the voice speaking at its end when that is
    /// another.
    mutating func finished() -> (text: String, voice: String?, lastVoice: String?, wasCut: Bool) {
        decodeUndecoded()
        // The voice speaking last is told apart only when it is not the
        // cue's own (`TimedTextCue.lastVoice`).
        let (text, wasCut) = TimedTextCue.finishedText(
            of: String(decoding: decoded, as: UTF8.self),
            characterLimit: TimedTextLimits.maximumCueCharacters
        )
        return (text, voice, namedLast == voice ? nil : namedLast, wasCut)
    }

    /// Moves the text not yet decoded to the decoded text, its character
    /// references decoded.
    private mutating func decodeUndecoded() {
        TimedTextMarkup.appendDecodingReferences(undecoded[...], to: &decoded)
        undecoded.removeAll(keepingCapacity: true)
    }
}

// MARK: - Finishing a File

/// The cues a reader keeps as it reads a file, and how many it passes over,
/// finished into the file's `TimedTextDocument`.
struct TimedTextCueList {
    /// The format of the file read.
    let format: TimedTextFormat
    /// The most cues the file may hold.
    let maximumCues: Int
    /// The cues kept, in the file's order.
    private var cues: [TimedTextCue] = []
    /// How many cues were passed over as unusable.
    private var skippedCueCount = 0

    /// An empty list for a file of `format` that may hold `maximumCues`.
    init(format: TimedTextFormat, maximumCues: Int) {
        self.format = format
        self.maximumCues = maximumCues
    }

    /// Reads the cue of `timingLine` and the lines of text after it
    /// (`TimedTextMarkup.cue(timingLine:textLines:removingOverrides:)`):
    /// keeps it, or counts it passed over when it cannot be used. SubRip's
    /// overrides are removed from a SubRip file's cues alone.
    /// - Throws: `TimedTextError.tooManyCues` as soon as more than
    ///   `maximumCues` are kept, so a file holding millions is not read to
    ///   its end.
    mutating func read(timingLine: TimedTextMarkup.Line, textLines: some Collection<TimedTextMarkup.Line>) throws {
        guard let cue = TimedTextMarkup.cue(
            timingLine: timingLine, textLines: textLines, removingOverrides: format == .subRip
        ) else {
            skippedCueCount += 1
            return
        }
        cues.append(cue)
        if cues.count > maximumCues {
            throw TimedTextError.tooManyCues(limit: maximumCues)
        }
    }

    /// The file read: its cues sorted by start, those that begin together
    /// in the file's order, and the count of those passed over.
    /// - Throws: `TimedTextError.noCues(format)` when no cue was kept.
    func document() throws -> TimedTextDocument {
        guard !cues.isEmpty else { throw TimedTextError.noCues(format) }
        // Each cue's place in the file settles a tie, which keeps the sort
        // stable whatever the sorting algorithm.
        let sorted = cues.enumerated()
            .sortedStably { ($0.element.startMilliseconds, $0.offset) < ($1.element.startMilliseconds, $1.offset) }
            .map(\.element)
        return TimedTextDocument(format: format, cues: sorted, skippedCueCount: skippedCueCount)
    }
}
