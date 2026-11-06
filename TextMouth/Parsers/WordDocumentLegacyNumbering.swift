import Foundation

// MARK: - Numbering in Word 6 and Word 95

/// The numbering of a Word 6 or Word 95 document. These versions have no
/// list tables: a numbered paragraph carries its own description of its
/// number, an `ANLD` of 52 bytes (`sprmPAnld`), and the level it is at
/// (`sprmPNLvlAnm`, 1 to 9 for an outline, 10 for a simple list). The reader
/// gives each different `ANLD` a list instance of its own, and lets the
/// numbering that Word 97 has (`WordListNumbering`) count it, so a
/// paragraph's number is written, or kept silent, by the same switch
/// (`WordDocumentReader.speaksListNumbers`) as a Word 97 document's.
///
/// What it does not follow: the numbering a style carries (`ANLD`s in a
/// style's properties), and a count that runs on from an outline level to
/// another level with a different `ANLD` (each different `ANLD` counts
/// alone). Both only change the numbers a listener hears, when they are
/// heard; which paragraphs are items of a list is right either way.
///
/// The `ANLD` ([MS-DOC] 2.9.23 describes Word 97's, which has the same
/// fields in 84 bytes; the older one is 52 bytes, read from real files): the
/// number format (0 Arabic, 1 and 2 upper- and lower-case Roman numerals, 3
/// and 4 upper- and lower-case letters, 5 ordinal, 255 a bullet), the count of
/// characters of text before and after the number, three bytes of flags, a
/// font and a size, the number the count starts at (a 16-bit one, at 10), the
/// indent and the space, four flag bytes, and the text before and after in
/// 32 bytes (at 20).
enum WordLegacyNumbering {

    /// The size of an `ANLD`, in bytes.
    private static let anldSize = 52

    /// `paragraphs`, with each numbered paragraph's list instance and level
    /// set, and the tables of the instances. A paragraph with an `ANLD` of
    /// the wrong size, or at a level of 0 or past 10 (not numbered), is not
    /// in a list.
    /// - Parameter characters: how the `ANLD`'s text is read.
    static func apply(
        to paragraphs: WordFormatRuns<WordParagraphFormat>, characters: WordLegacyCharacters
    ) -> (paragraphs: WordFormatRuns<WordParagraphFormat>, lists: WordListTables) {
        var instances: [[UInt8]: Int] = [:]
        var levels: [[WordListLevel]] = []
        let runs = paragraphs.runs.map { run -> WordFormatRuns<WordParagraphFormat>.Run in
            guard let anld = run.format.legacyNumbering else { return run }
            var format = run.format
            format.legacyNumbering = nil
            let outline = format.legacyNumberingLevel ?? 10
            format.legacyNumberingLevel = nil
            guard anld.count == anldSize, (1...10).contains(outline) else { return .init(range: run.range, format: format) }
            // The level an outline's number is at; a simple list is the first.
            let level = outline == 10 ? 0 : outline - 1
            let instance: Int
            if let known = instances[anld] {
                instance = known
            } else if levels.count < 0x07FE {
                levels.append(self.levels(of: anld, characters: characters))
                instance = levels.count
                instances[anld] = instance
            } else {
                return .init(range: run.range, format: format)
            }
            format.listIndex = instance
            format.listLevel = level
            return .init(range: run.range, format: format)
        }
        return (WordFormatRuns(runs: runs), levels.isEmpty ? .none : WordListTables(legacyInstances: levels))
    }

    /// The nine levels of the list an `ANLD` describes: each the number the
    /// `ANLD` gives, at that level, which is the one level a paragraph
    /// uses, so that the placeholder stands for the paragraph's own level.
    private static func levels(of anld: [UInt8], characters: WordLegacyCharacters) -> [WordListLevel] {
        let format = Int(anld[0])
        let before = min(Int(anld[1]), 32)
        let after = min(Int(anld[2]), 32 - before)
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
        return (0..<WordListTables.levelCount).map { level in
            // The text before, the number's place (one-based, naming the level), the text after.
            let shown = Array(text[0..<before]) + [UInt16(level)] + Array(text[before..<before + after])
            return WordListLevel(
                numberFormat: numberFormat, start: min(start, 0x7FFF), restartLimit: nil, isLegal: false,
                numberIsHidden: false, text: shown, placeholders: [before + 1]
            )
        }
    }
}
