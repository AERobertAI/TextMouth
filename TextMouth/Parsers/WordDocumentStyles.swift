import Foundation

// MARK: - The Style Sheet

/// The style sheet (STSH) of a Word 97-2003 document ([MS-DOC] 2.9.271):
/// the styles a paragraph or run of text can name by index (`istd`), each
/// with its built-in identifier (`sti`), the style it is based on, and the
/// paragraph and character properties the reader needs from it: the outline
/// level, bold, italic, and hidden text, the size, a page break before, and
/// the list the style is linked to.
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
        /// The list instance a paragraph in the style is in (`sprmPIlfo`, as
        /// the file stores it), or nil: how a heading style is linked to a
        /// list of chapter numbers.
        let listIndex: Int?
        /// The level in its list a paragraph in the style is at (`sprmPIlvl`), or nil.
        let listLevel: Int?
    }

    /// What a style says once the styles it is based on are counted: the first
    /// style of its chain (itself, then the one it is based on, and so on) that
    /// says anything about a property decides it, and a toggle (bold, italic,
    /// hidden) is every style's setting laid on the one before. It is worked
    /// out once for each style when the sheet is read, so that a paragraph
    /// asking costs a lookup, not a walk of the chain: a sheet can make a chain
    /// thousands of styles long.
    struct Resolved {
        /// Whether some style of the chain says the paragraph is a heading, or not.
        var headingDecided = false
        /// The heading level (1 to 6) that style gives, nil for body text.
        var headingLevel: Int?
        var pageBreakBefore: Bool?
        var fontSize: Int?
        var listIndex: Int?
        var listLevel: Int?
        var bold = Toggle()
        var italic = Toggle()
        var hidden = Toggle()
    }

    /// What a chain of styles does to a toggle property: whether text has it
    /// on after the chain, given whether it had it on before.
    struct Toggle {
        /// The value after the chain when the value before it is off, and when on.
        var whenOff = false
        var whenOn = true

        /// The value after the chain, given `value` before it.
        func applied(to value: Bool) -> Bool { value ? whenOn : whenOff }

        /// The toggle after the setting `setting` of a style is laid on it: 0
        /// and 1 set the property off and on, 0x81 reverses it, and anything
        /// else (0x80, or nothing) keeps what it was ([MS-DOC] 2.6.1).
        func laying(_ setting: Int?) -> Toggle {
            Toggle(whenOff: Self.after(setting, whenOff), whenOn: Self.after(setting, whenOn))
        }

        /// `value` after one style's or run's `setting` of the property.
        static func after(_ setting: Int?, _ value: Bool) -> Bool {
            switch setting {
            case 0: return false
            case 1: return true
            case 0x81: return !value
            default: return value
            }
        }
    }

    /// The styles by index; nil for an unused slot of the sheet.
    let styles: [Style?]
    /// Each style as the chain it is based on makes it (`Resolved`); nil where `styles` is.
    private let resolvedStyles: [Resolved?]

    /// A document with no style sheet: every paragraph is body text.
    static let empty = WordStyleSheet(styles: [])

    private init(styles: [Style?]) {
        self.styles = styles
        resolvedStyles = Self.resolve(styles)
    }

    /// Works out every style's `Resolved`. A style is worked out from the one
    /// it is based on; a walk from a style stops at one that is not in the
    /// sheet, one already worked out, or one already in this walk (a loop,
    /// which is then not followed round), so each style is walked once.
    private static func resolve(_ styles: [Style?]) -> [Resolved?] {
        var done = [Resolved?](repeating: nil, count: styles.count)
        // 0 not met, 1 in the walk now, 2 worked out.
        var state = [UInt8](repeating: 0, count: styles.count)
        for start in styles.indices where styles[start] != nil && state[start] == 0 {
            var walk: [Int] = []
            var base = Resolved()
            var next: Int? = start
            while let current = next, current < styles.count, let style = styles[current] {
                if state[current] == 2, let worked = done[current] {
                    base = worked
                    break
                }
                if state[current] == 1 { break }
                state[current] = 1
                walk.append(current)
                next = style.basedOn
            }
            // From the style the walk ended at down to the one it began with.
            for index in walk.reversed() {
                if let style = styles[index] { base = resolved(style, basedOn: base) }
                done[index] = base
                state[index] = 2
            }
        }
        return done
    }

    /// `style` laid on `base`, what the style it is based on gives.
    private static func resolved(_ style: Style, basedOn base: Resolved) -> Resolved {
        var result = base
        // A style's own outline level or built-in identity says whether it is a heading.
        if let outline = style.outlineLevel {
            result.headingDecided = true
            result.headingLevel = headingLevel(ofOutlineLevel: outline)
        } else {
            switch style.builtInIdentifier {
            case 1...9: (result.headingDecided, result.headingLevel) = (true, min(style.builtInIdentifier, 6))
            case 62: (result.headingDecided, result.headingLevel) = (true, 1)
            case 74: (result.headingDecided, result.headingLevel) = (true, 2)
            default: break
            }
        }
        result.pageBreakBefore = style.pageBreakBefore ?? base.pageBreakBefore
        result.fontSize = style.fontSize ?? base.fontSize
        result.listIndex = style.listIndex ?? base.listIndex
        result.listLevel = style.listLevel ?? base.listLevel
        result.bold = base.bold.laying(style.bold)
        result.italic = base.italic.laying(style.italic)
        result.hidden = base.hidden.laying(style.hidden)
        return result
    }

    /// What style `index` says: nothing for one that is not in the sheet, so
    /// that a paragraph naming it (a file's own mistake, or the style 0xFFFF
    /// that means none) has the default formatting ([MS-DOC] sprmPIstd).
    func resolved(styleIndex index: Int) -> Resolved {
        resolvedStyles.indices.contains(index) ? resolvedStyles[index] ?? Resolved() : Resolved()
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
        for _ in 0..<styleCount {
            // Each style is a 16-bit size and then that many bytes; a size of
            // zero leaves the slot unused. A sheet cut short (its length in the
            // file's header is less than its slots need) has no more styles:
            // the slots it does not hold are unused, and so is a style it holds
            // only in part.
            guard position + 2 <= range.upperBound else { break }
            let size = try table.u16(position)
            position += 2
            guard position + size <= range.upperBound else { break }
            if size == 0 {
                styles.append(nil)
            } else {
                styles.append(try Self.style(at: position, size: size, fixedSize: fixedSize, in: table))
            }
            position += size
        }
        // The slots a short sheet does not hold are unused.
        while styles.count < styleCount { styles.append(nil) }
        self.styles = styles
        resolvedStyles = Self.resolve(styles)
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
        var listIndex: Int?
        var listLevel: Int?
        var bold: Int?
        var italic: Int?
        var hidden: Int?
        var fontSize: Int?
        // Paragraph properties of a paragraph style: after the index (2 bytes).
        if kind == 1, let paragraph = groups.first, paragraph.count >= 2 {
            WordSprm.forEach(in: paragraph.dropFirst(2)) { opcode, operand in
                if opcode == WordSprm.outlineLevel, let value = operand.first { outlineLevel = Int(value) }
                if opcode == WordSprm.pageBreakBefore, let value = operand.first { pageBreakBefore = value != 0 }
                if opcode == WordSprm.listLevel, let value = operand.first { listLevel = Int(value) }
                if opcode == WordSprm.listIndex, operand.count >= 2 { listIndex = WordSprm.value(of: operand) }
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
                if opcode == WordSprm.fontSize, operand.count >= 2 { fontSize = WordSprm.value(of: operand) }
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
            pageBreakBefore: pageBreakBefore,
            listIndex: listIndex,
            listLevel: listLevel
        )
    }

    // MARK: Questions

    /// The heading level (1 to 6) of a paragraph in style `index` with the
    /// outline level `direct` set on the paragraph itself, or nil for body
    /// text. Word's outline levels 0 to 8 are heading levels 1 to 9 and 9 is
    /// body text; the deepest levels are read as level 6, as the DOCX reader
    /// reads them, so a document reads alike in both formats. The first of
    /// these that says anything decides: the paragraph's own level, then the
    /// outline level of the style, then of the style it is based on, and so
    /// on, with a style's built-in identity (Heading 1 to 9, Title,
    /// Subtitle) as its level where it sets none. A paragraph in Heading 1 to
    /// 9 (style index 1 to 9) has the level of its style whatever level it
    /// sets itself: [MS-DOC] says its `sprmPOutLvl` MUST be ignored.
    func headingLevel(styleIndex index: Int, directOutlineLevel direct: Int?) -> Int? {
        if let direct, !(1...9).contains(index) { return Self.headingLevel(ofOutlineLevel: direct) }
        return resolved(styleIndex: index).headingLevel
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
        paragraphStyle: Int, characterStyle: Int?, direct: Int?, _ property: KeyPath<Resolved, Toggle>
    ) -> Bool {
        // The paragraph style's chain, from the style it is based on up to the
        // style itself, then the character style's.
        var value = resolved(styleIndex: paragraphStyle)[keyPath: property].applied(to: false)
        if let characterStyle { value = resolved(styleIndex: characterStyle)[keyPath: property].applied(to: value) }
        return Toggle.after(direct, value)
    }

    /// Whether the text with the character format `character` in a paragraph
    /// with the format `paragraph` is hidden (`sprmCFVanish`, a toggle through
    /// the styles): the ordinary view does not show it.
    func hides(_ character: WordCharacterFormat, in paragraph: WordParagraphFormat) -> Bool {
        isToggledOn(paragraphStyle: paragraph.style, characterStyle: character.style, direct: character.hidden, \.hidden)
    }

    /// Whether a paragraph in style `index` with the property `direct` (its own
    /// page-break-before setting, or nil) begins a page: its own setting
    /// wins, else the style's, else that of the style it is based on, and so
    /// on, as the DOCX reader reads `w:pageBreakBefore`.
    func beginsPage(styleIndex index: Int, direct: Bool?) -> Bool {
        direct ?? resolved(styleIndex: index).pageBreakBefore ?? false
    }

    /// The list instance (one-based) and level (0 to 8) of a paragraph in
    /// style `index` with the list properties `direct` and `directLevel` set
    /// on the paragraph itself (nil for none), or nil when the paragraph is
    /// not in a list or its level skips the numbering (0x0C). Each property
    /// is the paragraph's own, else the style's, else that of the style it is
    /// based on, and so on; a paragraph that names list 0 is in no list
    /// whatever its style says, and the level is 0 when none says.
    func listMembership(styleIndex index: Int, listIndex direct: Int?, listLevel directLevel: Int?) -> (instance: Int, level: Int)? {
        let resolved = self.resolved(styleIndex: index)
        guard let raw = direct ?? resolved.listIndex,
              let instance = WordListTables.instanceNumber(ofIlfo: raw) else { return nil }
        let level = directLevel ?? resolved.listLevel ?? 0
        return level < WordListTables.levelCount ? (instance, level) : nil
    }

    /// The font size in half-points of text with the paragraph style
    /// `paragraphStyle`, the character style `characterStyle` (or nil), and
    /// the direct size `direct` (or nil): the direct size, else the character
    /// style's, else the paragraph style's, each through the styles it is
    /// based on, else Word's default of 10 points.
    func fontSize(paragraphStyle: Int, characterStyle: Int?, direct: Int?) -> Int {
        if let direct { return direct }
        if let characterStyle, let size = resolved(styleIndex: characterStyle).fontSize { return size }
        return resolved(styleIndex: paragraphStyle).fontSize ?? 20
    }
}
