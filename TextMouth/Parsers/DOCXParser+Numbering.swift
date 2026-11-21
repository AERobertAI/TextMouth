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
        // ISO/IEC 29500-1 (w:startOverride): a start override wins over the
        // start of any level definition it accompanies.
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

    /// The key under which the paragraphs of list instance `numId` share
    /// their counts: its abstract definition, every instance of which Word
    /// numbers as one list, or the instance itself when it names none.
    func counterKey(numId: String) -> String {
        numIdToAbstractId[numId].map { "abstract:" + $0 } ?? "instance:" + numId
    }

    /// The levels list instance `numId` starts afresh when its first
    /// paragraph appears, shallowest first: those it overrides with a start
    /// override or a replacement level.
    func restartedLevels(numId: String) -> [Int] {
        (levelOverrides[numId] ?? [:])
            .filter { $0.value.startOverride != nil || $0.value.level != nil }
            .keys
            .sortedStably()
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

    /// The number the level counts from (`w:start`). ISO/IEC 29500-1 counts
    /// from 0 when a level names no start. Word always writes one, and
    /// TextMouth has always counted such levels from 1, as the simpler
    /// documents other tools write expect, so 1 is kept.
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
    /// when an item at index `usedLevel` appears (ISO/IEC 29500-1, `w:lvlRestart`).
    /// Only a shallower item restarts a level. By default any shallower
    /// item does; a restart value of n restarts it after an item at
    /// one-based level n or shallower, and 0 never. A value naming this
    /// level or a deeper one names no level that could restart it, so it is
    /// ignored and the default applies.
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
/// (`w:lvlOverride` in ISO/IEC 29500-1).
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

// MARK: - List Numbers

/// Numbers a document's list paragraphs in reading order, as Word numbers
/// them (ISO/IEC 29500-1 §17.9):
/// - The instances of one abstract definition share their counts, so a
///   list Word splits across instances numbers on across them. An instance
///   that overrides a level's start (with a start override or a replacement
///   level) starts that level afresh when its first paragraph appears,
///   which is how Word stores Restart Numbering; later paragraphs of any
///   instance count on from there. The standard counts per abstract
///   definition (its example for `w:start`) without spelling out how
///   instances share a count; this follows Word as it is observed to number.
/// - A level counts on from its start value, one item at a time.
/// - Every item starts afresh the deeper levels that restart after it
///   (`ListLevelFormat.restarts(level:afterItemAt:)`).
struct DOCXListCounter {
    /// The list definitions the paragraphs refer to.
    let numbering: DOCXNumbering
    /// The number last given at each level, by counter key. A level with no
    /// number gives its next item its start value.
    private var counts: [String: [Int: Int]] = [:]
    /// The list instances whose first paragraph has been numbered.
    private var startedInstances: Set<String> = []

    init(numbering: DOCXNumbering) {
        self.numbering = numbering
    }

    /// The marker of the next paragraph of list instance `numId` at
    /// `level`: its number, or a bullet when that level is bulleted or not
    /// defined. Either way the item starts afresh the deeper levels that
    /// restart after it.
    mutating func marker(numId: String, level: Int) -> DOCXListMarker {
        let key = numbering.counterKey(numId: numId)
        var levels = counts[key] ?? [:]
        if startedInstances.insert(numId).inserted {
            // An overridden level starts afresh, and with it the levels
            // below it, as though an item at that level had appeared.
            for overridden in numbering.restartedLevels(numId: numId) {
                levels[overridden] = nil
                restartLevels(deeperThan: overridden, of: numId, in: &levels)
            }
        }
        restartLevels(deeperThan: level, of: numId, in: &levels)

        var marker = DOCXListMarker.bullet
        if let format = numbering.levelFormat(numId: numId, level: level), format.listType == .numbered {
            let number = Self.number(after: levels[level], start: format.start)
            levels[level] = number
            marker = .number(number)
        }
        counts[key] = levels
        return marker
    }

    /// The marker of the next paragraph numbered by its paragraph style
    /// alone (a "List Number" style, naming no list instance): each such
    /// style counts as a list of one level, from 1.
    mutating func marker(numberedStyle styleId: String) -> DOCXListMarker {
        let key = "style:" + styleId
        let number = Self.number(after: counts[key]?[0], start: 1)
        counts[key] = [0: number]
        return .number(number)
    }

    /// The number last given at `level` in the list of instance `numId`, or
    /// nil if that level has not been counted since it started. A level's
    /// number text can name the number of a more significant level (the
    /// "1" of "1.2"), which is this.
    func lastNumber(numId: String, level: Int) -> Int? {
        counts[numbering.counterKey(numId: numId)]?[level]
    }

    /// Gives every level more significant than `level` of the list of
    /// instance `numId` that has no count its start value, as Word does when a
    /// less significant level comes first: a "1.1" before any "1" has a "1"
    /// before it, and the next "1" level is the second (Microsoft KB Q197139).
    /// The DOCX reader does not call this.
    mutating func startLevels(moreSignificantThan level: Int, numId: String) {
        let key = numbering.counterKey(numId: numId)
        var levels = counts[key] ?? [:]
        for shallower in 0..<max(level, 0) where levels[shallower] == nil {
            if let format = numbering.levelFormat(numId: numId, level: shallower) { levels[shallower] = format.start }
        }
        counts[key] = levels
    }

    /// Forget the counts of list instance `numId`, so it starts again from its start value.
    mutating func restart(numId: String) {
        counts[numbering.counterKey(numId: numId)] = nil
        startedInstances.remove(numId)
    }

    /// Forget every count, so each list starts again from its start value.
    mutating func restartAll() {
        counts.removeAll()
    }

    /// Clear the counts of the levels deeper than `level` that restart
    /// after an item at `level`, by the definitions list instance `numId`
    /// gives them. A level the instance does not define restarts, as a
    /// level does by default.
    private func restartLevels(deeperThan level: Int, of numId: String, in levels: inout [Int: Int]) {
        for deeper in levels.keys.filter({ $0 > level }) {
            let format = numbering.levelFormat(numId: numId, level: deeper)
            if format?.restarts(level: deeper, afterItemAt: level) ?? true {
                levels[deeper] = nil
            }
        }
    }

    /// The number after `previous`, held to the largest a list item can
    /// show, or `start` when the level has not counted since it started.
    private static func number(after previous: Int?, start: Int) -> Int {
        previous.map { min($0 + 1, ListLevelFormat.largestNumber) } ?? start
    }
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
            // ISO/IEC 29500-1 (w:numFmt): a level that names no number format
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
