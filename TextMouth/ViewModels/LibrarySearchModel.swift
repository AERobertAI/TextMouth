import Foundation
import os

// MARK: - What the Window Lists

/// One book's matches as a search found them, which the window lists under
/// the book's heading.
struct LibrarySearchGroup: Identifiable, Equatable, Sendable {
    /// The book's ID.
    var id: UUID { book.id }
    /// The book.
    let book: LibrarySearchBook
    /// The book's place in the list searched: books are listed in this order.
    let order: Int
    /// How many matches the book holds, up to the limit counted.
    var matchCount: Int
    /// Whether the book holds more matches than `matchCount`.
    var countReachedLimit: Bool
    /// The matches kept, in reading order.
    var matches: [BookSearchResult]
    /// Whether the listener asked for all of this book's matches, so the
    /// list shows every one kept, up to Search in Book's limit.
    var showsAll = false

    /// The group of `result`.
    init(_ result: LibrarySearchBookResult) {
        book = result.book
        order = result.order
        matchCount = result.matchCount
        countReachedLimit = result.countReachedLimit
        matches = result.matches
    }

    /// The heading the window shows and speaks over the book's matches.
    var heading: String {
        LibrarySearchWording.bookHeading(
            title: book.title, author: book.author, matches: matchCount, isLowerBound: countReachedLimit
        )
    }
}

/// One match as the window lists it: the match, and its book.
struct LibrarySearchMatchRow: Identifiable, Equatable, Sendable {
    /// Stable across searches' redraws: the book and the match's own ID.
    var id: String { "\(book.id.uuidString):\(match.id)" }
    /// The book the match is in.
    let book: LibrarySearchBook
    /// The match, with its context and where it is.
    let match: BookSearchResult
    /// The match's number in its book, from 0, in reading order.
    let ordinal: Int

    /// What the row says: the match in its context, where it is, and the
    /// book's title.
    var spokenLabel: String {
        LibrarySearchWording.matchLabel(context: match.contextSnippet, location: match.locationTitle, bookTitle: book.title)
    }
}

/// One book's part of the list: its heading, the matches shown, and what
/// follows them.
struct LibrarySearchSection: Identifiable, Equatable, Sendable {
    /// What the last row under a book's matches offers.
    enum More: Equatable, Sendable {
        /// Nothing: every match is shown.
        case nothing
        /// Show All: the book has more matches than the list shows.
        case showAll
        /// A note: the book has more matches than even Show All lists.
        case beyondShowAll
    }

    /// The book's ID.
    var id: UUID { group.id }
    /// The book's group.
    let group: LibrarySearchGroup
    /// The matches shown, in reading order.
    let rows: [LibrarySearchMatchRow]
    /// What follows them.
    let more: More
}

// MARK: - The Model

/// Runs Search Library's searches (LIBRARY-SEARCH-RESEARCH-2026-11-13.md): it
/// waits for typing to pause, runs each search off the main actor on the
/// engine's own threads, cancels a search as soon as a newer query or option
/// makes it obsolete, and publishes the results in batches while the search
/// runs, a status line, and one VoiceOver announcement when the search ends.
///
/// The app keeps one model (`shared`), so the query, its options, and its
/// results stay while the window is closed and are there when it opens again.
@MainActor
final class LibrarySearchModel: ObservableObject {
    /// Runs one search of `books`: the engine in the app, a fake in tests.
    /// Called on a search thread; returns once the search has ended.
    typealias Runner = @Sendable (
        _ query: String,
        _ options: TextSearchOptions,
        _ books: [LibrarySearchBook],
        _ limits: LibrarySearchLimits,
        _ isCancelled: @escaping @Sendable () -> Bool,
        _ report: @escaping @Sendable (LibrarySearchBookResult?, LibrarySearchTally) -> Void
    ) -> LibrarySearchOutcome

    /// What the status line says.
    enum Status: Equatable {
        /// Nothing is typed.
        case idle
        /// A search runs; the tally says how far it has got.
        case searching(LibrarySearchTally)
        /// The search finished; the text says what it found.
        case finished(String)
        /// The query is not a valid regular expression.
        case invalidPattern(String)
        /// No book of the library has a text to search.
        case noBooks

        /// The status line's text, which VoiceOver also announces when a
        /// search ends.
        var text: String {
            switch self {
            case .idle:
                return LibrarySearchWording.idle
            case .searching(let tally):
                return tally.booksDone == 0
                    ? LibrarySearchWording.searching(books: tally.booksGiven)
                    : LibrarySearchWording.searched(tally.booksDone, of: tally.booksGiven)
            case .finished(let text):
                return text
            case .invalidPattern(let reason):
                return LibrarySearchWording.invalidPattern(reason)
            case .noBooks:
                return LibrarySearchWording.noBooks
            }
        }

        /// Whether the status reports a problem with the query. The text
        /// says so in words; the status line also shows it in red.
        var isError: Bool {
            if case .invalidPattern = self { return true }
            return false
        }

        /// Whether a search is under way.
        var isSearching: Bool {
            if case .searching = self { return true }
            return false
        }
    }

    // MARK: Limits of the List

    /// How many of a book's matches the list shows until Show All.
    static let shownPerBook = 20
    /// How many matches the list shows in all, Show All's aside, so a word
    /// on every page lists no more than VoiceOver can be taken through.
    static let shownInAll = 1_000
    /// How long typing must pause before a search starts.
    static let debounceInterval: Duration = .milliseconds(300)
    /// How often results reach the list while a search runs.
    static let publishInterval: Duration = .milliseconds(150)

    // MARK: The Search

    /// The search text, bound to the search field. Every change starts over.
    @Published var query = "" {
        didSet { if query != oldValue { restartSearch() } }
    }

    /// Whether case must match, bound to the Match Case checkbox; off by
    /// default. Every change starts over.
    @Published var matchCase = false {
        didSet { if matchCase != oldValue { restartSearch() } }
    }

    /// Whether the query is a regular expression, bound to the Regular
    /// Expression checkbox; off by default. Every change starts over.
    @Published var useRegex = false {
        didSet { if useRegex != oldValue { restartSearch() } }
    }

    /// The options the next search runs with: the two checkboxes.
    var options: TextSearchOptions {
        TextSearchOptions(matchCase: matchCase, isRegularExpression: useRegex)
    }

    /// Each book's matches from the latest search, in the order of the books
    /// searched. A newer search's results replace them as they come, so rows
    /// do not vanish at every keystroke.
    @Published private(set) var groups: [LibrarySearchGroup] = []

    /// What the status line says.
    @Published private(set) var status: Status = .idle

    /// Counts restarts. Each search remembers the generation it began in and
    /// publishes only while that is still current, so a stale search can
    /// never replace a newer one's results, even one that finished despite
    /// being cancelled.
    private(set) var generation = 0

    /// The pending or running search, if any. Tests await it.
    private(set) var searchTask: Task<Void, Never>?

    /// The running Show All search, if any. Tests await it.
    private(set) var showAllTask: Task<Void, Never>?

    /// The books a search reads, asked as each search starts.
    private let books: @MainActor () -> [LibrarySearchBook]
    /// Runs a search.
    private let runner: Runner
    /// Speaks a finished search's status through VoiceOver.
    private let announce: @MainActor (String) -> Void
    /// How long typing must pause.
    private let debounceInterval: Duration
    /// The queue each search's coordinator runs on, below the main thread.
    private let queue = DispatchQueue(label: "com.textmouth.library-search", qos: .userInitiated)

    /// A model reading `books` as each search starts.
    /// - Parameters:
    ///   - books: The books to search, in the order they are listed.
    ///   - runner: Runs a search; the engine by default.
    ///   - debounceInterval: How long typing must pause before a search.
    ///   - announce: Speaks a finished search's status.
    init(
        books: @escaping @MainActor () -> [LibrarySearchBook],
        runner: @escaping Runner = LibrarySearchModel.engineRunner(store: .shared),
        debounceInterval: Duration = LibrarySearchModel.debounceInterval,
        announce: @escaping @MainActor (String) -> Void
    ) {
        self.books = books
        self.runner = runner
        self.debounceInterval = debounceInterval
        self.announce = announce
    }

    /// A search left running when the model goes has no one to report to.
    deinit {
        searchTask?.cancel()
        showAllTask?.cancel()
    }

    /// The engine as a runner, reading and keeping search texts in `store`.
    nonisolated static func engineRunner(store: LibrarySearchTextStore) -> Runner {
        { query, options, books, limits, isCancelled, report in
            LibrarySearchEngine.search(
                query: query, options: options, in: books, store: store,
                limits: limits, isCancelled: isCancelled, report: report
            )
        }
    }

    // MARK: Starting and Stopping

    /// Stops any pending or running search without publishing anything more.
    func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        showAllTask?.cancel()
        showAllTask = nil
        generation += 1
    }

    /// Searches again for the current query and options, as an edit does:
    /// after the library changed, or to try again.
    func searchAgain() {
        restartSearch()
    }

    /// Start over for the current query: cancel whatever search is pending
    /// or running, then, unless the query is empty, search again once typing
    /// pauses.
    private func restartSearch() {
        cancelSearch()
        guard !query.isEmpty else {
            // Nothing to search for: clear at once.
            groups = []
            status = .idle
            return
        }
        let generation = generation
        let query = query
        let options = options
        status = .searching(LibrarySearchTally())
        let debounceInterval = debounceInterval
        searchTask = Task { [weak self] in
            do {
                // The debounce: the next edit cancels this task during the
                // sleep, so steady typing runs one search for the final text.
                try await Task.sleep(for: debounceInterval)
            } catch {
                return
            }
            await self?.start(query: query, options: options, generation: generation)
        }
    }

    /// Reads the books to search, as the library holds them now, and runs
    /// the search of `generation`, unless the library has no book to search.
    private func start(query: String, options: TextSearchOptions, generation: Int) async {
        guard generation == self.generation else { return }
        let books = books()
        guard !books.isEmpty else {
            groups = []
            status = .noBooks
            searchTask = nil
            announce(status.text)
            return
        }
        status = .searching(LibrarySearchTally(booksGiven: books.count))
        await run(query: query, options: options, books: books, generation: generation)
    }

    /// Runs the search of `books` for `query`, publishing what it finds in
    /// batches while it runs, and its outcome once it ends, while
    /// `generation` is still the current one.
    private func run(query: String, options: TextSearchOptions, books: [LibrarySearchBook], generation: Int) async {
        let inbox = LibrarySearchInbox()
        let flag = LibrarySearchCancellation()
        let runner = runner
        let queue = queue
        // Publishes while the search runs, until it ends.
        let publisher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.publishInterval)
                guard !Task.isCancelled else { return }
                self?.publish(inbox.take(), generation: generation)
            }
        }
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<LibrarySearchOutcome, Never>) in
                queue.async {
                    let outcome = runner(query, options, books, .library, { flag.isCancelled }, { result, tally in
                        inbox.add(result, tally)
                    })
                    continuation.resume(returning: outcome)
                }
            }
        } onCancel: {
            flag.cancel()
        }
        publisher.cancel()
        finish(outcome, last: inbox.take(), generation: generation)
    }

    /// What a search has found since the last batch: its new books' results
    /// and its latest tally.
    struct Batch: Sendable {
        var results: [LibrarySearchBookResult] = []
        var tally: LibrarySearchTally?
        /// Whether this is the search's first batch to reach the list.
        var isFirst = false
    }

    /// Shows `batch`, the newest results of the search of `generation`,
    /// when it is still current: the first batch replaces the older
    /// search's results, and each adds its books in their order.
    private func publish(_ batch: Batch, generation: Int) {
        guard generation == self.generation else { return }
        if batch.isFirst {
            groups = []
        }
        if !batch.results.isEmpty {
            groups = Self.merged(groups, adding: batch.results.map(LibrarySearchGroup.init))
        }
        if let tally = batch.tally, status.isSearching {
            status = .searching(tally)
        }
    }

    /// Shows the outcome of the search of `generation`, with `last`, what it
    /// found after the last batch, and says it once, when still current.
    private func finish(_ outcome: LibrarySearchOutcome, last: Batch, generation: Int) {
        guard generation == self.generation else { return }
        searchTask = nil
        switch outcome {
        case .finished(let tally):
            // The last batch, which replaces an older search's rows when it
            // is the first; a search that found nothing leaves none.
            publish(last, generation: generation)
            if tally.booksWithMatches == 0 { groups = [] }
            status = .finished(Self.finishedText(tally: tally, sections: sections))
        case .invalidPattern(let reason):
            groups = []
            status = .invalidPattern(reason)
        case .cancelled:
            return
        }
        announce(status.text)
    }

    /// `groups` with `added` put in their places, in the order of the books
    /// searched; a book already listed is replaced.
    static func merged(_ groups: [LibrarySearchGroup], adding added: [LibrarySearchGroup]) -> [LibrarySearchGroup] {
        var byID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for group in added {
            byID[group.id] = group
        }
        return byID.values.sorted { $0.order < $1.order }
    }

    // MARK: The Status

    /// A finished search's status: what it found, what the list leaves out,
    /// and which books it did not search.
    static func finishedText(tally: LibrarySearchTally, sections: [LibrarySearchSection]) -> String {
        let found = LibrarySearchWording.found(
            matches: tally.matches, books: tally.booksWithMatches, isLowerBound: tally.booksPastTheLimit > 0
        )
        var notes: [String] = []
        let shown = sections.reduce(0) { $0 + $1.rows.count }
        let anyCut = sections.contains { $0.more != .nothing }
        if tally.matches > 0, anyCut {
            let inAll = shown >= shownInAll ? shownInAll : nil
            notes.append(LibrarySearchWording.showing(perBook: shownPerBook, inAll: inAll))
        }
        if tally.booksInCloud > 0 {
            notes.append(LibrarySearchWording.inCloud(tally.booksInCloud))
        }
        if tally.booksUnreadable > 0 {
            notes.append(LibrarySearchWording.unreadable(tally.booksUnreadable))
        }
        return LibrarySearchWording.finished(found: found, notes: notes)
    }

    // MARK: The List

    /// What the window lists: each book's heading, the first of its matches,
    /// up to `shownPerBook` each and `shownInAll` in all, except a book whose
    /// matches the listener asked for in full, and what follows them.
    var sections: [LibrarySearchSection] {
        var budget = Self.shownInAll
        return groups.map { group in
            let wanted = group.showsAll ? group.matches.count : min(Self.shownPerBook, budget)
            let shown = Array(group.matches.prefix(max(0, wanted)))
            if !group.showsAll { budget -= shown.count }
            let rows = shown.enumerated().map { LibrarySearchMatchRow(book: group.book, match: $1, ordinal: $0) }
            let more: LibrarySearchSection.More
            if group.showsAll {
                more = group.countReachedLimit || group.matchCount > shown.count ? .beyondShowAll : .nothing
            } else {
                more = group.countReachedLimit || group.matchCount > shown.count ? .showAll : .nothing
            }
            return LibrarySearchSection(group: group, rows: rows, more: more)
        }
    }

    // MARK: Show All

    /// Lists up to Search in Book's limit of the matches in the book
    /// `bookID`, searching that book again with the current query and
    /// options, and says how many it lists.
    func showAllMatches(in bookID: UUID) {
        guard let group = groups.first(where: { $0.id == bookID }) else { return }
        let generation = generation
        let query = query
        let options = options
        let runner = runner
        let queue = queue
        showAllTask?.cancel()
        let flag = LibrarySearchCancellation()
        showAllTask = Task { [weak self] in
            let outcome: (LibrarySearchOutcome, LibrarySearchBookResult?) = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    queue.async {
                        let found = OSAllocatedUnfairLock<LibrarySearchBookResult?>(initialState: nil)
                        let outcome = runner(query, options, [group.book], .wholeBook, { flag.isCancelled }, { result, _ in
                            found.withLock { $0 = result }
                        })
                        continuation.resume(returning: (outcome, found.withLock { $0 }))
                    }
                }
            } onCancel: {
                flag.cancel()
            }
            self?.finishShowAll(of: group, outcome: outcome.0, result: outcome.1, generation: generation)
        }
    }

    /// Lists the book's matches a Show All search found, when the search
    /// they belong to is still current.
    private func finishShowAll(
        of group: LibrarySearchGroup,
        outcome: LibrarySearchOutcome,
        result: LibrarySearchBookResult?,
        generation: Int
    ) {
        guard generation == self.generation, case .finished = outcome,
              let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        showAllTask = nil
        var updated = groups[index]
        if let result {
            updated.matches = result.matches
            updated.matchCount = max(updated.matchCount, result.matchCount)
            updated.countReachedLimit = updated.countReachedLimit || result.countReachedLimit
        }
        updated.showsAll = true
        groups[index] = updated
        announce(LibrarySearchWording.listedAll(updated.matches.count, bookTitle: group.book.title))
    }

    // MARK: The Books of a Library

    /// The books of `library` a search reads: every book of the library's
    /// own that has a package, where its content.md is, in the order of
    /// their titles, as the Library sorts them by title. Feed items are left
    /// out, as the Library's lists leave them out.
    static func searchableBooks(in library: Library) -> [LibrarySearchBook] {
        let books = library.libraryBooks.filter { !$0.tmbDirectoryName.isEmpty }
        return LibraryBookSorter.sorted(books, by: .title, ascending: true).map(LibrarySearchBook.init)
    }
}

// MARK: - Between the Search and the Main Actor

/// What a running search has found and not yet published: the engine adds
/// to it from its threads, and the model takes it on the main actor.
final class LibrarySearchInbox: Sendable {
    /// The results waiting, the latest tally, and whether anything was taken.
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// The inbox's contents.
    private struct State: Sendable {
        var results: [LibrarySearchBookResult] = []
        var tally: LibrarySearchTally?
        var taken = false
    }

    /// Adds `result`, when the book had matches, and `tally`, kept when it
    /// has counted more books than the one kept: tallies are made in order
    /// under the engine's lock but may arrive out of order.
    func add(_ result: LibrarySearchBookResult?, _ tally: LibrarySearchTally) {
        state.withLock { state in
            if let result { state.results.append(result) }
            if (state.tally?.booksDone ?? -1) < tally.booksDone { state.tally = tally }
        }
    }

    /// Takes everything waiting, as one batch.
    func take() -> LibrarySearchModel.Batch {
        state.withLock { state in
            let batch = LibrarySearchModel.Batch(
                results: state.results,
                tally: state.tally,
                isFirst: !state.taken && (!state.results.isEmpty || state.tally != nil)
            )
            if batch.isFirst { state.taken = true }
            state.results = []
            return batch
        }
    }
}

/// A search's cancel, which the engine asks from its threads.
final class LibrarySearchCancellation: Sendable {
    /// Whether the search was cancelled.
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    /// Whether the search was cancelled.
    var isCancelled: Bool {
        cancelled.withLock { $0 }
    }

    /// Cancels the search.
    func cancel() {
        cancelled.withLock { $0 = true }
    }
}
