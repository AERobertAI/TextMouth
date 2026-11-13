import Foundation
import os
import XCTest
@testable import TextMouth

// MARK: - Fixtures

/// A made-up book for a fake search to report on. Its content.md is a path
/// nothing reads: the fake runners never open a file.
private func makeBook(_ number: Int, title: String? = nil) -> LibrarySearchBook {
    LibrarySearchBook(
        id: UUID(),
        title: title ?? "Book \(number)",
        author: "Author \(number)",
        contentURL: URL(fileURLWithPath: "/nonexistent/LibrarySearchModelTests/\(number)/content.md"),
        packageURL: nil,
        isAudiobook: false
    )
}

/// `count` made-up matches in reading order, each with its own offset (so
/// each has its own ID) and `query` as the text that matched.
private func makeMatches(_ count: Int, matching query: String = "needle") -> [BookSearchResult] {
    (0..<count).map { index in
        BookSearchResult(
            chapterIndex: 0,
            characterOffset: index * 10,
            matchedText: query,
            contextSnippet: "the \(query) number \(index)",
            globalOffset: index * 10
        )
    }
}

/// What a search reports for `book`: `kept` matches in hand out of `count`
/// counted (by default all of them), the count stopped at its limit when
/// `reachedLimit` says so.
private func makeResult(
    _ book: LibrarySearchBook,
    order: Int,
    kept: Int,
    count: Int? = nil,
    reachedLimit: Bool = false,
    query: String = "needle"
) -> LibrarySearchBookResult {
    LibrarySearchBookResult(
        book: book,
        order: order,
        matchCount: count ?? kept,
        countReachedLimit: reachedLimit,
        matches: makeMatches(kept, matching: query)
    )
}

/// A search's tally with only the counts a test names.
private func makeTally(
    given: Int,
    searched: Int = 0,
    withMatches: Int = 0,
    matches: Int = 0,
    pastTheLimit: Int = 0,
    inCloud: Int = 0,
    unreadable: Int = 0
) -> LibrarySearchTally {
    var tally = LibrarySearchTally()
    tally.booksGiven = given
    tally.booksSearched = searched
    tally.booksWithMatches = withMatches
    tally.matches = matches
    tally.booksPastTheLimit = pastTheLimit
    tally.booksInCloud = inCloud
    tally.booksUnreadable = unreadable
    return tally
}

/// Plays a whole made-up search inside a fake runner: reports each of
/// `results`, in the order given, then every other book that was searched
/// and held no match, each with the tally so far, and returns the finished
/// outcome. `inCloud` and `unreadable` books are counted as passed over.
private func playOut(
    _ results: [LibrarySearchBookResult],
    given: Int,
    inCloud: Int = 0,
    unreadable: Int = 0,
    report: @Sendable (LibrarySearchBookResult?, LibrarySearchTally) -> Void
) -> LibrarySearchOutcome {
    var tally = makeTally(given: given, inCloud: inCloud, unreadable: unreadable)
    for result in results {
        tally.booksSearched += 1
        tally.matches += result.matchCount
        if result.matchCount > 0 { tally.booksWithMatches += 1 }
        if result.countReachedLimit { tally.booksPastTheLimit += 1 }
        report(result, tally)
    }
    // The books searched that held no match report nothing but the tally.
    while tally.booksDone < given {
        tally.booksSearched += 1
        report(nil, tally)
    }
    return .finished(tally)
}

/// What a fake runner was asked, and whether it was told to stop. Fake
/// runners run on a search thread while tests read the log on the main
/// actor, so every access takes the lock.
private final class RunLog: Sendable {
    /// One search a fake runner received.
    struct Call: Equatable, Sendable {
        let query: String
        let options: TextSearchOptions
        let bookIDs: [UUID]
        let limits: LibrarySearchLimits
        /// Whether the runner ran on the main thread; it never should.
        let ranOnMainThread: Bool
    }

    /// The log's contents.
    private struct State: Sendable {
        var calls: [Call] = []
        var cancellations: [Bool] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Notes a search starting. Call from inside the fake runner.
    func record(
        query: String, options: TextSearchOptions, books: [LibrarySearchBook], limits: LibrarySearchLimits
    ) {
        let call = Call(
            query: query, options: options, bookIDs: books.map(\.id), limits: limits,
            ranOnMainThread: Thread.isMainThread
        )
        state.withLock { $0.calls.append(call) }
    }

    /// Notes whether a fake search was told to stop.
    func recordCancellation(_ wasCancelled: Bool) {
        state.withLock { $0.cancellations.append(wasCancelled) }
    }

    var calls: [Call] { state.withLock { $0.calls } }
    var queries: [String] { calls.map(\.query) }
    var cancellations: [Bool] { state.withLock { $0.cancellations } }
}

/// Waits, on a fake runner's search thread, until `condition` holds or
/// `timeout` seconds pass; false when it never held, which fails the test.
private func waitOnSearchThread(timeout: TimeInterval = 10, _ condition: @Sendable () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { return false }
        Thread.sleep(forTimeInterval: 0.002)
    }
    return true
}

/// Waits, on a fake runner's search thread, for the test to signal `gate`,
/// for at most `timeout` seconds, so no search thread is ever left blocked.
private func waitForGate(_ gate: DispatchSemaphore, timeout: TimeInterval = 10) {
    _ = gate.wait(timeout: .now() + timeout)
}

/// Records what a model announces through VoiceOver.
@MainActor
private final class AnnouncementLog {
    private(set) var messages: [String] = []

    func record(_ message: String) {
        messages.append(message)
    }
}

/// The library's books as the model asks for them, which a test changes
/// between searches.
@MainActor
private final class BookList {
    var books: [LibrarySearchBook]

    init(_ books: [LibrarySearchBook]) {
        self.books = books
    }
}

/// Records what the model opens.
@MainActor
private final class OpenLog {
    /// One opening the model asked for.
    struct Opening: Equatable {
        let rowID: String
        let bookID: UUID
        let query: String
        let options: TextSearchOptions
    }

    private(set) var openings: [Opening] = []

    func record(_ row: LibrarySearchMatchRow, _ query: String, _ options: TextSearchOptions) {
        openings.append(Opening(rowID: row.id, bookID: row.book.id, query: query, options: options))
    }
}

// MARK: - The Model

/// Debouncing, cancellation, batching, the status line, the list's limits,
/// Show All, and opening a match, in Search Library's model, with fake
/// runners that report results made up in the test from a search thread.
@MainActor
final class LibrarySearchModelTests: XCTestCase {
    /// Keeps tests fast; tests about debouncing itself choose their own.
    private let quickDebounce: Duration = .milliseconds(10)

    /// A model over `list`, announcing into `announcements` and opening into
    /// `openings`, whose searches `runner` makes up.
    private func makeModel(
        _ list: BookList,
        _ announcements: AnnouncementLog,
        openings: OpenLog = OpenLog(),
        debounce: Duration? = nil,
        runner: @escaping LibrarySearchModel.Runner
    ) -> LibrarySearchModel {
        LibrarySearchModel(
            books: { list.books },
            runner: runner,
            opener: openings.record,
            debounceInterval: debounce ?? quickDebounce,
            announce: announcements.record
        )
    }

    /// Types `query` and waits for the search it starts to end.
    private func searchAndWait(_ model: LibrarySearchModel, _ query: String = "needle") async {
        model.query = query
        await model.searchTask?.value
    }

    /// Waits up to `timeout` seconds for `condition` to hold on the main
    /// actor; false when it never did.
    private func eventually(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    // MARK: Debounce

    /// Steady typing runs one search, for the final text, and announces it
    /// once, however many edits it took.
    func testSteadyTypingRunsOneSearchForTheFinalText() async throws {
        let log = RunLog()
        let announcements = AnnouncementLog()
        let list = BookList([makeBook(0)])
        // Generous beside the pauses between edits, so a busy machine cannot
        // split the burst.
        let model = makeModel(list, announcements, debounce: .milliseconds(800)) { query, options, books, limits, _, report in
            log.record(query: query, options: options, books: books, limits: limits)
            return playOut([], given: books.count, report: report)
        }

        for query in ["f", "fe", "fer", "ferr", "ferry"] {
            model.query = query
            try await Task.sleep(for: .milliseconds(5))
        }
        await model.searchTask?.value

        XCTAssertEqual(log.queries, ["ferry"], "Five edits should run one search, for the final text")
        XCTAssertEqual(log.calls.first?.limits, .library, "A search of the library keeps the library's limits")
        XCTAssertEqual(log.calls.first?.ranOnMainThread, false, "A search must run off the main thread")
        XCTAssertEqual(model.status, .finished("No matches"), "Actual: \(model.status)")
        XCTAssertEqual(announcements.messages, ["No matches"], "Actual announcements: \(announcements.messages)")
    }

    /// Edits separated by more than the debounce interval each get a search.
    func testEditsAfterAPauseSearchAgain() async {
        let log = RunLog()
        let list = BookList([makeBook(0)])
        let model = makeModel(list, AnnouncementLog()) { query, options, books, limits, _, report in
            log.record(query: query, options: options, books: books, limits: limits)
            return playOut([], given: books.count, report: report)
        }

        await searchAndWait(model, "ferry")
        await searchAndWait(model, "ferryman")

        XCTAssertEqual(log.queries, ["ferry", "ferryman"])
    }

    /// The two checkboxes restart the search and reach the runner as its
    /// options.
    func testTheCheckboxesRestartTheSearchWithTheirOptions() async {
        let log = RunLog()
        let list = BookList([makeBook(0)])
        let model = makeModel(list, AnnouncementLog()) { query, options, books, limits, _, report in
            log.record(query: query, options: options, books: books, limits: limits)
            return playOut([], given: books.count, report: report)
        }

        await searchAndWait(model, "Ferry")
        model.matchCase = true
        await model.searchTask?.value
        model.useRegex = true
        await model.searchTask?.value

        XCTAssertEqual(log.queries, ["Ferry", "Ferry", "Ferry"])
        XCTAssertEqual(log.calls.map(\.options), [
            TextSearchOptions(matchCase: false, isRegularExpression: false),
            TextSearchOptions(matchCase: true, isRegularExpression: false),
            TextSearchOptions(matchCase: true, isRegularExpression: true),
        ])
    }

    // MARK: Cancellation

    /// A newer query cancels the older search, whose results, reported after
    /// the newer query and even after the newer search finished, never reach
    /// the list; the newer search's results replace the older's.
    func testNewQueryCancelsTheOldSearchWhoseLateResultsNeverPublish() async throws {
        let log = RunLog()
        let announcements = AnnouncementLog()
        let book0 = makeBook(0)
        let book1 = makeBook(1)
        let books = [book0, book1]
        let list = BookList(books)
        let oldResult = makeResult(book0, order: 0, kept: 2, query: "old")
        let lateOldResult = makeResult(book1, order: 1, kept: 4, query: "old")
        let newResult = makeResult(book1, order: 1, kept: 3, query: "new")
        let releaseOld = DispatchSemaphore(value: 0)
        // Never leave a search thread blocked, whatever fails below.
        defer { releaseOld.signal() }

        let model = makeModel(list, announcements) { query, options, books, limits, isCancelled, report in
            log.record(query: query, options: options, books: books, limits: limits)
            guard query == "old" else {
                return playOut([newResult], given: books.count, report: report)
            }
            // The old search reports a first book, which reaches the list, then
            // waits to be told to stop, as a runaway pattern would, and ends
            // late, reporting one more book after the new search has ended.
            report(oldResult, makeTally(given: 2, searched: 1, withMatches: 1, matches: 2))
            log.recordCancellation(waitOnSearchThread(isCancelled))
            waitForGate(releaseOld)
            report(lateOldResult, makeTally(given: 2, searched: 2, withMatches: 2, matches: 6))
            return .finished(makeTally(given: 2, searched: 2, withMatches: 2, matches: 6))
        }

        model.query = "old"
        let oldShown = await eventually { model.groups.map(\.order) == [0] }
        XCTAssertTrue(oldShown, "The old search's first book should reach the list; groups: \(model.groups.map(\.order))")
        let oldSearch = try XCTUnwrap(model.searchTask)

        model.query = "new"
        await model.searchTask?.value
        XCTAssertEqual(model.groups.map(\.order), [1], "The new search's results should replace the old ones")
        XCTAssertEqual(model.groups.first?.matches.map(\.matchedText), ["new", "new", "new"])

        // Let the old search end after the new one has been published.
        releaseOld.signal()
        await oldSearch.value

        XCTAssertEqual(log.queries, ["old", "new"])
        XCTAssertEqual(log.cancellations, [true], "The old search should have been told to stop")
        XCTAssertEqual(model.groups.map(\.order), [1], "The old search's late book must not join the list")
        XCTAssertEqual(model.groups.first?.matches.map(\.matchedText), ["new", "new", "new"])
        XCTAssertEqual(model.foundQuery, "new", "The list was found by the new query")
        XCTAssertEqual(model.status, .finished("3 matches in 1 book"), "Actual: \(model.status)")
        XCTAssertEqual(announcements.messages, ["3 matches in 1 book"], "Only the new search is announced")
    }

    /// Stopping the search, as closing the window does, publishes and
    /// announces nothing, even from a search that finishes anyway.
    func testCancelledSearchPublishesAndAnnouncesNothing() async throws {
        let log = RunLog()
        let announcements = AnnouncementLog()
        let book = makeBook(0)
        let list = BookList([book])
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }

        let model = makeModel(list, announcements) { query, options, books, limits, isCancelled, report in
            log.record(query: query, options: options, books: books, limits: limits)
            log.recordCancellation(waitOnSearchThread(isCancelled))
            waitForGate(release)
            return playOut([makeResult(book, order: 0, kept: 1)], given: books.count, report: report)
        }

        model.query = "needle"
        let started = await eventually { log.queries == ["needle"] }
        XCTAssertTrue(started, "The search should have started; calls: \(log.queries)")
        let search = try XCTUnwrap(model.searchTask)
        let generationBefore = model.generation
        model.cancelSearch()
        release.signal()
        await search.value

        XCTAssertEqual(log.cancellations, [true], "The runner should have been told to stop")
        XCTAssertGreaterThan(model.generation, generationBefore, "Cancelling starts a new generation")
        XCTAssertEqual(model.groups, [], "A cancelled search lists nothing")
        XCTAssertEqual(announcements.messages, [], "A cancelled search announces nothing")
        XCTAssertNil(model.searchTask)
    }

    /// A runner that reports the search cancelled makes no announcement and
    /// lists nothing, even when the model did not cancel it.
    func testCancelledOutcomeAnnouncesNothing() async {
        let announcements = AnnouncementLog()
        let list = BookList([makeBook(0)])
        let model = makeModel(list, announcements) { _, _, _, _, _, _ in .cancelled }

        await searchAndWait(model)

        XCTAssertEqual(announcements.messages, [])
        XCTAssertEqual(model.groups, [])
    }

    // MARK: Stopping

    /// Stop keeps what a running search has found: it lists those books,
    /// says "Stopped after 1 of 3 books:" with what was found, announces
    /// that once, tells the runner to stop, and lists nothing the runner
    /// reports afterwards.
    func testStopKeepsWhatWasFoundAndIgnoresWhatComesAfter() async throws {
        let log = RunLog()
        let announcements = AnnouncementLog()
        let book0 = makeBook(0)
        let book1 = makeBook(1)
        let book2 = makeBook(2)
        let books = [book0, book1, book2]
        let list = BookList(books)
        let firstResult = makeResult(book2, order: 2, kept: 4)
        let lateResult = makeResult(book0, order: 0, kept: 5)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }

        let model = makeModel(list, announcements) { query, options, books, limits, isCancelled, report in
            log.record(query: query, options: options, books: books, limits: limits)
            // One book is found, then the search runs on, slowly, until told
            // to stop, and reports one more book and finishes anyway.
            report(firstResult, makeTally(given: 3, searched: 1, withMatches: 1, matches: 4))
            log.recordCancellation(waitOnSearchThread(isCancelled))
            waitForGate(release)
            report(lateResult, makeTally(given: 3, searched: 2, withMatches: 2, matches: 9))
            return .finished(makeTally(given: 3, searched: 3, withMatches: 2, matches: 9))
        }

        model.query = "needle"
        let started = await eventually { log.queries == ["needle"] }
        XCTAssertTrue(started, "The search should have started; calls: \(log.queries)")
        let search = try XCTUnwrap(model.searchTask)

        model.stopSearch()

        XCTAssertEqual(model.groups.map(\.order), [2], "What was found so far is listed; actual: \(model.groups.map(\.order))")
        XCTAssertEqual(
            model.status, .finished("Stopped after 1 of 3 books: 4 matches in 1 book"), "Actual: \(model.status)"
        )
        XCTAssertEqual(announcements.messages, ["Stopped after 1 of 3 books: 4 matches in 1 book"], "Announced once; actual: \(announcements.messages)")
        let cancelled = await eventually { log.cancellations == [true] }
        XCTAssertTrue(cancelled, "The runner should be told to stop; cancellations: \(log.cancellations)")
        XCTAssertFalse(model.status.isSearching)

        // The runner ends late, reporting one more book; none of it counts.
        release.signal()
        await search.value
        XCTAssertEqual(model.groups.map(\.order), [2], "Nothing reported after Stop is listed")
        XCTAssertEqual(
            model.status, .finished("Stopped after 1 of 3 books: 4 matches in 1 book"), "Actual: \(model.status)"
        )
        XCTAssertEqual(announcements.messages.count, 1, "Still one announcement; actual: \(announcements.messages)")
    }

    /// Stop does nothing while typing pauses, before the runner is called,
    /// and when nothing is typed.
    func testStopDoesNothingBeforeTheSearchRuns() async {
        let log = RunLog()
        let announcements = AnnouncementLog()
        let list = BookList([makeBook(0)])
        let model = makeModel(list, announcements, debounce: .seconds(30)) { query, options, books, limits, _, report in
            log.record(query: query, options: options, books: books, limits: limits)
            return playOut([], given: books.count, report: report)
        }

        model.stopSearch()
        XCTAssertEqual(model.status, .idle, "Nothing is typed, so Stop changes nothing")

        model.query = "needle"
        let statusBefore = model.status
        model.stopSearch()

        XCTAssertEqual(model.status, statusBefore, "Stop changes nothing while typing pauses; actual: \(model.status)")
        XCTAssertNotNil(model.searchTask, "The pending search stays pending")
        XCTAssertEqual(announcements.messages, [])
        XCTAssertEqual(log.queries, [])
        model.cancelSearch()
    }

    // MARK: Batches

    /// Results reach the list in batches while the runner is still running,
    /// before it returns, and in the order of the books' `order`, whatever
    /// order they were reported in.
    func testResultsArriveInBatchesInTheBooksOrder() async throws {
        let announcements = AnnouncementLog()
        let book0 = makeBook(0)
        let book1 = makeBook(1)
        let book2 = makeBook(2)
        let books = [book0, book1, book2]
        let list = BookList(books)
        let result0 = makeResult(book0, order: 0, kept: 2)
        let result1 = makeResult(book1, order: 1, kept: 2)
        let result2 = makeResult(book2, order: 2, kept: 2)
        let afterFirstBatch = DispatchSemaphore(value: 0)
        let afterSecondBatch = DispatchSemaphore(value: 0)
        defer {
            afterFirstBatch.signal()
            afterSecondBatch.signal()
        }

        let model = makeModel(list, announcements) { _, _, _, _, _, report in
            // The last book finishes first, and is listed last.
            report(result2, makeTally(given: 3, searched: 1, withMatches: 1, matches: 2))
            waitForGate(afterFirstBatch)
            report(result1, makeTally(given: 3, searched: 2, withMatches: 2, matches: 4))
            report(result0, makeTally(given: 3, searched: 3, withMatches: 3, matches: 6))
            waitForGate(afterSecondBatch)
            return .finished(makeTally(given: 3, searched: 3, withMatches: 3, matches: 6))
        }

        model.query = "needle"
        let search = try XCTUnwrap(model.searchTask)
        let firstShown = await eventually { model.groups.map(\.order) == [2] }
        XCTAssertTrue(firstShown, "The first batch should reach the list while the runner runs; groups: \(model.groups.map(\.order))")
        XCTAssertTrue(model.status.isSearching, "The search is still running; status: \(model.status)")
        XCTAssertEqual(announcements.messages, [], "Nothing is announced until the search ends")
        XCTAssertEqual(model.foundQuery, "needle", "The first batch sets the query its rows were found with")

        afterFirstBatch.signal()
        let allShown = await eventually { model.groups.map(\.order) == [0, 1, 2] }
        XCTAssertTrue(allShown, "The second batch should list every book in order; groups: \(model.groups.map(\.order))")
        XCTAssertEqual(model.groups.map(\.book.id), books.map(\.id))
        XCTAssertTrue(model.status.isSearching, "The runner has not returned; status: \(model.status)")
        XCTAssertEqual(announcements.messages, [])

        afterSecondBatch.signal()
        await search.value
        XCTAssertEqual(model.groups.map(\.order), [0, 1, 2])
        XCTAssertEqual(announcements.messages, ["6 matches in 3 books"], "Actual: \(announcements.messages)")
    }

    // MARK: Status

    /// Nothing typed is idle: emptying the field clears the list, stops the
    /// pending search, and runs no search.
    func testEmptyQueryIsIdleAndClearsTheList() async {
        let log = RunLog()
        let announcements = AnnouncementLog()
        let book = makeBook(0)
        let list = BookList([book])
        let model = makeModel(list, announcements) { query, options, books, limits, _, report in
            log.record(query: query, options: options, books: books, limits: limits)
            return playOut([makeResult(book, order: 0, kept: 1)], given: books.count, report: report)
        }
        XCTAssertEqual(model.status, .idle, "A new model is idle")
        XCTAssertEqual(model.status.text, LibrarySearchWording.idle)

        await searchAndWait(model)
        XCTAssertEqual(model.groups.count, 1)
        let announced = announcements.messages

        model.query = ""
        XCTAssertEqual(model.groups, [], "Emptying the field removes the results")
        XCTAssertEqual(model.status, .idle)
        XCTAssertEqual(model.status.text, "Type text to find in every book of the library.")
        XCTAssertNil(model.searchTask)
        XCTAssertEqual(log.queries, ["needle"], "An empty query runs no search")
        XCTAssertEqual(announcements.messages, announced, "Emptying the field announces nothing")
    }

    /// While a search runs the status counts the books: "Searching 3
    /// books…", then "Searched 1 of 3 books…", and when it ends the finished
    /// text is announced exactly once.
    func testStatusCountsTheBooksAndTheFinishedTextIsAnnouncedOnce() async throws {
        let announcements = AnnouncementLog()
        let books = (0..<3).map { makeBook($0) }
        let list = BookList(books)
        let start = DispatchSemaphore(value: 0)
        let afterFirstBook = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)
        defer {
            start.signal()
            afterFirstBook.signal()
            finish.signal()
        }

        let model = makeModel(list, announcements) { _, _, _, _, _, report in
            waitForGate(start)
            report(nil, makeTally(given: 3, searched: 1))
            waitForGate(afterFirstBook)
            report(nil, makeTally(given: 3, searched: 2))
            waitForGate(finish)
            return .finished(makeTally(given: 3, searched: 3))
        }

        model.query = "needle"
        let search = try XCTUnwrap(model.searchTask)
        let searching = await eventually { model.status.text == "Searching 3 books…" }
        XCTAssertTrue(searching, "Before any book is done; status: \(model.status.text)")

        start.signal()
        let searched = await eventually { model.status.text == "Searched 1 of 3 books…" }
        XCTAssertTrue(searched, "After the first book; status: \(model.status.text)")
        XCTAssertEqual(announcements.messages, [], "Progress is not announced")

        afterFirstBook.signal()
        finish.signal()
        await search.value

        XCTAssertEqual(model.status, .finished("No matches"), "Actual: \(model.status)")
        XCTAssertEqual(announcements.messages, ["No matches"], "Exactly one announcement; actual: \(announcements.messages)")
    }

    /// A library with no book to search says so, announces it once, and
    /// runs no search.
    func testNoBooksIsReportedAndRunsNoSearch() async {
        let log = RunLog()
        let announcements = AnnouncementLog()
        let list = BookList([])
        let model = makeModel(list, announcements) { query, options, books, limits, _, report in
            log.record(query: query, options: options, books: books, limits: limits)
            return playOut([], given: books.count, report: report)
        }

        await searchAndWait(model)

        XCTAssertEqual(model.status, .noBooks, "Actual: \(model.status)")
        XCTAssertEqual(model.status.text, "No book in the library has text to search.")
        XCTAssertEqual(announcements.messages, [LibrarySearchWording.noBooks])
        XCTAssertEqual(log.queries, [], "With no book there is nothing to run")
        XCTAssertNil(model.searchTask)
    }

    /// An invalid pattern is the status, in the words Search in Book uses,
    /// announced once; the list is empty and the status is an error.
    func testInvalidPatternIsTheStatus() async {
        let announcements = AnnouncementLog()
        let list = BookList([makeBook(0)])
        let model = makeModel(list, announcements) { _, _, _, _, _, _ in .invalidPattern("missing closing )") }
        model.useRegex = true

        await searchAndWait(model, "caf(")

        XCTAssertEqual(model.status, .invalidPattern("missing closing )"), "Actual: \(model.status)")
        XCTAssertEqual(model.status.text, "Invalid regular expression: missing closing )")
        XCTAssertTrue(model.status.isError)
        XCTAssertEqual(model.groups, [])
        XCTAssertEqual(announcements.messages, ["Invalid regular expression: missing closing )"])
    }

    // MARK: The List's Limits

    /// A book with more matches than a list shows lists the first twenty and
    /// offers Show All; a book with exactly twenty lists them all.
    func testABookShowsTwentyMatchesAndOffersShowAll() async {
        let book0 = makeBook(0)
        let book1 = makeBook(1)
        let books = [book0, book1]
        let list = BookList(books)
        let results = [makeResult(book0, order: 0, kept: 25), makeResult(book1, order: 1, kept: 20)]
        let model = makeModel(list, AnnouncementLog()) { _, _, books, _, _, report in
            playOut(results, given: books.count, report: report)
        }

        await searchAndWait(model)

        let sections = model.sections
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections.first?.rows.count, 20, "Twenty of 25 are shown; actual: \(sections.first?.rows.count ?? -1)")
        XCTAssertEqual(sections.first?.more, .showAll)
        XCTAssertEqual(sections.first?.rows.map(\.ordinal), Array(0..<20), "Rows are numbered from 0 in reading order")
        XCTAssertEqual(sections.last?.rows.count, 20)
        XCTAssertEqual(sections.last?.more, .nothing, "Exactly twenty is the whole list")
        XCTAssertEqual(
            model.status, .finished("45 matches in 2 books; showing up to 20 in each book"), "Actual: \(model.status)"
        )
    }

    /// Sixty books of twenty matches list a thousand in all: the books after
    /// the fiftieth show no rows and offer Show All.
    func testTheListStopsAtAThousandMatchesInAll() async {
        let books = (0..<60).map { makeBook($0) }
        let list = BookList(books)
        let results = books.enumerated().map { makeResult($1, order: $0, kept: 20) }
        let announcements = AnnouncementLog()
        let model = makeModel(list, announcements) { _, _, books, _, _, report in
            // Reported in reverse, so the cap follows the books' order.
            playOut(results.reversed(), given: books.count, report: report)
        }

        await searchAndWait(model)

        let sections = model.sections
        XCTAssertEqual(sections.count, 60)
        XCTAssertEqual(sections.map(\.rows.count).reduce(0, +), 1_000, "A thousand rows in all")
        XCTAssertTrue(sections.prefix(50).allSatisfy { $0.rows.count == 20 && $0.more == .nothing }, "The first fifty list every match")
        XCTAssertTrue(sections.suffix(10).allSatisfy { $0.rows.isEmpty && $0.more == .showAll }, "The last ten list none and offer Show All")
        let expected = "\(1_200.formatted()) matches in 60 books; showing up to 20 in each book, and \(1_000.formatted()) in all"
        XCTAssertEqual(model.status.text, expected, "Actual: \(model.status.text)")
        XCTAssertEqual(announcements.messages, [expected])
    }

    /// A book whose count stopped at its limit offers Show All, however few
    /// matches it kept.
    func testACountThatReachedItsLimitOffersShowAll() async {
        let book = makeBook(0)
        let list = BookList([book])
        let result = makeResult(book, order: 0, kept: 5, reachedLimit: true)
        let model = makeModel(list, AnnouncementLog()) { _, _, books, _, _, report in
            playOut([result], given: books.count, report: report)
        }

        await searchAndWait(model)

        XCTAssertEqual(model.sections.first?.rows.count, 5)
        XCTAssertEqual(model.sections.first?.more, .showAll)
        XCTAssertEqual(
            model.status.text, "More than 5 matches in 1 book; showing up to 20 in each book", "Actual: \(model.status.text)"
        )
    }

    // MARK: Show All

    /// Show All searches that one book again with whole-book limits, lists
    /// every match kept, offers nothing more, and says how many it lists.
    func testShowAllListsEveryMatchKept() async {
        let log = RunLog()
        let announcements = AnnouncementLog()
        let book0 = makeBook(0, title: "The Long Road")
        let book1 = makeBook(1)
        let books = [book0, book1]
        let list = BookList(books)
        let libraryResults = [makeResult(book0, order: 0, kept: 100, count: 150), makeResult(book1, order: 1, kept: 3)]
        let wholeBookResult = makeResult(book0, order: 0, kept: 150)
        let model = makeModel(list, announcements) { query, options, books, limits, _, report in
            log.record(query: query, options: options, books: books, limits: limits)
            guard limits == .wholeBook else {
                return playOut(libraryResults, given: books.count, report: report)
            }
            return playOut([wholeBookResult], given: books.count, report: report)
        }
        model.matchCase = true
        await searchAndWait(model, "needle")
        XCTAssertEqual(model.sections.first?.rows.count, 20)
        XCTAssertEqual(model.sections.first?.more, .showAll)

        model.showAllMatches(in: book0.id)
        await model.showAllTask?.value

        let calls = log.calls
        XCTAssertEqual(calls.count, 2, "One library search and one Show All; actual: \(calls.count)")
        XCTAssertEqual(calls.last?.limits, .wholeBook)
        XCTAssertEqual(calls.last?.bookIDs, [book0.id], "Show All searches only that book")
        XCTAssertEqual(calls.last?.query, "needle")
        XCTAssertEqual(calls.last?.options, TextSearchOptions(matchCase: true, isRegularExpression: false))
        XCTAssertEqual(model.sections.first?.rows.count, 150, "Every match kept is listed")
        XCTAssertEqual(model.sections.first?.more, .nothing)
        XCTAssertEqual(model.sections.last?.rows.count, 3, "The other book is unchanged")
        XCTAssertEqual(announcements.messages.last, LibrarySearchWording.listedAll(150, bookTitle: "The Long Road"))
        XCTAssertEqual(announcements.messages.last, "Listing 150 matches in The Long Road")
        XCTAssertNil(model.showAllTask)
    }

    /// When even the whole-book search stopped at its limit, the book lists
    /// what it kept and ends with the note to refine the search.
    func testShowAllBeyondTheLimitEndsWithANote() async {
        let announcements = AnnouncementLog()
        let book = makeBook(0, title: "Endless")
        let list = BookList([book])
        let libraryResult = makeResult(book, order: 0, kept: 100, count: 1_000, reachedLimit: true)
        let wholeBookResult = makeResult(book, order: 0, kept: 500, reachedLimit: true)
        let model = makeModel(list, announcements) { _, _, books, limits, _, report in
            playOut([limits == .wholeBook ? wholeBookResult : libraryResult], given: books.count, report: report)
        }
        await searchAndWait(model)

        model.showAllMatches(in: book.id)
        await model.showAllTask?.value

        XCTAssertEqual(model.sections.first?.rows.count, 500, "Everything kept is listed")
        XCTAssertEqual(model.sections.first?.more, .beyondShowAll)
        XCTAssertEqual(announcements.messages.last, "Listing 500 matches in Endless", "Actual: \(announcements.messages)")
    }

    /// Show All for a book the list does not hold searches nothing.
    func testShowAllForAnUnknownBookDoesNothing() async {
        let log = RunLog()
        let book = makeBook(0)
        let list = BookList([book])
        let model = makeModel(list, AnnouncementLog()) { query, options, books, limits, _, report in
            log.record(query: query, options: options, books: books, limits: limits)
            return playOut([makeResult(book, order: 0, kept: 30)], given: books.count, report: report)
        }
        await searchAndWait(model)

        model.showAllMatches(in: UUID())

        XCTAssertNil(model.showAllTask)
        XCTAssertEqual(log.calls.count, 1, "Only the library search ran")
    }

    // MARK: The Status Text

    /// A section of `book` listing `rowCount` of its matches, with `more`.
    private func makeSection(
        _ book: LibrarySearchBook, order: Int = 0, rowCount: Int, more: LibrarySearchSection.More
    ) -> LibrarySearchSection {
        let matches = makeMatches(rowCount)
        let group = LibrarySearchGroup(makeResult(book, order: order, kept: rowCount))
        let rows = matches.enumerated().map { LibrarySearchMatchRow(book: book, match: $1, ordinal: $0) }
        return LibrarySearchSection(group: group, rows: rows, more: more)
    }

    /// The counts in words: matches and books, "No matches", and "More than"
    /// when a book's count reached its limit.
    func testFinishedTextCountsMatchesAndBooks() {
        XCTAssertEqual(
            LibrarySearchModel.finishedText(tally: makeTally(given: 40, withMatches: 31, matches: 212), sections: []),
            "212 matches in 31 books"
        )
        XCTAssertEqual(
            LibrarySearchModel.finishedText(tally: makeTally(given: 4, withMatches: 1, matches: 1), sections: []),
            "1 match in 1 book"
        )
        XCTAssertEqual(
            LibrarySearchModel.finishedText(tally: makeTally(given: 9), sections: []),
            "No matches"
        )
        XCTAssertEqual(
            LibrarySearchModel.finishedText(
                tally: makeTally(given: 9, withMatches: 3, matches: 800, pastTheLimit: 1), sections: []
            ),
            "More than 800 matches in 3 books"
        )
    }

    /// A list cut short says so: up to twenty in each book, and a thousand in
    /// all when the list stopped there; a list that shows everything does not.
    func testFinishedTextNotesACutList() {
        let book = makeBook(0)
        let tally = makeTally(given: 3, withMatches: 3, matches: 212)
        let cut = [makeSection(book, rowCount: 20, more: .showAll)]
        XCTAssertEqual(
            LibrarySearchModel.finishedText(tally: tally, sections: cut),
            "212 matches in 3 books; showing up to 20 in each book"
        )
        let whole = [makeSection(book, rowCount: 5, more: .nothing)]
        XCTAssertEqual(LibrarySearchModel.finishedText(tally: tally, sections: whole), "212 matches in 3 books")

        // Fifty sections of twenty rows have used the thousand.
        let full = (0..<50).map { makeSection(book, order: $0, rowCount: 20, more: .nothing) } + [makeSection(book, order: 50, rowCount: 0, more: .showAll)]
        XCTAssertEqual(
            LibrarySearchModel.finishedText(tally: tally, sections: full),
            "212 matches in 3 books; showing up to 20 in each book, and \(1_000.formatted()) in all"
        )
        // A search that found nothing has no list to cut.
        XCTAssertEqual(LibrarySearchModel.finishedText(tally: makeTally(given: 3), sections: cut), "No matches")
    }

    /// Books not searched are said after the count, joined by semicolons:
    /// those in the cloud, which a search never downloads, then those that
    /// could not be read.
    func testFinishedTextNotesBooksNotSearched() {
        let found = makeTally(given: 9, withMatches: 2, matches: 5)
        func text(inCloud: Int = 0, unreadable: Int = 0, tally: LibrarySearchTally? = nil) -> String {
            var tally = tally ?? found
            tally.booksInCloud = inCloud
            tally.booksUnreadable = unreadable
            return LibrarySearchModel.finishedText(tally: tally, sections: [])
        }

        XCTAssertEqual(text(inCloud: 1), "5 matches in 2 books; 1 book in the cloud wasn't searched")
        XCTAssertEqual(text(inCloud: 3), "5 matches in 2 books; 3 books in the cloud weren't searched")
        XCTAssertEqual(text(unreadable: 1), "5 matches in 2 books; 1 book couldn't be read")
        XCTAssertEqual(text(unreadable: 2), "5 matches in 2 books; 2 books couldn't be read")
        XCTAssertEqual(
            text(inCloud: 3, unreadable: 2),
            "5 matches in 2 books; 3 books in the cloud weren't searched; 2 books couldn't be read"
        )
        XCTAssertEqual(
            text(inCloud: 3, tally: makeTally(given: 9)),
            "No matches; 3 books in the cloud weren't searched",
            "Books left out matter most when nothing was found"
        )
        // The cut-list note comes before the notes on books left out.
        let cut = [makeSection(makeBook(0), rowCount: 20, more: .showAll)]
        var tally = found
        tally.booksInCloud = 1
        tally.booksUnreadable = 2
        XCTAssertEqual(
            LibrarySearchModel.finishedText(tally: tally, sections: cut),
            "5 matches in 2 books; showing up to 20 in each book; 1 book in the cloud wasn't searched; 2 books couldn't be read"
        )
    }

    /// The cloud and unreadable notes reach the status a search ends with.
    func testTheFinishedStatusCarriesTheNotesOfTheTally() async {
        let announcements = AnnouncementLog()
        let book0 = makeBook(0)
        let books = [book0] + (1..<4).map { makeBook($0) }
        let list = BookList(books)
        let result = makeResult(book0, order: 0, kept: 2)
        let model = makeModel(list, announcements) { _, _, books, _, _, report in
            playOut([result], given: books.count, inCloud: 1, unreadable: 2, report: report)
        }

        await searchAndWait(model)

        let expected = "2 matches in 1 book; 1 book in the cloud wasn't searched; 2 books couldn't be read"
        XCTAssertEqual(model.status.text, expected, "Actual: \(model.status.text)")
        XCTAssertEqual(announcements.messages, [expected])
    }

    // MARK: Opening a Match

    /// A match opens with the query and options of the search that found
    /// the list, even when the field has changed since.
    func testOpenUsesTheQueryAndOptionsThatFoundTheRows() async throws {
        let announcements = AnnouncementLog()
        let openings = OpenLog()
        let book = makeBook(0)
        let list = BookList([book])
        let model = makeModel(list, announcements, openings: openings) { _, _, books, _, _, report in
            playOut([makeResult(book, order: 0, kept: 3)], given: books.count, report: report)
        }
        model.matchCase = true
        await searchAndWait(model, "alpha")
        let row = try XCTUnwrap(model.sections.first?.rows[safe: 1], "The search should list a second row")
        XCTAssertEqual(model.foundQuery, "alpha")

        // The field changes. Nothing suspends before the row opens, so the
        // new search has not begun.
        model.useRegex = true
        model.query = "beta"
        model.open(row)

        let expected = OpenLog.Opening(
            rowID: row.id, bookID: book.id, query: "alpha",
            options: TextSearchOptions(matchCase: true, isRegularExpression: false)
        )
        XCTAssertEqual(openings.openings, [expected], "Actual: \(openings.openings)")

        // Once the new search lists its rows, they open with its query.
        await model.searchTask?.value
        let newRow = try XCTUnwrap(model.sections.first?.rows.first)
        model.open(newRow)
        XCTAssertEqual(openings.openings.last?.query, "beta", "Actual: \(openings.openings)")
        XCTAssertEqual(
            openings.openings.last?.options, TextSearchOptions(matchCase: true, isRegularExpression: true)
        )
    }

    /// A match whose book has left the library says so and opens nothing.
    func testOpeningAMatchOfABookThatLeftTheLibrarySaysSo() async throws {
        let announcements = AnnouncementLog()
        let openings = OpenLog()
        let book = makeBook(0, title: "Vanished Volume")
        let kept = makeBook(1)
        let list = BookList([book, kept])
        let results = [makeResult(book, order: 0, kept: 2), makeResult(kept, order: 1, kept: 2)]
        let model = makeModel(list, announcements, openings: openings) { _, _, books, _, _, report in
            playOut(results, given: books.count, report: report)
        }
        await searchAndWait(model)
        let goneRow = try XCTUnwrap(model.sections.first?.rows.first)
        let keptRow = try XCTUnwrap(model.sections.last?.rows.first)
        list.books = [kept]

        model.open(goneRow)

        XCTAssertEqual(openings.openings, [], "A book that left the library is not opened")
        XCTAssertEqual(announcements.messages.last, LibrarySearchWording.bookGone(title: "Vanished Volume"))
        XCTAssertEqual(announcements.messages.last, "Vanished Volume is no longer in the library.")

        model.open(keptRow)
        XCTAssertEqual(openings.openings.map(\.bookID), [kept.id], "A book still in the library opens")
    }

    // MARK: The Books of a Library

    /// A book of the library's own, with or without a package.
    private func makeLibraryBook(_ title: String, package: String?, format: BookFormat = .txt) -> Book {
        Book(
            title: title, author: "Some Author", format: format, filePath: "\(title).txt", md5Hash: "hash-\(title)",
            tmbDirectoryName: package ?? ""
        )
    }

    /// Only the library's own books with a package are searched, feed items
    /// and books without a package left out, in the order of their titles.
    func testSearchableBooksAreTheOwnBooksWithAPackageInTitleOrder() throws {
        let zebra = makeLibraryBook("Zebra Crossing", package: "zebra.tmb")
        let apple = makeLibraryBook("Apple Orchard", package: "apple.tmb")
        let mango = makeLibraryBook("Mango Grove", package: "mango.tmb", format: .audio)
        let noPackage = makeLibraryBook("Bare Bones", package: nil)
        var feedItem = makeLibraryBook("Episode One", package: "episode.tmb")
        feedItem.feedLink = FeedBookLink(feedID: UUID(), itemID: "guid:one")
        let library = Library(books: [zebra, feedItem, noPackage, apple, mango])

        let searchable = LibrarySearchModel.searchableBooks(in: library)

        XCTAssertEqual(
            searchable.map(\.title), ["Apple Orchard", "Mango Grove", "Zebra Crossing"],
            "Actual: \(searchable.map(\.title))"
        )
        XCTAssertEqual(searchable.map(\.id), [apple.id, mango.id, zebra.id])
        XCTAssertEqual(searchable.map(\.isAudiobook), [false, true, false], "An audiobook's text is its transcript")
        XCTAssertEqual(searchable.first?.contentURL, MarkdownCacheService.cacheURL(for: apple))
        XCTAssertEqual(searchable.first?.packageURL, apple.tmbDirectory)
        XCTAssertEqual(searchable.first?.author, "Some Author")
    }

    /// A library with no book to search lists none.
    func testSearchableBooksOfAnEmptyLibraryIsEmpty() {
        XCTAssertEqual(LibrarySearchModel.searchableBooks(in: Library()), [])
        let feedOnly = makeLibraryBook("Episode", package: "episode.tmb")
        var item = feedOnly
        item.feedLink = FeedBookLink(feedID: UUID(), itemID: "guid:two")
        XCTAssertEqual(LibrarySearchModel.searchableBooks(in: Library(books: [item])), [])
    }
}
