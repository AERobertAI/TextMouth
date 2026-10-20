import Foundation

// MARK: - Results

/// The kinds of braille file TextMouth reads (FMT20).
enum BrailleFileKind: Equatable, Sendable {
    /// Braille ASCII in finished pages.
    case brf
    /// Braille ASCII, unformatted.
    case brl
    /// Portable Embosser Format: XML of Unicode braille rows.
    case pef
}

/// A braille file's pages, before their layout is read (FMT20).
struct BrailleFilePages: Equatable, Sendable {
    var kind: BrailleFileKind
    /// Each page's rows, top to bottom; a row is its cells as the file
    /// wrote them, blank cells (U+2800) included, trailing ones too.
    var pages: [[String]]
    /// A PEF's dc:title, dc:creator, and dc:language; nil for BRF and
    /// BRL, and for a PEF that names none.
    var title: String? = nil
    var author: String? = nil
    var language: String? = nil
}

// MARK: - Refusals

/// Why a braille file is refused (FMT20). Each sentence is read to the
/// listener after the import's own ("Could not import “book.brf”. Reading
/// its text failed: "), so none names the file.
enum BrailleFileError: LocalizedError, Equatable {
    /// What a BRF or BRL file held where braille ASCII belongs.
    enum Found: Equatable {
        /// A printable character, such as é.
        case character(Character)
        /// A control character (Unicode category Cc), by its code.
        case controlCharacter(UInt32)
        /// A byte that begins no valid UTF-8 character.
        case byte(UInt8)
    }

    /// A BRF or BRL file holds something that is not braille ASCII, first
    /// on `line`, counted from 1.
    case notBrailleASCII(Found, line: Int)
    /// A PEF file that is not well-formed XML, not a PEF document, or
    /// holds a row that is not braille.
    case damagedPEF
    /// A PEF file whose rows use dots 7 and 8.
    case eightDotBraille

    var errorDescription: String? {
        switch self {
        case let .notBrailleASCII(found, line):
            return "Line \(line) holds \(Self.words(for: found)), which is not braille ASCII."
        case .damagedPEF:
            return "This file could not be read as a PEF braille file. It may be damaged, or another kind of file."
        case .eightDotBraille:
            return "This file is eight-dot braille, which TextMouth does not read."
        }
    }

    /// How the sentence names what was found, made in this one place.
    private static func words(for found: Found) -> String {
        switch found {
        case let .character(character): return "“\(character)”"
        case let .controlCharacter(code): return "the control character \(hex("U+", code, minimumDigits: 4))"
        case let .byte(byte): return "the byte \(hex("0x", UInt32(byte), minimumDigits: 2))"
        }
    }

    /// `value` in uppercase hexadecimal after `prefix`, padded with zeros
    /// to at least `minimumDigits` digits.
    private static func hex(_ prefix: String, _ value: UInt32, minimumDigits: Int) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return prefix + String(repeating: "0", count: max(0, minimumDigits - digits.count)) + digits
    }
}

// MARK: - The Reader

/// Reads BRF, BRL, and PEF braille files into pages of rows of Unicode
/// braille, and nothing more: no layout is interpreted here (FMT20). The
/// layout, the headings and paragraphs and page numbers, is read from the
/// pages by another type.
enum BrailleFileReader {
    /// The lines on a page of a BRF file that has no form feeds.
    static let linesPerUnmarkedPage = 25
    /// How much of a PEF file `pefMetadata(of:)` reads: its head comes first.
    static let metadataByteCount = 65_536

    /// The pages of the braille file at `url`, read as `kind`.
    /// - Throws: `FileImportError.noTextToRead` for an empty file,
    ///   `DocumentTooLargeError` for one past the limit, a
    ///   `BrailleFileError` for one that is not braille, and the file
    ///   system's error for one that cannot be read.
    static func read(_ url: URL, as kind: BrailleFileKind) throws -> BrailleFilePages {
        let data = try DocumentByteLimit.contents(of: url)
        switch kind {
        case .brf, .brl: return try pages(fromASCII: data, kind: kind)
        case .pef: return try pages(fromPEF: data)
        }
    }

    // MARK: BRF and BRL

    /// The pages of a BRF or BRL file's `data`. A `.pef` kind is read as a
    /// PEF, so a caller cannot misuse this function into a trap.
    /// - Throws: `BrailleFileError.notBrailleASCII` for the first byte that
    ///   is not braille ASCII.
    static func pages(fromASCII data: Data, kind: BrailleFileKind) throws -> BrailleFilePages {
        guard kind != .pef else { return try pages(fromPEF: data) }

        // A final Ctrl-Z is an old DOS end-of-file mark, not braille.
        var bytes = Array(data)
        if bytes.last == 0x1A { bytes.removeLast() }

        var scanner = ASCIIScanner(formFeedsEndPages: kind == .brf)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            try scanner.take(byte, following: bytes, at: index)
            // A CR LF is one line end: the LF after a CR is not another.
            if byte == 0x0D, index < bytes.count, bytes[index] == 0x0A { index += 1 }
        }

        let pages: [[String]]
        let allPages = scanner.finish()
        let rows = allPages.flatMap { $0 }
        if rows.isEmpty {
            // Nothing but form feeds: no page, and the caller refuses it.
            pages = []
        } else if kind == .brl {
            pages = [rows]
        } else if !scanner.sawFormFeed {
            // No form feed at all: pages of a fixed number of lines.
            pages = stride(from: 0, to: rows.count, by: linesPerUnmarkedPage).map {
                Array(rows[$0..<min($0 + linesPerUnmarkedPage, rows.count)])
            }
        } else {
            pages = allPages
        }
        return BrailleFilePages(kind: kind, pages: pages)
    }

    /// Collects the rows of a BRF or BRL file byte by byte, in pages cut
    /// at its form feeds.
    private struct ASCIIScanner {
        /// Whether a form feed ends a page (BRF) or is ignored (BRL).
        let formFeedsEndPages: Bool
        /// The pages ended so far, and the rows of the page being read.
        private var finished: [[String]] = []
        /// Whether a form feed ended a page anywhere in the file.
        private(set) var sawFormFeed = false
        private var page: [String] = []
        /// The cells of the line being read, and whether it has any byte.
        private var line = String.UnicodeScalarView()
        private var lineStarted = false
        /// The line the next byte falls on: lines are counted from 1 by
        /// line ends, and a form feed does not start one.
        private var lineNumber = 1

        init(formFeedsEndPages: Bool) { self.formFeedsEndPages = formFeedsEndPages }

        /// Take `byte`, which the caller read at `index - 1` of `bytes`.
        /// - Throws: `BrailleFileError.notBrailleASCII` for a byte that is
        ///   no braille ASCII, a tab, or a line or page end.
        mutating func take(_ byte: UInt8, following bytes: [UInt8], at index: Int) throws {
            switch byte {
            case 0x0A, 0x0D:
                endLine()
            case 0x0C:
                // BRL has no pages: its form feeds are not even characters.
                if formFeedsEndPages { endPage() }
            case 0x09:
                // A tab is one blank cell.
                line.append(BrailleCells.blank)
                lineStarted = true
            default:
                guard let cell = BrailleCells.cell(forASCII: byte) else {
                    throw BrailleFileError.notBrailleASCII(
                        Self.found(at: index - 1, in: bytes), line: lineNumber)
                }
                line.append(cell)
                lineStarted = true
            }
        }

        /// End the line being read as a row, empty or not.
        private mutating func endLine() {
            page.append(String(line))
            line = String.UnicodeScalarView()
            lineStarted = false
            lineNumber += 1
        }

        /// End the page: the line a form feed interrupts ends there too.
        private mutating func endPage() {
            if lineStarted {
                page.append(String(line))
                line = String.UnicodeScalarView()
                lineStarted = false
            }
            finished.append(page)
            page = []
            sawFormFeed = true
        }

        /// The pages of the whole file, once all its bytes are taken. Text
        /// after the last line end is a line only if it is not empty, and
        /// a form feed at the very end adds no empty page after it.
        mutating func finish() -> [[String]] {
            if lineStarted { page.append(String(line)) }
            return page.isEmpty ? finished : finished + [page]
        }

        /// What the file holds at `start`, the first byte that is no braille
        /// ASCII: the UTF-8 character that begins there, named as itself
        /// or, for a control character, by its code; or, when the bytes
        /// begin no valid character, the byte.
        private static func found(at start: Int, in bytes: [UInt8]) -> BrailleFileError.Found {
            // The length a UTF-8 character has, from its first byte.
            let length: Int
            switch bytes[start] {
            case 0x00...0x7F: length = 1
            case 0xC2...0xDF: length = 2
            case 0xE0...0xEF: length = 3
            case 0xF0...0xF4: length = 4
            default: length = 0
            }
            guard length > 0, start + length <= bytes.count,
                  let text = String(bytes: bytes[start..<start + length], encoding: .utf8),
                  text.unicodeScalars.count == 1,
                  let scalar = text.unicodeScalars.first else {
                return .byte(bytes[start])
            }
            if scalar.properties.generalCategory == .control { return .controlCharacter(scalar.value) }
            return .character(Character(scalar))
        }
    }

    // MARK: PEF

    /// The pages and metadata of a PEF file's `data`.
    /// - Throws: `BrailleFileError.damagedPEF` or `.eightDotBraille`.
    static func pages(fromPEF data: Data) throws -> BrailleFilePages {
        let collector = PEFCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.shouldProcessNamespaces = true
        // Never fetch an external entity a file names.
        parser.shouldResolveExternalEntities = false
        let parsed = parser.parse()
        // A refusal the collector made is the reason the parse stopped.
        if let refusal = collector.refusal { throw refusal }
        guard parsed else { throw BrailleFileError.damagedPEF }
        return BrailleFilePages(kind: .pef, pages: collector.pages,
                                title: collector.title, author: collector.author,
                                language: collector.language)
    }

    /// The title, author, and language the PEF file at `url` names, read
    /// from its first 65,536 bytes only, for the import's title and author.
    /// It never throws: a file that cannot be read gives three nils.
    static func pefMetadata(of url: URL) -> (title: String?, author: String?, language: String?) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, nil, nil) }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: metadataByteCount), !prefix.isEmpty else {
            return (nil, nil, nil)
        }
        let collector = PEFCollector(stopsAfterHead: true)
        let parser = XMLParser(data: prefix)
        parser.delegate = collector
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        // The parse ends in an error, either the abort at the end of the
        // head or the cut that ends the prefix: once the head is read, the
        // error is moot.
        _ = parser.parse()
        return (collector.title, collector.author, collector.language)
    }

    /// The namespace of PEF 2008-1 elements.
    fileprivate static let pefNamespace = "http://www.daisy.org/ns/2008/pef"
    /// The namespace of the Dublin Core elements in a PEF's head.
    fileprivate static let dublinCoreNamespace = "http://purl.org/dc/elements/1.1/"
}

// MARK: - Collecting a PEF

/// Collects a PEF document's metadata, pages, and rows as an `XMLParser`
/// reads it (FMT20), and aborts the parse at the first refusal.
private final class PEFCollector: NSObject, XMLParserDelegate {
    /// Whether to abort at the end of the head, when only the metadata is wanted.
    private let stopsAfterHead: Bool
    private(set) var pages: [[String]] = []
    private(set) var title: String?
    private(set) var author: String?
    private(set) var language: String?
    /// Why the parse was aborted, when the collector did it.
    private(set) var refusal: BrailleFileError?

    /// The open elements, as local names for PEF elements and as
    /// "{namespace}name" for every other, innermost last.
    private var path: [String] = []
    /// The rows of the page being read, nil outside a page.
    private var pageRows: [String]?
    /// The cells of the row being read, nil outside a row.
    private var rowCells: String.UnicodeScalarView?
    /// The text of the Dublin Core element being read, nil outside one.
    private var metadataText: String?

    /// The white space a row ignores: a PEF's rows are indented and wrapped.
    private static let rowWhitespace: Set<Unicode.Scalar> = [" ", "\t", "\r", "\n"]

    init(stopsAfterHead: Bool = false) { self.stopsAfterHead = stopsAfterHead }

    /// Record `error` as the refusal and stop the parse.
    private func refuse(_ error: BrailleFileError, _ parser: XMLParser) {
        // The first refusal is the reason; later ones are its echoes.
        if refusal == nil { refusal = error }
        parser.abortParsing()
    }

    /// The path entry of an element.
    private func entry(_ name: String, _ namespace: String?) -> String {
        namespace == BrailleFileReader.pefNamespace ? name : "{\(namespace ?? "")}\(name)"
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        // The root element must be a PEF.
        if path.isEmpty && entry(elementName, namespaceURI) != "pef" {
            return refuse(.damagedPEF, parser)
        }
        let isPEF = namespaceURI == BrailleFileReader.pefNamespace
        if isPEF && elementName == "page" {
            pageRows = []
        } else if isPEF && elementName == "row" {
            // A row belongs to a page.
            guard pageRows != nil else { return refuse(.damagedPEF, parser) }
            rowCells = String.UnicodeScalarView()
        } else if namespaceURI == BrailleFileReader.dublinCoreNamespace, path == ["pef", "head", "meta"],
                  ["title", "creator", "language"].contains(elementName) {
            metadataText = ""
        }
        path.append(entry(elementName, namespaceURI))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if metadataText != nil { metadataText?.append(string) }
        guard rowCells != nil else { return }
        for scalar in string.unicodeScalars {
            if Self.rowWhitespace.contains(scalar) { continue }
            if BrailleCells.usesEightDots(scalar) { return refuse(.eightDotBraille, parser) }
            // Only the six-dot patterns remain a braille row may hold.
            guard BrailleCells.isPattern(scalar) else { return refuse(.damagedPEF, parser) }
            rowCells?.append(scalar)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let isPEF = namespaceURI == BrailleFileReader.pefNamespace
        if isPEF && elementName == "row", let cells = rowCells {
            pageRows?.append(String(cells))
            rowCells = nil
        } else if isPEF && elementName == "page", let rows = pageRows {
            pages.append(rows)
            pageRows = nil
        } else if let text = metadataText, namespaceURI == BrailleFileReader.dublinCoreNamespace {
            // Only the first of each is kept, and only if it says something.
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            metadataText = nil
            if !trimmed.isEmpty {
                switch elementName {
                case "title": title = title ?? trimmed
                case "creator": author = author ?? trimmed
                case "language": language = language ?? trimmed
                default: break
                }
            }
        }
        if !path.isEmpty { path.removeLast() }
        if stopsAfterHead && isPEF && elementName == "head" { parser.abortParsing() }
    }
}
