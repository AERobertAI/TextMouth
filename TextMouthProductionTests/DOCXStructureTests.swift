import XCTest
@testable import TextMouth

/// A Word document keeps its structure in the reading TextMouth makes of it
/// (TODO T05): list levels are matched by their identity, with their start
/// values, restart rules, and per-instance overrides; list items nest so
/// that each is heard once, apart from the text around it, with no bullet
/// or number read as a word; styles inherit heading levels through their
/// `w:basedOn` chains; a paragraph's own outline level makes it a heading or
/// body text; only current formatting counts, never the formatting a
/// tracked change replaced; a table nested in a cell keeps its rows apart
/// from the row holding it; and every character of the text is read as
/// written. Each test builds a minimal DOCX package in memory and reads it
/// through `DOCXParser`, the path every import takes, or parses one part
/// with its production parser.
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

    /// A level that names no number format is decimal (ISO/IEC 29500-1,
    /// `w:numFmt`), so its paragraphs are numbered rather than bulleted.
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

    /// ISO/IEC 29500-1 (`w:lvlRestart`): by default a level restarts after any
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

    // MARK: - List Structure

    /// A list that skips a level nests its deeper items one step inside the
    /// item above them. Indented by their level instead, they would run on
    /// as lines of that item's paragraph, their bullets read as words.
    func testItemsBelowASkippedLevelNestOneStep() throws {
        let reading = try read(body: [
            Self.listItem("Measure the board", numId: "1", level: 0),
            Self.listItem("Mark both edges", numId: "1", level: 2),
            Self.listItem("Square the ends", numId: "1", level: 2),
            Self.listItem("Cut along the marks", numId: "1", level: 0)
        ], numbering: """
        <w:abstractNum w:abstractNumId="0">
        <w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/></w:lvl>
        <w:lvl w:ilvl="2"><w:numFmt w:val="bullet"/></w:lvl>
        </w:abstractNum>
        <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
        """)

        XCTAssertEqual(reading.markdown, """
        1. Measure the board
            - Mark both edges
            - Square the ends
        2. Cut along the marks
        """)
        XCTAssertEqual(reading.spoken, """
        Measure the board

        Mark both edges

        Square the ends

        Cut along the marks
        """)
    }

    /// A list whose first item is below level 0 starts where the paragraph
    /// before it ends, rather than indented as though inside an item, which
    /// would make its items lines of that paragraph.
    func testListStartingBelowTheFirstLevelIsStillAList() throws {
        let reading = try read(body: [
            Self.paragraph("Before planing:"),
            Self.listItem("Sharpen the iron", numId: "1", level: 1),
            Self.listItem("Set the depth", numId: "1", level: 1),
            Self.paragraph("Then plane with the grain.")
        ], numbering: """
        <w:abstractNum w:abstractNumId="0">
        <w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/></w:lvl>
        <w:lvl w:ilvl="1"><w:numFmt w:val="bullet"/></w:lvl>
        </w:abstractNum>
        <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
        """)

        XCTAssertEqual(reading.markdown, """
        Before planing\\:
        - Sharpen the iron
        - Set the depth

        Then plane with the grain\\.
        """)
        XCTAssertEqual(reading.spoken, """
        Before planing:

        Sharpen the iron

        Set the depth

        Then plane with the grain.
        """)
    }

    /// A nested list whose count carries on under a new parent item starts
    /// its new Markdown list at a number other than 1, which may not
    /// interrupt the parent's paragraph, so a blank line comes first.
    /// Without it, "2." and the item's words would be read as part of the
    /// parent item.
    func testNestedListContinuingAboveOneIsNotReadIntoItsParent() throws {
        let reading = try read(body: [
            Self.listItem("Prime the wall", numId: "1", level: 0),
            Self.listItem("Fill the cracks", numId: "1", level: 1),
            Self.listItem("Paint the wall", numId: "1", level: 0),
            Self.listItem("Cut in the edges", numId: "1", level: 1)
        ], numbering: """
        <w:abstractNum w:abstractNumId="0">
        <w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/></w:lvl>
        <w:lvl w:ilvl="1"><w:numFmt w:val="decimal"/><w:lvlRestart w:val="0"/></w:lvl>
        </w:abstractNum>
        <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
        """)

        XCTAssertEqual(reading.markdown, """
        1. Prime the wall
            1. Fill the cracks
        2. Paint the wall

            2. Cut in the edges
        """)
        XCTAssertEqual(reading.spoken, """
        Prime the wall

        Fill the cracks

        Paint the wall

        Cut in the edges
        """)
    }

    /// A numbered list taken up again after a bulleted item starts a new
    /// Markdown list at its next number, after a blank line, so the number
    /// is not read into the bullet's words.
    func testNumberedItemAfterABulletIsNotReadIntoTheBullet() throws {
        let reading = try read(body: [
            Self.listItem("Wet the stone", numId: "1", level: 0),
            Self.listItem("Hone the bevel", numId: "1", level: 0),
            Self.listItem("Keep the stone flat", numId: "2", level: 0),
            Self.listItem("Strop the edge", numId: "1", level: 0)
        ], numbering: """
        <w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/></w:lvl></w:abstractNum>
        <w:abstractNum w:abstractNumId="1"><w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/></w:lvl></w:abstractNum>
        <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
        <w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>
        """)

        XCTAssertEqual(reading.markdown, """
        1. Wet the stone
        2. Hone the bevel
        - Keep the stone flat

        3. Strop the edge
        """)
        XCTAssertEqual(reading.spoken, """
        Wet the stone

        Hone the bevel

        Keep the stone flat

        Strop the edge
        """)
    }

    // MARK: - List Numbers

    /// A list counts from its level's start value. Starting above 1 right
    /// after a paragraph, it follows a blank line, so its number never joins
    /// the paragraph's words; no number is read aloud.
    func testListsCountFromTheirStartValues() throws {
        let reading = try read(body: [
            Self.paragraph("Pick up where the last session ended:"),
            Self.listItem("Glue the spine", numId: "1", level: 0),
            Self.listItem("Clamp it overnight", numId: "1", level: 0)
        ], numbering: """
        <w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:start w:val="3"/><w:numFmt w:val="decimal"/></w:lvl></w:abstractNum>
        <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
        """)

        XCTAssertEqual(reading.markdown, """
        Pick up where the last session ended\\:

        3. Glue the spine
        4. Clamp it overnight
        """)
        XCTAssertEqual(reading.spoken, """
        Pick up where the last session ended:

        Glue the spine

        Clamp it overnight
        """)
    }

    /// A list instance with a start override (how Word stores "Set
    /// Numbering Value") numbers its first item from the override, though
    /// another instance of the same definition has counted before it.
    func testStartOverrideNumbersItsInstanceFromTheOverride() throws {
        let reading = try read(body: [
            Self.listItem("Strip the old finish", numId: "1", level: 0),
            Self.listItem("Sand the surface", numId: "1", level: 0),
            Self.listItem("Wipe away the dust", numId: "2", level: 0),
            Self.listItem("Apply the first coat", numId: "2", level: 0)
        ], numbering: """
        <w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/></w:lvl></w:abstractNum>
        <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
        <w:num w:numId="2"><w:abstractNumId w:val="0"/>
        <w:lvlOverride w:ilvl="0"><w:startOverride w:val="5"/></w:lvlOverride></w:num>
        """)

        XCTAssertEqual(reading.markdown, """
        1. Strip the old finish
        2. Sand the surface
        5. Wipe away the dust
        6. Apply the first coat
        """)
    }

    /// Word numbers every instance of one abstract definition as one list:
    /// a plain instance continues the count, an instance with a start
    /// override restarts it once, at its first paragraph, and every
    /// paragraph after that, in either instance, counts on.
    func testInstancesOfOneDefinitionShareOneCount() throws {
        let reading = try read(body: [
            Self.listItem("Thread the needle", numId: "1", level: 0),
            Self.listItem("Knot the end", numId: "1", level: 0),
            Self.listItem("Pierce the fold", numId: "3", level: 0),
            Self.listItem("Pass through the kettle stitch", numId: "2", level: 0),
            Self.listItem("Tie off the thread", numId: "1", level: 0),
            Self.listItem("Trim the tail", numId: "2", level: 0)
        ], numbering: """
        <w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/></w:lvl></w:abstractNum>
        <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
        <w:num w:numId="2"><w:abstractNumId w:val="0"/>
        <w:lvlOverride w:ilvl="0"><w:startOverride w:val="8"/></w:lvlOverride></w:num>
        <w:num w:numId="3"><w:abstractNumId w:val="0"/></w:num>
        """)

        XCTAssertEqual(reading.markdown, """
        1. Thread the needle
        2. Knot the end
        3. Pierce the fold
        8. Pass through the kettle stitch
        9. Tie off the thread
        10. Trim the tail
        """)
    }

    /// An item restarts the levels below it, whether it is numbered or
    /// bulleted: each new parent's sublist counts from 1 again. Counting on
    /// instead would also have read the "3." and its words into the parent.
    func testShallowerItemsRestartDeeperLevels() throws {
        let numbering = """
        <w:abstractNum w:abstractNumId="0">
        <w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/></w:lvl>
        <w:lvl w:ilvl="1"><w:numFmt w:val="lowerLetter"/></w:lvl>
        </w:abstractNum>
        <w:abstractNum w:abstractNumId="1">
        <w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/></w:lvl>
        <w:lvl w:ilvl="1"><w:numFmt w:val="decimal"/></w:lvl>
        </w:abstractNum>
        <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
        <w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>
        """

        let numberedParents = try read(body: [
            Self.listItem("Morning", numId: "1", level: 0),
            Self.listItem("Feed the starter", numId: "1", level: 1),
            Self.listItem("Mix the dough", numId: "1", level: 1),
            Self.listItem("Evening", numId: "1", level: 0),
            Self.listItem("Shape the loaves", numId: "1", level: 1)
        ], numbering: numbering)
        let bulletedParents = try read(body: [
            Self.listItem("Tools", numId: "2", level: 0),
            Self.listItem("Saw", numId: "2", level: 1),
            Self.listItem("Plane", numId: "2", level: 1),
            Self.listItem("Materials", numId: "2", level: 0),
            Self.listItem("Oak", numId: "2", level: 1)
        ], numbering: numbering)

        XCTAssertEqual(numberedParents.markdown, """
        1. Morning
            1. Feed the starter
            2. Mix the dough
        2. Evening
            1. Shape the loaves
        """)
        XCTAssertEqual(bulletedParents.markdown, """
        - Tools
            1. Saw
            2. Plane
        - Materials
            1. Oak
        """)
        XCTAssertEqual(bulletedParents.spoken, "Tools\n\nSaw\n\nPlane\n\nMaterials\n\nOak")
    }

    /// The example ISO/IEC 29500-1 gives for `w:lvlRestart`: the third level never
    /// restarts (`w:lvlRestart` 0), so it counts on under a new parent
    /// while the second level starts again, reading 1, A, i, ii, 2, A, iii,
    /// iv as numbers.
    func testLevelThatNeverRestartsCountsOnUnderNewParents() throws {
        let reading = try read(body: [
            Self.listItem("Survey the site", numId: "1", level: 0),
            Self.listItem("Walk the boundary", numId: "1", level: 1),
            Self.listItem("Note the slope", numId: "1", level: 2),
            Self.listItem("Note the drainage", numId: "1", level: 2),
            Self.listItem("Draw the plan", numId: "1", level: 0),
            Self.listItem("Mark the footings", numId: "1", level: 1),
            Self.listItem("Note the trees", numId: "1", level: 2),
            Self.listItem("Note the access", numId: "1", level: 2)
        ], numbering: """
        <w:abstractNum w:abstractNumId="0">
        <w:lvl w:ilvl="0"><w:start w:val="1"/><w:lvlText w:val="%1)"/></w:lvl>
        <w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="upperLetter"/><w:lvlText w:val="%2)"/></w:lvl>
        <w:lvl w:ilvl="2"><w:start w:val="1"/><w:numFmt w:val="lowerRoman"/><w:lvlRestart w:val="0"/></w:lvl>
        </w:abstractNum>
        <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
        """)

        XCTAssertEqual(reading.markdown, """
        1. Survey the site
            1. Walk the boundary
                1. Note the slope
                2. Note the drainage
        2. Draw the plan
            1. Mark the footings

                3. Note the trees
                4. Note the access
        """)
        XCTAssertEqual(reading.spoken, """
        Survey the site

        Walk the boundary

        Note the slope

        Note the drainage

        Draw the plan

        Mark the footings

        Note the trees

        Note the access
        """)
    }

    /// TextMouth's tested policy for a list interrupted by other text holds
    /// (DOCXEdgeCaseTests pins it at 1): the list starts again afterwards,
    /// now from its level's start value. Word would continue it at 6.
    func testListInterruptedByAParagraphStartsAgainFromItsStart() throws {
        let reading = try read(body: [
            Self.listItem("Soak the reed", numId: "1", level: 0),
            Self.listItem("Shape the tip", numId: "1", level: 0),
            Self.paragraph("Let it rest for an hour."),
            Self.listItem("Test the tone", numId: "1", level: 0)
        ], numbering: """
        <w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:start w:val="4"/><w:numFmt w:val="decimal"/></w:lvl></w:abstractNum>
        <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
        """)

        XCTAssertEqual(reading.markdown, """
        4. Soak the reed
        5. Shape the tip

        Let it rest for an hour\\.

        4. Test the tone
        """)
        XCTAssertEqual(reading.spoken, "Soak the reed\n\nShape the tip\n\nLet it rest for an hour.\n\nTest the tone")
    }

    /// Under an item whose number is three digits wide, a nested item is
    /// indented to the parent's text (five spaces) rather than four, which
    /// would leave it outside the parent, a line of the parent's paragraph.
    func testItemsNestedUnderWideNumbersStayInsideTheirParent() throws {
        let reading = try read(body: [
            Self.listItem("Ninety-ninth entry", numId: "1", level: 0),
            Self.listItem("Hundredth entry", numId: "1", level: 0),
            Self.listItem("A note on the hundredth", numId: "1", level: 1)
        ], numbering: """
        <w:abstractNum w:abstractNumId="0">
        <w:lvl w:ilvl="0"><w:start w:val="99"/><w:numFmt w:val="decimal"/></w:lvl>
        <w:lvl w:ilvl="1"><w:numFmt w:val="bullet"/></w:lvl>
        </w:abstractNum>
        <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
        """)

        XCTAssertEqual(reading.markdown, """
        99. Ninety\\-ninth entry
        100. Hundredth entry
             - A note on the hundredth
        """)
        XCTAssertEqual(reading.spoken, "Ninety-ninth entry\n\nHundredth entry\n\nA note on the hundredth")
    }

    /// Counting stops at the largest number a list item can show, so the
    /// items stay items however long the list runs.
    func testNumbersStopAtTheLargestAListItemCanShow() throws {
        let reading = try read(body: [
            Self.listItem("Penultimate", numId: "1", level: 0),
            Self.listItem("Last", numId: "1", level: 0),
            Self.listItem("Beyond", numId: "1", level: 0)
        ], numbering: """
        <w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:start w:val="999999998"/></w:lvl></w:abstractNum>
        <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
        """)

        XCTAssertEqual(reading.markdown, "999999998. Penultimate\n999999999. Last\n999999999. Beyond")
        XCTAssertEqual(reading.spoken, "Penultimate\n\nLast\n\nBeyond")
    }

    // MARK: - Style Inheritance

    /// Word's built-in heading styles as Word writes them: each names its
    /// heading level and outline level, based on Normal.
    private static let headingStyles = """
    <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
    <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/>
    <w:pPr><w:outlineLvl w:val="0"/></w:pPr></w:style>
    <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/>
    <w:pPr><w:outlineLvl w:val="1"/></w:pPr></w:style>
    <w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/>
    <w:pPr><w:outlineLvl w:val="2"/></w:pPr></w:style>
    """

    /// A custom style based on Heading 2, which says nothing about headings
    /// itself, inherits Heading 2's level: its paragraphs are level-2
    /// headings in the Markdown and in the heading list.
    func testStyleBasedOnAHeadingIsAHeadingOfThatLevel() throws {
        let reading = try read(body: [
            Self.paragraph("Tyre Repair", style: "Heading1"),
            Self.paragraph("Find the puncture", style: "RepairStep"),
            Self.paragraph("Pump the tube and listen for the hiss."),
            Self.paragraph("Patch the tube", style: "RepairStep")
        ], styles: Self.headingStyles + """
        <w:style w:type="paragraph" w:customStyle="1" w:styleId="RepairStep">
        <w:name w:val="Repair Step"/><w:basedOn w:val="Heading2"/></w:style>
        """)

        XCTAssertEqual(reading.headings, ["1 Tyre Repair", "2 Find the puncture", "2 Patch the tube"])
        XCTAssertTrue(reading.markdown.contains("\n## Find the puncture\n"), reading.markdown)
        XCTAssertEqual(reading.spoken, """
        Tyre Repair

        Find the puncture

        Pump the tube and listen for the hiss.

        Patch the tube
        """)
    }

    /// A chain of styles inherits from the nearest style that says whether
    /// it is a heading, however the part orders the definitions; here every
    /// style is defined before the style it is based on.
    func testHeadingLevelsFollowChainsInAnyOrder() throws {
        let styles = try Self.styles("""
        <w:style w:type="paragraph" w:styleId="StepDetail"><w:name w:val="Step Detail"/><w:basedOn w:val="Step"/></w:style>
        <w:style w:type="paragraph" w:styleId="Step"><w:name w:val="Step"/><w:basedOn w:val="Phase"/></w:style>
        <w:style w:type="paragraph" w:styleId="Phase"><w:name w:val="Phase"/><w:basedOn w:val="Heading3"/></w:style>
        """ + Self.headingStyles)

        XCTAssertEqual(styles.headingLevels["Phase"], 3)
        XCTAssertEqual(styles.headingLevels["Step"], 3)
        XCTAssertEqual(styles.headingLevels["StepDetail"], 3)
        XCTAssertNil(styles.headingLevels["Normal"])
    }

    /// What a style declares itself wins over what it would inherit: its own
    /// outline level, including 9 (body text), and its own heading name.
    func testOwnDeclarationWinsOverInheritance() throws {
        let styles = try Self.styles(Self.headingStyles + """
        <w:style w:type="paragraph" w:styleId="Aside"><w:name w:val="Aside"/><w:basedOn w:val="Heading1"/>
        <w:pPr><w:outlineLvl w:val="9"/></w:pPr></w:style>
        <w:style w:type="paragraph" w:styleId="PartTitle"><w:name w:val="Part Title"/><w:basedOn w:val="Heading1"/>
        <w:pPr><w:outlineLvl w:val="1"/></w:pPr></w:style>
        <w:style w:type="paragraph" w:styleId="Heading4"><w:name w:val="heading 4"/><w:basedOn w:val="Heading1"/></w:style>
        """)

        XCTAssertNil(styles.headingLevels["Aside"])
        XCTAssertEqual(styles.headingLevels["PartTitle"], 2)
        XCTAssertEqual(styles.headingLevels["Heading4"], 4)
    }

    /// A chain that loops back on itself, or reaches a style the part does
    /// not define, gives no heading level and never hangs. A heading style
    /// on the loop still gives its level to the styles based on it.
    func testBasedOnLoopsAndMissingStylesEndInheritance() throws {
        let styles = try Self.styles("""
        <w:style w:type="paragraph" w:styleId="Left"><w:name w:val="Left"/><w:basedOn w:val="Right"/></w:style>
        <w:style w:type="paragraph" w:styleId="Right"><w:name w:val="Right"/><w:basedOn w:val="Left"/></w:style>
        <w:style w:type="paragraph" w:styleId="Mirror"><w:name w:val="Mirror"/><w:basedOn w:val="Mirror"/></w:style>
        <w:style w:type="paragraph" w:styleId="Orphan"><w:name w:val="Orphan"/><w:basedOn w:val="Missing"/></w:style>
        <w:style w:type="paragraph" w:styleId="Lean"><w:name w:val="Lean"/><w:basedOn w:val="Left"/></w:style>
        <w:style w:type="paragraph" w:styleId="Upper"><w:name w:val="Upper"/><w:basedOn w:val="Heading2"/></w:style>
        <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Upper"/></w:style>
        """)

        for styleId in ["Left", "Right", "Mirror", "Orphan", "Lean"] {
            XCTAssertNil(styles.headingLevels[styleId], styleId)
        }
        XCTAssertEqual(styles.headingLevels["Heading2"], 2)
        XCTAssertEqual(styles.headingLevels["Upper"], 2)
    }

    /// A chain thousands of styles long resolves completely, every style on
    /// it a heading of its root's level, without recursing once per style.
    func testLongBasedOnChainResolves() throws {
        let count = 5_000
        let chain = (1...count).map { index in
            "<w:style w:type=\"paragraph\" w:styleId=\"S\(index)\"><w:name w:val=\"S\(index)\"/>"
                + "<w:basedOn w:val=\"S\(index - 1)\"/></w:style>"
        }.joined(separator: "\n")
        let styles = try Self.styles("""
        <w:style w:type="paragraph" w:styleId="S0"><w:name w:val="S0"/><w:basedOn w:val="Heading3"/></w:style>
        \(chain)
        """ + Self.headingStyles)

        XCTAssertEqual(styles.headingLevels["S\(count)"], 3)
        XCTAssertEqual(styles.headingLevels.count, count + 4)
    }

    /// A style without an ID can be named by no paragraph. Its heading or
    /// list role must not pass to the paragraphs that name no style.
    func testStyleWithoutAnIDGivesNoRole() throws {
        let reading = try read(body: [
            Self.paragraph("An ordinary paragraph."),
            Self.paragraph("Another one.")
        ], styles: """
        <w:style w:type="paragraph"><w:name w:val="heading 1"/></w:style>
        <w:style w:type="paragraph" w:styleId=""><w:name w:val="List Bullet"/></w:style>
        """)

        XCTAssertEqual(reading.markdown, "An ordinary paragraph\\.\n\nAnother one\\.")
        XCTAssertEqual(reading.headings, [])
    }

    // MARK: - Paragraph Outline Levels

    /// A paragraph's own outline level makes it a heading without a heading
    /// style: outline level 1 is a level-2 heading, and the deepest outline
    /// levels share heading level 6. The paragraph after it, with no outline
    /// level of its own, stays body text.
    func testParagraphOutlineLevelMakesItAHeading() throws {
        let reading = try read(body: [
            Self.outlinedParagraph("Spoke Tension", outline: "1"),
            Self.paragraph("Pluck each spoke and listen for a dull note."),
            Self.outlinedParagraph("Truing Notes", outline: "8")
        ], styles: Self.headingStyles)

        XCTAssertEqual(reading.headings, ["2 Spoke Tension", "6 Truing Notes"])
        XCTAssertTrue(reading.markdown.hasPrefix("## Spoke Tension\n"), reading.markdown)
    }

    /// A paragraph's own outline level wins over its style's, as direct
    /// formatting does: a Heading 1 paragraph marked level 2 is a level-3
    /// heading, and one marked body text (9) is no heading. A value that is
    /// not a number declares nothing, so the style's level stands.
    func testParagraphOutlineLevelWinsOverItsStyle() throws {
        let reading = try read(body: [
            Self.outlinedParagraph("Rim Width", style: "Heading1", outline: "2"),
            Self.outlinedParagraph("Measured inside the hooks.", style: "Heading1", outline: "9"),
            Self.outlinedParagraph("Valve Types", style: "Heading1", outline: "deep")
        ], styles: Self.headingStyles)

        XCTAssertEqual(reading.headings, ["3 Rim Width", "1 Valve Types"])
        XCTAssertTrue(reading.markdown.contains("\nMeasured inside the hooks\\.\n"), reading.markdown)
    }

    // MARK: - Tracked Formatting Changes

    /// A tracked formatting change records how a paragraph or run was
    /// formatted before the change; only the current formatting counts. The
    /// heading that was body text stays a heading, the paragraph that was a
    /// heading stays body text, the list item keeps its own list and level,
    /// and the run made bold is bold, not also italic as it once was.
    func testTrackedFormattingChangesDoNotOverrideCurrentFormatting() throws {
        let change = "w:id=\"1\" w:author=\"Reviewer\" w:date=\"2026-01-05T09:00:00Z\""
        let reading = try read(body: [
            "<w:p><w:pPr><w:pStyle w:val=\"Heading1\"/><w:pPrChange \(change)><w:pPr><w:pStyle w:val=\"Normal\"/>"
                + "</w:pPr></w:pPrChange></w:pPr><w:r><w:t>Brake Pads</w:t></w:r></w:p>",
            "<w:p><w:pPr><w:pPrChange \(change)><w:pPr><w:outlineLvl w:val=\"0\"/></w:pPr></w:pPrChange></w:pPr>"
                + "<w:r><w:t>Check the wear line first.</w:t></w:r></w:p>",
            "<w:p><w:pPr><w:numPr><w:ilvl w:val=\"0\"/><w:numId w:val=\"1\"/></w:numPr><w:pPrChange \(change)><w:pPr>"
                + "<w:numPr><w:ilvl w:val=\"1\"/><w:numId w:val=\"2\"/></w:numPr></w:pPr></w:pPrChange></w:pPr>"
                + "<w:r><w:t>Loosen the caliper</w:t></w:r></w:p>",
            "<w:p><w:r><w:rPr><w:b/><w:rPrChange \(change)><w:rPr><w:i/></w:rPr></w:rPrChange></w:rPr><w:t>Never</w:t></w:r>"
                + "<w:r><w:t xml:space=\"preserve\"> skip the test ride.</w:t></w:r></w:p>"
        ], styles: Self.headingStyles, numbering: """
        <w:abstractNum w:abstractNumId="0">
        <w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/></w:lvl><w:lvl w:ilvl="1"><w:numFmt w:val="decimal"/></w:lvl>
        </w:abstractNum>
        <w:abstractNum w:abstractNumId="1">
        <w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/></w:lvl><w:lvl w:ilvl="1"><w:numFmt w:val="bullet"/></w:lvl>
        </w:abstractNum>
        <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
        <w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>
        """)

        XCTAssertEqual(reading.markdown, """
        # Brake Pads


        Check the wear line first\\.
        1. Loosen the caliper

        **Never** skip the test ride\\.
        """)
        XCTAssertEqual(reading.headings, ["1 Brake Pads"])
    }

    // MARK: - Nested Tables

    /// A table nested in a cell keeps its rows apart from the row holding
    /// it. Every row is one paragraph of its cells' words, as an HTML table
    /// reads (TODO T03), and the nested rows come between the words of the
    /// cell before and after them, so everything reads once, in source
    /// order, with no two cells' words run together.
    func testNestedTableRowsStayApartFromTheRowHoldingThem() throws {
        let reading = try read(body: [
            Self.table(
                Self.row(Self.textCell("Tool"), Self.textCell("Use")),
                Self.row(
                    Self.textCell("Bone folder"),
                    Self.cell(
                        Self.paragraph("Creasing"),
                        Self.table(
                            Self.row(Self.textCell("Size"), Self.textCell("Small")),
                            Self.row(Self.textCell("Edge"), Self.textCell("Rounded"))
                        ),
                        Self.paragraph("Keep it dry")
                    )
                ),
                Self.row(Self.textCell("Awl"), Self.textCell("Piercing"))
            )
        ])

        XCTAssertEqual(reading.markdown, """
        Tool Use

        Bone folder Creasing

        Size Small

        Edge Rounded

        Keep it dry

        Awl Piercing
        """)
        XCTAssertEqual(reading.spoken, reading.markdown)
    }

    /// Tables nest to any depth, and every table's rows stay paragraphs of
    /// their own, in source order, between the text around the table.
    func testTablesNestedTwoDeepKeepEveryRowApart() throws {
        let reading = try read(body: [
            Self.paragraph("Kit list:"),
            Self.table(Self.row(
                Self.textCell("Bench"),
                Self.cell(Self.table(
                    Self.row(Self.textCell("Vise"), Self.cell(Self.table(
                        Self.row(Self.textCell("Jaw"), Self.textCell("Wooden")),
                        Self.row(Self.textCell("Screw"), Self.textCell("Steel"))
                    ))),
                    Self.row(Self.textCell("Stop"), Self.textCell("Brass"))
                ))
            )),
            Self.paragraph("Check each before work.")
        ])

        XCTAssertEqual(reading.spoken, """
        Kit list:

        Bench

        Vise

        Jaw Wooden

        Screw Steel

        Stop Brass

        Check each before work.
        """)
    }

    /// A table of text cells is still a Markdown table, before and after a
    /// table that nests one, and a nested table in a row's first cell reads
    /// before the cells after it.
    func testSimpleTablesStayMarkdownTablesBesideNestedOnes() throws {
        let simple = Self.table(
            Self.row(Self.textCell("Glue"), Self.textCell("Open time")),
            Self.row(Self.textCell("Hide"), Self.textCell("Short"))
        )
        let reading = try read(body: [
            simple,
            Self.table(Self.row(
                Self.cell(Self.table(Self.row(Self.textCell("Bar"), Self.textCell("Long")))),
                Self.textCell("Clamp")
            )),
            simple
        ])

        XCTAssertEqual(reading.markdown, """
        | Glue | Open time |
        | --- | --- |
        | Hide | Short |


        Bar Long

        Clamp


        | Glue | Open time |
        | --- | --- |
        | Hide | Short |
        """)
    }

    /// A document cut off inside a nested table keeps everything read before
    /// the cut: the nested table, its row, and the table holding it close
    /// as their end tags would have closed them, and the damage is reported
    /// beside the text.
    func testCutInsideANestedTableKeepsTheRowsReadBeforeIt() throws {
        let document = Self.documentPart([
            Self.paragraph("Joint chart:"),
            Self.table(
                Self.row(Self.textCell("Joint"), Self.textCell("Notes")),
                Self.row(Self.textCell("Dovetail"), Self.cell(Self.table(
                    Self.row(Self.textCell("Pins"), Self.textCell("Tails")),
                    Self.row(Self.textCell("Ratio"), Self.textCell("One to six"))
                )))
            )
        ])
        let docx = try makeTemporaryZip(prefix: "TextMouthDOCXStructure", entries: [
            DOCXParser.Part.document: Data(Self.truncated(document, before: "six</w:t>").utf8)
        ])
        addTeardownBlock { try? FileManager.default.removeItem(at: docx) }

        var diagnostics: [DOCXParserError] = []
        let markdown = try DOCXParser.extractMarkdown(from: docx, includesPages: false) { diagnostics.append($0) }

        XCTAssertEqual(markdown, "Joint chart\\:\n\nJoint Notes\n\nDovetail\n\nPins Tails\n\nRatio One to")
        XCTAssertEqual(diagnostics.count, 1, "\(diagnostics)")
    }

    // MARK: - Literal Text

    /// Every character of a document's text is read exactly as written.
    /// Asterisks, underscores, and number signs, like every other ASCII
    /// punctuation mark, never become emphasis, headings, list items,
    /// quotations, links, code, HTML, or a rule, and quotes, dashes, and
    /// ellipses keep the characters typed.
    func testTextIsReadExactlyAsWritten() throws {
        let lines = [
            "# Not a heading",
            "* Not a bullet *",
            "_underscored_ and snake_case_name",
            "2 * 3 * 4 = 24, not *emphasis* or __strong__",
            "#hashtag and issue #12 ##",
            "1. Not a numbered item",
            "- Not a dash item",
            "> Not a quotation",
            "* * *",
            "Fish & chips <b>not bold</b> [not a link](nowhere) `not code` ~~not struck~~ \\ a backslash",
            "\"Quoted\" -- it's ... done"
        ]

        let reading = try read(body: lines.map { Self.paragraph(Self.xmlEscaped($0)) })

        XCTAssertEqual(reading.spoken, lines.joined(separator: "\n\n"))
        XCTAssertEqual(reading.headings, [])
    }

    /// Text stays literal wherever it stands: a heading's label, a table
    /// cell, where a vertical bar stays inside its cell instead of dividing
    /// it, a list item, and a link's label.
    func testTextIsLiteralInHeadingsCellsListsAndLinks() throws {
        let reading = try read(body: [
            Self.paragraph(Self.xmlEscaped("Step #1: *Measure* twice"), style: "Heading1"),
            Self.table(Self.row(Self.textCell("a | b"), Self.textCell("c"))),
            Self.listItem("Use the 1/4 bit_ not the 3/8", numId: "1", level: 0),
            "<w:p><w:hyperlink r:id=\"rId7\"><w:r><w:t>[Spec] *v2*</w:t></w:r></w:hyperlink></w:p>"
        ], styles: Self.headingStyles, numbering: """
        <w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/></w:lvl></w:abstractNum>
        <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
        """, relationships: ["rId7": "https://example.org/spec"])

        XCTAssertEqual(reading.headings, ["1 Step #1: *Measure* twice"])
        XCTAssertTrue(reading.markdown.contains("| a \\| b | c |"), reading.markdown)
        XCTAssertTrue(reading.spoken.contains("a | b"), reading.spoken)
        XCTAssertTrue(reading.spoken.contains("\n\nUse the 1/4 bit_ not the 3/8\n\n"), reading.spoken)
        XCTAssertTrue(reading.markdown.contains("[\\[Spec\\] \\*v2\\*](https://example.org/spec)"), reading.markdown)
        XCTAssertTrue(reading.spoken.hasSuffix("\n\n[Spec] *v2*"), reading.spoken)
    }

    /// A line break inside a paragraph begins a Markdown line, and
    /// indentation after two breaks would make that line a code block, read
    /// verbatim with the backslashes that keep its characters literal. The
    /// indentation is left out instead: it is never heard.
    func testIndentedLineAfterTwoBreaksIsReadAsText() throws {
        let reading = try read(body: [
            "<w:p><w:r><w:t>Formula:</w:t><w:br/><w:br/><w:t xml:space=\"preserve\">    f(x) = x * 2</w:t></w:r></w:p>"
        ])

        XCTAssertEqual(reading.markdown, "Formula\\:\n\nf\\(x\\) \\= x \\* 2")
        XCTAssertEqual(reading.spoken, "Formula:\n\nf(x) = x * 2")
    }

    // MARK: - Helpers

    /// The WordprocessingML namespace each part declares.
    private static let wordNamespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

    /// A paragraph reading `text` as an item of list instance `numId` at `level`.
    private static func listItem(_ text: String, numId: String, level: Int) -> String {
        "<w:p><w:pPr><w:numPr><w:ilvl w:val=\"\(level)\"/><w:numId w:val=\"\(numId)\"/></w:numPr></w:pPr>"
            + "<w:r><w:t>\(text)</w:t></w:r></w:p>"
    }

    /// A paragraph reading `text`, in the paragraph style `style` when one is given.
    private static func paragraph(_ text: String, style: String? = nil) -> String {
        let properties = style.map { "<w:pPr><w:pStyle w:val=\"\($0)\"/></w:pPr>" } ?? ""
        return "<w:p>\(properties)<w:r><w:t>\(text)</w:t></w:r></w:p>"
    }

    /// A table holding `rows`.
    private static func table(_ rows: String...) -> String {
        "<w:tbl>" + rows.joined() + "</w:tbl>"
    }

    /// A table row holding `cells`.
    private static func row(_ cells: String...) -> String {
        "<w:tr>" + cells.joined() + "</w:tr>"
    }

    /// A table cell holding the paragraphs and tables in `contents`.
    private static func cell(_ contents: String...) -> String {
        "<w:tc>" + contents.joined() + "</w:tc>"
    }

    /// A table cell holding one paragraph reading `text`.
    private static func textCell(_ text: String) -> String {
        cell(paragraph(text))
    }

    /// A paragraph reading `text` whose own properties give it the outline
    /// level `outline`, in the paragraph style `style` when one is given.
    private static func outlinedParagraph(_ text: String, style: String? = nil, outline: String) -> String {
        let styleProperty = style.map { "<w:pStyle w:val=\"\($0)\"/>" } ?? ""
        return "<w:p><w:pPr>\(styleProperty)<w:outlineLvl w:val=\"\(outline)\"/></w:pPr>"
            + "<w:r><w:t>\(text)</w:t></w:r></w:p>"
    }

    /// The text part of a document whose body holds `body`.
    private static func documentPart(_ body: [String]) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="\(wordNamespace)"
         xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body>
        \(body.joined(separator: "\n"))
        </w:body></w:document>
        """
    }

    /// The document's relationships part, holding a hyperlink to each
    /// target in `targets` under its relationship ID.
    private static func relationshipsPart(_ targets: [String: String]) -> String {
        let relationships = targets.sorted { $0.key < $1.key }.map { id, target in
            "<Relationship Id=\"\(id)\" Target=\"\(target)\" TargetMode=\"External\""
                + " Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\"/>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        \(relationships.joined(separator: "\n"))
        </Relationships>
        """
    }

    /// `text` with the characters XML gives meaning to written as entity
    /// references, ready to stand as an element's content.
    private static func xmlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
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

    /// A styles part holding the style definitions `definitions`.
    private static func stylesPart(_ definitions: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="\(wordNamespace)">
        \(definitions)
        </w:styles>
        """
    }

    /// The styles `definitions` declares, read by the production parser.
    private static func styles(_ definitions: String) throws -> DOCXStyles {
        try DOCXStylesParser(data: Data(stylesPart(definitions).utf8), file: DOCXParser.Part.styles).parse()
    }

    /// What a reader gets from a document.
    private struct Reading {
        /// The Markdown TextMouth caches for it.
        let markdown: String
        /// The words a reader hears.
        let spoken: String
        /// Its headings as the heading list shows them: "level label".
        let headings: [String]
    }

    /// Read a package whose text part holds the paragraphs and tables in
    /// `body`, with a styles part holding `styles`, a numbering part holding
    /// `numbering`, and a relationships part holding hyperlink
    /// `relationships` when they are given, exactly as an import reads it.
    /// Any damage report fails the test.
    private func read(
        body: [String],
        styles: String? = nil,
        numbering: String? = nil,
        relationships: [String: String] = [:],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Reading {
        var parts = [DOCXParser.Part.document: Self.documentPart(body)]
        parts[DOCXParser.Part.styles] = styles.map(Self.stylesPart)
        parts[DOCXParser.Part.numbering] = numbering.map(Self.numberingPart)
        if !relationships.isEmpty {
            parts[DOCXParser.Part.documentRelationships] = Self.relationshipsPart(relationships)
        }
        let docx = try makeTemporaryZip(prefix: "TextMouthDOCXStructure", entries: parts.mapValues { Data($0.utf8) })
        addTeardownBlock { try? FileManager.default.removeItem(at: docx) }

        let markdown = try DOCXParser.extractMarkdown(from: docx, includesPages: false) { damage in
            XCTFail("Unexpected damage report: \(damage)", file: file, line: line)
        }
        let chapter = try MarkdownDocParser.parse(markdown: markdown).chapters[0]
        return Reading(
            markdown: markdown,
            spoken: chapter.text,
            headings: chapter.headings.map { "\($0.level) \($0.text)" }
        )
    }
}
