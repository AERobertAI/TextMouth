import Foundation

// MARK: - The Piece Table

/// The piece table of a Word document ([MS-DOC] 2.9.178, in the CLX
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
/// A piece also carries property modifiers (`Pcd.prm`, [MS-DOC] 2.9.214), by
/// which a fast-saved document sets a paragraph's style, or text's emphasis
/// or hiding, without a new entry in the bin tables: either one modifier
/// (`Prm0`, named by its index in the specification's table) or an index into
/// the CLX's array of modifier groups (`Prm1`). They apply after the
/// properties of the bin tables, to the paragraph whose last character is in
/// the piece and to the characters of the piece.
///
/// Every offset and count is checked against the data when the table is
/// read, so reading the text afterwards cannot leave the stream.
struct WordPieceTable {

    // MARK: Property Modifiers

    /// The most groups of modifiers the CLX can hold: `Prm1`'s index has 15 bits.
    private static let mostModifierGroups = 0x8000

    /// The sprm a `Prm0` names by `isprm` ([MS-DOC] 2.9.215), for those sprms
    /// this reader uses; every other entry of the specification's table
    /// (justification, borders, and so on) changes nothing the reader reads.
    /// Each operand is one byte, the `Prm0`'s `val`. Keep the reader's sprms
    /// (`WordSprm`) here as it learns more.
    private static let sprmOfIsprm: [Int: Int] = [
        0x04: WordSprm.incrementLevel,
        0x09: WordSprm.pageBreakBefore,
        0x0C: WordSprm.listLevel,
        0x18: WordSprm.inTable,
        0x19: WordSprm.rowEnd,
        0x41: WordSprm.deleted,
        0x55: WordSprm.bold,
        0x56: WordSprm.italic,
        0x53: WordSprm.plain,
        0x51: WordSprm.styleSeparator,
        0x5C: WordSprm.hidden,
        0x75: WordSprm.special,
        0x78: WordSprm.outlineLevel,
    ]

    /// The property modifiers `prm` (a `Pcd`'s last two bytes) gives, as a
    /// list of sprms in the form of a `grpprl`: empty for none.
    /// - Parameter groups: the CLX's groups of modifiers, which a `Prm1` indexes.
    /// A `Prm1` whose index names no group has no modifiers: the properties
    /// are hints about the text and a stray index costs formatting, not the
    /// document, as in Apache POI.
    private static func modifiers(of prm: Int, groups: [ArraySlice<UInt8>]) -> ArraySlice<UInt8> {
        if prm & 1 == 1 {
            // Prm1: fComplex, then the 15-bit index of a group.
            let index = prm >> 1
            return index < groups.count ? groups[index] : []
        }
        // Prm0: fComplex (0), the 7-bit isprm, and the 8-bit operand.
        let isprm = (prm >> 1) & 0x7F
        guard let sprm = sprmOfIsprm[isprm] else { return [] }
        return [UInt8(sprm & 0xFF), UInt8(sprm >> 8), UInt8(prm >> 8)]
    }

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
        /// The piece's property modifiers (`Pcd.prm`) as a list of sprms,
        /// which apply after the bin tables' properties; empty for none.
        let modifiers: ArraySlice<UInt8>

        /// Bytes per character.
        let width: Int
        /// The number of characters.
        var length: Int { endCharacter - firstCharacter }
        /// The offset after the piece's last byte.
        var fileEnd: Int { fileOffset + length * width }
    }

    /// The pieces in character order.
    let pieces: [Piece]
    /// How the characters of a Word 6 or Word 95 document are read, or nil
    /// for a Word 97 document (Windows-1252 or UTF-16 by the piece).
    private let legacyCharacters: WordLegacyCharacters?
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
    /// - Parameter characters: for a Word 6 or Word 95 document, how its
    ///   characters are stored: its pieces have a plain file offset (no
    ///   compression bit), and its groups of modifiers are in the older form.
    init(clx: Range<Int>, table: OLEBytes, document: OLEBytes, characters: WordLegacyCharacters? = nil) throws {
        // The CLX is any number of property modifier groups (kind 1, a 16-bit
        // size and the modifiers, which fast-saved pieces name by their
        // index) and then the piece table (kind 2, a 32-bit size).
        var position = clx.lowerBound
        var plcStart = 0
        var plcLength = 0
        var groups: [ArraySlice<UInt8>] = []
        while true {
            guard position < clx.upperBound else { throw OLEDamage(reason: "the CLX holds no piece table") }
            let kind = try table.u8(position)
            if kind == 1 {
                let size = try table.u16(position + 1)
                guard groups.count < Self.mostModifierGroups, position + 3 + size <= clx.upperBound else {
                    throw OLEDamage(reason: "a group of modifiers runs past the CLX")
                }
                let group = try table.slice(offset: position + 3, length: size)
                groups.append(characters == nil ? group : WordLegacySprm.modern(group))
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
            let modifiers = Self.modifiers(of: try table.u16(descriptorsStart + index * 8 + 6), groups: groups)
            // A Word 97 piece says in one bit whether its characters are
            // compressed, and then stores the offset doubled; a Word 6 or
            // Word 95 piece has the offset as it is.
            let isCompressed = characters == nil && rawOffset & 0x4000_0000 != 0
            let offset = characters != nil ? rawOffset : (isCompressed ? (rawOffset & 0x3FFF_FFFF) / 2 : rawOffset & 0x3FFF_FFFF)
            let piece = Piece(
                firstCharacter: previousEnd, endCharacter: end, fileOffset: offset, isCompressed: isCompressed,
                modifiers: modifiers, width: characters?.width ?? (isCompressed ? 1 : 2)
            )
            guard document.contains(offset: offset, length: piece.length * piece.width) else {
                throw OLEDamage(reason: "piece \(index) holds \(piece.length) characters that run past the stream")
            }
            pieces.append(piece)
            previousEnd = end
        }
        self.pieces = pieces
        legacyCharacters = characters
        (piecesByFile, largestFileEnd) = Self.fileOrder(of: pieces)
    }

    /// A Word 6 or Word 95 document saved in full (no Fast Save): its text
    /// is one piece, the bytes of the stream from `bytes`.
    /// - Throws: `OLEDamage` when the characters run past the stream.
    init(contiguous bytes: Range<Int>, document: OLEBytes, characters: WordLegacyCharacters) throws {
        let count = bytes.count / characters.width
        legacyCharacters = characters
        guard count > 0 else {
            pieces = []
            (piecesByFile, largestFileEnd) = ([], [])
            return
        }
        guard document.contains(offset: bytes.lowerBound, length: count * characters.width) else {
            throw OLEDamage(reason: "the text runs past the stream")
        }
        pieces = [Piece(
            firstCharacter: 0, endCharacter: count, fileOffset: bytes.lowerBound, isCompressed: false,
            modifiers: [], width: characters.width
        )]
        (piecesByFile, largestFileEnd) = Self.fileOrder(of: pieces)
    }

    /// The pieces that hold characters in file order, and for each the
    /// largest end offset of it and of those before it.
    private static func fileOrder(of pieces: [Piece]) -> (pieces: [Piece], largestFileEnd: [Int]) {
        let byFile = pieces.filter { $0.length > 0 }.sortedStably { $0.fileOffset < $1.fileOffset }
        var largest = 0
        let ends = byFile.map { piece -> Int in
            largest = max(largest, piece.fileEnd)
            return largest
        }
        return (byFile, ends)
    }

    // MARK: Reading the Text

    /// Calls `body` with the character position and the UTF-16 code unit of
    /// each character from position `start` up to (not including) `limit`,
    /// in order. Windows-1252 characters are turned into their Unicode code
    /// unit as they are read. The first piece it reads is found by halving
    /// the pieces (their ends never go back), so a caller that reads many
    /// short ranges of a document of many pieces does not walk the pieces
    /// before each.
    /// - Parameters:
    ///   - document: the stream the table was checked against; the
    ///     reads here stay inside the ranges that check passed.
    ///   - codePages: for a Word 6 or Word 95 document of one-byte characters, the code page of
    ///     each stretch of its text; without it the document's own decodes all.
    func forEachCharacter(
        from start: Int = 0, upTo limit: Int, in document: OLEBytes, codePages: WordLegacyCodePages? = nil,
        _ body: (_ position: Int, _ unit: UInt16) throws -> Void
    ) rethrows {
        let bytes = document.bytes
        // The code page of each stretch, for a document of one-byte characters that has them.
        var codeCursor = codePages?.cursor()
        for index in indexOfFirstPiece(endingAfter: start)..<pieces.count {
            let piece = pieces[index]
            guard piece.firstCharacter < limit else { return }
            guard piece.endCharacter > start else { continue }
            let end = min(piece.endCharacter, limit)
            var position = max(piece.firstCharacter, start)
            if let characters = legacyCharacters {
                // A Word 6 or Word 95 character: a byte, or a 16-bit unit
                // that holds a byte, a pair, or (a pair that is none) two bytes.
                var decoded: [UInt16: WordLegacyCharacters.Decoded] = [:]
                while position < end {
                    let at = piece.fileOffset + (position - piece.firstCharacter) * piece.width
                    if piece.width == 1 {
                        if codeCursor != nil {
                            try body(position, codeCursor!.table(at: position)[Int(bytes[at])])
                        } else {
                            try body(position, characters.unit(ofByte: bytes[at]))
                        }
                    } else {
                        let stored = characters.characters(ofStored: UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8, cache: &decoded)
                        try body(position, stored.first)
                        if let second = stored.second { try body(position, second) }
                    }
                    position += 1
                }
            } else if piece.isCompressed {
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

    /// The index of the first piece (in character order) that ends after character position `start`,
    /// found by halving: the pieces' ends never go back.
    private func indexOfFirstPiece(endingAfter start: Int) -> Int {
        var low = 0
        var high = pieces.count
        while low < high {
            let middle = (low + high) / 2
            if pieces[middle].endCharacter > start { high = middle } else { low = middle + 1 }
        }
        return low
    }

    /// How many bytes above 0x7F the characters at `range` hold, in a Word 6 or Word 95 document of
    /// one-byte characters (0 for any other): the weight a code page is chosen by.
    func countBytesAbove7F(in range: Range<Int>, document: OLEBytes) -> Int {
        guard legacyCharacters?.width == 1 else { return 0 }
        let bytes = document.bytes
        var count = 0
        for index in indexOfFirstPiece(endingAfter: range.lowerBound)..<pieces.count {
            let piece = pieces[index]
            guard piece.firstCharacter < range.upperBound else { break }
            let first = max(piece.firstCharacter, range.lowerBound)
            let end = min(piece.endCharacter, range.upperBound)
            guard first < end else { continue }
            let from = piece.fileOffset + (first - piece.firstCharacter)
            for at in from..<from + (end - first) where bytes[at] > 0x7F { count += 1 }
        }
        return count
    }

    /// Some characters and the property modifiers of the piece that holds them.
    struct Placed {
        /// The character positions.
        let range: Range<Int>
        /// The piece's modifiers, as `Piece.modifiers`.
        let modifiers: ArraySlice<UInt8>
    }

    /// The character positions that the bytes `fileStart..<fileEnd` of the
    /// stream hold, as one range for each piece they cross, in file order,
    /// each with its piece's property modifiers.
    /// - Parameter budget: how many pieces the caller will still look at in
    ///   all its calls; each piece looked at costs one. Pieces that overlap in
    ///   the file could otherwise make every call cross every piece.
    /// - Throws: `OLEDamage` when the budget is spent.
    func characterRanges(fileStart: Int, fileEnd: Int, budget: inout Int) throws -> [Placed] {
        guard fileStart < fileEnd else { return [] }
        // The first piece in file order that ends after fileStart, by halving.
        var low = 0
        var high = piecesByFile.count
        while low < high {
            let middle = (low + high) / 2
            if largestFileEnd[middle] > fileStart { high = middle } else { low = middle + 1 }
        }
        var ranges: [Placed] = []
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
                ranges.append(Placed(range: first..<min(after, piece.endCharacter), modifiers: piece.modifiers))
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
