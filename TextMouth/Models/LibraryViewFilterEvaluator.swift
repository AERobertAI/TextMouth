import Foundation

// MARK: - The Kind of a Book's Row

extension Book {
    /// The kind of row this is, as a Library view lists it and the
    /// library's counts count it (design section 4,
    /// LIBRARY-VIEWS-RESEARCH-2026-10-30.md): a book of the library's own,
    /// an episode (a feed item whose format is audio), or an article (any
    /// other feed item). The one spelling of this rule; never `.feeds`, which
    /// only a feed's own row is.
    var listedKind: LibraryViewItemKind {
        guard isFeedItem else { return .books }
        return format.isAudio ? .episodes : .articles
    }
}

// MARK: - What a Filter Reads

/// Everything a Library view's filter reads beyond the rows themselves
/// (design section 4), gathered once per list. Only what the filter reads is
/// gathered, and the rest stays empty or nil, so the context can be part of
/// a list cache's key: a change the filter does not read never makes a new
/// key.
struct LibraryViewFilterContext: Hashable, Sendable {
    /// For each day count of a "within the last N days" condition, the first
    /// instant inside it: the start of the day N − 1 days before today.
    var dayThresholds: [Int: Date] = [:]
    /// The rows Books Finished counts; nil unless a reading state of In
    /// Progress or Finished is tested.
    var finishedIDs: Set<UUID>? = nil
    /// The reading list's rows; nil unless "in the reading list" is tested.
    var readingListIDs: Set<UUID>? = nil
    /// The path of each folder a folder condition names, by folder ID; a
    /// folder no longer in the library is absent.
    var folderPaths: [UUID: String] = [:]
    /// Each feed's folder path, by feed ID; nil unless a folder condition is
    /// tested on episodes or articles.
    var feedFolderPaths: [UUID: String]? = nil
}

extension LibraryViewFilterContext {
    /// What `filter` reads, gathered through the closures, each called only
    /// when the filter needs what it gives, and at most once (`folderPath`
    /// once for each folder the conditions name). A condition that tests none
    /// of the kinds of rows the filter lists is never evaluated, so it reads
    /// nothing. Declared in an extension, so the memberwise initializer, which
    /// tests build contexts with, is kept.
    ///
    /// - Parameters:
    ///   - now: The instant the "within the last N days" conditions count
    ///     back from.
    ///   - calendar: The calendar whose days they count, this Mac's.
    ///   - finishedIDs: The rows Books Finished counts.
    ///   - readingListIDs: The reading list's rows.
    ///   - folderPath: A folder's path by its ID; nil for a folder no longer
    ///     in the library.
    ///   - feedFolderPaths: Each feed's folder path, by feed ID.
    init(
        for filter: LibraryViewFilter,
        now: Date,
        calendar: Calendar,
        finishedIDs: () -> Set<UUID>,
        readingListIDs: () -> Set<UUID>,
        folderPath: (UUID) -> String?,
        feedFolderPaths: () -> [UUID: String]
    ) {
        self.init()
        // What the evaluated conditions need, each noted once however many
        // conditions need it.
        var dayCounts = Set<Int>()
        var namedFolderIDs = Set<UUID>()
        var readsFinished = false
        var readsReadingList = false
        var testsFolders = false
        let evaluated = filter.conditions.filter { condition in filter.lists.contains(where: condition.tests) }
        for condition in evaluated {
            switch condition.test {
            case .addedWithin(let days), .openedWithin(let days):
                dayCounts.insert(days)
            case .readingState(.inProgress), .readingState(.finished):
                readsFinished = true
            case .inReadingList:
                readsReadingList = true
            case .folder(let folderID, _):
                testsFolders = true
                if let folderID {
                    namedFolderIDs.insert(folderID)
                }
            case .format, .readingState(.unopened), .titleOrAuthorContains, .hasNewItems, .subscribed:
                // Read from the row alone, or, for a feed, through the
                // closures `LibraryViewFilterEvaluator.feeds` is given.
                break
            }
        }

        let today = calendar.startOfDay(for: now)
        // A day count outside the range a condition can hold, which only
        // code could make, gets no threshold, so its test fails rather than
        // overflowing; a date the calendar cannot make is skipped likewise.
        for days in dayCounts where LibraryViewCondition.dayRange.contains(days) {
            if let threshold = calendar.date(byAdding: .day, value: -(days - 1), to: today) {
                dayThresholds[days] = threshold
            }
        }
        if readsFinished {
            self.finishedIDs = finishedIDs()
        }
        if readsReadingList {
            self.readingListIDs = readingListIDs()
        }
        for folderID in namedFolderIDs {
            if let path = folderPath(folderID) {
                folderPaths[folderID] = path
            }
        }
        // An episode or article is in its feed's folder; a feed's own folder
        // comes through the closure `LibraryViewFilterEvaluator.feeds` is
        // given instead.
        if testsFolders, !filter.lists.isDisjoint(with: [.episodes, .articles]) {
            self.feedFolderPaths = feedFolderPaths()
        }
    }
}

// MARK: - What a Filter Lists

/// What a Library view's filter lists (design section 4): pure functions of
/// the rows and feeds a list is made from and the context gathered for it,
/// which read nothing else.
enum LibraryViewFilterEvaluator {
    /// The kinds of rows a book's row can be (`Book.listedKind`).
    private static let itemKinds: [LibraryViewItemKind] = [.books, .episodes, .articles]

    /// The books, episodes, and articles of `rows` that `filter` lists (design
    /// section 4): the rows of the kinds it lists that match its conditions;
    /// then, with `onePerFeed`, of each feed's items the one opened last; then
    /// at most its limit's count, chosen by the limit's order. A limit chosen
    /// by the view's sort keeps the first of `sorted(rows)`; the other
    /// limits break ties by title as `articles` reads titles. The rows come
    /// in no order the caller may rely on; the caller sorts them by the
    /// view's sort. No rows when the filter lists none of these kinds.
    static func items(
        of filter: LibraryViewFilter,
        in rows: [Book],
        context: LibraryViewFilterContext,
        sorted: ([Book]) -> [Book],
        articles: LeadingArticles = .partOfTitle
    ) -> [Book] {
        let conditionsByKind = itemConditions(of: filter)
        guard !conditionsByKind.isEmpty else { return [] }
        let matched = rows.filter { isListed($0, conditionsByKind, filter.match, context: context) }
        return chosen(from: matched, by: filter, sorted: sorted, articles: articles)
    }

    /// Whether `filter` lists any of `rows`, as `items` would (review of
    /// October 31, 2026, finding 4): the search ends at the first row that
    /// matches, since one per feed and a limit keep at least one of any rows
    /// that match, and nothing is sorted or measured on disk. What a
    /// window's View pop-up asks of each view shown when applicable, at
    /// every redraw.
    static func listsAnyItem(of filter: LibraryViewFilter, in rows: [Book], context: LibraryViewFilterContext) -> Bool {
        let conditionsByKind = itemConditions(of: filter)
        // A limit below 1, which only code could make, keeps nothing, as
        // `items` keeps nothing then.
        guard !conditionsByKind.isEmpty, (filter.limit?.count ?? 1) >= 1 else { return false }
        return rows.contains { isListed($0, conditionsByKind, filter.match, context: context) }
    }

    /// The feeds of `feeds` that `filter` lists, in their order: none unless
    /// it lists feeds; those matching its conditions. `newItemCount` gives a
    /// feed's new episodes and articles (`FeedCenter.counts(of:).new`), and
    /// `folderPath` its folder's path, nil when the folder is gone.
    static func feeds(
        of filter: LibraryViewFilter,
        in feeds: [Feed],
        context: LibraryViewFilterContext,
        newItemCount: (UUID) -> Int,
        folderPath: (Feed) -> String?
    ) -> [Feed] {
        guard filter.lists.contains(.feeds) else { return [] }
        let feedConditions = conditions(of: filter, testing: .feeds)
        return feeds.filter { feed in
            isListed(feed, feedConditions, filter.match, context: context, newItemCount: newItemCount, folderPath: folderPath)
        }
    }

    /// Whether `filter` lists any of `feeds`, the search ending at the first
    /// feed that matches (`listsAnyItem`'s companion).
    static func listsAnyFeed(
        of filter: LibraryViewFilter,
        in feeds: [Feed],
        context: LibraryViewFilterContext,
        newItemCount: (UUID) -> Int,
        folderPath: (Feed) -> String?
    ) -> Bool {
        guard filter.lists.contains(.feeds) else { return false }
        let feedConditions = conditions(of: filter, testing: .feeds)
        return feeds.contains { feed in
            isListed(feed, feedConditions, filter.match, context: context, newItemCount: newItemCount, folderPath: folderPath)
        }
    }

    /// The conditions that test each kind of book row `filter` lists, found
    /// once for a whole list rather than for every row; empty when it lists
    /// no books, episodes, or articles.
    private static func itemConditions(of filter: LibraryViewFilter) -> [LibraryViewItemKind: [LibraryViewCondition]] {
        var conditionsByKind: [LibraryViewItemKind: [LibraryViewCondition]] = [:]
        for kind in itemKinds where filter.lists.contains(kind) {
            conditionsByKind[kind] = conditions(of: filter, testing: kind)
        }
        return conditionsByKind
    }

    /// Whether `row` is of a kind listed (`conditionsByKind` names the kinds)
    /// and meets the conditions that test its kind under `match`.
    private static func isListed(
        _ row: Book,
        _ conditionsByKind: [LibraryViewItemKind: [LibraryViewCondition]],
        _ match: LibraryViewMatch,
        context: LibraryViewFilterContext
    ) -> Bool {
        guard let rowConditions = conditionsByKind[row.listedKind] else { return false }
        return meets(rowConditions, match) { passes($0, item: row, context: context) }
    }

    /// Whether `feed` meets `feedConditions`, the conditions that test feeds,
    /// under `match` (`feeds` and `listsAnyFeed` share it).
    private static func isListed(
        _ feed: Feed,
        _ feedConditions: [LibraryViewCondition],
        _ match: LibraryViewMatch,
        context: LibraryViewFilterContext,
        newItemCount: (UUID) -> Int,
        folderPath: (Feed) -> String?
    ) -> Bool {
        meets(feedConditions, match) { test in
            passes(test, feed: feed, context: context, newItemCount: newItemCount, folderPath: folderPath)
        }
    }

    // MARK: Matching

    /// The conditions of `filter` that test rows of `kind`, in its order,
    /// with the text of each title or author condition lowercased here once,
    /// rather than at every row it is looked for in.
    private static func conditions(of filter: LibraryViewFilter, testing kind: LibraryViewItemKind) -> [LibraryViewCondition] {
        filter.conditions.compactMap { condition -> LibraryViewCondition? in
            guard condition.tests(kind) else { return nil }
            guard case .titleOrAuthorContains(let text) = condition.test else { return condition }
            return LibraryViewCondition(test: .titleOrAuthorContains(text.lowercased()), isNegated: condition.isNegated)
        }
    }

    /// Whether a row meets `conditions`, those that test its kind, under
    /// `match`: with none, it does; otherwise every one holds (All) or at
    /// least one (Any). A condition holds when `passes` says its test passes,
    /// or, negated, when it fails.
    private static func meets(
        _ conditions: [LibraryViewCondition],
        _ match: LibraryViewMatch,
        passes: (LibraryViewCondition.Test) -> Bool
    ) -> Bool {
        guard !conditions.isEmpty else { return true }
        switch match {
        case .all:
            return conditions.allSatisfy { passes($0.test) != $0.isNegated }
        case .any:
            return conditions.contains { passes($0.test) != $0.isNegated }
        }
    }

    /// Whether `test` passes for `row`, a book, an episode, or an article,
    /// whose title or author text `conditions(of:testing:)` lowercased.
    private static func passes(_ test: LibraryViewCondition.Test, item row: Book, context: LibraryViewFilterContext) -> Bool {
        switch test {
        case .format(let format):
            return row.format == format
        case .folder(let folderID, let includingSubfolders):
            return isInFolder(folderPath(of: row, context: context), folderID: folderID, includingSubfolders: includingSubfolders, context: context)
        case .readingState(.unopened):
            return row.isUnopened
        case .readingState(.inProgress):
            return !row.isUnopened && !isFinished(row, context: context)
        case .readingState(.finished):
            return isFinished(row, context: context)
        case .inReadingList:
            return context.readingListIDs?.contains(row.id) ?? false
        case .addedWithin(let days):
            guard let threshold = context.dayThresholds[days] else { return false }
            return row.dateAdded >= threshold
        case .openedWithin(let days):
            guard let threshold = context.dayThresholds[days], let opened = row.lastOpened else { return false }
            return opened >= threshold
        case .titleOrAuthorContains(let query):
            return contains(query, title: row.title, author: row.author)
        case .hasNewItems, .subscribed:
            // Tests of feeds, which `LibraryViewCondition.tests(_:)` never
            // gives a book, an episode, or an article.
            return false
        }
    }

    /// Whether `test` passes for `feed`, whose title or author text
    /// `conditions(of:testing:)` lowercased.
    private static func passes(
        _ test: LibraryViewCondition.Test,
        feed: Feed,
        context: LibraryViewFilterContext,
        newItemCount: (UUID) -> Int,
        folderPath: (Feed) -> String?
    ) -> Bool {
        switch test {
        case .folder(let folderID, let includingSubfolders):
            return isInFolder(folderPath(feed), folderID: folderID, includingSubfolders: includingSubfolders, context: context)
        case .titleOrAuthorContains(let query):
            return contains(query, title: feed.title, author: feed.author ?? "")
        case .hasNewItems:
            return newItemCount(feed.id) > 0
        case .subscribed:
            return feed.isSubscribed
        case .format, .readingState, .inReadingList, .addedWithin, .openedWithin:
            // Tests of books, episodes, and articles, which
            // `LibraryViewCondition.tests(_:)` never gives a feed.
            return false
        }
    }

    /// Whether Books Finished counts `row`; never when the context holds no
    /// finished rows.
    private static func isFinished(_ row: Book, context: LibraryViewFilterContext) -> Bool {
        context.finishedIDs?.contains(row.id) ?? false
    }

    /// The path of the folder a folder condition finds `row` in: a book's
    /// own, and an episode's or article's feed's, nil when that is unknown.
    private static func folderPath(of row: Book, context: LibraryViewFilterContext) -> String? {
        guard let feedID = row.feedLink?.feedID else { return row.folderPath }
        return context.feedFolderPaths?[feedID]
    }

    /// Whether a row whose folder is at `path` is in the folder a condition
    /// names: the folder `folderID`, or Library Root for nil, with or without
    /// the folders inside it. An unknown `path`, or a folder no longer in the
    /// library, matches nothing. Library Root with its folders holds every
    /// row whose folder is known, and without them the top of the library
    /// alone; another folder holds its own rows, and, with the folders inside
    /// it, theirs, by whole path components (`Library.isPath(_:inTreeAt:)`).
    private static func isInFolder(
        _ path: String?,
        folderID: UUID?,
        includingSubfolders: Bool,
        context: LibraryViewFilterContext
    ) -> Bool {
        guard let path else { return false }
        let target: String
        if let folderID {
            guard let named = context.folderPaths[folderID] else { return false }
            target = named
        } else {
            target = ""
        }
        if target.isEmpty {
            return includingSubfolders || path.isEmpty
        }
        return includingSubfolders ? Library.isPath(path, inTreeAt: target) : path == target
    }

    /// Whether `query`, lowercased already, is in `title` or `author`,
    /// ignoring case as the Library window's search matches
    /// (`LibraryViewModel.displayedBooks(at:matching:)`). An empty text is in
    /// every one, as an empty search narrows nothing.
    private static func contains(_ query: String, title: String, author: String) -> Bool {
        query.isEmpty || title.lowercased().contains(query) || author.lowercased().contains(query)
    }

    // MARK: After the Conditions

    /// What `filter` keeps of the rows that `matched` its conditions (design
    /// section 4, "After the conditions"). A limit chosen by Opened Last is
    /// the sorter's own choice, which keeps one item per feed itself, so the
    /// shipped Recently Opened view lists exactly what
    /// `LibraryBookSorter.recent(_:limit:)` does. Otherwise, with
    /// `onePerFeed`, of each feed's items the one opened last; then, with a
    /// limit, at most its count. Ties fall by title as `articles` reads
    /// titles, as they do in the list.
    private static func chosen(
        from matched: [Book],
        by filter: LibraryViewFilter,
        sorted: ([Book]) -> [Book],
        articles: LeadingArticles
    ) -> [Book] {
        guard let limit = filter.limit else {
            return latestPerFeed(of: matched, if: filter.onePerFeed, articles: articles)
        }
        // A count below 1, which only code could make, keeps nothing.
        let count = max(limit.count, 0)
        switch limit.chosenBy {
        case .lastOpened:
            return LibraryBookSorter.latestOpened(matched, limit: count, onePerFeed: filter.onePerFeed, articles: articles)
        case .dateAdded:
            // Added last first, by the comparator every list sorts with, so
            // ties fall as they do in a list sorted by Date Added.
            return atMost(count, of: latestPerFeed(of: matched, if: filter.onePerFeed, articles: articles)) {
                LibraryBookSorter.sorted($0, by: .dateAdded, ascending: false, articles: articles)
            }
        case .viewSort:
            return atMost(count, of: latestPerFeed(of: matched, if: filter.onePerFeed, articles: articles), rankedBy: sorted)
        }
    }

    /// `rows`, or, when `onePerFeed`, the books among them and, of each
    /// feed's items, only the one opened last, ties falling by title as
    /// `articles` reads titles.
    private static func latestPerFeed(of rows: [Book], if onePerFeed: Bool, articles: LeadingArticles) -> [Book] {
        onePerFeed ? LibraryBookSorter.latestOpened(rows, limit: nil, onePerFeed: true, articles: articles) : rows
    }

    /// At most `count` of `rows`: every one, unsorted, when they are within
    /// it, since the caller sorts them; otherwise the first `count` in the
    /// order `ranked` puts them in.
    private static func atMost(_ count: Int, of rows: [Book], rankedBy ranked: ([Book]) -> [Book]) -> [Book] {
        guard rows.count > count else { return rows }
        return Array(ranked(rows).prefix(count))
    }
}
