import XCTest
@testable import TextMouth

/// The one limit on the depth of a Markdown text, which every walk of
/// Markdown shares (#5512): `MarkdownTree.read(_:within:_:)` refuses a text
/// nested past it before a walk begins, in two layers (the count of block
/// quotes and lists in the text, `MarkdownNesting`, and the depth of the
/// parsed tree, `MarkdownNode.levels(stopAbove:)`, measured with cmark's
/// iterator, which does not recurse), and the reader (`MarkdownDocParser`)
/// refuses what it refuses.
///
/// Every depth that reaches a walk here is one the old code, a walk with no
/// limit, survives (a few hundred levels); a depth beyond that goes only to
/// code that never recurses (`levels`, `isDeeper`), or to a thread of a
/// large stack. Hermetic: no library, no file.
final class MarkdownDepthLimitTests: XCTestCase {

    // MARK: - Helpers

    /// The limits every reading has.
    private let standard = MarkupGuard.Limits.standard

    /// The deepest nesting of containers read (128).
    private var nestingLimit: Int { standard.deepestNesting }

    /// How many levels `markdown`'s tree has, the document at 1 (no limit).
    private func levels(_ markdown: String) -> Int {
        MarkdownTree.read(markdown) { $0.levels(stopAbove: .max) }
    }

    /// Whether `MarkdownTree.read(_:within:_:)` hands `markdown` to its body
    /// under `limits`, and the error that stopped it otherwise.
    private func readOutcome(_ markdown: String, limits: MarkupGuard.Limits? = nil) -> (readIt: Bool, refusal: MarkupRefusal?) {
        var readIt = false
        do {
            try MarkdownTree.read(markdown, within: limits ?? standard) { _ in readIt = true }
        } catch {
            return (readIt, error as? MarkupRefusal)
        }
        return (readIt, nil)
    }

    /// Whether the reader refuses `markdown` under `limits`.
    private func readerRefuses(_ markdown: String, limits: MarkupGuard.Limits) -> Bool {
        MarkupGuard.$limits.withValue(limits) {
            do {
                _ = try MarkdownDocParser.parseChapter(markdown: markdown, title: "T")
                return false
            } catch {
                return error is MarkupRefusal
            }
        }
    }

    // MARK: - The limit

    /// The limit on the tree is the reader's own: twice the count of
    /// containers and 16 levels, 272; a limit set on the tree is used as it is.
    func testTheLimitOnTheTreeIsTwiceTheCountAndSixteen() {
        XCTAssertEqual(MarkdownNesting.deepestTree(under: standard), 272)
        var shallow = standard
        shallow.deepestNesting = 10
        XCTAssertEqual(MarkdownNesting.deepestTree(under: shallow), 36)
        shallow.deepestTree = 5
        XCTAssertEqual(MarkdownNesting.deepestTree(under: shallow), 5)
    }

    // MARK: - Counting levels

    /// A tree's levels are counted from the document at 1 down to its
    /// deepest leaf: a paragraph, a quote, a list and its item, emphasis.
    func testLevelsAreCountedFromTheDocument() {
        XCTAssertEqual(levels(""), 1)
        XCTAssertEqual(levels("words"), 3)
        XCTAssertEqual(levels("> words"), 4)
        XCTAssertEqual(levels("> > words"), 5)
        XCTAssertEqual(levels("- item"), 5)
        XCTAssertEqual(levels("*emphasis*"), 4)
        // A leaf that is no container (a rule, a code block) is a level of its own.
        XCTAssertEqual(levels("---"), 2)
        XCTAssertEqual(levels("> ```\n> code\n> ```"), 3)
    }

    /// The generated shapes are as deep as their names say, so the tests
    /// below sit on the limit they mean to.
    func testTheShapesAreAsDeepAsTheyClaim() {
        XCTAssertEqual(levels(DeepMarkdown.quotes(30)), 30 + 3)
        XCTAssertEqual(levels(DeepMarkdown.lists(30)), 2 * 30 + 3)
        XCTAssertEqual(levels(DeepMarkdown.emphasis(30)), 30 + 3)
        // The link, its images, and the text.
        XCTAssertEqual(levels(DeepMarkdown.links(30)), 30 + 4)
    }

    /// A body row of a table, and what is in it, counts one level more than
    /// cmark has it, as the reader has always counted (a body between the
    /// table and its rows, as swift-markdown built the tree); a header row
    /// does not.
    func testABodyRowOfATableCountsOneLevelMore() {
        // document, table, header row, cell, text.
        XCTAssertEqual(levels("| a |\n|---|"), 5)
        // The body's row, cell, and text are one level deeper than cmark's.
        XCTAssertEqual(levels("| a |\n|---|\n| b |"), 6)
        // The same table in a quote is one level deeper still.
        XCTAssertEqual(levels("> | a |\n> |---|\n> | b |"), 7)
        // Two body rows are not deeper than one: the extra level is the body's.
        XCTAssertEqual(levels("| a |\n|---|\n| b |\n| c |"), 6)
    }

    /// The count stops once a level passes the limit, saying it did.
    func testTheCountStopsPastTheLimit() {
        let tree = DeepMarkdown.quotes(200)
        let stopped = MarkdownTree.read(tree) { $0.levels(stopAbove: 10) }
        XCTAssertGreaterThan(stopped, 10)
        XCTAssertLessThanOrEqual(stopped, 12)
        // At the limit it is exact, and not past it.
        XCTAssertEqual(MarkdownTree.read(DeepMarkdown.quotes(7)) { $0.levels(stopAbove: 10) }, 10)
        XCTAssertEqual(MarkdownTree.read(DeepMarkdown.quotes(8)) { $0.levels(stopAbove: 10) }, 11)
    }

    /// Counting does not call itself, nor does the parse or the freeing of the
    /// tree around it: a tree 5,000 levels deep is parsed, counted, and freed
    /// on an 8 MiB stack (`StackProbe`), and what was written of the stack is
    /// measured (the margin is 128 KiB). A count that called itself once for a level would write 5,000
    /// frames, hundreds of KiB, and fail the assertion without overflowing.
    ///
    /// It fills a thread's stack, so it runs on GitHub's runner only: a probe
    /// that miscounted by a guard page would end the test host here.
    func testACountOfADeepTreeNeedsNoStack() throws {
        try TestMachine.skipUnlessGitHubRunner("This test fills a thread's stack with a pattern to measure the count")
        let deep = DeepMarkdown.quotes(5_000)
        let probe = StackProbe.run(margin: 128 * 1024) { MarkdownTree.read(deep) { $0.levels(stopAbove: .max) } }
        XCTAssertEqual(probe.value, 5_000 + 3)
        XCTAssertNil(probe.deepestWrite, "the count, the parse, or the freeing used the stack for each level: \(probe.deepestWrite ?? 0) bytes deep")
    }

    /// A text read inside a level of a tree (the rest of a marker line, inside
    /// its HTML block) is counted on top of that level, without a level for
    /// its own document: "> > words" is 5 levels, so inside level 4 it reaches
    /// 8, the limit, and inside level 5 it reaches 9, past it.
    func testATextReadInsideALevelIsCountedOnTopOfIt() {
        var limits = standard
        limits.deepestTree = 8
        func refused(insideLevel level: Int) -> Bool {
            do {
                try MarkdownTree.read("> > words", within: limits, insideLevel: level) { _ in }
                return false
            } catch {
                return true
            }
        }
        XCTAssertFalse(refused(insideLevel: 1))
        XCTAssertFalse(refused(insideLevel: 4))
        XCTAssertTrue(refused(insideLevel: 5))
    }

    // MARK: - Reading within the limit

    /// A text nested as the limit allows is handed to the body, and one level
    /// past it is refused, each shape at its own edge: quotes and lists by
    /// the count of containers, emphasis and images by the tree's depth.
    func testEveryShapeIsReadAtTheLimitAndRefusedJustPastIt() {
        for shape in DeepMarkdown.shapes() {
            let atTheLimit = readOutcome(shape.text(shape.edge))
            XCTAssertTrue(atTheLimit.readIt, "\(shape.name) at \(shape.edge) was refused")
            XCTAssertNil(atTheLimit.refusal, shape.name)

            let pastTheLimit = readOutcome(shape.text(shape.edge + 1))
            XCTAssertFalse(pastTheLimit.readIt, "\(shape.name) at \(shape.edge + 1) was read")
            XCTAssertEqual(pastTheLimit.refusal, .nestedTooDeeply(limit: nestingLimit), shape.name)
        }
    }

    /// A text of any depth the count can see is refused before anything is
    /// parsed: the refusal costs one pass over the bytes.
    func testAVeryDeepTextIsRefusedByTheCountBeforeItIsParsed() {
        let outcome = readOutcome(DeepMarkdown.quotes(200_000))
        XCTAssertFalse(outcome.readIt)
        XCTAssertEqual(outcome.refusal, .nestedTooDeeply(limit: nestingLimit))
    }

    /// The second layer refuses what the first cannot see: a limit on the
    /// tree set below the count (five levels, which "> > words" fills) refuses a text the count passes, and the
    /// sentence's number is the count's.
    func testTheSecondLayerRefusesWhatTheCountPasses() {
        var limits = standard
        limits.deepestTree = 5
        XCTAssertTrue(readOutcome("> words", limits: limits).readIt)
        let refused = readOutcome("> > > words", limits: limits)
        XCTAssertFalse(refused.readIt)
        XCTAssertEqual(refused.refusal, .nestedTooDeeply(limit: nestingLimit))
    }

    /// What the body throws is thrown on, not taken for a refusal.
    func testTheBodysOwnErrorIsNotAnEdgeOfTheLimit() {
        struct Mine: Error {}
        XCTAssertThrowsError(try MarkdownTree.read("words", within: standard) { _ in throw Mine() }) {
            XCTAssertTrue($0 is Mine)
        }
    }

    // MARK: - The reader refuses what the walks' limit refuses

    /// Under every limit on the tree from 1 to 20, the reader refuses a text
    /// exactly when the shared limit does: the same count of levels, down to
    /// the table body's, which is why they are one limit. Cases hold each
    /// kind of node the walks read.
    func testTheReaderAndTheSharedLimitRefuseTheSameTexts() {
        let texts: [(name: String, markdown: String)] = [
            ("words", "words"),
            ("quote", DeepMarkdown.quotes(4)),
            ("list", DeepMarkdown.lists(3)),
            ("emphasis", DeepMarkdown.emphasis(5)),
            ("links", DeepMarkdown.links(4)),
            ("table", "| a | b |\n|---|---|\n| c | d |"),
            ("table in quotes", DeepMarkdown.quotedTable(3)),
            ("header only table", "| a |\n|---|"),
            ("heading", "# A *heading* with **strong *and* emphasis**"),
            ("code in a list", "- item\n\n  ```\n  code\n  ```"),
            ("strikethrough", "~~struck *and* emphatic~~"),
            ("html block in a quote", "> <div>\n> raw\n> </div>"),
        ]
        for (name, markdown) in texts {
            for limit in 1...20 {
                var limits = standard
                limits.deepestTree = limit
                XCTAssertEqual(
                    readerRefuses(markdown, limits: limits),
                    readOutcome(markdown, limits: limits).refusal != nil,
                    "\(name) under a limit of \(limit) levels"
                )
            }
        }
    }

    /// At the standard limits too: the reader and the shared limit give the
    /// same answer at the edge of every shape.
    func testTheReaderAndTheSharedLimitAgreeAtTheEdges() {
        for shape in DeepMarkdown.shapes() {
            for count in [shape.edge - 1, shape.edge, shape.edge + 1, shape.edge + 2] {
                XCTAssertEqual(
                    readerRefuses(shape.text(count), limits: standard),
                    readOutcome(shape.text(count)).refusal != nil,
                    "\(shape.name) \(count) deep"
                )
            }
        }
    }
}
