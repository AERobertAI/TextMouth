import XCTest
@testable import TextMouth

/// The lists of Word 97-2003 documents (`PlfLst`, `PlfLfo`): how the reader
/// counts the numbered paragraphs, and the two forms it writes them in.
///
/// Word stores no number in the text of a numbered paragraph. By default
/// (`WordDocumentReader.speaksListNumbers` is false) a numbered paragraph is an
/// item of an `ol` nested by its level, a bullet an item of a `ul`, and no
/// number is heard; with the switch on the number is written as words before
/// the paragraph. Every test here passes the switch's value in, so both forms
/// stay tested and the words form can be turned on with one line.
final class WordDocumentListTests: XCTestCase {

    // MARK: - Helpers

    typealias Paragraph = WordDocumentBuilder.Paragraph
    typealias Run = WordDocumentBuilder.Run
    typealias ListLevel = WordDocumentBuilder.ListLevel

    /// A document with one list (identifier 7) of these levels, the rest
    /// of its nine being plain Arabic numbers, and one instance of it.
    private func listBuilder(_ levels: [ListLevel], extraInstances: [WordDocumentBuilder.ListInstance] = []) -> WordDocumentBuilder {
        var builder = WordDocumentBuilder()
        let filler = (levels.count..<9).map { ListLevel(0, "%\($0 + 1).") }
        builder.lists = [WordDocumentBuilder.List(identifier: 7, levels: levels + filler)]
        builder.listInstances = [WordDocumentBuilder.ListInstance(listIdentifier: 7)] + extraInstances
        return builder
    }

    /// The modifiers of a paragraph in list instance `instance` at `level`.
    private func inList(_ instance: Int = 1, level: Int = 0) -> [UInt8] {
        WordDocumentBuilder.listProperties(instance: instance, level: level)
    }

    private let inTable = WordDocumentBuilder.modifier(WordSprm.inTable, 1)
    private var rowEnd: [UInt8] { inTable + WordDocumentBuilder.modifier(WordSprm.rowEnd, 1) }

    private func span(_ page: Int) -> String {
        "<span role=\"doc-pagebreak\" aria-label=\"\(page)\"></span>"
    }

    /// Asserts what `builder`'s document is written as in each form.
    private func assertBody(
        _ builder: WordDocumentBuilder, pages: Bool = false, words: String, silent: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let data = builder.build()
        XCTAssertEqual(try wordBody(of: data, pages: pages, speaksNumbers: true), words, "numbers as words", file: file, line: line)
        XCTAssertEqual(try wordBody(of: data, pages: pages, speaksNumbers: false), silent, "numbers silent", file: file, line: line)
    }

    /// An `ol` of the items `items` at one level.
    private func ol(_ items: [String]) -> String {
        "<ol>\n" + items.map { "<li>\($0)</li>\n" }.joined() + "</ol>\n"
    }

    // MARK: - Counting

    func testANumberedListKeepsCountingPastOtherParagraphs() throws {
        var builder = listBuilder([ListLevel(0, "%1.")])
        builder.paragraphs = [
            Paragraph("First", modifiers: inList()),
            Paragraph("Second", modifiers: inList()),
            Paragraph("Between"),
            Paragraph("Third", modifiers: inList()),
        ]
        try assertBody(
            builder,
            words: "<p>1. First</p>\n<p>2. Second</p>\n<p>Between</p>\n<p>3. Third</p>\n",
            silent: ol(["First", "Second"]) + "<p>Between</p>\n" + ol(["Third"])
        )
    }

    func testLevelsRestartTheLessSignificantOnesAndTheirTextNamesTheMoreSignificantNumbers() throws {
        var builder = listBuilder([ListLevel(0, "%1."), ListLevel(0, "%1.%2"), ListLevel(4, "(%3)")])
        builder.paragraphs = [
            Paragraph("A", modifiers: inList(level: 0)),
            Paragraph("B", modifiers: inList(level: 1)),
            Paragraph("C", modifiers: inList(level: 1)),
            Paragraph("D", modifiers: inList(level: 2)),
            Paragraph("E", modifiers: inList(level: 2)),
            Paragraph("F", modifiers: inList(level: 0)),
            Paragraph("G", modifiers: inList(level: 1)),
            Paragraph("H", modifiers: inList(level: 2)),
        ]
        // Silent, the levels nest: B and C in A, D and E in C, G in F, H in G.
        try assertBody(
            builder,
            words: "<p>1. A</p>\n<p>1.1 B</p>\n<p>1.2 C</p>\n<p>(a) D</p>\n<p>(b) E</p>\n<p>2. F</p>\n<p>2.1 G</p>\n<p>(a) H</p>\n",
            silent: "<ol>\n<li>A<ol>\n<li>B</li>\n<li>C<ol>\n<li>D</li>\n<li>E</li>\n</ol>\n</li>\n</ol>\n</li>\n"
                + "<li>F<ol>\n<li>G<ol>\n<li>H</li>\n</ol>\n</li>\n</ol>\n</li>\n</ol>\n"
        )
    }

    func testNumbersAreWrittenInTheLevelsFormats() throws {
        var builder = listBuilder([
            ListLevel(1, "Article %1", start: 3), ListLevel(2, "%2)"), ListLevel(3, "%3."), ListLevel(4, "%4."), ListLevel(0x16, "%5"),
            // Formats the reader does not write in words are written as Arabic numbers.
            ListLevel(5, "%6"),
        ])
        builder.paragraphs = [
            Paragraph("a", modifiers: inList(level: 0)),
            Paragraph("b", modifiers: inList(level: 1)),
            Paragraph("c", modifiers: inList(level: 2)),
            Paragraph("d", modifiers: inList(level: 3)),
            Paragraph("e", modifiers: inList(level: 4)),
            Paragraph("f", modifiers: inList(level: 5)),
            Paragraph("Article", modifiers: inList(level: 0)),
        ]
        let words = try wordBody(of: builder.build(), speaksNumbers: true)
        XCTAssertEqual(
            words,
            "<p>Article III a</p>\n<p>i) b</p>\n<p>A. c</p>\n<p>a. d</p>\n<p>01 e</p>\n<p>1 f</p>\n<p>Article IV Article</p>\n"
        )
        // Silent, the words alone, whatever the formats.
        let silent = try wordBody(of: builder.build(), speaksNumbers: false)
        for number in ["III", "IV", "i)", "01"] { XCTAssertFalse(silent.contains(number), silent) }
        XCTAssertTrue(silent.contains("<li>a<ol>"), silent)
    }

    func testLegalNumberingWritesTheInheritedNumbersInArabicNumerals() throws {
        var builder = listBuilder([ListLevel(1, "%1."), ListLevel(0, "%1.%2", isLegal: true), ListLevel(0, "%1.%2", isLegal: false)])
        builder.paragraphs = [
            Paragraph("a", modifiers: inList(level: 0)),
            Paragraph("b", modifiers: inList(level: 1)),
            Paragraph("c", modifiers: inList(level: 2)),
        ]
        XCTAssertEqual(try wordBody(of: builder.build(), speaksNumbers: true), "<p>I. a</p>\n<p>1.1 b</p>\n<p>I.1 c</p>\n")
    }

    func testALevelThatDoesNotRestartKeepsCounting() throws {
        // fNoRestart with a limit of 0: no more significant level starts it again.
        var builder = listBuilder([ListLevel(0, "%1."), ListLevel(4, "%2.", restartLimit: 0)])
        builder.paragraphs = [
            Paragraph("a", modifiers: inList(level: 0)),
            Paragraph("b", modifiers: inList(level: 1)),
            Paragraph("c", modifiers: inList(level: 0)),
            Paragraph("d", modifiers: inList(level: 1)),
        ]
        XCTAssertEqual(
            try wordBody(of: builder.build(), speaksNumbers: true), "<p>1. a</p>\n<p>a. b</p>\n<p>2. c</p>\n<p>b. d</p>\n"
        )
    }

    func testAnInstanceThatOverridesALevelStartsItAgainAndTheListsInstancesCountTogether() throws {
        // Instance 2 uses the same list, starting level 0 at 5; instance 3 replaces level 0 with lower-case Roman numerals.
        var builder = listBuilder([ListLevel(0, "%1.")], extraInstances: [
            WordDocumentBuilder.ListInstance(listIdentifier: 7, overrides: [WordDocumentBuilder.ListOverride(level: 0, startAt: 5)]),
            WordDocumentBuilder.ListInstance(
                listIdentifier: 7, overrides: [WordDocumentBuilder.ListOverride(level: 0, replacement: ListLevel(2, "%1)", start: 2))]
            ),
        ])
        builder.paragraphs = [
            Paragraph("a", modifiers: inList(1)),
            Paragraph("b", modifiers: inList(1)),
            Paragraph("c", modifiers: inList(2)),
            Paragraph("d", modifiers: inList(2)),
            Paragraph("e", modifiers: inList(3)),
            Paragraph("f", modifiers: inList(3)),
            // The first instance goes on from where the count stands.
            Paragraph("g", modifiers: inList(1)),
        ]
        XCTAssertEqual(
            try wordBody(of: builder.build(), speaksNumbers: true),
            "<p>1. a</p>\n<p>2. b</p>\n<p>5. c</p>\n<p>6. d</p>\n<p>ii) e</p>\n<p>iii) f</p>\n<p>4. g</p>\n"
        )
    }

    func testAHeadingStyleLinkedToAListNumbersItsHeadingsAndTheBodyBetweenDoesNotRestartThem() throws {
        var builder = listBuilder([ListLevel(0, "Chapter %1:")])
        builder.styles[1] = WordDocumentBuilder.Style(builtInIdentifier: 1, basedOn: 0, outlineLevel: 0, bold: 1, listIndex: 1, listLevel: 0)
        builder.paragraphs = [
            Paragraph("The Beginning", style: 1),
            Paragraph("Some text."),
            Paragraph("The Middle", style: 1),
            Paragraph("More text."),
            Paragraph("The End", style: 1),
        ]
        try assertBody(
            builder,
            words: "<h1>Chapter 1: The Beginning</h1>\n<p>Some text.</p>\n<h1>Chapter 2: The Middle</h1>\n<p>More text.</p>\n<h1>Chapter 3: The End</h1>\n",
            // A numbered heading is its words alone.
            silent: "<h1>The Beginning</h1>\n<p>Some text.</p>\n<h1>The Middle</h1>\n<p>More text.</p>\n<h1>The End</h1>\n"
        )
    }

    func testAParagraphThatNamesNoListLeavesItsStylesList() throws {
        var builder = listBuilder([ListLevel(0, "%1.")])
        builder.styles.append(WordDocumentBuilder.Style(basedOn: 0, listIndex: 1, listLevel: 0))
        builder.paragraphs = [
            Paragraph("numbered by style", style: 12),
            // sprmPIlfo 0 and 0xF801 say "no list"; a style based on a numbered one is numbered too.
            Paragraph("none", style: 12, modifiers: inList(0)),
            Paragraph("also none", style: 12, modifiers: inList(0xF801)),
            Paragraph("second", style: 12),
        ]
        try assertBody(
            builder,
            words: "<p>1. numbered by style</p>\n<p>none</p>\n<p>also none</p>\n<p>2. second</p>\n",
            silent: ol(["numbered by style"]) + "<p>none</p>\n<p>also none</p>\n" + ol(["second"])
        )
    }

    func testANegativeInstanceNumberNamesTheSameInstance() throws {
        var builder = listBuilder([ListLevel(0, "%1.")])
        builder.paragraphs = [Paragraph("a", modifiers: inList(1)), Paragraph("b", modifiers: inList(0xFFFF))]
        try assertBody(builder, words: "<p>1. a</p>\n<p>2. b</p>\n", silent: ol(["a", "b"]))
    }

    // MARK: - Bullets and Levels Without Numbers

    func testBulletsAreItemsOfAListAndNoNumberLevelsAreParagraphs() throws {
        var builder = listBuilder([ListLevel(0x17, "\u{F0B7}"), ListLevel(0xFF, "")])
        builder.paragraphs = [
            Paragraph("one", modifiers: inList(level: 0)),
            Paragraph("two", modifiers: inList(level: 0)),
            Paragraph("plain", modifiers: inList(level: 1)),
            Paragraph("three", modifiers: inList(level: 0)),
        ]
        // A bullet is an item of a list in both forms.
        let expected = "<ul>\n<li>one</li>\n<li>two</li>\n</ul>\n<p>plain</p>\n<ul>\n<li>three</li>\n</ul>\n"
        try assertBody(builder, words: expected, silent: expected)
    }

    func testABulletBelowANumberNestsInIt() throws {
        var builder = listBuilder([ListLevel(0, "%1."), ListLevel(0x17, "\u{F0B7}")])
        builder.paragraphs = [
            Paragraph("step", modifiers: inList(level: 0)),
            Paragraph("detail", modifiers: inList(level: 1)),
            Paragraph("step two", modifiers: inList(level: 0)),
        ]
        try assertBody(
            builder,
            words: "<p>1. step</p>\n<ul>\n<li>detail</li>\n</ul>\n<p>2. step two</p>\n",
            silent: "<ol>\n<li>step<ul>\n<li>detail</li>\n</ul>\n</li>\n<li>step two</li>\n</ol>\n"
        )
    }

    // MARK: - Empty, Skipped, Table, and Page

    func testASkippedLevelIsNotCounted() throws {
        var builder = listBuilder([ListLevel(0, "%1.")])
        builder.paragraphs = [
            Paragraph("A", modifiers: inList()),
            // Level 12 (0x0C): the list skips the paragraph.
            Paragraph("skipped", modifiers: inList(level: 12)),
            Paragraph("C", modifiers: inList()),
        ]
        try assertBody(
            builder,
            words: "<p>1. A</p>\n<p>skipped</p>\n<p>2. C</p>\n",
            silent: ol(["A"]) + "<p>skipped</p>\n" + ol(["C"])
        )
    }

    func testAnEmptyNumberedParagraphIsItsNumberUnlessItsMarkIsHiddenOrDeleted() throws {
        // Word shows a numbered empty paragraph's number, and counts it.
        var builder = listBuilder([ListLevel(0, "%1.")])
        builder.paragraphs = [
            Paragraph("A", modifiers: inList()),
            Paragraph("", modifiers: inList()),
            Paragraph("C", modifiers: inList()),
        ]
        // Silent, an empty item has no words and is left out.
        try assertBody(builder, words: "<p>1. A</p>\n<p>2.</p>\n<p>3. C</p>\n", silent: ol(["A", "C"]))
        // With its mark hidden, or deleted, the number is not shown; a hidden one is counted.
        let hidden = WordDocumentBuilder.modifier(WordSprm.hidden, 1)
        let deleted = WordDocumentBuilder.modifier(WordSprm.deleted, 1)
        builder.paragraphs[1] = Paragraph("", modifiers: inList(), markModifiers: hidden)
        try assertBody(builder, words: "<p>1. A</p>\n<p>3. C</p>\n", silent: ol(["A", "C"]))
        // A deleted one is not counted either: it is gone.
        builder.paragraphs[1] = Paragraph("", modifiers: inList(), markModifiers: deleted)
        try assertBody(builder, words: "<p>1. A</p>\n<p>2. C</p>\n", silent: ol(["A", "C"]))
    }

    func testANumberedCellWithNoWordsBesideCellsOfWordsIsItsNumber() throws {
        // A table's numbered first column: "1." | "Apples", as Word shows it.
        var builder = listBuilder([ListLevel(0, "%1.")])
        builder.paragraphs = [
            Paragraph("", modifiers: inTable + inList(), mark: 0x07),
            Paragraph("Apples", modifiers: inTable, mark: 0x07),
            Paragraph("", modifiers: rowEnd, mark: 0x07),
        ]
        XCTAssertEqual(
            try wordBody(of: builder.build(), speaksNumbers: true),
            "<table>\n<tr><td><p>1.</p>\n</td><td><p>Apples</p>\n</td></tr>\n</table>\n"
        )
    }

    func testANumberedParagraphInATableCellKeepsItsNumber() throws {
        var builder = listBuilder([ListLevel(0, "%1.")])
        builder.paragraphs = [
            Paragraph("cell", modifiers: inTable + inList(), mark: 0x07),
            Paragraph("", modifiers: rowEnd, mark: 0x07),
        ]
        try assertBody(
            builder,
            words: "<table>\n<tr><td><p>1. cell</p>\n</td></tr>\n</table>\n",
            silent: "<table>\n<tr><td><ol>\n<li>cell</li>\n</ol>\n</td></tr>\n</table>\n"
        )
    }

    func testAPageBeginsBeforeTheNumberOfTheParagraphThatBeginsIt() throws {
        var builder = listBuilder([ListLevel(0, "%1.")])
        let pageBreakBefore = WordDocumentBuilder.modifier(WordSprm.pageBreakBefore, 1)
        builder.paragraphs = [Paragraph("Intro"), Paragraph("Item", modifiers: inList() + pageBreakBefore)]
        try assertBody(
            builder, pages: true,
            words: span(1) + "<p>Intro</p>\n<p>\(span(2))1. Item</p>\n",
            silent: span(1) + "<p>Intro</p>\n<ol>\n<li>\(span(2))Item</li>\n</ol>\n"
        )
    }

    func testANumberedParagraphThatIsAllHiddenIsStillCountedAndWritesNothingButItsNumber() throws {
        var builder = listBuilder([ListLevel(0, "%1.")])
        builder.paragraphs = [
            Paragraph(runs: [Run("hidden", hidden: 1)], modifiers: inList(), markModifiers: WordDocumentBuilder.modifier(WordSprm.hidden, 1)),
            Paragraph("shown", modifiers: inList()),
        ]
        try assertBody(builder, words: "<p>2. shown</p>\n", silent: ol(["shown"]))
    }

    func testListsThatDoNotFitLoseTheNumbersAndNotTheDocument() throws {
        var builder = listBuilder([ListLevel(0, "%1.")])
        builder.paragraphs = [Paragraph("A", modifiers: inList()), Paragraph("B", modifiers: inList())]
        // A list table that claims 32,767 lists in a few bytes.
        let data = builder.build { _, table, layout in
            table[layout.listFormats] = 0xFF
            table[layout.listFormats + 1] = 0x7F
        }
        for speaks in [true, false] {
            XCTAssertEqual(try wordBody(of: data, speaksNumbers: speaks), "<p>A</p>\n<p>B</p>\n")
        }
        XCTAssertEqual(try wordBody(of: builder.build(), speaksNumbers: true), "<p>1. A</p>\n<p>2. B</p>\n")
    }

    // MARK: - Levels With No Number, And Levels Out of Order

    func testALessSignificantLevelBeforeAMoreSignificantOneStartsTheMoreSignificantOne() throws {
        // Microsoft KB Q197139: four second-level items, then a first-level one, make the
        // first the second, whatever came before: 1.1 to 1.4, then 2.
        var builder = listBuilder([ListLevel(0, "%1."), ListLevel(0, "%1.%2")])
        builder.paragraphs = ["a", "b", "c", "d"].map { Paragraph($0, modifiers: inList(level: 1)) } + [Paragraph("e", modifiers: inList(level: 0))]
        try assertBody(
            builder,
            words: "<p>1.1 a</p>\n<p>1.2 b</p>\n<p>1.3 c</p>\n<p>1.4 d</p>\n<p>2. e</p>\n",
            silent: ol(["a", "b", "c", "d"]) + ol(["e"])
        )
    }

    func testALevelThatCountsFromAnOverriddenStartNamesItForTheLevelsAboveIt() throws {
        // An instance that starts level 0 at 2 and level 1 at 99 (how Word stores "Set Numbering Value"):
        // the third-level paragraph is 2.99.1, and the numbers go on from there.
        var builder = listBuilder(
            [ListLevel(0, "%1."), ListLevel(0, "%1.%2"), ListLevel(0, "%1.%2.%3")],
            extraInstances: [WordDocumentBuilder.ListInstance(listIdentifier: 7, overrides: [
                WordDocumentBuilder.ListOverride(level: 0, startAt: 2), WordDocumentBuilder.ListOverride(level: 1, startAt: 99),
            ])]
        )
        builder.paragraphs = [
            Paragraph("a", modifiers: inList(2, level: 2)),
            Paragraph("b", modifiers: inList(2, level: 1)),
            Paragraph("c", modifiers: inList(2, level: 0)),
        ]
        XCTAssertEqual(try wordBody(of: builder.build(), speaksNumbers: true), "<p>2.99.1 a</p>\n<p>2.100 b</p>\n<p>3. c</p>\n")
    }

    func testALevelWithNoNumberSequenceStillCountsAndRestartsTheLevelsUnderIt() throws {
        // "Part" headings of no number, with numbered items under each: the items start again.
        var builder = listBuilder([ListLevel(0xFF, ""), ListLevel(0, "%2.")])
        builder.paragraphs = [
            Paragraph("Part one", modifiers: inList(level: 0)),
            Paragraph("Apple", modifiers: inList(level: 1)),
            Paragraph("Pear", modifiers: inList(level: 1)),
            Paragraph("Part two", modifiers: inList(level: 0)),
            Paragraph("Saw", modifiers: inList(level: 1)),
        ]
        try assertBody(
            builder,
            words: "<p>Part one</p>\n<p>1. Apple</p>\n<p>2. Pear</p>\n<p>Part two</p>\n<p>1. Saw</p>\n",
            silent: "<p>Part one</p>\n" + ol(["Apple", "Pear"]) + "<p>Part two</p>\n" + ol(["Saw"])
        )
        // The same with bullets as the first level.
        builder = listBuilder([ListLevel(0x17, "\u{F0B7}"), ListLevel(0, "%2.")])
        builder.paragraphs = [
            Paragraph("Part one", modifiers: inList(level: 0)),
            Paragraph("Apple", modifiers: inList(level: 1)),
            Paragraph("Part two", modifiers: inList(level: 0)),
            Paragraph("Saw", modifiers: inList(level: 1)),
        ]
        XCTAssertEqual(
            try wordBody(of: builder.build(), speaksNumbers: true),
            "<ul>\n<li>Part one</li>\n</ul>\n<p>1. Apple</p>\n<ul>\n<li>Part two</li>\n</ul>\n<p>1. Saw</p>\n"
        )
    }

    func testAPlaceholderOfALevelWithNoNumberSequenceIsIgnored() throws {
        // [MS-DOC] LVL: placeholders for levels that have no number sequence MUST be ignored.
        var builder = listBuilder([ListLevel(0xFF, ""), ListLevel(4, "%1%2."), ListLevel(2, "%1%2.%3")])
        builder.paragraphs = [
            Paragraph("Letter A", modifiers: inList(level: 1)),
            Paragraph("A dot I", modifiers: inList(level: 2)),
            Paragraph("Letter B", modifiers: inList(level: 1)),
        ]
        XCTAssertEqual(
            try wordBody(of: builder.build(), speaksNumbers: true),
            "<p>a. Letter A</p>\n<p>a.i A dot I</p>\n<p>b. Letter B</p>\n"
        )
        // And one of a bullet level.
        builder = listBuilder([ListLevel(0, "%1."), ListLevel(0x17, "\u{F0B7}"), ListLevel(0, "%1.%2.%3")])
        builder.paragraphs = [Paragraph("x", modifiers: inList(level: 0)), Paragraph("y", modifiers: inList(level: 2))]
        XCTAssertEqual(try wordBody(of: builder.build(), speaksNumbers: true), "<p>1. x</p>\n<p>1..1 y</p>\n")
    }

    func testALevelWithNoNumberKeepsItsTextAsWords() throws {
        // [MS-DOC]'s own example of a list: a level whose text is "Example:" and has no number.
        var builder = listBuilder([ListLevel(0xFF, "Note:")])
        builder.paragraphs = [Paragraph("read this", modifiers: inList())]
        try assertBody(builder, words: "<p>Note: read this</p>\n", silent: "<p>read this</p>\n")
    }

    func testANumberThatIsHiddenTextIsCountedAndNotShown() throws {
        var builder = listBuilder([ListLevel(0, "%1.", numberIsHidden: true), ListLevel(0, "%1.%2")])
        builder.paragraphs = [Paragraph("a", modifiers: inList(level: 0)), Paragraph("b", modifiers: inList(level: 1))]
        XCTAssertEqual(try wordBody(of: builder.build(), speaksNumbers: true), "<p>a</p>\n<p>1.1 b</p>\n")
    }

    func testALevelInFullUsesItsOwnStartNotTheOverridesStart() throws {
        // LFOLVL: iStartAt MUST be ignored when a level follows; the level's own start counts.
        var builder = listBuilder([ListLevel(0, "%1.")], extraInstances: [
            WordDocumentBuilder.ListInstance(listIdentifier: 7, overrides: [
                WordDocumentBuilder.ListOverride(level: 0, startAt: 7, replacement: ListLevel(0, "%1)", start: 3)),
            ]),
        ])
        builder.paragraphs = [Paragraph("x", modifiers: inList(2))]
        XCTAssertEqual(try wordBody(of: builder.build(), speaksNumbers: true), "<p>3) x</p>\n")
    }

    // MARK: - Paragraphs a Tracked Change Deleted

    func testAParagraphWhollyDeletedIsNotCountedAndOneWithOnlyItsMarkDeletedIsJoined() throws {
        let deletedMark = WordDocumentBuilder.modifier(WordSprm.deleted, 1)
        var gone = Run("two")
        gone.isDeleted = true
        var builder = listBuilder([ListLevel(0, "%1.")])
        builder.paragraphs = [
            Paragraph("one", modifiers: inList()),
            Paragraph(runs: [gone], modifiers: inList(), markModifiers: deletedMark),
            Paragraph("three", modifiers: inList()),
        ]
        XCTAssertEqual(try wordBody(of: builder.build(), speaksNumbers: true), "<p>1. one</p>\n<p>2. three</p>\n")
        // Only the mark of the first deleted: its words and the next paragraph's are one item, with its number on the first.
        builder.paragraphs = [
            Paragraph("one", modifiers: inList(), markModifiers: deletedMark),
            Paragraph("two", modifiers: inList()),
            Paragraph("three", modifiers: inList()),
        ]
        XCTAssertEqual(try wordBody(of: builder.build(), speaksNumbers: true), "<p>1. one</p>\n<p>two</p>\n<p>2. three</p>\n")
    }

    // MARK: - What the Counting Must Not Lose

    func testAPieceModifierThatSetsALevelMovesTheParagraphToIt() throws {
        // Prm0 0x0C is sprmPIlvl.
        var builder = listBuilder([ListLevel(0, "%1."), ListLevel(0, "%1.%2")])
        builder.paragraphs = [Paragraph("x", modifiers: inList(level: 0))]
        builder.pieceCount = 2
        builder.storesPiecesInOrder = true
        builder.piecePrms = [0, WordDocumentBuilder.prm0(0x0C, 1)]
        XCTAssertEqual(try wordBody(of: builder.build(), speaksNumbers: true), "<p>1.1 x</p>\n")
    }

    func testTheMarkThatEndsARowIsNotCounted() throws {
        var builder = listBuilder([ListLevel(0, "%1.")])
        for end in [WordDocumentBuilder.modifier(WordSprm.rowEnd, 1), WordDocumentBuilder.modifier(WordSprm.innerRowEnd, 1)] {
            builder.paragraphs = [
                Paragraph("one", modifiers: inTable + inList(), mark: 0x07),
                Paragraph("", modifiers: inTable + inList() + end, mark: 0x07),
                Paragraph("two", modifiers: inTable + inList(), mark: 0x07),
                Paragraph("", modifiers: rowEnd, mark: 0x07),
            ]
            let body = try wordBody(of: builder.build(), speaksNumbers: true)
            XCTAssertTrue(body.contains("<p>1. one</p>"), body)
            XCTAssertTrue(body.contains("<p>2. two</p>"), body)
        }
    }

    func testLegalNumberingKeepsALeadingZero() throws {
        var builder = listBuilder([ListLevel(0x16, "%1."), ListLevel(0, "%1.%2", isLegal: true)])
        builder.paragraphs = [Paragraph("a", modifiers: inList(level: 0)), Paragraph("b", modifiers: inList(level: 1))]
        XCTAssertEqual(try wordBody(of: builder.build(), speaksNumbers: true), "<p>01. a</p>\n<p>01.1 b</p>\n")
    }

    func testALevelThatRestartsOnlyAfterALevelAboveZeroIsNotRestartedByTheOnesBelow() throws {
        // fNoRestart with ilvlRestartLim 1: level 2 starts again after level 0, not after level 1.
        var builder = listBuilder([ListLevel(0, "%1."), ListLevel(0, "%1.%2"), ListLevel(4, "%3.", restartLimit: 1)])
        builder.paragraphs = [
            Paragraph("a", modifiers: inList(level: 0)), Paragraph("b", modifiers: inList(level: 1)),
            Paragraph("c", modifiers: inList(level: 2)), Paragraph("d", modifiers: inList(level: 1)),
            Paragraph("e", modifiers: inList(level: 2)), Paragraph("f", modifiers: inList(level: 0)),
            Paragraph("g", modifiers: inList(level: 2)),
        ]
        XCTAssertEqual(
            try wordBody(of: builder.build(), speaksNumbers: true),
            "<p>1. a</p>\n<p>1.1 b</p>\n<p>a. c</p>\n<p>1.2 d</p>\n<p>b. e</p>\n<p>2. f</p>\n<p>a. g</p>\n"
        )
    }

    func testANegativeStartCountsFromZeroAndControlsInANumberTextAreNotWords() throws {
        var builder = listBuilder([ListLevel(0, "\u{01}%1.", start: -5)])
        builder.paragraphs = [Paragraph("x", modifiers: inList()), Paragraph("y", modifiers: inList())]
        XCTAssertEqual(try wordBody(of: builder.build(), speaksNumbers: true), "<p>0. x</p>\n<p>1. y</p>\n")
    }

    func testASimpleListHasOneLevelAndTheListsAfterItAreStillRead() throws {
        var builder = WordDocumentBuilder()
        builder.lists = [
            WordDocumentBuilder.List(identifier: 3, levels: [ListLevel(1, "%1)")], isSimple: true),
            WordDocumentBuilder.List(identifier: -16, levels: (0..<9).map { ListLevel(0, "%\($0 + 1).") }),
        ]
        // A signed list identifier, named by its instance.
        builder.listInstances = [
            WordDocumentBuilder.ListInstance(listIdentifier: 3), WordDocumentBuilder.ListInstance(listIdentifier: -16),
        ]
        builder.paragraphs = [
            Paragraph("simple", modifiers: inList(1)), Paragraph("second list", modifiers: inList(2)), Paragraph("simple again", modifiers: inList(1)),
        ]
        XCTAssertEqual(
            try wordBody(of: builder.build(), speaksNumbers: true),
            "<p>I) simple</p>\n<p>1. second list</p>\n<p>II) simple again</p>\n"
        )
    }

    func testAPlaceholderOfALessSignificantLevelIsLeftOutAndMarkdownCharactersInANumberAreEscaped() throws {
        var builder = listBuilder([ListLevel(0, "%2."), ListLevel(0, "<%1> & %2")])
        builder.paragraphs = [Paragraph("x", modifiers: inList(level: 0)), Paragraph("y", modifiers: inList(level: 1))]
        // Level 0's text names level 1 (which cannot be known yet): ignored. Level 1's has markup.
        XCTAssertEqual(try wordBody(of: builder.build(), speaksNumbers: true), "<p>. x</p>\n<p>&lt;1&gt; &amp; 1 y</p>\n")
    }

    func testAnEmptyNumberedParagraphWhoseMarkIsHiddenByItsStyleShowsNoNumber() throws {
        var builder = listBuilder([ListLevel(0, "%1.")])
        // Style 12 is hidden: the mark is hidden text through the paragraph style.
        builder.styles.append(WordDocumentBuilder.Style(basedOn: 0, hidden: 1))
        builder.paragraphs = [Paragraph("a", modifiers: inList()), Paragraph("", style: 12, modifiers: inList()), Paragraph("c", modifiers: inList())]
        XCTAssertEqual(try wordBody(of: builder.build(), speaksNumbers: true), "<p>1. a</p>\n<p>3. c</p>\n")
    }

    func testAGuessedHeadingKeepsItsNumberInTheWordsForm() throws {
        // No heading style: a paragraph in a larger size is a heading by the guess, and its number is part of it.
        var builder = listBuilder([ListLevel(0, "%1.")])
        builder.paragraphs = [
            Paragraph(runs: [Run("Big", fontSize: 40)], modifiers: inList()),
            Paragraph("Body text goes on for a good while here."),
            Paragraph("More body text."),
        ]
        XCTAssertEqual(
            try wordBody(of: builder.build(), speaksNumbers: true),
            "<h1>1. Big</h1>\n<p>Body text goes on for a good while here.</p>\n<p>More body text.</p>\n"
        )
    }

    // MARK: - Stories

    func testAListCountsAgainInEachNoteAndEachBoxWhenTheirTablesAreGood() throws {
        var builder = listBuilder([ListLevel(0, "%1.")])
        builder.paragraphs = [
            Paragraph("a", modifiers: inList()), Paragraph("b", modifiers: inList()), Paragraph("c\u{02}\u{02}", modifiers: inList()),
        ]
        builder.footnoteReferences = [5, 6]
        builder.stories = [
            .footnotes: [Paragraph("n1", modifiers: inList()), Paragraph("n2", modifiers: inList())],
            .textBoxes: [Paragraph("x", modifiers: inList()), Paragraph("y", modifiers: inList())],
        ]
        builder.writesTextBoxTable = true
        XCTAssertEqual(
            try wordBody(of: builder.build(), speaksNumbers: true),
            "<p>1. a</p>\n<p>2. b</p>\n<p>3. c</p>\n<p>1. n1</p>\n<p>1. n2</p>\n<p>1. x</p>\n<p>1. y</p>\n"
        )
        // Without the tables, each story is read whole and counts from its own start.
        builder.footnoteReferences = []
        builder.writesTextBoxTable = false
        XCTAssertEqual(
            try wordBody(of: builder.build(), speaksNumbers: true),
            "<p>1. a</p>\n<p>2. b</p>\n<p>3. c</p>\n<p>1. n1</p>\n<p>2. n2</p>\n<p>1. x</p>\n<p>2. y</p>\n"
        )
    }

    // MARK: - The Real Samples

    func testTheRealSampleWithHeadingsLinkedToAChapterListNumbersThemOnlyInTheWordsForm() throws {
        // Heading 1 to 6 in styles linked to one list: A., I., a., i., a bullet, and a level that names them all.
        let words = try wordSampleBody("doc/libreoffice-tdf104239_chapterNumbering.doc", speaksNumbers: true)
        XCTAssertTrue(words.contains("<h1>A. Heading 1</h1>"), words)
        XCTAssertTrue(words.contains("<h2>I. Heading 2</h2>"), words)
        XCTAssertTrue(words.contains("<h3>a. Heading 3</h3>"), words)
        XCTAssertTrue(words.contains("<h4>i. Heading 4</h4>"), words)
        // A bullet level has no number to write in a heading.
        XCTAssertTrue(words.contains("<h5>Heading 5</h5>"), words)
        XCTAssertTrue(words.contains("<h6>A.I.a.i..1 Heading 6</h6>"), words)
        // Silent: the headings are their words alone, at their levels.
        let silent = try wordSampleBody("doc/libreoffice-tdf104239_chapterNumbering.doc", speaksNumbers: false)
        for level in 1...6 { XCTAssertTrue(silent.contains("<h\(level)>Heading \(level)</h\(level)>"), silent) }
    }

    func testTheRealSampleOfTwoLevelsLinkedToStylesNumbersTheHeadingsAndTheirBodyOnlyInTheWordsForm() throws {
        XCTAssertEqual(
            try wordSampleBody("doc/libreoffice-list-nolevel.doc", speaksNumbers: true),
            "<h1>1. This is 1</h1>\n<p>1.1 This is 1.1</p>\n<h1>2. This is 2</h1>\n<p>2.1 This is 2.1</p>\n"
        )
        // Silent: the body lines are items of lists, nested in nothing, one list for each.
        XCTAssertEqual(
            try wordSampleBody("doc/libreoffice-list-nolevel.doc", speaksNumbers: false),
            "<h1>This is 1</h1>\n<ol>\n<li>This is 1.1</li>\n</ol>\n<h1>This is 2</h1>\n<ol>\n<li>This is 2.1</li>\n</ol>\n"
        )
    }

    func testTheRealSampleWithBulletedAndNumberedListsWritesThemAsLists() throws {
        let words = try wordSampleBody("doc/poi-lists.doc", speaksNumbers: true)
        // Bullets of three different lists are items of lists; the glyphs are not words.
        XCTAssertTrue(words.contains("<ul>\n<li>Unordered list 1</li>\n<li>UL 2</li>\n<li>UL 3</li>\n</ul>"), words)
        XCTAssertTrue(words.contains("<ul>\n<li>Tick 1</li>\n<li>Tick 2</li>\n</ul>"), words)
        // A numbered list, and a multi-level one whose numbers name the levels above.
        XCTAssertTrue(words.contains("<p>1. Ordered list 1</p>\n<p>2. OL 2</p>\n<p>3. OL 3</p>"), words)
        XCTAssertTrue(words.contains("<p>2. OL 2</p>\n<p>2.1. OL 2.1</p>\n<p>2.2. OL 2.2</p>\n<p>2.2.1. OL 2.2.1</p>"), words)
        XCTAssertTrue(words.contains("<p>2.2.2.1. OL 2.2.2.1</p>\n<p>2.2.3. OL 2.2.3</p>\n<p>3. OL 3</p>"), words)
        XCTAssertTrue(words.contains("<p>Indented once</p>"), words)
        // Silent: the same lists, the numbered ones as an `ol` with its levels nested.
        let silent = try wordSampleBody("doc/poi-lists.doc", speaksNumbers: false)
        XCTAssertTrue(silent.contains("<ul>\n<li>Unordered list 1</li>\n<li>UL 2</li>\n<li>UL 3</li>\n</ul>"), silent)
        XCTAssertTrue(silent.contains("<ol>\n<li>Ordered list 1</li>\n<li>OL 2</li>\n<li>OL 3</li>\n</ol>"), silent)
        XCTAssertTrue(silent.contains("<li>OL 2<ol>\n<li>OL 2.1</li>\n<li>OL 2.2<ol>\n<li>OL 2.2.1</li>"), silent)
        XCTAssertTrue(silent.contains("<p>Indented once</p>"), silent)
    }

    func testTheRealChapterNumberedSampleNumbersChaptersAndSectionsOnlyInTheWordsForm() throws {
        let words = try wordSampleBody("doc/libreoffice-tdf106541_chapterNumbering.doc", speaksNumbers: true)
        for line in ["1 Chapter 1, level 1", "1.1 Chapter 1, level 2", "2 Chapter 2, level 1", "2.1 Chapter 2, level 2"] {
            XCTAssertTrue(words.contains(line), "\(line) in \(words)")
        }
        let silent = try wordSampleBody("doc/libreoffice-tdf106541_chapterNumbering.doc", speaksNumbers: false)
        for line in ["Chapter 1, level 1", "Chapter 1, level 2", "Chapter 2, level 1", "Chapter 2, level 2"] {
            XCTAssertTrue(silent.contains(line), "\(line) in \(silent)")
        }
        XCTAssertFalse(silent.contains("1.1 Chapter"), silent)
    }

    // MARK: - The Reading Text

    func testListNumbersAreInTheReadingTextOnlyInTheWordsForm() throws {
        // The Markdown of a numbered paragraph written as words escapes its
        // dot ("1\. First"), so it is text and no list marker.
        var builder = listBuilder([ListLevel(0, "%1.")])
        builder.paragraphs = [Paragraph("First", modifiers: inList()), Paragraph("Second", modifiers: inList())]
        XCTAssertEqual(try wordReadingChapter(of: builder.build(), speaksNumbers: true).text, "1. First\n\n2. Second")
        // As an `ol` the Markdown marker is never part of the reading text.
        XCTAssertEqual(try wordReadingChapter(of: builder.build(), speaksNumbers: false).text, "First\n\nSecond")
    }

    func testABulletAddsNoWordToTheReadingTextInEitherForm() throws {
        var builder = listBuilder([ListLevel(0x17, "\u{F0B7}")])
        builder.paragraphs = [Paragraph("one", modifiers: inList()), Paragraph("two", modifiers: inList())]
        for speaks in [true, false] {
            XCTAssertEqual(try wordReadingChapter(of: builder.build(), speaksNumbers: speaks).text, "one\n\ntwo")
        }
    }

    func testANumberedHeadingsNumberIsHeardAndListedOnlyInTheWordsForm() throws {
        let data = try Data(contentsOf: formatSampleURL("doc/libreoffice-tdf104239_chapterNumbering.doc"))
        let words = try wordReadingChapter(of: data, speaksNumbers: true)
        XCTAssertTrue(words.text.hasPrefix("A. Heading 1\n\nI. Heading 2\n\na. Heading 3"), words.text)
        XCTAssertEqual(words.headings.first?.text, "A. Heading 1")
        XCTAssertTrue(words.text.hasSuffix("A.I.a.i..1 Heading 6"), words.text)
        let silent = try wordReadingChapter(of: data, speaksNumbers: false)
        XCTAssertEqual(silent.text, "Heading 1\n\nHeading 2\n\nHeading 3\n\nHeading 4\n\nHeading 5\n\nHeading 6")
        XCTAssertEqual(silent.headings.map(\.text), (1...6).map { "Heading \($0)" })
    }
}
