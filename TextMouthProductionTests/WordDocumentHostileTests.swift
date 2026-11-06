import XCTest
@testable import TextMouth

/// The Word 97-2003 reader on hostile files (FMT47): documents whose offsets,
/// counts, and indexes do not fit. Each must end with the typed failure the
/// reader gives for a document it cannot read, never a crash, and in well
/// under a second. The compound file beneath is tested by `CompoundFileTests`.
final class WordDocumentHostileTests: XCTestCase {

    // MARK: - Helpers

    typealias Paragraph = WordDocumentBuilder.Paragraph
    typealias Run = WordDocumentBuilder.Run

    private let unreadable = TextutilConverter.Failure.unreadable(.doc)

    /// A document with every structure the reader reads: headings, runs of
    /// emphasis, a table, a field, page and section breaks, and three pieces.
    private func richDocument() -> WordDocumentBuilder {
        let inTable = WordDocumentBuilder.modifier(WordSprm.inTable, 1)
        var builder = WordDocumentBuilder()
        builder.pieceCount = 3
        builder.sectionBreaks = [(5, 2)]
        builder.title = "Title"
        builder.author = "Author"
        builder.paragraphs = [
            Paragraph("Chapter one", style: 1),
            Paragraph(runs: [Run("Plain "), Run("bold", bold: 1), Run(" and "), Run("italic", italic: 1), Run(".")]),
            Paragraph("A field \u{13} PAGE \u{14}7\u{15} result and a page\u{0C} break."),
            Paragraph("a", modifiers: inTable, mark: 0x07),
            Paragraph("b", modifiers: inTable, mark: 0x07),
            Paragraph("", modifiers: inTable + WordDocumentBuilder.modifier(WordSprm.rowEnd, 1), mark: 0x07),
            Paragraph("End of the first section.", mark: 0x0C),
            Paragraph("Second section.", style: 2),
        ]
        return builder
    }

    /// Asserts that reading `data` ends with the unreadable failure in under a second.
    private func assertUnreadable(_ data: Data, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let start = Date()
        XCTAssertThrowsError(try WordDocumentReader.html(from: data, includesPages: true), message, file: file, line: line) { error in
            XCTAssertEqual(error as? TextutilConverter.Failure, unreadable, message, file: file, line: line)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, message, file: file, line: line)
    }

    /// Asserts that reading `data` gives HTML, or fails with an error the
    /// reader or the importer gives for a document it cannot read, in under
    /// a second: the contract for any damaged file.
    private func assertSurvives(_ data: Data, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let start = Date()
        do {
            _ = try WordDocumentReader.html(from: data, includesPages: true)
        } catch {
            let known = error is TextutilConverter.Failure || error is PasswordProtectedDocument || error is DocumentTooLargeError
            XCTAssertTrue(known, "\(message): \(error)", file: file, line: line)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, message, file: file, line: line)
    }

    /// `builder`'s document with the table stream changed by `change`.
    private func damaged(
        _ builder: WordDocumentBuilder,
        table change: @escaping (inout [UInt8], WordDocumentBuilder.Layout) -> Void = { _, _ in },
        word changeWord: @escaping (inout [UInt8], WordDocumentBuilder.Layout) -> Void = { _, _ in }
    ) -> Data {
        builder.build { word, table, layout in
            change(&table, layout)
            changeWord(&word, layout)
        }
    }

    private func le32(_ value: Int) -> [UInt8] { WordDocumentBuilder.le32(value) }
    private func le16(_ value: Int) -> [UInt8] { WordDocumentBuilder.le16(value) }

    /// Writes `bytes` at `offset`.
    private func put(_ bytes: [UInt8], at offset: Int, in stream: inout [UInt8]) {
        stream.replaceSubrange(offset..<offset + bytes.count, with: bytes)
    }

    // MARK: - The Undamaged Document

    func testTheRichDocumentReads() throws {
        let html = try XCTUnwrap(WordDocumentReader.html(from: richDocument().build(), includesPages: true))
        XCTAssertTrue(html.contains("<h1>Chapter one</h1>"), html)
        XCTAssertTrue(html.contains("<strong>bold</strong>"), html)
        XCTAssertTrue(html.contains("<table>"), html)
        XCTAssertTrue(html.contains("A field 7 result and a page"), html)
        XCTAssertTrue(html.contains("aria-label=\"3\""), html)
    }

    // MARK: - The Piece Table

    func testAPieceWhoseOffsetLeavesTheStreamIsRefused() {
        for compressed in [true, false] {
            var builder = richDocument()
            builder.isCompressed = compressed
            builder.pieceCount = 1
            let data = damaged(builder, table: { table, layout in
                // The first descriptor's file offset, after 2 flag bytes.
                let offset = layout.pieceTable + 2 * 4 + 2
                self.put(self.le32(compressed ? (0x3FFF_FF00 | 0x4000_0000) : 0x3FFF_FF00), at: offset, in: &table)
            })
            assertUnreadable(data, "a piece offset past the stream, compressed \(compressed)")
        }
    }

    func testAPieceWhoseCharactersRunPastTheEndOfTheStreamIsRefused() {
        var builder = richDocument()
        builder.pieceCount = 1
        // The last character position is made larger than the stream can hold.
        let data = damaged(builder, table: { table, layout in
            self.put(self.le32(5_000_000), at: layout.pieceTable + 4, in: &table)
        })
        assertUnreadable(data, "a piece longer than the stream")
        assertUnreadable(damaged(builder, table: { table, layout in
            self.put(self.le32(0xFFFF_FFFF), at: layout.pieceTable + 4, in: &table)
        }), "a piece of 4 billion characters")
    }

    func testCharacterPositionsThatDoNotAddUpAreRefused() {
        let builder = richDocument()
        // The text does not begin at 0.
        assertUnreadable(damaged(builder, table: { table, layout in
            self.put(self.le32(5), at: layout.pieceTable, in: &table)
        }), "first position 5")
        // A piece ends before it begins.
        assertUnreadable(damaged(builder, table: { table, layout in
            self.put(self.le32(1), at: layout.pieceTable + 4, in: &table)
            self.put(self.le32(0), at: layout.pieceTable + 8, in: &table)
        }), "positions go back")
    }

    func testAMalformedClxIsRefused() {
        let builder = richDocument()
        // A block of an unknown kind.
        assertUnreadable(damaged(builder, table: { table, layout in table[layout.clx] = 7 }), "kind 7")
        // A piece table larger than the CLX, and one that is not a whole number of pieces.
        assertUnreadable(damaged(builder, table: { table, layout in
            self.put(self.le32(0xFFFF_FFFF), at: layout.clx + 1, in: &table)
        }), "piece table of 4 GB")
        assertUnreadable(damaged(builder, table: { table, layout in
            let length = (table[layout.clx + 1]) &+ 1
            table[layout.clx + 1] = length
        }), "piece table of an odd size")
        // A group of modifiers that runs past the CLX.
        assertUnreadable(damaged(builder, table: { table, layout in
            table[layout.clx] = 1
            self.put(self.le16(0xFFFF), at: layout.clx + 1, in: &table)
        }), "modifier group of 64 KB")
        // No piece table at all.
        assertUnreadable(damaged(builder, table: { table, layout in
            table[layout.clx] = 1
            self.put(self.le16(0), at: layout.clx + 1, in: &table)
            // The bytes after the empty group are the old piece table's size; make them a third kind.
            table[layout.clx + 3] = 0x09
        }), "a block of kind 9 after an empty modifier group")
    }

    func testAPieceModifierNamingAGroupThatIsNotThereIsRefused() {
        var builder = richDocument()
        builder.modifierGroups = [WordDocumentBuilder.modifier(WordSprm.bold, 1)]
        // The group at index 0 exists; index 1 and the largest index of 15 bits do not.
        for index in [0, 1, 0x7FFF] {
            builder.piecePrms = [0, WordDocumentBuilder.prm1(index)]
            if index == 0 {
                XCTAssertNoThrow(try WordDocumentReader.html(from: builder.build(), includesPages: true), "group 0")
            } else {
                assertUnreadable(builder.build(), "a modifier group at index \(index) of 1")
            }
        }
    }

    func testMoreGroupsOfModifiersThanAnIndexCanNameAreRefused() {
        var builder = richDocument()
        builder.modifierGroups = [[UInt8]](repeating: [], count: 0x8001)
        assertUnreadable(builder.build(), "32,769 groups")
        // Exactly as many as an index can name read fine.
        builder.modifierGroups = [[UInt8]](repeating: [], count: 0x8000)
        XCTAssertNoThrow(try WordDocumentReader.html(from: builder.build(), includesPages: true), "32,768 groups")
    }

    func testAGroupOfModifiersWithDamagedSprmsOnlyLosesFormatting() {
        var builder = richDocument()
        // An operand that runs past the group, a size byte past it, and the rest of an opcode.
        builder.modifierGroups = [[0x35, 0x08], [0x08, 0xD6, 0xFF], [0x35], [0x15, 0xC6, 0xFF, 0x01]]
        for index in 0..<4 {
            builder.piecePrms = [WordDocumentBuilder.prm1(index), WordDocumentBuilder.prm1(index), WordDocumentBuilder.prm1(index)]
            assertSurvives(builder.build(), "damaged group \(index)")
        }
    }

    func testATextLengthLargerThanTheTextIsReadAsFarAsTheTextGoes() throws {
        let data = richDocument().build { word, _, _ in
            word.replaceSubrange(64 + 12..<64 + 16, with: WordDocumentBuilder.le32(0xFFFF_FFFF))
        }
        let html = try XCTUnwrap(WordDocumentReader.html(from: data, includesPages: true))
        XCTAssertTrue(html.contains("Second section."), html)
        // And zero: a main story with no words reads the rest of the text, so nothing is lost.
        let none = richDocument().build { word, _, _ in
            word.replaceSubrange(64 + 12..<64 + 16, with: WordDocumentBuilder.le32(0))
        }
        XCTAssertTrue(try XCTUnwrap(WordDocumentReader.html(from: none, includesPages: true)).contains("Second section."))
    }

    func testStoryLengthsThatDoNotFitTheTextAreCutNotTrusted() throws {
        var builder = richDocument()
        builder.stories = [.footnotes: [Paragraph("Footnote words.")], .endnotes: [Paragraph("Endnote words.")]]
        // Every length in the FIB, in turn, as large as it can be, and the main text longer than the text.
        for offset in [76, 80, 84, 88, 92, 96, 100, 104] {
            for value in [0xFFFF_FFFF, 0x7FFF_FFFF, 1_000_000] {
                let data = builder.build { word, _, _ in
                    word.replaceSubrange(offset..<offset + 4, with: WordDocumentBuilder.le32(value))
                }
                assertSurvives(data, "FIB length at \(offset) of \(value)")
            }
        }
    }

    // MARK: - The FIB

    func testFIBFieldsThatDoNotFitAreRefused() {
        let builder = richDocument()
        assertUnreadable(builder.build { word, _, _ in word.replaceSubrange(2..<4, with: WordDocumentBuilder.le16(0x7FFF)) }, "nFib 0x7FFF")
        assertUnreadable(builder.build { word, _, _ in word.replaceSubrange(32..<34, with: WordDocumentBuilder.le16(0xFFFF)) }, "csw 65535")
        assertUnreadable(builder.build { word, _, _ in word.replaceSubrange(62..<64, with: WordDocumentBuilder.le16(0xFFFF)) }, "cslw 65535")
        assertUnreadable(builder.build { word, _, _ in word.replaceSubrange(62..<64, with: WordDocumentBuilder.le16(2)) }, "cslw 2")
        assertUnreadable(builder.build { word, _, _ in word.replaceSubrange(152..<154, with: WordDocumentBuilder.le16(0xFFFF)) }, "65535 pairs")
        assertUnreadable(builder.build { word, _, _ in word.replaceSubrange(152..<154, with: WordDocumentBuilder.le16(10)) }, "10 pairs")
        assertUnreadable(builder.build { word, _, _ in word.replaceSubrange(0..<2, with: WordDocumentBuilder.le16(0x1234)) }, "wIdent 0x1234")
        // A WordDocument stream shorter than a FIB.
        assertUnreadable(builder.build { word, _, _ in word = Array(word.prefix(40)) }, "a stream of 40 bytes")
    }

    func testStructuresWhoseOffsetsLeaveTheTableStreamAreRefused() {
        let builder = richDocument()
        let pairs = WordDocumentBuilder.Layout().pairs
        // Every structure in turn: the style sheet (1), sections (6), the two bin tables (12, 13), the CLX (33).
        for index in [1, 6, 12, 13, 33] {
            assertUnreadable(builder.build { word, _, _ in
                word.replaceSubrange(pairs + index * 8..<pairs + index * 8 + 4, with: WordDocumentBuilder.le32(0x00FF_FFFF))
            }, "structure \(index) at an offset past the table")
            assertUnreadable(builder.build { word, _, _ in
                word.replaceSubrange(pairs + index * 8 + 4..<pairs + index * 8 + 8, with: WordDocumentBuilder.le32(0xFFFF_FFFF))
            }, "structure \(index) of 4 GB")
        }
    }

    func testTheCLXIsRequired() {
        let pairs = WordDocumentBuilder.Layout().pairs
        assertUnreadable(richDocument().build { word, _, _ in
            word.replaceSubrange(pairs + 33 * 8 + 4..<pairs + 33 * 8 + 8, with: WordDocumentBuilder.le32(0))
        }, "a CLX of no length")
    }

    // MARK: - The Style Sheet

    func testAStyleSheetCutShortHasOnlyTheStylesItHolds() throws {
        let builder = richDocument()
        // A sheet cut short is read as far as it goes (real files are: the
        // slots past the length the header gives are unused), the styles it
        // does not hold in full are unused, and a paragraph in one has the
        // default formatting, so the document reads, with no headings.
        for (message, damage) in [
            ("65535 styles", { (table: inout [UInt8], layout: WordDocumentBuilder.Layout) in
                table.replaceSubrange(layout.styleSheet + 2..<layout.styleSheet + 4, with: [0xFF, 0xFF])
            }),
            ("a style of 64 KB", { (table: inout [UInt8], layout: WordDocumentBuilder.Layout) in
                table.replaceSubrange(layout.styleSheet + 2 + 18..<layout.styleSheet + 2 + 20, with: [0xFF, 0xFF])
            }),
            ("a header of 64 KB", { (table: inout [UInt8], layout: WordDocumentBuilder.Layout) in
                table.replaceSubrange(layout.styleSheet..<layout.styleSheet + 2, with: [0xFF, 0xFF])
            }),
        ] {
            let html = try XCTUnwrap(WordDocumentReader.html(from: damaged(builder, table: damage), includesPages: true), message)
            XCTAssertTrue(html.contains("Chapter one"), message)
            XCTAssertFalse(html.contains("<h1>"), message)
        }
    }

    func testAStyleSheetWhoseFixedPartDoesNotFitIsRefused() {
        let builder = richDocument()
        // A fixed part larger than the style.
        assertUnreadable(damaged(builder, table: { table, layout in
            self.put(self.le16(0xFFFF), at: layout.styleSheet + 4, in: &table)
        }), "a fixed part of 64 KB")
        assertUnreadable(damaged(builder, table: { table, layout in
            self.put(self.le16(2), at: layout.styleSheet + 4, in: &table)
        }), "a fixed part of 2 bytes")
    }

    func testAStyleIndexPastTheStyleSheetHasTheDefaultFormatting() throws {
        // [MS-DOC] sprmPIstd: a style that is empty or does not exist is the
        // default formatting. Real files name style 0xFFFF, or one past the sheet.
        var builder = WordDocumentBuilder()
        builder.paragraphs = [
            Paragraph("in style 200", style: 200),
            Paragraph("in style 0xFFFF", style: 0xFFFF),
            Paragraph(runs: [Run("in character style 200", characterStyle: 200)]),
            Paragraph("set by a modifier", modifiers: WordDocumentBuilder.le16(WordSprm.paragraphStyle) + WordDocumentBuilder.le16(300)),
        ]
        XCTAssertEqual(
            try wordBody(of: builder.build()),
            "<p>in style 200</p>\n<p>in style 0xFFFF</p>\n<p>in character style 200</p>\n<p>set by a modifier</p>\n"
        )
    }

    func testStyleIndexesOfNoStyleAreBodyText() throws {
        var builder = WordDocumentBuilder()
        builder.paragraphs = [Paragraph("none", style: 0x0FFF)]
        XCTAssertTrue(try XCTUnwrap(WordDocumentReader.html(from: builder.build(), includesPages: false)).contains("<p>none</p>"))
    }

    // MARK: - Properties

    func testAPageNumberPastTheStreamIsRefused() {
        let builder = richDocument()
        assertUnreadable(damaged(builder, table: { table, layout in
            // The page number of the first page, after its 2 file offsets.
            let plc = layout.paragraphBinTable
            self.put(self.le32(0x003F_FFFF), at: plc + 8, in: &table)
        }), "a paragraph page at 2 GB")
        assertUnreadable(damaged(builder, table: { table, layout in
            self.put(self.le32(0x003F_FFFF), at: layout.characterBinTable + 8, in: &table)
        }), "a character page at 2 GB")
    }

    func testABinTableOfTheWrongSizeIsRefused() {
        let pairs = WordDocumentBuilder.Layout().pairs
        for index in [12, 13] {
            for length in [1, 7, 13, 21] {
                assertUnreadable(richDocument().build { word, _, _ in
                    word.replaceSubrange(pairs + index * 8 + 4..<pairs + index * 8 + 8, with: WordDocumentBuilder.le32(length))
                }, "a bin table of \(length) bytes")
            }
        }
    }

    func testAPageWhoseRunsLeaveItIsRefused() {
        let builder = richDocument()
        // Paragraph page: the count of runs larger than a page holds.
        assertUnreadable(damaged(builder, word: { word, layout in word[layout.paragraphPages[0] + 511] = 255 }), "255 paragraph runs")
        assertUnreadable(damaged(builder, word: { word, layout in word[layout.characterPages[0] + 511] = 255 }), "255 character runs")
        // A run that ends before it begins.
        assertUnreadable(damaged(builder, word: { word, layout in
            self.put(self.le32(0xFFFF_FFF0), at: layout.paragraphPages[0], in: &word)
        }), "a run that begins after it ends")
        // A run's properties at the page's last bytes, leaving the page.
        assertUnreadable(damaged(builder, word: { word, layout in
            let crun = Int(word[layout.paragraphPages[0] + 511])
            word[layout.paragraphPages[0] + (crun + 1) * 4] = 255
        }), "paragraph properties at offset 510 of the page")
        assertUnreadable(damaged(builder, word: { word, layout in
            let crun = Int(word[layout.characterPages[0] + 511])
            // Character runs: the first run's entry; with a size larger than the page.
            // The first run's properties are at the page's offset 510, which holds a size of 200.
            word[layout.characterPages[0] + (crun + 1) * 4] = 255
            word[layout.characterPages[0] + 510] = 200
        }), "character properties of 200 bytes at the page's end")
    }

    func testPropertiesAtOffsetsOutsideTheirPageAreRefusedOrHarmless() {
        // Every offset byte of every run of the first page, set to an offset
        // at or past the page's end (0xFF) or into its middle (0x80, 0xFE).
        for byte in [0xFF, 0xFE, 0x80] {
            let paragraphs = damaged(richDocument(), word: { word, layout in
                let page = layout.paragraphPages[0]
                let crun = Int(word[page + 511])
                for run in 0..<crun { word[page + (crun + 1) * 4 + run * 13] = UInt8(byte) }
            })
            if byte == 0xFF {
                assertUnreadable(paragraphs, "offset byte \(byte)")
            } else {
                assertSurvives(paragraphs, "offset byte \(byte)")
            }
        }
    }

    // MARK: - Sections

    func testASectionWhosePropertiesLeaveTheStreamIsRefused() {
        let builder = richDocument()
        assertUnreadable(damaged(builder, table: { table, layout in
            // The first descriptor: 2 bytes, then the properties' offset. Two sections: 3 positions, then descriptors.
            self.put(self.le32(0x7FFF_FFF0), at: layout.sectionTable + 3 * 4 + 2, in: &table)
        }), "section properties at 2 GB")
        let pairs = WordDocumentBuilder.Layout().pairs
        assertUnreadable(builder.build { word, _, _ in
            word.replaceSubrange(pairs + 6 * 8 + 4..<pairs + 6 * 8 + 8, with: WordDocumentBuilder.le32(7))
        }, "a section table of 7 bytes")
    }

    // MARK: - Fields and Counts

    func testFieldsNestedTooDeepAreRefused() {
        var builder = WordDocumentBuilder()
        builder.paragraphs = [Paragraph(String(repeating: "\u{13}", count: 10_001))]
        assertUnreadable(builder.build(), "10001 fields open")
    }

    func testDeeplyNestedFieldsBelowTheLimitReadWithoutRecursion() throws {
        var builder = WordDocumentBuilder()
        let depth = 5_000
        builder.paragraphs = [Paragraph(String(repeating: "\u{13}x\u{14}", count: depth) + "deep" + String(repeating: "\u{15}", count: depth))]
        let start = Date()
        let html = try XCTUnwrap(WordDocumentReader.html(from: builder.build(), includesPages: true))
        XCTAssertTrue(html.contains("deep"), html)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testAnOutputPastTheLimitIsRefusedWithTheTooLargeSentence() {
        var builder = WordDocumentBuilder()
        builder.paragraphs = (0..<2_000).map { _ in Paragraph(String(repeating: "word ", count: 20)) }
        let data = builder.build()
        do {
            // The limit is bound for this read alone.
            _ = try DocumentByteLimit.$current.withValue(10_000) {
                try WordDocumentReader.html(from: data, includesPages: false)
            }
            XCTFail("the output passed the limit and was written")
        } catch {
            XCTAssertTrue(error is DocumentTooLargeError, "\(error)")
        }
    }

    // MARK: - The Lists

    /// A document with a list of nine levels, its instance, and two paragraphs in it.
    private func listedDocument() -> WordDocumentBuilder {
        var builder = WordDocumentBuilder()
        builder.lists = [WordDocumentBuilder.List(identifier: 7, levels: (0..<9).map { WordDocumentBuilder.ListLevel(0, "%\($0 + 1).") })]
        builder.listInstances = [WordDocumentBuilder.ListInstance(listIdentifier: 7)]
        let inList = WordDocumentBuilder.listProperties(instance: 1, level: 0)
        builder.paragraphs = [Paragraph("Chapter one", modifiers: inList), Paragraph("Chapter two", modifiers: inList)]
        return builder
    }

    /// Asserts that `data` reads, in under a second, as a document that still holds its words.
    private func assertStillReads(_ data: Data, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let start = Date()
        for speaks in [true, false] {
            do {
                let html = try WordDocumentReader.html(from: data, includesPages: true, speaksListNumbers: speaks)
                XCTAssertTrue(try XCTUnwrap(html).contains("Chapter two"), message, file: file, line: line)
            } catch {
                XCTFail("\(message): \(error)", file: file, line: line)
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, message, file: file, line: line)
    }

    func testTheListTablesCutOffAtManyLengthsLoseTheNumbersAndNotTheDocument() {
        let builder = listedDocument()
        // The tables are at the end of the table stream, so cutting it there cuts them.
        for length in stride(from: 0, through: 700, by: 5) {
            assertStillReads(builder.build { _, table, layout in
                table.removeSubrange(min(layout.listFormats + length, table.count)...)
            }, "table stream cut \(length) bytes into the list tables")
        }
    }

    func testListTablesWithCountsAtTheMaximumOrOffsetsPastTheEndLoseTheNumbersAndNotTheDocument() {
        let builder = listedDocument()
        // Counts of lists and of instances as large as they can be written.
        for count in [0x7FFF, 0xFFFF] {
            assertStillReads(damaged(builder, table: { table, layout in
                self.put(self.le16(count), at: layout.listFormats, in: &table)
            }), "\(count) lists")
        }
        for count in [0x7FF, 0x1_0000, 3_000_000, 0x7FFF_FFFF, 0xFFFF_FFFF] {
            assertStillReads(damaged(builder, table: { table, layout in
                self.put(self.le32(count), at: layout.listOverrides, in: &table)
            }), "\(count) list instances")
        }
        // Each list table's offset and length in the FIB, pointed past the end.
        for structure in [WordFileInformationBlock.Structure.listFormats, .listOverrides] {
            for (offset, length) in [(0x7FFF_FFF0, 100), (0, 0x7FFF_FFF0), (0xFFFF_FFFF, 0xFFFF_FFFF)] {
                assertStillReads(damaged(builder, word: { word, layout in
                    self.put(self.le32(offset) + self.le32(length), at: layout.pairs + structure.rawValue * 8, in: &word)
                }), "\(structure) at \(offset) of \(length) bytes")
            }
        }
    }

    func testAnOverrideWithMoreLevelsThanItHoldsOrALevelPastTheEndLosesTheNumbersAndNotTheDocument() {
        var builder = listedDocument()
        builder.listInstances = [WordDocumentBuilder.ListInstance(listIdentifier: 7, overrides: [
            WordDocumentBuilder.ListOverride(level: 0, replacement: WordDocumentBuilder.ListLevel(0, "%1)", start: 2)),
        ])]
        // The count of overrides (255) larger than the data holds.
        assertStillReads(damaged(builder, table: { table, layout in
            self.put([0xFF], at: layout.listOverrides + 4 + 12, in: &table)
        }), "255 overrides")
        // The number text of a level as long as it can be written.
        assertStillReads(damaged(builder, table: { table, layout in
            self.put(self.le16(0xFFFF), at: layout.listFormats + 2 + 28 + 28, in: &table)
        }), "a level text of 64 K characters")
    }

    func testMoreInstancesThanCanBeNamedAreNotKept() throws {
        // 5,000 instances; a paragraph can name the first 0x7FE only.
        var builder = listedDocument()
        builder.listInstances = (0..<5000).map { _ in WordDocumentBuilder.ListInstance(listIdentifier: 7) }
        builder.paragraphs = [Paragraph("kept", modifiers: WordDocumentBuilder.listProperties(instance: 0x7FE, level: 0))]
        XCTAssertEqual(try wordBody(of: builder.build(), speaksNumbers: true), "<p>1. kept</p>\n")
    }

    // MARK: - Time

    /// Asserts that reading `data` takes under `seconds` and gives HTML.
    private func assertReadsWithin(_ seconds: Double, _ data: Data, _ message: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let start = Date()
        let html = try XCTUnwrap(WordDocumentReader.html(from: data, includesPages: true), message, file: file, line: line)
        XCTAssertLessThan(Date().timeIntervalSince(start), seconds, message, file: file, line: line)
        return html
    }

    func testAChainOfThousandsOfStylesCostsNothingPerParagraph() throws {
        // 4,000 styles each based on the next, a list the deepest one is in, and
        // many paragraphs in it: the chain was walked for each paragraph's
        // heading, page break, list, size, and emphasis (126 microseconds a
        // paragraph; two hours for a 64 MB file).
        var builder = WordDocumentBuilder()
        let first = builder.styles.count
        let depth = 4000
        for index in 0..<depth {
            let based = index == depth - 1 ? 0 : first + index + 1
            builder.styles.append(WordDocumentBuilder.Style(
                basedOn: based, bold: 0x81, hidden: 0x80, listIndex: index == depth - 1 ? 1 : nil, listLevel: index == depth - 1 ? 0 : nil
            ))
        }
        builder.lists = [WordDocumentBuilder.List(identifier: 7, levels: (0..<9).map { WordDocumentBuilder.ListLevel(0, "%\($0 + 1).") })]
        builder.listInstances = [WordDocumentBuilder.ListInstance(listIdentifier: 7)]
        builder.paragraphs = (0..<40_000).map { _ in Paragraph("a", style: first) }
        let html = try assertReadsWithin(2.0, builder.build(), "40,000 paragraphs under a chain of 4,000 styles")
        XCTAssertTrue(html.contains("<li>a"), String(html.prefix(300)))
    }

    func testManyNotesWhoseMarksAreHiddenInManyPiecesCostNothingPerNote() throws {
        // 100,000 one-mark pieces and notes, every other mark hidden: each
        // shown note was read from a walk of every piece before it (a
        // quadratic time: an hour for a 64 MB file).
        let count = 100_000
        var builder = WordDocumentBuilder()
        builder.paragraphs = [Paragraph(runs: [Run("Main.")] + (0..<count).map { Run("\u{02}", hidden: $0 % 2 == 0 ? 1 : nil) })]
        builder.footnoteReferences = (0..<count).map { $0 + 5 }
        builder.stories = [.footnotes: (0..<count).map { _ in Paragraph("n") }]
        builder.pieceCount = count
        let html = try assertReadsWithin(1.0, builder.build(), "100,000 notes in 100,000 pieces")
        // The shown notes are the odd ones, 50,000 of them, each a paragraph.
        XCTAssertEqual(html.components(separatedBy: "<p>n</p>").count - 1, count / 2)
    }

    // MARK: - Truncation and Random Damage

    func testTruncationAtManyLengthsNeverCrashes() throws {
        let documents = [
            ("rich", richDocument().build()),
            ("headings.doc", try Data(contentsOf: formatSampleURL("doc/headings.doc"))),
            ("tdf81705", try Data(contentsOf: formatSampleURL("doc/libreoffice-tdf81705_outlineLevel.doc"))),
        ]
        for (name, data) in documents {
            for length in stride(from: 0, to: data.count, by: 251) {
                assertSurvives(data.prefix(length), "\(name) truncated to \(length)")
            }
        }
    }

    func testRandomByteFlipsInTheStreamsNeverCrashOrHang() throws {
        var generator = SplitMix64(seed: 20_261_104)
        let builder = richDocument()
        // Flips inside the streams themselves, where the structures are.
        for round in 0..<400 {
            let data = builder.build { word, table, _ in
                for _ in 0..<(1 + round % 6) {
                    if round % 2 == 0 {
                        word[Int.random(in: 0..<word.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
                    } else {
                        table[Int.random(in: 0..<table.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
                    }
                }
            }
            assertSurvives(data, "rich document, round \(round)")
        }
    }

    func testRandomByteFlipsInTheSamplesNeverCrashOrHang() throws {
        var generator = SplitMix64(seed: 20_261_105)
        for sample in ["doc/headings.doc", "doc/libreoffice-tdf104239_chapterNumbering.doc", "doc/page-breaks.doc"] {
            let original = try Data(contentsOf: formatSampleURL(sample))
            for round in 0..<200 {
                var data = original
                for _ in 0..<(1 + round % 8) {
                    data[Int.random(in: 0..<data.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
                }
                assertSurvives(data, "\(sample), round \(round)")
            }
        }
    }
}
