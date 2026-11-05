import Foundation

// MARK: - The File Information Block

/// The File Information Block (FIB) at the start of a Word 97-2003
/// document's `WordDocument` stream ([MS-DOC] 2.5.1): the version, the flags,
/// the length of the main text, and a table of (offset, length) pairs that
/// say where each structure lives in the table stream (`0Table` or
/// `1Table`).
///
/// Written from [MS-DOC]; word-extractor (MIT) and Apache POI's HWPF
/// (Apache 2.0) were read as maps of the layout, never copied.
struct WordFileInformationBlock {

    // MARK: Constants

    /// The `wIdent` of every Word 97 and later document.
    private static let identifier = 0xA5EC
    /// The `wIdent` of a Word 6 document.
    private static let word6Identifier = 0xA5DC
    /// The oldest `nFib` of Word 97 (0x00C1); older files are Word 6 and
    /// Word 95, which this reader leaves alone.
    private static let firstWord97Version = 0x00C1
    /// The newest `nFib` any Word version has written (Word 2007's is 0x0112).
    private static let lastKnownVersion = 0x0200

    /// The structures of the table stream this reader uses, each named by
    /// its place among the (offset, length) pairs of the FibRgFcLcb
    /// ([MS-DOC] 2.5.4).
    enum Structure: Int {
        /// The style sheet (STSH).
        case styleSheet = 1
        /// The section table (PlcfSed).
        case sectionTable = 6
        /// The character property bin table (PlcfBteChpx).
        case characterBinTable = 12
        /// The paragraph property bin table (PlcfBtePapx).
        case paragraphBinTable = 13
        /// The complex file information (CLX), which holds the piece table.
        case complexInformation = 33
    }

    // MARK: Fields

    /// `nFib`: the version of the file format.
    let version: Int
    /// The flags word of the FIB's base ([MS-DOC] 2.5.2).
    let flags: Int
    /// `ccpText`: how many characters the main document holds.
    let mainTextLength: Int
    /// Where the pairs begin in the `WordDocument` stream.
    private let pairsOffset: Int
    /// How many pairs the FIB holds.
    private let pairCount: Int
    /// The `WordDocument` stream, for reading the pairs.
    private let stream: OLEBytes

    /// Whether the document is encrypted (`fEncrypted`).
    var isEncrypted: Bool { flags & 0x0100 != 0 }
    /// Whether the table stream is `1Table` (`fWhichTblStm`), or `0Table`.
    var usesOneTable: Bool { flags & 0x0200 != 0 }
    /// The name of the table stream.
    var tableStreamName: String { usesOneTable ? "1Table" : "0Table" }

    // MARK: Reading

    /// The FIB at the start of `stream`, or nil for a Word 6 or Word 95
    /// document, whose older layout this reader does not read.
    /// - Throws: `OLEDamage` when the stream does not begin as a FIB or the
    ///   FIB does not fit it.
    static func read(from stream: OLEBytes) throws -> WordFileInformationBlock? {
        let ident = try stream.u16(0)
        guard ident == identifier || ident == word6Identifier else { throw OLEDamage(reason: "the WordDocument stream is not a FIB") }
        let version = try stream.u16(2)
        if ident == word6Identifier || version < firstWord97Version { return nil }
        guard version <= lastKnownVersion else { throw OLEDamage(reason: "nFib \(version) is not a Word version") }

        // FibBase is 32 bytes; csw (the count of 16-bit values) follows it,
        // then the 16-bit values, then cslw (the count of 32-bit values),
        // the 32-bit values, cbRgFcLcb, and the pairs.
        let flags = try stream.u16(10)
        let shortValues = try stream.u16(32)
        let longCountOffset = 34 + shortValues * 2
        let longValues = try stream.u16(longCountOffset)
        let longStart = longCountOffset + 2
        // ccpText is the fourth 32-bit value (cbMac, two reserved, ccpText).
        guard longValues >= 4 else { throw OLEDamage(reason: "the FIB holds too few lengths") }
        let textLength = try stream.u32(longStart + 12)
        let pairCountOffset = longStart + longValues * 4
        let pairCount = try stream.u16(pairCountOffset)
        let pairsOffset = pairCountOffset + 2
        guard stream.contains(offset: pairsOffset, length: pairCount * 8) else {
            throw OLEDamage(reason: "the FIB's offsets run past the stream")
        }
        // The CLX is the last structure this reader needs.
        guard pairCount > Structure.complexInformation.rawValue else { throw OLEDamage(reason: "the FIB has no CLX") }
        return WordFileInformationBlock(
            version: version, flags: flags, mainTextLength: textLength,
            pairsOffset: pairsOffset, pairCount: pairCount, stream: stream
        )
    }

    /// Where `structure` lies in `table`: its offset and length, checked
    /// against the stream; nil when the document has none (a length of zero).
    /// - Throws: `OLEDamage` when the structure runs past the end of `table`.
    func range(of structure: Structure, in table: OLEBytes) throws -> Range<Int>? {
        let offset = try stream.u32(pairsOffset + structure.rawValue * 8)
        let length = try stream.u32(pairsOffset + structure.rawValue * 8 + 4)
        guard length > 0 else { return nil }
        guard table.contains(offset: offset, length: length) else {
            throw OLEDamage(reason: "a structure at \(offset) of \(length) bytes runs past the table stream")
        }
        return offset..<offset + length
    }
}

// MARK: - Property Modifiers

/// A list of single property modifiers (sprms, [MS-DOC] 2.6) as paragraph,
/// character, and section properties are stored: an opcode of 16 bits, then
/// an operand whose size the opcode's top three bits (`spra`) give.
enum WordSprm {

    // MARK: Opcodes

    /// The paragraph style (`sprmPIstd`).
    static let paragraphStyle = 0x4600
    /// The paragraph starts a page (`sprmPFPageBreakBefore`).
    static let pageBreakBefore = 0x2407
    /// The paragraph is in a table (`sprmPFInTable`).
    static let inTable = 0x2416
    /// The paragraph ends a row of a table (`sprmPFTtp`).
    static let rowEnd = 0x2417
    /// The paragraph's outline level, 0 to 8, or 9 for body text (`sprmPOutLvl`).
    static let outlineLevel = 0x2640
    /// The depth of the table the paragraph is in (`sprmPItap`).
    static let tableDepth = 0x6649
    /// Bold (`sprmCFBold`).
    static let bold = 0x0835
    /// Italic (`sprmCFItalic`).
    static let italic = 0x0836
    /// The character style (`sprmCIstd`).
    static let characterStyle = 0x4A30
    /// The character is a special character, such as a picture's anchor (`sprmCFSpec`).
    static let special = 0x0855
    /// How a section begins (`sprmSBkc`).
    static let sectionBreakKind = 0x3009

    // MARK: Walking

    /// Calls `body` with the opcode and operand of each sprm in `grpprl`, in
    /// order. A sprm whose operand runs past the end of `grpprl` ends the
    /// walk: a property list is only a list of hints about the text, and no
    /// offset in it reaches anything but itself, so damage here costs
    /// formatting and never safety. A single trailing byte, the padding Word
    /// leaves, is not a sprm.
    static func forEach(in grpprl: ArraySlice<UInt8>, _ body: (_ opcode: Int, _ operand: ArraySlice<UInt8>) -> Void) {
        var position = grpprl.startIndex
        // Bounded by the list: every sprm takes at least two bytes.
        while grpprl.endIndex - position >= 2 {
            let opcode = Int(grpprl[position]) | Int(grpprl[position + 1]) << 8
            let operandStart = position + 2
            guard let size = operandSize(opcode: opcode, in: grpprl, at: operandStart),
                  size <= grpprl.endIndex - operandStart else { return }
            body(opcode, grpprl[operandStart..<operandStart + size])
            position = operandStart + size
        }
    }

    /// The size in bytes of the operand of the sprm `opcode` whose operand
    /// begins at `start` in `grpprl`, or nil when the size cannot be told.
    private static func operandSize(opcode: Int, in grpprl: ArraySlice<UInt8>, at start: Int) -> Int? {
        switch opcode >> 13 {
        case 0, 1: return 1
        case 2, 4, 5: return 2
        case 3: return 4
        case 7: return 3
        default:
            // spra 6: an operand that begins with its own size.
            guard start < grpprl.endIndex else { return nil }
            if opcode == 0xD608 {
                // sprmTDefTable: a 16-bit size that is the operand's size less one.
                guard start + 1 < grpprl.endIndex else { return nil }
                return (Int(grpprl[start]) | Int(grpprl[start + 1]) << 8) + 1
            }
            let size = Int(grpprl[start])
            // sprmPChgTabs writes 255 to say the size is computed from its
            // contents; it is the one such sprm, and not read here.
            if size == 255 && opcode == 0xC615 { return nil }
            return size + 1
        }
    }
}
