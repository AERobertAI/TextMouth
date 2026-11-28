import XCTest
@testable import TextMouth

/// Hostile KFX files, end to end (FMT52): the real samples cut at many
/// lengths and flipped byte by byte with a fixed seed, the limits on what a
/// book can make large, and the books that lie about what they hold. Each is
/// refused, or read as far as it can be, in well under a second, and none
/// traps. The container and Ion layers have their own hostile tests
/// (`KFXContainerTests`, `KFXIonTests`), the archive and folder ones are in
/// `KFXSetTests`.
final class KFXHostileFileTests: XCTestCase {

    // MARK: - Helpers

    private func bytes(of sample: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: formatSampleURL(sample)))
    }

    /// The fragments of a book built in code, for a test that walks them.
    private func decoded(_ book: KFXTestBook) throws -> KFXFragments {
        var book = book
        let container = try KFXContainer(bytes: book.build())
        var budget = KFXContainer.maximumValues
        return KFXFragments(try container.fragments(budget: &budget))
    }

    // MARK: - Cut

    func testTheFeatureBookCutAtManyLengthsIsRefusedAtEachQuickly() throws {
        let real = try bytes(of: "kfx/kfx-features.kfx")
        var lengths = Array(0..<200)
        lengths += Array(stride(from: 200, to: real.count, by: 61))
        lengths += [real.count - 1, real.count - 2, real.count - 100]
        for length in lengths {
            assertRefusedQuickly("cut at \(length)") {
                try KFXParser.prepareBook(bytes: Array(real.prefix(length)), fallbackTitle: "T")
            }
        }
    }

    func testAliceCutAtManyLengthsIsRefusedAtEachQuickly() throws {
        let real = try bytes(of: "kfx/alice.kfx")
        for length in Array(stride(from: 0, to: real.count, by: 4_093)) + [real.count - 1] {
            assertRefusedQuickly("cut at \(length)") { try KFXBook(bytes: Array(real.prefix(length))) }
        }
    }

    // MARK: - Flipped

    /// Flips a few bytes of `real` in each of `rounds` rounds, with a fixed
    /// seed, and reads each damaged copy with `read`. Whatever `read` does
    /// with a copy, it ends within a second; a copy that reads is fine, one
    /// that throws throws an error of the reader's own.
    private func flipRun(
        of real: [UInt8], rounds: Int, seed: UInt64, read: ([UInt8]) throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        var generator = KFXSeededGenerator(seed: seed)
        for round in 0..<rounds {
            var damaged = real
            for _ in 0..<(1 + Int(generator.next() % 5)) {
                // Half the flips fall in the first 6 KB, where the headers, tables, and symbols are.
                let limit = generator.next() % 2 == 0 ? min(6_000, damaged.count) : damaged.count
                damaged[Int(generator.next() % UInt64(limit))] = UInt8(truncatingIfNeeded: generator.next())
            }
            assertQuick("round \(round)", file: file, line: line) {
                do { try read(damaged) } catch {
                    XCTAssertTrue(
                        error is MOBIError || error is KFXError || error is DocumentTooLargeError || error is FileImportError,
                        "round \(round): \(error)", file: file, line: line)
                }
            }
        }
    }

    func testAFixedSeedByteFlipRunOverTheFeatureBookNeverTrapsOrHangs() throws {
        flipRun(of: try bytes(of: "kfx/kfx-features.kfx"), rounds: 400, seed: 20_261_106) { damaged in
            _ = try KFXParser.prepareBook(bytes: damaged, fallbackTitle: "T")
        }
    }

    func testAFixedSeedByteFlipRunOverAliceNeverTrapsOrHangs() throws {
        flipRun(of: try bytes(of: "kfx/alice.kfx"), rounds: 60, seed: 11) { damaged in
            _ = try KFXBook(bytes: damaged)
        }
    }

    // MARK: - Limits

    func testTheNodeLimitStopsAWalkOfAHugeSection() throws {
        var book = KFXTestBook()
        book.sections = [("c0", (0..<50).map { .text("Paragraph \($0).") })]
        let fragments = try decoded(book)
        var walk = KFXWalk(fragments: fragments, maximumNodes: 10)
        assertRefusedQuickly("node limit") { try walk.section(named: "c0") }
        var roomy = KFXWalk(fragments: fragments, maximumNodes: 50)
        XCTAssertNoThrow(try roomy.section(named: "c0"))
    }

    func testTheHTMLLimitStopsAWalkThatWouldWriteTooMuch() throws {
        var book = KFXTestBook()
        book.sections = [("c0", (0..<200).map { .text("Paragraph number \($0) of many.") })]
        let fragments = try decoded(book)
        var walk = KFXWalk(fragments: fragments)
        let error = DocumentByteLimit.$current.withValue(2_000) {
            assertRefusedQuickly("html limit") { try walk.section(named: "c0") }
        }
        XCTAssertEqual(error as? DocumentTooLargeError, DocumentTooLargeError(limit: 2_000))
    }

    func testTheValueBudgetStopsAContainerThatHoldsTooManyValues() throws {
        var book = KFXTestBook()
        book.sections = [("c0", (0..<100).map { .text("Paragraph \($0).") })]
        let container = try KFXContainer(bytes: book.build())
        var small = 50
        assertRefusedQuickly("value budget") { try container.fragments(budget: &small) }
    }

    // MARK: - A book that lies

    func testSymbolIdsPastTheTableAreHandledWhereverTheyStand() throws {
        var book = KFXTestBook()
        let past = Int(Int32.max)
        book.sections = [("c0", [
            .raw(.structure([
                (155, .symbol(past)), (159, .symbol(past)), (157, .symbol(past + 0)),
                (142, .list([.structure([(143, .int(0)), (144, .int(2)), (157, .symbol(past)), (179, .symbol(past))])])),
                (145, .string("Some words here.")),
            ])),
            .text("After."),
        ])]
        book.documentData = [(past, .symbol(past))]
        let prepared = try KFXParser.prepareBook(bytes: { var copy = book; return copy.build() }(), fallbackTitle: "T")
        XCTAssertEqual(
            prepared.chapters.flatMap { $0.chapter.text.split(whereSeparator: \.isWhitespace).map(String.init) },
            ["Some", "words", "here.", "After."])
    }

    func testPositionsAndOffsetsThatAreHugeOrNegativeNeverBreakTheWords() throws {
        var book = KFXTestBook()
        book.sections = [("c0", [.text("Alpha beta gamma.", runs: [
            .init(start: Int(Int32.max), length: Int(Int32.max)), .init(start: 6, length: Int(Int32.max), style: "bold"),
            .init(start: Int(Int.max - 3), length: 10, style: "bold"),
        ])])]
        let words = try KFXParser.prepareBook(bytes: { var copy = book; return copy.build() }(), fallbackTitle: "T")
            .chapters[0].chapter.text.split(whereSeparator: \.isWhitespace).map(String.init)
        XCTAssertEqual(words, ["Alpha", "beta", "gamma."])
    }

    func testTheExtremeIntegersAnIonFileCanHoldNeverTrapAnyArithmetic() throws {
        let extremes: [Int64] = [Int64.min, Int64.min + 1, -1, 0, Int64.max, Int64.max - 1]
        // Symbols, runs, link positions, and navigation offsets at the extremes.
        for value in extremes {
            var book = KFXTestBook()
            book.sections = [("c0", [.text("Alpha beta gamma.", runs: [
                .init(start: Int(value), length: Int(value), style: "bold"),
                .init(start: 2, length: Int(value), style: "bold"),
                .init(start: Int(value), length: 3, style: "italic"),
            ])])]
            book.anchors = ["x": (url: nil, node: Int(value), offset: Int(value))]
            book.navigation = { ids in
                func unit(_ label: String, _ node: Int64) -> IonOut {
                    let label: IonOut = .structure([(244, .string(label))])
                    let position: IonOut = .structure([(155, .int(node)), (143, .int(value))])
                    return .annotated([393], .structure([(241, label), (246, position)]))
                }
                func container(_ type: Int, _ unit: IonOut) -> IonOut {
                    .annotated([391], .structure([(235, .symbol(type)), (247, .list([unit]))]))
                }
                let containers: [IonOut] = [
                    container(212, unit("T", Int64(ids[0]))),
                    container(237, unit("9", value)),
                ]
                return .list([.structure([(178, .symbol(351)), (392, .list(containers))])])
            }
            let bytes = { var copy = book; return copy.build() }()
            // Whatever it does, it does not trap, and a book that reads keeps its words.
            if let prepared = try? KFXParser.prepareBook(bytes: bytes, fallbackTitle: "T") {
                XCTAssertEqual(
                    prepared.chapters.flatMap { $0.chapter.text.split(whereSeparator: \.isWhitespace).map(String.init) },
                    ["Alpha", "beta", "gamma."], "\(value)")
            }
        }
    }

    func testSymbolNamesAtTheExtremeIdsNeverTrap() {
        for symbols in [KFXSymbols.sharedOnly, KFXSymbols(sharedMaximum: 859, local: ["a"]), KFXSymbols(sharedMaximum: Int.max, local: ["a"])] {
            for id in [Int.min, Int.min + 1, -1, 0, 1, 859, 860, Int.max - 1, Int.max] {
                _ = symbols.name(of: id)
            }
        }
    }

    func testAReadingOrderNamingManySectionsThatAreNotThereIsDamageQuickly() throws {
        var book = KFXTestBook()
        book.sections = [("c0", [.text("Real.")])]
        let bytes = book.build { builder in
            builder.entities.removeAll { $0.type == 538 }
            let names = (0..<5_000).map { IonOut.symbol(900 + $0) }
            builder.add(type: 538, .structure([(169, .list([.structure([(178, .symbol(351)), (170, .list(names))])]))]))
        }
        assertRefusedQuickly("missing sections") { try KFXBook(bytes: bytes) }
    }

    func testAFragmentWhoseStructDeclaresAHugeLengthIsRefusedBeforeAnythingIsAllocated() throws {
        // A content fragment whose struct claims a huge length is refused by Ion before anything is allocated.
        var book = KFXTestBook()
        book.sections = [("c0", [.text("Real.")])]
        let bytes = book.build { builder in
            let index = builder.entities.firstIndex { $0.type == 145 }!
            builder.entities[index].value = nil
            builder.entities[index].raw = IonWriter.marker + [0xDE, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0xFF]
        }
        assertRefusedQuickly("huge list") { try KFXBook(bytes: bytes) }
    }
}
