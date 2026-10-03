import Foundation

// MARK: - Numbering

/// The list definitions in a document's numbering part (word/numbering.xml).
///
/// A list's formats live in an abstract definition (`w:abstractNum`) of up
/// to nine levels, each named by its level index (`w:ilvl`); paragraphs
/// refer to a list instance (`w:num`), which names the abstract definition
/// it uses and may override some of its levels (`w:lvlOverride`). Levels
/// are kept by that index, never by their position in the part, so a
/// definition that lists its levels sparsely or out of order still gives
/// every paragraph the level it names.
struct DOCXNumbering {
    /// The level indexes (`w:ilvl`) a Word list can use: nine levels, 0 through 8.
    static let levelIndexes = 0...8

    /// The levels of each abstract definition: abstractNumId -> level index -> level.
    var abstractNums: [String: [Int: ListLevelFormat]] = [:]

    /// The abstract definition each list instance uses: numId -> abstractNumId.
    var numIdToAbstractId: [String: String] = [:]

    /// How each list instance overrides levels of its abstract definition:
    /// numId -> level index -> override.
    var levelOverrides: [String: [Int: ListLevelOverride]] = [:]

    /// The level a paragraph of list instance `numId` at `level` uses: the
    /// instance's own definition of the level when it overrides one, or else
    /// its abstract definition's, starting from the instance's start
    /// override when it has one. Nil when neither defines the level.
    func levelFormat(numId: String, level: Int) -> ListLevelFormat? {
        let override = levelOverrides[numId]?[level]
        let abstractLevel = numIdToAbstractId[numId].flatMap { abstractNums[$0]?[level] }
        guard var format = override?.level ?? abstractLevel else { return nil }
        // ISO/IEC 29500-1 §17.9.27: a start override wins over the start of
        // any level definition it accompanies.
        if let start = override?.startOverride {
            format.start = start
        }
        return format
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
    /// The largest number a list item is given. CommonMark reads at most
    /// nine digits as a list item's number; a longer one would turn the
    /// item into a paragraph whose number is read aloud.
    static let largestNumber = 999_999_999

    /// The level's number format (`w:numFmt`): "bullet", "decimal",
    /// "lowerLetter", and so on.
    var numFmt: String

    /// The number the level counts from (`w:start`). ISO/IEC 29500-1
    /// §17.9.25 counts from 0 when a level names no start. Word always
    /// writes one, and TextMouth has always counted such levels from 1, as
    /// the simpler documents other tools write expect, so 1 is kept.
    var start = 1

    /// When the level counts from its start again (`w:lvlRestart`): nil
    /// when the definition does not say, 0 for never, and otherwise the
    /// one-based level whose items, like those of any shallower level,
    /// restart it. See `restarts(level:afterItemAt:)`.
    var restartAfter: Int?

    /// Bulleted for the bullet format; every other format numbers its items.
    var listType: ListType {
        numFmt == "bullet" ? .bullet : .numbered
    }

    /// Whether this level, at index `ownLevel`, counts from its start again
    /// when an item at index `usedLevel` appears (ISO/IEC 29500-1 §17.9.10).
    /// Only a shallower item restarts a level. By default any shallower
    /// item does; a restart value of n restarts it after an item at
    /// one-based level n or shallower, and 0 never. A value naming this
    /// level or a deeper one is ignored, as the standard says.
    func restarts(level ownLevel: Int, afterItemAt usedLevel: Int) -> Bool {
        guard usedLevel < ownLevel else { return false }
        switch restartAfter {
        case 0?:
            return false
        case let named? where named - 1 < ownLevel:
            return usedLevel < named
        default:
            return true
        }
    }

    /// `value` read as a list number: a whole number held to the numbers a
    /// list item can show (0 through `largestNumber`), or nil when it is
    /// not a whole number.
    static func number(_ value: String?) -> Int? {
        guard let value, let number = Int(value) else { return nil }
        return min(max(number, 0), largestNumber)
    }
}

/// How a list instance overrides one level of its abstract definition
/// (`w:lvlOverride`, ISO/IEC 29500-1 §17.9.9).
struct ListLevelOverride {
    /// The number the level starts from in this instance (`w:startOverride`).
    var startOverride: Int?
    /// A definition the instance uses in place of the abstract one (`w:lvl`).
    var level: ListLevelFormat?
}

/// Whether a list item is bulleted or numbered
enum ListType {
    case bullet
    case numbered
}

/// What begins one list item in the Markdown: a bullet, or its number.
enum DOCXListMarker: Equatable {
    case bullet
    case number(Int)
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
    /// The level override being read inside a list instance and the index
    /// of the level it overrides. Nil outside an override, and inside one
    /// whose index is not valid.
    private var levelOverride: (index: Int, override: ListLevelOverride)?

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
        case "lvl" where abstractNum != nil || levelOverride != nil:
            // ISO/IEC 29500-1 §17.9.17: a level that names no number format
            // is decimal, so the level starts out decimal. A level inside an
            // override replaces the level the override names, whatever
            // index the level itself declares.
            let index = levelOverride?.index ?? Self.levelIndex(attributes["w:ilvl"])
            level = index.map { ($0, ListLevelFormat(numFmt: "decimal")) }
        case "numFmt" where level != nil:
            // Word writes a second format for the same level inside
            // mc:AlternateContent; the last one read stands, and neither
            // can move the level to another index.
            level?.format.numFmt = attributes["w:val"] ?? "bullet"
        case "start" where level != nil:
            if let start = ListLevelFormat.number(attributes["w:val"]) {
                level?.format.start = start
            }
        case "lvlRestart" where level != nil:
            // A negative value names no level, so it says no more than a
            // missing one.
            if let value = attributes["w:val"].flatMap({ Int($0) }), value >= 0 {
                level?.format.restartAfter = value
            }
        case "num":
            // Start of a <w:num> element -- track its numId
            currentNumId = attributes["w:numId"]
            inNum = true
        case "abstractNumId" where inNum:
            // Inside a <w:num>, links numId to its abstract numbering definition
            if let val = attributes["w:val"], let numId = currentNumId {
                numbering.numIdToAbstractId[numId] = val
            }
        case "lvlOverride" where inNum:
            levelOverride = Self.levelIndex(attributes["w:ilvl"]).map { ($0, ListLevelOverride()) }
        case "startOverride" where levelOverride != nil:
            levelOverride?.override.startOverride = ListLevelFormat.number(attributes["w:val"])
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
                if levelOverride != nil {
                    levelOverride?.override.level = level.format
                } else {
                    abstractNum?.levels[level.index] = level.format
                }
            }
            level = nil
        case "lvlOverride":
            if let levelOverride, let numId = currentNumId {
                numbering.levelOverrides[numId, default: [:]][levelOverride.index] = levelOverride.override
            }
            levelOverride = nil
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
