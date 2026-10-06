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
