import Foundation

// MARK: - Styles

/// Parsed style definitions mapping style IDs to their semantic roles
struct DOCXStyles {
    /// Maps style ID -> heading level (1-6), empty if no heading styles found.
    /// A style that says nothing about being a heading takes the level of
    /// the style it is based on (`w:basedOn`), so a custom style based on
    /// "Heading 2" is a level-2 heading too.
    var headingLevels: [String: Int] = [:]

    /// Style IDs that represent bullet list paragraphs
    var bulletListStyles: Set<String> = []

    /// Style IDs that represent numbered list paragraphs
    var numberedListStyles: Set<String> = []

    /// Style IDs whose paragraphs begin a new page (PG07): the style's own
    /// properties hold `w:pageBreakBefore`, or the style it is based on
    /// (`w:basedOn`) does and it does not turn that off with a `w:val` of
    /// "0", "false", or "off".
    var pageBreakBeforeStyles: Set<String> = []

    /// What each paragraph style says about hiding its text: `w:vanish` in the
    /// style's own run properties (true, or false for a `w:val` of "0"), or
    /// else in the first style it is based on that says anything, through
    /// styles of the same kind (ECMA-376 17.7.4.3: a `w:basedOn` naming a style
    /// of another kind is ignored). A style that says nothing is absent. The
    /// value is kept, false included, because Word resets to it
    /// (`DOCXHiding`).
    var paragraphHiding: [String: Bool] = [:]

    /// What each character style says about hiding its text, resolved the same way.
    var characterHiding: [String: Bool] = [:]

    /// What each table style says about hiding its text (`w:vanish` in the
    /// style's own run properties, not in its conditional formatting),
    /// resolved the same way.
    var tableHiding: [String: Bool] = [:]

    /// What the document defaults say about hiding text (`w:vanish` in
    /// `w:docDefaults`): nil when they say nothing.
    var documentDefaultsHiding: Bool?

    /// Paragraph style IDs that hide their text.
    var hiddenParagraphStyles: Set<String> { Set(paragraphHiding.filter(\.value).keys) }

    /// Character style IDs that hide their text.
    var hiddenCharacterStyles: Set<String> { Set(characterHiding.filter(\.value).keys) }

    /// Table style IDs that hide their text.
    var hiddenTableStyles: Set<String> { Set(tableHiding.filter(\.value).keys) }

    /// Whether the document defaults hide all text.
    var documentDefaultsHide: Bool { documentDefaultsHiding == true }

    /// The ID of the default paragraph style (`w:default` on a paragraph
    /// style): the style a paragraph that names none takes. Nil when the
    /// part names none.
    var defaultParagraphStyle: String?

    /// The ID of the default table style (`w:default` on a table style): the
    /// style a table that names none takes. Nil when the part names none.
    var defaultTableStyle: String?
}

/// Whether the `w:val` of an on/off property (`w:pageBreakBefore`) turns it
/// on. A property with no `w:val` is on; "0", "false", and "off" turn it off
/// (ISO/IEC 29500-1, ST_OnOff), and every other value leaves it on.
enum DOCXOnOff {
    /// The state `value`, the property's `w:val` attribute (nil when absent), gives.
    static func isOn(_ value: String?) -> Bool {
        guard let value else { return true }
        return !["0", "false", "off"].contains(value)
    }
}

/// What an explicit outline level (`w:outlineLvl`) says about a paragraph.
/// Word's outline levels 0 through 8 are headings, read here as heading
/// levels 1 through 6 (the deepest three share level 6), and 9 is body
/// text. Any other number is not an outline level Word writes, so it is
/// read as body text too rather than inventing a heading.
enum DOCXOutlineLevel: Equatable {
    /// A heading at this level, 1 through 6.
    case heading(Int)
    /// Body text: explicitly not a heading.
    case bodyText

    /// The outline level the attribute value `value` declares, or nil when
    /// the value is missing or not a whole number, which declares nothing.
    init?(_ value: String?) {
        guard let value, let outline = Int(value) else { return nil }
        self = (0...8).contains(outline) ? .heading(min(outline + 1, 6)) : .bodyText
    }

    /// The heading level, or nil for body text.
    var headingLevel: Int? {
        if case .heading(let level) = self {
            return level
        }
        return nil
    }
}

/// SAX parser for word/styles.xml to identify which style IDs correspond to headings
class DOCXStylesParser: DOCXSAXParser {
    private var styles = DOCXStyles()

    /// What a style's own definition says about being a heading.
    private enum OwnHeading {
        /// A heading at this level, 1 through 6.
        case level(Int)
        /// Not a heading, whatever style it is based on: its outline level
        /// is body text.
        case notAHeading
    }

    /// One style as its definition declares it, before inheritance.
    private struct Declaration {
        /// What the style says about being a heading; nil when it says
        /// nothing, so the style it is based on decides.
        var ownHeading: OwnHeading?
        /// The style it is based on (`w:basedOn`), if any.
        var basedOn: String?
        /// What the style's own properties say about starting a page
        /// (`w:pageBreakBefore`); nil when they say nothing, so the style it
        /// is based on decides.
        var ownPageBreakBefore: Bool?
        /// What the style's own run properties say about hiding its text
        /// (`w:vanish`); nil when they say nothing, so the style it is based
        /// on decides.
        var ownHidden: Bool?
        /// The style's kind (`w:type`): "paragraph", "character", "table",
        /// or "numbering".
        var type: String
    }

    /// Every style declared in the part, by style ID.
    private var declarations: [String: Declaration] = [:]

    // Tracking state during parsing
    private var currentStyleId = ""
    private var currentStyleName = ""
    private var currentBasedOn: String?
    private var inStyle = false
    private var currentOutlineLevel: DOCXOutlineLevel?
    private var currentPageBreakBefore: Bool?
    private var currentHidden: Bool?
    private var currentStyleType = "paragraph"

    /// The names of the elements being read, outermost first: `w:vanish`
    /// counts only as a child of the style's own `w:rPr`, not of a table
    /// style's conditional formatting or of a record of a change.
    private var elementStack: [String] = []

    /// How many records of tracked formatting changes (`w:pPrChange` and the
    /// like) enclose the element being read. Their properties are those from
    /// before the change, not the style's own.
    private var trackedChangeDepth = 0

    /// Read every style definition in the part.
    /// - Throws: `DOCXParserError.malformedXML` naming the part when it is
    ///   truncated or not well-formed. The styles after the damage would be
    ///   missing, silently reading their headings and lists as paragraphs.
    func parse() throws -> DOCXStyles {
        try parseDocument()
        styles.headingLevels = Self.headingLevels(of: declarations)
        styles.pageBreakBeforeStyles = Self.pageBreakBeforeStyles(of: declarations)
        let hiding = Self.inherited(through: declarations, own: \.ownHidden)
        styles.paragraphHiding = hiding.filter { declarations[$0.key]?.type == "paragraph" }
        styles.characterHiding = hiding.filter { declarations[$0.key]?.type == "character" }
        styles.tableHiding = hiding.filter { declarations[$0.key]?.type == "table" }
        return styles
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let localName = ParserUtilities.stripNamespacePrefix(elementName)
        elementStack.append(localName)
        if localName.hasSuffix("Change") {
            trackedChangeDepth += 1
        }

        switch localName {
        case "style":
            // Start of a style definition -- capture its ID
            currentStyleId = attributes["w:styleId"] ?? ""
            currentStyleName = ""
            currentBasedOn = nil
            currentOutlineLevel = nil
            currentPageBreakBefore = nil
            currentHidden = nil
            // A style that names no type is a paragraph style (ST_StyleType).
            currentStyleType = attributes["w:type"] ?? "paragraph"
            inStyle = true
            // The default paragraph style is the one a paragraph with no
            // style takes.
            if let flag = attributes["w:default"], DOCXOnOff.isOn(flag), !currentStyleId.isEmpty {
                if currentStyleType == "paragraph" {
                    styles.defaultParagraphStyle = currentStyleId
                } else if currentStyleType == "table" {
                    styles.defaultTableStyle = currentStyleId
                }
            }
        case "vanish" where inStyle && trackedChangeDepth == 0 && Self.isStyleRunProperty(elementStack):
            // The style's text is hidden, unless turned off
            currentHidden = DOCXOnOff.isOn(attributes["w:val"])
        case "vanish" where !inStyle && trackedChangeDepth == 0 && Self.isDocumentDefaultRunProperty(elementStack):
            // Every run is hidden by default, unless turned off
            styles.documentDefaultsHiding = DOCXOnOff.isOn(attributes["w:val"])
        case "pageBreakBefore" where inStyle && trackedChangeDepth == 0:
            // The style's paragraphs begin a page (PG07), unless turned off
            currentPageBreakBefore = DOCXOnOff.isOn(attributes["w:val"])
        case "name" where inStyle:
            // The human-readable style name (e.g. "heading 1", "Heading 2")
            currentStyleName = attributes["w:val"] ?? ""
        case "basedOn" where inStyle:
            // The style this one inherits its properties from
            currentBasedOn = attributes["w:val"]
        case "outlineLvl" where inStyle:
            // Explicit outline level -- most reliable indicator of heading level
            if let outline = DOCXOutlineLevel(attributes["w:val"]) {
                currentOutlineLevel = outline
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let localName = ParserUtilities.stripNamespacePrefix(elementName)
        if localName.hasSuffix("Change") {
            trackedChangeDepth = max(0, trackedChangeDepth - 1)
        }
        if !elementStack.isEmpty { elementStack.removeLast() }

        // A style without an ID cannot be named by any paragraph. Recorded
        // under the empty ID, it would give its role to every paragraph
        // that names no style.
        if localName == "style" && inStyle && !currentStyleId.isEmpty {
            declarations[currentStyleId] = Declaration(
                ownHeading: ownHeading(),
                basedOn: currentBasedOn,
                ownPageBreakBefore: currentPageBreakBefore,
                ownHidden: currentHidden,
                type: currentStyleType
            )

            // Detect list styles by name pattern (e.g. "ListBullet", "List Number")
            let nameLower = currentStyleName.lowercased()
            let idLower = currentStyleId.lowercased()
            if nameLower.contains("list bullet") || idLower.contains("listbullet") {
                styles.bulletListStyles.insert(currentStyleId)
            } else if nameLower.contains("list number") || idLower.contains("listnumber") {
                styles.numberedListStyles.insert(currentStyleId)
            }
        }
        if localName == "style" {
            inStyle = false
        }
    }

    /// Whether the element at the top of `stack` is a direct child of the
    /// run properties (`w:rPr`) that are a direct child of a style
    /// (`w:style`): the style's own character formatting, as opposed to a
    /// table style's conditional formatting (`w:tblStylePr`).
    private static func isStyleRunProperty(_ stack: [String]) -> Bool {
        stack.count >= 3 && stack[stack.count - 2] == "rPr" && stack[stack.count - 3] == "style"
    }

    /// Whether the element at the top of `stack` is a direct child of the
    /// default run properties (`w:docDefaults/w:rPrDefault/w:rPr`).
    private static func isDocumentDefaultRunProperty(_ stack: [String]) -> Bool {
        stack.dropLast().suffix(3) == ["docDefaults", "rPrDefault", "rPr"]
    }

    /// What the style being read says about being a heading by itself: its
    /// explicit outline level when it has one, which wins over its name;
    /// otherwise the level its name or ID gives ("heading 2", "Heading2",
    /// "Title", "Subtitle"); otherwise nothing.
    private func ownHeading() -> OwnHeading? {
        if let outline = currentOutlineLevel {
            return outline.headingLevel.map(OwnHeading.level) ?? .notAHeading
        }

        // Fall back to style name pattern matching (works for "heading 1",
        // "Heading1", etc.), then to the style ID (Word uses "Heading1").
        let nameLower = currentStyleName.lowercased()
        let idLower = currentStyleId.lowercased()
        if let level = Self.headingNumber(in: nameLower) ?? Self.headingNumber(in: idLower) {
            return .level(level)
        }

        // "Title" style maps to heading level 1
        if nameLower == "title" || idLower == "title" {
            return .level(1)
        }

        // "Subtitle" maps to heading level 2
        if nameLower == "subtitle" || idLower == "subtitle" {
            return .level(2)
        }

        return nil
    }

    /// The heading level a lowercased style name or ID such as "heading 2"
    /// or "heading2" gives, with levels deeper than 6 read as 6, or nil when
    /// it does not name a heading level from 1 up.
    private static func headingNumber(in name: String) -> Int? {
        guard name.hasPrefix("heading"),
              let number = Int(name.dropFirst("heading".count).trimmingCharacters(in: .whitespaces)),
              number >= 1 else { return nil }
        return min(number, 6)
    }

    /// The heading level of every declared style: its own when its
    /// definition gives one, otherwise that of the style it is based on,
    /// followed up the `w:basedOn` chain to the first style that says
    /// whether it is a heading. A chain that loops back on itself, or
    /// reaches a style the part does not define, gives no level.
    private static func headingLevels(of declarations: [String: Declaration]) -> [String: Int] {
        inherited(through: declarations, own: \.ownHeading).compactMapValues { heading in
            if case .level(let level) = heading {
                return level
            }
            return nil
        }
    }

    /// The styles that begin a page (PG07): those whose own properties
    /// hold `w:pageBreakBefore`, or, when they say nothing, whose
    /// `w:basedOn` chain does at its first style that says anything. A style
    /// that turns the property off (`w:val` "0", "false", or "off") ends the
    /// search with no page break, whatever the styles behind it say.
    private static func pageBreakBeforeStyles(of declarations: [String: Declaration]) -> Set<String> {
        Set(inherited(through: declarations, own: \.ownPageBreakBefore).filter(\.value).keys)
    }

    /// What every declared style answers for a property that a style may
    /// state itself (`own` gives that statement, or nil for a style that
    /// says nothing) and otherwise takes from the style it is based on,
    /// followed up the `w:basedOn` chain to the first style that states it.
    /// A style whose chain states nothing, loops back on itself, or reaches
    /// a style the part does not define is left out of the result. A
    /// `w:basedOn` that names a style of another kind (a paragraph style
    /// based on a character or table style) "shall be ignored" (ECMA-376
    /// 17.7.4.3): the chain ends there.
    ///
    /// Each chain is walked once, in a loop rather than by recursion, and
    /// every style it passes is resolved with it, so a chain thousands of
    /// styles long neither exhausts the stack nor costs more than linear
    /// time over all the styles.
    private static func inherited<Answer>(
        through declarations: [String: Declaration],
        own: (Declaration) -> Answer?
    ) -> [String: Answer] {
        // Each style's answer once known; nil for a style known to have none.
        var resolved: [String: Answer?] = [:]
        for styleId in declarations.keys {
            var chain: [String] = []
            var visited: Set<String> = []
            var answer: Answer?
            var next: String? = styleId
            while let current = next {
                if let known = resolved[current] {
                    answer = known
                    break
                }
                // A style met twice closes a loop: nothing on it states the
                // property. An undefined style says nothing either.
                guard visited.insert(current).inserted, let declaration = declarations[current] else { break }
                chain.append(current)
                if let stated = own(declaration) {
                    answer = stated
                    break
                }
                // A base of another kind is ignored.
                next = declaration.basedOn.flatMap { declarations[$0]?.type == declaration.type ? $0 : nil }
            }
            for passed in chain {
                resolved[passed] = answer
            }
        }
        return resolved.compactMapValues { $0 }
    }
}

// MARK: - Hidden Text

/// How Word settles whether a run's text is hidden (`w:vanish`), a toggle
/// property: the document defaults, the run's table style, paragraph style, and
/// character style, and the run's own properties. Each level's stated value is
/// kept (true, or false for a `w:val` of "0"), not only whether it hides.
///
/// - ECMA-376 17.7.3: a value in the run's own (direct) formatting is the
///   absolute state.
/// - MS-OI29500 17.7.3(a) and (b): when the document defaults say true, a level
///   with no value takes the defaults' value (true), and the text is hidden
///   if and only if its effective value is false for an even number of the
///   three levels (none, or two, are false).
/// - MS-OI29500 17.7.6(b) and 17.7.8(a): otherwise Word does not toggle the
///   state for a table style or a paragraph style, it resets it to the value
///   the style states ("a value of 1 resets the property's state to True
///   instead of toggling it"), in the order table, then paragraph.
/// - A character style toggles, as the standard says (ECMA-376 17.7.3, with no
///   Word note): true flips the state, false leaves it.
///
/// - A row marked hidden (`w:trPr/w:hidden`) hides nothing of its own, in a
///   DOCX or in Word 2003 XML: ECMA-376 Part 1 §17.4.20 (Hidden Table Row
///   Marker) hides the glyph of the row's end marker, "to ensure that the
///   entire table row is hidden and not displayed in the document, as if any
///   part of the row is visible, the row is displayed". So a row marked hidden
///   whose runs are visible shows them, and a row that Word hides has its runs
///   and marks hidden, which the runs' own `w:vanish` already says. The
///   clause's example says the row is not displayed, so the clause is not
///   clean. This is the one place that says so; the readers, the tests, and
///   the reader versions refer to it as "the hidden row rule of `DOCXHiding`".
///
/// The notes come from Microsoft's and ECMA's documents alone; nothing here
/// has been checked in Word itself.
enum DOCXHiding {
    /// Whether the text is hidden, given what each level states (nil for a
    /// level that states nothing).
    static func isHidden(documentDefaults: Bool?, table: Bool?, paragraph: Bool?, character: Bool?, direct: Bool?) -> Bool {
        if let direct { return direct }
        if documentDefaults == true {
            // A level with no value takes the defaults' value, true.
            let falseLevels = [table, paragraph, character].filter { ($0 ?? true) == false }.count
            return falseLevels % 2 == 0
        }
        // The defaults say false or nothing: the state starts false.
        var hidden = false
        if let table { hidden = table }
        if let paragraph { hidden = paragraph }
        if character == true { hidden.toggle() }
        return hidden
    }
}
