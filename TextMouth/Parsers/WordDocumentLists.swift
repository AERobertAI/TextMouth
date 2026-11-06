import Foundation

// MARK: - A Level of a List

/// One level of a list of a Word 97-2003 document: the `LVL` of [MS-DOC]
/// 2.9.149, with the parts this reader uses. A level says how its items are
/// numbered (or that they are bullets, or are not numbered), where its count
/// begins and when it begins again, and the text that stands before an item:
/// the level's number text, with a placeholder where the number of a level
/// goes.
struct WordListLevel {

    /// The number format of the level, an MSONFC ([MS-OSHARED] 2.2.1.3):
    /// 0 Arabic numerals, 1 and 2 upper- and lower-case Roman numerals, 3
    /// and 4 upper- and lower-case letters, 0x16 Arabic with a leading zero,
    /// 0x17 a bullet, and 0xFF no number; others (ordinals and words, the
    /// numerals of other scripts) are written in Arabic numerals, as page
    /// numbers in those formats are (`DOCXPageNumberFormat`).
    let numberFormat: Int
    /// The number the level counts from (`iStartAt`), held to what a list
    /// item can show.
    let start: Int
    /// When the level counts from its start again: nil for after any more
    /// significant level; otherwise `ilvlRestartLim`, the level from which on
    /// a more significant item no longer restarts it (`fNoRestart`), 0 being never.
    let restartLimit: Int?
    /// Whether the level writes every number it names in Arabic numerals
    /// (`fLegal`: "1.1.2" in legal documents, whatever the levels' own formats).
    let isLegal: Bool
    /// Whether the number is hidden text (`sprmCFVanish` in the level's
    /// character properties): it counts but is not shown.
    let numberIsHidden: Bool
    /// The characters of the number text (`xst`), at most `longestText`.
    let text: [UInt16]
    /// The one-based positions in `text` of the placeholders (`rgbxchNums`,
    /// up to its first zero); the character at each is the level it stands for.
    let placeholders: Set<Int>

    /// The most characters of number text kept: a level's text is short, and
    /// a file could ask for 64 thousand, for every paragraph.
    static let longestText = 255

    /// Whether the level's items are bullets (no number is written).
    var isBullet: Bool { numberFormat == 0x17 }
    /// Whether the level numbers nothing.
    var hasNoNumber: Bool { numberFormat == 0xFF }

    /// The name of the format as the DOCX numbering part names it
    /// (`w:numFmt`), which is how the shared counters and
    /// `DOCXPageNumberFormat` know it.
    var formatName: String {
        switch numberFormat {
        case 1: return "upperRoman"
        case 2: return "lowerRoman"
        case 3: return "upperLetter"
        case 4: return "lowerLetter"
        case 0x17: return "bullet"
        case 0xFF: return "none"
        default: return "decimal"
        }
    }

    /// The level as the shared counters (`DOCXListCounter`) take it.
    var counterFormat: ListLevelFormat {
        ListLevelFormat(numFmt: formatName, start: start, restartAfter: restartLimit)
    }

    /// `number` written in this level's format, or in Arabic numerals when
    /// `legal` says so (`fLegal`; a leading zero is kept).
    func label(forNumber number: Int, legal: Bool) -> String {
        if numberFormat == 0x16 { return number < 10 ? "0\(number)" : String(number) }
        return DOCXPageNumberFormat(legal ? "decimal" : formatName).label(forNumber: number)
    }

    // MARK: Reading

    /// Reads the `LVL` at `position` in `table`, and returns it with the
    /// position after it. An `LVL` is an `LVLF` of 28 bytes, the property
    /// lists of the paragraph and of the number's characters (sized by the
    /// `LVLF`), and the number text: a 16-bit length and that many UTF-16
    /// characters.
    /// - Throws: `OLEDamage` for a level that runs past the table stream.
    static func read(at position: Int, in table: OLEBytes) throws -> (level: WordListLevel, end: Int) {
        let flags = try table.u8(position + 5)
        let sizeOfCharacterProperties = try table.u8(position + 24)
        let sizeOfParagraphProperties = try table.u8(position + 25)
        let restartLimit = try table.u8(position + 26)
        // rgbxchNums: nine one-based positions, ending at the first zero.
        var placeholders: Set<Int> = []
        for offset in 6..<15 {
            let place = try table.u8(position + offset)
            if place == 0 { break }
            placeholders.insert(place)
        }
        // The text follows the property lists: the paragraph's, then the number's characters'.
        let textStart = position + 28 + sizeOfParagraphProperties + sizeOfCharacterProperties
        var numberIsHidden = false
        WordSprm.forEach(in: try table.slice(offset: position + 28 + sizeOfParagraphProperties, length: sizeOfCharacterProperties)) { opcode, operand in
            // A toggle, with no style under it: 1 and 0x81 hide.
            if opcode == WordSprm.hidden, let value = operand.first { numberIsHidden = value == 1 || value == 0x81 }
        }
        let count = try table.u16(textStart)
        let characters = try table.slice(offset: textStart + 2, length: count * 2)
        let text = stride(from: 0, to: min(count, longestText) * 2, by: 2).map { index -> UInt16 in
            UInt16(characters[characters.startIndex + index]) | UInt16(characters[characters.startIndex + index + 1]) << 8
        }
        let start = try table.u32(position)
        // The start is a signed 32-bit number that the specification holds to 0 through 0x7FFF.
        let signedStart = start >= 0x8000_0000 ? 0 : min(start, 0x7FFF)
        let level = WordListLevel(
            numberFormat: try table.u8(position + 4),
            start: signedStart,
            // fNoRestart is bit 3 of the flags (bits 0 and 1 are the justification, bit 2 fLegal).
            restartLimit: flags & 0x08 != 0 ? restartLimit : nil,
            isLegal: flags & 0x04 != 0,
            numberIsHidden: numberIsHidden,
            text: text,
            placeholders: placeholders
        )
        return (level, textStart + 2 + count * 2)
    }
}

// MARK: - The List Tables

/// The lists of a Word 97-2003 document: the list table (`PlfLst`, [MS-DOC]
/// 2.9.201), which defines each list's levels, and the list override table
/// (`PlfLfo`, 2.9.200), by which a paragraph names the list it is in
/// (`sprmPIlfo`, an index into the overrides) and which may start a level
/// again or replace it.
///
/// Word stores no number in the text of a numbered paragraph, so the numbers
/// are made from these tables and the paragraphs that name them
/// (`WordListNumbering`). Every length and count is checked.
struct WordListTables {

    // MARK: Fields

    /// How a list instance (`LFO`) changes one level of its list.
    struct Override {
        /// The number the level starts from here (`LFOLVL.fStartAt`), if it does.
        let startAt: Int?
        /// The level in place of the list's own (`LFOLVL.fFormatting`), if one.
        let level: WordListLevel?
    }

    /// One list instance: the list it uses, and its changes to the list's levels.
    struct Instance {
        /// The identifier of the list (`lsid`).
        let listIdentifier: Int
        /// The changes, by level.
        let overrides: [Int: Override]
    }

    /// The levels of each list (one for a simple list, nine otherwise), by list identifier.
    private let lists: [Int: [WordListLevel]]
    /// The list instances, in order: `sprmPIlfo` is a one-based index.
    private let instances: [Instance]

    /// A document with no lists.
    static let none = WordListTables()

    private init() {
        lists = [:]
        instances = []
    }

    /// Whether the document has no list a paragraph could be in.
    var isEmpty: Bool { instances.isEmpty || lists.isEmpty }

    /// The most levels a list has.
    static let levelCount = 9
    /// The most list instances a paragraph can name (`sprmPIlfo`, 0x07FE).
    static let mostInstances = 0x07FE

    // MARK: Reading

    /// Reads the tables.
    /// - Parameters:
    ///   - listFormats: where the `PlfLst` lies in `table`: a 16-bit count and
    ///     that many `LSTF`s of 28 bytes. The `LVL`s of the lists follow it
    ///     directly, outside the range the file's header gives for it.
    ///   - listOverrides: where the `PlfLfo` lies in `table`: a 32-bit count,
    ///     that many `LFO`s of 16 bytes, and an `LFOData` for each.
    /// - Throws: `OLEDamage` for a count or level that does not fit.
    init(listFormats: Range<Int>?, listOverrides: Range<Int>?, table: OLEBytes) throws {
        var lists: [Int: [WordListLevel]] = [:]
        if let listFormats {
            let count = try table.i16(listFormats.lowerBound)
            guard count >= 0, 2 + count * 28 <= listFormats.count else { throw OLEDamage(reason: "the list table holds \(count) lists") }
            // The LVLs, in the order of the lists: one for a simple list, else nine.
            var position = listFormats.upperBound
            for index in 0..<count {
                let entry = listFormats.lowerBound + 2 + index * 28
                let identifier = Int(Int32(truncatingIfNeeded: try table.u32(entry)))
                let isSimple = try table.u8(entry + 26) & 1 != 0
                var levels: [WordListLevel] = []
                for _ in 0..<(isSimple ? 1 : Self.levelCount) {
                    let read = try WordListLevel.read(at: position, in: table)
                    levels.append(read.level)
                    position = read.end
                }
                lists[identifier] = levels
            }
        }

        var instances: [Instance] = []
        if let listOverrides {
            let count = try table.u32(listOverrides.lowerBound)
            guard 4 + count * 16 <= listOverrides.count else { throw OLEDamage(reason: "the list override table holds \(count) lists") }
            // The LFODatas follow the LFOs, one for each. Only the first 0x7FE
            // instances can be named (`sprmPIlfo`), so no more are kept: a file
            // that claims millions costs nothing.
            var position = listOverrides.lowerBound + 4 + count * 16
            for index in 0..<min(count, Self.mostInstances) {
                let entry = listOverrides.lowerBound + 4 + index * 16
                let identifier = Int(Int32(truncatingIfNeeded: try table.u32(entry)))
                let overrideCount = try table.u8(entry + 12)
                // An LFOData: a 32-bit position we skip, and an LFOLVL for each override.
                position += 4
                var overrides: [Int: Override] = [:]
                for _ in 0..<overrideCount {
                    let startAt = Int(Int32(truncatingIfNeeded: try table.u32(position)))
                    let flags = try table.u32(position + 4)
                    position += 8
                    var level: WordListLevel?
                    if flags & 0x20 != 0 {
                        // fFormatting: the level in full follows.
                        let read = try WordListLevel.read(at: position, in: table)
                        level = read.level
                        position = read.end
                    }
                    guard position <= listOverrides.upperBound else { throw OLEDamage(reason: "a list override runs past its table") }
                    let levelIndex = flags & 0x0F
                    if levelIndex < Self.levelCount {
                        // With a level in full, its own start counts: the LFOLVL's iStartAt MUST be ignored.
                        overrides[levelIndex] = Override(
                            startAt: flags & 0x10 != 0 && level == nil ? min(max(startAt, 0), 0x7FFF) : nil, level: level
                        )
                    }
                }
                guard position <= listOverrides.upperBound else { throw OLEDamage(reason: "a list override runs past its table") }
                instances.append(Instance(listIdentifier: identifier, overrides: overrides))
            }
        }
        self.lists = lists
        self.instances = instances
    }

    // MARK: Asking

    /// The level `level` (0 to 8) of list instance `instance` (one-based, as
    /// `sprmPIlfo` counts): the instance's own definition of it, if it has
    /// one, or else its list's. Nil when the instance, its list, or the level
    /// does not exist.
    func level(instance: Int, level: Int) -> WordListLevel? {
        guard instance >= 1, instance <= instances.count else { return nil }
        let entry = instances[instance - 1]
        if let replacement = entry.overrides[level]?.level { return replacement }
        guard let levels = lists[entry.listIdentifier], level >= 0, level < levels.count else { return nil }
        return levels[level]
    }

    /// The tables as the shared counters (`DOCXListCounter`) take them: each
    /// list is an abstract definition named by its identifier, and each
    /// instance a list instance named by its one-based index, with the
    /// levels it starts again or replaces. Word counts the paragraphs of one
    /// list together whichever instance they name, and so do the counters.
    var numbering: DOCXNumbering {
        var numbering = DOCXNumbering()
        for (identifier, levels) in lists {
            numbering.abstractNums[String(identifier)] = Dictionary(
                uniqueKeysWithValues: levels.enumerated().map { ($0.offset, $0.element.counterFormat) }
            )
        }
        for (index, instance) in instances.enumerated() {
            let name = String(index + 1)
            numbering.numIdToAbstractId[name] = String(instance.listIdentifier)
            let overrides = instance.overrides.mapValues { entry in
                ListLevelOverride(startOverride: entry.startAt, level: entry.level?.counterFormat)
            }
            if !overrides.isEmpty { numbering.levelOverrides[name] = overrides }
        }
        return numbering
    }

    // MARK: Paragraphs

    /// The one-based list instance a paragraph's `sprmPIlfo` value `raw`
    /// (a signed 16-bit number) names ([MS-DOC] 2.6.2), or nil for none: 0
    /// and 0xF801 are not in a list; a positive value up to 0x07FE is an
    /// index; a negative value down to 0xF802 is the negation of one, with
    /// the paragraph's indents kept (which does not matter here).
    static func instanceNumber(ofIlfo raw: Int) -> Int? {
        let signed = raw >= 0x8000 ? raw - 0x10000 : raw
        if (1...0x07FE).contains(signed) { return signed }
        if (-0x07FE ... -1).contains(signed) { return -signed }
        return nil
    }
}

// MARK: - Numbering the Paragraphs

/// Numbers the paragraphs of a document that are in lists, in the order they
/// come, as Word does ([MS-DOC] 2.4.6.4): the paragraphs of one list count
/// together, a level counts on one paragraph at a time from its start, a
/// more significant level starts the less significant ones again, and an
/// instance that overrides a level starts it again. The counting is
/// `DOCXListCounter`'s, which the DOCX reader numbers its lists with, so a
/// number is the same in both formats.
///
/// Every paragraph in a list is counted and restarts the levels under it,
/// whatever its level shows: a level of bullets or of no number sequence
/// counts too (the specification's step 8 tests only the level). A level
/// that comes before any more significant one takes that one to be at its
/// start, so the next of the more significant level is the second, as Word
/// numbers it (KB Q197139).
///
/// Unlike the DOCX reader, which writes a Markdown list and starts every
/// list again after a paragraph that is not in one, this keeps counting:
/// Word does, and a chapter's number must not start again at each chapter's
/// body text.
struct WordListNumbering {

    /// What stands before a paragraph.
    enum Marker: Equatable {
        /// Nothing: the paragraph is not in a list, or its level shows nothing.
        case none
        /// A bullet.
        case bullet
        /// A number, as the level's text writes it ("1.2.", "Article IV",
        /// "(a)"); empty when the level's number is hidden text.
        case numbered(String)
        /// A level with no number sequence whose text is words ("Note:"): the
        /// words, and no number.
        case labelled(String)
    }

    private let tables: WordListTables
    private var counter: DOCXListCounter

    /// A numbering that has counted nothing yet.
    init(tables: WordListTables) {
        self.tables = tables
        counter = DOCXListCounter(numbering: tables.numbering)
    }

    /// Whether no paragraph can be in a list.
    var isEmpty: Bool { tables.isEmpty }

    /// The marker of the next paragraph, which is in list instance
    /// `instance` (one-based) at `level` (0 to 8). It counts the paragraph,
    /// so each paragraph of a list must be asked about once, in order.
    mutating func marker(instance: Int, level: Int) -> Marker {
        guard let definition = tables.level(instance: instance, level: level) else { return .none }
        let name = String(instance)
        // Count the paragraph first, whatever its level shows, so that it
        // restarts the levels under it and the levels over it have a count.
        let counted = counter.marker(numId: name, level: level)
        counter.startLevels(moreSignificantThan: level, numId: name)
        if definition.isBullet { return .bullet }

        // The level's text, with each placeholder replaced by the number of
        // the level it names: this paragraph's, or the latest of a more
        // significant level. A placeholder of a level with no number
        // sequence (a bullet, or none) is ignored ([MS-DOC] LVL).
        var written: [UInt16] = []
        for (index, unit) in definition.text.enumerated() {
            guard definition.placeholders.contains(index + 1) else {
                // Controls (the unused placeholders) are not words.
                if unit >= 0x20 { written.append(unit) }
                continue
            }
            let named = Int(unit)
            // A placeholder for a less significant level cannot be filled: the file is invalid.
            guard named <= level, let namedLevel = tables.level(instance: instance, level: named),
                  !namedLevel.isBullet, !namedLevel.hasNoNumber else { continue }
            let value: Int
            if named == level {
                guard case .number(let number) = counted else { continue }
                value = number
            } else {
                guard let latest = counter.lastNumber(numId: name, level: named) else { continue }
                value = latest
            }
            written += Array(namedLevel.label(forNumber: value, legal: definition.isLegal).utf16)
        }
        var text = String(decoding: written, as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // A number that is hidden text is counted and not shown.
        if definition.numberIsHidden { text = "" }
        if definition.hasNoNumber { return text.isEmpty ? .none : .labelled(text) }
        return .numbered(text)
    }
}
