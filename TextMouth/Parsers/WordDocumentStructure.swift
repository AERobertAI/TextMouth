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
    /// Word 95, read by their own layout (`Layout.legacy`).
    private static let firstWord97Version = 0x00C1
    /// The `nFib` of Word 6 (0x0065); Word 95's is 0x0068. An older file is
    /// Word 5 or before, whose layout this reader does not know.
    private static let firstLegacyVersion = 0x0065
    /// The least a Word 6 or Word 95 FIB holds that this reader reads: it
    /// ends with the CLX's offset and size, at 0x160 and 0x164.
    private static let legacyLength = 0x168
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
        /// The font table (SttbfFfn), which names each font's character set;
        /// a Word 6 or Word 95 document's code page comes from it.
        case fontTable = 15
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

        /// Where the offset and size of this structure lie in the FIB of a
        /// Word 6 or Word 95 document, or nil for one those do not have
        /// (endnotes, text boxes, and the list tables of Word 97: the stories
        /// of the first two are read whole, in one range each). The
        /// structures are in the `WordDocument` stream itself. Every offset here
        /// was found by reading real files; the footnote tables fit in all 26
        /// real documents that have footnotes (the sizes of the tables, the marks
        /// in the main text, and the ends agreeing with `ccpFtn`).
        fileprivate var legacyOffset: Int? {
            switch self {
            case .styleSheet: return 0x60
            case .footnoteReferences: return 0x68
            case .footnoteText: return 0x70
            case .sectionTable: return 0x88
            case .characterBinTable: return 0xB8
            case .paragraphBinTable: return 0xC0
            case .fontTable: return 0xD0
            case .complexInformation: return 0x160
            default: return nil
            }
        }
    }

    /// Which layout the FIB and the structures it names have.
    enum Layout {
        /// Word 97 and later: the structures are in the `0Table` or `1Table` stream.
        case modern
        /// Word 6 and Word 95: the structures are in the `WordDocument` stream.
        case legacy
    }

    // MARK: Fields

    /// `nFib`: the version of the file format.
    let version: Int
    /// The flags word of the FIB's base ([MS-DOC] 2.5.2).
    let flags: Int
    /// `ccpText`: how many characters the main document holds.
    let mainTextLength: Int
    /// The layout of the document: Word 97's, or Word 6's and Word 95's.
    let layout: Layout
    /// For a Word 6 or Word 95 document, the offsets of the first and of the
    /// last character of the text in the `WordDocument` stream (`fcMin` and
    /// `fcMac`), which hold the text of a document saved in full; and the
    /// language (`lid`) and the character set (`chs`) of the document.
    let legacyText: Range<Int>
    let languageIdentifier: Int
    let characterSet: Int
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
    /// Whether a Word 6 or Word 95 document is saved with its text in the
    /// piece table of a CLX (`fComplex`), as Fast Save leaves it, and not
    /// whole from `legacyText`'s start.
    var hasPieceTable: Bool { flags & 0x0004 != 0 }
    /// Whether the characters of a Word 6 or Word 95 document are two bytes
    /// each (`fExtChar`): the files of Far East editions, and of Word 95
    /// for them, store the 8-bit text of a code page as 16-bit units.
    var hasTwoByteCharacters: Bool { flags & 0x1000 != 0 }
    /// Whether the table stream is `1Table` (`fWhichTblStm`), or `0Table`.
    var usesOneTable: Bool { flags & 0x0200 != 0 }
    /// For a Word 6 or Word 95 document, how many formatted disk pages of the bin table `structure` the file
    /// holds (`cpnBteChp` at 0x18E, `cpnBtePap` at 0x190), or 0 for any other structure or document or a FIB too
    /// short to say. The table itself may list fewer, and the rest follow the last listed.
    func declaredPageCount(of structure: Structure) -> Int {
        guard layout == .legacy, stream.count >= 0x192 else { return 0 }
        switch structure {
        case .characterBinTable: return (try? stream.u16(0x18E)) ?? 0
        case .paragraphBinTable: return (try? stream.u16(0x190)) ?? 0
        default: return 0
        }
    }

    /// The name of the table stream.
    var tableStreamName: String { usesOneTable ? "1Table" : "0Table" }

    // MARK: Reading

    /// The FIB at the start of `stream`, or nil for a document older than
    /// Word 6, whose layout this reader does not know.
    /// - Throws: `OLEDamage` when the stream does not begin as a FIB or the
    ///   FIB does not fit it.
    static func read(from stream: OLEBytes) throws -> WordFileInformationBlock? {
        let ident = try stream.u16(0)
        let version = try stream.u16(2)
        // A file whose identifier is Word 97's (0xA5EC, which [MS-DOC] says every Word 97 and later
        // FIB has) is read by that layout whatever its version: Word installs a special empty
        // document with an `nFib` of 0x00C0. Any other identifier with the version of Word 6 or 95 or
        // older (Word 6's own is 0xA5DC, and some Word for Windows and Macintosh files have 0xA697 to
        // 0xA699) has the older layout; any other is not a FIB.
        if ident != identifier {
            guard ident == word6Identifier || version < firstWord97Version else {
                throw OLEDamage(reason: "the WordDocument stream is not a FIB")
            }
            // Word 5 and older keep to textutil; Word 6 and Word 95 are read here.
            guard version >= firstLegacyVersion, version < firstWord97Version else { return nil }
            return try readLegacy(from: stream, version: version)
        }
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
            layout: .modern, legacyText: 0..<0, languageIdentifier: 0, characterSet: 0,
            longValuesOffset: longStart, longValueCount: longValues,
            pairsOffset: pairsOffset, pairCount: pairCount, stream: stream
        )
    }

    /// The FIB of a Word 6 or Word 95 document ([MS-DOC] does not describe
    /// it; the offsets were found by reading real files): the flags at 10,
    /// the language at 6, the character set at 0x14, the first and the end of
    /// the text at 0x18 and 0x1C, the lengths of the stories from 0x34 (the
    /// main text's first, in the same order as Word 97's), and the offsets and
    /// sizes of the structures from 0x58, each four bytes.
    private static func readLegacy(from stream: OLEBytes, version: Int) throws -> WordFileInformationBlock {
        guard stream.count >= legacyLength else { throw OLEDamage(reason: "the FIB is cut short") }
        let first = try stream.u32(0x18)
        let end = try stream.u32(0x1C)
        // The text of a document saved in full lies between these two offsets, in the stream.
        guard first <= end, end <= stream.count else { throw OLEDamage(reason: "the text runs past the stream") }
        return WordFileInformationBlock(
            version: version, flags: try stream.u16(10), mainTextLength: try stream.u32(0x34),
            layout: .legacy, legacyText: first..<end, languageIdentifier: try stream.u16(6),
            characterSet: try stream.u16(0x14),
            // The story lengths are the Word 97 order from ccpText (the fourth value) on.
            longValuesOffset: 0x28, longValueCount: 11, pairsOffset: 0, pairCount: 0, stream: stream
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
        // Where the pair of the structure lies in the FIB. A Word 97 FIB with
        // fewer pairs than the structure's place has none of it; a Word 6 or
        // Word 95 FIB has the few it names (`Structure.legacyOffset`).
        let pairOffset: Int
        switch layout {
        case .modern:
            guard structure.rawValue < pairCount else { return nil }
            pairOffset = pairsOffset + structure.rawValue * 8
        case .legacy:
            guard let offset = structure.legacyOffset else { return nil }
            pairOffset = offset
        }
        let offset = try stream.u32(pairOffset)
        let length = try stream.u32(pairOffset + 4)
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
    /// A Word 97 run's font for the ASCII range (`sprmCRgFtc0`, an index into the font table). The real
    /// documents' runs of Word 97 text typed in a symbol font (U+F020 to U+F0FF) have this and `sprmCRgFtc2` (the
    /// font for other characters) the same font, always; this one decides.
    static let fontAscii = 0x4A4F
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
    /// The symbol a run holds (`sprmCSymbol`): a 16-bit font (an index into the font
    /// table) and a 16-bit character ([MS-DOC] 2.6.1; a character in 0xF000 to 0xF0FF is its low byte).
    static let symbol = 0x6A09
    /// Opcodes that only a Word 6 or Word 95 document makes (`WordLegacySprm`), outside the
    /// ones Word 97 has. Their top bits (`spra`) give the operand sizes the Word 97 walker reads
    /// them by, so a group of modifiers kept in this form (a piece's) is read by either walker:
    /// - the paragraph's numbering (`sprmPAnld`; a size byte, then the 52 bytes of an `ANLD`) and
    ///   its level in the numbering (`sprmPNLvlAnm`);
    /// - the run's font (`sprmCFtc`, an index into the font table) and its character set
    ///   (`sprmCChse`: a flag that says it differs, and 16 bits, 256 for the Macintosh's).
    static let legacyNumbering = 0xC0F0
    static let legacyNumberingLevel = 0x24F1
    static let legacyFont = 0x4AF2
    static let legacyCharacterSet = 0xE0F3

    // MARK: Operands

    /// The little-endian number in the first (up to four) bytes of `operand`.
    static func value(of operand: ArraySlice<UInt8>) -> Int {
        operand.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
    }

    // MARK: Walking

    /// Which format's property modifiers a list holds.
    enum Dialect {
        /// Word 97 and later: two-byte opcodes whose top bits give the operand's size.
        case modern
        /// Word 6 and Word 95: one-byte opcodes, sizes from a table (`WordLegacySprm`).
        case legacy
    }

    /// Calls `body` with the opcode and operand of each sprm in `grpprl`, in
    /// order. A sprm whose operand runs past the end of `grpprl` ends the
    /// walk: a property list is only a list of hints about the text, and no
    /// offset in it reaches anything but itself, so damage here costs
    /// formatting and never safety. A single trailing byte, the padding Word
    /// leaves, is not a sprm.
    static func forEach(in grpprl: ArraySlice<UInt8>, dialect: Dialect = .modern, _ body: (_ opcode: Int, _ operand: ArraySlice<UInt8>) -> Void) {
        // A Word 6 or Word 95 list is walked by its own table, which hands
        // the body the Word 97 form of each sprm the reader acts on.
        if dialect == .legacy { return WordLegacySprm.forEach(in: grpprl, body) }
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
