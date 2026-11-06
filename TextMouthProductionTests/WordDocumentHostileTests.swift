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

    func testAStyleSheetWhoseCountsDoNotFitIsRefused() {
        let builder = richDocument()
        // The count of styles larger than the sheet.
        assertUnreadable(damaged(builder, table: { table, layout in
            self.put(self.le16(0xFFFF), at: layout.styleSheet + 2, in: &table)
        }), "65535 styles")
        // A style's size past the sheet.
        assertUnreadable(damaged(builder, table: { table, layout in
            let first = layout.styleSheet + 2 + 18
            self.put(self.le16(0xFFFF), at: first, in: &table)
        }), "a style of 64 KB")
        // A fixed part larger than the style.
        assertUnreadable(damaged(builder, table: { table, layout in
            self.put(self.le16(0xFFFF), at: layout.styleSheet + 4, in: &table)
        }), "a fixed part of 64 KB")
        assertUnreadable(damaged(builder, table: { table, layout in
            self.put(self.le16(2), at: layout.styleSheet + 4, in: &table)
        }), "a fixed part of 2 bytes")
        // The header's own size past the sheet.
        assertUnreadable(damaged(builder, table: { table, layout in
            self.put(self.le16(0xFFFF), at: layout.styleSheet, in: &table)
        }), "a header of 64 KB")
    }

    func testAStyleIndexPastTheStyleSheetIsRefused() {
        var builder = richDocument()
        builder.paragraphs.append(Paragraph("lost", style: 200))
        assertUnreadable(builder.build(), "a paragraph in style 200")
        builder = richDocument()
        builder.paragraphs.append(Paragraph(runs: [Run("lost", characterStyle: 200)]))
        assertUnreadable(builder.build(), "a run in character style 200")
        // The paragraph style set by a modifier.
        builder = richDocument()
        builder.paragraphs.append(Paragraph("lost", modifiers: WordDocumentBuilder.le16(WordSprm.paragraphStyle) + WordDocumentBuilder.le16(300)))
        assertUnreadable(builder.build(), "a style modifier of 300")
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
