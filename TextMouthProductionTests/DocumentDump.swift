import Foundation
@testable import TextMouth

/// The facts a person would check about an imported document, in a form that
/// is written to a small text file (a golden) and compared with the dump of
/// the same document later.
///
/// `TextPipelineGoldenTests` pins 64-bit digests of what a book reads as, and
/// a digest says only "something changed". A golden says what: the title, the
/// author, how many chapters, words, and characters, the headings with their
/// levels, a checksum of the reading text, its first and last 300 characters,
/// and, for a book with audio, its tracks. A change to a parser, the text
/// pipeline, or heading detection that alters what the user hears for a book
/// then names the difference in words (`differences(golden:actual:)`).
///
/// The golden format is line oriented, LF, UTF-8, with a final newline:
///
///     # TextMouth document golden, format 2
///     file: alice.epub
///     format: epub
///     title: Alice's Adventures in Wonderland
///     ...
///     heading: 1 | Down the Rabbit-Hole
///     page: 12 | 3:1540 | The Queen turned crimson
///     track: Chapter 1 | audio/ch1.mp3 | 0.00-61.50
///
/// Every value is on one line: backslash, newline, carriage return, and tab
/// are written as `\\`, `\n`, `\r`, and `\t`. Heading character offsets are
/// not recorded: the text checksum covers the text and where everything lies.
/// Page offsets are recorded (chapter, then UTF-16 offset, with the words the
/// page opens with), because pages add no text for the checksum to cover
/// (PG01). The page lines are what this format added to the first.
struct DocumentDump: Equatable {

    // MARK: - Parts

    /// One heading as a reader meets it: its level (1 to 6) and its text.
    struct HeadingLine: Equatable {
        var level: Int
        var text: String
    }

    /// One page of the book (PG01): its label, where it begins (chapter and
    /// UTF-16 offset into that chapter's reading text), and the words it
    /// opens with, so a moved page is named by what is there now.
    struct PageLine: Equatable {
        var label: String
        var chapterIndex: Int
        var characterOffset: Int
        var opening: String
    }

    /// One stretch of one audio file, with the title of the section that
    /// plays it. A section of several clips is several tracks.
    struct Track: Equatable {
        var title: String
        var file: String
        var start: Double
        var end: Double
    }

    // MARK: - Fields

    /// The first line of every golden; changes only when the format does.
    static let header = "# TextMouth document golden, format 2"

    /// How many characters (Unicode scalars) each sample holds.
    static let sampleLength = 300

    /// How many characters (Unicode scalars) of the reading text a page's
    /// line shows from the page's offset.
    static let openingLength = 24

    var fileName: String
    var format: String
    var title: String
    var author: String
    var chapterCount: Int
    var wordCount: Int
    /// The length of the reading text in UTF-16 units.
    var textLength: Int
    /// `TextPipelineFixtures.digest` of the reading text: the chapters'
    /// `text` joined with "\n".
    var textChecksum: String
    /// The first `sampleLength` characters of the reading text, unescaped.
    var firstSample: String
    /// The last `sampleLength` characters of the reading text, unescaped.
    var lastSample: String
    /// What the import could not read, in the report's words; nil when it
    /// read everything.
    var reportMessage: String?
    var headings: [HeadingLine]
    /// The audio length in seconds, nil for a book with no audio.
    var audioDuration: Double?
    var tracks: [Track]
    /// The book's pages in book order (PG01); empty for a book without them.
    var pages: [PageLine]
    /// "major.minor" of the macOS that made the dump; recorded for PDFs only,
    /// whose text PDFKit and Vision produce and change with macOS.
    var macOSVersion: String?

    // MARK: - Making a Dump

    /// Memberwise, so tests can build a dump without importing anything.
    init(
        fileName: String, format: String, title: String, author: String,
        chapterCount: Int, wordCount: Int, textLength: Int, textChecksum: String,
        firstSample: String, lastSample: String, reportMessage: String? = nil,
        headings: [HeadingLine] = [], audioDuration: Double? = nil, tracks: [Track] = [],
        macOSVersion: String? = nil, pages: [PageLine] = []
    ) {
        self.fileName = fileName
        self.format = format
        self.title = title
        self.author = author
        self.chapterCount = chapterCount
        self.wordCount = wordCount
        self.textLength = textLength
        self.textChecksum = textChecksum
        self.firstSample = firstSample
        self.lastSample = lastSample
        self.reportMessage = reportMessage
        self.headings = headings
        self.audioDuration = audioDuration
        self.tracks = tracks
        self.macOSVersion = macOSVersion
        self.pages = pages
    }

    /// The dump of an imported book, as a reader would open it.
    /// - Parameters:
    ///   - fileName: the document's file name in TestData.
    ///   - book: the imported book (title, author, format).
    ///   - opened: the book loaded by `BookContentAnalysisService.load`.
    ///   - report: the import's report of what the source could not supply.
    ///   - macOSVersion: recorded in the dump when given (PDFs).
    init(fileName: String, book: Book, opened: BookContentAnalysisService.Result, report: ExtractionReport, macOSVersion: String? = nil) {
        let chapters = opened.content.chapters
        // The reading text is the chapters' text joined by one newline.
        let text = chapters.map(\.text).joined(separator: "\n")
        let scalars = text.unicodeScalars
        let segments = opened.audioSegments ?? []
        self.init(
            fileName: fileName,
            format: book.format.rawValue,
            title: book.title,
            author: book.author,
            chapterCount: chapters.count,
            wordCount: opened.index.totalWordCount,
            textLength: text.utf16.count,
            textChecksum: TextPipelineFixtures.digest(text),
            firstSample: String(String.UnicodeScalarView(scalars.prefix(Self.sampleLength))),
            lastSample: String(String.UnicodeScalarView(scalars.suffix(Self.sampleLength))),
            reportMessage: report.isComplete ? nil : report.message,
            headings: chapters.flatMap(\.headings).map { HeadingLine(level: $0.level, text: $0.text) },
            audioDuration: opened.index.totalAudioDuration,
            tracks: segments.flatMap { segment in
                segment.clips.map { Track(title: segment.title, file: $0.file, start: $0.startTime, end: $0.endTime) }
            },
            macOSVersion: macOSVersion,
            pages: opened.content.pages.breaks.map { page in
                PageLine(
                    label: page.label, chapterIndex: page.chapterIndex, characterOffset: page.characterOffset,
                    opening: Self.opening(of: page, in: chapters)
                )
            }
        )
    }

    /// The first `openingLength` Unicode scalars of the chapter's reading text
    /// from the page's offset (found through UTF-16, which clamps it); empty
    /// when the page names a chapter the book does not have.
    private static func opening(of page: PageBreak, in chapters: [Chapter]) -> String {
        guard chapters.indices.contains(page.chapterIndex) else { return "" }
        let text = chapters[page.chapterIndex].text
        let start = text.index(atUTF16Offset: page.characterOffset)
        return String(String.UnicodeScalarView(text.unicodeScalars[start...].prefix(openingLength)))
    }

    /// "major.minor" of the macOS this process runs on.
    static var currentMacOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)"
    }

    // MARK: - Rendering

    /// `value` on one line: backslash, newline, carriage return, and tab
    /// become `\\`, `\n`, `\r`, and `\t`.
    static func escaped(_ value: String) -> String {
        var result = ""
        for character in value.unicodeScalars {
            switch character {
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default: result.unicodeScalars.append(character)
            }
        }
        return result
    }

    /// A number of seconds as the golden writes it: two decimals.
    private static func seconds(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    /// One `key: value` line; an empty value leaves no trailing space.
    private static func line(_ key: String, _ value: String) -> String {
        value.isEmpty ? "\(key):" : "\(key): \(value)"
    }

    /// The golden format: the header, `key: value` lines in a fixed order,
    /// then the headings, the pages, and the tracks.
    func rendered() -> String {
        var lines = [Self.header]
        lines.append(Self.line("file", Self.escaped(fileName)))
        if let macOSVersion { lines.append(Self.line("macOS", macOSVersion)) }
        lines.append(Self.line("format", Self.escaped(format)))
        lines.append(Self.line("title", Self.escaped(title)))
        lines.append(Self.line("author", Self.escaped(author)))
        lines.append(Self.line("chapters", String(chapterCount)))
        lines.append(Self.line("words", String(wordCount)))
        lines.append(Self.line("text length", String(textLength)))
        lines.append(Self.line("text checksum", textChecksum))
        if let reportMessage { lines.append(Self.line("report", Self.escaped(reportMessage))) }
        if let audioDuration { lines.append(Self.line("audio duration", Self.seconds(audioDuration))) }
        lines.append(Self.line("first \(Self.sampleLength)", Self.escaped(firstSample)))
        lines.append(Self.line("last \(Self.sampleLength)", Self.escaped(lastSample)))
        for heading in headings {
            lines.append(Self.line("heading", "\(heading.level) | \(Self.escaped(heading.text))"))
        }
        for page in pages {
            lines.append(Self.line(
                "page", "\(Self.escaped(page.label)) | \(page.chapterIndex):\(page.characterOffset) | \(Self.escaped(page.opening))"
            ))
        }
        for track in tracks {
            lines.append(Self.line(
                "track", "\(Self.escaped(track.title)) | \(Self.escaped(track.file)) | \(Self.seconds(track.start))-\(Self.seconds(track.end))"
            ))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Reading a Golden

    /// A golden's lines, split into the scalar `key: value` pairs in file
    /// order, the repeated `heading` values, the repeated `page` values, and
    /// the repeated `track` values.
    private struct Parsed {
        var header: String?
        var scalars: [(key: String, value: String)] = []
        var headings: [String] = []
        var pages: [String] = []
        var tracks: [String] = []

        func value(of key: String) -> String? {
            scalars.first { $0.key == key }?.value
        }
    }

    /// Splits `text` (a golden or a rendered dump) into its parts. Lines
    /// with no colon and blank lines are ignored; the first line starting
    /// with `#` is the header.
    private static func parse(_ text: String) -> Parsed {
        var parsed = Parsed()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            if line.hasPrefix("#") {
                if parsed.header == nil { parsed.header = line }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon])
            // The value follows ": "; an empty value is written as "key:".
            var value = String(line[line.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() }
            switch key {
            case "heading": parsed.headings.append(value)
            case "page": parsed.pages.append(value)
            case "track": parsed.tracks.append(value)
            default: parsed.scalars.append((key, value))
            }
        }
        return parsed
    }

    /// The value of `key` in a golden, or nil when it has no such line.
    static func value(of key: String, inGolden golden: String) -> String? {
        parse(golden).value(of: key)
    }

    /// The macOS major version a golden was recorded on, or nil when it
    /// records none (every golden but a PDF's).
    static func macOSMajorVersion(inGolden golden: String) -> Int? {
        guard let version = value(of: "macOS", inGolden: golden) else { return nil }
        return Int(version.split(separator: ".").first ?? "")
    }

    // MARK: - Differences

    /// The keys whose values are counts, so a difference says how many more
    /// or fewer.
    private static let countKeys: Set<String> = ["chapters", "words", "text length"]

    /// The scalar keys in the order `rendered()` writes them.
    private static let scalarKeyOrder = [
        "file", "macOS", "format", "title", "author", "chapters", "words", "text length", "text checksum",
        "report", "audio duration", "first \(sampleLength)", "last \(sampleLength)",
    ]

    /// How many differences of a list (headings, tracks) are named before
    /// the rest are only counted.
    static let listDifferenceLimit = 10

    /// Every way `actual` differs from `golden`, one sentence each, in an
    /// order a reader can follow: the scalar lines by key, then the headings,
    /// the pages, and the tracks. Lines are compared by key, not by position, so a
    /// line that appears or disappears does not shift the rest. Empty when
    /// the two say the same.
    static func differences(golden: String, actual: String) -> [String] {
        let old = parse(golden)
        let new = parse(actual)
        var result: [String] = []

        // A golden written by another format cannot be compared line by line.
        if old.header != new.header {
            result.append("golden header is \(quoted(old.header ?? "missing")), now \(quoted(new.header ?? "missing"))")
        }

        // The keys in the order the format writes them, then any other key
        // (from a golden of a later format) in the order it appears.
        let present = old.scalars.map(\.key) + new.scalars.map(\.key)
        var keys = scalarKeyOrder.filter(present.contains)
        for key in present where !keys.contains(key) { keys.append(key) }
        for key in keys {
            if let sentence = scalarDifference(key: key, golden: old.value(of: key), actual: new.value(of: key)) {
                result.append(sentence)
            }
        }

        result += listDifferences(noun: "heading", golden: old.headings, actual: new.headings)
        result += listDifferences(noun: "page", golden: old.pages, actual: new.pages)
        result += listDifferences(noun: "track", golden: old.tracks, actual: new.tracks)
        return result
    }

    /// `text` in straight double quotes.
    private static func quoted(_ text: String) -> String { "\"\(text)\"" }

    /// The sentence for one scalar key whose value differs, nil when it does
    /// not. A count says how many more or fewer.
    private static func scalarDifference(key: String, golden: String?, actual: String?) -> String? {
        switch (golden, actual) {
        case (nil, nil):
            return nil
        case (nil, let now?):
            return "\(key): golden has none, now \(quoted(now))"
        case (let old?, nil):
            return "\(key): golden is \(quoted(old)), now there is none"
        case (let old?, let now?):
            guard old != now else { return nil }
            if countKeys.contains(key), let oldCount = Int(old), let newCount = Int(now) {
                let change = newCount > oldCount ? "\(newCount - oldCount) more" : "\(oldCount - newCount) fewer"
                return "\(key): golden \(old), now \(now) (\(change))"
            }
            return "\(key): golden is \(quoted(old)), now \(quoted(now))"
        }
    }

    /// The sentences for a repeated line (`heading`, `page`, or `track`): how many
    /// the golden and the actual have, then each position that differs,
    /// at most `listDifferenceLimit`, then how many more there are.
    private static func listDifferences(noun: String, golden: [String], actual: [String]) -> [String] {
        var result: [String] = []
        if golden.count != actual.count {
            result.append("\(noun)s: golden has \(golden.count), now \(actual.count)")
        }
        var sentences: [String] = []
        for position in 0..<max(golden.count, actual.count) {
            let old = position < golden.count ? golden[position] : nil
            let now = position < actual.count ? actual[position] : nil
            switch (old, now) {
            case (let old?, let now?) where old != now:
                sentences.append("\(noun) \(position + 1): golden \(quoted(old)), now \(quoted(now))")
            case (let old?, nil):
                sentences.append("\(noun) \(position + 1) only in golden: \(quoted(old))")
            case (nil, let now?):
                sentences.append("\(noun) \(position + 1) only now: \(quoted(now))")
            default:
                break
            }
        }
        result += sentences.prefix(listDifferenceLimit)
        if sentences.count > listDifferenceLimit {
            result.append("and \(sentences.count - listDifferenceLimit) more \(noun) differences")
        }
        return result
    }
}
