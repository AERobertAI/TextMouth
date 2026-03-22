import Foundation

// MARK: - Numbering

/// Parsed numbering definitions for bullet and numbered lists
struct DOCXNumbering {
    /// Maps abstract numbering ID -> array of level formats.
    /// Each level has a format type (bullet, decimal, etc.)
    var abstractNums: [String: [ListLevelFormat]] = [:]

    /// Maps numbering ID (numId) -> abstract numbering ID
    var numIdToAbstractId: [String: String] = [:]

    /// Determine whether a given numId + indent level is a bullet or numbered list
    func listType(numId: String, level: Int) -> ListType {
        guard let abstractId = numIdToAbstractId[numId],
              let levels = abstractNums[abstractId],
              level < levels.count else {
            return .bullet // default to bullet if we can't determine
        }
        return levels[level].listType
    }
}

/// Format information for a single list level
struct ListLevelFormat {
    var numFmt: String // "bullet", "decimal", "lowerLetter", etc.

    var listType: ListType {
        numFmt == "bullet" ? .bullet : .numbered
    }
}

/// Whether a list item is bulleted or numbered
enum ListType {
    case bullet
    case numbered
}

/// SAX parser for word/numbering.xml
class DOCXNumberingParser: NSObject, XMLParserDelegate {
    private let xml: String
    private var numbering = DOCXNumbering()

    // Parsing state
    private var currentAbstractNumId = ""
    private var inAbstractNum = false
    private var currentLevels: [ListLevelFormat] = []
    // Track the current <w:num> element's numId so we can link it to abstractNumId
    private var currentNumId: String?
    private var inNum = false

    init(xml: String) {
        self.xml = xml
    }

    func parse() -> DOCXNumbering {
        guard let data = xml.data(using: .utf8) else { return numbering }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return numbering
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let localName = ParserUtilities.stripNamespacePrefix(elementName)

        switch localName {
        case "abstractNum":
            currentAbstractNumId = attributes["w:abstractNumId"] ?? ""
            currentLevels = []
            inAbstractNum = true
        case "lvl" where inAbstractNum:
            // Each level definition -- we'll fill in the format when we see numFmt
            break
        case "numFmt" where inAbstractNum:
            let fmt = attributes["w:val"] ?? "bullet"
            currentLevels.append(ListLevelFormat(numFmt: fmt))
        case "num":
            // Start of a <w:num> element -- track its numId
            currentNumId = attributes["w:numId"]
            inNum = true
        case "abstractNumId" where inNum:
            // Inside a <w:num>, links numId to its abstract numbering definition
            if let val = attributes["w:val"], let numId = currentNumId {
                numbering.numIdToAbstractId[numId] = val
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let localName = ParserUtilities.stripNamespacePrefix(elementName)
        if localName == "abstractNum" && inAbstractNum {
            numbering.abstractNums[currentAbstractNumId] = currentLevels
            inAbstractNum = false
        } else if localName == "num" && inNum {
            inNum = false
            currentNumId = nil
        }
    }
}
