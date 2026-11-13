import XCTest
@testable import TextMouth

/// Sorting under the Leading articles setting (TITLE-ARTICLES-RESEARCH-
/// 2026-11-13.md): titles as written order exactly as main ordered them, in
/// the first and second choices alike; the third sorts every title, and
/// every tie broken by title, without its leading article; and the Library's
/// lists follow the setting from the preferences store.
@MainActor
final class LeadingArticlesSortTests: XCTestCase {

    // MARK: - As Written, as Main Ordered

    /// Every field, both ways, with titles as written, orders exactly as
    /// main's comparator did before the setting (copied below as
    /// `mainOrder`), whether the setting is named or left to its default;
    /// and the second choice, which only changes where typing goes, keeps
    /// that order too.
    func testWrittenTitlesOrderExactlyAsMainOrdered() {
        let books = Self.mixedBooks
        let sizes = Dictionary(uniqueKeysWithValues: books.enumerated().map { ($0.element.id, ($0.offset * 37) % 5) })
        var mismatches: [String] = []
        for field in LibrarySortField.allCases {
            for ascending in [true, false] {
                let expected = Self.mainOrder(books, by: field, ascending: ascending, fileSizes: sizes).map(\.title)
                let orders: [(String, [Book])] = [
                    ("default", LibraryBookSorter.sorted(books, by: field, ascending: ascending, fileSizes: sizes)),
                    ("part of the title", LibraryBookSorter.sorted(books, by: field, ascending: ascending, fileSizes: sizes, articles: .partOfTitle)),
                    ("ignored when typing", LibraryBookSorter.sorted(books, by: field, ascending: ascending, fileSizes: sizes, articles: .ignoredWhenTyping)),
                ]
                for (name, order) in orders where order.map(\.title) != expected {
                    mismatches.append("\(field) \(ascending ? "ascending" : "descending") (\(name)): \(order.map(\.title)), not \(expected)")
                }
            }
        }
        XCTAssertEqual(mismatches, [])
    }

    // MARK: - Without Articles

    /// The third choice sorts by the title from where it files: The Hobbit
    /// among the H's, a title and the same title with an article side by
    /// side, the shorter first, letter case aside, and descending the
    /// reverse.
    func testTheTitleSortPassesOverArticles() {
        let books = ["Zebra Crossing", "The Hobbit", "Hobbit", "A Tale of Two Cities", "Apple Pie", "the hobbit", "An Ocean", "The 39 Steps", "Treasure Island"]
            .map { Self.book($0) }
        let ascending = LibraryBookSorter.sorted(books, by: .title, ascending: true, articles: .ignoredWhenTypingAndSorting).map(\.title)
        // "The Hobbit" and "the hobbit" tie on every title comparison; their
        // IDs decide, so only their place as a pair is checked.
        XCTAssertEqual(
            ascending.map { $0.lowercased() },
            ["the 39 steps", "apple pie", "hobbit", "the hobbit", "the hobbit", "an ocean", "a tale of two cities", "treasure island", "zebra crossing"]
        )
        let descending = LibraryBookSorter.sorted(books, by: .title, ascending: false, articles: .ignoredWhenTypingAndSorting).map(\.title)
        XCTAssertEqual(descending.map { $0.lowercased() }, ascending.reversed().map { $0.lowercased() })
    }

    /// Every sort that breaks ties by title reads the key: books alike in
    /// the field sorted by fall by their titles without their articles in
    /// the third choice, and as written in the first, whichever way the
    /// field runs.
    func testEveryTieBrokenByTitleReadsTheKey() {
        let titles = ["The Zebra", "Apple", "A Mango", "mango"]
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let books = titles.map { title in
            Self.book(title, author: "Same Author", dateAdded: day, lastOpened: day, manualSortOrder: 3)
        }
        let sizes = Dictionary(uniqueKeysWithValues: books.map { ($0.id, 100) })
        var mismatches: [String] = []
        for field in LibrarySortField.allCases where field != .title {
            for ascending in [true, false] {
                let withoutArticles = LibraryBookSorter.sorted(books, by: field, ascending: ascending, fileSizes: sizes, articles: .ignoredWhenTypingAndSorting)
                if withoutArticles.map(\.title) != ["Apple", "A Mango", "mango", "The Zebra"] {
                    mismatches.append("\(field) \(ascending) without articles: \(withoutArticles.map(\.title))")
                }
                let asWritten = LibraryBookSorter.sorted(books, by: field, ascending: ascending, fileSizes: sizes, articles: .partOfTitle)
                if asWritten.map(\.title) != ["A Mango", "Apple", "mango", "The Zebra"] {
                    mismatches.append("\(field) \(ascending) as written: \(asWritten.map(\.title))")
                }
            }
        }
        XCTAssertEqual(mismatches, [])
    }

    /// Recently Opened's order breaks ties by the key too: rows never
    /// opened, added at one time, fall by their titles without articles.
    func testTheOpenedLastOrderBreaksTiesByTheKey() {
        let added = Date(timeIntervalSince1970: 1_800_000_000)
        let books = ["The Zebra", "Apple", "A Mango"].map { Self.book($0, dateAdded: added) }
        XCTAssertEqual(
            LibraryBookSorter.latestOpened(books, limit: nil, onePerFeed: false, articles: .ignoredWhenTypingAndSorting).map(\.title),
            ["Apple", "A Mango", "The Zebra"]
        )
        XCTAssertEqual(
            LibraryBookSorter.latestOpened(books, limit: nil, onePerFeed: false).map(\.title),
            ["A Mango", "Apple", "The Zebra"]
        )
    }

    /// A folder's manual order breaks ties among books not yet placed by
    /// the key, and moving a book, and whether it can move, follow that one
    /// order, as the list shows it.
    func testTheManualOrderBreaksTiesByTheKeyAndMovesFollowIt() {
        let folder = "Shelf"
        let books = ["The Zebra", "Apple", "A Mango"].map { Self.book($0, folderPath: folder) }
        var library = Library(books: books, folders: [BookFolder(name: folder)])
        let articles = LeadingArticles.ignoredWhenTypingAndSorting
        XCTAssertEqual(ManualBookOrder.orderedBooks(in: library, folderPath: folder, articles: articles).map(\.title), ["Apple", "A Mango", "The Zebra"])
        XCTAssertEqual(ManualBookOrder.orderedBooks(in: library, folderPath: folder).map(\.title), ["A Mango", "Apple", "The Zebra"])
        let mango = books[2].id
        XCTAssertTrue(ManualBookOrder.canMove(in: library, bookID: mango, direction: 1, folderPath: folder, articles: articles))
        XCTAssertFalse(ManualBookOrder.canMove(in: library, bookID: mango, direction: -1, folderPath: folder))
        let moved = ManualBookOrder.move(library: &library, bookID: mango, direction: -1, folderPath: folder, articles: articles)
        XCTAssertEqual(moved?.announcement, "Moved A Mango above Apple")
        XCTAssertEqual(ManualBookOrder.orderedBooks(in: library, folderPath: folder, articles: articles).map(\.title), ["A Mango", "Apple", "The Zebra"])
    }

    /// A book's metadata language decides whose articles its title sorts
    /// without: "Die Hard" in an English book among the D's, "Die
    /// Verwandlung" in a German one among the V's.
    func testABooksLanguageDecidesWhoseArticlesItsTitleSortsWithout() {
        let books = [
            Self.book("Ulysses"),
            Self.book("Die Verwandlung", language: "de"),
            Self.book("Die Hard", language: "en"),
            Self.book("Dune"),
            Self.book("Le Petit Prince", language: "fr"),
            Self.book("Le Morte d'Arthur"),
        ]
        XCTAssertEqual(
            LibraryBookSorter.sorted(books, by: .title, ascending: true, articles: .ignoredWhenTypingAndSorting).map(\.title),
            ["Die Hard", "Dune", "Le Morte d'Arthur", "Le Petit Prince", "Ulysses", "Die Verwandlung"]
        )
    }

    // MARK: - The Library's Lists

    /// A Library window's list follows the setting in the preferences store:
    /// as written, then without articles, the list derived again for the
    /// change; the second choice keeps the first's order; a search finds a
    /// book by its title as its row shows it only while the rows show it so;
    /// and a book's language changing derives the list again.
    func testTheLibrarysListsFollowTheSetting() throws {
        let store = TextMouthRuntime.current.preferences
        preservePreferences([LeadingArticles.preference.key], in: store)
        let folder = "Shelf"
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(
            books: ["The Hobbit", "Ivanhoe", "A Tale of Two Cities", "Gulliver's Travels", "Die Verwandlung"].map { Self.book($0, folderPath: folder) },
            folders: [BookFolder(name: folder)]
        )
        let location = LibraryLocation(category: .folders, folderPath: folder)
        model.library.folderSortSettings[location.sortSettingsKey] = FolderSortSetting(sortField: .title, sortAscending: true)
        func listed(_ search: String = "") -> [String] {
            model.displayedBooks(at: location, matching: search).map(\.title)
        }

        LeadingArticles.preference.write(.partOfTitle, to: store)
        let asWritten = ["A Tale of Two Cities", "Die Verwandlung", "Gulliver's Travels", "Ivanhoe", "The Hobbit"]
        XCTAssertEqual(model.leadingArticles, .partOfTitle)
        XCTAssertEqual(listed(), asWritten)
        XCTAssertEqual(listed("hobbit, the"), [])

        LeadingArticles.preference.write(.ignoredWhenTyping, to: store)
        XCTAssertEqual(listed(), asWritten, "the second choice changes only where typing goes")

        LeadingArticles.preference.write(.ignoredWhenTypingAndSorting, to: store)
        let before = model.listCache.derivationCount
        XCTAssertEqual(listed(), ["Die Verwandlung", "Gulliver's Travels", "The Hobbit", "Ivanhoe", "A Tale of Two Cities"])
        XCTAssertGreaterThan(model.listCache.derivationCount, before, "the list was not derived again for the setting")
        // The search finds the title as written and as its row shows it.
        XCTAssertEqual(listed("hobbit, the"), ["The Hobbit"])
        XCTAssertEqual(listed("the hob"), ["The Hobbit"])

        // The German book's language, once known, files it among the V's.
        let german = try XCTUnwrap(model.library.books.firstIndex { $0.title == "Die Verwandlung" })
        model.library.books[german].epubLanguage = "de"
        XCTAssertEqual(listed(), ["Gulliver's Travels", "The Hobbit", "Ivanhoe", "A Tale of Two Cities", "Die Verwandlung"])
    }

    /// The Reading List keeps the order the user arranged in every choice,
    /// since it is never sorted, while its rows show titles as every other
    /// list's do: inverted in the third choice.
    func testTheReadingListKeepsItsOrderInEveryChoice() {
        let store = TextMouthRuntime.current.preferences
        preservePreferences([LeadingArticles.preference.key], in: store)
        let books = ["The Hobbit", "Ivanhoe", "A Tale of Two Cities"].map { Self.book($0) }
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: books, folders: [])
        model.library.readingList = ReadingList(bookIDs: [books[2].id, books[0].id, books[1].id])
        let readingList = LibraryLocation(category: .readingList, folderPath: "")
        let arranged = ["A Tale of Two Cities", "The Hobbit", "Ivanhoe"]

        for choice in LeadingArticles.allCases {
            LeadingArticles.preference.write(choice, to: store)
            XCTAssertEqual(model.displayedBooks(at: readingList, matching: "").map(\.title), arranged, "\(choice)")
        }
        LeadingArticles.preference.write(.ignoredWhenTypingAndSorting, to: store)
        let shown = model.displayedBooks(at: readingList, matching: "").map { book in
            model.rowTitle(of: book, articles: model.leadingArticles) ?? book.title
        }
        XCTAssertEqual(shown, ["Tale of Two Cities, A", "Hobbit, The", "Ivanhoe"])
    }

    // MARK: - Fixtures

    /// A book titled `title`, with the given fields, at a path that exists
    /// nowhere.
    private static func book(
        _ title: String,
        author: String = "Author",
        language: String? = nil,
        folderPath: String = "",
        dateAdded: Date = Date(timeIntervalSince1970: 1_700_000_000),
        lastOpened: Date? = nil,
        manualSortOrder: Int? = nil
    ) -> Book {
        var book = Book(
            title: title,
            author: author,
            format: .epub,
            filePath: "/nonexistent/leading-articles/\(UUID().uuidString).epub",
            md5Hash: UUID().uuidString,
            folderPath: folderPath,
            dateAdded: dateAdded,
            lastOpened: lastOpened,
            manualSortOrder: manualSortOrder
        )
        book.epubLanguage = language
        return book
    }

    /// Books whose every field ties somewhere and differs somewhere: titles
    /// with and without articles, in several cases, twice over; authors,
    /// dates, and manual places shared and missing; languages known and not.
    private static let mixedBooks: [Book] = {
        let titles = [
            "The Hobbit", "Hobbit", "the hobbit", "A Tale of Two Cities", "Apple Pie", "An Ocean", "Zebra",
            "The 39 Steps", "\"The Raven\"", "Die Hard", "Die Verwandlung", "L'Étranger", "Le Petit Prince",
            "A Is for Alibi", "The", "Thebes",
        ]
        let languages: [String?] = [nil, "en", "de", "fr"]
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        return titles.enumerated().map { index, title in
            book(
                title,
                author: ["Ann", "bob", "Ann", "Cy"][index % 4],
                language: languages[index % languages.count],
                dateAdded: base.addingTimeInterval(Double(index % 3) * 60),
                lastOpened: index % 5 == 0 ? nil : base.addingTimeInterval(Double(index % 2) * 3_600),
                manualSortOrder: index % 4 == 0 ? nil : index % 3
            )
        }
    }()

    /// The order main's comparator gave before the Leading articles setting
    /// (LibraryBookSorter at c6f394da), copied here so the order of titles
    /// as written is pinned against it: the field in its direction, then the
    /// title as written, ignoring case, ascending, then the ID string.
    private static func mainOrder(_ books: [Book], by field: LibrarySortField, ascending: Bool, fileSizes: [UUID: Int]) -> [Book] {
        func compare<T: Comparable>(_ first: T, _ second: T) -> ComparisonResult {
            first < second ? .orderedAscending : first > second ? .orderedDescending : .orderedSame
        }
        return books.sorted { first, second in
            let primary: ComparisonResult
            switch field {
            case .title: primary = first.title.localizedCaseInsensitiveCompare(second.title)
            case .author: primary = first.author.localizedCaseInsensitiveCompare(second.author)
            case .dateAdded: primary = compare(first.dateAdded, second.dateAdded)
            case .lastOpened: primary = compare(first.lastOpened ?? .distantPast, second.lastOpened ?? .distantPast)
            case .fileSize: primary = compare(fileSizes[first.id] ?? 0, fileSizes[second.id] ?? 0)
            case .manual: primary = compare(first.manualSortOrder ?? Int.max, second.manualSortOrder ?? Int.max)
            }
            if primary != .orderedSame {
                return ascending ? primary == .orderedAscending : primary == .orderedDescending
            }
            let title = first.title.localizedCaseInsensitiveCompare(second.title)
            if title != .orderedSame {
                return title == .orderedAscending
            }
            return first.id.uuidString < second.id.uuidString
        }
    }
}
