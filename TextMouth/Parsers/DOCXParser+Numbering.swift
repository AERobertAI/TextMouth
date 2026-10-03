import Foundation

// MARK: - Numbering

/// The list definitions in a document's numbering part (word/numbering.xml).
///
/// A list's formats live in an abstract definition (`w:abstractNum`) of up
/// to nine levels, each named by its level index (`w:ilvl`); paragraphs
/// refer to a list instance (`w:num`), which names the abstract definition
/// it uses. Levels are kept by that index, never by their position in the
/// part, so a definition that lists its levels sparsely or out of order
/// still gives every paragraph the level it names.
struct DOCXNumbering {
    /// The level indexes (`w:ilvl`) a Word list can use: nine levels, 0 through 8.
    static let levelIndexes = 0...8

    /// The levels of each abstract definition: abstractNumId -> level index -> level.
    var abstractNums: [String: [Int: ListLevelFormat]] = [:]

    /// The abstract definition each list instance uses: numId -> abstractNumId.
    var numIdToAbstractId: [String: String] = [:]

    /// The level a paragraph of list instance `numId` at `level` uses, or
    /// nil when the instance, its definition, or that level is not defined.
    func levelFormat(numId: String, level: Int) -> ListLevelFormat? {
        guard let abstractId = numIdToAbstractId[numId] else { return nil }
        return abstractNums[abstractId]?[level]
    }

    /// Whether a paragraph of list instance `numId` at `level` is bulleted
    /// or numbered. A paragraph whose list or level is not defined reads as
    /// a bullet, since there is no number to give it.
    func listType(numId: String, level: Int) -> ListType {
        levelFormat(numId: numId, level: level)?.listType ?? .bullet
    }
}

/// One level of a list definition (`w:lvl`).
struct ListLevelFormat {
    /// The level's number format (`w:numFmt`): "bullet", "decimal",
    /// "lowerLetter", and so on.
    var numFmt: String

    /// Bulleted for the bullet format; every other format numbers its items.
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
class DOCXNumberingParser: DOCXSAXParser {
    private var numbering = DOCXNumbering()

    // Parsing state
    /// The abstract definition being read: its ID and the levels read so far.
    private var abstractNum: (id: String, levels: [Int: ListLevelFormat])?
    /// The level being read and the index it is stored under. Nil outside a
    /// level, and inside one whose index is missing or not one of the nine
    /// a list allows: no paragraph could be matched to it.
    private var level: (index: Int, format: ListLevelFormat)?
    // Track the current <w:num> element's numId so we can link it to abstractNumId
    private var currentNumId: String?
    private var inNum = false

    /// Read every list definition in the part.
    /// - Throws: `DOCXParserError.malformedXML` naming the part when it is
    ///   truncated or not well-formed. The lists defined after the damage
    ///   would be missing, silently reading numbered steps as bullets.
    func parse() throws -> DOCXNumbering {
        try parseDocument()
        return numbering
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let localName = ParserUtilities.stripNamespacePrefix(elementName)

        switch localName {
        case "abstractNum":
            abstractNum = (attributes["w:abstractNumId"] ?? "", [:])
        case "lvl" where abstractNum != nil:
            // ISO/IEC 29500-1 §17.9.17: a level that names no number format
            // is decimal, so the level starts out decimal.
            level = Self.levelIndex(attributes["w:ilvl"]).map { ($0, ListLevelFormat(numFmt: "decimal")) }
        case "numFmt" where level != nil:
            // Word writes a second format for the same level inside
            // mc:AlternateContent; the last one read stands, and neither
            // can move the level to another index.
            level?.format.numFmt = attributes["w:val"] ?? "bullet"
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
        switch localName {
        case "lvl":
            if let level {
                abstractNum?.levels[level.index] = level.format
            }
            level = nil
        case "abstractNum":
            if let abstractNum {
                numbering.abstractNums[abstractNum.id] = abstractNum.levels
            }
            abstractNum = nil
        case "num" where inNum:
            inNum = false
            currentNumId = nil
        default:
            break
        }
    }

    /// The level index `value` names, or nil when it is not a whole number
    /// among the nine indexes a Word list allows.
    private static func levelIndex(_ value: String?) -> Int? {
        guard let value, let index = Int(value), DOCXNumbering.levelIndexes.contains(index) else { return nil }
        return index
    }
}
