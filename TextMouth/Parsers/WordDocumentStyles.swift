import Foundation

// MARK: - The Style Sheet

/// The style sheet (STSH) of a Word 97-2003 document ([MS-DOC] 2.9.271):
/// the styles a paragraph or run of text can name by index (`istd`), each
/// with its built-in identifier (`sti`), the style it is based on, and the
/// paragraph and character properties the reader needs from it: the outline
/// level, and bold and italic.
///
/// The style sheet is how a heading is told from body text: Word's built-in
/// "Heading 1" to "Heading 9" have `sti` 1 to 9, whatever language the
/// styles' names are in.
struct WordStyleSheet {

    // MARK: A Style

    /// One style, with only the properties this reader uses.
    struct Style {
        /// The built-in identifier (`sti`): 1 to 9 are Heading 1 to 9, 62
        /// is Title, 74 is Subtitle; 0xFFE is a user-defined style.
        let builtInIdentifier: Int
        /// The index of the style this one is based on, or nil.
        let basedOn: Int?
        /// The outline level the style sets (0 to 8, or 9 for body text), or nil.
        let outlineLevel: Int?
        /// The style's own bold property: 0 off, 1 on, 0x80 as the style it
        /// is based on, 0x81 the opposite; nil when it says nothing.
        let bold: Int?
        /// The style's own italic property, valued as `bold` is.
        let italic: Int?
        /// The style's own hidden-text property (`sprmCFVanish`), valued as
        /// `bold` is.
        let hidden: Int?
        /// The style's own font size in half-points, or nil.
        let fontSize: Int?
        /// Whether the style says a paragraph in it begins a page, or nil.
        let pageBreakBefore: Bool?
    }

    /// The styles by index; nil for an unused slot of the sheet.
    let styles: [Style?]

    /// A document with no style sheet: every paragraph is body text.
    static let empty = WordStyleSheet(styles: [])

    private init(styles: [Style?]) {
        self.styles = styles
    }

    // MARK: Reading

    /// Reads the style sheet at `range` in `table`.
    /// - Throws: `OLEDamage` when the sheet's counts or sizes do not fit it.
    init(range: Range<Int>, table: OLEBytes) throws {
        // Stshi: its size, then the count of styles and the size of the fixed
        // part of each style.
        let headerSize = try table.u16(range.lowerBound)
        let styleCount = try table.u16(range.lowerBound + 2)
        let fixedSize = try table.u16(range.lowerBound + 4)
        guard fixedSize >= 10 else { throw OLEDamage(reason: "a style's fixed part is \(fixedSize) bytes long") }
        var position = range.lowerBound + 2 + headerSize
        var styles: [Style?] = []
        styles.reserveCapacity(styleCount)
        for index in 0..<styleCount {
            // Each style is a 16-bit size and then that many bytes; a size of
            // zero leaves the slot unused.
            let size = try table.u16(position)
            position += 2
            guard position + size <= range.upperBound else { throw OLEDamage(reason: "style \(index) runs past the style sheet") }
            if size == 0 {
                styles.append(nil)
            } else {
                styles.append(try Self.style(at: position, size: size, fixedSize: fixedSize, in: table))
            }
            position += size
        }
        self.styles = styles
    }

    /// The style whose bytes are `size` bytes at `position` in `table`.
    private static func style(at position: Int, size: Int, fixedSize: Int, in table: OLEBytes) throws -> Style {
        guard fixedSize + 2 <= size else { throw OLEDamage(reason: "a style is \(size) bytes long") }
        // The fixed part: the identifier and flags, then the kind of style
        // and the style it is based on, then the count of property groups.
        let first = try table.u16(position)
        let second = try table.u16(position + 2)
        let third = try table.u16(position + 4)
        let kind = second & 0x000F
        let basedOn = second >> 4
        let groupCount = third & 0x000F
        // Then the name: a 16-bit length, that many UTF-16 characters, and a
        // terminating null.
        let nameLength = try table.u16(position + fixedSize)
        var offset = fixedSize + 2 + (nameLength + 1) * 2
        guard offset <= size else { throw OLEDamage(reason: "a style's name runs past the style") }

        // Then the property groups, each a 16-bit size and the bytes, padded
        // to an even size. A paragraph style has two: paragraph properties
        // (which begin with the style index of the paragraph) and character
        // properties. A character style has one: character properties.
        var groups: [ArraySlice<UInt8>] = []
        for _ in 0..<groupCount {
            guard offset + 2 <= size else { break }
            let groupSize = try table.u16(position + offset)
            offset += 2
            guard offset + groupSize <= size else { throw OLEDamage(reason: "a style's properties run past the style") }
            groups.append(try table.slice(offset: position + offset, length: groupSize))
            offset += groupSize + groupSize % 2
        }

        var outlineLevel: Int?
        var pageBreakBefore: Bool?
        var bold: Int?
        var italic: Int?
        var hidden: Int?
        var fontSize: Int?
        // Paragraph properties of a paragraph style: after the index (2 bytes).
        if kind == 1, let paragraph = groups.first, paragraph.count >= 2 {
            WordSprm.forEach(in: paragraph.dropFirst(2)) { opcode, operand in
                if opcode == WordSprm.outlineLevel, let value = operand.first { outlineLevel = Int(value) }
                if opcode == WordSprm.pageBreakBefore, let value = operand.first { pageBreakBefore = value != 0 }
            }
        }
        // Character properties: the second group of a paragraph style, the
        // first of a character style.
        let characterGroup = kind == 1 ? 1 : 0
        if kind == 1 || kind == 2, groups.count > characterGroup {
            WordSprm.forEach(in: groups[characterGroup]) { opcode, operand in
                guard let value = operand.first else { return }
                if opcode == WordSprm.bold { bold = Int(value) }
                if opcode == WordSprm.italic { italic = Int(value) }
                if opcode == WordSprm.hidden { hidden = Int(value) }
                if opcode == WordSprm.fontSize, operand.count >= 2 { fontSize = Int(operand[operand.startIndex]) | Int(operand[operand.startIndex + 1]) << 8 }
            }
        }
        return Style(
            builtInIdentifier: first & 0x0FFF,
            basedOn: basedOn == 0x0FFF ? nil : basedOn,
            outlineLevel: outlineLevel,
            bold: bold,
            italic: italic,
            hidden: hidden,
            fontSize: fontSize,
            pageBreakBefore: pageBreakBefore
        )
    }

    // MARK: Questions

    /// Whether `index` names a style of the sheet. `0x0FFF` (no style) and
    /// any index at all in a document with no sheet name Normal.
    func contains(styleIndex index: Int) -> Bool {
        styles.isEmpty || index == 0x0FFF || index < styles.count
    }

    /// The style `index` and the styles it is based on, in that order. The
    /// walk stops at a style that does not exist or that was passed already,
    /// so a loop in the sheet cannot make it long.
    func chain(from index: Int) -> [Style] {
        var chain: [Style] = []
        var passed: Set<Int> = []
        var next: Int? = index
        while let current = next, current < styles.count, passed.insert(current).inserted, let style = styles[current] {
            chain.append(style)
            next = style.basedOn
        }
        return chain
    }

    /// The heading level (1 to 6) of a paragraph in style `index` with the
    /// outline level `direct` set on the paragraph itself, or nil for body
    /// text. Word's outline levels 0 to 8 are heading levels 1 to 9 and 9 is
    /// body text; the deepest levels are read as level 6, as the DOCX reader
    /// reads them, so a document reads alike in both formats. The first of
    /// these that says anything decides: the paragraph's own level, then the
    /// outline level of the style, then of the style it is based on, and so
    /// on, with a style's built-in identity (Heading 1 to 9, Title,
    /// Subtitle) as its level where it sets none.
    func headingLevel(styleIndex index: Int, directOutlineLevel direct: Int?) -> Int? {
        if let direct { return Self.headingLevel(ofOutlineLevel: direct) }
        for style in chain(from: index) {
            if let outline = style.outlineLevel { return Self.headingLevel(ofOutlineLevel: outline) }
            switch style.builtInIdentifier {
            case 1...9: return min(style.builtInIdentifier, 6)
            case 62: return 1
            case 74: return 2
            default: continue
            }
        }
        return nil
    }

    /// The heading level of Word's outline level `outline`.
    private static func headingLevel(ofOutlineLevel outline: Int) -> Int? {
        (0...8).contains(outline) ? min(outline + 1, 6) : nil
    }

    /// Whether text with the paragraph style `paragraphStyle`, the character
    /// style `characterStyle` (or nil), and the direct property `direct` has
    /// the toggle property `property` on: bold, italic, or hidden. Such a
    /// property is a toggle ([MS-DOC] 2.6.1): 0 and 1 set it off and on, 0x80
    /// keeps what the style it is based on, or the paragraph, gives, and
    /// 0x81 reverses it.
    func isToggledOn(
        paragraphStyle: Int, characterStyle: Int?, direct: Int?, _ property: KeyPath<Style, Int?>
    ) -> Bool {
        var value = false
        // Each chain from the style it is based on up to the style itself.
        for style in chain(from: paragraphStyle).reversed() { value = Self.toggled(value, by: style[keyPath: property]) }
        if let characterStyle {
            for style in chain(from: characterStyle).reversed() { value = Self.toggled(value, by: style[keyPath: property]) }
        }
        return Self.toggled(value, by: direct)
    }

    /// Whether a paragraph in style `index` with the property `direct` (its own
    /// page-break-before setting, or nil) begins a page: its own setting
    /// wins, else the style's, else that of the style it is based on, and so
    /// on, as the DOCX reader reads `w:pageBreakBefore`.
    func beginsPage(styleIndex index: Int, direct: Bool?) -> Bool {
        if let direct { return direct }
        return chain(from: index).lazy.compactMap(\.pageBreakBefore).first ?? false
    }

    /// The font size in half-points of text with the paragraph style
    /// `paragraphStyle`, the character style `characterStyle` (or nil), and
    /// the direct size `direct` (or nil): the direct size, else the character
    /// style's, else the paragraph style's, each through the styles it is
    /// based on, else Word's default of 10 points.
    func fontSize(paragraphStyle: Int, characterStyle: Int?, direct: Int?) -> Int {
        if let direct { return direct }
        if let characterStyle, let size = chain(from: characterStyle).lazy.compactMap(\.fontSize).first { return size }
        return chain(from: paragraphStyle).lazy.compactMap(\.fontSize).first ?? 20
    }

    /// `value` after the toggle property `setting` is applied to it.
    private static func toggled(_ value: Bool, by setting: Int?) -> Bool {
        switch setting {
        case 0: return false
        case 1: return true
        case 0x81: return !value
        default: return value
        }
    }
}
