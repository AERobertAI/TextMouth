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

    /// Reads the run property element `name`, when it is one of these.
    mutating func read(_ name: String, _ attributes: [String: String]) {
        switch name {
        case "w:b": bold = Self.isOn(attributes)
        case "w:i": italic = Self.isOn(attributes)
        case "w:vanish": hidden = Self.isOn(attributes)
        case "w:sz": size = attributes["w:val"].flatMap { Int($0) }.map { min(max($0, 1), 2_000) }
        case "w:rStyle": characterStyle = attributes["w:val"]
        default: break
        }
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
            size: child.size ?? size, characterStyle: child.characterStyle ?? characterStyle
        )
    }
}

/// The paragraph properties Word 2003 XML states with `w:pPr`: the ones the
/// reading uses.
struct WordMLParagraphProperties: Equatable {
    /// `w:pStyle`: the paragraph's style.
    var style: String?
    /// `w:outlineLvl`, counted from 1 here (Word counts from 0).
    var outlineLevel: Int?
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
        case "w:outlineLvl": outlineLevel = attributes["w:val"].flatMap { Int($0) }.map { min(max($0 + 1, 1), 9) }
        case "w:pageBreakBefore": pageBreakBefore = WordMLRunProperties.isOn(attributes)
        case "w:ilvl": listLevel = attributes["w:val"].flatMap { Int($0) }.map { min(max($0, 0), 8) }
        case "w:ilfo": listID = attributes["w:val"]
        case "wx:t": listMark = attributes["wx:val"]
        default: break
        }
    }
}

/// One style: what it says of its paragraphs and of its text, the style it is
/// based on, and its name.
struct WordMLStyle {
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
    /// How each list mark: list (`w:ilfo`) to level to whether it is numbered
    /// (false for a bullet), from `w:lists`.
    private var listLevels: [String: [Int: Bool]] = [:]
    private var listDefinition: [String: String] = [:]

    var count: Int { styles.count + listLevels.count }

    /// Adds a style of `type` (`paragraph` or `character`) with `id`.
    func add(_ style: WordMLStyle, type: String, id: String) {
        styles[type + "\u{0}" + id] = style
        if type == "paragraph", style.isDefault { defaultParagraphID = id }
    }

    /// The properties of the style `id` of `type` with those of every style
    /// it is based on, oldest first. The heading level of a style named
    /// "heading 1" to "heading 9" is its outline level.
    func resolved(type: String, id: String?) -> (paragraph: WordMLParagraphProperties, run: WordMLRunProperties) {
        var chain: [WordMLStyle] = []
        var seen: Set<String> = []
        var next = id ?? (type == "paragraph" ? defaultParagraphID : nil)
        while let current = next, !seen.contains(current), chain.count < Self.longestChain,
              let style = styles[type + "\u{0}" + current] {
            seen.insert(current)
            chain.append(style)
            next = style.basedOn
        }
        var paragraph = WordMLParagraphProperties()
        var run = WordMLRunProperties()
        for style in chain.reversed() {
            let own = style.paragraph
            paragraph.outlineLevel = own.outlineLevel ?? Self.headingLevel(named: style.name) ?? paragraph.outlineLevel
            paragraph.pageBreakBefore = own.pageBreakBefore ?? paragraph.pageBreakBefore
            run = run.overridden(by: style.run)
        }
        return (paragraph, run)
    }

    /// The level 1 to 9 of a style named "heading N" (without regard to
    /// case), or nil.
    private static func headingLevel(named name: String?) -> Int? {
        guard let name = name?.lowercased(), name.hasPrefix("heading "),
              let level = Int(name.dropFirst("heading ".count).trimmingCharacters(in: .whitespaces)),
              (1...9).contains(level) else { return nil }
        return level
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
