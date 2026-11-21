import Foundation

// MARK: - Word 6 and Word 95 Property Modifiers

/// The property modifiers (sprms) of a Word 6 or Word 95 document: an opcode
/// of one byte, then an operand whose size the opcode alone gives (there are
/// no `spra` bits as in Word 97), so a table of sizes is how a list of
/// modifiers is walked. A wrong size would misread everything after it, so
/// the table holds only sprms whose size is established, and a modifier the
/// table does not hold ends the walk of its list: a list is only a set of
/// hints about the text, and no offset in it reaches anything but itself, so
/// a list cut short costs formatting and never safety.
///
/// How far each size is trusted. No published description of the Word 6
/// format is available, so the table was found by reading real files:
/// - **Walked to the exact end.** The review of this reader (November 6,
///   2026) walked every paragraph list and every character list of 333 real
///   Word 6 and Word 95 documents (312 US government files, Apache POI's and
///   LibreOffice's samples) with these sizes, 12,287 character lists among
///   them, and each ended exactly at the end of its list (but for the zero
///   byte of padding Word leaves after a list). A size that were wrong would
///   put the next opcode in the wrong place, and an unknown opcode would end
///   the walk early: neither happened. This holds for every sprm the files
///   use (the opcodes seen are the ones listed below as the common ones).
/// - **By order.** For the few the files never use, the size follows the
///   order Word 97 kept: a paragraph sprm of Word 97 with the low byte `b`
///   is Word 6's number `b + 2`, a character sprm of the group 0x0800 is
///   `b + 65`, and of 0x0835 and after `b + 32`, with the operand sizes the
///   later ones have. Microsoft's [MS-DOC] 2.9.215 (`Prm0`) numbers the sprms
///   that fit a one-byte operand with the same numbers for most of these, but
///   not for 12, 15, 80, and 81, where it numbers Word 97's own additions into
///   Word 6's retired places; it is evidence for the others only.
/// - A size byte first, for the sprms whose operand varies (`sizedBySizeByte`);
///   a 16-bit size for `sprmTDefTable` (190).
///
/// An opcode that was once taken for a one-byte operand and was not: the size
/// of the font size (99) is two bytes (`63 18 00 56 01` is a size, then italic),
/// and a picture's place (68) and a symbol (74) have a size byte first.
///
/// The sprms the reader acts on are turned into their Word 97 form
/// (`translation`), so that the readers of properties, styles, and sections
/// are one for both formats.
enum WordLegacySprm {

    // MARK: Sizes

    /// The operand sizes of the sprms with a fixed one, by opcode.
    private static let fixedSizes: [Int: Int] = {
        var sizes: [Int: Int] = [:]
        /// Records that the sprms `opcodes` have operands of `size` bytes.
        func record(_ size: Int, _ opcodes: [Int]) { for opcode in opcodes { sizes[opcode] = size } }
        // Paragraph. The style, indents, spacing, borders, and positions; flags.
        record(2, [2, 16, 17, 18, 19, 21, 22, 26, 27, 28, 30, 31, 32, 33, 34, 35, 36, 38, 39, 40, 41, 42, 43, 45, 46, 47, 48, 49, 59, 60])
        record(1, [4, 5, 6, 7, 8, 9, 10, 11, 13, 14, 24, 25, 29, 37, 44, 50, 51, 53, 54, 55, 56, 57, 58, 61])
        record(4, [20])
        // Character. Revision marks and field codes, the character set, emphasis, the font and size, the
        // special mark and object, and the fonts of other scripts.
        record(1, [65, 66, 67, 71, 75, 85, 86, 87, 88, 89, 90, 91, 92, 94, 98, 100, 102, 104, 117, 118, 119])
        record(2, [69, 72, 77, 80, 93, 96, 97, 99, 101, 107, 109, 110, 111, 112, 113, 121, 122, 123, 124])
        record(3, [73, 95])
        record(4, [70])
        // Section. One byte or two (the page size and margins, 164 to 171, are two).
        record(1, [132, 142, 143, 146, 147, 150, 151, 152, 153, 158, 159, 162, 163])
        record(2, [131, 140, 141, 144, 145, 148, 149, 154, 155, 156, 157, 160, 161, 164, 165, 166, 167, 168, 169, 170, 171])
        record(3, [136, 137])
        record(1, [138, 139])
        // Table.
        record(2, [182, 183, 184, 189, 195, 197, 198])
        record(1, [185, 186])
        record(12, [187])
        record(4, [192, 194, 196, 200])
        record(5, [193, 199])
        return sizes
    }()

    /// The sprms whose operand begins with its own size (a byte, the number of
    /// bytes after it): the style permutation (3), the paragraph's numbering
    /// (12, an ANLD of 52 bytes), the tab stops (15 for a paragraph's own, 23
    /// for a change of them), a picture's place (68), a symbol (74, a font and
    /// a character), and the other lists of values.
    private static let sizedBySizeByte: Set<Int> = [3, 12, 15, 23, 68, 74, 81, 103, 105, 106, 108, 120, 133, 188, 191]

    /// `sprmTDefTable`, whose operand begins with a 16-bit size (as Word 97's does).
    private static let sizedBySixteenBits = 190

    /// The size of the operand of the sprm `opcode` that begins at `start` in
    /// `grpprl`, or nil when it cannot be told: an opcode outside the table,
    /// or a size past the end.
    private static func operandSize(opcode: Int, in grpprl: ArraySlice<UInt8>, at start: Int) -> Int? {
        if let size = fixedSizes[opcode] { return size }
        if opcode == sizedBySixteenBits {
            guard start + 1 < grpprl.endIndex else { return nil }
            return (Int(grpprl[start]) | Int(grpprl[start + 1]) << 8) + 1
        }
        guard sizedBySizeByte.contains(opcode), start < grpprl.endIndex else { return nil }
        let declared = Int(grpprl[start])
        // 255 says the size is worked out from the contents, which is not read here.
        return declared == 255 ? nil : declared + 1
    }

    // MARK: Translation

    /// How a legacy operand is changed into the Word 97 operand of the same meaning.
    private enum Operand {
        /// Kept as it is.
        case same
        /// A symbol: a size byte, a 16-bit font, and a one-byte character become Word 97's 16-bit font and
        /// 16-bit character.
        case symbol
    }

    /// What the reader acts on, in Word 97's terms: the opcode a legacy sprm
    /// becomes and how its operand changes. The pseudo-opcodes (`WordSprm.legacy…`) are
    /// ones Word 97 has no sprm for; they are sized by their `spra` bits as the Word 97 walker
    /// reads them, so a group of modifiers kept in this form (a piece's) can be read by that walker.
    private static let translation: [Int: (opcode: Int, operand: Operand)] = [
        2: (WordSprm.paragraphStyle, .same),
        4: (WordSprm.incrementLevel, .same),
        9: (WordSprm.pageBreakBefore, .same),
        12: (WordSprm.legacyNumbering, .same),
        13: (WordSprm.legacyNumberingLevel, .same),
        24: (WordSprm.inTable, .same),
        25: (WordSprm.rowEnd, .same),
        65: (WordSprm.deleted, .same),
        73: (WordSprm.legacyCharacterSet, .same),
        74: (WordSprm.symbol, .symbol),
        80: (WordSprm.characterStyle, .same),
        85: (WordSprm.bold, .same),
        86: (WordSprm.italic, .same),
        92: (WordSprm.hidden, .same),
        93: (WordSprm.legacyFont, .same),
        99: (WordSprm.fontSize, .same),
        117: (WordSprm.special, .same),
        142: (WordSprm.sectionBreakKind, .same),
    ]

    /// `grpprl` as a list of Word 97 sprms of the same meaning, for those
    /// the reader acts on; a piece's modifiers (`Prm1`) are kept in that form.
    static func modern(_ grpprl: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        var result: [UInt8] = []
        forEach(in: grpprl) { opcode, operand in
            result.append(UInt8(opcode & 0xFF))
            result.append(UInt8(opcode >> 8))
            result.append(contentsOf: operand)
        }
        return result[...]
    }

    // MARK: Walking

    /// Calls `body` with the Word 97 opcode and operand of each sprm of
    /// `grpprl` the reader acts on, in order. A sprm the table does not hold,
    /// or whose operand runs past the end, ends the walk (a lone zero byte,
    /// the padding Word leaves, is one such: no sprm has the opcode 0).
    static func forEach(in grpprl: ArraySlice<UInt8>, _ body: (_ opcode: Int, _ operand: ArraySlice<UInt8>) -> Void) {
        var position = grpprl.startIndex
        while position < grpprl.endIndex {
            let opcode = Int(grpprl[position])
            let operandStart = position + 1
            guard let size = operandSize(opcode: opcode, in: grpprl, at: operandStart),
                  size <= grpprl.endIndex - operandStart else { return }
            if let translated = translation[opcode], size >= 1 {
                let operand = grpprl[operandStart..<operandStart + size]
                switch translated.operand {
                case .same:
                    body(translated.opcode, operand)
                case .symbol:
                    // [size = 3, font (2), character (1)] becomes [font (2), character (2)].
                    if size == 4 {
                        let start = operand.startIndex
                        body(translated.opcode, [operand[start + 1], operand[start + 2], operand[start + 3], 0][...])
                    }
                }
            }
            position = operandStart + size
        }
    }
}
