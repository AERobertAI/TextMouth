import XCTest
@testable import TextMouth

/// Recently Opened and the Reading List list episodes and articles beside
/// books (FR11), and their summary bar and Books header counted them all as
/// books (REV10, item 8). They now count only the library's own books as
/// books and name the feed items beside them by their nouns, the bar's words
/// spoken as shown.
final class LibraryFeedListCountTests: XCTestCase {

    /// The count of a list's books, episodes, articles, and feeds, each
    /// left out at zero, and "0 books" for nothing at all, as the library's
    /// count of books and feeds says it.
    func testAListCountsEachKindByItsNoun() {
        XCTAssertEqual(CountWording.listItems(books: 2, episodes: 5), "2 books, 5 episodes")
        XCTAssertEqual(CountWording.listItems(books: 1, episodes: 2, articles: 1), "1 book, 2 episodes, 1 article")
        XCTAssertEqual(CountWording.listItems(books: 0, episodes: 3), "3 episodes")
        XCTAssertEqual(CountWording.listItems(books: 0, episodes: 1, articles: 2), "1 episode, 2 articles")
        XCTAssertEqual(CountWording.listItems(books: 743, feeds: 2), "743 books, 2 feeds")
        XCTAssertEqual(CountWording.listItems(books: 0), "0 books")
        XCTAssertEqual(CountWording.listItems(of: Self.rows(books: 2, episodes: 5, articles: 1)), "2 books, 5 episodes, 1 article")
        XCTAssertEqual(CountWording.listItems(of: Self.rows(books: 3, episodes: 0, articles: 0), feeds: 1), "3 books, 1 feed")
    }

    /// The Books section's header names each kind with its count, and reads
    /// as it always has for books alone.
    func testTheHeaderCountsEachKindApart() {
        XCTAssertEqual(CountWording.booksHeader(of: Self.rows(books: 743, episodes: 0, articles: 0)), "Books (743)")
        XCTAssertEqual(CountWording.booksHeader(of: Self.rows(books: 2, episodes: 5, articles: 0)), "Books (2), Episodes (5)")
        XCTAssertEqual(CountWording.booksHeader(of: Self.rows(books: 0, episodes: 3, articles: 1)), "Episodes (3), Articles (1)")
        XCTAssertEqual(CountWording.booksHeader(of: []), "Books (0)")
    }

    /// The summary bar over a list of books and episodes shows "2 books, 5
    /// episodes", and VoiceOver hears the same words first.
    @MainActor
    func testTheSummaryBarSaysWhatItShows() {
        let bar = TimeRemainingBar(books: Self.rows(books: 2, episodes: 5, articles: 0), wpm: 200)

        XCTAssertEqual(bar.countText, "2 books, 5 episodes")
        XCTAssertTrue(bar.summaryAccessibilityLabel.hasPrefix("2 books, 5 episodes"), bar.summaryAccessibilityLabel)
    }

    // MARK: - Fixtures

    /// `books` rows of the library's own, then `episodes` feed items of
    /// audio and `articles` feed items of text.
    private static func rows(books: Int, episodes: Int, articles: Int) -> [Book] {
        let feedID = UUID()
        func row(_ number: Int, format: BookFormat, inFeed: Bool) -> Book {
            Book(
                title: "Row \(number)",
                format: format,
                filePath: "/nonexistent/row-\(number)",
                md5Hash: "row-\(number)",
                tmbDirectoryName: "row-\(number).tmb",
                feedLink: inFeed ? FeedBookLink(feedID: feedID, itemID: "guid:\(number)") : nil
            )
        }
        let ownBooks = (0..<books).map { row($0, format: .txt, inFeed: false) }
        let episodeRows = (0..<episodes).map { row(1_000 + $0, format: .audio, inFeed: true) }
        let articleRows = (0..<articles).map { row(2_000 + $0, format: .html, inFeed: true) }
        return ownBooks + episodeRows + articleRows
    }
}
