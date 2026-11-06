import Foundation

// MARK: - What a Style Says

/// A font size as a style writes it: a length, or a share of the size of
/// the style it is based on.
enum ODTFontSize: Equatable {
    /// A size in points.
    case points(Double)
    /// A percentage of the inherited size (`150%` is 1.5).
    case factor(Double)

    /// The size in a style's `fo:font-size` (`12pt`, `0.5in`, `1.2cm`,
    /// `10mm`, `16px`, `1pc`, or `120%`), or nil for a value that is none
    /// of these or not a sane size.
    init?(_ value: String?) {
        guard let text = value?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        // The units a length can have, with their size in points.
        let units: [(suffix: String, points: Double)] = [
            ("pt", 1), ("in", 72), ("cm", 72 / 2.54), ("mm", 72 / 25.4), ("px", 0.75), ("pc", 12),
        ]
        if text.hasSuffix("%"), let percent = Double(text.dropLast()), percent.isFinite, percent > 0, percent <= 10_000 {
            self = .factor(percent / 100)
        } else if let unit = units.first(where: { text.hasSuffix($0.suffix) }),
                  let amount = Double(text.dropLast(unit.suffix.count)),
                  amount.isFinite, amount > 0, amount * unit.points <= 1_000 {
            self = .points(amount * unit.points)
        } else {
            return nil
        }
    }

    /// This size where it is based on `inherited` (a size in points).
    func applied(to inherited: Double) -> Double {
        switch self {
        case .points(let points): return points
        case .factor(let factor): return min(inherited * factor, 1_000)
        }
    }
}

/// What one style states, or what a style and the styles it is based on
/// state together. A property a style leaves unsaid is nil, so it is
/// inherited.
struct ODTStyleProperties: Equatable {
    /// `style:parent-style-name`: the style this one is based on.
    var parent: String?
    /// `style:list-style-name`: the list a paragraph of the style belongs to.
    var listStyleName: String?
    /// Whether the style names a master page (`style:master-page-name`), in
    /// which case a paragraph or table of the style begins a page.
    var hasMasterPage: Bool?
    /// `style:default-outline-level`: the heading level of a paragraph of
    /// the style.
    var outlineLevel: Int?
    /// Bold (`fo:font-weight`).
    var bold: Bool?
    /// Italic (`fo:font-style`).
    var italic: Bool?
    /// Hidden text (`text:display`).
    var hidden: Bool?
    /// The size of the text (`fo:font-size`).
    var fontSize: ODTFontSize?
    /// A page break before (`fo:break-before`) and after (`fo:break-after`).
    var breaksBefore: Bool?
    var breaksAfter: Bool?

    /// These properties, with each one `child` states put over them: a
    /// style that is based on this one.
    func overridden(by child: ODTStyleProperties) -> ODTStyleProperties {
        var merged = self
        merged.listStyleName = child.listStyleName ?? listStyleName
        merged.hasMasterPage = child.hasMasterPage ?? hasMasterPage
        merged.outlineLevel = child.outlineLevel ?? outlineLevel
        merged.bold = child.bold ?? bold
        merged.italic = child.italic ?? italic
        merged.hidden = child.hidden ?? hidden
        merged.breaksBefore = child.breaksBefore ?? breaksBefore
        merged.breaksAfter = child.breaksAfter ?? breaksAfter
        // A size that is a share of the inherited one is a share of this
        // style's, whose own size may itself be a share of the one before.
        switch (fontSize, child.fontSize) {
        case (_, nil): merged.fontSize = fontSize
        case (.points(let base)?, .factor?): merged.fontSize = .points(child.fontSize?.applied(to: base) ?? base)
        case (.factor(let base)?, .factor(let own)?): merged.fontSize = .factor(min(base * own, 10_000))
        default: merged.fontSize = child.fontSize
        }
        return merged
    }
}

/// How a level of a list is marked.
enum ODTListMarker: Equatable {
    /// Numbered (`text:list-level-style-number`).
    case number
    /// Bulleted (`text:list-level-style-bullet` and `-image`).
    case bullet
    /// A level that shows no mark: a number style whose format is empty.
    case none
}

// MARK: - The Styles of a Document

/// The styles of an OpenDocument text document: the paragraph, text, and
/// table styles of `styles.xml` and of the automatic styles of
/// `content.xml`, and the list styles, kept by name. It resolves a style
/// through `style:parent-style-name`, with a guard against a chain that
/// loops (a hostile file can name a style as its own ancestor).
final class ODTStyleSheet {
    /// The most styles a document may define. Real documents define
    /// hundreds; a file that defines more is not a document.
    static let maximumStyles = 100_000

    /// The longest chain of parents followed.
    private static let longestChain = 64

    /// The size of text a style chain does not size: Word's and Writer's
    /// default.
    private static let defaultPoints = 12.0

    /// The styles, by family (`paragraph`, `text`, `table`) and name. The
    /// default style of a family (`style:default-style`) is kept under the
    /// empty name.
    private var styles: [String: [String: ODTStyleProperties]] = [:]
    /// The marks of each list style's levels, by list style name and level
    /// (1 is the outermost).
    private var lists: [String: [Int: ODTListMarker]] = [:]
    /// The styles already resolved, by family and name.
    private var resolved: [String: ODTStyleProperties] = [:]
    /// How many styles and list styles have been added.
    private(set) var count = 0

    /// Adds a style of `family` named `name` (empty for the family's
    /// default).
    func add(_ properties: ODTStyleProperties, family: String, name: String) {
        styles[family, default: [:]][name] = properties
        resolved.removeAll()
        count += 1
    }

    /// Adds a list style and the marks of its levels.
    func addList(named name: String, levels: [Int: ODTListMarker]) {
        lists[name] = levels
        count += 1
    }

    /// The mark of `level` (1 is the outermost) of the list style `name`,
    /// or nil when the document defines no such level.
    func marker(ofList name: String?, level: Int) -> ODTListMarker? {
        name.flatMap { lists[$0]?[level] }
    }

    /// The properties the style `name` of `family` states with those of
    /// every style it is based on, put over the family's default. Nil `name`
    /// gives the default alone; a name the document does not define does too.
    func properties(family: String, name: String?) -> ODTStyleProperties {
        let key = family + "\u{0}" + (name ?? "")
        if let known = resolved[key] { return known }
        // The chain, the style first, with a guard against loops.
        var chain: [ODTStyleProperties] = []
        var seen: Set<String> = []
        var next = name
        while let current = next, !seen.contains(current), chain.count < Self.longestChain,
              let style = styles[family]?[current] {
            seen.insert(current)
            chain.append(style)
            next = style.parent
        }
        // The family's default first, then from the oldest ancestor down.
        var merged = styles[family]?[""] ?? ODTStyleProperties()
        for style in chain.reversed() { merged = merged.overridden(by: style) }
        resolved[key] = merged
        return merged
    }

    /// The size of text in points where no style says: the default
    /// paragraph style's, or 12.
    var defaultPointSize: Double {
        properties(family: "paragraph", name: nil).fontSize?.applied(to: Self.defaultPoints) ?? Self.defaultPoints
    }
}

// MARK: - Reading the Styles

/// Reads the style definitions of a part: all of `styles.xml`, and the
/// automatic styles of `content.xml`, which come before the body. The
/// content reader hands it the elements it does not read itself
/// (`ODTStyleCollector.handles(_:)`).
final class ODTStyleCollector {
    /// The style sheet the definitions go into.
    let sheet: ODTStyleSheet

    /// The style being defined: its family, its name, and what it says.
    private var style: (family: String, name: String, properties: ODTStyleProperties)?
    /// The list style being defined, and the marks of its levels so far.
    private var list: (name: String, levels: [Int: ODTListMarker])?

    init(sheet: ODTStyleSheet) {
        self.sheet = sheet
    }

    /// Whether `name` is a style element that this collector reads.
    static func handles(_ name: String) -> Bool {
        name.hasPrefix("style:") || name.hasPrefix("text:list-style") || name.hasPrefix("text:list-level-style")
    }

    /// An element starts. Whether the sheet outgrew its limit is for the
    /// caller to ask (`ODTStyleSheet.count`).
    func start(_ name: String, attributes: [String: String]) {
        switch name {
        case "style:style":
            style = (attributes["style:family"] ?? "", attributes["style:name"] ?? "", ODTStyleProperties(
                parent: attributes["style:parent-style-name"],
                listStyleName: attributes["style:list-style-name"],
                hasMasterPage: attributes["style:master-page-name"].map { !$0.isEmpty },
                outlineLevel: attributes["style:default-outline-level"].flatMap { Int($0) }
            ))
        case "style:default-style":
            style = (attributes["style:family"] ?? "", "", ODTStyleProperties())
        case "style:text-properties":
            guard style != nil else { return }
            readTextProperties(attributes)
        case "style:paragraph-properties", "style:table-properties":
            guard style != nil else { return }
            style?.properties.breaksBefore = attributes["fo:break-before"].map(Self.isPageBreak)
            style?.properties.breaksAfter = attributes["fo:break-after"].map(Self.isPageBreak)
        case "text:list-style":
            list = (attributes["style:name"] ?? "", [:])
        case "text:list-level-style-number":
            // An empty format shows no number.
            let empty = attributes["style:num-format"]?.isEmpty == true
            addLevel(attributes, empty ? .none : .number)
        case "text:list-level-style-bullet", "text:list-level-style-image":
            addLevel(attributes, .bullet)
        default:
            break
        }
    }

    /// An element ends.
    func end(_ name: String) {
        switch name {
        case "style:style", "style:default-style":
            if let finished = style { sheet.add(finished.properties, family: finished.family, name: finished.name) }
            style = nil
        case "text:list-style":
            if let finished = list { sheet.addList(named: finished.name, levels: finished.levels) }
            list = nil
        default:
            break
        }
    }

    /// Reads `style:text-properties` into the style being defined.
    private func readTextProperties(_ attributes: [String: String]) {
        if let weight = attributes["fo:font-weight"] {
            // CSS weights: a number from 600 up, and "bold", are bold.
            style?.properties.bold = weight == "bold" || (Int(weight).map { $0 >= 600 } ?? false)
        }
        if let slant = attributes["fo:font-style"] {
            style?.properties.italic = slant == "italic" || slant == "oblique"
        }
        if let size = ODTFontSize(attributes["fo:font-size"]) {
            style?.properties.fontSize = size
        }
        if let display = attributes["text:display"] {
            // "true" shows the text, "none" hides it, and "condition" hides
            // it when the condition is "none".
            style?.properties.hidden = display == "none" || (display == "condition" && attributes["text:condition"] == "none")
        }
    }

    /// Adds the level a `text:list-level-style-…` element defines to the
    /// list style being defined.
    private func addLevel(_ attributes: [String: String], _ marker: ODTListMarker) {
        guard list != nil, let level = attributes["text:level"].flatMap({ Int($0) }), (1...10).contains(level) else { return }
        list?.levels[level] = marker
    }

    /// Whether a `fo:break-before` or `fo:break-after` value breaks the page.
    private static func isPageBreak(_ value: String) -> Bool {
        value == "page"
    }
}

// MARK: - styles.xml

/// Reads the styles of `styles.xml`, or of any part that holds only
/// style definitions, into a sheet.
final class ODTStylesReader: ODTXMLReader {
    private let collector: ODTStyleCollector

    /// Prepares to read `data`, the part at `file`, into `sheet`.
    init(data: Data, file: String, sheet: ODTStyleSheet) {
        collector = ODTStyleCollector(sheet: sheet)
        super.init(data: data, file: file)
    }

    override func startElement(_ name: String, attributes: [String: String]) {
        // The master pages' headers and footers hold text, which is not read.
        if name == "style:master-page" || name == "office:master-styles" { return skipSubtree() }
        collector.start(name, attributes: attributes)
        if collector.sheet.count > ODTStyleSheet.maximumStyles { fail(TextutilConverter.Failure.unreadable(.odt)) }
    }

    override func endElement(_ name: String) {
        collector.end(name)
    }
}
