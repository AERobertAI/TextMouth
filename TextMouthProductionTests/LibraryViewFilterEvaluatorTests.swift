import XCTest
@testable import TextMouth

/// The pure evaluator of a Library view's filter (the design of October 30,
/// 2026, LIBRARY-VIEWS-RESEARCH-2026-10-30.md, sections 3 and 4): the shipped
/// views giving exactly the lists their categories always gave; what each
/// condition lists of books, episodes, articles, and feeds, negated or not,
/// under All and Any; folders by path; days by the calendar; only the latest
/// from each feed, and each limit; what the context gathers; the sorter's
/// choice of the rows opened last, which Recently Opened and the evaluator
/// share; and the kind of each row.
final class LibraryViewFilterEvaluatorTests: XCTestCase {

    // MARK: - The Shipped Views

    /// Each shipped view lists exactly what its category always listed, in
    /// the same order: All Items the library's own books, Unopened those
    /// never opened, and Recently Opened the rows `LibraryBookSorter.recent`
    /// chooses, here and in a library with more opened rows than it lists,
    /// many of them opened at the same instant. The Feeds view lists no
    /// book. All Items and Feeds list every feed, Unopened those with a new
    /// episode or article, and Recently Opened none. None of them sorts.
    func testTheShippedViewsListWhatTheirCategoriesAlwaysListed() throws {
        let fixture = try Fixture()
        let shipped = try ShippedFilters()
        let crowded = Library(books: fixture.rows + fixture.crowdedRows(), folders: fixture.folders)
        XCTAssertEqual(LibraryBookSorter.recent(fixture.library.books).count, 7)
        XCTAssertEqual(LibraryBookSorter.recent(crowded.books).count, LibraryBookSorter.recentlyOpenedCount)

        for library in [fixture.library, crowded] {
            /// The titles of the rows `filter` lists of the library's rows,
            /// failing if it sorts them.
            func listed(_ filter: LibraryViewFilter) -> [String] {
                fixture.listedItems(filter, in: library.books) { rows in
                    XCTFail("A shipped view sorted its rows")
                    return rows
                }.map(\.title)
            }
            XCTAssertEqual(listed(shipped.allItems), library.libraryBooks.map(\.title))
            XCTAssertEqual(listed(shipped.unopened), library.unopenedBooks().map(\.title))
            XCTAssertEqual(listed(shipped.recent), LibraryBookSorter.recent(library.books).map(\.title))
            XCTAssertEqual(listed(shipped.feeds), [])
        }

        let everyFeed = ["Harbour Radio", "The Weekly Ledger", "Static Hour"]
        XCTAssertEqual(fixture.listedFeeds(shipped.allItems).map(\.title), everyFeed)
        XCTAssertEqual(fixture.listedFeeds(shipped.feeds).map(\.title), everyFeed)
        XCTAssertEqual(fixture.listedFeeds(shipped.unopened).map(\.title), ["Harbour Radio", "The Weekly Ledger"])
        XCTAssertEqual(fixture.listedFeeds(shipped.recent).map(\.title), [])
    }

    // MARK: - Each Condition

    /// Every test on every kind of row it tests, passing and failing, and
    /// negated, which lists exactly the rows of those kinds it hid; the rows
    /// of a kind it does not test are listed both ways.
    func testEachConditionOnEachKindOfRowItTests() throws {
        let fixture = try Fixture()
        let episodes: Set<String> = ["Tide Tables, Part One", "Tide Tables, Part Two", "Tide Tables, Part Three", "Static Hour 12"]

        // The format: every episode is audio, as is the library's own
        // audiobook; articles come in any other format.
        assertListed(.format(.audio), items: episodes.union(["Ferry Songs"]), feeds: nil, in: fixture)
        assertListed(.format(.pdf), items: ["Salt and Empire", "Ledger: Canal Fees"], feeds: nil, in: fixture)
        assertListed(.format(.html), items: ["Street Signs", "Ledger: On Ferries", "Ledger: Salt Prices"], feeds: nil, in: fixture)
        assertListed(.format(.epub), items: ["Canal Engineering"], feeds: nil, in: fixture)

        // The reading state: never opened; opened and not finished; finished
        // as Books Finished counts it, opened or not.
        assertListed(
            .readingState(.unopened),
            items: ["Canal Engineering", "Ferry Songs", "Tide Tables, Part Three", "Ledger: Salt Prices"],
            feeds: nil,
            in: fixture
        )
        assertListed(
            .readingState(.inProgress),
            items: ["The Night Ferry", "Salt and Empire", "Street Signs", "Tide Tables, Part Two", "Static Hour 12", "Ledger: Canal Fees"],
            feeds: nil,
            in: fixture
        )
        assertListed(
            .readingState(.finished),
            items: ["Pocket Stories", "Tide Tables, Part One", "Ledger: On Ferries"],
            feeds: nil,
            in: fixture
        )

        // The reading list.
        assertListed(.inReadingList, items: ["Salt and Empire", "Tide Tables, Part Two", "Ledger: Salt Prices"], feeds: nil, in: fixture)

        // Added and opened within the last days: today, or on one of the
        // days before; a row never opened was opened within none.
        assertListed(
            .addedWithin(days: 2),
            items: ["The Night Ferry", "Salt and Empire", "Tide Tables, Part Two", "Tide Tables, Part Three", "Ledger: Salt Prices"],
            feeds: nil,
            in: fixture
        )
        assertListed(.addedWithin(days: 1), items: ["Salt and Empire", "Tide Tables, Part Three"], feeds: nil, in: fixture)
        assertListed(
            .openedWithin(days: 2),
            items: ["The Night Ferry", "Tide Tables, Part Two", "Ledger: Canal Fees"],
            feeds: nil,
            in: fixture
        )
        assertListed(.openedWithin(days: 1), items: ["The Night Ferry", "Tide Tables, Part Two"], feeds: nil, in: fixture)
        assertListed(.openedWithin(days: 3_650), items: fixture.openedTitles, feeds: nil, in: fixture)

        // The title or author, ignoring case, of every kind of row, a feed's
        // own included: a feed without an author has none, not "Unknown".
        assertListed(
            .titleOrAuthorContains("FERR"),
            items: ["The Night Ferry", "Ferry Songs", "Ledger: On Ferries"],
            feeds: [],
            in: fixture
        )
        assertListed(
            .titleOrAuthorContains("varga"),
            items: ["Canal Engineering", "Ferry Songs", "Static Hour 12"],
            feeds: ["Static Hour"],
            in: fixture
        )
        assertListed(
            .titleOrAuthorContains("Ledger"),
            items: ["Ledger: On Ferries", "Ledger: Salt Prices", "Ledger: Canal Fees"],
            feeds: ["The Weekly Ledger"],
            in: fixture
        )
        assertListed(
            .titleOrAuthorContains("unknown"),
            items: ["Tide Tables, Part One", "Tide Tables, Part Two", "Tide Tables, Part Three", "Ledger: On Ferries", "Ledger: Salt Prices", "Ledger: Canal Fees"],
            feeds: [],
            in: fixture
        )
        // An empty text is in every one, as an empty search narrows nothing.
        assertListed(.titleOrAuthorContains(""), items: fixture.itemTitles, feeds: fixture.feedTitles, in: fixture)

        // A feed's new items and its subscription.
        assertListed(.hasNewItems, items: nil, feeds: ["Harbour Radio", "The Weekly Ledger"], in: fixture)
        assertListed(.subscribed, items: nil, feeds: ["Harbour Radio", "Static Hour"], in: fixture)
    }

    /// The tests that read the context fail on every row when it holds
    /// nothing for them, so, negated, they hold on every row: no finished
    /// rows (In Progress is then every row opened), no reading list, no
    /// threshold for the days.
    func testATestWhoseContextIsMissingFails() throws {
        let fixture = try Fixture()
        let empty = LibraryViewFilterContext()
        assertListed(.readingState(.finished), items: [], feeds: nil, in: fixture, context: empty)
        assertListed(.readingState(.inProgress), items: fixture.openedTitles, feeds: nil, in: fixture, context: empty)
        assertListed(.inReadingList, items: [], feeds: nil, in: fixture, context: empty)
        assertListed(.addedWithin(days: 2), items: [], feeds: nil, in: fixture, context: empty)
        assertListed(.openedWithin(days: 2), items: [], feeds: nil, in: fixture, context: empty)
    }

    /// A condition never hides a row it does not test, under All and Any,
    /// negated or not: a feed's tests leave every book listed, and a book's
    /// tests every feed.
    func testAConditionNeverHidesARowItDoesNotTest() throws {
        let fixture = try Fixture()
        for match in LibraryViewMatch.allCases {
            for isNegated in [false, true] {
                let aboutFeeds = LibraryViewFilter(
                    lists: [.books, .episodes, .articles],
                    match: match,
                    conditions: [
                        LibraryViewCondition(test: .hasNewItems, isNegated: isNegated),
                        LibraryViewCondition(test: .subscribed, isNegated: isNegated),
                    ]
                )
                XCTAssertEqual(fixture.listedItemTitles(aboutFeeds), fixture.itemTitles, "\(match), negated: \(isNegated)")
                let aboutBooks = LibraryViewFilter(
                    lists: [.feeds],
                    match: match,
                    conditions: [
                        LibraryViewCondition(test: .format(.epub), isNegated: isNegated),
                        LibraryViewCondition(test: .readingState(.finished), isNegated: isNegated),
                        LibraryViewCondition(test: .inReadingList, isNegated: isNegated),
                    ]
                )
                XCTAssertEqual(fixture.listedFeedTitles(aboutBooks), fixture.feedTitles, "\(match), negated: \(isNegated)")
            }
        }
    }

    /// All Conditions lists a row when every condition that tests it holds,
    /// and Any Condition when one does; a row is judged by the conditions
    /// that test its kind alone, and with none, under either, it is listed.
    func testAllConditionsOrAnyCondition() throws {
        let fixture = try Fixture()
        let unopened = LibraryViewCondition(test: .readingState(.unopened))
        let audio = LibraryViewCondition(test: .format(.audio))
        var filter = LibraryViewFilter(lists: Set(LibraryViewItemKind.allCases), match: .all, conditions: [unopened, audio])
        XCTAssertEqual(fixture.listedItemTitles(filter), ["Ferry Songs", "Tide Tables, Part Three"])
        XCTAssertEqual(fixture.listedFeedTitles(filter), fixture.feedTitles)
        filter.match = .any
        XCTAssertEqual(
            fixture.listedItemTitles(filter),
            ["Canal Engineering", "Ferry Songs", "Tide Tables, Part One", "Tide Tables, Part Two", "Tide Tables, Part Three", "Static Hour 12", "Ledger: Salt Prices"]
        )
        XCTAssertEqual(fixture.listedFeedTitles(filter), fixture.feedTitles)

        // Unopened's own two conditions: under either match, a book needs
        // the first and a feed the second, since each tests one kind alone.
        let unopenedItems: Set<String> = ["Canal Engineering", "Ferry Songs", "Tide Tables, Part Three", "Ledger: Salt Prices"]
        for match in LibraryViewMatch.allCases {
            filter = LibraryViewFilter(lists: Set(LibraryViewItemKind.allCases), match: match, conditions: [LibraryViewCondition(test: .hasNewItems), unopened])
            XCTAssertEqual(fixture.listedItemTitles(filter), unopenedItems, "\(match)")
            XCTAssertEqual(fixture.listedFeedTitles(filter), ["Harbour Radio", "The Weekly Ledger"], "\(match)")
        }

        // A negated condition among others: opened, and in the reading list;
        // opened, or in the reading list.
        let opened = LibraryViewCondition(test: .readingState(.unopened), isNegated: true)
        let inReadingList = LibraryViewCondition(test: .inReadingList)
        filter = LibraryViewFilter(lists: [.books, .episodes, .articles], match: .all, conditions: [opened, inReadingList])
        XCTAssertEqual(fixture.listedItemTitles(filter), ["Salt and Empire", "Tide Tables, Part Two"])
        filter.match = .any
        XCTAssertEqual(fixture.listedItemTitles(filter), fixture.openedTitles.union(["Ledger: Salt Prices"]))

        // No conditions: every row of the kinds listed.
        for match in LibraryViewMatch.allCases {
            filter = LibraryViewFilter(lists: Set(LibraryViewItemKind.allCases), match: match)
            XCTAssertEqual(fixture.listedItemTitles(filter), fixture.itemTitles, "\(match)")
            XCTAssertEqual(fixture.listedFeedTitles(filter), fixture.feedTitles, "\(match)")
        }
    }

    /// A filter lists the kinds of rows it names and no other: the library's
    /// own audiobook is a book, not an episode, and a filter of feeds alone
    /// lists no book, episode, or article, and one without feeds no feed.
    func testAFilterListsTheKindsItNames() throws {
        let fixture = try Fixture()
        let books: Set<String> = ["Canal Engineering", "The Night Ferry", "Pocket Stories", "Salt and Empire", "Ferry Songs", "Street Signs"]
        let episodes: Set<String> = ["Tide Tables, Part One", "Tide Tables, Part Two", "Tide Tables, Part Three", "Static Hour 12"]
        let articles: Set<String> = ["Ledger: On Ferries", "Ledger: Salt Prices", "Ledger: Canal Fees"]
        XCTAssertEqual(books.union(episodes).union(articles), fixture.itemTitles)

        XCTAssertEqual(fixture.listedItemTitles(LibraryViewFilter(lists: [.books])), books)
        XCTAssertEqual(fixture.listedItemTitles(LibraryViewFilter(lists: [.episodes])), episodes)
        XCTAssertEqual(fixture.listedItemTitles(LibraryViewFilter(lists: [.articles])), articles)
        XCTAssertEqual(fixture.listedItemTitles(LibraryViewFilter(lists: [.books, .articles])), books.union(articles))
        XCTAssertEqual(fixture.listedItemTitles(LibraryViewFilter(lists: [.feeds])), [])
        XCTAssertEqual(fixture.listedFeedTitles(LibraryViewFilter(lists: [.feeds])), fixture.feedTitles)
        XCTAssertEqual(fixture.listedFeedTitles(LibraryViewFilter(lists: [.books, .episodes, .articles])), [])
    }

    // MARK: - Folders

    /// Folder conditions, by each row's folder: a book's own, and an
    /// episode's or article's feed's, never the folder its row names; Library
    /// Root, with and without the folders inside it; a folder, with and
    /// without them, by whole path components ("Fictional" is not inside
    /// "Fiction"); and a folder no longer in the library, which matches
    /// nothing, as a feed whose folder is gone matches no folder, not even
    /// Library Root with every folder inside it.
    func testFolderConditions() throws {
        let fixture = try Fixture()
        let books: Set<String> = ["Canal Engineering", "The Night Ferry", "Pocket Stories", "Salt and Empire", "Ferry Songs", "Street Signs"]
        let harbourEpisodes: Set<String> = ["Tide Tables, Part One", "Tide Tables, Part Two", "Tide Tables, Part Three"]
        let ledgerArticles: Set<String> = ["Ledger: On Ferries", "Ledger: Salt Prices", "Ledger: Canal Fees"]

        assertListed(.folder(id: nil, includingSubfolders: false), items: ["Canal Engineering"], feeds: [], in: fixture)
        assertListed(
            .folder(id: nil, includingSubfolders: true),
            items: books.union(harbourEpisodes).union(ledgerArticles),
            feeds: ["Harbour Radio", "The Weekly Ledger"],
            in: fixture
        )
        assertListed(.folder(id: fixture.fiction.id, includingSubfolders: false), items: ["The Night Ferry", "Ferry Songs"], feeds: [], in: fixture)
        assertListed(
            .folder(id: fixture.fiction.id, includingSubfolders: true),
            items: ["The Night Ferry", "Pocket Stories", "Ferry Songs"],
            feeds: [],
            in: fixture
        )
        assertListed(.folder(id: fixture.short.id, includingSubfolders: true), items: ["Pocket Stories"], feeds: [], in: fixture)
        assertListed(.folder(id: fixture.fictional.id, includingSubfolders: false), items: ["Street Signs"], feeds: [], in: fixture)
        assertListed(
            .folder(id: fixture.essays.id, includingSubfolders: false),
            items: ledgerArticles.union(["Salt and Empire"]),
            feeds: ["The Weekly Ledger"],
            in: fixture
        )
        assertListed(.folder(id: fixture.podcasts.id, includingSubfolders: false), items: [], feeds: [], in: fixture)
        assertListed(.folder(id: fixture.podcasts.id, includingSubfolders: true), items: harbourEpisodes, feeds: ["Harbour Radio"], in: fixture)
        assertListed(.folder(id: fixture.harbourFolder.id, includingSubfolders: false), items: harbourEpisodes, feeds: ["Harbour Radio"], in: fixture)
        for includingSubfolders in [false, true] {
            assertListed(.folder(id: fixture.goneFolderID, includingSubfolders: includingSubfolders), items: [], feeds: [], in: fixture)
            assertListed(.folder(id: UUID(), includingSubfolders: includingSubfolders), items: [], feeds: [], in: fixture)
        }

        // Without the feeds' folders, an episode's or article's is unknown:
        // no folder condition finds it; a book's and a feed's are known still.
        assertListed(
            .folder(id: nil, includingSubfolders: true),
            items: books,
            feeds: ["Harbour Radio", "The Weekly Ledger"],
            in: fixture,
            context: LibraryViewFilterContext()
        )
    }

    // MARK: - Days

    /// A day counts by the calendar: "within the last N days" begins at the
    /// start of the day N − 1 days before today, so a row added or opened at
    /// 23:59 yesterday is within 2 days and not within 1, and one at
    /// midnight today within both. A day count outside the range a condition
    /// can hold has no threshold: its test fails, and nothing overflows.
    func testDaysAreCountedByTheCalendarAcrossMidnight() throws {
        let fixture = try Fixture()
        let thresholds = fixture.context(for: LibraryViewFilter(
            lists: [.books],
            conditions: [
                LibraryViewCondition(test: .addedWithin(days: 1)),
                LibraryViewCondition(test: .openedWithin(days: 2)),
                LibraryViewCondition(test: .addedWithin(days: 3_650)),
            ]
        )).dayThresholds
        XCTAssertEqual(thresholds, [
            1: Fixture.startOfToday,
            2: Fixture.startOfToday.addingTimeInterval(-Fixture.day),
            3_650: Fixture.startOfToday.addingTimeInterval(-3_649 * Fixture.day),
        ])

        let lateYesterday = Fixture.startOfToday.addingTimeInterval(-60)
        let rows = [
            Fixture.row("At 23:59 Yesterday", .txt, added: lateYesterday, opened: lateYesterday),
            Fixture.row("At Midnight Today", .txt, added: Fixture.startOfToday, opened: Fixture.startOfToday),
        ]
        let expected: [Int: Set<String>] = [1: ["At Midnight Today"], 2: ["At 23:59 Yesterday", "At Midnight Today"]]
        for (days, titles) in expected {
            for test in [LibraryViewCondition.Test.addedWithin(days: days), .openedWithin(days: days)] {
                let filter = LibraryViewFilter(lists: [.books], conditions: [LibraryViewCondition(test: test)])
                XCTAssertEqual(fixture.listedItemTitles(filter, in: rows), titles, "\(test)")
            }
        }

        for days in [0, -1, 3_651, Int.min, Int.max] {
            for test in [LibraryViewCondition.Test.addedWithin(days: days), .openedWithin(days: days)] {
                let filter = LibraryViewFilter(lists: [.books], conditions: [LibraryViewCondition(test: test)])
                XCTAssertEqual(fixture.context(for: filter).dayThresholds, [:], "\(test)")
                XCTAssertEqual(fixture.listedItemTitles(filter, in: rows), [], "\(test)")
                let negated = LibraryViewFilter(lists: [.books], conditions: [LibraryViewCondition(test: test, isNegated: true)])
                XCTAssertEqual(fixture.listedItemTitles(negated, in: rows).count, rows.count, "\(test)")
            }
        }
    }

    /// Days are the calendar's, not 24 hours each: where daylight saving
    /// time ends (New York, Sunday, November 1, 2026, a day of 25 hours),
    /// "within the last 2 days" on Monday begins at the start of Sunday, 25
    /// hours before Monday began, so a row added at 00:30 on Sunday is
    /// within it.
    func testDaysFollowTheCalendarWhereTheClockChanges() throws {
        let fixture = try Fixture()
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let mondayNoon = Date(timeIntervalSince1970: 1_793_638_800)
        let mondayStart = Date(timeIntervalSince1970: 1_793_595_600)
        let sundayStart = Date(timeIntervalSince1970: 1_793_505_600)
        XCTAssertEqual(mondayStart.timeIntervalSince(sundayStart), 25 * 3_600)

        let filter = LibraryViewFilter(lists: [.books], conditions: [LibraryViewCondition(test: .addedWithin(days: 2))])
        let context = fixture.context(for: filter, now: mondayNoon, calendar: newYork)
        XCTAssertEqual(context.dayThresholds, [2: sundayStart])
        let earlySunday = Fixture.row("Early Sunday", .txt, added: Date(timeIntervalSince1970: 1_793_507_400), opened: nil)
        let saturdayNight = Fixture.row("Saturday Night", .txt, added: sundayStart.addingTimeInterval(-1), opened: nil)
        XCTAssertEqual(fixture.listedItemTitles(filter, in: [earlySunday, saturdayNight], context: context), ["Early Sunday"])
    }

    // MARK: - After the Conditions

    /// Only the latest from each feed keeps, of each feed's episodes and
    /// articles, the one opened last, and every book.
    func testOnlyTheLatestFromEachFeed() throws {
        let fixture = try Fixture()
        let filter = LibraryViewFilter(lists: [.books, .episodes, .articles], onePerFeed: true)
        XCTAssertEqual(
            fixture.listedItemTitles(filter),
            fixture.bookTitles.union(["Tide Tables, Part Two", "Ledger: Canal Fees", "Static Hour 12"])
        )
        // After the conditions: of the episodes never opened, one.
        let unopenedEpisodes = LibraryViewFilter(
            lists: [.episodes],
            conditions: [LibraryViewCondition(test: .readingState(.unopened))],
            onePerFeed: true
        )
        XCTAssertEqual(fixture.listedItemTitles(unopenedEpisodes), ["Tide Tables, Part Three"])
    }

    /// A limit chosen by Opened Last keeps the rows opened last, the latest
    /// of each feed's first when the filter asks, a row never opened after
    /// every one opened; a limit larger than the rows keeps them all.
    func testALimitChosenByOpenedLast() throws {
        let fixture = try Fixture()
        /// The titles listed with a limit of `count` chosen by Opened Last.
        func listed(_ count: Int, onePerFeed: Bool) -> Set<String> {
            fixture.listedItemTitles(LibraryViewFilter(
                lists: [.books, .episodes, .articles],
                onePerFeed: onePerFeed,
                limit: LibraryViewLimit(count: count, chosenBy: .lastOpened)
            ))
        }
        XCTAssertEqual(listed(3, onePerFeed: false), ["Tide Tables, Part Two", "The Night Ferry", "Ledger: Canal Fees"])
        XCTAssertEqual(listed(3, onePerFeed: true), ["Tide Tables, Part Two", "The Night Ferry", "Ledger: Canal Fees"])
        XCTAssertEqual(
            listed(6, onePerFeed: false),
            ["Tide Tables, Part Two", "The Night Ferry", "Ledger: Canal Fees", "Pocket Stories", "Salt and Empire", "Tide Tables, Part One"]
        )
        XCTAssertEqual(
            listed(6, onePerFeed: true),
            ["Tide Tables, Part Two", "The Night Ferry", "Ledger: Canal Fees", "Pocket Stories", "Salt and Empire", "Static Hour 12"]
        )
        XCTAssertEqual(listed(9, onePerFeed: false), fixture.openedTitles)
        XCTAssertEqual(listed(10, onePerFeed: false).subtracting(fixture.openedTitles).count, 1)
        XCTAssertEqual(listed(100, onePerFeed: false), fixture.itemTitles)
        XCTAssertEqual(listed(LibraryViewLimit.countRange.upperBound, onePerFeed: true), fixture.bookTitles.union(["Tide Tables, Part Two", "Ledger: Canal Fees", "Static Hour 12"]))
    }

    /// A limit chosen by Added Last keeps the rows added last, after only
    /// the latest from each feed when the filter asks, with ties falling as
    /// a list sorted by Date Added breaks them (by title); a limit larger
    /// than the rows keeps them all, and sorts nothing.
    func testALimitChosenByAddedLast() throws {
        let fixture = try Fixture()
        /// The titles listed with a limit of `count` chosen by Added Last.
        func listed(_ count: Int, onePerFeed: Bool, in rows: [Book]? = nil) -> Set<String> {
            fixture.listedItemTitles(LibraryViewFilter(
                lists: [.books, .episodes, .articles],
                onePerFeed: onePerFeed,
                limit: LibraryViewLimit(count: count, chosenBy: .dateAdded)
            ), in: rows)
        }
        XCTAssertEqual(listed(3, onePerFeed: false), ["Tide Tables, Part Three", "Salt and Empire", "The Night Ferry"])
        XCTAssertEqual(listed(3, onePerFeed: true), ["Salt and Empire", "The Night Ferry", "Tide Tables, Part Two"])
        XCTAssertEqual(listed(100, onePerFeed: false), fixture.itemTitles)

        let added = Fixture.now.addingTimeInterval(-Fixture.day)
        let drafts = [
            Fixture.row("Second Draft", .txt, added: added, opened: nil),
            Fixture.row("First Draft", .txt, added: added, opened: nil),
        ]
        XCTAssertEqual(listed(1, onePerFeed: false, in: drafts), ["First Draft"])
        XCTAssertEqual(listed(1, onePerFeed: false, in: drafts.reversed()), ["First Draft"])
    }

    /// A limit chosen by the view's sort keeps the first rows in the order
    /// the given sort puts them in, after only the latest from each feed
    /// when the filter asks, and sorts once; a limit larger than the rows
    /// keeps them all and sorts nothing.
    func testALimitChosenByTheViewsSort() throws {
        let fixture = try Fixture()
        /// The titles listed with a limit of `count` chosen by the view's
        /// sort, here titles Z to A, and how many rows each sort was given.
        func listed(_ count: Int, onePerFeed: Bool) -> (titles: Set<String>, sortedCounts: [Int]) {
            var sortedCounts: [Int] = []
            let titles = fixture.listedItems(LibraryViewFilter(
                lists: [.books, .episodes, .articles],
                onePerFeed: onePerFeed,
                limit: LibraryViewLimit(count: count, chosenBy: .viewSort)
            )) { given in
                sortedCounts.append(given.count)
                return LibraryBookSorter.sorted(given, by: .title, ascending: false)
            }.map(\.title)
            return (Set(titles), sortedCounts)
        }
        let byTitle = listed(2, onePerFeed: false)
        XCTAssertEqual(byTitle.titles, ["Tide Tables, Part Two", "Tide Tables, Part Three"])
        XCTAssertEqual(byTitle.sortedCounts, [13])
        let latestByTitle = listed(2, onePerFeed: true)
        XCTAssertEqual(latestByTitle.titles, ["Tide Tables, Part Two", "The Night Ferry"])
        XCTAssertEqual(latestByTitle.sortedCounts, [9])
        let everyRow = listed(100, onePerFeed: false)
        XCTAssertEqual(everyRow.titles, fixture.itemTitles)
        XCTAssertEqual(everyRow.sortedCounts, [])
        XCTAssertEqual(listed(13, onePerFeed: false).sortedCounts, [])
        XCTAssertEqual(listed(12, onePerFeed: false).titles.count, 12)
    }

    /// A limit of no rows, which only code could make, lists nothing,
    /// whatever chooses, and traps nowhere.
    func testALimitOfNoRowsListsNothing() throws {
        let fixture = try Fixture()
        for order in LibraryViewLimit.Order.allCases {
            for count in [0, -3, Int.min] {
                for onePerFeed in [false, true] {
                    let filter = LibraryViewFilter(
                        lists: [.books, .episodes, .articles],
                        onePerFeed: onePerFeed,
                        limit: LibraryViewLimit(count: count, chosenBy: order)
                    )
                    XCTAssertEqual(fixture.listedItems(filter), [], "\(order), \(count)")
                }
            }
        }
    }

    // MARK: - Whether a Filter Lists Anything

    /// Whether a filter lists any row or feed, which ends at the first that
    /// matches, says what the whole lists say: for each condition either
    /// way, on every kind, one kind, and feeds alone; for every condition at
    /// once, all or any; with only the latest from each feed and a limit
    /// chosen each way, of no rows too; and for a limit of no rows, which
    /// only code could make (review of October 31, 2026, finding 4).
    func testWhetherAFilterListsAnythingAgreesWithWhatItLists() throws {
        let fixture = try Fixture()
        let tests: [LibraryViewCondition.Test] = [
            .format(.epub), .format(.daisy),
            .folder(id: fixture.fiction.id, includingSubfolders: true), .folder(id: fixture.goneFolderID, includingSubfolders: false),
            .readingState(.unopened), .readingState(.finished), .inReadingList,
            .addedWithin(days: 1), .openedWithin(days: 2),
            .titleOrAuthorContains("ferry"), .titleOrAuthorContains("nowhere at all"),
            .hasNewItems, .subscribed,
        ]
        let kinds: [Set<LibraryViewItemKind>] = [Set(LibraryViewItemKind.allCases), [.episodes], [.feeds]]
        var filters: [LibraryViewFilter] = []
        for test in tests {
            for isNegated in [false, true] {
                for lists in kinds {
                    filters.append(LibraryViewFilter(lists: lists, conditions: [LibraryViewCondition(test: test, isNegated: isNegated)]))
                }
            }
        }
        let every = tests.map { LibraryViewCondition(test: $0) }
        filters.append(LibraryViewFilter(lists: Set(LibraryViewItemKind.allCases), conditions: every))
        filters.append(LibraryViewFilter(lists: Set(LibraryViewItemKind.allCases), match: .any, conditions: every))
        for order in LibraryViewLimit.Order.allCases {
            for count in [1, 3, 0] {
                filters.append(LibraryViewFilter(
                    lists: [.books, .episodes, .articles],
                    conditions: [LibraryViewCondition(test: .readingState(.unopened))],
                    onePerFeed: true,
                    limit: LibraryViewLimit(count: count, chosenBy: order)
                ))
            }
        }

        var answers: [Bool] = []
        for filter in filters {
            let context = fixture.context(for: filter)
            for rows in [fixture.rows, []] {
                let listsAny = LibraryViewFilterEvaluator.listsAnyItem(of: filter, in: rows, context: context)
                XCTAssertEqual(listsAny, !fixture.listedItems(filter, in: rows, context: context).isEmpty, "\(filter), \(rows.count) rows")
                answers.append(listsAny)
            }
            for feeds in [fixture.feeds, []] {
                let listsAny = LibraryViewFilterEvaluator.listsAnyFeed(
                    of: filter,
                    in: feeds,
                    context: context,
                    newItemCount: { fixture.newItemCounts[$0] ?? 0 },
                    folderPath: { fixture.folderPath($0.folderID) }
                )
                let listed = LibraryViewFilterEvaluator.feeds(
                    of: filter,
                    in: feeds,
                    context: context,
                    newItemCount: { fixture.newItemCounts[$0] ?? 0 },
                    folderPath: { fixture.folderPath($0.folderID) }
                )
                XCTAssertEqual(listsAny, !listed.isEmpty, "\(filter), \(feeds.count) feeds")
                answers.append(listsAny)
            }
        }
        // The filters ask both ways.
        XCTAssertTrue(answers.contains(true))
        XCTAssertTrue(answers.contains(false))
    }

    // MARK: - The Context

    /// The context gathers only what the filter reads, each source asked at
    /// most once (a folder's path once for each folder named), so a change
    /// the filter does not read never changes it: nothing for the shipped
    /// views; the finished rows for In Progress and Finished alone; the
    /// reading list for its own condition; the folders named, and the feeds'
    /// folders only where episodes or articles are listed; thresholds for
    /// the days; and nothing for a condition that tests no kind listed.
    func testTheContextGathersOnlyWhatTheFilterReads() throws {
        let fixture = try Fixture()
        let shipped = try ShippedFilters()
        for filter in [shipped.allItems, shipped.unopened, shipped.recent, shipped.feeds] {
            let gathering = gathered(filter, from: fixture)
            XCTAssertEqual(gathering.context, LibraryViewFilterContext())
            XCTAssertEqual(gathering.calls, Calls())
        }

        var gathering = gathered(LibraryViewFilter(lists: [.books], conditions: [
            LibraryViewCondition(test: .readingState(.inProgress)),
            LibraryViewCondition(test: .readingState(.finished), isNegated: true),
            LibraryViewCondition(test: .readingState(.unopened)),
        ]), from: fixture)
        XCTAssertEqual(gathering.context, LibraryViewFilterContext(finishedIDs: fixture.finishedIDs))
        XCTAssertEqual(gathering.calls, Calls(finished: 1))
        gathering = gathered(LibraryViewFilter(lists: [.books], conditions: [LibraryViewCondition(test: .readingState(.unopened))]), from: fixture)
        XCTAssertEqual(gathering.calls, Calls())

        gathering = gathered(LibraryViewFilter(lists: [.articles], conditions: [
            LibraryViewCondition(test: .inReadingList),
            LibraryViewCondition(test: .inReadingList, isNegated: true),
        ]), from: fixture)
        XCTAssertEqual(gathering.context, LibraryViewFilterContext(readingListIDs: fixture.readingListIDs))
        XCTAssertEqual(gathering.calls, Calls(readingList: 1))

        let folderConditions = [
            LibraryViewCondition(test: .folder(id: fixture.fiction.id, includingSubfolders: false)),
            LibraryViewCondition(test: .folder(id: fixture.fiction.id, includingSubfolders: true), isNegated: true),
            LibraryViewCondition(test: .folder(id: fixture.goneFolderID, includingSubfolders: false)),
            LibraryViewCondition(test: .folder(id: nil, includingSubfolders: true)),
        ]
        let namedFolders = [fixture.fiction.id: 1, fixture.goneFolderID: 1]
        for lists in [[.books], [.feeds], [.books, .feeds]] as [Set<LibraryViewItemKind>] {
            gathering = gathered(LibraryViewFilter(lists: lists, conditions: folderConditions), from: fixture)
            XCTAssertEqual(gathering.context, LibraryViewFilterContext(folderPaths: [fixture.fiction.id: "Fiction"]), "\(lists)")
            XCTAssertEqual(gathering.calls, Calls(folders: namedFolders), "\(lists)")
        }
        for lists in [[.episodes], [.articles], [.books, .articles, .feeds]] as [Set<LibraryViewItemKind>] {
            gathering = gathered(LibraryViewFilter(lists: lists, conditions: folderConditions), from: fixture)
            XCTAssertEqual(
                gathering.context,
                LibraryViewFilterContext(folderPaths: [fixture.fiction.id: "Fiction"], feedFolderPaths: fixture.feedFolderPaths),
                "\(lists)"
            )
            XCTAssertEqual(gathering.calls, Calls(feedFolders: 1, folders: namedFolders), "\(lists)")
        }
        gathering = gathered(LibraryViewFilter(lists: [.episodes], conditions: [
            LibraryViewCondition(test: .folder(id: nil, includingSubfolders: false)),
        ]), from: fixture)
        XCTAssertEqual(gathering.context, LibraryViewFilterContext(feedFolderPaths: fixture.feedFolderPaths))
        XCTAssertEqual(gathering.calls, Calls(feedFolders: 1))

        gathering = gathered(LibraryViewFilter(lists: [.books], conditions: [
            LibraryViewCondition(test: .addedWithin(days: 7)),
            LibraryViewCondition(test: .openedWithin(days: 7), isNegated: true),
            LibraryViewCondition(test: .addedWithin(days: 1)),
        ]), from: fixture)
        XCTAssertEqual(gathering.context, LibraryViewFilterContext(dayThresholds: [
            1: Fixture.startOfToday,
            7: Fixture.startOfToday.addingTimeInterval(-6 * Fixture.day),
        ]))
        XCTAssertEqual(gathering.calls, Calls())

        // Conditions about books on a list of feeds, and about feeds or
        // anything on a list of books, read nothing they do not need.
        gathering = gathered(LibraryViewFilter(lists: [.feeds], conditions: [
            LibraryViewCondition(test: .inReadingList),
            LibraryViewCondition(test: .readingState(.finished)),
            LibraryViewCondition(test: .addedWithin(days: 3)),
            LibraryViewCondition(test: .openedWithin(days: 4)),
            LibraryViewCondition(test: .format(.epub)),
            LibraryViewCondition(test: .hasNewItems),
            LibraryViewCondition(test: .subscribed),
            LibraryViewCondition(test: .titleOrAuthorContains("Ledger")),
        ]), from: fixture)
        XCTAssertEqual(gathering.context, LibraryViewFilterContext())
        XCTAssertEqual(gathering.calls, Calls())
        gathering = gathered(LibraryViewFilter(lists: [.books], conditions: [
            LibraryViewCondition(test: .hasNewItems),
            LibraryViewCondition(test: .subscribed, isNegated: true),
            LibraryViewCondition(test: .format(.epub)),
            LibraryViewCondition(test: .titleOrAuthorContains("Ledger")),
        ]), from: fixture)
        XCTAssertEqual(gathering.context, LibraryViewFilterContext())
        XCTAssertEqual(gathering.calls, Calls())
    }

    // MARK: - The Rows Opened Last

    /// `LibraryBookSorter.latestOpened` and `recent`, and the shipped
    /// Recently Opened view, choose exactly what `recent` chose before
    /// either existed (copied below), on rows of three feeds and books
    /// opened at a few instants, so many share one, in several orders, at
    /// every limit; with no limit and every feed item kept, every row opened
    /// comes in the order of the same sort, and the rows never opened last,
    /// by title, all of them added at one instant (review of October 31,
    /// 2026, finding 7).
    func testTheRowsOpenedLastAreChosenAsRecentChoseThem() throws {
        let fixture = try Fixture()
        let recentView = try ShippedFilters().recent
        let rows = Self.rowsWithTies()
        for order in [rows, rows.reversed(), Array(rows.dropFirst(13) + rows.prefix(13))] {
            for limit in [Int.min, -1, 0, 1, 2, 3, 5, 10, 17, 26, 100] {
                let before = Self.recentAsItWas(order, limit: limit).map(\.title)
                XCTAssertEqual(LibraryBookSorter.recent(order, limit: limit).map(\.title), before, "limit \(limit)")
                XCTAssertEqual(
                    LibraryBookSorter.latestOpened(order.filter { !$0.isUnopened }, limit: limit, onePerFeed: true).map(\.title),
                    before,
                    "limit \(limit)"
                )
            }
            XCTAssertEqual(fixture.listedItems(recentView, in: order).map(\.title), Self.recentAsItWas(order).map(\.title))

            // Changed on purpose by the review of October 31, 2026 (finding
            // 7): the rows never opened no longer come as the rows came.
            let opened = order.filter { !$0.isUnopened }.sorted { ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }
            let everyRow = LibraryBookSorter.latestOpened(order, limit: nil, onePerFeed: false)
            XCTAssertEqual(everyRow.map(\.title), opened.map(\.title) + ["Row 13", "Row 20", "Row 27", "Row 34", "Row 6"])
            XCTAssertEqual(LibraryBookSorter.latestOpened(order, limit: 4, onePerFeed: false).map(\.title), opened.prefix(4).map(\.title))
        }
    }

    /// Of a feed's episodes never opened, only the latest from each feed
    /// keeps the one added last, whatever order the library holds them in,
    /// and, of two added at one instant, the first by title; an episode
    /// opened, however long ago, comes before them all (review of October
    /// 31, 2026, finding 7).
    func testTheLatestOfEpisodesNeverOpenedIsTheNewest() throws {
        let fixture = try Fixture()
        let feedID = fixture.harbour.id
        let older = Fixture.row("Harbour Notes, Monday", .audio, added: Fixture.now.addingTimeInterval(-Fixture.day), opened: nil, feedID: feedID)
        let newer = Fixture.row("Harbour Notes, Tuesday", .audio, added: Fixture.now, opened: nil, feedID: feedID)
        let twin = Fixture.row("Harbour Notes, Extra", .audio, added: Fixture.now, opened: nil, feedID: feedID)
        let filter = LibraryViewFilter(lists: [.episodes], onePerFeed: true)
        for rows in [[older, newer], [newer, older]] {
            XCTAssertEqual(fixture.listedItems(filter, in: rows).map(\.title), ["Harbour Notes, Tuesday"])
            XCTAssertEqual(LibraryBookSorter.latestOpened(rows, limit: nil, onePerFeed: true).map(\.title), ["Harbour Notes, Tuesday"])
        }
        for rows in [[newer, twin, older], [older, twin, newer], [twin, newer, older]] {
            XCTAssertEqual(fixture.listedItems(filter, in: rows).map(\.title), ["Harbour Notes, Extra"])
        }
        let opened = Fixture.row(
            "Harbour Notes, Last Year",
            .audio,
            added: Fixture.now.addingTimeInterval(-400 * Fixture.day),
            opened: Fixture.now.addingTimeInterval(-300 * Fixture.day),
            feedID: feedID
        )
        XCTAssertEqual(fixture.listedItems(filter, in: [newer, opened, older]).map(\.title), ["Harbour Notes, Last Year"])
    }

    // MARK: - The Kind of a Row

    /// A row of the library's own is a book, whatever its format, an
    /// audiobook included; a feed's item is an episode when it is audio and
    /// an article otherwise; no book's row is a feed.
    func testEachRowIsABookAnEpisodeOrAnArticle() {
        let feedID = UUID()
        /// A row of `format`, a feed's item when `inFeed`.
        func row(_ format: BookFormat, inFeed: Bool) -> Book {
            Book(
                title: "\(format.rawValue) row",
                format: format,
                filePath: "/nonexistent/evaluator/\(format.rawValue)",
                md5Hash: "evaluator-\(format.rawValue)",
                feedLink: inFeed ? FeedBookLink(feedID: feedID, itemID: "guid:\(format.rawValue)") : nil
            )
        }
        XCTAssertEqual(row(.txt, inFeed: false).listedKind, .books)
        XCTAssertEqual(row(.audio, inFeed: false).listedKind, .books)
        XCTAssertEqual(row(.audio, inFeed: true).listedKind, .episodes)
        XCTAssertEqual(row(.html, inFeed: true).listedKind, .articles)
        XCTAssertEqual(row(.pdf, inFeed: true).listedKind, .articles)
        for format in BookFormat.allCases {
            XCTAssertEqual(row(format, inFeed: false).listedKind, .books, format.rawValue)
            XCTAssertNotEqual(row(format, inFeed: true).listedKind, .feeds, format.rawValue)
        }
    }

    /// A list's counts tell its rows apart by the same rule: the library's
    /// own audiobook is counted as a book, a feed's audio item as an
    /// episode, and its other items as articles.
    func testAListsCountsTellItsRowsApartByTheSameRule() {
        let feedID = UUID()
        let rows = [(BookFormat.txt, false), (.audio, false), (.audio, true), (.html, true), (.pdf, true)].map { format, inFeed in
            Fixture.row("\(format.rawValue) row", format, added: Fixture.now, opened: nil, feedID: inFeed ? feedID : nil)
        }
        XCTAssertEqual(rows.map(\.listedKind), [.books, .books, .episodes, .articles, .articles])
        XCTAssertEqual(CountWording.listItems(of: rows), "2 books, 1 episode, 2 articles")
        XCTAssertEqual(CountWording.booksHeader(of: rows), "Books (2), Episodes (1), Articles (2)")
    }

    // MARK: - Helpers

    /// Asserts that a filter listing every kind of row, with the one
    /// condition `test`, lists the books, episodes, and articles titled
    /// `items` and the feeds titled `feeds`, and, negated, every other one;
    /// nil stands for a kind the test does not test, whose rows are listed
    /// both ways. The context is the one gathered for each filter unless one
    /// is given.
    private func assertListed(
        _ test: LibraryViewCondition.Test,
        items: Set<String>?,
        feeds: Set<String>?,
        in fixture: Fixture,
        context: LibraryViewFilterContext? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for isNegated in [false, true] {
            let filter = LibraryViewFilter(
                lists: Set(LibraryViewItemKind.allCases),
                conditions: [LibraryViewCondition(test: test, isNegated: isNegated)]
            )
            let expectedItems = items.map { isNegated ? fixture.itemTitles.subtracting($0) : $0 } ?? fixture.itemTitles
            let expectedFeeds = feeds.map { isNegated ? fixture.feedTitles.subtracting($0) : $0 } ?? fixture.feedTitles
            let label = "\(test), negated: \(isNegated)"
            XCTAssertEqual(fixture.listedItemTitles(filter, context: context), expectedItems, label, file: file, line: line)
            XCTAssertEqual(fixture.listedFeedTitles(filter, context: context), expectedFeeds, label, file: file, line: line)
        }
    }

    /// How many times gathering a context asked each of its sources.
    private struct Calls: Equatable {
        var finished = 0
        var readingList = 0
        var feedFolders = 0
        /// By folder ID.
        var folders: [UUID: Int] = [:]
    }

    /// The context gathered for `filter` from `fixture`, and how many times
    /// each source was asked.
    private func gathered(_ filter: LibraryViewFilter, from fixture: Fixture) -> (context: LibraryViewFilterContext, calls: Calls) {
        var calls = Calls()
        let context = LibraryViewFilterContext(
            for: filter,
            now: Fixture.now,
            calendar: Fixture.calendar,
            finishedIDs: {
                calls.finished += 1
                return fixture.finishedIDs
            },
            readingListIDs: {
                calls.readingList += 1
                return fixture.readingListIDs
            },
            folderPath: { folderID in
                calls.folders[folderID, default: 0] += 1
                return fixture.folderPath(folderID)
            },
            feedFolderPaths: {
                calls.feedFolders += 1
                return fixture.feedFolderPaths
            }
        )
        return (context, calls)
    }

    /// The filters of the views TextMouth ships that list what a filter
    /// finds.
    private struct ShippedFilters {
        let allItems: LibraryViewFilter
        let unopened: LibraryViewFilter
        let recent: LibraryViewFilter
        let feeds: LibraryViewFilter

        init() throws {
            allItems = try XCTUnwrap(LibraryViewDefinition.shipped(.allItems).filter)
            unopened = try XCTUnwrap(LibraryViewDefinition.shipped(.unopened).filter)
            recent = try XCTUnwrap(LibraryViewDefinition.shipped(.recent).filter)
            feeds = try XCTUnwrap(LibraryViewDefinition.shipped(LibraryViewID.feeds)?.filter)
        }
    }

    /// What `LibraryBookSorter.recent` did before `latestOpened` existed
    /// (October 30, 2026), copied as it was.
    private static func recentAsItWas(_ books: [Book], limit: Int = 10) -> [Book] {
        guard limit > 0 else { return [] }
        let opened = books
            .filter { !$0.isUnopened }
            .sorted { ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }
        var listedFeeds = Set<UUID>()
        var listed: [Book] = []
        for book in opened {
            if let feedID = book.feedLink?.feedID, !listedFeeds.insert(feedID).inserted {
                continue
            }
            listed.append(book)
            if listed.count == limit {
                break
            }
        }
        return listed
    }

    /// Thirty-six rows: books and the items of three feeds, each opened at
    /// one of four instants or never, so many share an instant, across
    /// books and feeds alike.
    private static func rowsWithTies() -> [Book] {
        let feedIDs = (UUID(), UUID(), UUID())
        return (0..<36).map { number in
            let feedID: UUID?
            switch number % 4 {
            case 1: feedID = feedIDs.0
            case 2: feedID = feedIDs.1
            case 3: feedID = feedIDs.2
            default: feedID = nil
            }
            let opened = number % 7 == 6 ? nil : Fixture.now.addingTimeInterval(-Double(number % 3) * Fixture.hour)
            return Fixture.row("Row \(number)", feedID == nil ? .txt : .audio, added: Fixture.now, opened: opened, feedID: feedID)
        }
    }

    // MARK: - The Library

    /// A small library, built afresh for each test.
    ///
    /// Books of the library's own, in Library Root, Fiction, Fiction/Short,
    /// Fictional, and Essays, of several formats, opened and never opened,
    /// two of them opened at the same instant; the episodes and articles of
    /// three feeds, whose rows name no folder of their own; the feeds, one in
    /// a folder that holds books too, and one in a folder no longer in the
    /// library; and which rows are finished and in the reading list.
    ///
    /// | Row | Kind | Format | Folder | Added | Opened | Also |
    /// |---|---|---|---|---|---|---|
    /// | Canal Engineering, Odile Varga | book | EPUB | root | 30 days ago | never | |
    /// | The Night Ferry, Tomasz Okafor | book | text | Fiction | 23:59 yesterday | 2 hours ago | |
    /// | Pocket Stories, Ines Duarte | book | Markdown | Fiction/Short | 400 days ago | 3 days ago | finished |
    /// | Salt and Empire, Ruth Abernathy | book | PDF | Essays | 01:00 today | 3 days ago | reading list |
    /// | Ferry Songs, Odile Varga | book | audio | Fiction | 3 days ago | never | |
    /// | Street Signs, Hugo Lindqvist | book | HTML | Fictional | 5 days ago | 10 days ago | |
    /// | Tide Tables, Part One | Harbour Radio | audio | | 6 days ago | 4 days ago | finished |
    /// | Tide Tables, Part Two | Harbour Radio | audio | | 1 day ago | 1 hour ago | reading list |
    /// | Tide Tables, Part Three | Harbour Radio | audio | | 2 hours ago | never | |
    /// | Static Hour 12, Varga Sound | Static Hour | audio | | 9 days ago | 6 days ago | |
    /// | Ledger: On Ferries | The Weekly Ledger | HTML | | 8 days ago | 5 days ago | finished |
    /// | Ledger: Salt Prices | The Weekly Ledger | HTML | | 30 hours ago | never | reading list |
    /// | Ledger: Canal Fees | The Weekly Ledger | PDF | | 40 days ago | 25 hours ago | |
    ///
    /// The feeds: Harbour Radio, by Port Office Media, in Podcasts/Harbour
    /// Radio, subscribed, with 2 new items; The Weekly Ledger, with no
    /// author, in Essays, unsubscribed, with 3 new; and Static Hour, by Varga
    /// Sound, whose folder is gone, subscribed, with none new.
    private struct Fixture {
        /// Friday, October 30, 2026, at noon UTC: the tests' now.
        static let now = Date(timeIntervalSince1970: 1_793_361_600)
        /// Midnight UTC that day.
        static let startOfToday = Date(timeIntervalSince1970: 1_793_318_400)
        /// A Gregorian calendar in UTC.
        static let calendar: Calendar = {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .gmt
            return calendar
        }()
        static let hour: TimeInterval = 3_600
        static let day: TimeInterval = 86_400

        let fiction = BookFolder(name: "Fiction")
        let short = BookFolder(name: "Short", parentPath: "Fiction")
        let fictional = BookFolder(name: "Fictional")
        let essays = BookFolder(name: "Essays")
        let podcasts = BookFolder(name: "Podcasts")
        let harbourFolder = BookFolder(name: "Harbour Radio", parentPath: "Podcasts")
        /// The folder Static Hour's downloads went to, deleted since.
        let goneFolderID = UUID()

        let harbour: Feed
        let ledger: Feed
        let staticHour: Feed
        /// The library's rows, books and feed items mixed, in the order the
        /// library holds them.
        let rows: [Book]
        let finishedIDs: Set<UUID>
        let readingListIDs: Set<UUID>

        init() throws {
            let subscribed = Self.now.addingTimeInterval(-100 * Self.day)
            harbour = try Self.feed("Harbour Radio", by: "Port Office Media", in: harbourFolder.id, since: subscribed)
            ledger = try Self.feed("The Weekly Ledger", by: nil, in: essays.id, since: subscribed, unsubscribed: true)
            staticHour = try Self.feed("Static Hour", by: "Varga Sound", in: goneFolderID, since: subscribed)

            let ago = { (seconds: TimeInterval) in Self.now.addingTimeInterval(-seconds) }
            let threeDaysAgo = ago(3 * Self.day)
            let pocketStories = Self.row("Pocket Stories", by: "Ines Duarte", .markdown, in: "Fiction/Short", added: ago(400 * Self.day), opened: threeDaysAgo)
            let saltAndEmpire = Self.row("Salt and Empire", by: "Ruth Abernathy", .pdf, in: "Essays", added: Self.startOfToday.addingTimeInterval(Self.hour), opened: threeDaysAgo)
            let tidesOne = Self.row("Tide Tables, Part One", .audio, added: ago(6 * Self.day), opened: ago(4 * Self.day), feedID: harbour.id)
            let tidesTwo = Self.row("Tide Tables, Part Two", .audio, added: ago(Self.day), opened: ago(Self.hour), feedID: harbour.id)
            let onFerries = Self.row("Ledger: On Ferries", .html, added: ago(8 * Self.day), opened: ago(5 * Self.day), feedID: ledger.id)
            let saltPrices = Self.row("Ledger: Salt Prices", .html, added: ago(30 * Self.hour), opened: nil, feedID: ledger.id)
            rows = [
                Self.row("Canal Engineering", by: "Odile Varga", .epub, added: ago(30 * Self.day), opened: nil),
                tidesOne,
                Self.row("The Night Ferry", by: "Tomasz Okafor", .txt, in: "Fiction", added: Self.startOfToday.addingTimeInterval(-60), opened: ago(2 * Self.hour)),
                onFerries,
                pocketStories,
                tidesTwo,
                saltAndEmpire,
                Self.row("Static Hour 12", by: "Varga Sound", .audio, added: ago(9 * Self.day), opened: ago(6 * Self.day), feedID: staticHour.id),
                Self.row("Ferry Songs", by: "Odile Varga", .audio, in: "Fiction", added: threeDaysAgo, opened: nil),
                saltPrices,
                Self.row("Street Signs", by: "Hugo Lindqvist", .html, in: "Fictional", added: ago(5 * Self.day), opened: ago(10 * Self.day)),
                Self.row("Tide Tables, Part Three", .audio, added: ago(2 * Self.hour), opened: nil, feedID: harbour.id),
                Self.row("Ledger: Canal Fees", .pdf, added: ago(40 * Self.day), opened: ago(25 * Self.hour), feedID: ledger.id),
            ]
            finishedIDs = [pocketStories.id, tidesOne.id, onFerries.id]
            readingListIDs = [saltAndEmpire.id, tidesTwo.id, saltPrices.id]
        }

        /// The library's folders.
        var folders: [BookFolder] {
            [fiction, short, fictional, essays, podcasts, harbourFolder]
        }

        /// The feeds, in the order the Feeds section lists them.
        var feeds: [Feed] {
            [harbour, ledger, staticHour]
        }

        /// The library holding the rows and folders.
        var library: Library {
            Library(books: rows, folders: folders)
        }

        /// How many new episodes or articles each feed has, by feed ID.
        var newItemCounts: [UUID: Int] {
            [harbour.id: 2, ledger.id: 3]
        }

        /// The path of each feed's folder still in the library, by feed ID.
        var feedFolderPaths: [UUID: String] {
            Dictionary(uniqueKeysWithValues: feeds.compactMap { feed in
                folderPath(feed.folderID).map { (feed.id, $0) }
            })
        }

        /// The titles of every book, episode, and article.
        var itemTitles: Set<String> {
            Set(rows.map(\.title))
        }

        /// The titles of the library's own books.
        var bookTitles: Set<String> {
            Set(rows.filter { !$0.isFeedItem }.map(\.title))
        }

        /// The titles of every row ever opened.
        var openedTitles: Set<String> {
            Set(rows.filter { !$0.isUnopened }.map(\.title))
        }

        /// The titles of the feeds.
        var feedTitles: Set<String> {
            Set(feeds.map(\.title))
        }

        /// The path of the folder `folderID`, as the library finds it; nil
        /// for a folder no longer in it.
        func folderPath(_ folderID: UUID) -> String? {
            folders.first { $0.id == folderID }?.fullPath
        }

        /// The context gathered for `filter` from this library, as a list
        /// gathers it.
        func context(for filter: LibraryViewFilter, now: Date = Fixture.now, calendar: Calendar = Fixture.calendar) -> LibraryViewFilterContext {
            LibraryViewFilterContext(
                for: filter,
                now: now,
                calendar: calendar,
                finishedIDs: { finishedIDs },
                readingListIDs: { readingListIDs },
                folderPath: { folderPath($0) },
                feedFolderPaths: { feedFolderPaths }
            )
        }

        /// The rows `filter` lists of `rows` (the library's own by
        /// default), in `context` (the one gathered for it by default); a
        /// limit chosen by the view's sort ranks them by `sorted`.
        func listedItems(
            _ filter: LibraryViewFilter,
            in rows: [Book]? = nil,
            context: LibraryViewFilterContext? = nil,
            sorted: ([Book]) -> [Book] = { $0 }
        ) -> [Book] {
            LibraryViewFilterEvaluator.items(
                of: filter,
                in: rows ?? self.rows,
                context: context ?? self.context(for: filter),
                sorted: sorted
            )
        }

        /// The titles of the rows `filter` lists, as `listedItems` lists
        /// them.
        func listedItemTitles(_ filter: LibraryViewFilter, in rows: [Book]? = nil, context: LibraryViewFilterContext? = nil) -> Set<String> {
            Set(listedItems(filter, in: rows, context: context).map(\.title))
        }

        /// The feeds `filter` lists, in `context` (the one gathered for it
        /// by default).
        func listedFeeds(_ filter: LibraryViewFilter, context: LibraryViewFilterContext? = nil) -> [Feed] {
            LibraryViewFilterEvaluator.feeds(
                of: filter,
                in: feeds,
                context: context ?? self.context(for: filter),
                newItemCount: { newItemCounts[$0] ?? 0 },
                folderPath: { folderPath($0.folderID) }
            )
        }

        /// The titles of the feeds `filter` lists.
        func listedFeedTitles(_ filter: LibraryViewFilter, context: LibraryViewFilterContext? = nil) -> Set<String> {
            Set(listedFeeds(filter, context: context).map(\.title))
        }

        /// More rows than Recently Opened lists, to follow the fixture's:
        /// twelve books and six of Harbour Radio's episodes, opened at the
        /// fixture's own instants an hour and two hours ago, or never.
        func crowdedRows() -> [Book] {
            let books = (1...12).map { number in
                Self.row(
                    "Crowded Book \(number)",
                    .txt,
                    in: number.isMultiple(of: 2) ? "Fiction" : "",
                    added: Self.now.addingTimeInterval(-Double(number) * Self.day),
                    opened: number.isMultiple(of: 5) ? nil : Self.now.addingTimeInterval(-Double(1 + number % 2) * Self.hour)
                )
            }
            let episodes = (1...6).map { number in
                Self.row(
                    "Crowded Episode \(number)",
                    .audio,
                    added: Self.now.addingTimeInterval(-Double(number) * Self.hour),
                    opened: number == 6 ? nil : Self.now.addingTimeInterval(-Double(number % 2) * Self.hour),
                    feedID: harbour.id
                )
            }
            return books + episodes
        }

        /// A row titled `title`, by `author`, of `format`, in the folder
        /// `folder`, added at `added` and last opened at `opened` (nil:
        /// never), and, with `feedID`, an item of that feed.
        static func row(
            _ title: String,
            by author: String = Book.unknownAuthor,
            _ format: BookFormat,
            in folder: String = "",
            added: Date,
            opened: Date?,
            feedID: UUID? = nil
        ) -> Book {
            let id = UUID()
            return Book(
                id: id,
                title: title,
                author: author,
                format: format,
                filePath: "/nonexistent/evaluator/\(id.uuidString)",
                md5Hash: "evaluator-\(id.uuidString)",
                folderPath: folder,
                dateAdded: added,
                lastOpened: opened,
                feedLink: feedID.map { FeedBookLink(feedID: $0, itemID: "guid:\(id.uuidString)") }
            )
        }

        /// A feed titled `title`, by `author`, whose downloads go to the
        /// folder `folderID`, subscribed since `date`, unsubscribed when
        /// `unsubscribed`.
        private static func feed(_ title: String, by author: String?, in folderID: UUID, since date: Date, unsubscribed: Bool = false) throws -> Feed {
            let address = try XCTUnwrap(URL(string: "https://feeds.example/\(UUID().uuidString).xml"))
            var feed = Feed(feedURL: address, folderID: folderID, subscribedDate: date)
            feed.title = title
            feed.author = author
            feed.unsubscribedDate = unsubscribed ? date.addingTimeInterval(Self.day) : nil
            return feed
        }
    }
}
