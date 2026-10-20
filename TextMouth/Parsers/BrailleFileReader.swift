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

/// A braille file's pages, before their layout is read (FMT20), in the
/// compact form the analyzer works on.
///
/// A book is far larger as one `String` for each row and an array for each
/// page than as the file it came from, and TextMouth reads it in its own
/// process, so the pages are kept as three flat arrays: every cell of the
/// file as one byte in `cells`, where each row ends in `rowEnds`, and where
/// each page ends in `pageEnds`. A file's limits (`maxPages`, `maxRows`, and
/// the size the offsets can count) keep every offset in an `Int32`.
struct BrailleFilePages: Equatable, Sendable {
    var kind: BrailleFileKind
    /// A PEF's dc:title, dc:creator, and dc:language; nil for BRF and
    /// BRL, and for a PEF that names none.
    var title: String? = nil
    var author: String? = nil
    var language: String? = nil

    /// Every cell of the file, a byte each, page after page and row after
    /// row: the cell's dots (dot 1 is 1, dot 8 is 128), so the byte is the
    /// Unicode braille pattern less U+2800 and 0 is the blank cell. Blank
    /// cells are kept, trailing ones too.
    private(set) var cells: [UInt8] = []
    /// Where each row ends in `cells` (exclusive); a row starts where the
    /// row before it ended, the first at 0.
    private(set) var rowEnds: [Int32] = []
    /// For each page, the number of rows in the pages up to and including
    /// it: the page's rows are those from the previous entry (0 for the
    /// first) up to this one.
    private(set) var pageEnds: [Int32] = []

    /// The most pages a braille file may have: a 64 MB book of real
    /// braille has about 65,000.
    static let maxPages = 100_000
    /// The most rows a braille file may have: a 64 MB book of real braille
    /// has about 1,700,000.
    static let maxRows = 4_000_000
    /// The most cells a file may hold, which its offsets can count.
    static let maxCells = Int(Int32.max)

    /// An empty set of pages of `kind`.
    init(kind: BrailleFileKind) { self.kind = kind }

    /// The pages made of `pages`, each a list of rows of Unicode braille
    /// patterns (a scalar that is no pattern, which a reader never gives,
    /// is kept as the cell of all eight dots). For tests and for a caller
    /// that has its pages as text; no limit is applied.
    init(kind: BrailleFileKind, pages: [[String]]) {
        self.kind = kind
        for page in pages {
            for row in page {
                for scalar in row.unicodeScalars { append(cell: Self.dots(of: scalar)) }
                rowEnds.append(Int32(clamping: cells.count))
            }
            pageEnds.append(Int32(clamping: rowEnds.count))
        }
    }

    // MARK: Reading the pages

    /// The number of pages.
    var pageCount: Int { pageEnds.count }
    /// The number of rows in all the pages.
    var rowCount: Int { rowEnds.count }

    /// The indexes of the rows of page `page` (empty for an index past the
    /// last page).
    func rows(ofPage page: Int) -> Range<Int> {
        guard pageEnds.indices.contains(page) else { return 0..<0 }
        let start = page == 0 ? 0 : Int(pageEnds[page - 1])
        return start..<Int(pageEnds[page])
    }

    /// The offsets in `cells` of row `row`, trailing blank cells included
    /// (empty for an index past the last row).
    func cellRange(ofRow row: Int) -> Range<Int> {
        guard rowEnds.indices.contains(row) else { return 0..<0 }
        let start = row == 0 ? 0 : Int(rowEnds[row - 1])
        return start..<Int(rowEnds[row])
    }

    /// Each page's rows as text, Unicode braille patterns with the blank
    /// cells and trailing ones as the file wrote them. For tests: it is a
    /// full copy of the book, so no reader of a book uses it.
    var pages: [[String]] {
        (0..<pageCount).map { page in
            rows(ofPage: page).map { row in Self.string(of: cells[cellRange(ofRow: row)]) }
        }
    }

    /// The Unicode braille pattern text of `cells`, which are cell bytes.
    /// Written straight into the string's own storage, three bytes of UTF-8
    /// to a cell (U+2800 to U+28FF), so a book's text takes no more room
    /// than the string itself.
    static func string<Cells: Collection>(of cells: Cells) -> String where Cells.Element == UInt8 {
        String(unsafeUninitializedCapacity: cells.count * 3) { buffer in
            var length = 0
            for cell in cells {
                buffer[length] = 0xE2
                buffer[length + 1] = 0xA0 | (cell >> 6)
                buffer[length + 2] = 0x80 | (cell & 0x3F)
                length += 3
            }
            return length
        }
    }

    /// The cell byte of `scalar`: its dots, or all eight for a character
    /// that is not a braille pattern.
    private static func dots(of scalar: Unicode.Scalar) -> UInt8 {
        BrailleCells.isPattern(scalar) ? UInt8(truncatingIfNeeded: scalar.value) : 0xFF
    }

    // MARK: Building the pages

    /// Makes room for the most `cells`, `rows`, and `pages` a file can
    /// hold, so that building the pages never copies an array to grow it.
    /// Room that is not used is never touched, so it is not memory in use.
    mutating func reserveCapacity(cells cellCount: Int, rows rowCount: Int, pages pageCount: Int) {
        cells.reserveCapacity(cellCount)
        rowEnds.reserveCapacity(min(rowCount, Self.maxRows))
        pageEnds.reserveCapacity(min(pageCount, Self.maxPages))
    }

    /// Adds a cell, given by its dots, to the row being read.
    mutating func append(cell: UInt8) { cells.append(cell) }

    /// Ends the row being read.
    /// - Throws: `BrailleFileError.tooManyRows` for a row past `maxRows`.
    mutating func endRow() throws(BrailleFileError) {
        guard rowEnds.count < Self.maxRows else { throw .tooManyRows }
        rowEnds.append(Int32(clamping: cells.count))
    }

    /// Ends the page being read, which holds the rows ended since the last.
    /// - Throws: `BrailleFileError.tooManyPages` for a page past `maxPages`.
    mutating func endPage() throws(BrailleFileError) {
        guard pageEnds.count < Self.maxPages else { throw .tooManyPages }
        pageEnds.append(Int32(clamping: rowEnds.count))
    }

    /// Cuts all the rows into pages of `rowsPerPage` rows, the last page
    /// shorter, for a file that marks no page of its own; no row, no page.
    /// - Throws: `BrailleFileError.tooManyPages` for more than `maxPages`.
    mutating func repage(every rowsPerPage: Int) throws(BrailleFileError) {
        let count = rowCount
        guard rowsPerPage > 0, (count + rowsPerPage - 1) / rowsPerPage <= Self.maxPages else {
            throw .tooManyPages
        }
        pageEnds = stride(from: rowsPerPage, to: count, by: rowsPerPage).map { Int32($0) }
        if count > 0 { pageEnds.append(Int32(count)) }
    }
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
        /// A character that cannot be told apart on the screen or by ear:
        /// white space (Zs, Zl, Zp, such as U+00A0), a format character (Cf,
        /// such as U+200B or U+FEFF), or a combining mark (Mn, Mc, Me).
        /// Named by its code, as a control character is.
        case unseenCharacter(UInt32)
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
    /// A file of more than `BrailleFilePages.maxPages` pages, which no
    /// book could have.
    case tooManyPages
    /// A file of more than `BrailleFilePages.maxRows` rows of braille.
    case tooManyRows

    var errorDescription: String? {
        switch self {
        case let .notBrailleASCII(found, line):
            return "Line \(line) holds \(Self.words(for: found)), which is not braille ASCII."
        case .damagedPEF:
            return "This file could not be read as a PEF braille file. It may be damaged, or another kind of file."
        case .eightDotBraille:
            return "This file is eight-dot braille, which TextMouth does not read."
        case .tooManyPages:
            return "This file has more than 100,000 braille pages, the most TextMouth reads."
        case .tooManyRows:
            return "This file has more than 4,000,000 lines of braille, the most TextMouth reads."
        }
    }

    /// How the sentence names what was found, made in this one place.
    private static func words(for found: Found) -> String {
        switch found {
        case let .character(character): return "“\(character)”"
        case let .controlCharacter(code): return "the control character \(hex("U+", code, minimumDigits: 4))"
        case let .unseenCharacter(code): return "the character \(hex("U+", code, minimumDigits: 4))"
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

/// Reads BRF, BRL, and PEF braille files into pages of rows of braille
/// cells, and nothing more: no layout is interpreted here (FMT20). The
/// layout, the headings and paragraphs and page numbers, is read from the
/// pages by another type.
enum BrailleFileReader {
    /// The lines on a page of a BRF file that has no form feeds.
    static let linesPerUnmarkedPage = 25
    /// How much of a PEF file `pefMetadata(of:)` reads: its head comes first.
    static let metadataByteCount = 65_536
    /// The bytes of a UTF-8 byte order mark (U+FEFF).
    private static let utf8ByteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

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

    /// Refuses `data` when it is more than the offsets of the pages can count.
    private static func requireOffsetsFit(_ data: Data) throws {
        guard data.count <= BrailleFilePages.maxCells else {
            throw DocumentTooLargeError(limit: Int64(BrailleFilePages.maxCells))
        }
    }

    // MARK: BRF and BRL

    /// The pages of a BRF or BRL file's `data`. A `.pef` kind is read as a
    /// PEF, so a caller cannot misuse this function into a trap.
    /// - Throws: `BrailleFileError.notBrailleASCII` for the first byte that
    ///   is not braille ASCII, `.tooManyPages` and `.tooManyRows` for a file
    ///   past those limits, and `DocumentTooLargeError` for data too large
    ///   for the pages' offsets.
    static func pages(fromASCII data: Data, kind: BrailleFileKind) throws -> BrailleFilePages {
        guard kind != .pef else { return try pages(fromPEF: data) }
        try requireOffsetsFit(data)

        var scanner = ASCIIScanner(kind: kind)
        // The bytes are scanned where they are, with no copy of them.
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var bytes = raw.bindMemory(to: UInt8.self)
            // A UTF-8 byte order mark at the very start is dropped, as
            // TextMouth's text decoder drops it; it is no braille either.
            if bytes.starts(with: utf8ByteOrderMark) { bytes = UnsafeBufferPointer(rebasing: bytes[utf8ByteOrderMark.count...]) }
            // A final Ctrl-Z is an old DOS end-of-file mark, not braille.
            if bytes.last == 0x1A { bytes = UnsafeBufferPointer(rebasing: bytes.dropLast()) }

            // A cell is a byte at most, a row ends at a line end, a page at a
            // form feed: counting them gives the room the pages can need.
            let lineEnds = bytes.lazy.filter { $0 == 0x0A || $0 == 0x0D }.count
            let formFeeds = kind == .brf ? bytes.lazy.filter { $0 == 0x0C }.count : 0
            scanner.reserveCapacity(cells: bytes.count, rows: lineEnds + 1, pages: formFeeds + 1)

            var index = 0
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                try scanner.take(byte, following: bytes, at: index)
                // A CR LF is one line end: the LF after a CR is not another.
                if byte == 0x0D, index < bytes.count, bytes[index] == 0x0A { index += 1 }
            }
        }
        return try scanner.finish()
    }

    /// Collects the rows of a BRF or BRL file byte by byte, in pages cut
    /// at its form feeds, into the compact pages.
    private struct ASCIIScanner {
        let kind: BrailleFileKind
        /// The pages being built.
        private var pages: BrailleFilePages
        /// Whether a form feed ended a page anywhere in the file.
        private var sawFormFeed = false
        /// Whether the line being read has any byte.
        private var lineStarted = false
        /// The line the next byte falls on: lines are counted from 1 by
        /// line ends, and a form feed does not start one.
        private var lineNumber = 1

        init(kind: BrailleFileKind) {
            self.kind = kind
            self.pages = BrailleFilePages(kind: kind)
        }

        /// Makes room in the pages for the most a file can need.
        mutating func reserveCapacity(cells: Int, rows: Int, pages count: Int) {
            pages.reserveCapacity(cells: cells, rows: rows, pages: count)
        }

        /// Whether a form feed ends a page: in a BRF; a BRL has no pages.
        private var formFeedsEndPages: Bool { kind == .brf }

        /// Take `byte`, which the caller read at `index - 1` of `bytes`.
        /// - Throws: `BrailleFileError.notBrailleASCII` for a byte that is
        ///   no braille ASCII, a tab, or a line or page end, and the limits'
        ///   refusals.
        mutating func take(_ byte: UInt8, following bytes: UnsafeBufferPointer<UInt8>, at index: Int) throws {
            switch byte {
            case 0x0A, 0x0D:
                try endLine()
            case 0x0C:
                // BRL has no pages: its form feeds are not even characters.
                if formFeedsEndPages { try endPage() }
            case 0x09:
                // A tab is one blank cell.
                pages.append(cell: 0)
                lineStarted = true
            default:
                guard let cell = BrailleCells.cell(forASCII: byte) else {
                    throw BrailleFileError.notBrailleASCII(
                        Self.found(at: index - 1, in: bytes), line: lineNumber)
                }
                pages.append(cell: UInt8(truncatingIfNeeded: cell.value))
                lineStarted = true
            }
        }

        /// End the line being read as a row, empty or not.
        private mutating func endLine() throws {
            try pages.endRow()
            lineStarted = false
            lineNumber += 1
        }

        /// End the page: the line a form feed interrupts ends there too.
        private mutating func endPage() throws {
            if lineStarted {
                try pages.endRow()
                lineStarted = false
            }
            try pages.endPage()
            sawFormFeed = true
        }

        /// The pages of the whole file, once all its bytes are taken. Text
        /// after the last line end is a line only if it is not empty, and
        /// a form feed at the very end adds no empty page after it.
        mutating func finish() throws -> BrailleFilePages {
            if lineStarted { try pages.endRow() }
            // The rows since the last form feed make a last page, if any.
            let rowsOnLastPage = pages.rowCount - (pages.pageEnds.last.map(Int.init) ?? 0)
            if rowsOnLastPage > 0 { try pages.endPage() }
            if pages.rowCount == 0 || (kind == .brf && !sawFormFeed) {
                // Nothing but form feeds: no page, and the caller refuses it.
                // Or no form feed at all: pages of a fixed number of lines.
                try pages.repage(every: BrailleFileReader.linesPerUnmarkedPage)
            }
            return pages
        }

        /// What the file holds at `start`, the first byte that is no braille
        /// ASCII: the UTF-8 character that begins there, named as itself
        /// or, for a control, white space, format, or combining character,
        /// by its code; or, when the bytes begin no valid character, the byte.
        private static func found(at start: Int, in bytes: UnsafeBufferPointer<UInt8>) -> BrailleFileError.Found {
            // The length a UTF-8 character has, from its first byte.
            let length: Int
            switch bytes[start] {
            case 0x00...0x7F: length = 1
            case 0xC2...0xDF: length = 2
            case 0xE0...0xEF: length = 3
            case 0xF0...0xF4: length = 4
            default: length = 0
            }
            // Decoded by the UTF-8 codec itself, since `String(bytes:encoding:)`
            // drops a byte order mark, which would leave nothing to name.
            var iterator = bytes[start..<min(start + length, bytes.count)].makeIterator()
            var decoder = UTF8()
            guard length > 0, start + length <= bytes.count,
                  case let .scalarValue(scalar) = decoder.decode(&iterator),
                  // The character must use all the bytes its first byte promised.
                  case .emptyInput = decoder.decode(&iterator) else {
                return .byte(bytes[start])
            }
            switch scalar.properties.generalCategory {
            case .control:
                return .controlCharacter(scalar.value)
            case .spaceSeparator, .lineSeparator, .paragraphSeparator, .format,
                 .nonspacingMark, .spacingMark, .enclosingMark:
                // These show as nothing, or join the character before them
                // in quotes, so a listener could not tell what was found.
                return .unseenCharacter(scalar.value)
            default:
                return .character(Character(scalar))
            }
        }
    }

    // MARK: PEF

    /// The pages and metadata of a PEF file's `data`.
    /// - Throws: `BrailleFileError.damagedPEF`, `.eightDotBraille`,
    ///   `.tooManyPages` or `.tooManyRows`, and `DocumentTooLargeError` for
    ///   data too large for the pages' offsets.
    static func pages(fromPEF data: Data) throws -> BrailleFilePages {
        try requireOffsetsFit(data)
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
        var result = collector.pages
        result.title = collector.title
        result.author = collector.author
        result.language = collector.language
        return result
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
/// reads it (FMT20), straight into the compact pages, and aborts the parse
/// at the first refusal.
private final class PEFCollector: NSObject, XMLParserDelegate {
    /// Whether to abort at the end of the head, when only the metadata is wanted.
    private let stopsAfterHead: Bool
    /// The pages read so far (their kind is PEF; the metadata is kept apart).
    private(set) var pages = BrailleFilePages(kind: .pef)
    private(set) var title: String?
    private(set) var author: String?
    private(set) var language: String?
    /// Why the parse was aborted, when the collector did it.
    private(set) var refusal: BrailleFileError?

    /// The open elements, as local names for PEF elements and as
    /// "{namespace}name" for every other, innermost last.
    private var path: [String] = []
    /// Whether a page is open.
    private var inPage = false
    /// Whether a row is open.
    private var inRow = false
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
            inPage = true
        } else if isPEF && elementName == "row" {
            // A row belongs to a page.
            guard inPage else { return refuse(.damagedPEF, parser) }
            inRow = true
        } else if namespaceURI == BrailleFileReader.dublinCoreNamespace, path == ["pef", "head", "meta"],
                  ["title", "creator", "language"].contains(elementName) {
            metadataText = ""
        }
        path.append(entry(elementName, namespaceURI))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if metadataText != nil { metadataText?.append(string) }
        guard inRow else { return }
        for scalar in string.unicodeScalars {
            if Self.rowWhitespace.contains(scalar) { continue }
            if BrailleCells.usesEightDots(scalar) { return refuse(.eightDotBraille, parser) }
            // Only the six-dot patterns remain a braille row may hold.
            guard BrailleCells.isPattern(scalar) else { return refuse(.damagedPEF, parser) }
            pages.append(cell: UInt8(truncatingIfNeeded: scalar.value))
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let isPEF = namespaceURI == BrailleFileReader.pefNamespace
        if isPEF && elementName == "row", inRow {
            inRow = false
            do { try pages.endRow() } catch { refuse(error, parser) }
        } else if isPEF && elementName == "page", inPage {
            inPage = false
            do { try pages.endPage() } catch { refuse(error, parser) }
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
