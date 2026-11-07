import XCTest
@testable import TextMouth

/// What the verifier of the fix round found, and the limits no test touched:
/// positions near Int.max on every path a position can take, a heading or a
/// paragraph with a floated span, a work bound that follows the file's size,
/// the caps on archives, sidecars, units, and pages, and the metadata and
/// styles the real samples do not exercise.
final class KFXVerifyRoundTests: XCTestCase {

    // MARK: - Helpers

    private func single(_ nodes: [KFXNodeSpec]) -> KFXTestBook {
        var book = KFXTestBook()
        book.sections = [(name: "c0", nodes: nodes)]
        return book
    }

    private func fragments(_ book: KFXTestBook) throws -> KFXFragments {
        var book = book
        let container = try KFXContainer(bytes: book.build())
        var budget = KFXContainer.maximumValues
        return KFXFragments(try container.fragments(budget: &budget))
    }

    private func prepare(_ bytes: [UInt8]) throws -> MOBIParser.PreparedBook {
        try KFXParser.prepareBook(bytes: bytes, fallbackTitle: "T")
    }

    // MARK: - Positions near Int.max on every path

    func testHugeAndNegativePositionsOnEveryPathNeverTrapAndNeverLoseAWord() throws {
        let extremes: [Int64] = [Int64.max, Int64.max - 1, Int64.max - 5, Int64.max / 2, Int64(Int32.max), 0, -1, Int64.min + 1, Int64.min]
        for offset in extremes {
            for length in 1...7 {
                // The page's label is the text's first characters, so the text is a candidate to leave out.
                let label = String("1234567".prefix(length))
                var book = single([.text("1234567 and more words.", runs: [
                    .init(start: Int(offset), length: Int(offset), style: "bold"),
                    .init(start: 0, length: Int(offset), style: "italic"),
                ])])
                book.anchors = ["x": (url: nil, node: 801, offset: Int(offset))]
                book.navigation = { ids in
                    func container(_ type: Int, _ units: [IonOut]) -> IonOut {
                        .annotated([391], .structure([(235, .symbol(type)), (247, .list(units))]))
                    }
                    func unit(_ label: String) -> IonOut {
                        let position: IonOut = .structure([(155, .int(Int64(ids[0]))), (143, .int(offset))])
                        return .annotated([393], .structure([(241, .structure([(244, .string(label))])), (246, position)]))
                    }
                    let containers: [IonOut] = [container(237, [unit(label)]), container(212, [unit("Entry")])]
                    return .list([.structure([(178, .symbol(351)), (392, .list(containers))])])
                }
                var copy = book
                let bytes = copy.build()
                if let prepared = try? prepare(bytes) {
                    let words = prepared.chapters.flatMap { $0.chapter.text.split(whereSeparator: \.isWhitespace).map(String.init) }
                    // The text may lose its leading label where a page begins on it, never more.
                    XCTAssertTrue(words.suffix(3) == ["and", "more", "words."], "\(offset) \(length): \(words)")
                }
            }
        }
    }

    func testAPageLabelMatchingTheTextAtAnExactOffsetIsLeftOutAndNothingElseIs() throws {
        var book = single([.text("Before 11 after.")])
        book.navigation = { ids in kfxNavigation(type: 237, [(label: "11", node: ids[0], offset: 7)]) }
        var copy = book
        let chapter = try prepare(copy.build()).chapters[0].chapter
        XCTAssertEqual(chapter.text.split(whereSeparator: \.isWhitespace).map(String.init), ["Before", "after."])
        // At a wrong offset the text stays.
        var elsewhere = single([.text("Before 11 after.")])
        elsewhere.navigation = { ids in kfxNavigation(type: 237, [(label: "11", node: ids[0], offset: 3)]) }
        let kept = try prepare(elsewhere.build()).chapters[0].chapter
        XCTAssertEqual(kept.text.split(whereSeparator: \.isWhitespace).count, 3)
    }

    // MARK: - A heading holding a floated span, a paragraph starting with one

    func testAHeadingWithNoTextOfItsOwnThatHoldsOneChildOfTextIsAHeading() throws {
        let inner: IonOut = .structure([(155, .int(3)), (601, .symbol(283)), (159, .symbol(270)), (658, .symbol(58)),
                                        (146, .list([.structure([(155, .int(4)), (159, .symbol(269)), (145, .string("fl words"))])]))])
        let child: IonOut = .structure([(155, .int(2)), (159, .symbol(269)), (146, .list([.string("Alpha "), inner, .string(" gamma")]))])
        var book = single([.text("x")])
        let bytes = book.build { builder in
            let index = builder.entities.firstIndex { $0.type == 259 }!
            builder.entities[index].value = .structure([
                (176, .symbol(builder.id(of: "story_c0"))),
                (146, .list([
                    .structure([(155, .int(1)), (159, .symbol(269)), (157, .symbol(builder.id(of: "h"))), (790, .int(2)), (146, .list([child]))]),
                ])),
            ])
        }
        let chapter = try prepare(bytes).chapters[0].chapter
        XCTAssertEqual(chapter.headings.map { "\($0.level): \($0.text)" }, ["2: Alpha fl words gamma"])
        XCTAssertEqual(chapter.text.split(whereSeparator: \.isWhitespace).map(String.init), ["Alpha", "fl", "words", "gamma"])
    }

    func testAPlaceInsideAHeadingThatHoldsAFloatLandsOnItsWords() throws {
        let child: IonOut = .structure([(155, .int(2)), (159, .symbol(269)), (146, .list([.string("Alpha beta gamma")]))])
        var book = single([.text("x")])
        book.navigation = { _ in kfxNavigation(type: 237, [(label: "9", node: 2, offset: 6)]) }
        let bytes = book.build { builder in
            let index = builder.entities.firstIndex { $0.type == 259 }!
            builder.entities[index].value = .structure([
                (176, .symbol(builder.id(of: "story_c0"))),
                (146, .list([.structure([(155, .int(1)), (159, .symbol(269)), (157, .symbol(builder.id(of: "h"))), (790, .int(2)), (146, .list([child]))])])),
            ])
        }
        let chapter = try prepare(bytes).chapters[0].chapter
        XCTAssertEqual(chapter.pages.map(\.label), ["9"])
        let text = chapter.text
        // A page that begins inside a heading is written before the heading, as the EPUB reader writes it,
        // so it begins at the heading's first word.
        XCTAssertEqual(chapter.pages.map(\.characterOffset), [text.utf16.distance(from: text.startIndex, to: text.range(of: "Alpha")!.lowerBound)])
    }

    func testAParagraphStartingWithAFloatedSpanOfWordsIsOneParagraph() throws {
        let float: IonOut = .structure([(155, .int(2)), (159, .symbol(270)), (658, .symbol(58)),
                                        (146, .list([.structure([(155, .int(3)), (159, .symbol(269)), (145, .string("Floated first"))])]))])
        let rest: IonOut = .structure([(155, .int(4)), (159, .symbol(269)), (145, .string("then the remaining words"))])
        var book = single([.text("x")])
        let bytes = book.build { builder in
            let index = builder.entities.firstIndex { $0.type == 259 }!
            builder.entities[index].value = .structure([
                (176, .symbol(builder.id(of: "story_c0"))),
                (146, .list([.structure([(155, .int(1)), (159, .symbol(269)), (146, .list([float, rest]))])])),
            ])
        }
        let book2 = try KFXBook(bytes: bytes)
        XCTAssertEqual(book2.sections[0].html, "<p> Floated first then the remaining words</p>")
        let lines = try prepare(bytes).chapters[0].chapter.text.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }
        XCTAssertEqual(lines.count, 1)
    }

    // MARK: - The work bound follows the file's size

    func testTheWorkLimitIsAMultipleOfTheFilesSizeWithAFloorAndACeiling() {
        XCTAssertEqual(KFXBook.workLimit(forBytes: 0), KFXBook.workFloor)
        XCTAssertEqual(KFXBook.workLimit(forBytes: 1_000_000), 16_000_000)
        XCTAssertEqual(KFXBook.workLimit(forBytes: Int.max), KFXWalk.maximumWork)
    }

    func testASmallFileThatAsksForMuchMoreWorkThanItsSizeIsRefusedQuickly() throws {
        // 400 page templates naming one storyline of 2,000 numbers: a small file, 800,000 steps.
        var book = single([])
        let bytes = book.build { builder in
            let story = builder.id(of: "story_c0")
            let index = builder.entities.firstIndex { $0.type == 259 }!
            builder.entities[index].value = .structure([(176, .symbol(story)), (146, .list((0..<2_000).map { IonOut.int(Int64($0)) }))])
            let section = builder.entities.firstIndex { $0.type == 260 }!
            builder.entities[section].value = .structure([
                (174, .symbol(builder.id(of: "c0"))),
                (141, .list((0..<400).map { _ in IonOut.structure([(155, .int(1)), (176, .symbol(story))]) })),
            ])
        }
        XCTAssertLessThan(bytes.count, 20_000)
        let error = assertRefusedQuickly("work bound") { try KFXBook(bytes: bytes) }
        XCTAssertTrue(error?.localizedDescription.contains("more work") == true, "\(String(describing: error))")
    }

    func testARealBookStaysFarUnderItsWorkLimit() throws {
        // The feature book and Alice read: their work is about their size, far under sixteen times it.
        XCTAssertNoThrow(try KFXParser.prepareBook(url: formatSampleURL("kfx/kfx-features.kfx")))
        XCTAssertNoThrow(try KFXParser.prepareBook(url: formatSampleURL("kfx/alice.kfx")))
    }

    // MARK: - Caps

    func testTheTotalSizeOfASetsContainersIsCapped() throws {
        var book = single([.text("Words.")])
        let bytes = book.build()
        let made = try makeTemporaryZip(prefix: "kfx-cap", orderedEntries: (0..<3).map { TestZIPEntry("part\($0).kfx", Data(bytes)) })
        addTeardownBlock { try? FileManager.default.removeItem(at: made) }
        XCTAssertEqual(try KFXPackage.containers(inArchiveAt: made).count, 3)
        XCTAssertThrowsError(try KFXPackage.containers(inArchiveAt: made, totalLimit: Int64(bytes.count) * 2)) {
            XCTAssertEqual($0 as? DocumentTooLargeError, DocumentTooLargeError(limit: Int64(bytes.count) * 2))
        }
    }

    func testTheBytesOfSidecarsAreCapped() throws {
        let root = try makeSandboxDirectory("SidecarCap")
        var main = single([.text("Words.")])
        let mainBytes = main.build { builder in builder.entities.removeAll { $0.type == 490 } }
        let url = root.appendingPathComponent("Book.kfx")
        try Data(mainBytes).write(to: url)
        var meta = KFXContainerBuilder()
        meta.add(type: 490, .structure([(491, .list([.structure([
            (495, .string("kindle_title_metadata")),
            (258, .list([.structure([(492, .string("title")), (307, .string("From The Sidecar"))])])),
        ])]))]))
        let sdr = root.appendingPathComponent("Book.sdr")
        try FileManager.default.createDirectory(at: sdr, withIntermediateDirectories: true)
        try Data(meta.build()).write(to: sdr.appendingPathComponent("meta.kfx"))
        XCTAssertEqual(try KFXParser.prepareBook(url: url).title, "From The Sidecar")
        try KFXParser.$currentSidecarBytes.withValue(10) {
            XCTAssertEqual(try KFXParser.prepareBook(url: url).title, "Book")
        }
    }

    func testTheUnitsAndPagesOfNavigationAreCapped() throws {
        var book = single([.text("Alpha.")])
        book.navigation = { ids in
            kfxNavigation(type: 237, (1...5).map { (label: "\($0)", node: ids[0], offset: $0) })
        }
        let all = KFXNavigation(try fragments(book))
        XCTAssertEqual(all.pages.count, 5)
        XCTAssertEqual(KFXNavigation(try fragments(book), maximumPages: 2).pages.count, 2)
        XCTAssertEqual(KFXNavigation(try fragments(book), maximumUnits: 3).pages.count, 3)
    }

    // MARK: - Tables, metadata, styles

    func testATableFootIsWritten() throws {
        let book = single([.typed(278, [.typed(455, [.typed(279, [.text("A"), .text("B")])])])])
        var copy = book
        XCTAssertEqual(try KFXBook(bytes: copy.build()).sections[0].html, "<table><tfoot><tr><td>A</td><td>B</td></tr></tfoot></table>")
    }

    func testTheFlatMetadataGivesATitleAnAuthorAndALanguage() throws {
        var book = single([.text("Words.")])
        let bytes = book.build { builder in
            builder.entities.removeAll { $0.type == 490 }
            builder.add(type: 258, .structure([(153, .string("Flat Title")), (222, .string("Flat Author")), (10, .string("fr"))]))
        }
        let metadata = try KFXBook(bytes: bytes).metadata
        XCTAssertEqual(metadata.title, "Flat Title")
        XCTAssertEqual(metadata.author, "Flat Author")
        XCTAssertEqual(metadata.language, "fr")
    }

    func testEveryBoldWeightAndItalicSlantTheBookUsesIsRead() {
        func style(_ field: Int, _ symbol: Int) -> KFXStyle {
            KFXStyle(properties: IonStruct(fields: [IonField(id: field, value: .symbol(symbol))]))
        }
        for weight in [361, 362, 363] { XCTAssertTrue(style(13, weight).isBold, "\(weight)") }
        for weight in [350, 355, 360] { XCTAssertFalse(style(13, weight).isBold, "\(weight)") }
        for slant in [381, 382] { XCTAssertTrue(style(12, slant).isItalic, "\(slant)") }
        XCTAssertFalse(style(12, 350).isItalic)
    }
}
