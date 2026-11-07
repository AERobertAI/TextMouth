import Foundation

// MARK: - What the Styles and Lists of a Word 2003 XML Document Say

/// The run properties Word 2003 XML states with `w:rPr` (FMT53): the ones the
/// reading uses. A property left unsaid is nil, so it is inherited.
struct WordMLRunProperties: Equatable {
    /// `w:b` and `w:i`.
    var bold: Bool?
    var italic: Bool?
    /// `w:vanish`: hidden text.
    var hidden: Bool?
    /// `w:sz`: the size in half points.
    var size: Int?
    /// `w:rStyle`: the character style of a run.
    var characterStyle: String?
    /// `w:rFonts`: the font, its `w:ascii`, else its `w:h-ansi`; a symbol is read in it.
    var font: String?

    /// Reads the run property element `name`, when it is one of these.
    mutating func read(_ name: String, _ attributes: [String: String]) {
        switch name {
        case "w:b": bold = Self.isOn(attributes)
        case "w:i": italic = Self.isOn(attributes)
        case "w:vanish": hidden = Self.isOn(attributes)
        case "w:sz": size = attributes["w:val"].flatMap { Int($0) }.map { min(max($0, 1), 2_000) }
        case "w:rStyle": characterStyle = attributes["w:val"]
        case "w:rFonts": font = Self.fontName(in: attributes) ?? font
        default: break
        }
    }

    /// The font the attributes of a `w:rFonts` name (`w:ascii`, else `w:h-ansi`), or nil for none.
    static func fontName(in attributes: [String: String]) -> String? {
        for key in ["w:ascii", "w:h-ansi"] {
            if let name = attributes[key], !name.isEmpty { return name }
        }
        return nil
    }

    /// Whether a toggle property is on: present with no value, or with a
    /// value other than off, false, or 0.
    static func isOn(_ attributes: [String: String]) -> Bool {
        guard let value = attributes["w:val"]?.lowercased() else { return true }
        return !["off", "false", "0"].contains(value)
    }

    /// These properties with those `child` states put over them.
    func overridden(by child: WordMLRunProperties) -> WordMLRunProperties {
        WordMLRunProperties(
            bold: child.bold ?? bold, italic: child.italic ?? italic, hidden: child.hidden ?? hidden,
            size: child.size ?? size, characterStyle: child.characterStyle ?? characterStyle, font: child.font ?? font
        )
    }
}

/// What an outline level (`w:outlineLvl`) or a style's name says about a
/// paragraph, by the rule of the DOCX reader (`DOCXOutlineLevel`): Word's
/// levels 0 through 8 are headings, read as heading levels 1 through 6 (the
/// deepest three share level 6), and anything else, level 9 included, is
/// body text, which overrides the heading level a style gives.
enum WordMLOutline: Equatable {
    /// A heading at this level, 1 through 6.
    case heading(Int)
    /// Body text: explicitly not a heading.
    case bodyText

    /// The outline level the attribute value `value` declares, or nil when
    /// it is missing or not a whole number, which declares nothing. A
    /// number too large for an `Int`, or any other, is body text.
    init?(_ value: String?) {
        guard let value, let outline = Int(value) else { return nil }
        self = (0...8).contains(outline) ? .heading(min(outline + 1, 6)) : .bodyText
    }

    /// The heading level, or nil for body text.
    var headingLevel: Int? {
        if case .heading(let level) = self { return level }
        return nil
    }
}

/// The paragraph properties Word 2003 XML states with `w:pPr`: the ones the
/// reading uses.
struct WordMLParagraphProperties: Equatable {
    /// `w:pStyle`: the paragraph's style.
    var style: String?
    /// `w:outlineLvl`.
    var outline: WordMLOutline?
    /// `w:pageBreakBefore`.
    var pageBreakBefore: Bool?
    /// `w:listPr`: the level (`w:ilvl`), the list (`w:ilfo`), and the mark it
    /// shows (`wx:t`).
    var listLevel: Int?
    var listID: String?
    var listMark: String?

    /// Reads the paragraph property element `name`, when it is one of these.
    mutating func read(_ name: String, _ attributes: [String: String]) {
        switch name {
        case "w:pStyle": style = attributes["w:val"]
        case "w:outlineLvl": outline = WordMLOutline(attributes["w:val"])
        case "w:pageBreakBefore": pageBreakBefore = WordMLRunProperties.isOn(attributes)
        case "w:ilvl": listLevel = attributes["w:val"].flatMap { Int($0) }.map { min(max($0, 0), 8) }  // clamped: a file's number
        case "w:ilfo": listID = attributes["w:val"]
        case "wx:t": listMark = attributes["wx:val"]
        default: break
        }
    }
}

/// One style: what it says of its paragraphs and of its text, the style it is
/// based on, and its name.
struct WordMLStyle {
    var id = ""
    var name: String?
    var basedOn: String?
    var isDefault = false
    var paragraph = WordMLParagraphProperties()
    var run = WordMLRunProperties()
}

// MARK: - The Style Sheet

/// The styles of a Word 2003 XML document, by type and id, and the lists. A
/// style is resolved through `w:basedOn`, with a guard against a chain that
/// loops (a hostile file can name a style as its own ancestor).
final class WordMLStyleSheet {
    /// The most styles a document may define.
    static let maximumStyles = 100_000
    /// The longest chain of styles followed.
    private static let longestChain = 64

    private var styles: [String: WordMLStyle] = [:]
    /// The id of the default paragraph style (`w:default="on"`).
    private var defaultParagraphID: String?
    /// The font the document defaults name (`w:docDefaults`), if they name one.
    var defaultFont: String?
    /// What the document's font table declares of its fonts (`w:fonts`).
    var fonts = WordXMLFonts()
    /// How each list mark: list (`w:ilfo`) to level to whether it is numbered
    /// (false for a bullet), from `w:lists`.
    private var listLevels: [String: [Int: Bool]] = [:]
    private var listDefinition: [String: String] = [:]

    var count: Int { styles.count + listLevels.count }

    /// Adds a style of `type` (`paragraph` or `character`) with `id`.
    func add(_ style: WordMLStyle, type: String, id: String) {
        var style = style
        style.id = id
        styles[type + "\u{0}" + id] = style
        if type == "paragraph", style.isDefault { defaultParagraphID = id }
    }

    /// The properties of the style `id` of `type` with those of every style
    /// it is based on, oldest first. The heading level of a style named
    /// "heading 1" to "heading 9" is its outline level.
    func resolved(type: String, id: String?) -> (paragraph: WordMLParagraphProperties, run: WordMLRunProperties) {
        let chain = OfficeStyleChain.walk(
            from: id ?? (type == "paragraph" ? defaultParagraphID : nil), limit: Self.longestChain,
            lookup: { self.styles[type + "\u{0}" + $0] }, parent: { $0.basedOn }
        ).styles
        var paragraph = WordMLParagraphProperties()
        var run = WordMLRunProperties()
        for style in chain.reversed() {
            let own = style.paragraph
            paragraph.outline = own.outline ?? Self.outline(of: style) ?? paragraph.outline
            paragraph.pageBreakBefore = own.pageBreakBefore ?? paragraph.pageBreakBefore
            // A list a style belongs to (`w:listPr` in the style).
            paragraph.listID = own.listID ?? paragraph.listID
            paragraph.listLevel = own.listLevel ?? paragraph.listLevel
            paragraph.listMark = own.listMark ?? paragraph.listMark
            run = run.overridden(by: style.run)
        }
        return (paragraph, run)
    }

    /// What a style's name makes of its paragraphs: a style named "heading N"
    /// (1 to 9) is a heading of level N (at most 6), "title" is level 1 and
    /// "subtitle" level 2 (as the DOCX and rich-text readers read them), all
    /// without regard to case, by the style's name or its id; nil otherwise.
    private static func outline(of style: WordMLStyle) -> WordMLOutline? {
        for candidate in [style.name, style.id] {
            guard let name = candidate?.lowercased() else { continue }
            if name == "title" { return .heading(1) }
            if name == "subtitle" { return .heading(2) }
            if name.hasPrefix("heading "),
               let level = Int(name.dropFirst("heading ".count).trimmingCharacters(in: .whitespaces)),
               (1...9).contains(level) {
                return .heading(min(level, 6))
            }
        }
        return nil
    }

    // MARK: Lists

    /// Adds the level `level` of list definition `definition`: bulleted for
    /// number format 23, numbered for the other formats, and left unknown for
    /// 255, which shows no mark.
    func addListLevel(definition: String, level: Int, numberFormat: Int) {
        guard numberFormat != 255 else { return }
        listLevels[definition, default: [:]][level] = numberFormat != 23
    }

    /// Notes that list `list` (`w:ilfo`) uses definition `definition`.
    func addList(_ list: String, definition: String) {
        listDefinition[list] = definition
    }

    /// Whether level `level` of list `list` is numbered (true), bulleted
    /// (false), or unknown (nil).
    func isNumbered(list: String, level: Int) -> Bool? {
        listDefinition[list].flatMap { listLevels[$0]?[level] }
    }
}
