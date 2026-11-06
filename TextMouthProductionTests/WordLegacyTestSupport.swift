import Foundation
import XCTest
@testable import TextMouth

// MARK: - Building Word 6 and Word 95 Documents in Code

/// Writes a Word 6 or Word 95 document from a description of its paragraphs,
/// runs, and styles, so a test can make the documents it reads and damage them
/// at places it knows. The layout is the one the real samples show
/// (`TestData/format-samples/doc6`): a FIB of 0x200 bytes at the start of the
/// `WordDocument` stream, the text from 0x300, two kinds of 512-byte
/// formatted disk pages (a CHPX page, and a PAPX page of 7-byte entries whose
/// PAPX is a size in words and then twice that many bytes), the style
/// sheet, the font table, the section table, and (for a document saved with
/// Fast Save) a piece table of plain file offsets. There is no table
/// stream. Bytes are written in the order Word writes them, so a mistake in the
/// reader's reading of the order shows.
struct WordLegacyDocumentBuilder {

    // MARK: The Description

    /// A run of text with one set of character modifiers.
    struct Run {
        var text: String
        /// The run's character sprms, as bytes (`sprm(_:_:)`).
        var sprms: [UInt8]
        /// The encoding the run's characters are written in, when it is not the document's (Mac text in a Windows file).
        var encoding: String.Encoding?

        init(_ text: String, sprms: [UInt8] = [], encoding: String.Encoding? = nil) {
            self.text = text
            self.sprms = sprms
            self.encoding = encoding
        }
    }

    /// A paragraph: runs of text and the mark that ends it.
    struct Paragraph {
        var runs: [Run]
        /// The paragraph's style index.
        var style: Int
        /// The paragraph's sprms, as bytes.
        var sprms: [UInt8]
        /// The character that ends the paragraph, and its own character sprms (a hidden mark, for one).
        var mark: UInt8
        var markSprms: [UInt8]

        init(_ text: String, style: Int = 0, sprms: [UInt8] = [], mark: UInt8 = 0x0D, markSprms: [UInt8] = []) {
            runs = [Run(text)]
            self.style = style
            self.sprms = sprms
            self.mark = mark
            self.markSprms = markSprms
        }

        init(runs: [Run], style: Int = 0, sprms: [UInt8] = [], mark: UInt8 = 0x0D, markSprms: [UInt8] = []) {
            self.runs = runs
            self.style = style
            self.sprms = sprms
            self.mark = mark
            self.markSprms = markSprms
        }
    }

    /// A style of the sheet.
    struct Style {
        /// The built-in identifier (1 to 9 are Heading 1 to 9).
        var sti: Int
        /// 1 for a paragraph style, 2 for a character style.
        var kind = 1
        /// The style it is based on, or 0xFFF for none.
        var basedOn = 0xFFF
        var name: String
        /// The paragraph's sprms and the characters' sprms of the style.
        var paragraphSprms: [UInt8] = []
        var characterSprms: [UInt8] = []
    }

    /// A section: the character position after its last character, and its sprm `sprmSBkc` if it has one.
    struct Section {
        var end: Int
        var breakKind: UInt8?
    }

    var paragraphs: [Paragraph] = []
    /// The style sheet by index; nil leaves a slot unused. The default is Normal and Heading 1 to 3.
    var styles: [Style?] = [
        Style(sti: 0, name: "Normal"),
        Style(sti: 1, basedOn: 0, name: "heading 1"),
        Style(sti: 2, basedOn: 0, name: "heading 2"),
        Style(sti: 3, basedOn: 0, name: "heading 3"),
    ]
    /// The notes' texts; each begins with a reference mark (U+0002) in the main text where the caller puts one.
    var footnotes: [String] = []
    /// The endnotes' and text boxes' paragraphs: stories with no tables of their own in this layout, read whole.
    var endnotes: [String] = []
    var textBoxes: [String] = []
    /// The property modifiers (`Pcd.prm`) of the first and of the second piece of a fast-saved document, and the
    /// groups of modifiers (in the form of a property list) that a `Prm1` names by its index.
    var piecePrms: [UInt16] = [0, 0]
    var modifierGroups: [[UInt8]] = []
    /// The index of a style whose first property group claims to be larger than the style.
    var damagedStyle: Int?
    /// The names of the first fonts of the font table (the rest are "Font" and their index).
    var fontNames: [String] = []
    var sections: [Section] = []
    /// The code page the characters are written in.
    var encoding: String.Encoding = .windowsCP1252
    /// Whether each character is a 16-bit unit (`fExtChar`).
    var twoByteCharacters = false
    /// The language id the FIB says (English), and the character set field (0).
    var language = 0x0409
    var characterSet = 0
    /// The character sets of the fonts in the font table; none writes no table.
    var fontCharacterSets: [Int] = []
    /// Whether the text is in a piece table of two pieces, stored in reverse order, as Fast Save leaves it.
    var isFastSaved = false
    /// The FIB's identifier and version.
    var identifier = 0xA5DC
    var version = 0x65
    /// Flag bits to set in the FIB (`fEncrypted` is 0x100).
    var extraFlags = 0

    // MARK: Sprms

    /// One sprm: the opcode byte and its operand.
    static func sprm(_ opcode: UInt8, _ operand: [UInt8]) -> [UInt8] { [opcode] + operand }

    /// The sprms for bold, italic, hidden text, and a deletion, with a value (1 on, 0 off, 0x80 and 0x81 the toggles).
    static func bold(_ value: UInt8 = 1) -> [UInt8] { sprm(85, [value]) }
    static func italic(_ value: UInt8 = 1) -> [UInt8] { sprm(86, [value]) }
    static func hidden(_ value: UInt8 = 1) -> [UInt8] { sprm(92, [value]) }
    static func deleted(_ value: UInt8 = 1) -> [UInt8] { sprm(65, [value]) }
    /// The font size in half-points (`sprmCHps`, two bytes).
    static func size(halfPoints: Int) -> [UInt8] { sprm(99, [UInt8(halfPoints & 0xFF), UInt8(halfPoints >> 8)]) }
    /// The paragraph is in a table, and ends a row.
    static let inTable = sprm(24, [1])
    static let rowEnd = sprm(25, [1])
    /// A page break before the paragraph.
    static let pageBreakBefore = sprm(9, [1])

    /// An `ANLD` of 52 bytes numbering with format `format` (0 Arabic, 255 bullet), text before and after
    /// the number, starting at `start`, that includes the previous level's number if `includesPrevious`; as a
    /// paragraph's sprm, at `level` (1 to 9 outline, 10 simple, 11 bullet; nil leaves the level out, as a
    /// leftover `ANLD` is stored).
    static func numbering(
        format: UInt8 = 0, before: String = "", after: String = ".", start: Int = 1, level: UInt8? = 10,
        includesPrevious: Bool = false
    ) -> [UInt8] {
        var anld = [UInt8](repeating: 0, count: 52)
        anld[0] = format
        anld[3] = includesPrevious ? 0x04 : 0
        anld[1] = UInt8(before.utf8.count)
        anld[2] = UInt8(after.utf8.count)
        anld[10] = UInt8(start & 0xFF)
        anld[11] = UInt8(start >> 8)
        for (index, byte) in (Array(before.utf8) + Array(after.utf8)).enumerated() { anld[20 + index] = byte }
        // The size byte, then the 52 bytes; then the level.
        return sprm(12, [52] + anld) + (level.map { sprm(13, [$0]) } ?? [])
    }

    // MARK: Building

    /// What a build lays out, for tests that damage it.
    struct Layout {
        var textStart = 0x300
        var textEnd = 0
        var chpxPages: [Int] = []
        var papxPages: [Int] = []
        var styleSheet = 0
        var styleSheetLength = 0
        var clx = 0
        var clxLength = 0
        /// The characters of the main text and of the notes.
        var mainCharacters = 0
        var noteCharacters = 0
        var endnoteCharacters = 0
        var textBoxCharacters = 0
    }

    /// The `WordDocument` stream and where its parts are.
    func buildStream() -> (bytes: [UInt8], layout: Layout) {
        var layout = Layout()
        let width = twoByteCharacters ? 2 : 1

        // The text, as units, in order: every paragraph's runs and mark, then the notes.
        var units: [[UInt8]] = []
        /// Appends the units of `text` and returns how many.
        func appendUnits(_ text: String, in runEncoding: String.Encoding? = nil) -> Int {
            var count = 0
            for scalar in text.unicodeScalars {
                let bytes = scalar.value < 0x80 ? [UInt8(scalar.value)] : Array(String(scalar).data(using: runEncoding ?? encoding) ?? Data([0x3F]))
                if twoByteCharacters {
                    // A byte is itself with a zero above; a pair is stored trail byte first.
                    units.append(bytes.count == 2 ? [bytes[1], bytes[0]] : [bytes.first ?? 0x3F, 0])
                } else {
                    units.append(bytes)
                }
                count += 1
            }
            return count
        }
        // The runs' and paragraphs' character spans (in units).
        var characterSpans: [(range: Range<Int>, sprms: [UInt8])] = []
        var paragraphSpans: [(range: Range<Int>, style: Int, sprms: [UInt8])] = []
        for paragraph in paragraphs {
            let start = units.count
            for run in paragraph.runs {
                let runStart = units.count
                let count = appendUnits(run.text, in: run.encoding)
                characterSpans.append((runStart..<runStart + count, run.sprms))
            }
            let markStart = units.count
            units.append(twoByteCharacters ? [paragraph.mark, 0] : [paragraph.mark])
            characterSpans.append((markStart..<markStart + 1, paragraph.markSprms))
            paragraphSpans.append((start..<units.count, paragraph.style, paragraph.sprms))
        }
        layout.mainCharacters = units.count
        var noteStarts: [Int] = []
        for note in footnotes {
            noteStarts.append(units.count - layout.mainCharacters)
            _ = appendUnits(note + "\r")
        }
        layout.noteCharacters = units.count - layout.mainCharacters
        for note in endnotes { _ = appendUnits(note + "\r") }
        layout.endnoteCharacters = units.count - layout.mainCharacters - layout.noteCharacters
        for box in textBoxes { _ = appendUnits(box + "\r") }
        layout.textBoxCharacters = units.count - layout.mainCharacters - layout.noteCharacters - layout.endnoteCharacters

        // The stream: the FIB's room, then the text. A fast-saved document stores the second half first.
        var stream = [UInt8](repeating: 0, count: layout.textStart)
        let splitAt = units.count / 2
        let order: [Range<Int>] = isFastSaved ? [splitAt..<units.count, 0..<splitAt] : [0..<units.count]
        // The file offset of each character.
        var offsets = [Int](repeating: 0, count: units.count)
        for range in order {
            for index in range {
                offsets[index] = stream.count
                stream += units[index]
            }
        }
        layout.textEnd = stream.count
        /// The file offset of the character at position `position` (the end is the end of the last piece).
        func offset(_ position: Int) -> Int { position < units.count ? offsets[position] : layout.textEnd }
        /// The byte range of a span of characters, cut at the piece boundary when fast-saved.
        func fileRuns(of range: Range<Int>) -> [Range<Int>] {
            guard isFastSaved, range.lowerBound < splitAt, range.upperBound > splitAt else {
                guard !range.isEmpty else { return [] }
                return [offset(range.lowerBound)..<offset(range.lowerBound) + range.count * width]
            }
            return fileRuns(of: range.lowerBound..<splitAt) + fileRuns(of: splitAt..<range.upperBound)
        }

        /// Appends `page` aligned to 512 bytes and returns its number.
        func appendPage(_ page: [UInt8]) -> Int {
            while stream.count % 512 != 0 { stream.append(0) }
            stream += page
            return stream.count / 512 - 1
        }

        // The runs of character properties, in file order, with the pages that hold them.
        let characterRuns = characterSpans.flatMap { span in fileRuns(of: span.range).map { (range: $0, sprms: span.sprms) } }
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
        let paragraphRuns = paragraphSpans.flatMap { span in fileRuns(of: span.range).map { (range: $0, style: span.style, sprms: span.sprms) } }
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
        let characterPlc = pages(
            of: characterRuns.map { (range: $0.range, data: $0.sprms.isEmpty ? [] : [UInt8($0.sprms.count)] + $0.sprms) },
            entrySize: 1, appendPage: appendPage
        )
        let paragraphPlc = pages(
            of: paragraphRuns.map { run -> (range: Range<Int>, data: [UInt8]) in
                // The size in words of what follows (the style, the sprms, and a pad), then those bytes.
                let words = (2 + run.sprms.count + 1) / 2
                return (run.range, [UInt8(words), UInt8(run.style & 0xFF), UInt8(run.style >> 8)] + run.sprms
                    + [UInt8](repeating: 0, count: words * 2 - 2 - run.sprms.count))
            },
            entrySize: 7, appendPage: appendPage
        )
        layout.chpxPages = characterPlc.pageNumbers
        layout.papxPages = paragraphPlc.pageNumbers

        // The rest, anywhere in the stream; each part's offset and length go in the FIB.
        var pairs: [Int: (Int, Int)] = [:]
        func append(_ bytes: [UInt8], as field: Int) {
            guard !bytes.isEmpty else { return }
            pairs[field] = (stream.count, bytes.count)
            stream += bytes
        }
        append(characterPlc.plc, as: 0xB8)
        append(paragraphPlc.plc, as: 0xC0)
        let sheet = styleSheet()
        layout.styleSheet = stream.count
        layout.styleSheetLength = sheet.count
        append(sheet, as: 0x60)
        append(fontTable(), as: 0xD0)
        let sectionBytes = sectionTable(appendingPropertiesTo: &stream)
        append(sectionBytes, as: 0x88)
        // The notes' tables.
        if !footnotes.isEmpty {
            let marks = (0..<layout.mainCharacters).filter { units[$0].first == 0x02 }
            append(plc(marks + [layout.mainCharacters], data: marks.map { _ in [0, 0] }), as: 0x68)
            let last = noteStarts.last.map { _ in layout.noteCharacters } ?? 0
            append(plc(noteStarts + [last, last + 1], data: []), as: 0x70)
        }
        if isFastSaved {
            // The CLX: a PlcPcd of two pieces, each a descriptor of flags, a plain offset, and no modifiers.
            let first = [UInt8](UInt16(0x40).bytes) + UInt32(offset(0)).bytes + (piecePrms.first ?? 0).bytes
            let second = [UInt8](UInt16(0x40).bytes) + UInt32(offset(splitAt)).bytes + (piecePrms.dropFirst().first ?? 0).bytes
            let pieceTable = UInt32(0).bytes + UInt32(splitAt).bytes + UInt32(units.count).bytes + first + second
            let groups = modifierGroups.flatMap { [UInt8(1)] + UInt16($0.count).bytes + $0 }
            let clx = groups + [UInt8(2)] + UInt32(pieceTable.count).bytes + pieceTable
            layout.clx = stream.count
            layout.clxLength = clx.count
            append(clx, as: 0x160)
        }

        // The FIB.
        func put16(_ value: Int, at position: Int) { stream.replaceSubrange(position..<position + 2, with: UInt16(truncatingIfNeeded: value).bytes) }
        func put32(_ value: Int, at position: Int) { stream.replaceSubrange(position..<position + 4, with: UInt32(truncatingIfNeeded: value).bytes) }
        put16(identifier, at: 0)
        put16(version, at: 2)
        put16(language, at: 6)
        put16((isFastSaved ? 0x0004 : 0) | (twoByteCharacters ? 0x1000 : 0) | extraFlags, at: 10)
        put16(characterSet, at: 0x14)
        put32(layout.textStart, at: 0x18)
        put32(layout.textEnd, at: 0x1C)
        put32(layout.mainCharacters, at: 0x34)
        put32(layout.noteCharacters, at: 0x38)
        put32(layout.endnoteCharacters, at: 0x48)
        put32(layout.textBoxCharacters, at: 0x4C)
        for (field, pair) in pairs {
            put32(pair.0, at: field)
            put32(pair.1, at: field + 4)
        }
        return (stream, layout)
    }

    /// The compound file with the stream.
    func build() -> Data {
        var file = CompoundFileBuilder()
        file.streams = [("WordDocument", buildStream().bytes)]
        return file.build().data
    }

    // MARK: Parts

    /// A PLC: the positions (n + 1 of them, or n + 2) and the `data` of each entry, in bytes.
    private func plc(_ positions: [Int], data: [[UInt8]]) -> [UInt8] {
        positions.flatMap { UInt32($0).bytes } + data.flatMap { $0 }
    }

    /// The formatted disk pages that hold `runs` (each a span of file bytes and the bytes of its
    /// modifiers, with their size in front; empty for none), and the bin table: a PLC of the pages'
    /// first offsets and the last end, and the 16-bit page numbers. A page holds the offsets of its
    /// runs and the end, then an entry of `entrySize` bytes for each run (the first the modifiers'
    /// offset in words), and the modifiers from the end of the page backward, each on a word; the
    /// last byte is the count of runs.
    private func pages(
        of runs: [(range: Range<Int>, data: [UInt8])], entrySize: Int, appendPage: ([UInt8]) -> Int
    ) -> (plc: [UInt8], pageNumbers: [Int]) {
        var starts: [Int] = []
        var numbers: [Int] = []
        var end = 0
        var index = 0
        while index < runs.count {
            // Take runs while the page can hold them: the offsets, the entries, the modifiers, a word of slack each.
            var taken = 0
            var modifiersSize = 0
            while index + taken < runs.count {
                let next = runs[index + taken].data.count
                let needed = 4 * (taken + 2) + entrySize * (taken + 1) + modifiersSize + next + 2 * (taken + 1) + 1
                if taken > 0, needed > 512 { break }
                modifiersSize += next
                taken += 1
            }
            var page = [UInt8](repeating: 0, count: 512)
            var free = 511
            for (position, run) in runs[index..<index + taken].enumerated() {
                page.replaceSubrange(position * 4..<position * 4 + 4, with: UInt32(run.range.lowerBound).bytes)
                var wordOffset = 0
                if !run.data.isEmpty {
                    free = (free - run.data.count) & ~1
                    page.replaceSubrange(free..<free + run.data.count, with: run.data)
                    wordOffset = free / 2
                }
                page[4 * (taken + 1) + position * entrySize] = UInt8(wordOffset)
            }
            page.replaceSubrange(taken * 4..<taken * 4 + 4, with: UInt32(runs[index + taken - 1].range.upperBound).bytes)
            page[511] = UInt8(taken)
            starts.append(runs[index].range.lowerBound)
            numbers.append(appendPage(page))
            end = runs[index + taken - 1].range.upperBound
            index += taken
        }
        guard !starts.isEmpty else { return ([], []) }
        return ((starts + [end]).flatMap { UInt32($0).bytes } + numbers.flatMap { UInt16($0).bytes }, numbers)
    }

    /// The style sheet: its header, and each style's base, name, and property groups.
    private func styleSheet() -> [UInt8] {
        // Stshi: the count of styles, the base's size (8), flags, and the rest, 14 bytes in all.
        var header: [UInt8] = UInt16(styles.count).bytes + UInt16(8).bytes + UInt16(1).bytes
        header += [UInt8](repeating: 0, count: 14 - header.count)
        var sheet: [UInt8] = UInt16(14).bytes + header
        for (index, style) in styles.enumerated() {
            guard let style else {
                sheet += UInt16(0).bytes
                continue
            }
            var std: [UInt8] = []
            std += UInt16(style.sti | 0x4000).bytes
            std += UInt16(style.kind | style.basedOn << 4).bytes
            std += UInt16((style.kind == 1 ? 2 : 1) | index << 4).bytes
            std += UInt16(0).bytes
            // The name: a size byte, the characters, a null; the groups begin on a word.
            let name = Array(style.name.utf8)
            std += [UInt8(name.count)] + name + [0]
            if std.count % 2 != 0 { std.append(0) }
            /// A group: a 16-bit size, the bytes, and a pad to a word.
            func group(_ bytes: [UInt8]) -> [UInt8] { UInt16(bytes.count).bytes + bytes + (bytes.count % 2 != 0 ? [0] : []) }
            if style.kind == 1 {
                std += group(UInt16(index).bytes + style.paragraphSprms)
                std += group(style.characterSprms)
            } else {
                std += group(style.characterSprms)
            }
            std.replaceSubrange(6..<8, with: UInt16(std.count).bytes)
            if index == damagedStyle, let groupAt = std.indices.first(where: { $0 >= 8 + name.count + 2 && $0 % 2 == 0 }) {
                // The first group's size is larger than the style.
                std.replaceSubrange(groupAt..<groupAt + 2, with: UInt16(0x7FFF).bytes)
            }
            sheet += UInt16(std.count).bytes + std
        }
        return sheet
    }

    /// The font table: a 16-bit size, then each font as a size byte, flags, a weight, its character set, a
    /// place for the name, and the name with its null.
    private func fontTable() -> [UInt8] {
        guard !fontCharacterSets.isEmpty else { return [] }
        let fonts = fontCharacterSets.enumerated().map { index, set -> [UInt8] in
            let name = index < fontNames.count ? fontNames[index] : "Font\(index)"
            let body: [UInt8] = [0x10, 0x90, 0x01, UInt8(set), 0] + Array(name.utf8) + [0]
            return [UInt8(body.count)] + body
        }
        return UInt16(fonts.reduce(0) { $0 + $1.count }).bytes + fonts.flatMap { $0 }
    }

    /// The section table (a PLC of the sections' ends and a 12-byte descriptor each); each section's
    /// properties (a 16-bit size and its sprms) are appended to `stream` first.
    private func sectionTable(appendingPropertiesTo stream: inout [UInt8]) -> [UInt8] {
        guard !sections.isEmpty else { return [] }
        var descriptors: [UInt8] = []
        for section in sections {
            var offset = 0xFFFF_FFFF
            if let kind = section.breakKind {
                offset = stream.count
                let sprms = Self.sprm(142, [kind])
                stream += UInt16(sprms.count).bytes + sprms
            }
            descriptors += [0, 0] + UInt32(offset).bytes + [0, 0, 0, 0, 0, 0]
        }
        return ([0] + sections.map { $0.end }).flatMap { UInt32($0).bytes } + descriptors
    }
}

// MARK: - Little-Endian Bytes

private extension UInt16 {
    /// The two bytes, least significant first.
    var bytes: [UInt8] { [UInt8(truncatingIfNeeded: self), UInt8(truncatingIfNeeded: self >> 8)] }
}

private extension UInt32 {
    /// The four bytes, least significant first.
    var bytes: [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: self >> (8 * UInt32($0))) } }
}
