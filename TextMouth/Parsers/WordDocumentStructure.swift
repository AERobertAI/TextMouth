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
        /// Where the footnotes' reference marks lie in the main text (PlcffndRef).
        case footnoteReferences = 2
        /// Where each footnote's text lies in the footnote story (PlcffndTxt).
        case footnoteText = 3
        /// Where the endnotes' reference marks lie in the main text (PlcfendRef).
        case endnoteReferences = 46
        /// Where each endnote's text lies in the endnote story (PlcfendTxt).
        case endnoteText = 47
        /// Where each text box's text lies in the text box story (PlcftxbxTxt).
        case textBoxText = 56
        /// The list table (PlfLst): the lists and their levels.
        case listFormats = 73
        /// The list override table (PlfLfo): the list instances paragraphs name.
        case listOverrides = 74
    }

    // MARK: Fields

    /// `nFib`: the version of the file format.
    let version: Int
    /// The flags word of the FIB's base ([MS-DOC] 2.5.2).
    let flags: Int
    /// `ccpText`: how many characters the main document holds.
    let mainTextLength: Int
    /// Where the FIB's 32-bit values begin, and how many there are.
    private let longValuesOffset: Int
    private let longValueCount: Int
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
        let version = try stream.u16(2)
        // A file with another identifier and the version of Word 6 or 95 or older
        // (some Word for Windows and Macintosh files have 0xA699) has their layout,
        // which this reader leaves to textutil; any other is not a FIB.
        guard ident == identifier || ident == word6Identifier || version < firstWord97Version else {
            throw OLEDamage(reason: "the WordDocument stream is not a FIB")
        }
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
            longValuesOffset: longStart, longValueCount: longValues,
            pairsOffset: pairsOffset, pairCount: pairCount, stream: stream
        )
    }

    /// The stories of a document after its main text, as character positions.
    /// They are laid end to end after it, in the order of these fields; each
    /// is cut at the characters the document holds, and one that is empty,
    /// or that a FIB too short to give its length leaves out, is an empty range.
    struct Stories {
        var footnotes = 0..<0
        var headers = 0..<0
        var macros = 0..<0
        var comments = 0..<0
        var endnotes = 0..<0
        var textBoxes = 0..<0
        var headerTextBoxes = 0..<0

        /// The ones that hold characters, in the order the file keeps them.
        var inFileOrder: [Range<Int>] {
            [footnotes, headers, macros, comments, endnotes, textBoxes, headerTextBoxes].filter { !$0.isEmpty }
        }
    }

    /// The stories after the main text (`ccpFtn` to `ccpHdrTxbx`), cut at
    /// `limit`. A person reading the document sees the footnotes, the
    /// endnotes, and the main document's text boxes; the headers, the
    /// comments, and the header text boxes are page furniture or notes to the
    /// author and are read only when nothing else holds words.
    func stories(limit: Int) throws -> Stories {
        var result = Stories()
        guard longValueCount >= 9 else { return result }
        // ccpFtn, ccpHdd, ccpMcr, ccpAtn, ccpEdn, ccpTxbx, ccpHdrTxbx follow ccpText, as many as the FIB holds.
        let lengths = try (4...10).map { index -> Int in
            index < longValueCount ? try stream.u32(longValuesOffset + index * 4) : 0
        }
        var start = mainTextLength
        func take(_ length: Int) -> Range<Int> {
            defer { start += length }
            // A story that begins past the characters the document holds has none.
            guard start < limit else { return 0..<0 }
            return start..<min(start + length, limit)
        }
        result.footnotes = take(lengths[0])
        result.headers = take(lengths[1])
        result.macros = take(lengths[2])
        result.comments = take(lengths[3])
        result.endnotes = take(lengths[4])
        result.textBoxes = take(lengths[5])
        result.headerTextBoxes = take(lengths[6])
        return result
    }

    /// Where `structure` lies in `table`: its offset and length, checked
    /// against the stream; nil when the document has none (a length of zero).
    /// - Throws: `OLEDamage` when the structure runs past the end of `table`.
    func range(of structure: Structure, in table: OLEBytes) throws -> Range<Int>? {
        // A FIB with fewer pairs than the structure's place has none of it.
        guard structure.rawValue < pairCount else { return nil }
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
    /// The paragraph's style is moved up or down the Heading 1 to 9 styles
    /// by a signed 8-bit number (`sprmPIncLvl`).
    static let incrementLevel = 0x2602
    /// The paragraph's properties are in the Data stream, at the 32-bit
    /// offset the operand gives (`sprmPHugePapx`), and `sprmPTableProps`
    /// is the same for a table's.
    static let hugeParagraphProperties = 0x6646
    static let tableProperties = 0x646B
    /// The paragraph is the last of a nested table's row (`sprmPFInnerTtp`).
    static let innerRowEnd = 0x244C
    /// The paragraph's level in its list, 0 to 8 (`sprmPIlvl`).
    static let listLevel = 0x260A
    /// The list instance the paragraph is in, one-based (`sprmPIlfo`).
    static let listIndex = 0x460B
    /// The paragraph's outline level, 0 to 8, or 9 for body text (`sprmPOutLvl`).
    static let outlineLevel = 0x2640
    /// The depth of the table the paragraph is in (`sprmPItap`).
    static let tableDepth = 0x6649
    /// Bold (`sprmCFBold`).
    static let bold = 0x0835
    /// Italic (`sprmCFItalic`).
    static let italic = 0x0836
    /// Hidden text (`sprmCFVanish`), a toggle property like bold and italic.
    /// Text hidden only on the web (`sprmCFWebHidden`, 0x0811) and a hidden
    /// paragraph mark alone (`sprmCFSpecVanish`, 0x0818) are not read as
    /// hidden, so neither has a name here.
    static let hidden = 0x083C
    /// The text is a tracked deletion (`sprmCFRMarkDel`).
    static let deleted = 0x0800
    /// The font size in half-points (`sprmCHps`).
    static let fontSize = 0x4A43
    /// The character style (`sprmCIstd`); it takes its properties from the
    /// style, so the direct ones before it do not stay.
    static let characterStyle = 0x4A30
    /// The characters have no direct formatting and no character style (`sprmCPlain`).
    static let plain = 0x2A33
    /// The paragraph mark (or a line break) is a style separator, hidden so
    /// that a run-in heading's paragraph and the next read as one (`sprmCFSpecVanish`).
    static let styleSeparator = 0x0818
    /// The character is a special character, such as a picture's anchor (`sprmCFSpec`).
    static let special = 0x0855
    /// How a section begins (`sprmSBkc`).
    static let sectionBreakKind = 0x3009

    // MARK: Operands

    /// The little-endian number in the first (up to four) bytes of `operand`.
    static func value(of operand: ArraySlice<UInt8>) -> Int {
        operand.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
    }

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
