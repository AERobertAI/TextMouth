import XCTest
@testable import TextMouth

/// A Word document keeps its structure in the reading TextMouth makes of it
/// (TODO T05): list levels are matched by their identity, with their start
/// values, restart rules, and per-instance overrides. Each test builds a
/// minimal DOCX package in memory and reads it through `DOCXParser`, the
/// path every import takes, or parses one part with its production parser.
final class DOCXStructureTests: XCTestCase {

    // MARK: - List Level Identity

    /// A definition may list its levels in any order and leave some out.
    /// Each level is found by the index it declares: here level 0 is a
    /// bullet and level 2 is numbered although level 2 comes first, and
    /// level 1, which is not defined, has no number to give.
    func testListLevelsAreFoundByTheirIndexNotTheirPosition() throws {
        let numbering = try Self.numbering("""
        <w:abstractNum w:abstractNumId="7">
        <w:lvl w:ilvl="2"><w:numFmt w:val="lowerRoman"/></w:lvl>
        <w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/></w:lvl>
        </w:abstractNum>
        <w:num w:numId="3"><w:abstractNumId w:val="7"/></w:num>
        """)

        XCTAssertEqual(numbering.listType(numId: "3", level: 0), .bullet)
        XCTAssertEqual(numbering.listType(numId: "3", level: 2), .numbered)
        XCTAssertNil(numbering.levelFormat(numId: "3", level: 1))
        XCTAssertEqual(numbering.listType(numId: "3", level: 1), .bullet)
    }

    /// Levels written out of order still number the paragraphs that name
    /// them: the bulleted outer steps keep their bullets and the numbered
    /// inner steps their numbers, each heard once.
    func testOutOfOrderLevelsFormatTheParagraphsThatNameThem() throws {
        let reading = try read(body: [
            Self.listItem("Gather the signatures", numId: "1", level: 0),
            Self.listItem("Fold each sheet", numId: "1", level: 1),
            Self.listItem("Press the folds", numId: "1", level: 1),
            Self.listItem("Sew the stack", numId: "1", level: 0)
        ], numbering: """
        <w:abstractNum w:abstractNumId="0">
        <w:lvl w:ilvl="1"><w:numFmt w:val="decimal"/></w:lvl>
        <w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/></w:lvl>
        </w:abstractNum>
        <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
        """)

        XCTAssertEqual(reading.markdown, """
        - Gather the signatures
            1. Fold each sheet
            2. Press the folds
        - Sew the stack
        """)
        XCTAssertEqual(reading.spoken, """
        Gather the signatures

        Fold each sheet

        Press the folds

        Sew the stack
        """)
    }

    /// A level that names no number format is decimal (ISO/IEC 29500-1
    /// §17.9.17), so its paragraphs are numbered rather than bulleted.
    func testLevelWithoutANumberFormatIsDecimal() throws {
        let numbering = try Self.numbering("""
        <w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:start w:val="1"/></w:lvl></w:abstractNum>
        <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
        """)

        XCTAssertEqual(numbering.levelFormat(numId: "1", level: 0)?.numFmt, "decimal")
        XCTAssertEqual(numbering.listType(numId: "1", level: 0), .numbered)
    }

    /// Word writes a custom number format twice inside mc:AlternateContent,
    /// once for itself and once as a fallback. Both describe one level, so
    /// the next level keeps its own format instead of inheriting one.
    func testAlternateNumberFormatsDescribeOneLevel() throws {
        let numbering = try Self.numbering("""
        <w:abstractNum w:abstractNumId="0"
         xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006">
        <w:lvl w:ilvl="0"><mc:AlternateContent>
        <mc:Choice Requires="w14"><w:numFmt w:val="custom" w:format="01, 02, 03, ..."/></mc:Choice>
        <mc:Fallback><w:numFmt w:val="decimalZero"/></mc:Fallback>
        </mc:AlternateContent></w:lvl>
        <w:lvl w:ilvl="1"><w:numFmt w:val="bullet"/></w:lvl>
        </w:abstractNum>
        <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
        """)

        XCTAssertEqual(numbering.listType(numId: "1", level: 0), .numbered)
        XCTAssertEqual(numbering.listType(numId: "1", level: 1), .bullet)
        XCTAssertNil(numbering.levelFormat(numId: "1", level: 2))
    }

    /// A level whose index is missing, not a number, or outside the nine a
    /// list allows matches no paragraph, so it is skipped and cannot take
    /// the place of a level that is defined.
    func testLevelsWithoutAValidIndexAreSkipped() throws {
        let numbering = try Self.numbering("""
        <w:abstractNum w:abstractNumId="0">
        <w:lvl><w:numFmt w:val="upperRoman"/></w:lvl>
        <w:lvl w:ilvl="first"><w:numFmt w:val="upperRoman"/></w:lvl>
        <w:lvl w:ilvl="-1"><w:numFmt w:val="upperRoman"/></w:lvl>
        <w:lvl w:ilvl="9"><w:numFmt w:val="upperRoman"/></w:lvl>
        <w:lvl w:ilvl="1"><w:numFmt w:val="bullet"/></w:lvl>
        </w:abstractNum>
        <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
        """)

        XCTAssertEqual(numbering.abstractNums["0"].map { Set($0.keys) }, [1])
        XCTAssertEqual(numbering.listType(numId: "1", level: 1), .bullet)
    }

    // MARK: - Start Values, Restarts, and Overrides

    /// A level keeps the number it starts from (`w:start`) and when it
    /// restarts (`w:lvlRestart`). A level naming neither starts from 1 and
    /// leaves its restart to the default.
    func testLevelsKeepTheirStartAndRestartValues() throws {
        let numbering = try Self.numbering("""
        <w:abstractNum w:abstractNumId="0">
        <w:lvl w:ilvl="0"><w:start w:val="4"/><w:numFmt w:val="decimal"/></w:lvl>
        <w:lvl w:ilvl="1"><w:numFmt w:val="lowerLetter"/><w:lvlRestart w:val="0"/></w:lvl>
        <w:lvl w:ilvl="2"><w:start w:val="0"/><w:numFmt w:val="lowerRoman"/><w:lvlRestart w:val="1"/></w:lvl>
        <w:lvl w:ilvl="3"><w:lvlRestart w:val="-2"/></w:lvl>
        </w:abstractNum>
        <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
        """)

        let levels = try (0...3).map { try XCTUnwrap(numbering.levelFormat(numId: "1", level: $0)) }
        XCTAssertEqual(levels.map(\.start), [4, 1, 0, 1])
        XCTAssertEqual(levels.map(\.restartAfter), [nil, 0, 1, nil])
    }

    /// Start values are held to the numbers a Markdown list item can show:
    /// a negative start counts from 0, and one longer than nine digits from
    /// the largest nine-digit number, so the number can never turn into
    /// words of a paragraph. A start that is not a whole number is ignored.
    func testStartValuesAreHeldToNumbersAListItemCanShow() throws {
        let numbering = try Self.numbering("""
        <w:abstractNum w:abstractNumId="0">
        <w:lvl w:ilvl="0"><w:start w:val="-3"/></w:lvl>
        <w:lvl w:ilvl="1"><w:start w:val="12345678901"/></w:lvl>
        <w:lvl w:ilvl="2"><w:start w:val="two"/></w:lvl>
        </w:abstractNum>
        <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
        """)

        XCTAssertEqual((0...2).map { numbering.levelFormat(numId: "1", level: $0)?.start }, [0, 999_999_999, 1])
    }

    /// A list instance's overrides change its own paragraphs only. A start
    /// override moves where a level starts; a replacement level changes its
    /// format and start; a start override wins over the start of the level
    /// it accompanies; and an override may define a level the abstract
    /// definition lacks. Another instance of the definition keeps the
    /// definition's levels.
    func testInstanceOverridesChangeOnlyTheirOwnLevels() throws {
        let numbering = try Self.numbering("""
        <w:abstractNum w:abstractNumId="0">
        <w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/></w:lvl>
        <w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="lowerLetter"/></w:lvl>
        </w:abstractNum>
        <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
        <w:num w:numId="2"><w:abstractNumId w:val="0"/>
        <w:lvlOverride w:ilvl="0"><w:startOverride w:val="5"/></w:lvlOverride>
        <w:lvlOverride w:ilvl="1"><w:lvl w:ilvl="1"><w:start w:val="3"/><w:numFmt w:val="bullet"/></w:lvl></w:lvlOverride>
        </w:num>
        <w:num w:numId="3"><w:abstractNumId w:val="0"/>
        <w:lvlOverride w:ilvl="0"><w:startOverride w:val="7"/>
        <w:lvl w:ilvl="0"><w:start w:val="4"/><w:numFmt w:val="upperRoman"/></w:lvl></w:lvlOverride>
        <w:lvlOverride w:ilvl="4"><w:lvl w:ilvl="4"><w:numFmt w:val="decimal"/></w:lvl></w:lvlOverride>
        </w:num>
        """)

        XCTAssertEqual(numbering.levelFormat(numId: "1", level: 0)?.start, 1)
        XCTAssertEqual(numbering.levelFormat(numId: "1", level: 1)?.numFmt, "lowerLetter")

        XCTAssertEqual(numbering.levelFormat(numId: "2", level: 0)?.start, 5)
        XCTAssertEqual(numbering.levelFormat(numId: "2", level: 0)?.numFmt, "decimal")
        XCTAssertEqual(numbering.listType(numId: "2", level: 1), .bullet)
        XCTAssertEqual(numbering.levelFormat(numId: "2", level: 1)?.start, 3)

        XCTAssertEqual(numbering.levelFormat(numId: "3", level: 0)?.start, 7)
        XCTAssertEqual(numbering.levelFormat(numId: "3", level: 0)?.numFmt, "upperRoman")
        XCTAssertEqual(numbering.levelFormat(numId: "3", level: 1)?.numFmt, "lowerLetter")
        XCTAssertEqual(numbering.listType(numId: "3", level: 4), .numbered)
        XCTAssertNil(numbering.levelFormat(numId: "1", level: 4))
    }

    /// An override of a level a list cannot have names no level, so it is
    /// ignored, as is a start override outside any level override.
    func testOverridesOfLevelsAListCannotHaveAreIgnored() throws {
        let numbering = try Self.numbering("""
        <w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:start w:val="2"/></w:lvl></w:abstractNum>
        <w:num w:numId="1"><w:abstractNumId w:val="0"/>
        <w:startOverride w:val="8"/>
        <w:lvlOverride w:ilvl="12"><w:startOverride w:val="9"/></w:lvlOverride>
        <w:lvlOverride><w:startOverride w:val="9"/></w:lvlOverride>
        </w:num>
        """)

        XCTAssertNil(numbering.levelOverrides["1"])
        XCTAssertEqual(numbering.levelFormat(numId: "1", level: 0)?.start, 2)
    }

    /// ISO/IEC 29500-1 §17.9.10: by default a level restarts after any
    /// shallower item; a restart value naming a shallower level restarts it
    /// only after items at that level or shallower; 0 never restarts it;
    /// and a value naming the level itself or a deeper one is ignored. An
    /// item never restarts its own level or a shallower one.
    func testLevelRestartRules() {
        let byDefault = ListLevelFormat(numFmt: "decimal")
        XCTAssertTrue(byDefault.restarts(level: 2, afterItemAt: 0))
        XCTAssertTrue(byDefault.restarts(level: 2, afterItemAt: 1))
        XCTAssertFalse(byDefault.restarts(level: 2, afterItemAt: 2))
        XCTAssertFalse(byDefault.restarts(level: 1, afterItemAt: 2))

        let never = ListLevelFormat(numFmt: "decimal", restartAfter: 0)
        XCTAssertFalse(never.restarts(level: 2, afterItemAt: 0))

        // One-based level 1 is index 0, so only items at index 0 restart it.
        let afterTheFirstLevel = ListLevelFormat(numFmt: "decimal", restartAfter: 1)
        XCTAssertTrue(afterTheFirstLevel.restarts(level: 2, afterItemAt: 0))
        XCTAssertFalse(afterTheFirstLevel.restarts(level: 2, afterItemAt: 1))

        let namingItself = ListLevelFormat(numFmt: "decimal", restartAfter: 3)
        XCTAssertTrue(namingItself.restarts(level: 2, afterItemAt: 1))
    }

    // MARK: - Helpers

    /// The WordprocessingML namespace each part declares.
    private static let wordNamespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

    /// A paragraph reading `text` as an item of list instance `numId` at `level`.
    private static func listItem(_ text: String, numId: String, level: Int) -> String {
        "<w:p><w:pPr><w:numPr><w:ilvl w:val=\"\(level)\"/><w:numId w:val=\"\(numId)\"/></w:numPr></w:pPr>"
            + "<w:r><w:t>\(text)</w:t></w:r></w:p>"
    }

    /// The text part of a document whose body holds `body`.
    private static func documentPart(_ body: [String]) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="\(wordNamespace)"><w:body>
        \(body.joined(separator: "\n"))
        </w:body></w:document>
        """
    }

    /// A numbering part holding `definitions`: abstract definitions and list instances.
    private static func numberingPart(_ definitions: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:numbering xmlns:w="\(wordNamespace)">
        \(definitions)
        </w:numbering>
        """
    }

    /// The list definitions `definitions` makes, read by the production parser.
    private static func numbering(_ definitions: String) throws -> DOCXNumbering {
        try DOCXNumberingParser(data: Data(numberingPart(definitions).utf8), file: DOCXParser.Part.numbering).parse()
    }

    /// Read a package whose text part holds the paragraphs and tables in
    /// `body`, with a numbering part holding `numbering` when it is given,
    /// exactly as an import reads it. Returns the Markdown and the words a
    /// reader hears for it; any damage report fails the test.
    private func read(
        body: [String],
        numbering: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (markdown: String, spoken: String) {
        var parts = [DOCXParser.Part.document: Self.documentPart(body)]
        parts[DOCXParser.Part.numbering] = numbering.map(Self.numberingPart)
        let docx = try makeTemporaryZip(prefix: "TextMouthDOCXStructure", entries: parts.mapValues { Data($0.utf8) })
        addTeardownBlock { try? FileManager.default.removeItem(at: docx) }

        let markdown = try DOCXParser.extractMarkdown(from: docx) { damage in
            XCTFail("Unexpected damage report: \(damage)", file: file, line: line)
        }
        let spoken = try MarkdownDocParser.parse(markdown: markdown).chapters[0].text
        return (markdown, spoken)
    }
}
