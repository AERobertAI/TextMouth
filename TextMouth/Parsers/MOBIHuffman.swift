import Foundation

/// HUFF/CDIC, the compression of some older commercial Mobipocket books
/// (compression type 17480): a Huffman code whose codewords stand for
/// dictionary entries, some of which are themselves coded.
///
/// The book holds a HUFF record, which gives two tables for finding a
/// codeword's length and its dictionary index, and one or more CDIC records
/// that hold the dictionary. Written from the format's specification (the
/// MobileRead wiki's "MOBI" page); the way a codeword is found and turned
/// into an entry follows foliate-js's `mobi.js` (MIT), whose `huffcdic`
/// function is the map of it. The steps of `decompress(_:...)` are close to
/// that function's, which is what the format leaves room for, so the MIT
/// notice for `mobi.js` covers it.
struct MOBIHuffman {

    /// One dictionary entry: where its bytes lie in the file, and whether
    /// they are the entry's text (`isText`) or a coded string that must be
    /// decompressed in turn to give it.
    private struct Entry {
        var range: Range<Int>
        var isText: Bool
    }

    /// How deep entries may be coded in entries. Real books go one level.
    /// An entry that names itself, or a cycle of entries, would otherwise
    /// never end, so the depth is held to a few levels (recursion here is
    /// at most this many frames, whatever the file says).
    private static let maximumDepth = 8
    /// Most records the HUFF and CDIC records may fill, and most dictionary
    /// entries all the CDIC records may hold.
    private static let maximumRecords = 256
    private static let maximumEntries = 1 << 20

    /// The file the entries' ranges lie in.
    private let bytes: [UInt8]
    /// For each value of a codeword's first byte: whether that byte alone
    /// settles the code (bit 7), the code's length (bits 0 to 4), and the
    /// value its index is counted from (the rest).
    private let firstByteTable: [Int]
    /// For each code length from 1 to 32 (index 0 is unused): the smallest
    /// codeword of that length, and the value its index is counted from.
    private let lengthTable: [(minimum: Int, base: Int)]
    private let dictionary: [Entry]

    /// Reads the HUFF record at `firstRecord` and the `recordCount - 1` CDIC
    /// records after it.
    /// - Throws: `MOBIError.damaged` for tables or a dictionary that do not
    ///   fit their records, or records that are not HUFF and CDIC.
    init(database: MOBIPalmDatabase, firstRecord: Int, recordCount: Int) throws {
        guard recordCount >= 2, recordCount <= Self.maximumRecords else {
            throw MOBIError.damaged("the Huffman tables are in an impossible number of records")
        }
        let huff = try database.record(firstRecord, "The Huffman table")
        guard huff.hasTag("HUFF", at: 0) else { throw MOBIError.damaged("the Huffman table is missing") }
        let firstByteOffset = try huff.uint32(8, "The Huffman table's first offset")
        let lengthOffset = try huff.uint32(12, "The Huffman table's second offset")
        firstByteTable = try (0..<256).map { try huff.uint32(firstByteOffset + $0 * 4, "A Huffman code") }
        lengthTable = try (0..<33).map { length in
            // Index 0 is unused; lengths 1 to 32 follow, eight bytes each.
            guard length > 0 else { return (0, 0) }
            let at = lengthOffset + (length - 1) * 8
            return (try huff.uint32(at, "A Huffman code length's minimum"), try huff.uint32(at + 4, "A Huffman code length's base"))
        }

        var entries: [Entry] = []
        for number in 1..<recordCount {
            let record = try database.record(firstRecord + number, "A dictionary")
            guard record.hasTag("CDIC", at: 0) else { throw MOBIError.damaged("a dictionary record is not CDIC") }
            let headerLength = try record.uint32(4, "The dictionary header's length")
            let total = try record.uint32(8, "The dictionary's entry count")
            let codeLength = try record.uint32(12, "The dictionary's code length")
            guard codeLength <= 16, total <= Self.maximumEntries else {
                throw MOBIError.damaged("a dictionary is larger than a book's can be")
            }
            // This record's share: all its codes, or what is left of the total.
            let share = max(0, min(1 << codeLength, total - entries.count))
            for index in 0..<share {
                // The entry's place is a 16-bit offset, counted from the end of the header.
                let place = headerLength + (try record.uint16(headerLength + index * 2, "A dictionary entry's place"))
                let word = try record.uint16(place, "A dictionary entry")
                let length = word & 0x7FFF
                let text = try record.window(place + 2, length, "A dictionary entry's bytes")
                entries.append(Entry(range: text.range, isText: word & 0x8000 != 0))
            }
        }
        dictionary = entries
        bytes = database.file.bytes
    }

    /// Decompresses the record `bytes[range]` (the text so far in `output`,
    /// its length held to `limit`).
    /// - Throws: `MOBIError.damaged` for a codeword the tables do not make
    ///   sense of, an index past the dictionary, or entries coded too deeply.
    func decompress(_ range: Range<Int>, into output: inout [UInt8], limit: Int) throws {
        try decompress(range, into: &output, limit: limit, depth: 0)
    }

    /// `decompress(_:into:limit:)`, `depth` levels down in coded entries.
    private func decompress(_ range: Range<Int>, into output: inout [UInt8], limit: Int, depth: Int) throws {
        guard depth <= Self.maximumDepth else { throw MOBIError.damaged("a dictionary entry is coded in too many levels") }
        let bitCount = range.count * 8
        var position = 0
        while position < bitCount, output.count < limit {
            // The next 32 bits, the bits past the end read as 0.
            let bits = thirtyTwoBits(from: range, at: position)
            let first = firstByteTable[bits >> 24]
            var length = first & 0x1F
            var base = first >> 8
            if first & 0x80 == 0 {
                // The first byte does not settle the code: the length is the
                // first one whose smallest codeword the bits reach.
                while length <= 32, length >= 1, bits >> (32 - length) < lengthTable[length].minimum { length += 1 }
                guard length >= 1, length <= 32 else { throw MOBIError.damaged("a Huffman codeword has no length") }
                base = lengthTable[length].base
            }
            guard length >= 1 else { throw MOBIError.damaged("a Huffman codeword has no length") }
            position += length
            // A last codeword that runs past the end of the record is padding.
            if position > bitCount { break }

            let index = base - (bits >> (32 - length))
            guard index >= 0, index < dictionary.count else {
                throw MOBIError.damaged("a Huffman codeword names an entry that is not in the dictionary")
            }
            let entry = dictionary[index]
            if entry.isText {
                output.append(contentsOf: bytes[entry.range])
            } else {
                // The entry is coded too.
                try decompress(entry.range, into: &output, limit: limit, depth: depth + 1)
            }
        }
        if output.count > limit { output.removeLast(output.count - limit) }
    }

    /// The 32 bits of `bytes[range]` that begin at bit `position` (counted
    /// from the first byte's high bit), as a number; bits past the end are 0.
    private func thirtyTwoBits(from range: Range<Int>, at position: Int) -> Int {
        var value = 0
        let firstByte = range.lowerBound + position / 8
        // Five bytes cover 32 bits at any bit offset within a byte.
        for index in 0..<5 {
            let at = firstByte + index
            value = value << 8 | (at < range.upperBound ? Int(bytes[at]) : 0)
        }
        // Drop the bits before `position` in the first byte, and the extras at the end.
        return (value >> (8 - position % 8)) & 0xFFFF_FFFF
    }
}
