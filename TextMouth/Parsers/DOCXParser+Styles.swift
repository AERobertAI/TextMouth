import Foundation

// MARK: - Styles

/// Parsed style definitions mapping style IDs to their semantic roles
struct DOCXStyles {
    /// Maps style ID -> heading level (1-6), empty if no heading styles found
    var headingLevels: [String: Int] = [:]

    /// Style IDs that represent bullet list paragraphs
    var bulletListStyles: Set<String> = []

    /// Style IDs that represent numbered list paragraphs
    var numberedListStyles: Set<String> = []
}

/// SAX parser for word/styles.xml to identify which style IDs correspond to headings
class DOCXStylesParser: DOCXSAXParser {
    private var styles = DOCXStyles()

    // Tracking state during parsing
    private var currentStyleId = ""
    private var currentStyleName = ""
    private var inStyle = false
    private var currentOutlineLevel: Int?

    /// Read every style definition in the part.
    /// - Throws: `DOCXParserError.malformedXML` naming the part when it is
    ///   truncated or not well-formed. The styles after the damage would be
    ///   missing, silently reading their headings and lists as paragraphs.
    func parse() throws -> DOCXStyles {
        try parseDocument()
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
            currentOutlineLevel = nil
            inStyle = true
        case "name" where inStyle:
            // The human-readable style name (e.g. "heading 1", "Heading 2")
            currentStyleName = attributes["w:val"] ?? ""
        case "outlineLvl" where inStyle:
            // Explicit outline level -- most reliable indicator of heading level
            if let val = attributes["w:val"], let level = Int(val) {
                currentOutlineLevel = level
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let localName = ParserUtilities.stripNamespacePrefix(elementName)

        if localName == "style" && inStyle {
            // Determine if this style is a heading
            let headingLevel = resolveHeadingLevel()
            if let level = headingLevel, level >= 1 && level <= 6 {
                styles.headingLevels[currentStyleId] = level
            }

            // Detect list styles by name pattern (e.g. "ListBullet", "List Number")
            let nameLower = currentStyleName.lowercased()
            let idLower = currentStyleId.lowercased()
            if nameLower.contains("list bullet") || idLower.contains("listbullet") {
                styles.bulletListStyles.insert(currentStyleId)
            } else if nameLower.contains("list number") || idLower.contains("listnumber") {
                styles.numberedListStyles.insert(currentStyleId)
            }

            inStyle = false
        }
    }

    /// Determine heading level from style name and/or outline level
    private func resolveHeadingLevel() -> Int? {
        // OOXML levels 0...8 are headings; 9 explicitly means body text.
        // Validate before adding one, including malformed Int.max values.
        if let level = currentOutlineLevel {
            guard (0...8).contains(level) else { return nil }
            return min(level + 1, 6)
        }

        // Fall back to style name pattern matching (works for "heading 1", "Heading1", etc.)
        let nameLower = currentStyleName.lowercased()
        if nameLower.hasPrefix("heading") {
            let rest = nameLower.dropFirst("heading".count)
                .trimmingCharacters(in: .whitespaces)
            if let level = Int(rest) {
                return min(level, 6)
            }
        }

        // Check style ID as last resort (Word uses "Heading1", "Heading2", etc.)
        let idLower = currentStyleId.lowercased()
        if idLower.hasPrefix("heading") {
            let rest = idLower.dropFirst("heading".count)
            if let level = Int(rest) {
                return min(level, 6)
            }
        }

        // "Title" style maps to heading level 1
        if nameLower == "title" || idLower == "title" {
            return 1
        }

        // "Subtitle" maps to heading level 2
        if nameLower == "subtitle" || idLower == "subtitle" {
            return 2
        }

        return nil
    }
}
