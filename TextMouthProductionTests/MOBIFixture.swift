import XCTest

/// Builds a Kindle (MOBI 6) book in memory, byte by byte, so a test can make
/// a valid book of any shape (a contents of any depth, trailing entries, a
/// PalmDOC book, DRM flags) and then damage it at a known place. The bytes
/// are laid out as the MobileRead wiki's "MOBI" and "PDB" pages describe, the
/// same layout `MOBIPalmDatabase`, `MOBIHeaders`, `MOBIText`, and `MOBIIndex`
/// read, so the fixture also proves they agree with the specification and not
/// only with each other (the samples from calibre and Project Gutenberg
/// prove it against real files).
struct MOBIFixture {
    /// One contents entry: its label, the byte offset it names in the text,
    /// and its depth (0 for a chapter).
    struct Entry {
        var label: String
        var offset: Int
        var depth = 0
    }

    // MARK: What the book holds

    /// The book's HTML, UTF-8 unless `textBytes` is given.
    var html = "<html><head></head><body><p>A short book for a test.</p></body></html>"
    /// The text's bytes when they are not `html` as UTF-8 (Windows-1252 text,
    /// plain PalmDOC text, or bytes that are not text at all).
    var textBytes: [UInt8]?
    /// The text encoding the header names: 65001 or 1252.
    var encoding = 65001
    /// The compression the header names, and the one the fixture really
    /// uses: 1 none, 2 PalmDOC, 17480 HUFF/CDIC (the small code of
    /// `huffmanRecords()`, which writes only text of bytes below 0xF0).
    var compression = 1
    /// How many bytes of text one record holds before it is cut.
    var recordSize = 4096
    /// An entry written at the end of every text record, as extra-data flag
    /// bit 1 describes (its size, as a one-byte number, follows its bytes).
    var trailingEntry: [UInt8]?
    /// The contents (NCX index); none when empty.
    var entries: [Entry] = []
    /// EXTH 503, the title; EXTH 100, the authors; EXTH 524, the language.
    var title: String? = "Fixture Book"
    var authors = ["Imre Falk"]
    var language: String? = "en"
    /// Further EXTH records, by type.
    var extraEXTH: [Int: [UInt8]] = [:]
    /// The full name in the header, and the database name.
    var fullName = "Fixture Book Full Name"
    var databaseName = "Fixture_Book"

    // MARK: What the headers say

    /// The PalmDOC header's encryption type, and the MOBI header's DRM
    /// offset and version.
    var encryption = 0
    var drmOffset = 0xFFFF_FFFF
    var version = 6
    /// The database's type and creator, and whether record 0 has a MOBI
    /// header (a plain PalmDOC book's has not).
    var type = "BOOK"
    var creator = "MOBI"
    var hasMOBIHeader = true

    // MARK: Layout

    /// The MOBI header's length, counted from byte 16: 232 in the books of
    /// calibre and Project Gutenberg.
    static let mobiHeaderLength = 232
    /// The Palm database header's size, before the record table.
    static let databaseHeaderSize = 78

    /// The text, once it is bytes.
    var text: [UInt8] { textBytes ?? Array(html.utf8) }

    /// The index of the first record of the contents, or nil without one. The
    /// Huffman tables, when the book has them, come right after the text.
    var indexRecordNumber: Int? { entries.isEmpty ? nil : 1 + textRecords().count + (compression == 17480 ? 2 : 0) }

    // MARK: Building

    /// The book as a file's bytes.
    func data() -> [UInt8] {
        let textRecords = self.textRecords()
        var records: [[UInt8]] = [record0(textRecordCount: textRecords.count)]
        records += textRecords
        if compression == 17480 { records += Self.huffmanRecords() }
        if hasMOBIHeader, !entries.isEmpty { records += indexRecords() }
        return Self.database(named: databaseName, type: type, creator: creator, records: records)
    }

    /// The text cut into records of `recordSize`, each compressed and given
    /// its trailing entry.
    func textRecords() -> [[UInt8]] {
        let bytes = text
        var records: [[UInt8]] = []
        var start = 0
        while start < bytes.count {
            let chunk = Array(bytes[start..<min(bytes.count, start + recordSize)])
            var record = chunk
            if compression == 2 { record = Self.compress(chunk) }
            if compression == 17480 { record = Self.huffmanCompress(chunk) }
            if let entry = trailingEntry {
                // The entry, then its own size (counting the size byte) with
                // the high bit set, which marks where the number starts.
                record += entry
                record.append(UInt8(0x80 | (entry.count + 1)))
            }
            records.append(record)
            start += recordSize
        }
        return records
    }

    /// Record 0: the PalmDOC header, the MOBI header, the EXTH records, and
    /// the full name.
    private func record0(textRecordCount: Int) -> [UInt8] {
        var record = [UInt8](repeating: 0, count: hasMOBIHeader ? 16 + Self.mobiHeaderLength : 16)
        Self.put16(&record, 0, compression)
        Self.put32(&record, 4, text.count)
        Self.put16(&record, 8, textRecordCount)
        Self.put16(&record, 10, recordSize)
        Self.put16(&record, 12, encryption)
        guard hasMOBIHeader else { return record }

        record.replaceSubrange(16..<20, with: Array("MOBI".utf8))
        Self.put32(&record, 20, Self.mobiHeaderLength)
        Self.put32(&record, 24, 2)
        Self.put32(&record, 28, encoding)
        Self.put32(&record, 36, version)
        // The Huffman tables, when the book has them, follow the text records.
        if compression == 17480 {
            Self.put32(&record, 112, 1 + textRecordCount)
            Self.put32(&record, 116, 2)
        }
        // Fields that say "none": the DRM, the index.
        Self.put32(&record, 168, drmOffset)
        Self.put32(&record, 244, indexRecordNumber ?? 0xFFFF_FFFF)
        Self.put32(&record, 240, trailingEntry == nil ? 0 : 0b10)

        // The EXTH records, then the full name after them.
        var records: [(type: Int, data: [UInt8])] = authors.map { (type: 100, data: Array($0.utf8)) }
        if let title { records.append((type: 503, data: Array(title.utf8))) }
        if let language { records.append((type: 524, data: Array(language.utf8))) }
        records += extraEXTH.sorted { $0.key < $1.key }.map { (type: $0.key, data: $0.value) }
        if !records.isEmpty {
            Self.put32(&record, 128, 0x40)
            record += Self.exth(records)
        }
        let name = Array(fullName.utf8)
        Self.put32(&record, 84, record.count)
        Self.put32(&record, 88, name.count)
        record += name + [0, 0]
        return record
    }

    /// The EXTH header and records, padded to a multiple of four bytes.
    private static func exth(_ records: [(type: Int, data: [UInt8])]) -> [UInt8] {
        var body: [UInt8] = []
        for record in records {
            body += be32(record.type) + be32(record.data.count + 8) + record.data
        }
        let length = 12 + body.count
        let padding = (4 - length % 4) % 4
        return Array("EXTH".utf8) + be32(length + padding) + be32(records.count) + body + [UInt8](repeating: 0, count: padding)
    }

    // MARK: The Contents

    /// The three kinds of record a contents is stored in: the index's
    /// header (with its tag table), its entries, and the label strings.
    private func indexRecords() -> [[UInt8]] {
        // One tag each for the offset (1), size (2), label (3), and depth (4),
        // each in its own bit of one control byte, then the end of that byte.
        let tags: [[UInt8]] = [[1, 1, 1, 0], [2, 1, 2, 0], [3, 1, 4, 0], [4, 1, 8, 0], [0, 0, 0, 1]]
        let tagx = Array("TAGX".utf8) + Self.be32(12 + tags.count * 4) + Self.be32(1) + tags.flatMap { $0 }

        // The labels, each a length and its bytes; an entry names its label
        // by the label's place in this record.
        var labels: [UInt8] = []
        var labelPlaces: [Int] = []
        for entry in entries {
            labelPlaces.append(labels.count)
            let bytes = Array(entry.label.utf8)
            labels += Self.variableNumber(bytes.count) + bytes
        }

        var header = [UInt8](repeating: 0, count: 192)
        header.replaceSubrange(0..<4, with: Array("INDX".utf8))
        Self.put32(&header, 4, 192)
        Self.put32(&header, 24, 1)
        Self.put32(&header, 28, 65001)
        Self.put32(&header, 52, 1)
        let primary = header + tagx

        // The entries: a name, a control byte saying each tag has one value,
        // and the four values.
        var data = header
        var offsets: [Int] = []
        for (position, entry) in entries.enumerated() {
            offsets.append(data.count)
            let name = Array(String(format: "%02d", position).utf8)
            data += [UInt8(name.count)] + name + [0x0F]
            data += Self.variableNumber(entry.offset) + Self.variableNumber(1)
                + Self.variableNumber(labelPlaces[position]) + Self.variableNumber(entry.depth)
        }
        let tableOffset = data.count
        data += Array("IDXT".utf8) + offsets.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        data += [UInt8](repeating: 0, count: data.count % 4 == 0 ? 0 : 4 - data.count % 4)
        Self.put32(&data, 20, tableOffset)
        Self.put32(&data, 24, entries.count)
        return [primary, data, labels]
    }

    // MARK: The Palm Database

    /// The database around `records`: the header, the table of records, and
    /// the records, each at the offset its entry names.
    static func database(named name: String, type: String, creator: String, records: [[UInt8]]) -> [UInt8] {
        var file = [UInt8](repeating: 0, count: databaseHeaderSize)
        let nameBytes = Array(name.utf8.prefix(31))
        file.replaceSubrange(0..<nameBytes.count, with: nameBytes)
        file.replaceSubrange(60..<64, with: Array(type.utf8))
        file.replaceSubrange(64..<68, with: Array(creator.utf8))
        put16(&file, 76, records.count)

        // Two bytes of padding follow the table in real books.
        var offset = databaseHeaderSize + records.count * 8 + 2
        var table: [UInt8] = []
        for (index, record) in records.enumerated() {
            table += be32(offset) + [0] + [UInt8(0), UInt8(0), UInt8(index & 0xFF)]
            offset += record.count
        }
        return file + table + [0, 0] + records.flatMap { $0 }
    }

    /// Where each record of `file` starts, read from its table of records.
    static func recordOffsets(of file: [UInt8]) -> [Int] {
        let count = Int(file[76]) << 8 | Int(file[77])
        return (0..<count).map { index in
            let at = databaseHeaderSize + index * 8
            return (0..<4).reduce(0) { $0 << 8 | Int(file[at + $1]) }
        }
    }

    // MARK: Numbers

    /// `value` as four big-endian bytes.
    static func be32(_ value: Int) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    /// Writes `value` as two big-endian bytes at `offset`.
    static func put16(_ bytes: inout [UInt8], _ offset: Int, _ value: Int) {
        bytes[offset] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 1] = UInt8(value & 0xFF)
    }

    /// Writes `value` as four big-endian bytes at `offset`.
    static func put32(_ bytes: inout [UInt8], _ offset: Int, _ value: Int) {
        bytes.replaceSubrange(offset..<(offset + 4), with: be32(value))
    }

    /// `value` as an index number: 7-bit groups, most significant first, the
    /// last with its high bit set.
    static func variableNumber(_ value: Int) -> [UInt8] {
        var groups = [UInt8(value & 0x7F) | 0x80]
        var rest = value >> 7
        while rest > 0 {
            groups.insert(UInt8(rest & 0x7F), at: 0)
            rest >>= 7
        }
        return groups
    }

    // MARK: HUFF/CDIC Compression

    /// A small Huffman code in the layout the format uses, to prove the
    /// reader against the specification: a byte below 0xF0 is its own 8-bit
    /// codeword (the dictionary entry 0xEF - byte, a text entry of that
    /// byte); the 256 codewords of 12 bits that begin with 0xF are the
    /// dictionary entries 0xF0 to 0x1EF, whose text is a capital and its
    /// lowercase ("Aa", "Bb", and so on, cycling) except the last, entry
    /// 0x1EF, whose text is "hello" written as a coded string (an entry that
    /// must be decompressed in turn). Entry k's 12-bit codeword is 0x10EF - k.
    static let huffmanLastEntry = 0x1EF
    static let huffmanCodedText = Array("hello".utf8)

    /// The HUFF record and the CDIC record the code above is written in.
    static func huffmanRecords() -> [[UInt8]] {
        // HUFF: a 24-byte header, the 256 words of the first-byte table, and
        // the 32 pairs of the length table.
        var huff = Array("HUFF".utf8) + be32(24) + be32(24) + be32(24 + 1024) + [UInt8](repeating: 0, count: 8)
        for byte in 0..<256 {
            // Bit 7: the byte settles the code. Bits 0 to 4: its length. The rest: the base of its index.
            huff += be32(byte < 0xF0 ? (0xEF << 8) | 0x80 | 8 : 12)
        }
        for length in 1...32 {
            huff += length == 12 ? be32(0xF00) + be32(0x10EF) : be32(0xFFFF_FFFF) + be32(0)
        }

        // CDIC: a 16-byte header, a 16-bit offset for each of the 496
        // entries (counted from the end of the header), and the entries.
        let entryCount = huffmanLastEntry + 1
        var offsets: [UInt8] = []
        var body: [UInt8] = []
        for index in 0..<entryCount {
            offsets += [UInt8((entryCount * 2 + body.count) >> 8), UInt8((entryCount * 2 + body.count) & 0xFF)]
            let text: [UInt8]
            var isText = true
            if index < 0xF0 {
                text = [UInt8(0xEF - index)]
            } else if index == huffmanLastEntry {
                text = huffmanCodedText
                isText = false
            } else {
                let letter = (index - 0xF0) % 26
                text = [UInt8(0x41 + letter), UInt8(0x61 + letter)]
            }
            let word = text.count | (isText ? 0x8000 : 0)
            body += [UInt8(word >> 8), UInt8(word & 0xFF)] + text
        }
        let cdic = Array("CDIC".utf8) + be32(16) + be32(entryCount) + be32(9) + offsets + body
        return [huff, cdic]
    }

    /// `input` written in the small code: "hello" as the coded entry, a
    /// capital with its lowercase as a 12-bit codeword, and any other byte
    /// (below 0xF0) as an 8-bit codeword. Bits are packed from the high bit
    /// of each byte and the last byte is padded with zeros.
    static func huffmanCompress(_ input: [UInt8]) -> [UInt8] {
        var bits: [Bool] = []
        /// Appends the low `count` bits of `value`, high bit first.
        func append(_ value: Int, _ count: Int) {
            for shift in stride(from: count - 1, through: 0, by: -1) { bits.append(value >> shift & 1 == 1) }
        }
        var position = 0
        while position < input.count {
            let byte = input[position]
            if input[position...].starts(with: huffmanCodedText) {
                append(0x10EF - huffmanLastEntry, 12)
                position += huffmanCodedText.count
            } else if (0x41...0x5A).contains(byte), position + 1 < input.count, input[position + 1] == byte + 0x20 {
                append(0x10EF - (0xF0 + Int(byte - 0x41)), 12)
                position += 2
            } else {
                // The small code has no codeword for the high bytes, so one is left
                // out; a test that uses one finds its text changed, and fails.
                if byte < 0xF0 { append(Int(byte), 8) }
                position += 1
            }
        }
        var bytes: [UInt8] = []
        for start in stride(from: 0, to: bits.count, by: 8) {
            var value = 0
            for offset in 0..<8 { value = value << 1 | (start + offset < bits.count && bits[start + offset] ? 1 : 0) }
            bytes.append(UInt8(value))
        }
        return bytes
    }

    // MARK: PalmDOC Compression

    /// `input` compressed as PalmDOC, with every kind of code the format
    /// has: a repeated phrase (3 to 10 bytes from up to 2047 back), a space
    /// folded into the letter after it, a byte as itself, and a run of bytes
    /// copied (for those a literal would be taken for a code). It looks for
    /// phrases the slow way, which is enough for a test's few kilobytes.
    static func compress(_ input: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        var position = 0
        while position < input.count {
            var bestLength = 0
            var bestDistance = 0
            for distance in stride(from: 1, through: min(position, 2047), by: 1) {
                var length = 0
                while length < 10, position + length < input.count,
                      input[position + length] == input[position - distance + length] {
                    length += 1
                }
                if length > bestLength { (bestLength, bestDistance) = (length, distance) }
            }
            if bestLength >= 3 {
                let code = 0x8000 | bestDistance << 3 | (bestLength - 3)
                output += [UInt8(code >> 8), UInt8(code & 0xFF)]
                position += bestLength
                continue
            }
            let byte = input[position]
            if byte == 0x20, position + 1 < input.count, (0x40...0x7F).contains(input[position + 1]) {
                output.append(input[position + 1] | 0x80)
                position += 2
            } else if byte == 0 || (0x09...0x7F).contains(byte) {
                output.append(byte)
                position += 1
            } else {
                output += [1, byte]
                position += 1
            }
        }
        return output
    }
}

extension XCTestCase {
    /// A file named `name` in a new folder of this test's own holding
    /// `bytes`.
    func writeMOBI(_ bytes: [UInt8], named name: String = "book.mobi") throws -> URL {
        let url = try makeSandboxDirectory("MOBI").appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }
}
