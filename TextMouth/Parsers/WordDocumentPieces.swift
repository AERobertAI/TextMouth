import Foundation

// MARK: - The Piece Table

/// The piece table of a Word 97-2003 document ([MS-DOC] 2.9.178, in the CLX
/// of the table stream): the list of pieces of text that make up the
/// document, each with the file offset where its characters are stored and
/// whether they are stored as 8-bit Windows-1252 or as UTF-16LE.
///
/// A document saved in full has one piece; one saved with Fast Save has many,
/// stored in any order, so a character's place in the stream and its place in
/// the text (its character position, CP) are told apart throughout. A
/// paragraph or character property says where in the stream its text is, as
/// a file offset (FC); `characterRanges(fileStart:fileEnd:budget:)` turns
/// that into the character positions it covers.
///
/// Every offset and count is checked against the data when the table is
/// read, so reading the text afterwards cannot leave the stream.
struct WordPieceTable {

    /// One piece of the document's text.
    struct Piece {
        /// The character position of the piece's first character.
        let firstCharacter: Int
        /// The character position after the piece's last character.
        let endCharacter: Int
        /// The offset in the `WordDocument` stream of the first character.
        let fileOffset: Int
        /// Whether the characters are one byte each (Windows-1252), not two (UTF-16LE).
        let isCompressed: Bool

        /// Bytes per character.
        var width: Int { isCompressed ? 1 : 2 }
        /// The number of characters.
        var length: Int { endCharacter - firstCharacter }
        /// The offset after the piece's last byte.
        var fileEnd: Int { fileOffset + length * width }
    }

    /// The pieces in character order.
    let pieces: [Piece]
    /// The pieces in file order, for turning file offsets into positions.
    private let piecesByFile: [Piece]
    /// For each piece in file order, the largest `fileEnd` of it and of
    /// those before it: a non-decreasing list a search can halve.
    private let largestFileEnd: [Int]

    /// How many characters the pieces hold in all.
    var characterCount: Int { pieces.last?.endCharacter ?? 0 }

    // MARK: Reading the CLX

    /// Reads the piece table from the CLX at `clx` in `table`, checking each
    /// piece against `document`, the `WordDocument` stream.
    /// - Throws: `OLEDamage` for a CLX of an unknown kind, a piece table whose
    ///   size or character positions do not fit, or a piece whose characters
    ///   lie outside the stream.
    init(clx: Range<Int>, table: OLEBytes, document: OLEBytes) throws {
        // The CLX is any number of property modifier groups (kind 1, a 16-bit
        // size and the modifiers, which belong to fast-saved changes and are
        // not read) and then the piece table (kind 2, a 32-bit size).
        var position = clx.lowerBound
        var plcStart = 0
        var plcLength = 0
        while true {
            guard position < clx.upperBound else { throw OLEDamage(reason: "the CLX holds no piece table") }
            let kind = try table.u8(position)
            if kind == 1 {
                let size = try table.u16(position + 1)
                position += 3 + size
            } else if kind == 2 {
                plcLength = try table.u32(position + 1)
                plcStart = position + 5
                break
            } else {
                throw OLEDamage(reason: "the CLX holds a block of kind \(kind)")
            }
        }
        guard plcStart + plcLength <= clx.upperBound else { throw OLEDamage(reason: "the piece table runs past the CLX") }

        // A PlcPcd: n+1 character positions of 4 bytes, then n descriptors of 8.
        guard plcLength >= 16, (plcLength - 4) % 12 == 0 else { throw OLEDamage(reason: "the piece table is \(plcLength) bytes long") }
        let count = (plcLength - 4) / 12
        let descriptorsStart = plcStart + (count + 1) * 4
        var pieces: [Piece] = []
        pieces.reserveCapacity(count)
        var previousEnd = try table.u32(plcStart)
        guard previousEnd == 0 else { throw OLEDamage(reason: "the text does not begin at character 0") }
        for index in 0..<count {
            let end = try table.u32(plcStart + (index + 1) * 4)
            guard end >= previousEnd else { throw OLEDamage(reason: "piece \(index) ends before it begins") }
            // The descriptor: 2 bytes of flags, the file offset, 2 bytes of modifiers.
            let rawOffset = try table.u32(descriptorsStart + index * 8 + 2)
            let isCompressed = rawOffset & 0x4000_0000 != 0
            // A compressed offset is stored doubled, so that it is told from
            // an uncompressed one by one bit.
            let offset = isCompressed ? (rawOffset & 0x3FFF_FFFF) / 2 : rawOffset & 0x3FFF_FFFF
            let piece = Piece(firstCharacter: previousEnd, endCharacter: end, fileOffset: offset, isCompressed: isCompressed)
            guard document.contains(offset: offset, length: piece.length * piece.width) else {
                throw OLEDamage(reason: "piece \(index) holds \(piece.length) characters that run past the stream")
            }
            pieces.append(piece)
            previousEnd = end
        }
        self.pieces = pieces

        let byFile = pieces.filter { $0.length > 0 }.sorted { $0.fileOffset < $1.fileOffset }
        piecesByFile = byFile
        var largest = 0
        largestFileEnd = byFile.map { piece in
            largest = max(largest, piece.fileEnd)
            return largest
        }
    }

    // MARK: Reading the Text

    /// Calls `body` with the character position and the UTF-16 code unit of
    /// each character from position `start` up to (not including) `limit`,
    /// in order. Windows-1252 characters are turned into their Unicode code
    /// unit as they are read.
    /// - Parameter document: the stream the table was checked against; the
    ///   reads here stay inside the ranges that check passed.
    func forEachCharacter(
        from start: Int = 0, upTo limit: Int, in document: OLEBytes,
        _ body: (_ position: Int, _ unit: UInt16) throws -> Void
    ) rethrows {
        let bytes = document.bytes
        for piece in pieces {
            guard piece.firstCharacter < limit else { return }
            guard piece.endCharacter > start else { continue }
            let end = min(piece.endCharacter, limit)
            var position = max(piece.firstCharacter, start)
            if piece.isCompressed {
                while position < end {
                    try body(position, Self.unicode(ofWindows1252: bytes[piece.fileOffset + position - piece.firstCharacter]))
                    position += 1
                }
            } else {
                while position < end {
                    let at = piece.fileOffset + (position - piece.firstCharacter) * 2
                    try body(position, UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8)
                    position += 1
                }
            }
        }
    }

    /// The character positions that the bytes `fileStart..<fileEnd` of the
    /// stream hold, as one range for each piece they cross, in file order.
    /// - Parameter budget: how many pieces the caller will still look at in
    ///   all its calls; each piece looked at costs one. Pieces that overlap in
    ///   the file could otherwise make every call cross every piece.
    /// - Throws: `OLEDamage` when the budget is spent.
    func characterRanges(fileStart: Int, fileEnd: Int, budget: inout Int) throws -> [Range<Int>] {
        guard fileStart < fileEnd else { return [] }
        // The first piece in file order that ends after fileStart, by halving.
        var low = 0
        var high = piecesByFile.count
        while low < high {
            let middle = (low + high) / 2
            if largestFileEnd[middle] > fileStart { high = middle } else { low = middle + 1 }
        }
        var ranges: [Range<Int>] = []
        var index = low
        while index < piecesByFile.count, piecesByFile[index].fileOffset < fileEnd {
            budget -= 1
            guard budget >= 0 else { throw OLEDamage(reason: "the pieces overlap too much to place the properties") }
            let piece = piecesByFile[index]
            let start = max(fileStart, piece.fileOffset)
            let end = min(fileEnd, piece.fileEnd)
            if start < end {
                let first = piece.firstCharacter + (start - piece.fileOffset) / piece.width
                let after = piece.firstCharacter + (end - piece.fileOffset + piece.width - 1) / piece.width
                ranges.append(first..<min(after, piece.endCharacter))
            }
            index += 1
        }
        return ranges
    }

    // MARK: Windows-1252

    /// The code units of Windows-1252's bytes 0x80 to 0x9F; every other byte
    /// is the code unit of the same number (as in Latin-1). The five bytes
    /// Windows-1252 leaves undefined keep their control characters, which the
    /// reader drops.
    private static let windows1252Upper: [UInt16] = [
        0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
        0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
    ]

    /// The UTF-16 code unit of the Windows-1252 byte `byte`.
    private static func unicode(ofWindows1252 byte: UInt8) -> UInt16 {
        (0x80...0x9F).contains(byte) ? windows1252Upper[Int(byte) - 0x80] : UInt16(byte)
    }
}
