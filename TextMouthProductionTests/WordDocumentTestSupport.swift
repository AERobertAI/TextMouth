import Foundation
import SwiftSoup
import XCTest
@testable import TextMouth

// MARK: - Building Word 97-2003 Documents in Code

/// Writes a Word 97-2003 document ([MS-DOC]) from a description of its
/// paragraphs, runs, styles, and sections, so a test can make the documents
/// it reads and damage them at places it knows. It writes what the reader
/// reads: the FIB, the piece table (one piece, or several stored in reverse
/// order, as Fast Save leaves them), the style sheet, the paragraph and
/// character bin tables with their formatted disk pages, the section table,
/// and the SummaryInformation stream; the compound file is
/// `CompoundFileBuilder`'s.
struct WordDocumentBuilder {

    // MARK: The Description

    /// A run of text with one set of character properties.
    struct Run {
        var text: String
        /// The direct bold, italic, and hidden-text properties: 0, 1, 0x80, or 0x81.
        var bold: Int?
        var italic: Int?
        var hidden: Int?
        /// The character style's index.
        var characterStyle: Int?
        /// Other modifiers, as bytes.
        var extraModifiers: [UInt8] = []
        /// Whether the run is marked special (`sprmCFSpec`).
        var isSpecial = false
        /// The font size in half-points.
        var fontSize: Int?
        /// Whether the run is a tracked deletion (`sprmCFRMarkDel`).
        var isDeleted = false

        init(
            _ text: String, bold: Int? = nil, italic: Int? = nil, hidden: Int? = nil,
            characterStyle: Int? = nil, fontSize: Int? = nil
        ) {
            self.hidden = hidden
            self.fontSize = fontSize
            self.text = text
            self.bold = bold
            self.italic = italic
            self.characterStyle = characterStyle
        }
    }

    /// A paragraph: runs of text and the mark that ends it.
    struct Paragraph {
        var runs: [Run]
        /// The paragraph's style index.
        var style = 0
        /// Paragraph modifiers, as bytes.
        var modifiers: [UInt8] = []
        /// The character that ends the paragraph.
        var mark: UInt16 = 0x0D
        /// The character modifiers of the mark itself, as bytes (a hidden
        /// paragraph mark, for one); none leaves the mark without properties.
        var markModifiers: [UInt8] = []

        init(_ text: String, style: Int = 0, modifiers: [UInt8] = [], mark: UInt16 = 0x0D, markModifiers: [UInt8] = []) {
            runs = [Run(text)]
            self.style = style
            self.modifiers = modifiers
            self.mark = mark
            self.markModifiers = markModifiers
        }

        init(runs: [Run], style: Int = 0, modifiers: [UInt8] = [], mark: UInt16 = 0x0D, markModifiers: [UInt8] = []) {
            self.runs = runs
            self.style = style
            self.modifiers = modifiers
            self.mark = mark
            self.markModifiers = markModifiers
        }
    }

    /// A style of the style sheet.
    struct Style {
        var builtInIdentifier = 0xFFE
        /// 1 for a paragraph style, 2 for a character style.
        var kind = 1
        var basedOn: Int?
        var outlineLevel: Int?
        var bold: Int?
        var italic: Int?
        var hidden: Int?
        var fontSize: Int?
        /// The style's page-break-before setting (0 or 1).
        var pageBreakBefore: Int?
        /// The style's list instance (`sprmPIlfo`) and level (`sprmPIlvl`).
        var listIndex: Int?
        var listLevel: Int?
    }

    /// One level of a list: its number format (an MSONFC), where it counts
    /// from, and its number text, in which "%1" to "%9" stand for the numbers
    /// of levels 1 to 9.
    struct ListLevel {
        var numberFormat = 0
        var start = 1
        var text = ""
        /// `ilvlRestartLim` when `fNoRestart` is on.
        var restartLimit: Int?
        var isLegal = false
        /// Whether the number is hidden text (`sprmCFVanish` in the level's character properties).
        var numberIsHidden = false

        init(
            _ numberFormat: Int = 0, _ text: String = "", start: Int = 1, restartLimit: Int? = nil, isLegal: Bool = false,
            numberIsHidden: Bool = false
        ) {
            self.numberFormat = numberFormat
            self.text = text
            self.start = start
            self.restartLimit = restartLimit
            self.isLegal = isLegal
            self.numberIsHidden = numberIsHidden
        }
    }

    /// A list: its identifier and its levels (nine, or one if simple).
    struct List {
        var identifier: Int
        var levels: [ListLevel]
        var isSimple = false
    }

    /// A change a list instance makes to one level of its list.
    struct ListOverride {
        var level: Int
        /// `LFOLVL.iStartAt`, with `fStartAt` set, if given.
        var startAt: Int?
        /// A level in full (`fFormatting`), if given.
        var replacement: ListLevel?
    }

    /// A list instance (`LFO`): the list it uses and its overrides.
    struct ListInstance {
        var listIdentifier: Int
        var overrides: [ListOverride] = []
    }


    /// The stories of a document after the main one, in the order the file
    /// stores them: the CP ranges of their lengths are the FIB's ccpFtn,
    /// ccpHdd, ccpAtn, ccpEdn, ccpTxbx, and ccpHdrTxbx.
    enum Story: Int, CaseIterable {
        case footnotes, headers, comments, endnotes, textBoxes, headerTextBoxes

        /// The offset in the FIB of the story's length (ccpFtn is at 80, ccpHdd
        /// at 84, then ccpMcr at 88, which these builds leave 0).
        var lengthOffset: Int {
            switch self {
            case .footnotes: return 80
            case .headers: return 84
            case .comments: return 92
            case .endnotes: return 96
            case .textBoxes: return 100
            case .headerTextBoxes: return 104
            }
        }
    }

    var paragraphs: [Paragraph] = []
    /// The paragraphs of the stories other than the main one.
    var stories: [Story: [Paragraph]] = [:]
    /// The style sheet; the default is Normal and Heading 1 to 9 at indexes 0 to 9.
    var styles: [Style?] = WordDocumentBuilder.standardStyles
    /// How each section after the first begins (`sprmSBkc`), keyed by the
    /// index of the paragraph that ends the section before it; nil leaves out
    /// the modifier.
    var sectionBreaks: [(endingParagraph: Int, nextKind: Int?)] = []
    /// Whether the text is stored one byte per character (it must then be Latin-1).
    var isCompressed = true
    /// How many pieces to split the text into; more than one stores them in
    /// reverse order in the file.
    var pieceCount = 1
    /// Whether the pieces are stored one after the other in the order of the
    /// text instead, so that a run of properties covers characters in more
    /// than one piece, as a run does in a real file whose pieces are next to
    /// each other.
    var storesPiecesInOrder = false
    /// The `Data` stream (where `sprmPHugePapx` and `sprmPTableProps` keep
    /// properties), written when not empty.
    var dataStream: [UInt8] = []
    /// The character positions in the main text of the reference marks of
    /// the footnotes and of the endnotes, one for each paragraph of those
    /// stories (a note is a paragraph); none leaves out the note tables.
    var footnoteReferences: [Int] = []
    var endnoteReferences: [Int] = []
    /// Whether to write the text box table (`PlcftxbxTxt`), a box for each
    /// paragraph of the text box story.
    var writesTextBoxTable = false
    /// How many of the boxes the table names, when fewer than the story holds.
    var textBoxTableLimit: Int?
    /// The lists (`PlfLst`) and list instances (`PlfLfo`); none leaves out both.
    var lists: [List] = []
    var listInstances: [ListInstance] = []
    /// The property modifiers (`Pcd.prm`, two bytes) of the pieces, by piece
    /// index; a piece beyond the list has none. See `prm0(_:_:)` and `prm1(_:)`.
    var piecePrms: [Int] = []
    /// The groups of modifiers in the CLX (`Prc`s) that a `Prm1` indexes.
    var modifierGroups: [[UInt8]] = []
    /// Whether the table stream is `1Table`.
    var usesOneTable = true
    /// The `nFib` written.
    var version = 0x00C1
    /// The `wIdent` written.
    var identifier = 0xA5EC
    /// Whether `fEncrypted` is set.
    var isEncrypted = false
    var title: String?
    var author: String?
    /// Left out when false: the properties of paragraphs, of characters.
    var writesParagraphProperties = true
    var writesCharacterProperties = true

    /// Normal, Heading 1 to 9 (built-in identifiers 1 to 9), a character
    /// style "Strong" at index 10 that is bold, and "Emphasis" at 11 that is
    /// italic.
    static let standardStyles: [Style?] = {
        var styles: [Style?] = [Style(builtInIdentifier: 0)]
        for level in 1...9 { styles.append(Style(builtInIdentifier: level, basedOn: 0, outlineLevel: level - 1, bold: 1)) }
        styles.append(Style(builtInIdentifier: 0x0, kind: 2, bold: 1))
        styles.append(Style(builtInIdentifier: 0x0, kind: 2, italic: 1))
        return styles
    }()

    // MARK: Where Things Are

    /// The offsets in the streams of the parts of a built document.
    struct Layout {
        /// In the `WordDocument` stream: the pages of paragraph properties and of character properties.
        var paragraphPages: [Int] = []
        var characterPages: [Int] = []
        /// In the table stream: the style sheet, the section table, the two bin tables, and the CLX.
        var styleSheet = 0
        var sectionTable = 0
        var paragraphBinTable = 0
        var characterBinTable = 0
        var clx = 0
        /// In the table stream: the piece table inside the CLX (PlcPcd).
        var pieceTable = 0
        /// In the `WordDocument` stream: the offset of each piece's characters, in character order.
        var pieceOffsets: [Int] = []
        /// In the table stream: the list table (PlfLst) and the list override table (PlfLfo), when there are lists.
        var listFormats = 0
        var listOverrides = 0
        /// In the `WordDocument` stream: the offset of the FIB's (offset, length) pairs.
        var pairs = 154
    }

    // MARK: Building

    /// The streams of the document: the `WordDocument` stream, the table
    /// stream, and the SummaryInformation stream.
    func streams() -> (word: [UInt8], table: [UInt8], summary: [UInt8], layout: Layout) {
        var layout = Layout()

        // The text, as UTF-16 units, with the character position of each paragraph and run.
        var units: [UInt16] = []
        var paragraphRanges: [Range<Int>] = []
        var runRanges: [(range: Range<Int>, run: Run, paragraph: Int)] = []
        // The main story's paragraphs, then each other story's, in file order.
        let allParagraphs = paragraphs + Story.allCases.flatMap { stories[$0] ?? [] }
        var mainLength = 0
        var storyLengths: [Story: Int] = [:]
        for (index, paragraph) in allParagraphs.enumerated() {
            if index == paragraphs.count { mainLength = units.count }
            let start = units.count
            for run in paragraph.runs {
                let runStart = units.count
                units += Array(run.text.utf16)
                runRanges.append((runStart..<units.count, run, index))
            }
            // A mark with properties of its own is a run of its own.
            if !paragraph.markModifiers.isEmpty {
                var markRun = Run("")
                markRun.extraModifiers = paragraph.markModifiers
                runRanges.append((units.count..<units.count + 1, markRun, index))
            }
            units.append(paragraph.mark)
            paragraphRanges.append(start..<units.count)
        }

        // Without other stories, the main story is all the text.
        if allParagraphs.count == paragraphs.count { mainLength = units.count }
        for story in Story.allCases {
            let length = (stories[story] ?? []).reduce(0) { $0 + $1.runs.reduce(0) { $0 + $1.text.utf16.count } + 1 }
            storyLengths[story] = length
        }

        // The WordDocument stream: the FIB's room, then the pieces' text.
        var word = [UInt8](repeating: 0, count: 1024)
        let pieceCount = max(1, min(self.pieceCount, max(units.count, 1)))
        var pieceBounds: [Int] = [0]
        for index in 1..<max(pieceCount, 1) { pieceBounds.append(units.count * index / pieceCount) }
        pieceBounds.append(units.count)
        var pieceFileOffsets = [Int](repeating: 0, count: pieceCount)
        // Reverse order in the file when split.
        for index in storesPiecesInOrder ? Array(0..<pieceCount) : Array((0..<pieceCount).reversed()) {
            pieceFileOffsets[index] = word.count
            for unit in units[pieceBounds[index]..<pieceBounds[index + 1]] {
                if isCompressed {
                    word.append(UInt8(truncatingIfNeeded: unit))
                } else {
                    word += Self.le16(Int(unit))
                }
            }
        }
        layout.pieceOffsets = pieceFileOffsets
        while word.count % 512 != 0 { word.append(0) }

        // The piece that holds a character position, by halving (a document
        // of a hundred thousand pieces is built here too).
        func pieceIndex(of position: Int) -> Int {
            var low = 0
            var high = pieceCount
            while low < high {
                let middle = (low + high) / 2
                if position < pieceBounds[middle + 1] { high = middle } else { low = middle + 1 }
            }
            return min(low, pieceCount - 1)
        }
        // A character position's offset in the stream.
        func fileOffset(ofCharacter position: Int) -> Int {
            let index = pieceIndex(of: position)
            return pieceFileOffsets[index] + (position - pieceBounds[index]) * (isCompressed ? 1 : 2)
        }
        // Splits a range of character positions at the pieces' ends into ranges of file offsets.
        func fileRanges(of range: Range<Int>) -> [Range<Int>] {
            // Pieces next to each other make one range of the file.
            if storesPiecesInOrder, !range.isEmpty {
                let first = fileOffset(ofCharacter: range.lowerBound)
                return [first..<first + range.count * (isCompressed ? 1 : 2)]
            }
            var result: [Range<Int>] = []
            var position = range.lowerBound
            while position < range.upperBound {
                let index = pieceIndex(of: position)
                let end = min(range.upperBound, pieceBounds[index + 1])
                let first = fileOffset(ofCharacter: position)
                result.append(first..<first + (end - position) * (isCompressed ? 1 : 2))
                position = end
            }
            return result
        }

        // The paragraph and character properties, in pages.
        var table: [UInt8] = []
        let paragraphRuns = paragraphRanges.enumerated().flatMap { index, range in
            fileRanges(of: range).map { (range: $0, data: Self.paragraphBlob(for: allParagraphs[index])) }
        }
        let characterRuns = runRanges.flatMap { entry in
            fileRanges(of: entry.range).map { (range: $0, data: Self.characterBlob(for: entry.run)) }
        }

        // The style sheet.
        layout.styleSheet = table.count
        table += styleSheetBytes()
        while table.count % 4 != 0 { table.append(0) }

        // The section table, with the properties of each section in the document stream.
        layout.sectionTable = table.count
        var sectionEnds: [Int] = []
        var sectionKinds: [Int?] = [nil]
        for (endingParagraph, nextKind) in sectionBreaks.sorted(by: { $0.endingParagraph < $1.endingParagraph }) {
            sectionEnds.append(paragraphRanges[endingParagraph].upperBound)
            sectionKinds.append(nextKind)
        }
        sectionEnds.append(mainLength)
        var sectionTable = sectionEnds.flatMap { Self.le32($0) }
        sectionTable = Self.le32(0) + sectionTable
        for kind in sectionKinds {
            var properties = 0xFFFF_FFFF
            if let kind {
                properties = word.count
                word += Self.le16(3) + Self.le16(WordSprm.sectionBreakKind) + [UInt8(kind)]
            }
            sectionTable += Self.le16(0) + Self.le32(properties) + Self.le16(0) + Self.le32(0)
        }
        table += sectionTable
        while table.count % 4 != 0 { table.append(0) }
        while word.count % 512 != 0 { word.append(0) }

        // The two bin tables.
        layout.paragraphBinTable = table.count
        if writesParagraphProperties {
            let packed = Self.pack(runs: paragraphRuns, isParagraph: true, into: &word)
            layout.paragraphPages = packed.pages
            table += packed.plc
        }
        layout.characterBinTable = table.count
        if writesCharacterProperties {
            let packed = Self.pack(runs: characterRuns, isParagraph: false, into: &word)
            layout.characterPages = packed.pages
            table += packed.plc
        }

        // The CLX: the groups of piece modifiers, then a piece table of the
        // pieces in character order.
        layout.clx = table.count
        for group in modifierGroups { table += [0x01] + Self.le16(group.count) + group }
        var plc: [UInt8] = []
        for index in 0...pieceCount { plc += Self.le32(pieceBounds[index]) }
        for index in 0..<pieceCount {
            let rawOffset = isCompressed ? (pieceFileOffsets[index] * 2) | 0x4000_0000 : pieceFileOffsets[index]
            plc += Self.le16(0) + Self.le32(rawOffset) + Self.le16(index < piecePrms.count ? piecePrms[index] : 0)
        }
        table += [0x02] + Self.le32(plc.count)
        layout.pieceTable = table.count
        table += plc
        let clxLength = table.count - layout.clx

        // The list tables, after everything else in the table stream: the
        // PlfLst (its LVLs follow it, outside its length) and the PlfLfo.
        var listPairs: [Int: (Int, Int)] = [:]
        if !lists.isEmpty || !listInstances.isEmpty {
            while table.count % 4 != 0 { table.append(0) }
            let formats = Self.listTableBytes(lists)
            layout.listFormats = table.count
            listPairs[WordFileInformationBlock.Structure.listFormats.rawValue] = (table.count, formats.header.count)
            table += formats.header + formats.levels
            while table.count % 4 != 0 { table.append(0) }
            let overrides = Self.listOverrideBytes(listInstances)
            layout.listOverrides = table.count
            listPairs[WordFileInformationBlock.Structure.listOverrides.rawValue] = (table.count, overrides.count)
            table += overrides
        }

        // The note tables: where each reference mark stands in the main text
        // (PlcfRef: the positions, one more, and an FRD for each) and where
        // each note begins in its story (PlcfTxt: the starts, where the last
        // ends, and one more).
        for (story, marks, reference, text) in [
            (Story.footnotes, footnoteReferences, WordFileInformationBlock.Structure.footnoteReferences, WordFileInformationBlock.Structure.footnoteText),
            (Story.endnotes, endnoteReferences, WordFileInformationBlock.Structure.endnoteReferences, WordFileInformationBlock.Structure.endnoteText),
        ] where !marks.isEmpty {
            var starts = [0]
            for note in (stories[story] ?? []).prefix(marks.count) {
                starts.append(starts[starts.count - 1] + note.runs.reduce(0) { $0 + $1.text.utf16.count } + 1)
            }
            var referenceBytes: [UInt8] = []
            for mark in marks { referenceBytes += Self.le32(mark) }
            referenceBytes += Self.le32(mainLength)
            for _ in marks { referenceBytes += Self.le16(1) }
            var textBytes: [UInt8] = []
            for start in starts { textBytes += Self.le32(start) }
            textBytes += Self.le32(starts[starts.count - 1] + 1)
            while table.count % 4 != 0 { table.append(0) }
            listPairs[reference.rawValue] = (table.count, referenceBytes.count)
            table += referenceBytes
            while table.count % 4 != 0 { table.append(0) }
            listPairs[text.rawValue] = (table.count, textBytes.count)
            table += textBytes
        }

        // The text box table: the position where each box begins (a box is a
        // paragraph of the story), where the last ends, and one more (the
        // last range, which is ignored), then an FTXBXS of 22 bytes for each box.
        if writesTextBoxTable, let boxes = stories[.textBoxes], !boxes.isEmpty {
            var starts = [0]
            let named = Array(boxes.prefix(textBoxTableLimit ?? boxes.count))
            for box in named { starts.append(starts[starts.count - 1] + box.runs.reduce(0) { $0 + $1.text.utf16.count } + 1) }
            var bytes: [UInt8] = []
            for start in starts { bytes += Self.le32(start) }
            bytes += Self.le32(starts[starts.count - 1] + 1)
            bytes += [UInt8](repeating: 0, count: 22 * named.count)
            while table.count % 4 != 0 { table.append(0) }
            listPairs[WordFileInformationBlock.Structure.textBoxText.rawValue] = (table.count, bytes.count)
            table += bytes
        }

        // The pairs of the FIB: (offset, length) of each structure.
        let styleSheetLength = layout.sectionTable - layout.styleSheet
        let sectionLength = sectionTable.count
        var pairs: [Int: (Int, Int)] = [
            WordFileInformationBlock.Structure.styleSheet.rawValue: (layout.styleSheet, styleSheetLength),
            WordFileInformationBlock.Structure.sectionTable.rawValue: (layout.sectionTable, sectionLength),
            WordFileInformationBlock.Structure.complexInformation.rawValue: (layout.clx, clxLength),
        ]
        pairs.merge(listPairs) { first, _ in first }
        pairs[WordFileInformationBlock.Structure.paragraphBinTable.rawValue] =
            writesParagraphProperties ? (layout.paragraphBinTable, layout.characterBinTable - layout.paragraphBinTable) : (0, 0)
        pairs[WordFileInformationBlock.Structure.characterBinTable.rawValue] =
            writesCharacterProperties ? (layout.characterBinTable, layout.clx - layout.characterBinTable) : (0, 0)

        // The FIB.
        func put(_ bytes: [UInt8], at offset: Int) { word.replaceSubrange(offset..<offset + bytes.count, with: bytes) }
        put(Self.le16(identifier), at: 0)
        put(Self.le16(version), at: 2)
        put(Self.le16((isEncrypted ? 0x0100 : 0) | (usesOneTable ? 0x0200 : 0)), at: 10)
        put(Self.le16(14), at: 32)
        put(Self.le16(22), at: 62)
        // ccpText is the fourth of the 32-bit values that begin at 64.
        put(Self.le32(mainLength), at: 64 + 12)
        for story in Story.allCases { put(Self.le32(storyLengths[story] ?? 0), at: story.lengthOffset) }
        put(Self.le16(93), at: 152)
        for (index, pair) in pairs {
            put(Self.le32(pair.0) + Self.le32(pair.1), at: layout.pairs + index * 8)
        }
        return (word, table, summaryBytes(), layout)
    }

    /// The compound file of the document.
    func build() -> Data {
        let parts = streams()
        var file = CompoundFileBuilder()
        file.streams = [
            ("WordDocument", parts.word),
            (usesOneTable ? "1Table" : "0Table", parts.table),
            ("\u{05}SummaryInformation", parts.summary),
        ]
        if !dataStream.isEmpty { file.streams.append(("Data", dataStream)) }
        return file.build().data
    }

    /// The compound file with its two main streams changed by `change`
    /// (given the document stream, the table stream, and the layout).
    func build(changing change: (inout [UInt8], inout [UInt8], Layout) -> Void) -> Data {
        var parts = streams()
        change(&parts.word, &parts.table, parts.layout)
        var file = CompoundFileBuilder()
        file.streams = [
            ("WordDocument", parts.word),
            (usesOneTable ? "1Table" : "0Table", parts.table),
            ("\u{05}SummaryInformation", parts.summary),
        ]
        if !dataStream.isEmpty { file.streams.append(("Data", dataStream)) }
        return file.build().data
    }

    // MARK: Modifiers

    static func le16(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)] }
    static func le32(_ value: Int) -> [UInt8] { le16(value & 0xFFFF) + le16((value >> 16) & 0xFFFF) }

    /// The paragraph modifiers that put a paragraph in list instance
    /// `instance` (one-based; the raw 16-bit value is written as it is) at `level`.
    static func listProperties(instance: Int, level: Int) -> [UInt8] {
        le16(WordSprm.listIndex) + le16(instance & 0xFFFF) + modifier(WordSprm.listLevel, level)
    }

    /// A `Prm0`: the sprm in the specification's table at `isprm`, with the one-byte operand `value`.
    static func prm0(_ isprm: Int, _ value: Int) -> Int { (isprm << 1) | (value << 8) }

    /// A `Prm1`: the group of modifiers at `index` in the CLX.
    static func prm1(_ index: Int) -> Int { (index << 1) | 1 }

    /// A modifier with a one-byte operand.
    static func modifier(_ opcode: Int, _ operand: Int) -> [UInt8] { le16(opcode) + [UInt8(operand)] }

    /// The paragraph properties of a paragraph: its style index and its modifiers.
    private static func paragraphBlob(for paragraph: Paragraph) -> [UInt8] {
        le16(paragraph.style) + paragraph.modifiers
    }

    /// The character properties of a run.
    private static func characterBlob(for run: Run) -> [UInt8] {
        var bytes: [UInt8] = []
        if let bold = run.bold { bytes += modifier(WordSprm.bold, bold) }
        if let italic = run.italic { bytes += modifier(WordSprm.italic, italic) }
        if let hidden = run.hidden { bytes += modifier(WordSprm.hidden, hidden) }
        if let style = run.characterStyle { bytes += le16(WordSprm.characterStyle) + le16(style) }
        if run.isSpecial { bytes += modifier(WordSprm.special, 1) }
        if let size = run.fontSize { bytes += le16(WordSprm.fontSize) + le16(size) }
        if run.isDeleted { bytes += modifier(WordSprm.deleted, 1) }
        return bytes + run.extraModifiers
    }

    // MARK: The Style Sheet

    /// The style sheet, as it is stored in the table stream.
    private func styleSheetBytes() -> [UInt8] {
        // Stshi: the count of styles, the size of each style's fixed part,
        // and fields this reader does not read.
        var stshi = Self.le16(styles.count) + Self.le16(10)
        stshi += Self.le16(0) + Self.le16(0) + Self.le16(0) + Self.le16(0) + [UInt8](repeating: 0, count: 6)
        var bytes = Self.le16(stshi.count) + stshi
        for (index, style) in styles.enumerated() {
            guard let style else {
                bytes += Self.le16(0)
                continue
            }
            // The fixed part: identifier, kind and base style, count of groups.
            let groupCount = style.kind == 1 ? 2 : 1
            var std = Self.le16(style.builtInIdentifier & 0x0FFF)
            std += Self.le16(style.kind | ((style.basedOn ?? 0x0FFF) << 4))
            std += Self.le16(groupCount) + Self.le16(0) + Self.le16(0)
            // The name, "Style N".
            let name = Array("Style \(index)".utf16)
            std += Self.le16(name.count) + name.flatMap { Self.le16(Int($0)) } + Self.le16(0)
            // The property groups, each padded to an even size.
            func group(_ bytes: [UInt8]) -> [UInt8] {
                Self.le16(bytes.count) + bytes + (bytes.count % 2 == 1 ? [0] : [])
            }
            var characters: [UInt8] = []
            if let bold = style.bold { characters += Self.modifier(WordSprm.bold, bold) }
            if let italic = style.italic { characters += Self.modifier(WordSprm.italic, italic) }
            if let hidden = style.hidden { characters += Self.modifier(WordSprm.hidden, hidden) }
            if let size = style.fontSize { characters += Self.le16(WordSprm.fontSize) + Self.le16(size) }
            if style.kind == 1 {
                var paragraph = Self.le16(index)
                if let outline = style.outlineLevel { paragraph += Self.modifier(WordSprm.outlineLevel, outline) }
                if let value = style.pageBreakBefore { paragraph += Self.modifier(WordSprm.pageBreakBefore, value) }
                if let level = style.listLevel { paragraph += Self.modifier(WordSprm.listLevel, level) }
                if let index = style.listIndex { paragraph += Self.le16(WordSprm.listIndex) + Self.le16(index) }
                std += group(paragraph) + group(characters)
            } else {
                std += group(characters)
            }
            bytes += Self.le16(std.count) + std
        }
        return bytes
    }

    // MARK: Lists

    /// The `LVL` of `level` ([MS-DOC] 2.9.149).
    private static func levelBytes(_ level: ListLevel) -> [UInt8] {
        // The number text: "%N" is the placeholder for level N, a character of value N - 1.
        var units: [UInt16] = []
        var placeholders: [UInt8] = []
        let characters = Array(level.text.utf16)
        var index = 0
        while index < characters.count {
            if characters[index] == 0x25, index + 1 < characters.count, (0x31...0x39).contains(characters[index + 1]) {
                placeholders.append(UInt8(units.count + 1))
                units.append(characters[index + 1] - 0x31)
                index += 2
            } else {
                units.append(characters[index])
                index += 1
            }
        }
        // The LVLF: start, format, flags, the placeholders (nine bytes), what follows, and sizes.
        var bytes = le32(level.start) + [UInt8(level.numberFormat)]
        let legal: UInt8 = level.isLegal ? 0x04 : 0
        let noRestart: UInt8 = level.restartLimit != nil ? 0x08 : 0
        bytes.append(legal | noRestart)
        bytes += (placeholders + [UInt8](repeating: 0, count: 9)).prefix(9)
        // ixchFollow (a tab), dxaIndentSav and an unused field (4 bytes each), then the
        // sizes of the two property lists (none), ilvlRestartLim, and grfhic.
        bytes.append(0)
        bytes += le32(0)
        bytes += le32(0)
        // The number's character properties (hidden or not) follow the LVLF, then the text.
        let characterProperties: [UInt8] = level.numberIsHidden ? modifier(WordSprm.hidden, 1) : []
        bytes += [UInt8(characterProperties.count), 0, UInt8(level.restartLimit ?? 0), 0] as [UInt8]
        return bytes + characterProperties + le16(units.count) + units.flatMap { le16(Int($0)) }
    }

    /// The `PlfLst` (a count and an `LSTF` for each list) and, apart, the
    /// `LVL`s that follow it.
    private static func listTableBytes(_ lists: [List]) -> (header: [UInt8], levels: [UInt8]) {
        var header = le16(lists.count)
        var levels: [UInt8] = []
        for list in lists {
            header += le32(list.identifier)
            header += le32(0)
            // rgistdPara: no style is linked to any of the nine levels.
            for _ in 0..<9 { header += le16(0x0FFF) }
            header += [list.isSimple ? 1 : 0, 0] as [UInt8]
            for level in list.levels.prefix(list.isSimple ? 1 : 9) { levels += levelBytes(level) }
        }
        return (header, levels)
    }

    /// The `PlfLfo`: a count, an `LFO` for each instance, and an `LFOData` for each.
    private static func listOverrideBytes(_ instances: [ListInstance]) -> [UInt8] {
        var bytes = le32(instances.count)
        for instance in instances {
            bytes += le32(instance.listIdentifier)
            bytes += le32(0)
            bytes += le32(0)
            bytes += [UInt8(instance.overrides.count), 0, 0, 0] as [UInt8]
        }
        for instance in instances {
            bytes += le32(0)
            for entry in instance.overrides {
                let flags = entry.level | (entry.startAt != nil ? 0x10 : 0) | (entry.replacement != nil ? 0x20 : 0)
                bytes += le32(entry.startAt ?? 0)
                bytes += le32(flags)
                if let replacement = entry.replacement { bytes += levelBytes(replacement) }
            }
        }
        return bytes
    }

    // MARK: Formatted Disk Pages

    /// Packs `runs` (ranges of file offsets and their property bytes), sorted
    /// by file offset with unspoken stretches between them left without
    /// properties, into pages appended to `word`, and returns the offsets of
    /// the pages and the bin table (PLC) that names them.
    private static func pack(
        runs: [(range: Range<Int>, data: [UInt8])], isParagraph: Bool, into word: inout [UInt8]
    ) -> (pages: [Int], plc: [UInt8]) {
        // The runs in file order, with a run of no properties in every gap.
        var ordered: [(range: Range<Int>, data: [UInt8]?)] = []
        for run in runs.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            if let last = ordered.last, last.range.upperBound < run.range.lowerBound {
                ordered.append((last.range.upperBound..<run.range.lowerBound, nil))
            }
            ordered.append((run.range, run.data))
        }

        var pages: [Int] = []
        var firstOffsets: [Int] = []
        var lastOffset = 0
        var index = 0
        while index < ordered.count {
            // Fill a page: each run takes a four-byte offset and its entry
            // (13 bytes for a paragraph, 1 for a character), and its data goes
            // at the end of the page, working backwards.
            let entrySize = isParagraph ? 13 : 1
            var count = 0
            var top = 511
            var blobs: [(offset: Int, bytes: [UInt8])?] = []
            while index + count < ordered.count {
                let run = ordered[index + count]
                var blob: [UInt8]?
                if let data = run.data {
                    if isParagraph {
                        // The PAPX: its size in words, the data (style index included).
                        blob = data.count % 2 == 1 ? [UInt8((data.count + 1) / 2)] + data : [0, UInt8(data.count / 2)] + data
                    } else {
                        blob = [UInt8(data.count)] + data
                    }
                }
                let used = (count + 2) * 4 + (count + 1) * entrySize
                let newTop = (top - (blob?.count ?? 0)) & ~1
                if used > newTop || count >= 20 { break }
                blobs.append(blob.map { (newTop, $0) })
                top = blob == nil ? top : newTop
                count += 1
            }
            var page = [UInt8](repeating: 0, count: 512)
            for position in 0..<count {
                let run = ordered[index + position]
                page.replaceSubrange(position * 4..<position * 4 + 4, with: le32(run.range.lowerBound))
                let entry = (count + 1) * 4 + position * entrySize
                if let blob = blobs[position] {
                    page.replaceSubrange(blob.offset..<blob.offset + blob.bytes.count, with: blob.bytes)
                    page[entry] = UInt8(blob.offset / 2)
                }
            }
            let end = ordered[index + count - 1].range.upperBound
            page.replaceSubrange(count * 4..<count * 4 + 4, with: le32(end))
            page[511] = UInt8(count)
            pages.append(word.count)
            firstOffsets.append(ordered[index].range.lowerBound)
            lastOffset = end
            word += page
            index += count
        }
        var plc = firstOffsets.flatMap { le32($0) } + le32(lastOffset)
        for page in pages { plc += le32(page / 512) }
        return (pages, plc)
    }

    // MARK: Summary Information

    /// The SummaryInformation stream with the title and author.
    private func summaryBytes() -> [UInt8] {
        // The property set: a code page (Windows-1252), then the strings.
        var properties: [(identifier: Int, value: [UInt8])] = [(1, Self.le16(2) + Self.le16(0) + Self.le16(1252) + Self.le16(0))]
        func string(_ text: String) -> [UInt8] {
            let bytes = Array(text.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }) + [0]
            var value = Self.le16(0x1E) + Self.le16(0) + Self.le32(bytes.count) + bytes
            while value.count % 4 != 0 { value.append(0) }
            return value
        }
        if let title { properties.append((2, string(title))) }
        if let author { properties.append((4, string(author))) }
        var set = Self.le32(0) + Self.le32(properties.count)
        var body: [UInt8] = []
        let table = 8 + properties.count * 8
        for property in properties {
            set += Self.le32(property.identifier) + Self.le32(table + body.count)
            body += property.value
        }
        set += body
        set.replaceSubrange(0..<4, with: Self.le32(set.count))
        // The header: byte order, version, system, class ID, one set at offset 48.
        var stream = Self.le16(0xFFFE) + Self.le16(0) + Self.le32(0) + [UInt8](repeating: 0, count: 16) + Self.le32(1)
        stream += [UInt8](repeating: 0, count: 16) + Self.le32(48)
        return stream + set
    }
}


// MARK: - Reading a Built Document

/// The inner HTML of the body of the document `data`, read as the reader does
/// with its list numbers written as words or not (`speaksNumbers`).
func wordBody(
    of data: Data, pages: Bool = false, speaksNumbers: Bool = WordDocumentReader.speaksListNumbers,
    file: StaticString = #filePath, line: UInt = #line
) throws -> String {
    let html = try XCTUnwrap(
        WordDocumentReader.html(from: data, includesPages: pages, speaksListNumbers: speaksNumbers), file: file, line: line
    )
    let start = try XCTUnwrap(html.range(of: "<body>\n"), file: file, line: line)
    let end = try XCTUnwrap(html.range(of: "</body>"), file: file, line: line)
    return String(html[start.upperBound..<end.lowerBound])
}

/// The body of the format sample at `path`, as `wordBody(of:)` reads it.
func wordSampleBody(
    _ path: String, pages: Bool = false, speaksNumbers: Bool = WordDocumentReader.speaksListNumbers,
    file: StaticString = #filePath, line: UInt = #line
) throws -> String {
    try wordBody(of: Data(contentsOf: formatSampleURL(path)), pages: pages, speaksNumbers: speaksNumbers, file: file, line: line)
}

/// The chapter an import makes of the HTML the reader writes for `data`: its
/// reading text, as a listener hears it, and its headings.
func wordReadingChapter(of data: Data, speaksNumbers: Bool = WordDocumentReader.speaksListNumbers) throws -> Chapter {
    let html = try XCTUnwrap(WordDocumentReader.html(from: data, includesPages: false, speaksListNumbers: speaksNumbers))
    let markdown = try HTMLToMarkdownConverter.convert(
        document: SwiftSoup.parse(html), readingFlow: PublicationSemantics.ReadingFlow(source: html), includesPages: false
    )
    return try MarkdownDocParser.parseChapter(markdown: markdown, title: "", includeNavigationHeadings: true)
}
