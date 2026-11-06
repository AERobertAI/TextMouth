import XCTest
import os
@testable import TextMouth

/// The fix round of the KFX reader (FMT52, after the review of November 6):
/// paragraphs that hold inline nodes, the work limit, overlapping fragments,
/// a MOBI book whose name begins CONT, named pipes, whole-paragraph emphasis,
/// pictures that are headings, places the walk once lost, joined sections,
/// authors, marks, and navigation given by name. Inline children are built as
/// Amazon writes them (strings and nodes in one list), and the real inline
/// sample is read in `KFXInlineBookTests`.
final class KFXFixRoundTests: XCTestCase {

    // MARK: - Helpers

    /// U+FDD0, the noncharacter that stands for an inline node, made without a literal.
    static let noncharacter = String(Unicode.Scalar(0xFDD0 as UInt32).map(Character.init) ?? "?")

    private func htmlOf(_ book: KFXTestBook, includesPages: Bool = true) throws -> String {
        var book = book
        return try KFXBook(containers: [KFXContainer(bytes: book.build())], includesPages: includesPages)
            .sections.map(\.html).joined(separator: "|")
    }

    private func single(_ nodes: [KFXNodeSpec]) -> KFXTestBook {
        var book = KFXTestBook()
        book.sections = [(name: "c0", nodes: nodes)]
        return book
    }

    private func prepare(_ book: KFXTestBook) throws -> MOBIParser.PreparedBook {
        var book = book
        return try KFXParser.prepareBook(bytes: book.build(), fallbackTitle: "T")
    }

    private func words(_ book: KFXTestBook) throws -> [String] {
        try prepare(book).chapters.flatMap { $0.chapter.text.split(whereSeparator: \.isWhitespace).map(String.init) }
    }

    // MARK: - Finding 1: inline nodes among the words

    func testAParagraphOfStringsAndAnInlinePictureKeepsAllItsWords() throws {
        let book = single([.mixed([.string("Text then "), .image(alt: ""), .string(" more text.")])])
        XCTAssertEqual(try words(book), ["Text", "then", "more", "text."])
        let alt = single([.mixed([.string("Before picture "), .image(alt: "first inline alt"), .string(" middle words after the page.")])])
        XCTAssertEqual(try words(alt), ["Before", "picture", "first", "inline", "alt", "middle", "words", "after", "the", "page."])
    }

    func testTwoPicturesSideBySideDoNotRunTogether() throws {
        let book = single([.mixed([.image(alt: "first of two"), .string(" "), .image(alt: "second of two")])])
        XCTAssertEqual(try words(book), ["first", "of", "two", "second", "of", "two"])
    }

    func testAnInlineSpanThatHoldsWordsIsSetOffByWordBoundaries() throws {
        let book = single([.mixed([.string("Text "), .span("floated span words"), .string("tail.")])])
        XCTAssertEqual(try words(book), ["Text", "floated", "span", "words", "tail."])
    }

    func testMathIsReadByItsAccessibleName() throws {
        let book = single([.mixed([.string("Math inline "), .math(alt: "y equals two"), .string(" done.")])])
        XCTAssertEqual(try words(book), ["Math", "inline", "y", "equals", "two", "done."])
    }

    func testAHeadingHoldingAPictureIsAHeadingWithItsWords() throws {
        let book = single([.mixed([.string("Heading "), .image(alt: "x"), .string(" words")], heading: 2), .text("Body.")])
        let chapter = try prepare(book).chapters[0].chapter
        XCTAssertEqual(chapter.headings.map { "\($0.level): \($0.text)" }.first, "2: Heading x words")
    }

    func testRunsAndPlacesOfTheParentCountEachInlineNodeAsOneCodePoint() throws {
        // "Before picture " (15) + the picture (1) + " middle" (7): a run at 16 for 7 is " middle".
        var book = single([.mixed(
            [.string("Before picture "), .image(alt: "pic"), .string(" middle words."),],
            runs: [.init(start: 16, length: 7, style: "bold")])])
        book.title = "T"
        let html = try htmlOf(book)
        XCTAssertTrue(html.contains("<strong> middle</strong>"), html)
        XCTAssertTrue(html.contains("Before picture <img alt=\"pic\"/>"), html)
    }

    func testAPlaceholderScalarInTheBooksOwnTextIsNotAnInlineNode() throws {
        let book = single([.mixed([.string("a" + KFXFixRoundTests.noncharacter + "b "), .image(alt: "pic")])])
        XCTAssertEqual(try words(book), ["a\u{FFFD}b", "pic"])
    }

    // MARK: - Finding 4: one counter of work against one limit

    private func fragments(_ book: KFXTestBook) throws -> KFXFragments {
        var book = book
        let container = try KFXContainer(bytes: book.build())
        var budget = KFXContainer.maximumValues
        return KFXFragments(try container.fragments(budget: &budget))
    }

    func testWhitespaceTextThatWritesNothingStillCostsWork() throws {
        let book = single((0..<40).map { _ in KFXNodeSpec.text(String(repeating: " ", count: 5_000)) })
        var walk = KFXWalk(fragments: try fragments(book), maximumWork: 50_000)
        assertRefusedQuickly("whitespace work") { try walk.section(named: "c0") }
    }

    func testNodesThatAreNotNodesStillCostWork() throws {
        let junk = IonOut.list((0..<5_000).map { .int(Int64($0)) })
        var book = single([])
        let bytes = book.build { builder in
            let index = builder.entities.firstIndex { $0.type == 259 }!
            builder.entities[index].value = .structure([(176, .symbol(builder.id(of: "story_c0"))), (146, junk)])
        }
        let container = try KFXContainer(bytes: bytes)
        var budget = KFXContainer.maximumValues
        var walk = KFXWalk(fragments: KFXFragments(try container.fragments(budget: &budget)), maximumWork: 1_000)
        assertRefusedQuickly("junk children") { try walk.section(named: "c0") }
    }

    func testRunsAndFieldsCostWork() throws {
        let runs = (0..<1_500).map { _ in KFXNodeSpec.Run(start: 0, length: 1, style: "bold") }
        let book = single((0..<20).map { _ in KFXNodeSpec.text("a", runs: runs) })
        var walk = KFXWalk(fragments: try fragments(book), maximumWork: 5_000)
        assertRefusedQuickly("run work") { try walk.section(named: "c0") }
    }

    func testARealBooksWorkIsNearItsSize() throws {
        var walk = KFXWalk(fragments: try fragments(single([.text("A short paragraph."), .text("Another one.")])), maximumWork: 200)
        XCTAssertNoThrow(try walk.section(named: "c0"))
    }

    func testARunOfVersionMarkersAndOfAnnotationIdsIsBudgeted() {
        var budget = 1_000
        let markers = [UInt8](repeating: 0, count: 0) + (0..<5_000).flatMap { _ in IonWriter.marker }
        XCTAssertThrowsError(try IonReader.values(in: KFXView(markers), budget: &budget))
        budget = 1_000
        let ids = IonOut.annotated(Array(repeating: 5, count: 3_000), .int(1))
        XCTAssertThrowsError(try IonReader.values(in: KFXView(IonWriter.document(ids)), budget: &budget))
    }

    // MARK: - Finding 3: overlapping fragments

    func testAFragmentListedManyTimesIsRefusedBeforeItIsDecodedAgain() throws {
        var book = single([.text("Real.")])
        var bytes = book.build()
        // Row 1 of the entity table now points at row 0's bytes: same offset and length.
        let container = try KFXContainer(bytes: bytes)
        XCTAssertGreaterThan(container.entities.count, 1)
        let table = 18
        for field in 8..<24 { bytes[table + 24 + field] = bytes[table + field] }
        assertRefusedQuickly("overlap") { try KFXContainer(bytes: bytes) }
    }

    // MARK: - Finding 2: a Palm database named CONT...

    func testAMOBIBookWhoseNameBeginsCONTReadsAsMOBI() throws {
        var bytes = [UInt8](try Data(contentsOf: formatSampleURL("mobi/pg1952-yellow-wallpaper.mobi")))
        let name = Array("CONTACT_in_the_Yellow_Room".utf8)
        for (index, byte) in name.enumerated() { bytes[index] = byte }
        XCTAssertFalse(KFXSignature.isKFXOrProtected(bytes))
        // Version bytes that look like a container's, with the Palm type that says MOBI.
        var versioned = bytes
        versioned[4] = 1
        versioned[5] = 0
        XCTAssertFalse(KFXSignature.isKFXOrProtected(versioned))
        for fileName in ["named.mobi", "named.azw"] {
            let url = try makeSandboxDirectory("PalmCONT").appendingPathComponent(fileName)
            try Data(bytes).write(to: url)
            XCTAssertEqual(try MOBIParser.prepareBook(url: url).title, "The Yellow Wallpaper", fileName)
        }
    }

    func testTheContainerSignatureNeedsItsVersion() {
        XCTAssertEqual(KFXSignature.kind(ofPrefix: Array("CONT".utf8) + [2, 0, 0, 0]), .container)
        XCTAssertEqual(KFXSignature.kind(ofPrefix: Array("CONT".utf8) + [1, 0, 0, 0]), .container)
        XCTAssertEqual(KFXSignature.kind(ofPrefix: Array("CONTACT_".utf8)), .other)
        XCTAssertEqual(KFXSignature.kind(ofPrefix: Array("CONT".utf8) + [3, 0, 0, 0]), .other)
    }

    // MARK: - Finding 5: a named pipe

    func testANamedPipeInTheFolderIsNeverOpened() throws {
        let root = try makeSandboxDirectory("Pipe")
        var book = KFXTestBook()
        book.sections = [(name: "c0", nodes: [.text("Words here.")])]
        let main = root.appendingPathComponent("Book.kfx")
        try Data(book.build()).write(to: main)
        let sdr = root.appendingPathComponent("Book.sdr")
        try FileManager.default.createDirectory(at: sdr, withIntermediateDirectories: true)
        let pipe = sdr.appendingPathComponent("pipe.kfx")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        // A pipe with no writer would block an open for good: the read runs on
        // a queue, and the test waits for it a few seconds, not for ever.
        let finished = DispatchSemaphore(value: 0)
        let outcome = OSAllocatedUnfairLock(initialState: (kind: KFXSignature.Kind.container, chapters: -1))
        DispatchQueue.global().async {
            let kind = (try? KFXSignature.kind(ofFileAt: pipe)) ?? .container
            let chapters = (try? KFXParser.prepareBook(url: main).chapters.count) ?? 0
            outcome.withLock { $0 = (kind, chapters) }
            finished.signal()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success, "reading beside a named pipe hung")
        let result = outcome.withLock { $0 }
        XCTAssertEqual(result.kind, .other)
        XCTAssertEqual(result.chapters, 1)
    }

    // MARK: - Finding 7: protected is told before size

    func testAProtectedFileOverTheSizeLimitIsToldItIsProtected() throws {
        let url = try makeSandboxDirectory("BigProtected").appendingPathComponent("Bought.kfx")
        try Data(KFXSignature.protectedMagic + [UInt8](repeating: 0, count: 5_000)).write(to: url)
        let azw = url.deletingLastPathComponent().appendingPathComponent("Bought.azw")
        try FileManager.default.copyItem(at: url, to: azw)
        // A limit far below the file's size, as the real one is far below a 70 MB file's.
        try DocumentByteLimit.$current.withValue(1_000) {
            XCTAssertThrowsError(try KFXParser.prepareBook(url: url)) { XCTAssertEqual($0 as? MOBIError, .copyProtected) }
            XCTAssertThrowsError(try MOBIParser.prepareBook(url: azw)) { XCTAssertEqual($0 as? MOBIError, .copyProtected) }
        }
    }

    // MARK: - Finding 6: the folder beside a book is checked in the import

    func testImportingABookWithAVoucherInItsFolderIsRefused() throws {
        let root = try makeSandboxDirectory("ImportSdr")
        var book = KFXTestBook()
        book.sections = [(name: "c0", nodes: [.text("Words here.")])]
        let main = root.appendingPathComponent("Book.kfx")
        try Data(book.build()).write(to: main)
        let sdr = root.appendingPathComponent("Book.sdr")
        try FileManager.default.createDirectory(at: sdr, withIntermediateDirectories: true)
        try Data("key".utf8).write(to: sdr.appendingPathComponent("voucher"))
        XCTAssertThrowsError(try FileImportService.importFileWithReport(from: main)) {
            XCTAssertTrue(
                $0.localizedDescription.hasSuffix("This Kindle book is copy-protected, and TextMouth can't read copy-protected books."),
                $0.localizedDescription)
        }
        // Without the voucher it imports.
        try FileManager.default.removeItem(at: sdr.appendingPathComponent("voucher"))
        XCTAssertNoThrow(try importedForTest(main))
    }

    // MARK: - Finding 8, 9, 11, 15: paragraphs

    func testACellHoldingOneParagraphWritesNoParagraphOfItsOwn() throws {
        let book = single([.table(caption: nil, header: ["Season", "Loans"], rows: [["Spring", "Forty"]])])
        let html = try htmlOf(book)
        XCTAssertTrue(html.contains("<thead><tr><td>Season</td><td>Loans</td></tr></thead>"), html)
        XCTAssertTrue(html.contains("<tbody><tr><td>Spring</td><td>Forty</td></tr></tbody>"), html)
    }

    func testANodesOwnStyleIsEmphasisOutsideHeadings() throws {
        var book = single([.text("Whole in em."), .text("Title", heading: 1)])
        book.styles["wholeItalic"] = (false, true, false)
        // Put the style on the first node by rebuilding it as a raw node.
        let bytes = book.build { builder in
            let index = builder.entities.firstIndex { $0.type == 259 }!
            let name = builder.id(of: "wholeItalic")
            builder.entities[index].value = .structure([
                (176, .symbol(builder.id(of: "story_c0"))),
                (146, .list([.structure([(155, .int(1)), (159, .symbol(269)), (157, .symbol(name)), (145, .string("Whole in em."))])])),
            ])
        }
        XCTAssertEqual(try KFXBook(bytes: bytes).sections[0].html, "<p><em>Whole in em.</em></p>")
    }

    func testAPictureDropCapAndItsTextAreOneParagraph() throws {
        let book = single([.typed(269, [
            .image(alt: "W"), .raw(.structure([(155, .int(5)), (159, .symbol(269)), (145, .string("ith a picture drop cap."))])),
        ])])
        let html = try htmlOf(book)
        XCTAssertEqual(html, "<p><img alt=\"W\"/>ith a picture drop cap.</p>")
    }

    func testAPictureThatIsAHeadingIsAHeading() throws {
        var book = single([.text("x")])
        let bytes = book.build { builder in
            let index = builder.entities.firstIndex { $0.type == 259 }!
            builder.entities[index].value = .structure([
                (176, .symbol(builder.id(of: "story_c0"))),
                (146, .list([.structure([
                    (155, .int(1)), (159, .symbol(271)), (584, .string("Picture Only Heading")),
                    (790, .int(2)), (157, .symbol(builder.id(of: "h"))),
                ])])),
            ])
        }
        XCTAssertEqual(try KFXBook(bytes: bytes).sections[0].html, "<h2><img alt=\"Picture Only Heading\"/></h2>")
    }

    // MARK: - Finding 12: places once lost

    func testAPageAtTheEndOfASectionThatWritesNothingIsNotLost() throws {
        var book = single([.text("Alpha."), .image(alt: nil)])
        book.navigation = { ids in kfxNavigation(type: 237, [(label: "2", node: ids[1], offset: 0)]) }
        let chapter = try prepare(book).chapters[0].chapter
        XCTAssertEqual(chapter.pages.map(\.label), ["2"])
    }

    func testAPlaceInAContainerWithAnOffsetStandsAtItsStart() throws {
        var book = single([.container([.text("Alpha."), .text("Beta.")])])
        book.navigation = { ids in kfxNavigation(type: 237, [(label: "4", node: ids[0], offset: 5)]) }
        XCTAssertEqual(try prepare(book).chapters[0].chapter.pages.map(\.label), ["4"])
    }

    func testAPageTemplatesIdIsTheStartOfItsSection() throws {
        var book = single([.text("Alpha."), .text("Beta.")])
        // The section's template is the node after the book's nodes (the next id).
        book.navigation = { _ in kfxNavigation(type: 237, [(label: "1", node: 803, offset: 0)]) }
        XCTAssertEqual(try prepare(book).chapters[0].chapter.pages.map(\.label), ["1"])
    }

    // MARK: - Finding 10: a cut is not a chapter

    func testASectionThatBeginsNothingJoinsTheChapterBeforeIt() throws {
        var book = KFXTestBook()
        book.sections = [
            (name: "c0", nodes: [.text("One", heading: 1), .text("First part.")]),
            (name: "c1", nodes: [.text("Second part, cut by a page break.")]),
            (name: "c2", nodes: [.text("Two", heading: 1), .text("Another.")]),
        ]
        let prepared = try prepare(book)
        XCTAssertEqual(prepared.chapters.map(\.chapter.title), ["One", "Two"])
        XCTAssertTrue(prepared.chapters[0].chapter.text.contains("Second part"))
    }

    func testAContentsEntryAtASectionsStartBeginsAChapterAndOneDeeperDoesNot() throws {
        var book = KFXTestBook()
        book.sections = [
            (name: "c0", nodes: [.text("Alpha.")]),
            (name: "c1", nodes: [.text("Beta."), .text("Gamma.")]),
            (name: "c2", nodes: [.text("Delta.")]),
        ]
        // ids: Alpha 801, Beta 802, Gamma 803, Delta 804. Entries: Alpha (start of c0), Beta (start of c1), Gamma (deeper, in c1).
        book.navigation = { ids in
            kfxNavigation(type: 212, [(label: "First", node: ids[0], offset: 0), (label: "Second", node: ids[1], offset: 0), (label: "Deep", node: ids[2], offset: 0)])
        }
        let prepared = try prepare(book)
        // c2 begins nothing and joins c1.
        XCTAssertEqual(prepared.chapters.map(\.chapter.title), ["First", "Second"])
        XCTAssertEqual(prepared.chapters[1].chapter.headings.map(\.text), ["Second", "Deep"])
        XCTAssertTrue(prepared.chapters[1].chapter.text.contains("Delta"))
    }

    func testABookWithNoContentsAndNoHeadingsIsOneChapterWithNoHeadingMadeUp() throws {
        var book = KFXTestBook()
        book.sections = [
            (name: "c0", nodes: [.text("First words.")]), (name: "c1", nodes: [.text("Second words.")]),
            (name: "c2", nodes: [.text("Third words.")]),
        ]
        let prepared = try prepare(book)
        XCTAssertEqual(prepared.chapters.count, 1)
        XCTAssertEqual(prepared.chapters[0].chapter.headings.count, 0)
        XCTAssertFalse(prepared.chapters[0].markdown.contains("textmouth-heading"))
        XCTAssertEqual(try words(book), ["First", "words.", "Second", "words.", "Third", "words."])
    }

    // MARK: - Finding 13: authors

    func testPreviewersFlippedAuthorsAreFlippedBack() throws {
        var book = single([.text("Words.")])
        book.authors = ["Carroll, Lewis", "Plain Name", "Mononym", "Vega, Tomas de la Jr."]
        let bytes = book.build { builder in
            builder.entities.removeAll { $0.type == 490 }
            builder.add(type: 490, .structure([(491, .list([
                .structure([(495, .string("kindle_title_metadata")), (258, .list([
                    .structure([(492, .string("author")), (307, .string("Carroll, Lewis"))]),
                    .structure([(492, .string("author")), (307, .string("Plain Name"))]),
                    .structure([(492, .string("author")), (307, .string("Smith"))]),
                ]))]),
                .structure([(495, .string("kindle_audit_metadata")), (258, .list([
                    .structure([(492, .string("file_creator")), (307, .string("KindlePreviewer"))]),
                ]))]),
            ]))]))
        }
        XCTAssertEqual(try KFXBook(bytes: bytes).metadata.author, "Lewis Carroll, Plain Name, Smith")
    }

    func testAnotherToolsNamesAreLeftAlone() throws {
        var book = single([.text("Words.")])
        book.authors = ["Carroll, Lewis"]
        XCTAssertEqual(try KFXBook(bytes: book.build()).metadata.author, "Carroll, Lewis")
    }

    // MARK: - Finding 14, 17, 18, 19, 20

    func testADamagedMemberOfASetIsDamageNotWrongWords() throws {
        var book = single([.text("The fool library opens.")])
        let bytes = book.build()
        let made = try makeTemporaryZip(prefix: "kfx-crc", orderedEntries: [TestZIPEntry("Book.kfx", Data(bytes))])
        addTeardownBlock { try? FileManager.default.removeItem(at: made) }
        var archive = [UInt8](try Data(contentsOf: made))
        // Change one stored byte of the text (the archive stores it uncompressed).
        let needle = Array("fool".utf8)
        let at = try XCTUnwrap(archive.indices.first { index in
            index + needle.count <= archive.count && Array(archive[index..<(index + needle.count)]) == needle
        })
        archive[at] = UInt8(ascii: "t")
        let url = try makeSandboxDirectory("CRC").appendingPathComponent("set.kfx-zip")
        try Data(archive).write(to: url)
        XCTAssertThrowsError(try KFXParser.prepareBook(url: url)) {
            guard case .damaged = $0 as? MOBIError else { return XCTFail("\($0)") }
        }
    }

    func testAContainerOfOnlyFlatMetadataWithAReadingOrderIsPartOfABook() throws {
        var builder = KFXContainerBuilder()
        builder.add(type: 258, .structure([(169, .list([.structure([(178, .symbol(351)), (170, .list([.symbol(900)]))])]))]))
        XCTAssertThrowsError(try KFXBook(bytes: builder.build())) { XCTAssertEqual($0 as? KFXError, .partOfABook) }
    }

    func testASidecarWithOneDamagedFragmentIsLeftOut() throws {
        var main = KFXTestBook()
        main.sections = [(name: "c0", nodes: [.text("Words here.")])]
        let mainBytes = main.build { builder in builder.entities.removeAll { $0.type == 490 } }
        var damaged = KFXContainerBuilder()
        damaged.add(type: 490, .structure([(491, .list([]))]))
        damaged.entities[0].value = nil
        damaged.entities[0].raw = IonWriter.marker + [0xF0]   // a reserved type
        let book = try KFXBook(
            containers: [KFXContainer(bytes: mainBytes)], sidecars: [KFXContainer(bytes: damaged.build())])
        XCTAssertEqual(book.sections.count, 1)
        XCTAssertEqual(try KFXBook.metadata(of: [KFXContainer(bytes: mainBytes)], sidecars: [KFXContainer(bytes: damaged.build())]).title, "")
    }

    func testMoreMarksRefuseABook() throws {
        for capability in [("continuous_popup_progression", IonOut.int(0)), ("continuous_popup_progression", .int(1))] {
            var book = single([.text("Words.")])
            book.capabilities = [(key: capability.0, value: capability.1)]
            XCTAssertThrowsError(try KFXBook(bytes: book.build()), capability.0) { XCTAssertEqual($0 as? KFXError, .noFlowingText) }
        }
        // A feature named like a capability.
        var featured = single([.text("Words.")])
        let bytes = featured.build { builder in
            builder.add(type: 585, .structure([(590, .list([.structure([(586, .string("ns")), (492, .string("yj_fixed_layout")), (589, .int(1))])]))]))
        }
        XCTAssertThrowsError(try KFXBook(bytes: bytes)) { XCTAssertEqual($0 as? KFXError, .noFlowingText) }
    }

    func testABookWhoseEverySectionIsFixedLayoutIsRefusedButOneFixedCoverIsNot() throws {
        func book(_ layouts: [Int]) -> [UInt8] {
            var book = KFXTestBook()
            book.sections = layouts.enumerated().map { (name: "c\($0.offset)", nodes: [.text("Words \($0.offset).")]) }
            return book.build { builder in
                for (index, layout) in layouts.enumerated() {
                    let entity = builder.entities.firstIndex { $0.type == 260 && $0.id == builder.id(of: "c\(index)") }!
                    builder.entities[entity].value = .structure([
                        (174, .symbol(builder.id(of: "c\(index)"))),
                        (141, .list([.structure([
                            (155, .int(Int64(7_000 + index))), (176, .symbol(builder.id(of: "story_c\(index)"))), (156, .symbol(layout)),
                        ])])),
                    ])
                }
            }
        }
        XCTAssertThrowsError(try KFXBook(bytes: book([326, 326]))) { XCTAssertEqual($0 as? KFXError, .noFlowingText) }
        XCTAssertNoThrow(try KFXBook(bytes: book([326, 323])))
    }

    func testNavigationGivenByNameIsFound() throws {
        var book = single([.text("Alpha."), .text("Beta.")])
        book.navigation = { ids in
            // The list names its container, and the container names its unit.
            .list([.structure([(178, .symbol(351)), (392, .list([.string("nav_container")]))])])
        }
        let bytes = book.build { builder in
            builder.localSymbols.append("nav_container")
            builder.localSymbols.append("nav_unit")
            builder.add(type: 391, name: "nav_container", .structure([(235, .symbol(212)), (247, .list([.symbol(builder.id(of: "nav_unit"))]))]))
            builder.add(type: 393, name: "nav_unit", .structure([
                (241, .structure([(244, .string("By Name"))])), (246, .structure([(155, .int(801)), (143, .int(0))])),
            ]))
        }
        XCTAssertEqual(try KFXParser.prepareBook(bytes: bytes, fallbackTitle: "T").chapters[0].chapter.title, "By Name")
    }

    // MARK: - Minor

    func testAContainerWhoseSchemeFieldsAreNotNumbersIsRefused() {
        for field in [410, 411] {
            var bytes = KFXContainerBuilder().build()
            let info = IonWriter.document(.structure([(field, .string("x"))]))
            let infoOffset = Int(bytes[10]) | Int(bytes[11]) << 8
            bytes.replaceSubrange(infoOffset..<(infoOffset + info.count), with: info)
            assertRefusedQuickly("scheme \(field)") { try KFXContainer(bytes: bytes) }
        }
    }

    func testTwoPageTemplatesMayNameOneStoryline() throws {
        var book = single([.text("Alpha.")])
        let bytes = book.build { builder in
            let index = builder.entities.firstIndex { $0.type == 260 }!
            let story = builder.id(of: "story_c0")
            builder.entities[index].value = .structure([
                (174, .symbol(builder.id(of: "c0"))),
                (141, .list([
                    .structure([(155, .int(1)), (176, .symbol(story))]), .structure([(155, .int(2)), (176, .symbol(story))]),
                ])),
            ])
        }
        XCTAssertEqual(try KFXBook(bytes: bytes).sections[0].html, "<p>Alpha.</p><p>Alpha.</p>")
    }

    /// Storylines that expand one another reach the walk's own depth guard
    /// (nodes nested in the Ion reach Ion's cap first, so this is the way to it).
    func testAChainOfStorylinesPastTheDepthLimitIsRefusedByTheWalk() throws {
        func chain(_ length: Int) -> [UInt8] {
            var book = single([.text("Start.")])
            return book.build { builder in
                let names = (1...length).map { "chain_\($0)" }
                builder.localSymbols += names
                let first = builder.entities.firstIndex { $0.type == 259 }!
                builder.entities[first].value = .structure([
                    (176, .symbol(builder.id(of: "story_c0"))),
                    (146, .list([.structure([(155, .int(1)), (159, .symbol(270)), (176, .symbol(builder.id(of: names[0])))])])),
                ])
                for (index, name) in names.enumerated() {
                    var node: [(Int, IonOut)] = [(155, .int(Int64(10 + index))), (159, .symbol(270))]
                    if index + 1 < names.count { node.append((176, .symbol(builder.id(of: names[index + 1])))) }
                    else { node.append((145, .string("End of the chain."))) }
                    builder.entities.append(.init(id: builder.id(of: name), type: 259, value: .structure([
                        (176, .symbol(builder.id(of: name))), (146, .list([.structure(node)])),
                    ])))
                }
            }
        }
        XCTAssertNoThrow(try KFXBook(bytes: chain(KFXWalk.maximumDepth - 5)))
        let error = assertRefusedQuickly("chain of storylines") { try KFXBook(bytes: chain(KFXWalk.maximumDepth + 10)) }
        XCTAssertTrue(error?.localizedDescription.contains("nest too deeply") == true, "\(String(describing: error))")
    }

    func testLowerAlphaAndUpperRomanListsAreNumbered() {
        XCTAssertTrue(KFXSymbol.orderedListStyles.isSuperset(of: [343, 345, 346]))
    }
}
