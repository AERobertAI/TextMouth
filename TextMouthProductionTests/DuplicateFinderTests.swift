import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import TextMouth

/// Regression coverage for combined duplicate-finder criteria: the four
/// criteria, which combine when checked together, with no fifth that two of
/// them make, and the group headings that say what matched.
final class DuplicateFinderTests: XCTestCase {
    /// The criteria are the four that combine; none is offered that two
    /// others make together, as "Same Title & Author" was until October 6,
    /// 2026, when Same Title checked with Same Author grouped the same way.
    func testNoCriterionDuplicatesTwoOthersCheckedTogether() {
        XCTAssertEqual(DuplicateFilter.allCases, [.md5Hash, .isbn, .title, .author])
        XCTAssertEqual(
            DuplicateFilter.allCases.map(\.rawValue),
            ["Identical File (MD5)", "Same ISBN", "Same Title", "Same Author"]
        )
        XCTAssertEqual(DuplicateFilter.title.hint, "Books with the same title, regardless of author")
        XCTAssertEqual(DuplicateFilter.author.hint, "All books by the same author")
    }

    /// A group's heading says what matched: the criteria checked, named
    /// together, over the values the books share, a title and an author
    /// matched together read as one. Until October 6, 2026 a pair's heading
    /// began "Combined:" and kept the title and author apart.
    func testAGroupsHeadingSaysWhatMatched() {
        let first = makeBook(title: "Shared", author: "One Author", hash: "same")
        let second = makeBook(title: "shared", author: "one author", hash: "same")
        func headings(_ filters: Set<DuplicateFilter>) -> [String] {
            DuplicateFinderEngine.findDuplicates(books: [first, second], filters: filters, isbnCache: [:])
                .map { "\($0.matchDescription): \($0.matchKey)" }
        }

        XCTAssertEqual(headings([.title]), ["Same Title: Shared"])
        XCTAssertEqual(headings([.author, .title]), ["Same Title and Same Author: Shared by One Author"])
        XCTAssertEqual(headings([.md5Hash, .author]), ["Identical File (MD5) and Same Author: Shared; One Author"])
        // Three criteria are listed as the system lists them, with or
        // without a comma before the "and".
        let three = try? XCTUnwrap(headings([.md5Hash, .title, .author]).first)
        XCTAssertTrue(three?.hasPrefix("Identical File (MD5), Same Title") ?? false, three ?? "no group")
        XCTAssertTrue(three?.hasSuffix("and Same Author: Shared; Shared by One Author") ?? false, three ?? "no group")
    }

    func testCombinedTitleAndAuthorRequiresBothFieldsToMatch() {
        let first = makeBook(title: "Shared", author: "First Author")
        let second = makeBook(title: "Shared", author: "Second Author")

        let groups = DuplicateFinderEngine.findDuplicates(
            books: [first, second],
            filters: [.title, .author],
            isbnCache: [:]
        )

        XCTAssertTrue(groups.isEmpty)
    }

    func testCombinedCriteriaGroupsBooksWhenEveryFieldMatches() {
        let first = makeBook(title: " Shared ", author: "Same Author", hash: "one")
        let second = makeBook(title: "shared", author: "same author", hash: "two")

        let groups = DuplicateFinderEngine.findDuplicates(
            books: [first, second],
            filters: [.title, .author],
            isbnCache: [:]
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].books.map(\.id)), Set([first.id, second.id]))
        XCTAssertEqual(groups[0].matchTypes, [.title, .author])
    }

    func testMissingSelectedISBNExcludesBookFromCombinedMatch() {
        let first = makeBook(title: "Shared", author: "Author")
        let second = makeBook(title: "Shared", author: "Author")

        let groups = DuplicateFinderEngine.findDuplicates(
            books: [first, second],
            filters: [.title, .isbn],
            isbnCache: [first.id: "9780000000001"]
        )

        XCTAssertTrue(groups.isEmpty)
    }

    /// A duplicate's row is spoken whole: its title, author, format, folder,
    /// and the date it was added, which the row showed but, until October
    /// 6, 2026, left unspoken, though it is what tells two copies apart.
    func testARowIsSpokenWithTheDateItWasAdded() {
        let added = Date(timeIntervalSince1970: 1_790_000_000)
        let filed = Book(
            title: "Atlas", author: "Dorothy Vance", format: .epub, filePath: "/tmp/a.epub", md5Hash: "a",
            folderPath: "Travel", dateAdded: added
        )
        let atRoot = Book(title: "Atlas", author: "Dorothy Vance", format: .pdf, filePath: "/tmp/b.pdf", md5Hash: "b", dateAdded: added)
        let date = added.formatted(date: .long, time: .omitted)

        XCTAssertEqual(DuplicateFinderWording.bookLabel(filed), "Atlas, by Dorothy Vance, EPUB, in Travel, added \(date)")
        XCTAssertEqual(DuplicateFinderWording.bookLabel(atRoot), "Atlas, by Dorothy Vance, PDF, in Library Root, added \(date)")
        XCTAssertEqual(DuplicateFinderWording.libraryRoot, "Library Root")
    }

    /// What a scan found is said in the right number, and spoken when the
    /// scan ends, as the removal's outcome is; until October 6, 2026 one
    /// group was "1 duplicate groups found" and a scan said nothing.
    @MainActor
    func testAScansResultIsCountedAndSpoken() {
        XCTAssertEqual(DuplicateFinderWording.scanResult(groupCount: 0), "No duplicates found with the selected criteria")
        XCTAssertEqual(DuplicateFinderWording.scanResult(groupCount: 1), "1 duplicate group found")
        XCTAssertEqual(DuplicateFinderWording.scanResult(groupCount: 3), "3 duplicate groups found")
        XCTAssertEqual(DuplicateFinderWording.noDuplicates, "No duplicates found.")

        let heard = recordingAnnouncements {
            DuplicateFinderWording.announceScanResult(groupCount: 0)
            DuplicateFinderWording.announceScanResult(groupCount: 2)
        }
        XCTAssertEqual(
            heard.announcements.map(\.message),
            ["No duplicates found with the selected criteria", "2 duplicate groups found"]
        )
    }

    // MARK: - Pages of Groups (REV13)

    /// A page holds whole groups, in the scan's order, of at most 40 books
    /// in all; a group of more books than that has a page of its own; and
    /// a scan that found nothing has no page.
    func testAPageHoldsWholeGroupsOfAtMostFortyBooks() {
        XCTAssertEqual(DuplicateGroupPages.rowsPerPage, 40)
        XCTAssertEqual(DuplicateGroupPages(rowCounts: []).ranges, [])
        XCTAssertEqual(DuplicateGroupPages(rowCounts: [2, 3]).ranges, [0..<2])
        XCTAssertEqual(DuplicateGroupPages(rowCounts: [10, 10, 10, 10]).ranges, [0..<4], "exactly 40 books fit")
        XCTAssertEqual(DuplicateGroupPages(rowCounts: [10, 10, 10, 10, 1]).ranges, [0..<4, 4..<5])
        XCTAssertEqual(DuplicateGroupPages(rowCounts: [30, 20, 2]).ranges, [0..<1, 1..<3])
        XCTAssertEqual(
            DuplicateGroupPages(rowCounts: [2, 45, 2]).ranges,
            [0..<1, 1..<2, 2..<3],
            "a group of 45 books has a page of its own"
        )
    }

    /// An author scan of a 700-book library, 116 groups of 688 books, is
    /// shown in pages that hold every group once, in order, each listing
    /// at most 40 books; until October 10, 2026 the sheet drew all 688
    /// books' checkboxes at once.
    func testAnAuthorScanOfALargeLibraryIsShownInPages() {
        let books = DuplicateFinderFixtures.authorLibrary(bookCount: 700)
        let groups = DuplicateFinderEngine.findDuplicates(books: books, filters: [.author], isbnCache: [:])
        XCTAssertEqual(groups.count, 116)
        XCTAssertEqual(groups.reduce(0) { $0 + $1.books.count }, 688)

        let pages = DuplicateGroupPages(groups: groups)
        XCTAssertGreaterThan(pages.count, 1)
        // Every group once, in the scan's order, with no page empty.
        XCTAssertEqual(pages.ranges.flatMap { Array($0) }, Array(groups.indices))
        for range in pages.ranges {
            let rows = groups[range].reduce(0) { $0 + $1.books.count }
            XCTAssertTrue(rows <= DuplicateGroupPages.rowsPerPage || range.count == 1, "\(range) lists \(rows) books")
        }
    }

    /// Turning past either end stays on the first or the last page, and a
    /// scan made again after a removal keeps the group that headed the
    /// page shown in view, on whatever page it now falls; with that group
    /// gone, the same page, or the last when there are fewer.
    func testTheListStaysWhereItWasThroughARemoval() {
        let groups = (0..<6).map { number in
            DuplicateGroup(
                matchKey: "Author \(number)",
                matchTypes: [.author],
                books: (0..<20).map { makeBook(title: "Book \(number).\($0)", author: "Author \(number)") }
            )
        }
        let pages = DuplicateGroupPages(groups: groups)
        XCTAssertEqual(pages.ranges, [0..<2, 2..<4, 4..<6])
        XCTAssertEqual(pages.clamped(-1), 0)
        XCTAssertEqual(pages.clamped(7), 2)
        XCTAssertEqual(pages.groupIndices(onPage: 9), 4..<6)

        // Group 0 is gone after a removal, so group 4, which headed the
        // third page, now heads the second.
        let rescanned = Array(groups.dropFirst())
        let after = DuplicateGroupPages(groups: rescanned)
        XCTAssertEqual(after.page(keeping: groups[4].id, of: rescanned, orElse: 2), 1)
        // The group that headed the page is gone itself: the same page.
        XCTAssertEqual(after.page(keeping: groups[0].id, of: rescanned, orElse: 1), 1)
        // Fewer pages than the page shown: the last.
        let fewer = Array(groups.prefix(2))
        XCTAssertEqual(DuplicateGroupPages(groups: fewer).page(keeping: "gone", of: fewer, orElse: 2), 0)
    }

    /// The line over a page says which groups it shows, as the screen shows
    /// it and VoiceOver reads and announces it, and the buttons turning
    /// the pages say what they show.
    func testThePagersWordsSayWhichGroupsAreShown() {
        XCTAssertEqual(DuplicateFinderWording.pageLine(groups: 0..<7, of: 116), "Showing groups 1 to 7 of 116")
        XCTAssertEqual(DuplicateFinderWording.pageLine(groups: 11..<12, of: 116), "Showing group 12 of 116")
        XCTAssertEqual(DuplicateFinderWording.previousPageTitle, "Previous Groups")
        XCTAssertEqual(DuplicateFinderWording.previousPageHint, "Shows the groups before these.")
        XCTAssertEqual(DuplicateFinderWording.nextPageTitle, "Next Groups")
        XCTAssertEqual(DuplicateFinderWording.nextPageHint, "Shows the groups after these.")
    }

    /// A page of the results draws a native checkbox for each of its books
    /// and no more, hosted at the sheet's fixed size.
    @MainActor
    func testAPageDrawsACheckboxForEachOfItsBooksAlone() {
        let books = DuplicateFinderFixtures.authorLibrary(bookCount: 700)
        let groups = DuplicateFinderEngine.findDuplicates(books: books, filters: [.author], isbnCache: [:])
        let firstPage = Array(groups[DuplicateGroupPages(groups: groups).groupIndices(onPage: 0)])
        let rows = firstPage.reduce(0) { $0 + $1.books.count }
        let box = DuplicateSelectionBox()
        let hosted = hostOffscreen(
            DuplicateSelectionHost(box: box, groups: firstPage).frame(width: 600, height: 550),
            size: NSSize(width: 600, height: 550)
        )
        defer { takeDown(hosted.window) }

        XCTAssertTrue(
            waitUntil { self.descendants(of: hosted.hostingView, as: NSButton.self).count == rows },
            "the page drew \(descendants(of: hosted.hostingView, as: NSButton.self).count) checkboxes for \(rows) books"
        )
        XCTAssertLessThanOrEqual(rows, DuplicateGroupPages.rowsPerPage)
    }

    // MARK: - What the Results Cost (REV13)

    /// Opt-in: what showing an author scan's results costs, for a 700-book
    /// library whose authors mostly hold 2 to 10 books, hosted at the
    /// sheet's fixed size: main-thread milliseconds and wall-clock
    /// milliseconds to lay the list out, the malloc it holds, and what
    /// checking one book costs, for every group at once, as the sheet drew
    /// them until October 10, 2026, and for the first page, as it draws
    /// them now. Prints one `DUPLICATEFINDER <label> <json>` line each. Set
    /// TEXTMOUTH_VIEW_BENCHMARKS=1 (TEST_RUNNER_… for xcodebuild).
    @MainActor
    func testMeasureWhatAnAuthorScansResultsCost() throws {
        guard ProcessInfo.processInfo.environment[ViewsAndWindowsBenchmarks.optInVariable] == "1" else {
            throw XCTSkip("Set \(ViewsAndWindowsBenchmarks.optInVariable)=1 to measure")
        }
        let books = DuplicateFinderFixtures.authorLibrary(bookCount: 700)
        let groups = DuplicateFinderEngine.findDuplicates(books: books, filters: [.author], isbnCache: [:])
        let firstPage = Array(groups[DuplicateGroupPages(groups: groups).groupIndices(onPage: 0)])
        // One small list first pays the frameworks' one-time costs.
        _ = measureList(Array(groups.prefix(3)))
        for (label, shown) in [("all", groups), ("firstPage", firstPage)] {
            var result = measureList(shown)
            result["groups"] = shown.count
            result["rows"] = shown.reduce(0) { $0 + $1.books.count }
            result["libraryBooks"] = books.count
            result["allGroups"] = groups.count
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            print("DUPLICATEFINDER list.\(label) \(String(decoding: data, as: UTF8.self))")
        }
    }

    /// Hosts the results list of `groups` at the sheet's size and returns
    /// what it cost: the first layout's main-thread and wall-clock
    /// milliseconds, the malloc held once it settled, and the main-thread
    /// milliseconds of checking one book.
    @MainActor
    private func measureList(_ groups: [DuplicateGroup]) -> [String: Any] {
        let box = DuplicateSelectionBox()
        let mallocBefore = mallocBytesInUse()
        let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let wallStart = Date()
        let hosted = hostOffscreen(
            DuplicateSelectionHost(box: box, groups: groups).frame(width: 600, height: 550),
            size: NSSize(width: 600, height: 550)
        )
        let firstLayoutCPU = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1_000_000
        let firstLayoutWall = Date().timeIntervalSince(wallStart) * 1_000
        settle(hosted.hostingView, seconds: 0.5)
        let heldMB = Double(mallocBytesInUse() - mallocBefore) / 1_048_576
        // Checking a book redraws the list: what one check costs.
        var checkCPU = 0.0
        if let book = groups.first?.books.first {
            let checkStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            box.selection.insert(book.id)
            flush(hosted.hostingView)
            checkCPU = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - checkStart) / 1_000_000
        }
        takeDown(hosted.window)
        settle(nil, seconds: 0.3)
        return [
            "firstLayoutCPUms": (firstLayoutCPU * 10).rounded() / 10,
            "firstLayoutWallms": (firstLayoutWall * 10).rounded() / 10,
            "heldMB": (heldMB * 10).rounded() / 10,
            "checkOneCPUms": (checkCPU * 10).rounded() / 10,
        ]
    }

    private func makeBook(
        title: String,
        author: String,
        hash: String = UUID().uuidString
    ) -> Book {
        Book(
            title: title,
            author: author,
            format: .epub,
            filePath: "/tmp/\(UUID().uuidString).epub",
            md5Hash: hash
        )
    }
}

/// The books a check in a hosted results list selects, which a test changes
/// as a check would.
@MainActor
private final class DuplicateSelectionBox: ObservableObject {
    @Published var selection: Set<UUID> = []
}

/// The Duplicate Finder's results list over `groups`, its checks kept in
/// `box`, as the sheet keeps them in its state.
private struct DuplicateSelectionHost: View {
    @ObservedObject var box: DuplicateSelectionBox
    let groups: [DuplicateGroup]

    var body: some View {
        DuplicateGroupList(groups: groups, selection: $box.selection)
    }
}

/// Libraries for the Duplicate Finder's tests.
enum DuplicateFinderFixtures {
    /// `bookCount` books whose authors mostly hold 2 to 10 books each, as
    /// an author scan of a large library finds them: author n holds 2 +
    /// (7n mod 9) books, and every tenth author holds one alone, which no
    /// group lists. 700 books make 116 groups of 688 books.
    static func authorLibrary(bookCount: Int) -> [Book] {
        var books: [Book] = []
        var author = 0
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        while books.count < bookCount {
            let held = author % 10 == 9 ? 1 : 2 + (author * 7) % 9
            for _ in 0..<min(held, bookCount - books.count) {
                let number = books.count
                books.append(Book(
                    title: "Shelved Book \(number)",
                    author: "Author \(author)",
                    format: .epub,
                    filePath: "/nonexistent/duplicates/\(number).epub",
                    md5Hash: "duplicates-\(number)",
                    folderPath: "Shelf \(number % 12)",
                    dateAdded: epoch.addingTimeInterval(Double(number) * 3_600)
                ))
            }
            author += 1
        }
        return books
    }
}
