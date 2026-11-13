import XCTest
@testable import TextMouth

/// The Library list's rows under the Leading articles setting
/// (TITLE-ARTICLES-RESEARCH-2026-11-13.md): a book's row, a feed's row in the
/// Feeds section, and a feed item's row show and speak their titles as the
/// setting shows them, "Hobbit, The" while sorting passes over articles,
/// while the books, feeds, and items keep their own titles, which their
/// commands and announcements name.
@MainActor
final class LeadingArticlesDisplayTests: XCTestCase {

    // MARK: - A Book's Row

    /// A book's row shows and speaks its title inverted only while sorting
    /// passes over articles, in the articles of its language, and its label
    /// begins with that title, as the row shows it.
    func testABooksRowShowsAndSpeaksItsTitleAsTheSettingShowsIt() {
        let hobbit = Self.book("The Hobbit", author: "J. R. R. Tolkien")
        XCTAssertNil(LeadingArticles.partOfTitle.rowTitle(of: hobbit))
        XCTAssertNil(LeadingArticles.ignoredWhenTyping.rowTitle(of: hobbit))
        XCTAssertEqual(LeadingArticles.ignoredWhenTypingAndSorting.rowTitle(of: hobbit), "Hobbit, The")

        let shown = BookRow(book: hobbit, shownTitle: "Hobbit, The").rowAccessibilityLabel
        XCTAssertTrue(shown.hasPrefix("Hobbit, The, by J. R. R. Tolkien, "), shown)
        let written = BookRow(book: hobbit).rowAccessibilityLabel
        XCTAssertTrue(written.hasPrefix("The Hobbit, by J. R. R. Tolkien, "), written)

        // A German book's "Die" is an article; an English one's is not.
        XCTAssertEqual(LeadingArticles.ignoredWhenTypingAndSorting.rowTitle(of: Self.book("Die Verwandlung", language: "de")), "Verwandlung, Die")
        XCTAssertEqual(LeadingArticles.ignoredWhenTypingAndSorting.rowTitle(of: Self.book("Die Hard", language: "en")), "Die Hard")
    }

    /// The list cache inverts each title once, for its title and language,
    /// and gives it again at once when the rows are drawn again; titles shown
    /// as written are inverted never.
    func testTheListCacheInvertsEachTitleOnce() {
        let cache = LibraryListCache()
        let hobbit = Self.book("The Hobbit")
        XCTAssertNil(cache.rowTitle(of: hobbit, articles: .partOfTitle))
        XCTAssertNil(cache.rowTitle(of: hobbit, articles: .ignoredWhenTyping))
        XCTAssertEqual(cache.titleInversionCount, 0)
        XCTAssertEqual(cache.rowTitle(of: hobbit, articles: .ignoredWhenTypingAndSorting), "Hobbit, The")
        XCTAssertEqual(cache.rowTitle(of: hobbit, articles: .ignoredWhenTypingAndSorting), "Hobbit, The")
        XCTAssertEqual(cache.titleInversionCount, 1, "a title was inverted again")
        // The same title in another language is inverted in that language's articles.
        XCTAssertEqual(cache.rowTitle(of: Self.book("Die Verwandlung", language: "de"), articles: .ignoredWhenTypingAndSorting), "Verwandlung, Die")
        XCTAssertEqual(cache.rowTitle(of: Self.book("Die Verwandlung", language: "en"), articles: .ignoredWhenTypingAndSorting), "Die Verwandlung")
        XCTAssertEqual(cache.titleInversionCount, 3)
    }

    /// Letter navigation reads rows the list cache made once for the list:
    /// every book's title folded when the list was made (3,000 books here),
    /// and none again for a key, which folds only the letters it types. A
    /// reading position leaves the rows alone, and a renamed book makes
    /// them again.
    func testTheListCacheMakesTheTypedRowsOncePerListAndAKeyFoldsNoTitle() {
        let cache = LibraryListCache()
        let books = (0..<3000).map { Self.book($0 % 7 == 0 ? "The Title \($0)" : "Title \($0)") }
        let rows = cache.typedRows(of: books)
        XCTAssertEqual(rows.count, 3000)
        XCTAssertEqual(cache.typedRowBuildCount, 3000)

        // A key: the letters are searched for and a Space is asked about
        // (`TitleTyping`). Each folds the letters typed once, and no row's
        // title, whatever the number of rows.
        let before = TitleFolding.foldCount
        let reached = TitleTyping.firstRow(
            reachedBy: "title 29", in: rows, selection: [books[10].id], isNewSearch: true, showingInverted: true
        )
        let joins = TitleTyping.spaceGoesOn(after: "title", in: rows, showingInverted: true)
        XCTAssertEqual(reached, books[29].id)
        XCTAssertTrue(joins)
        XCTAssertEqual(TitleFolding.foldCount - before, 2, "a key folded more than the letters typed")

        // Asked for again, the same list gives the same rows, made no more.
        XCTAssertEqual(cache.typedRows(of: books), rows)
        XCTAssertEqual(cache.typedRowBuildCount, 3000, "the rows were made again for an unchanged list")

        // A reading position changes no list: the rows are kept.
        var moved = books
        moved[5].readingPosition = ReadingPosition(characterOffset: 50)
        cache.libraryDidChange(from: Library(books: books), to: Library(books: moved))
        XCTAssertEqual(cache.typedRows(of: moved), rows)
        XCTAssertEqual(cache.typedRowBuildCount, 3000, "a reading position made the rows again")

        // A renamed book is a change of the list: the rows are made anew,
        // and the new title is the one typing reaches.
        var renamed = moved
        renamed[5].title = "Zebra Crossing"
        cache.libraryDidChange(from: Library(books: moved), to: Library(books: renamed))
        let renamedRows = cache.typedRows(of: renamed)
        XCTAssertEqual(cache.typedRowBuildCount, 6000)
        XCTAssertEqual(TitleTyping.firstRow(reachedBy: "zebra", in: renamedRows, showingInverted: false), renamed[5].id)
        XCTAssertNil(TitleTyping.firstRow(reachedBy: "zebra", in: rows, showingInverted: false))

        // Another list (a search's narrowing) is made for its own books.
        let narrowed = Array(renamed.prefix(10))
        XCTAssertEqual(cache.typedRows(of: narrowed).map(\.id), narrowed.map(\.id))
        XCTAssertEqual(cache.typedRowBuildCount, 6010)
    }

    /// A search finds a book by its title as its row shows it from the
    /// title the cache already inverted, and by its title as written and
    /// its author, in every choice.
    func testASearchFindsABookByItsShownTitleAndItsOwn() {
        let hobbit = Self.book("The Hobbit", author: "J. R. R. Tolkien")
        XCTAssertTrue(LibraryViewModel.book(hobbit, isFoundBy: "the hob", shownTitle: nil))
        XCTAssertFalse(LibraryViewModel.book(hobbit, isFoundBy: "hobbit, the", shownTitle: nil))
        XCTAssertTrue(LibraryViewModel.book(hobbit, isFoundBy: "hobbit, the", shownTitle: "Hobbit, The"))
        XCTAssertTrue(LibraryViewModel.book(hobbit, isFoundBy: "tolkien", shownTitle: "Hobbit, The"))
        XCTAssertFalse(LibraryViewModel.book(hobbit, isFoundBy: "silmarillion", shownTitle: "Hobbit, The"))
    }

    // MARK: - The Feeds Section

    /// The Feeds section's rows sort by title without its article and show
    /// the article after it while sorting passes over articles, their
    /// labels beginning with the title as shown; the other two choices keep
    /// the feeds' order and titles. The feeds keep their own titles.
    func testTheFeedsSectionSortsAndShowsFeedTitlesAsTheSettingSays() async throws {
        let world = try FeedTestWorld(self, label: "LeadingArticlesFeeds")
        for (title, path) in [("The Digital Antiquarian", "/antiquarian.xml"), ("Planet Money", "/money.xml"), ("A Way with Words", "/words.xml")] {
            _ = try await subscribe(world, title: title, path: path)
        }
        let top = LibraryLocation(category: .folders, folderPath: "")
        let now = Date()
        let asWritten = LibraryFeedsSectionRows.rows(at: top, center: world.center, now: now)
        XCTAssertEqual(asWritten.map(\.title), ["A Way with Words", "Planet Money", "The Digital Antiquarian"])
        XCTAssertEqual(asWritten.map(\.rowTitle), asWritten.map(\.title))
        XCTAssertEqual(LibraryFeedsSectionRows.rows(at: top, center: world.center, now: now, articles: .ignoredWhenTyping), asWritten)

        let inverted = LibraryFeedsSectionRows.rows(at: top, center: world.center, now: now, articles: .ignoredWhenTypingAndSorting)
        XCTAssertEqual(inverted.map(\.title), ["The Digital Antiquarian", "Planet Money", "A Way with Words"])
        XCTAssertEqual(inverted.map(\.rowTitle), ["Digital Antiquarian, The", "Planet Money", "Way with Words, A"])
        let label = inverted.first?.label ?? ""
        XCTAssertTrue(label.hasPrefix("Digital Antiquarian, The, Feed, "), label)

        // The Folders rotor's entry for each feed's folder names the feed as
        // its row in the Feeds section shows it.
        let base = LibraryLocation(category: .folders, folderPath: world.folder.path)
        let folders = LibraryFeedFolders(center: world.center)
        func rotorLabels(_ articles: LeadingArticles) -> [String] {
            folders.folderRows(world.library.subfoldersOf(world.folder.path), at: base, articles: articles) { _ in 0 }
                .rotorEntries.map(\.label).sorted()
        }
        let shownEntries = rotorLabels(.ignoredWhenTypingAndSorting)
        XCTAssertTrue(shownEntries.contains { $0.hasPrefix("Digital Antiquarian, The, Feed") }, "\(shownEntries)")
        XCTAssertTrue(shownEntries.contains { $0.hasPrefix("Way with Words, A, Feed") }, "\(shownEntries)")
        let writtenEntries = rotorLabels(.partOfTitle)
        XCTAssertTrue(writtenEntries.contains { $0.hasPrefix("The Digital Antiquarian, Feed") }, "\(writtenEntries)")
    }

    // MARK: - A Feed's Item

    /// An item not yet downloaded shows and speaks its title as the book
    /// rows beside it do, keeps its own title for its commands, and is found
    /// by a search for its title as shown only while it is shown so.
    func testAFeedItemsRowShowsItsTitleAsTheSettingShowsIt() async throws {
        let world = try FeedTestWorld(self, label: "LeadingArticlesItems")
        let feed = try await subscribe(world, title: "Harbour Notes", path: "/notes.xml", items: [
            FeedXML.Item(guid: "ep-1", title: "The One About Tides"),
        ])
        let item = try XCTUnwrap(world.center.listedItems(of: feed.id).first)

        let shown = FeedItemRowContent(item, of: feed, in: world.center, wordsPerMinute: 200, articles: .ignoredWhenTypingAndSorting)
        XCTAssertEqual(shown.title, "The One About Tides")
        XCTAssertEqual(shown.rowTitle, "One About Tides, The")
        XCTAssertTrue(shown.label.hasPrefix("One About Tides, The, "), shown.label)
        let written = FeedItemRowContent(item, of: feed, in: world.center, wordsPerMinute: 200)
        XCTAssertEqual(written.rowTitle, "The One About Tides")
        XCTAssertTrue(written.label.hasPrefix("The One About Tides, "), written.label)

        func found(_ search: String, _ articles: LeadingArticles) -> Int {
            FeedFolderListing.make(
                feedID: feed.id, center: world.center, shownBooks: [], folderBooks: [],
                search: search, wordsPerMinute: 200, articles: articles
            ).entries.count
        }
        XCTAssertEqual(found("one about tides, the", .ignoredWhenTypingAndSorting), 1)
        XCTAssertEqual(found("one about tides, the", .partOfTitle), 0)
        XCTAssertEqual(found("the one", .ignoredWhenTypingAndSorting), 1)
    }

    // MARK: - Fixtures

    /// A book titled `title` at a path that exists nowhere.
    private static func book(_ title: String, author: String = "Author", language: String? = nil) -> Book {
        var book = Book(title: title, author: author, format: .epub, filePath: "/nonexistent/\(UUID().uuidString).epub", md5Hash: UUID().uuidString)
        book.epubLanguage = language
        return book
    }

    /// Subscribes `world`'s engine to a feed titled `title`, served at
    /// `path` with `items`, each an episode, in a new folder in the world's
    /// folder.
    private func subscribe(
        _ world: FeedTestWorld,
        title: String,
        path: String,
        items: [FeedXML.Item] = [FeedXML.Item(guid: "ep-1", title: "An episode")]
    ) async throws -> Feed {
        let episodes = items.map { item -> FeedXML.Item in
            var episode = item
            if episode.enclosure == nil {
                episode.enclosure = "https://articles.example/audio/\(item.guid ?? UUID().uuidString).mp3"
            }
            return episode
        }
        world.server.serve(path, .feed(FeedXML.rss(title: title, items: episodes)))
        if !world.center.hasStarted {
            await world.start()
        }
        let outcome = try await world.center.subscribe(to: world.server.url(path).absoluteString, into: .newFolder(inParentPath: world.folder.path))
        guard case .subscribed(let feed) = outcome else {
            throw NSError(domain: "LeadingArticlesDisplayTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(outcome)"])
        }
        return feed
    }
}
