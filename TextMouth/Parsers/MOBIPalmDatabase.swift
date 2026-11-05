import Foundation

/// A window onto a book's bytes, every read of which is checked against the
/// window. A MOBI book's file is untrusted input: each offset, length, and
/// count in it is read through here, so a field that points outside the data
/// throws `MOBIError.damaged` instead of trapping on an index.
///
/// The window shares the file's storage (arrays copy on write), so a record
/// is a range, never a copy.
struct MOBIView {
    /// The whole file, shared by every window onto it.
    let bytes: [UInt8]
    /// The part of `bytes` this window shows.
    let range: Range<Int>

    /// A window onto all of `bytes`.
    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.range = 0..<bytes.count
    }

    /// A window onto `range` of `bytes`, which the caller has checked.
    fileprivate init(bytes: [UInt8], range: Range<Int>) {
        self.bytes = bytes
        self.range = range
    }

    /// How many bytes the window shows.
    var count: Int { range.count }

    /// Throws unless the `length` bytes from `offset` lie inside the window.
    /// - Parameter what: Names the field read, for the error's detail.
    func require(_ offset: Int, _ length: Int, _ what: String) throws {
        // Written without adding, so no value from the file can overflow.
        guard offset >= 0, length >= 0, offset <= count, length <= count - offset else {
            throw MOBIError.damaged("\(what) lies outside the book's data")
        }
    }

    /// The byte at `offset`.
    func uint8(_ offset: Int, _ what: String) throws -> Int {
        try require(offset, 1, what)
        return Int(bytes[range.lowerBound + offset])
    }

    /// The big-endian 16-bit number at `offset`.
    func uint16(_ offset: Int, _ what: String) throws -> Int {
        try require(offset, 2, what)
        let start = range.lowerBound + offset
        return Int(bytes[start]) << 8 | Int(bytes[start + 1])
    }

    /// The big-endian 32-bit number at `offset`.
    func uint32(_ offset: Int, _ what: String) throws -> Int {
        try require(offset, 4, what)
        let start = range.lowerBound + offset
        var value = 0
        for index in 0..<4 { value = value << 8 | Int(bytes[start + index]) }
        return value
    }

    /// The `length` bytes at `offset`, as a window.
    func window(_ offset: Int, _ length: Int, _ what: String) throws -> MOBIView {
        try require(offset, length, what)
        let start = range.lowerBound + offset
        return MOBIView(bytes: bytes, range: start..<(start + length))
    }

    /// The window from `offset` to its end.
    func window(from offset: Int, _ what: String) throws -> MOBIView {
        // A zero-length read at `offset` is inside the window exactly when
        // `offset` is, so this refuses an offset past the end.
        try require(offset, 0, what)
        return try window(offset, count - offset, what)
    }

    /// The bytes at `offset`, `length` of them, as an array.
    func slice(_ offset: Int, _ length: Int, _ what: String) throws -> [UInt8] {
        let part = try window(offset, length, what)
        return Array(bytes[part.range])
    }

    /// The window's bytes as an array.
    var array: [UInt8] { Array(bytes[range]) }

    /// Whether the four bytes at `offset` are the ASCII `tag`, false when
    /// they are not there.
    func hasTag(_ tag: String, at offset: Int) -> Bool {
        let expected = Array(tag.utf8)
        guard (try? require(offset, expected.count, tag)) != nil else { return false }
        let start = range.lowerBound + offset
        return Array(bytes[start..<(start + expected.count)]) == expected
    }
}

/// The Palm database a Kindle book (MOBI) or a PalmDOC book is stored in:
/// a header, a table of records, and the records themselves. It knows
/// where each record lies and nothing of what it holds.
///
/// Written from the format's specification (the MobileRead wiki's "PDB"
/// and "MOBI" pages) and read against foliate-js's `mobi.js` (MIT) for the
/// header's field offsets: header name at 0 (32 bytes), type at 60 and
/// creator at 64 (4 bytes each), record count at 76 (16 bits), and the
/// records' entries from 78, 8 bytes each, the first 4 the record's offset.
struct MOBIPalmDatabase {
    /// The bytes of the whole file.
    let file: MOBIView
    /// The database name (bytes 0 to 31, up to the first NUL), which names
    /// the book when it names no title itself.
    let name: String
    /// The four-byte type: `BOOK` for a MOBI book, `TEXt` for a PalmDOC.
    let type: String
    /// The four-byte creator: `MOBI` for a MOBI book, `REAd` for a PalmDOC.
    let creator: String
    /// Each record's bytes, in order. A record ends where the next begins
    /// and the last at the file's end.
    private let records: [MOBIView]

    /// The type and creator of a MOBI book, and of a plain PalmDOC book.
    static let mobiSignature = (type: "BOOK", creator: "MOBI")
    static let palmDocSignature = (type: "TEXt", creator: "REAd")

    /// The size of the header before the record table.
    private static let headerSize = 78

    /// Reads the database in `bytes`.
    /// - Throws: `MOBIError.notAKindleBook` when the type and creator are
    ///   neither of the two a book has, and `.damaged` for a record table
    ///   that does not fit the file or records whose offsets do not ascend
    ///   inside it.
    init(bytes: [UInt8]) throws {
        let file = MOBIView(bytes)
        guard file.count >= Self.headerSize else { throw MOBIError.notAKindleBook }
        self.file = file

        // The type and creator decide whether this is a book at all, before
        // any count is believed.
        let type = Self.text(of: try file.slice(60, 4, "The database type"))
        let creator = Self.text(of: try file.slice(64, 4, "The database creator"))
        let isBook = (type == Self.mobiSignature.type && creator == Self.mobiSignature.creator)
            || (type == Self.palmDocSignature.type && creator == Self.palmDocSignature.creator)
        guard isBook else { throw MOBIError.notAKindleBook }
        self.type = type
        self.creator = creator

        let nameBytes = try file.slice(0, 32, "The database name")
        name = Self.text(of: Array(nameBytes.prefix { $0 != 0 }))

        // The record table: 8 bytes an entry. The count is a 16-bit number,
        // so the table is 512 KB at most; it must still fit the file.
        let recordCount = try file.uint16(76, "The record count")
        guard recordCount >= 1 else { throw MOBIError.notAKindleBook }
        let tableEnd = Self.headerSize + recordCount * 8
        guard tableEnd <= file.count else {
            throw MOBIError.damaged("the table of records is longer than the book")
        }

        // Each record starts where its entry says, and must not start before
        // the table ends, before the record ahead of it, or after the file
        // ends. A record ends where the next starts, so ascending starts are
        // also what keeps the records from overlapping.
        var starts: [Int] = []
        starts.reserveCapacity(recordCount + 1)
        for index in 0..<recordCount {
            let start = try file.uint32(Self.headerSize + index * 8, "Record \(index)'s offset")
            guard start >= tableEnd, start <= file.count, start >= (starts.last ?? 0) else {
                throw MOBIError.damaged("record \(index) does not lie inside the book in order")
            }
            starts.append(start)
        }
        starts.append(file.count)
        records = try (0..<recordCount).map {
            try file.window(starts[$0], starts[$0 + 1] - starts[$0], "Record \($0)")
        }
    }

    /// How many records the database holds.
    var recordCount: Int { records.count }

    /// Record `index`.
    /// - Throws: `MOBIError.damaged` when the book has no such record.
    func record(_ index: Int, _ what: String = "A record") throws -> MOBIView {
        guard records.indices.contains(index) else {
            throw MOBIError.damaged("\(what) is record \(index), and the book has only \(records.count)")
        }
        return records[index]
    }

    /// `bytes` read as Latin-1, which keeps each byte as the character of
    /// its value: the type, creator, and name are ASCII in every real book.
    private static func text(of bytes: [UInt8]) -> String {
        String(bytes.map { Character(Unicode.Scalar($0)) })
    }
}
