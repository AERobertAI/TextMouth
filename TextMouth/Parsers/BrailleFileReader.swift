import Foundation

// MARK: - Results

/// The kinds of braille file TextMouth reads (FMT20).
enum BrailleFileKind: Equatable, Sendable {
    /// Braille in finished pages, each cell a character of the file's
    /// braille file code (`BrailleFileCode`).
    case brf
    /// Braille, unformatted, each cell a character of the file's braille
    /// file code.
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
    /// The line width a PEF declares in its volume's `cols` attribute, when
    /// that is a whole number from 18 to 80; nil for BRF and BRL, and for a
    /// PEF that declares none or a number outside the range. The analyzer
    /// takes it as the width before it measures any row (FMT20).
    var lineWidth: Int? = nil
    /// Whether the file marks where its pages end (PG12, the review of
    /// October 24): a PEF by its page elements, a BRF by the form feeds
    /// between its braille text. A BRF without one (a form feed only at its
    /// start or end is none) is cut into pages of `BrailleFileReader
    /// .linesPerUnmarkedPage` rows only so that its layout can be read
    /// (`repage(every:)`), and those are no pages an embosser counts unless
    /// braille page numbers mark them (`BrailleBookReader.marksItsPages(_:_:)`).
    /// A BRL marks none.
    var marksItsPages = false

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
        // Pages given one by one are marked, but for a BRL's, which has none.
        marksItsPages = kind != .brl
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
    /// What a BRF or BRL file held where a cell of its braille file code
    /// belongs.
    enum Found: Equatable {
        /// A printable character, such as é.
        case character(Character)
        /// A control character (Unicode category Cc), by its code.
        case controlCharacter(UInt32)
        /// A character that cannot be told apart on the screen or by ear:
        /// white space (Zs, Zl, Zp, such as U+00A0), a format character (Cf,
        /// such as U+200B or U+FEFF), a combining mark (Mn, Mc, Me), or the
        /// blank braille pattern, U+2800. Named by its code, as a control
        /// character is.
        case unseenCharacter(UInt32)
        /// A byte that begins no valid UTF-8 character.
        case byte(UInt8)
    }

    /// A BRF or BRL file read in North American Braille ASCII holds
    /// something that is not braille ASCII, first on `line`, counted from 1.
    case notBrailleASCII(Found, line: Int)
    /// A BRF or BRL file read in any other braille file code holds something
    /// that is no character of that code, first on `line`, counted from 1.
    /// `characters` is what the code's characters are called
    /// (`BrailleFileCode.characterName`), such as "Eurobraille".
    case notInFileCode(Found, line: Int, characters: String)
    /// A BRF or BRL file read in a seven-bit code holds `byte`, above 0x7F
    /// and beginning no UTF-8 character, first on `line`, counted from 1:
    /// the file may be eight-bit computer braille, in a code page TextMouth
    /// cannot read (BRAILLE-CODES-RESEARCH-2026-10-25.md, section 8.5), or a
    /// braille ASCII file with one stray byte, which the line and the byte
    /// let the listener find (the review of October 30, finding 6).
    case eightBitBraille(byte: UInt8, line: Int)
    /// A BRF or BRL file that begins with a UTF-16 byte order mark (FF FE or
    /// FE FF): text in UTF-16, which TextMouth does not read as braille, and
    /// which would otherwise be refused as eight-bit braille.
    case utf16Text
    /// A braille book records a braille file code, by the id given, that
    /// this TextMouth does not know, such as a later TextMouth's: the book is
    /// refused by name, never read as another code, which would give wrong
    /// text with no error (`BrailleFileCode.code(forStored:)`).
    case unknownFileCode(String)
    /// A PEF file that is not well-formed XML, not a PEF document, or
    /// holds a row that is not braille.
    case damagedPEF
    /// A PEF file whose rows use dots 7 and 8, or a BRF or BRL file of
    /// Unicode braille patterns whose cells do.
    case eightDotBraille
    /// A file of more than `BrailleFilePages.maxPages` pages, which no
    /// book could have.
    case tooManyPages
    /// A file of more than `BrailleFilePages.maxRows` rows of braille.
    case tooManyRows
    /// A file of more than `BrailleBookReader.maximumFileBytes` bytes, which
    /// no book could be: a long novel's BRF is 2 to 5 MB (review finding E5).
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case let .notBrailleASCII(found, line):
            return Self.sentence(found, line: line, isNot: BrailleFileCode.northAmerican.characterName)
        case let .notInFileCode(found, line, characters):
            return Self.sentence(found, line: line, isNot: characters)
        case let .eightBitBraille(byte, line):
            return "Line \(line) holds \(Self.words(for: .byte(byte))). "
                + "This file may be eight-bit computer braille, which TextMouth does not read."
        case .utf16Text:
            return "This file is in UTF-16, which TextMouth does not read as braille. Save it in UTF-8 to read it."
        case let .unknownFileCode(id):
            return "TextMouth has no braille file characters named “\(id)”."
        case .damagedPEF:
            return "This file could not be read as a PEF braille file. It may be damaged, or another kind of file."
        case .eightDotBraille:
            return "This file is eight-dot braille, which TextMouth does not read."
        case .tooManyPages:
            return "This file has more than 100,000 braille pages, the most TextMouth reads."
        case .tooManyRows:
            return "This file has more than 4,000,000 lines of braille, the most TextMouth reads."
        case .fileTooLarge:
            return "This braille file holds more than 32 MB, the most TextMouth reads from one braille file."
        }
    }

    /// The sentence that refuses `found`, on `line`, as no character of a
    /// code whose characters are called `characters`: "Line 3 holds “é”,
    /// which is not braille ASCII." Every code's refusal is made here, North
    /// American Braille ASCII's and the others' alike, so the words are
    /// written once.
    private static func sentence(_ found: Found, line: Int, isNot characters: String) -> String {
        "Line \(line) holds \(words(for: found)), which is not \(characters)."
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
///
/// A BRF or BRL file writes each cell as a character of a braille file code
/// (`BrailleFileCode`, braillecodes), and is read in the code given: North
/// American Braille ASCII when none is, as every braille file was read
/// before files had a code. A PEF's rows are Unicode braille patterns,
/// whatever the code.
enum BrailleFileReader {
    /// The lines on a page of a BRF file that has no form feed between its
    /// braille text.
    static let linesPerUnmarkedPage = 25
    /// How much of a PEF file `pefMetadata(of:)` reads: its head comes first.
    static let metadataByteCount = 65_536
    /// How much of a BRF or BRL file `certainCode(ofFileAt:)` reads: the
    /// first character after its blank lines is all it looks at.
    static let detectionByteCount = 65_536
    /// The bytes of a UTF-8 byte order mark (U+FEFF).
    private static let utf8ByteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]
    /// The bytes of a UTF-16 byte order mark, big-endian and little-endian
    /// (a UTF-32 little-endian mark begins with the latter too).
    private static let utf16BigEndianMark: [UInt8] = [0xFE, 0xFF]
    private static let utf16LittleEndianMark: [UInt8] = [0xFF, 0xFE]

    /// The pages of the braille file at `url`, read as `kind`: a BRF or BRL
    /// in the braille file code `code`, North American Braille ASCII when
    /// none is given, and a PEF as its rows of Unicode braille, whatever the
    /// code.
    /// - Throws: `FileImportError.noTextToRead` for an empty file,
    ///   `DocumentTooLargeError` for one past the limit, a
    ///   `BrailleFileError` for one that is not braille in the code, and the
    ///   file system's error for one that cannot be read.
    static func read(_ url: URL, as kind: BrailleFileKind,
                     code: BrailleFileCode = .northAmerican) throws -> BrailleFilePages {
        let data = try DocumentByteLimit.contents(of: url)
        switch kind {
        case .brf, .brl: return try pages(fromText: data, kind: kind, code: code)
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

    /// The pages of a BRF or BRL file's `data` in North American Braille
    /// ASCII, as every braille file was read before files had a code
    /// (`pages(fromText:kind:code:)`).
    static func pages(fromASCII data: Data, kind: BrailleFileKind) throws -> BrailleFilePages {
        try pages(fromText: data, kind: kind, code: .northAmerican)
    }

    /// The pages of a BRF or BRL file's `data`, whose cells are written in
    /// the braille file code `code`. A `.pef` kind is read as a PEF, so a
    /// caller cannot misuse this function into a trap.
    /// - Throws: `BrailleFileError.utf16Text` for a file that begins with a
    ///   UTF-16 byte order mark; then, for the first thing that is neither a
    ///   cell of `code` nor a line end, form feed, or tab:
    ///   `.eightBitBraille`, with the byte and its line, for
    ///   a seven-bit code's byte above 0x7F that begins no UTF-8 character,
    ///   `.eightDotBraille` for a Unicode braille pattern with dot 7 or 8,
    ///   and otherwise `.notBrailleASCII` (North American Braille ASCII) or
    ///   `.notInFileCode` (any other code), which name it and its line;
    ///   `.tooManyPages` and `.tooManyRows` for a file past those limits;
    ///   and `DocumentTooLargeError` for data too large for the pages'
    ///   offsets.
    static func pages(fromText data: Data, kind: BrailleFileKind,
                      code: BrailleFileCode) throws -> BrailleFilePages {
        guard kind != .pef else { return try pages(fromPEF: data) }
        try requireOffsetsFit(data)

        var scanner = TextScanner(kind: kind, code: code)
        // The bytes are scanned where they are, with no copy of them.
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var bytes = raw.bindMemory(to: UInt8.self)
            // A UTF-16 byte order mark, either way round, says the file is
            // UTF-16 text: refused by name, in every code, rather than as
            // eight-bit braille at its first byte.
            if bytes.starts(with: utf16BigEndianMark) || bytes.starts(with: utf16LittleEndianMark) {
                throw BrailleFileError.utf16Text
            }
            // A UTF-8 byte order mark at the very start is dropped, as
            // TextMouth's text decoder drops it; it is no braille either.
            if bytes.starts(with: utf8ByteOrderMark) { bytes = UnsafeBufferPointer(rebasing: bytes[utf8ByteOrderMark.count...]) }
            // A final Ctrl-Z is an old DOS end-of-file mark, not braille.
            if bytes.last == 0x1A { bytes = UnsafeBufferPointer(rebasing: bytes.dropLast()) }

            // A cell takes a byte at least, a row ends at a line end, a page
            // at a form feed: counting them gives the room the pages can need.
            let lineEnds = bytes.lazy.filter { $0 == 0x0A || $0 == 0x0D }.count
            let formFeeds = kind == .brf ? bytes.lazy.filter { $0 == 0x0C }.count : 0
            scanner.reserveCapacity(cells: bytes.count, rows: lineEnds + 1, pages: formFeeds + 1)

            // Each step takes what begins at `index`, a byte or more of it.
            var index = 0
            while index < bytes.count {
                index += try scanner.take(at: index, in: bytes)
            }
        }
        return try scanner.finish()
    }

    /// The dots of the Unicode braille pattern whose UTF-8 begins at `index`
    /// of `bytes`, or nil when the bytes there are no braille pattern.
    ///
    /// U+2800 to U+28FF are the three bytes E2, A0 to A3, and 80 to BF, and a
    /// pattern's dots are its low eight bits: the second byte's low two bits
    /// above the third byte's low six. All three must be inside `bytes`, so
    /// a pattern cut short by the end is none, and nothing past the end is
    /// read.
    private static func patternDots(at index: Int, in bytes: UnsafeBufferPointer<UInt8>) -> UInt8? {
        guard index + 2 < bytes.count, bytes[index] == 0xE2 else { return nil }
        let second = bytes[index + 1], third = bytes[index + 2]
        guard (0xA0...0xA3).contains(second), (0x80...0xBF).contains(third) else { return nil }
        return ((second & 0x03) << 6) | (third & 0x3F)
    }

    /// Collects the rows of a BRF or BRL file, cell by cell in its braille
    /// file code, in pages cut at its form feeds, into the compact pages.
    ///
    /// What is not a cell is read alike in every code: a line end, a form
    /// feed, and a tab. Only what a cell is differs from code to code: a
    /// byte of a seven-bit code is the cell its table gives, and a Unicode
    /// braille pattern is its own dots.
    private struct TextScanner {
        let kind: BrailleFileKind
        /// The code the file's cells are written in, which a refusal names.
        private let code: BrailleFileCode
        /// The code's seven-bit table, kept for the whole file, so that a
        /// cell of a seven-bit code is one lookup for each byte; nil for
        /// Unicode braille patterns.
        private let table: SevenBitBrailleTable?
        /// The pages being built.
        private var pages: BrailleFilePages
        /// Whether braille text, a cell that is not blank, has been read.
        private var sawText = false
        /// Whether a form feed has ended a page since braille text was read.
        private var formFeedFollowsText = false
        /// Whether a form feed stands between braille text, with text before
        /// it and after it: only such a form feed marks a page (the
        /// verification of October 24). One that stands only at the file's
        /// start or end, with nothing but line ends and blank cells before or
        /// after it, marks none, and the file is read as the same file
        /// without form feeds. Counted, the one form feed at the end of a
        /// six-page BANA file made it a single page labelled 6, and left the
        /// numbers of pages 1 to 5 in its text, where they were read aloud.
        private var formFeedBetweenText = false
        /// Whether the line being read has any byte.
        private var lineStarted = false
        /// The line the next byte falls on: lines are counted from 1 by
        /// line ends, and a form feed does not start one.
        private var lineNumber = 1

        /// A scanner for a file of `kind` whose cells are written in `code`.
        init(kind: BrailleFileKind, code: BrailleFileCode) {
            self.kind = kind
            self.code = code
            self.table = code.sevenBitTable
            self.pages = BrailleFilePages(kind: kind)
        }

        /// Makes room in the pages for the most a file can need.
        mutating func reserveCapacity(cells: Int, rows: Int, pages count: Int) {
            pages.reserveCapacity(cells: cells, rows: rows, pages: count)
        }

        /// Whether a form feed ends a page: in a BRF; a BRL has no pages.
        private var formFeedsEndPages: Bool { kind == .brf }

        /// Take what begins at `index` of `bytes`: a line end, a form feed, a
        /// tab, or a cell of the file's code.
        /// - Returns: The number of bytes taken, at least one: two for a CR
        ///   LF, which is one line end, and three for a Unicode braille
        ///   pattern.
        /// - Throws: `cell(at:in:)`'s refusals for anything else, and the
        ///   limits' refusals.
        mutating func take(at index: Int, in bytes: UnsafeBufferPointer<UInt8>) throws -> Int {
            switch bytes[index] {
            case 0x0A:
                try endLine()
                return 1
            case 0x0D:
                try endLine()
                // A CR LF is one line end: the LF after a CR is not another.
                return index + 1 < bytes.count && bytes[index + 1] == 0x0A ? 2 : 1
            case 0x0C:
                // BRL has no pages: its form feeds are not even characters.
                if formFeedsEndPages { try endPage() }
                return 1
            case 0x09:
                // A tab is one blank cell.
                pages.append(cell: 0)
                lineStarted = true
                return 1
            default:
                let (dots, length) = try cell(at: index, in: bytes)
                pages.append(cell: dots)
                lineStarted = true
                // The blank cell, the space, is no text.
                if dots != 0 { noteText() }
                return length
            }
        }

        /// The cell whose character begins at `index` of `bytes`, by its
        /// dots, and the number of bytes the character takes.
        /// - Throws: `BrailleFileError.eightDotBraille` for a Unicode braille
        ///   pattern with dot 7 or 8, and `refusal(at:in:)` for a character
        ///   that is no cell of the code.
        private func cell(at index: Int, in bytes: UnsafeBufferPointer<UInt8>) throws -> (dots: UInt8, length: Int) {
            let byte = bytes[index]
            if let table {
                // A seven-bit code: each byte is the cell its table gives,
                // the code's other written forms (its aliases) included.
                guard let dots = table.dots(forByte: byte) else { throw refusal(at: index, in: bytes) }
                return (dots, 1)
            }
            // Unicode braille patterns: the ASCII space, which some tools
            // write between words, is the blank cell.
            if byte == 0x20 { return (0, 1) }
            guard let dots = BrailleFileReader.patternDots(at: index, in: bytes) else {
                throw refusal(at: index, in: bytes)
            }
            // A pattern past U+283F uses dot 7 or 8.
            guard dots <= 0x3F else { throw BrailleFileError.eightDotBraille }
            return (dots, 3)
        }

        /// The refusal of the character at `index` of `bytes`, which is no
        /// cell of the code, on the line being read, named as
        /// `found(at:in:)` names it.
        private func refusal(at index: Int, in bytes: UnsafeBufferPointer<UInt8>) -> BrailleFileError {
            let found = Self.found(at: index, in: bytes)
            // A byte above 0x7F that begins no UTF-8 character is no text in
            // a seven-bit code: the file may be eight-bit computer braille, in
            // a code page TextMouth cannot read, and the line and the byte say
            // where. Unicode braille patterns are UTF-8, so there the byte is
            // named as any other character is.
            if table != nil, case let .byte(byte) = found {
                return .eightBitBraille(byte: byte, line: lineNumber)
            }
            // North American Braille ASCII keeps its own refusal; any other
            // code's refusal names what that code's characters are called.
            guard code != .northAmerican else { return .notBrailleASCII(found, line: lineNumber) }
            return .notInFileCode(found, line: lineNumber, characters: code.characterName)
        }

        /// Note braille text: a cell that is not blank. A form feed read
        /// since the text before it now stands between two texts.
        private mutating func noteText() {
            if formFeedFollowsText { formFeedBetweenText = true }
            sawText = true
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
            if sawText { formFeedFollowsText = true }
        }

        /// The pages of the whole file, once all its bytes are taken. Text
        /// after the last line end is a line only if it is not empty, and
        /// a form feed at the very end adds no empty page after it.
        mutating func finish() throws -> BrailleFilePages {
            if lineStarted { try pages.endRow() }
            // The rows since the last form feed make a last page, if any.
            let rowsOnLastPage = pages.rowCount - (pages.pageEnds.last.map(Int.init) ?? 0)
            if rowsOnLastPage > 0 { try pages.endPage() }
            if pages.rowCount == 0 || (kind == .brf && !formFeedBetweenText) {
                // Nothing but form feeds: no page, and the caller refuses it.
                // Or no form feed between braille text: pages of a fixed
                // number of lines, as in a file with no form feed at all.
                try pages.repage(every: BrailleFileReader.linesPerUnmarkedPage)
            }
            // Only a BRF's form feeds between its text mark pages; a BRL's
            // end no page.
            pages.marksItsPages = formFeedBetweenText
            return pages
        }

        /// What the file holds at `start`, the first byte that is no cell of
        /// the file's code: the UTF-8 character that begins there, named as
        /// itself or, for a control, white space, format, or combining
        /// character, by its code; or, when the bytes begin no valid
        /// character, the byte.
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
            // The blank braille pattern shows as nothing too, in quotes on the
            // screen and as an empty cell on a braille display, so it is named
            // by its code: a file of Unicode braille patterns read in another
            // code may well begin with one.
            if scalar == BrailleCells.blank {
                return .unseenCharacter(scalar.value)
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

    // MARK: Detection

    /// The braille file code that `prefix`, the first bytes of a BRF or BRL
    /// file, is certainly written in, or nil when nothing in it is certain
    /// (BRAILLE-CODES-RESEARCH-2026-10-25.md, section 8.5).
    ///
    /// Only Unicode braille patterns are ever certain: when the first
    /// character that is not a byte order mark at the very start, a line
    /// end, a form feed, a tab, or a space is a braille pattern, U+2800 to
    /// U+28FF, with all three of its bytes in `prefix` (one cut off at its
    /// end is no pattern). A seven-bit code is never guessed: the codes
    /// write their cells with the same printable characters, so no byte
    /// tells them apart for certain (research section 7.2). An empty prefix,
    /// or a blank one, gives nil.
    static func certainCode(of prefix: Data) -> BrailleFileCode? {
        prefix.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> BrailleFileCode? in
            let bytes = raw.bindMemory(to: UInt8.self)
            var index = bytes.starts(with: utf8ByteOrderMark) ? utf8ByteOrderMark.count : 0
            while index < bytes.count {
                switch bytes[index] {
                case 0x09, 0x0A, 0x0C, 0x0D, 0x20:
                    // A tab, line end, form feed, or space: no character yet.
                    index += 1
                default:
                    // The first character decides.
                    return patternDots(at: index, in: bytes) == nil ? nil : .unicode
                }
            }
            return nil
        }
    }

    /// The braille file code the BRF or BRL file at `url` is certainly
    /// written in (`certainCode(of:)`), from its first `detectionByteCount`
    /// bytes only, or nil. It never throws: a file that cannot be read, or
    /// is empty, gives nil.
    static func certainCode(ofFileAt url: URL) -> BrailleFileCode? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: detectionByteCount) else { return nil }
        return certainCode(of: prefix)
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
        // Every page of a PEF is a page element of its own.
        result.marksItsPages = true
        result.title = collector.title
        result.author = collector.author
        result.language = collector.language
        result.lineWidth = collector.lineWidth
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
    /// The first valid `cols` of a volume (see `BrailleFilePages.lineWidth`).
    private(set) var lineWidth: Int?
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

    /// The width a `cols` attribute declares: a whole number written in digits
    /// only, within the widths the analyzer measures; nil for anything else
    /// (the attribute is untrusted, so a sign, a space, or a huge number is ignored).
    private static func declaredWidth(_ cols: String?) -> Int? {
        guard let cols, !cols.isEmpty, cols.utf8.count <= 3, cols.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              let width = Int(cols), BraillePageAnalyzer.widthRange.contains(width) else { return nil }
        return width
    }

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
        } else if isPEF && elementName == "volume", lineWidth == nil {
            lineWidth = Self.declaredWidth(attributeDict["cols"])
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
