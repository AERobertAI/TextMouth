import XCTest
@testable import TextMouth

/// Letter navigation that passes over leading articles (the Leading articles
/// setting's second and third choices, TITLE-ARTICLES-RESEARCH-2026-11-13.md):
/// which row a typed prefix reaches, articles typed as words, folder names,
/// no match, and how typed letters add up within the interval.
final class TitleTypingTests: XCTestCase {

    /// A list of books in its order, one French book among them. Folders,
    /// whose names are typed as written, are checked on their own below.
    private let rows: [TypedRow<String>] = [
        TypedRow(id: "The Hobbit", title: "The Hobbit", language: nil),
        TypedRow(id: "Hamlet", title: "Hamlet", language: "en"),
        TypedRow(id: "A Tale of Two Cities", title: "A Tale of Two Cities", language: nil),
        TypedRow(id: "Treasure Island", title: "Treasure Island", language: nil),
        TypedRow(id: "Theory of Everything", title: "Theory of Everything", language: nil),
        TypedRow(id: "L'Étranger", title: "L’Étranger", language: "fr"),
        TypedRow(id: "Le Morte d'Arthur", title: "Le Morte d'Arthur", language: "en"),
        TypedRow(id: "The Hobbit Companion", title: "The Hobbit Companion", language: nil),
    ]

    /// Checks where each typed prefix goes in `rows`, failing once with
    /// every mismatch.
    private func check(
        _ expected: [(typed: String, row: String?)],
        showingInverted: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var mismatches: [String] = []
        for (typed, row) in expected {
            let reached = TitleTyping.firstRow(reachedBy: typed, in: rows, showingInverted: showingInverted)
            if reached != row {
                mismatches.append("\"\(typed)\" went to \(reached ?? "no row"), not \(row ?? "no row")")
            }
        }
        XCTAssertEqual(mismatches, [], file: file, line: line)
    }

    /// A typed prefix goes to the first row, in the list's order, whose
    /// title without its leading article begins with it, in any letter case
    /// and with or without accents; a title written without an article
    /// files as written.
    func testATypedPrefixGoesToTheFirstRowWhoseTitleWithoutItsArticleBeginsWithIt() {
        check([
            ("h", "The Hobbit"),
            ("H", "The Hobbit"),
            ("hob", "The Hobbit"),
            ("hobbit c", "The Hobbit Companion"),
            ("ha", "Hamlet"),
            // A Tale of Two Cities files under T, before Treasure Island.
            ("t", "A Tale of Two Cities"),
            ("tr", "Treasure Island"),
            ("e", "L'Étranger"),
            ("étr", "L'Étranger"),
            // An English book's "Le" is no article.
            ("le", "Le Morte d'Arthur"),
            ("le m", "Le Morte d'Arthur"),
            ("m", nil),
        ])
    }

    /// Letters that are an article, a space, and more reach a title written
    /// with that article (the user's "if the letters are not for an
    /// article"); the article alone reaches only titles filed under those
    /// letters, since more may follow; an elided article and the next
    /// letters reach its title.
    func testAnArticleTypedAsAWordReachesTheTitleWrittenWithIt() {
        check([
            ("the h", "The Hobbit"),
            ("THE HOB", "The Hobbit"),
            ("the hobbit c", "The Hobbit Companion"),
            ("a t", "A Tale of Two Cities"),
            ("a tale", "A Tale of Two Cities"),
            // The article alone, or with its space and no more.
            ("the", "Theory of Everything"),
            ("theo", "Theory of Everything"),
            ("the ", nil),
            ("a", nil),
            ("a ", nil),
            // An elided article joins the next letters, with either apostrophe.
            ("l'e", "L'Étranger"),
            ("l’é", "L'Étranger"),
            ("l'", nil),
            // An article the book's language lacks is no article.
            ("le p", nil),
        ])
    }

    /// Where the list shows titles inverted, "hobbit, t" reaches The
    /// Hobbit as its row shows it; elsewhere it reaches nothing.
    func testTheInvertedTitleIsReachedOnlyWhereTheListShowsIt() {
        check([("hobbit, t", "The Hobbit"), ("tale of two cities, a", "A Tale of Two Cities")], showingInverted: true)
        check([("hobbit, t", nil), ("tale of two cities, a", nil)], showingInverted: false)
        // A title with no article shows as written either way.
        check([("hamlet", "Hamlet")], showingInverted: true)
    }

    /// A folder's name is typed as written: "The Archive" files under T.
    func testAFolderNameIsTypedAsWritten() {
        let folders = [TypedRow(id: "archive", name: "The Archive"), TypedRow(id: "atlas", name: "Atlas")]
        XCTAssertEqual(TitleTyping.firstRow(reachedBy: "a", in: folders, showingInverted: true), "atlas")
        XCTAssertEqual(TitleTyping.firstRow(reachedBy: "the a", in: folders, showingInverted: true), "archive")
        XCTAssertEqual(TitleTyping.firstRow(reachedBy: "t", in: folders, showingInverted: true), "archive")
    }

    /// Nothing typed reaches nothing, and neither does a prefix no title
    /// begins with.
    func testNothingTypedAndNoMatchReachNoRow() {
        XCTAssertNil(TitleTyping.firstRow(reachedBy: "", in: rows, showingInverted: true))
        XCTAssertNil(TitleTyping.firstRow(reachedBy: "zz", in: rows, showingInverted: true))
        XCTAssertNil(TitleTyping.firstRow(reachedBy: "h", in: [TypedRow<String>](), showingInverted: false))
    }

    /// The first row in the list's order wins, wherever the selection is:
    /// with two rows that a prefix reaches, the earlier one, and once the
    /// list's order changes, the one now earlier.
    func testTheFirstRowInTheListsOrderWins() {
        let twice = [
            TypedRow(id: "first", title: "The Hobbit", language: nil),
            TypedRow(id: "second", title: "Hobbit", language: nil),
        ]
        XCTAssertEqual(TitleTyping.firstRow(reachedBy: "hob", in: twice, showingInverted: false), "first")
        XCTAssertEqual(TitleTyping.firstRow(reachedBy: "hob", in: twice.reversed(), showingInverted: false), "second")
    }

    // MARK: - The Letters Typed

    /// Letters typed within the interval of the one before add up; one
    /// typed later starts a new search; exactly the interval still adds up.
    /// (The times are exact in binary, so the boundary is exact.)
    func testTypedLettersAddUpWithinTheInterval() {
        var search = TitleTypingSearch()
        XCTAssertFalse(search.isUnderWay(at: 0, interval: 1))
        XCTAssertTrue(search.add("t", at: 10, interval: 1), "the first letter starts a search")
        XCTAssertEqual(search.typed, "t")
        XCTAssertFalse(search.add("h", at: 10.5, interval: 1))
        XCTAssertEqual(search.typed, "th")
        XCTAssertFalse(search.add("e", at: 11.5, interval: 1), "a letter exactly the interval later adds up")
        XCTAssertEqual(search.typed, "the")
        XCTAssertTrue(search.isUnderWay(at: 12.5, interval: 1))
        XCTAssertFalse(search.isUnderWay(at: 12.75, interval: 1))
        XCTAssertTrue(search.add("x", at: 12.75, interval: 1), "a letter after the interval starts anew")
        XCTAssertEqual(search.typed, "x")
        XCTAssertEqual(search.lastTypedAt, 12.75)
    }

    /// A Space continues the search only while it is an article, or an
    /// article and more, of the articles given: "the", "a", "the lord"; never
    /// an elided article, another word, or nothing typed.
    func testASpaceContinuesOnlyATitleTypedWithItsArticle() {
        let english = TitleTyping.articles(ofLanguages: [nil])
        func search(_ typed: String) -> TitleTypingSearch {
            var search = TitleTypingSearch()
            search.add(typed, at: 0, interval: 1)
            return search
        }
        XCTAssertTrue(search("the").spaceContinuesTitle(articles: english))
        XCTAssertTrue(search("THE").spaceContinuesTitle(articles: english))
        XCTAssertTrue(search("a").spaceContinuesTitle(articles: english))
        XCTAssertTrue(search("an").spaceContinuesTitle(articles: english))
        XCTAssertTrue(search("the lord").spaceContinuesTitle(articles: english))
        XCTAssertFalse(search("theory").spaceContinuesTitle(articles: english))
        XCTAssertFalse(search("lord").spaceContinuesTitle(articles: english))
        XCTAssertFalse(search("lord of").spaceContinuesTitle(articles: english))
        XCTAssertFalse(TitleTypingSearch().spaceContinuesTitle(articles: english))
        XCTAssertFalse(search("le").spaceContinuesTitle(articles: english), "le is not English")
        let french = TitleTyping.articles(ofLanguages: [nil, "fr"])
        XCTAssertTrue(search("le").spaceContinuesTitle(articles: french))
        XCTAssertFalse(search("l'").spaceContinuesTitle(articles: french), "an elided article joins the next word")
    }

    /// The articles a Space may follow: English's, and those of each
    /// language the rows' books name, each language once.
    func testTheArticlesOfTheRowsLanguages() {
        XCTAssertEqual(TitleTyping.articles(ofLanguages: []), ["the", "a", "an"])
        XCTAssertEqual(TitleTyping.articles(ofLanguages: [nil, "xx", "en"]), ["the", "a", "an"])
        let mixed = TitleTyping.articles(ofLanguages: ["fr", "de-DE", "fr-CA"])
        XCTAssertTrue(["the", "le", "l'", "die", "eines"].allSatisfy(mixed.contains), "\(mixed.sorted())")
        XCTAssertFalse(mixed.contains("el"), "Spanish was named by no book")
    }
}
