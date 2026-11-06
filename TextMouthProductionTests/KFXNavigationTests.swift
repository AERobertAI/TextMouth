import XCTest
@testable import TextMouth

/// A navigation unit (annotated `$393`): its label, the node and offset it
/// points at, an optional type, and nested units.
fileprivate func navUnit(
    _ label: String?, _ node: Int, offset: Int = 0, type: Int? = nil, children: [IonOut] = []
) -> IonOut {
    var members: [(Int, IonOut)] = []
    if let type { members.append((238, .symbol(type))) }
    if let label { members.append((241, .structure([(244, .string(label))]))) }
    members.append((246, .structure([(155, .int(Int64(node))), (143, .int(Int64(offset)))])))
    if !children.isEmpty { members.append((247, .list(children))) }
    return .annotated([393], .structure(members))
}

/// A navigation container (annotated `$391`) of `type` (212 contents, 237
/// page list, 798 headings).
fileprivate func navContainer(_ type: Int, name: String = "n1", _ units: [IonOut]) -> IonOut {
    .annotated([391], .structure([(235, .symbol(type)), (239, .string(name)), (247, .list(units))]))
}

/// The book navigation of the default reading order.
fileprivate func navList(_ containers: [IonOut]) -> IonOut {
    .list([.structure([(178, .symbol(351)), (392, .list(containers))])])
}

/// The navigation of the KFX reader (FMT52, layer 4): the table of contents
/// as chapters and headings, the headings container's levels, and the print
/// page list as pages, on books built in code, and the feature book Amazon's
/// conversion made.
final class KFXNavigationTests: XCTestCase {

    // MARK: - Helpers

    /// A book of `sections` (each a list of nodes) whose navigation is built from the written ids.
    private func bookWith(
        _ sections: [[KFXNodeSpec]], navigation make: @escaping ([Int]) -> [IonOut]
    ) -> KFXTestBook {
        var book = KFXTestBook()
        book.sections = sections.enumerated().map { (name: "c\($0.offset)", nodes: $0.element) }
        book.navigation = { ids in navList(make(ids)) }
        return book
    }

    private func prepare(_ book: KFXTestBook, includesPages: Bool = true) throws -> MOBIParser.PreparedBook {
        var book = book
        return try KFXParser.prepareBook(bytes: book.build(), fallbackTitle: "Fallback", includesPages: includesPages)
    }

    // MARK: - Contents

    func testAnEntryAtTheStartOfASectionTitlesItsChapter() throws {
        let book = bookWith([[.text("Alpha words."), .text("More.")], [.text("Beta words.")]]) { ids in
            [navContainer(212, [navUnit("First Chapter", ids[0]), navUnit("Second Chapter", ids[2])])]
        }
        let chapters = try prepare(book).chapters.map(\.chapter)
        XCTAssertEqual(chapters.map(\.title), ["First Chapter", "Second Chapter"])
        // The titles are navigation only: nothing is added to what is read aloud.
        XCTAssertEqual(chapters.map { $0.text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }, ["Alpha words. More.", "Beta words."])
    }

    func testAnEntryInTheMiddleOfASectionIsAHeadingAtItsPlace() throws {
        let book = bookWith([[.text("Alpha words."), .text("Middle words."), .text("Last words.")]]) { ids in
            [navContainer(212, [navUnit("Start", ids[0]), navUnit("The Middle", ids[1]), navUnit("The Last", ids[2], offset: 5)])]
        }
        let chapter = try prepare(book).chapters[0].chapter
        XCTAssertEqual(chapter.headings.map(\.text), ["Start", "The Middle", "The Last"])
        let text = chapter.text
        XCTAssertEqual(chapter.headings[1].characterOffset, text.utf16.distance(from: text.startIndex, to: text.range(of: "Middle")!.lowerBound))
        // An entry at an offset inside a paragraph stands at the start of the next word.
        XCTAssertEqual(chapter.headings[2].characterOffset, text.utf16.distance(from: text.startIndex, to: text.range(of: "words.", options: .backwards)!.lowerBound))
        XCTAssertEqual(text.split(whereSeparator: \.isWhitespace).count, 6)
    }

    func testNestedEntriesAreDeeperHeadings() throws {
        let book = bookWith([[.text("Alpha."), .text("Beta."), .text("Gamma.")]]) { ids in
            [navContainer(212, [navUnit("Part", ids[0], children: [navUnit("Chapter", ids[1], children: [navUnit("Section", ids[2])])])])]
        }
        let chapter = try prepare(book).chapters[0].chapter
        XCTAssertEqual(chapter.headings.map { "\($0.level): \($0.text)" }, ["1: Part", "2: Chapter", "3: Section"])
    }

    func testEntriesWithNoLabelOrNoPlaceInTheBookAreLeftOut() throws {
        let book = bookWith([[.text("Alpha."), .text("Beta.")]]) { ids in
            [navContainer(212, [navUnit("  ", ids[0]), navUnit("Ghost", 999_999), navUnit("Real\n  Entry", ids[1])])]
        }
        let chapter = try prepare(book).chapters[0].chapter
        XCTAssertEqual(chapter.headings.map(\.text), ["Chapter 1", "Real Entry"])
    }

    func testAnEntryThatNamesTheSameStartTwiceTitlesTheChapterOnce() throws {
        let book = bookWith([[.text("Alpha.")]]) { ids in
            [navContainer(212, [navUnit("First name", ids[0]), navUnit("Second name", ids[0])])]
        }
        XCTAssertEqual(try prepare(book).chapters[0].chapter.title, "First name")
    }

    // MARK: - Headings container

    func testTheHeadingsContainerGivesLevelsAndTheirUnitsChildrenInheritThem() throws {
        var test = bookWith([[.text("One."), .text("Two."), .text("Three."), .text("Four.")]]) { ids in
            [navContainer(798, [
                navUnit("heading-nav-unit", ids[0], type: 799, children: [navUnit(nil, ids[0]), navUnit(nil, ids[2])]),
                navUnit("heading-nav-unit", ids[1], type: 803, children: [navUnit(nil, ids[1])]),
            ])]
        }
        let html = try KFXBook(bytes: test.build()).sections[0].html
        XCTAssertEqual(html, "<h1>One.</h1><h5>Two.</h5><h1>Three.</h1><p>Four.</p>")
    }

    func testAHeadingsUnitOfAnUnknownTypeNamesNoLevel() throws {
        var test = bookWith([[.text("One.")]]) { ids in
            [navContainer(798, [navUnit("x", ids[0], type: 900), navUnit("y", ids[0], type: 798)])]
        }
        XCTAssertEqual(try KFXBook(bytes: test.build()).sections[0].html, "<p>One.</p>")
    }

    // MARK: - Pages

    func testThePrintPageListBeginsEachPageAtItsNode() throws {
        let book = bookWith([[.text("Alpha one."), .text("Beta two."), .text("Gamma three.")]]) { ids in
            [navContainer(237, [navUnit("iii", ids[0]), navUnit("iv", ids[1]), navUnit("5", ids[2])])]
        }
        let prepared = try prepare(book)
        let chapter = prepared.chapters[0].chapter
        XCTAssertEqual(chapter.pages.map(\.label), ["iii", "iv", "5"])
        let text = chapter.text
        let starts = ["Alpha", "Beta", "Gamma"].map { text.utf16.distance(from: text.startIndex, to: text.range(of: $0)!.lowerBound) }
        XCTAssertEqual(chapter.pages.map(\.characterOffset), starts)
        XCTAssertTrue(prepared.chapters[0].markdown.contains("<!-- page: iii -->"))
    }

    func testAPageAtAnOffsetBeginsAtTheNextWordAndIsNeverSpoken() throws {
        let book = bookWith([[.text("Hello world again")]]) { ids in
            [navContainer(237, [navUnit("7", ids[0], offset: 5), navUnit("8", ids[0], offset: 12)])]
        }
        let chapter = try prepare(book).chapters[0].chapter
        XCTAssertEqual(chapter.pages.map(\.label), ["7", "8"])
        let text = chapter.text
        XCTAssertEqual(chapter.pages.map(\.characterOffset), [
            text.utf16.distance(from: text.startIndex, to: text.range(of: "world")!.lowerBound),
            text.utf16.distance(from: text.startIndex, to: text.range(of: "again")!.lowerBound),
        ])
        XCTAssertEqual(text.split(whereSeparator: \.isWhitespace).joined(separator: " "), "Hello world again")
    }

    func testNoPagesAreWrittenWhenNotAskedFor() throws {
        let book = bookWith([[.text("Alpha.")]]) { ids in [navContainer(237, [navUnit("1", ids[0])])] }
        let prepared = try prepare(book, includesPages: false)
        XCTAssertTrue(prepared.chapters[0].chapter.pages.isEmpty)
        XCTAssertFalse(prepared.chapters[0].markdown.contains("<!-- page:"))
    }

    func testAMachineMadePageListIsNotPages() throws {
        let book = bookWith([[.text("Alpha."), .text("Beta.")]]) { ids in
            [navContainer(237, name: "APPROXIMATE_PAGE_LIST", [navUnit("1", ids[0]), navUnit("2", ids[1])])]
        }
        XCTAssertTrue(try prepare(book).chapters[0].chapter.pages.isEmpty)
    }

    func testPagesWithNoPlaceInTheBookAreLeftOutAndTheRestAreStillPages() throws {
        let book = bookWith([[.text("Alpha."), .text("Beta.")]]) { ids in
            [navContainer(237, [navUnit("1", 424_242), navUnit("2", ids[1]), navUnit("3", ids[1])])]
        }
        // The second entry for the same place is not a second page.
        XCTAssertEqual(try prepare(book).chapters[0].chapter.pages.map(\.label), ["2"])
    }

    func testAPageLabelThatNamesNoPageTakesItsOrdinal() throws {
        let book = bookWith([[.text("Alpha."), .text("Beta.")]]) { ids in
            [navContainer(237, [navUnit("", ids[0]), navUnit("Page", ids[1])])]
        }
        XCTAssertEqual(try prepare(book).chapters[0].chapter.pages.map(\.label), ["1", "2"])
    }

    // MARK: - Hostile navigation

    func testNavigationThatPointsPastTheTextOrIsNotNavigationNeverBreaksTheWords() throws {
        for bad in [
            navList([navContainer(212, [navUnit("Far", 801, offset: 1_000_000)])]),
            navList([navContainer(237, [navUnit("Far", 801, offset: Int(Int32.max))])]),
            .list([.int(1), .null, .string("x")]),
            .structure([]),
            navList([navContainer(212, [.int(1), .null, navUnit("Neg", 801, offset: -4)])]),
            navList([.int(3)]),
        ] {
            var book = KFXTestBook()
            book.sections = [("c0", [.text("Alpha beta gamma.")])]
            book.navigation = { _ in bad }
            let words = try prepare(book).chapters[0].chapter.text.split(whereSeparator: \.isWhitespace).map(String.init)
            XCTAssertEqual(words, ["Alpha", "beta", "gamma."])
        }
    }

    func testAContentsListThatIsDeeplyNestedIsReadWithoutRecursion() throws {
        var book = KFXTestBook()
        book.sections = [("c0", [.text("Alpha beta.")])]
        // Ion cuts nesting at its own depth; a list just inside it is read.
        var nested = navUnit("Deep", 801)
        for _ in 0..<30 { nested = navUnit("Level", 801, children: [nested]) }
        let deepest = nested
        book.navigation = { _ in navList([navContainer(212, [deepest])]) }
        XCTAssertNoThrow(try prepare(book))
    }

    // MARK: - The feature book Amazon made

    func testTheFeatureBooksContentsTitleItsThreeChapters() throws {
        let book = try KFXParser.prepareBook(url: formatSampleURL("kfx/kfx-features.kfx"))
        XCTAssertEqual(book.chapters.map(\.chapter.title), [
            "Chapter One: Headings and Emphasis", "Chapter Two: Lists and Tables", "Chapter Three: Notes, Links and Pictures",
        ])
        XCTAssertEqual(book.title, "The Tool Library Handbook")
        XCTAssertEqual(book.author, "Author, Test")
        XCTAssertEqual(book.language, "en")
    }

    func testTheFeatureBooksHeadingsAreTheSixLevelsItsHeadingsContainerNames() throws {
        let headings = try KFXParser.prepareBook(url: formatSampleURL("kfx/kfx-features.kfx")).chapters
            .flatMap(\.chapter.headings).map { "\($0.level): \($0.text)" }
        XCTAssertEqual(headings, [
            "1: Chapter One: Headings and Emphasis", "2: The Level Two Heading", "3: The Level Three Heading",
            "4: The Level Four Heading", "5: The Level Five Heading", "6: The Level Six Heading", "2: A Second Section",
            "1: Chapter Two: Lists and Tables", "1: Chapter Three: Notes, Links and Pictures",
        ])
    }

    func testTheFeatureBooksPrintPagesAreItsFiveAtTheirWords() throws {
        let chapters = try KFXParser.prepareBook(url: formatSampleURL("kfx/kfx-features.kfx")).chapters.map(\.chapter)
        let pages = chapters.flatMap { chapter in
            chapter.pages.map { page -> String in
                let start = chapter.text.utf16.index(chapter.text.utf16.startIndex, offsetBy: page.characterOffset)
                return page.label + ": " + chapter.text[start...].split(whereSeparator: \.isWhitespace).prefix(3).joined(separator: " ")
            }
        }
        XCTAssertEqual(pages, [
            "1: The tool library", "2: A Second Section", "3: The stock is", "4: The ladder has", "5: The last paragraph",
        ])
    }
}
