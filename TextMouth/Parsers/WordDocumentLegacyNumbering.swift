import Foundation

// MARK: - Numbering in Word 6 and Word 95

/// The numbering of a Word 6 or Word 95 document. These versions have no
/// list tables: a numbered paragraph carries its own description of its
/// number, an `ANLD` of 52 bytes (`sprmPAnld`), and the level it is at
/// (`sprmPNLvlAnm`: 1 to 9 for an outline, 10 for a simple list, 11 for a
/// bullet), taken from the paragraph or else from its style. A paragraph with
/// an `ANLD` and no level, directly or by style, is not numbered: its `ANLD`
/// is left over from an earlier numbering, and 1,589 paragraphs in 22 real
/// files are so (many begin with a number typed by hand).
///
/// The reader turns this into the list tables Word 97 has, and lets the
/// numbering that Word 97 has (`WordListNumbering`) count it, so a paragraph's
/// number is written, or kept silent, by the same switch
/// (`WordDocumentReader.speaksListNumbers`) as a Word 97 document's:
/// - the outline levels 1 to 9 of a document are one list, each level
///   defined by the `ANLD` of the first paragraph at it, and counted as an
///   outline is: a level begins again after a more significant one, and a
///   level whose `ANLD` says "include previous" (`fPrev`) writes the number
///   of the level above first ("2" and then ".1" is "2.1");
/// - each different `ANLD` of a simple list or a bullet is a list of its own,
///   which begins again at the number it starts at after a paragraph of
///   ordinary text.
///
/// What it does not follow: the numbering a style carries (`ANLD`s in a
/// style's properties). A numbered heading by style reads without its number.
///
/// The `ANLD` ([MS-DOC] 2.9.23 describes Word 97's, which has the same
/// fields in 84 bytes; the older one is 52 bytes, read from real files): the
/// number format (0 Arabic, 1 and 2 upper- and lower-case Roman numerals, 3
/// and 4 upper- and lower-case letters, 5 ordinal, 255 a bullet), the count of
/// characters of text before and after the number, three bytes of flags (the
/// third of which holds `fPrev` as its bit 2), a font and a size, the number
/// the count starts at (a 16-bit one, at 10), the indent and the space, four
/// flag bytes, and the text before and after in 32 bytes (at 20).
enum WordLegacyNumbering {

    /// The size of an `ANLD`, in bytes.
    private static let anldSize = 52
    /// The levels of an outline, and the levels past them: 10 for a simple list, 11 for a bullet.
    private static let outlineLevels = 1...9
    private static let numberedLevels = 1...11

    /// The list a numbered paragraph is in.
    private enum Kind: Hashable {
        /// The outline, one list for the document.
        case outline
        /// A simple list or a bullet, by its `ANLD`.
        case simple([UInt8])
    }

    /// `paragraphs`, with each numbered paragraph's list instance and level
    /// set, and the tables of the instances. A paragraph with an `ANLD` of
    /// the wrong size, or at a level of none (or past 11), is not in a list.
    /// - Parameters:
    ///   - characters: how the `ANLD`'s text is read.
    ///   - styles: where a paragraph that names no level of its own finds its style's.
    static func apply(
        to paragraphs: WordFormatRuns<WordParagraphFormat>, characters: WordLegacyCharacters, styles: WordStyleSheet
    ) -> (paragraphs: WordFormatRuns<WordParagraphFormat>, lists: WordListTables) {
        var kinds: [Kind] = []
        var instanceOfKind: [Kind: Int] = [:]
        // The `ANLD` of the first paragraph at each outline level, which defines the level.
        var outline: [Int: [UInt8]] = [:]
        let runs = paragraphs.runs.map { run -> WordFormatRuns<WordParagraphFormat>.Run in
            guard let anld = run.format.legacyNumbering else { return run }
            var format = run.format
            format.legacyNumbering = nil
            let direct = format.legacyNumberingLevel
            format.legacyNumberingLevel = nil
            // The level: the paragraph's own, else its style's, else none.
            let numbered = direct ?? styles.numberingLevel(styleIndex: format.style) ?? 0
            guard anld.count == anldSize, numberedLevels.contains(numbered) else { return .init(range: run.range, format: format) }
            let kind: Kind = outlineLevels.contains(numbered) ? .outline : .simple(anld)
            let level = outlineLevels.contains(numbered) ? numbered - 1 : 0
            let instance: Int
            if let known = instanceOfKind[kind] {
                instance = known
            } else if kinds.count < WordListTables.mostInstances {
                kinds.append(kind)
                instance = kinds.count
                instanceOfKind[kind] = instance
            } else {
                return .init(range: run.range, format: format)
            }
            if case .outline = kind, outline[level] == nil { outline[level] = anld }
            format.listIndex = instance
            format.listLevel = level
            return .init(range: run.range, format: format)
        }
        guard !kinds.isEmpty else { return (WordFormatRuns(runs: runs), .none) }

        // The tables: nine levels for each list.
        let levels = kinds.map { kind -> [WordListLevel] in
            switch kind {
            case .outline:
                return (0..<WordListTables.levelCount).map { level in
                    outline[level].map { self.level(of: $0, at: level, characters: characters) } ?? defaultLevel(at: level)
                }
            case .simple(let anld):
                return (0..<WordListTables.levelCount).map { self.level(of: anld, at: $0, characters: characters) }
            }
        }
        let simple = Set(kinds.enumerated().compactMap { entry -> Int? in
            if case .simple = entry.element { return entry.offset + 1 }
            return nil
        })
        return (WordFormatRuns(runs: runs), WordListTables(legacyInstances: levels, endedByPlainText: simple))
    }

    /// The level `level` (0 to 8) that the `ANLD` `anld` describes: its number in its format, the text before
    /// and after it, where it starts, and, when the `ANLD` includes the previous level (`fPrev`) and there is one,
    /// the number of the level above first.
    private static func level(of anld: [UInt8], at level: Int, characters: WordLegacyCharacters) -> WordListLevel {
        let format = Int(anld[0])
        let before = min(Int(anld[1]), 32)
        let after = min(Int(anld[2]), 32 - before)
        let includesPrevious = anld[3] & 0x04 != 0 && level > 0
        let start = Int(anld[10]) | Int(anld[11]) << 8
        let text = anld[20..<52].map { characters.unit(ofByte: $0) }
        // Word 97's numbers: 0 to 4 are the same; an ordinal is read in Arabic numerals,
        // and anything past the five (255) is a bullet.
        let numberFormat: Int
        switch format {
        case 0...4: numberFormat = format
        case 5: numberFormat = 0
        default: numberFormat = 0x17
        }
        // The previous level's place (naming that level), the text before, this level's place, the text after.
        var shown: [UInt16] = []
        var places: Set<Int> = []
        if includesPrevious {
            shown.append(UInt16(level - 1))
            places.insert(shown.count)
        }
        shown += text[0..<before]
        shown.append(UInt16(level))
        places.insert(shown.count)
        shown += text[before..<before + after]
        return WordListLevel(
            numberFormat: numberFormat, start: min(start, 0x7FFF), restartLimit: nil, isLegal: false,
            numberIsHidden: false, text: shown, placeholders: places
        )
    }

    /// The level of an outline that no paragraph of the document defines: Arabic numbers and a full stop.
    private static func defaultLevel(at level: Int) -> WordListLevel {
        WordListLevel(
            numberFormat: 0, start: 1, restartLimit: nil, isLegal: false, numberIsHidden: false,
            text: [UInt16(level), 0x2E], placeholders: [1]
        )
    }
}
