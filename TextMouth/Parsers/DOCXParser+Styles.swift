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
    }

    /// Every style declared in the part, by style ID.
    private var declarations: [String: Declaration] = [:]

    // Tracking state during parsing
    private var currentStyleId = ""
    private var currentStyleName = ""
    private var currentBasedOn: String?
    private var inStyle = false
    private var currentOutlineLevel: DOCXOutlineLevel?

    /// Read every style definition in the part.
    /// - Throws: `DOCXParserError.malformedXML` naming the part when it is
    ///   truncated or not well-formed. The styles after the damage would be
    ///   missing, silently reading their headings and lists as paragraphs.
    func parse() throws -> DOCXStyles {
        try parseDocument()
        styles.headingLevels = Self.headingLevels(of: declarations)
        return styles
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let localName = ParserUtilities.stripNamespacePrefix(elementName)

        switch localName {
        case "style":
            // Start of a style definition -- capture its ID
            currentStyleId = attributes["w:styleId"] ?? ""
            currentStyleName = ""
            currentBasedOn = nil
            currentOutlineLevel = nil
            inStyle = true
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

        // A style without an ID cannot be named by any paragraph. Recorded
        // under the empty ID, it would give its role to every paragraph
        // that names no style.
        if localName == "style" && inStyle && !currentStyleId.isEmpty {
            declarations[currentStyleId] = Declaration(ownHeading: ownHeading(), basedOn: currentBasedOn)

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
    ///
    /// Each chain is walked once, in a loop rather than by recursion, and
    /// every style it passes is resolved with it, so a chain thousands of
    /// styles long neither exhausts the stack nor costs more than linear
    /// time over all the styles.
    private static func headingLevels(of declarations: [String: Declaration]) -> [String: Int] {
        // Each style's level once known; nil for a style known to be no heading.
        var resolved: [String: Int?] = [:]
        for styleId in declarations.keys {
            var chain: [String] = []
            var visited: Set<String> = []
            var level: Int?
            var next: String? = styleId
            while let current = next {
                if let known = resolved[current] {
                    level = known
                    break
                }
                // A style met twice closes a loop: nothing on it says it is
                // a heading. An undefined style says nothing either.
                guard visited.insert(current).inserted, let declaration = declarations[current] else { break }
                chain.append(current)
                if let own = declaration.ownHeading {
                    if case .level(let ownLevel) = own {
                        level = ownLevel
                    }
                    break
                }
                next = declaration.basedOn
            }
            for passed in chain {
                resolved[passed] = level
            }
        }
        return resolved.compactMapValues { $0 }
    }
}
