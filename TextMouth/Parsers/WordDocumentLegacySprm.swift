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
/// How far each size is trusted:
/// - **Specification.** Microsoft's [MS-DOC] 2.9.215 (`Prm0`) lists the sprms
///   of Word 97 that keep their Word 6 numbers, each with an operand of one
///   byte: the paragraph flags (5, 7, 8, 9, 12 to 15, 24, 25, 29, 37, 44, 50,
///   51, 53 to 58), the character flags (65 to 67, 71, 75, 85 to 92, 94, 98,
///   104, 117, 118). No published description of the Word 6 format is
///   available; these are the numbers the later specification carries.
/// - **Real files.** Every sprm of the real Word 6 and Word 95 documents in
///   the test samples was walked to the exact end of its list; the sizes
///   confirmed that way are marked below.
/// - **Recollection, unconfirmed by a sample.** The rest follow the order of
///   Word 97's sprms, whose operand sizes they share (indents and spacing
///   are two bytes, line spacing four). They are marked below too.
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
        // Paragraph. One byte (specification): flags and the like.
        record(1, [4, 5, 7, 8, 9, 12, 13, 14, 15, 24, 25, 29, 37, 44, 50, 51, 53, 54, 55, 56, 57, 58])
        // One byte (recollection): side by side, borders' line style, and position.
        record(1, [6, 10, 11])
        // Two bytes, confirmed by real files: the left indent, the first line's indent, a top and a bottom border.
        record(2, [17, 19, 38, 40])
        // Two bytes (recollection): the style, the other indents, spacing, positions, and borders.
        record(2, [2, 16, 18, 21, 22, 26, 27, 28, 30, 31, 32, 33, 34, 35, 36, 39, 41, 42, 43, 45, 46, 47, 48, 49])
        // The line spacing: a distance and a rule (recollection).
        record(4, [20])
        // Character. One byte (specification): 65 to 67 deletion, insertion, and field codes; 71, 75; 85 to 92
        // bold to hidden; 94 underline; 98 colour; 104 super and subscript; 117 special; 118 object.
        record(1, [65, 66, 67, 71, 75, 85, 86, 87, 88, 89, 90, 91, 92, 94, 98, 104, 117, 118])
        // One byte, confirmed by real files: the size in half-points.
        record(1, [99])
        // One byte (recollection): the size's change, and the position's change.
        record(1, [100, 102])
        // Two bytes, confirmed by real files: the font, the language, and the fonts of other scripts.
        record(2, [93, 97, 111, 112])
        // Two bytes (recollection): the revision's author and reason, spacing, position, kerning, scale.
        record(2, [69, 72, 96, 101, 107, 109, 110, 113])
        // Three bytes (recollection): a character set, a symbol, a size and position.
        record(3, [73, 74, 95])
        // Four bytes, confirmed by real files: a picture's place (68); (recollection) a revision's date and an object's place.
        record(4, [68, 70, 119])
        // Section (recollection, except 142, 147, and 164 to 169, confirmed by real files): one byte or two.
        record(1, [142, 143, 146, 147, 150, 151, 152, 153, 158, 159, 162, 163])
        record(2, [144, 145, 148, 149, 154, 155, 156, 157, 160, 161, 164, 165, 166, 167, 168, 169, 170, 171, 172, 173])
        return sizes
    }()

    /// The sprms whose operand begins with its own size (a byte, the number of
    /// bytes after it): the style permutation, tab stops, and the like.
    private static let sizedBySizeByte: Set<Int> = [3, 23]

    /// The size of the operand of the sprm `opcode` that begins at `start` in
    /// `grpprl`, or nil when it cannot be told: an opcode outside the table,
    /// or a size byte past the end.
    private static func operandSize(opcode: Int, in grpprl: ArraySlice<UInt8>, at start: Int) -> Int? {
        if let size = fixedSizes[opcode] { return size }
        guard sizedBySizeByte.contains(opcode), start < grpprl.endIndex else { return nil }
        let declared = Int(grpprl[start])
        // 255 says the size is worked out from the contents, which is not read here.
        return declared == 255 ? nil : declared + 1
    }

    // MARK: Translation

    /// What the reader acts on, in Word 97's terms: the opcode a legacy sprm
    /// becomes, and whether its one-byte operand is widened to the two bytes
    /// the Word 97 sprm has.
    private static let translation: [Int: (opcode: Int, widens: Bool)] = [
        2: (WordSprm.paragraphStyle, false),
        4: (WordSprm.incrementLevel, false),
        9: (WordSprm.pageBreakBefore, false),
        24: (WordSprm.inTable, false),
        25: (WordSprm.rowEnd, false),
        65: (WordSprm.deleted, false),
        85: (WordSprm.bold, false),
        86: (WordSprm.italic, false),
        92: (WordSprm.hidden, false),
        99: (WordSprm.fontSize, true),
        117: (WordSprm.special, false),
        142: (WordSprm.sectionBreakKind, false),
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
    /// or whose operand runs past the end, ends the walk. A single trailing
    /// zero byte, the padding Word leaves, is not a sprm.
    static func forEach(in grpprl: ArraySlice<UInt8>, _ body: (_ opcode: Int, _ operand: ArraySlice<UInt8>) -> Void) {
        var position = grpprl.startIndex
        while position < grpprl.endIndex {
            // The padding: a zero that is the last byte.
            if position == grpprl.endIndex - 1, grpprl[position] == 0 { return }
            let opcode = Int(grpprl[position])
            let operandStart = position + 1
            guard let size = operandSize(opcode: opcode, in: grpprl, at: operandStart),
                  size <= grpprl.endIndex - operandStart else { return }
            if let translated = translation[opcode], size >= 1 {
                let operand = grpprl[operandStart..<operandStart + size]
                // A one-byte operand widened to two: the value is the same.
                body(translated.opcode, translated.widens ? [operand[operand.startIndex], 0][...] : operand)
            }
            position = operandStart + size
        }
    }
}
