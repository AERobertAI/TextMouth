import Foundation
import XCTest
@testable import TextMouth

/// Every sentence Speak Info speaks (October 7, 2026), pinned without a
/// window: a book's, a folder's, and a feed's brief and full summaries,
/// what each leaves out when it is unknown, and how the parts become
/// sentences.
final class LibraryInfoWordingTests: XCTestCase {

    // MARK: - Fixtures

    /// A calendar and locale the dates are read in, so the sentences never
    /// depend on the Mac's settings.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    private let locale = Locale(identifier: "en_US")

    /// October 4, 2026 at 3:30 PM UTC.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 15, minute: 30)) ?? Date()
    }

    /// `text` with the narrow space some systems put before AM and PM made
    /// an ordinary space.
    private func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ")
    }

    /// A book with every fact known.
    private var middlemarch: BookInfoFacts {
        BookInfoFacts(
            title: "Middlemarch",
            author: "George Eliot",
            format: "EPUB",
            folderPath: "Classics",
            progress: "42 percent",
            timeRemaining: 7_500,
            isUnopened: false,
            dateAdded: calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 9, minute: 0)) ?? now,
            lastOpened: calendar.date(byAdding: .minute, value: -25, to: now),
            bookmarkCount: 3,
            fileSize: 1_234_567,
            cloudNote: "In Cloud",
            isKeptOnThisMac: true,
            isOpenInWindow: true
        )
    }

    // MARK: - A Book

    /// A book's brief summary names it as its row does: title, author,
    /// format, folder, progress, and time left.
    func testABooksBriefSummaryNamesItAsItsRowDoes() {
        XCTAssertEqual(
            LibraryInfoWording.brief(.book(middlemarch)),
            "Middlemarch. By George Eliot. EPUB. In Classics. 42 percent. 2 hours, 5 minutes remaining."
        )
    }

    /// The placeholder author is left out, a book in no folder says so,
    /// and a book never opened says "Unopened" in place of a progress it
    /// has none of.
    func testAnUnknownAuthorIsLeftOutAndAnUnopenedBookSaysSo() {
        var draft = middlemarch
        draft.title = "Draft"
        draft.author = Book.unknownAuthor
        draft.format = "Plain Text"
        draft.folderPath = ""
        draft.progress = nil
        draft.timeRemaining = nil
        draft.isUnopened = true
        XCTAssertEqual(LibraryInfoWording.brief(.book(draft)), "Draft. Plain Text. Not in a folder. Unopened.")
        draft.author = ""
        XCTAssertEqual(LibraryInfoWording.brief(.book(draft)), "Draft. Plain Text. Not in a folder. Unopened.")
        // A time left without a measured progress is still said.
        draft.timeRemaining = 90
        XCTAssertEqual(LibraryInfoWording.brief(.book(draft)), "Draft. Plain Text. Not in a folder. 1 minute, 30 seconds remaining. Unopened.")
    }

    /// The full summary adds when the book was added and last opened, its
    /// bookmarks, its file size, its cloud note, that it is kept on this
    /// Mac, and that a reader window has it open.
    func testABooksFullSummaryAddsDatesBookmarksSizeCloudAndWindow() {
        let size = ByteCountFormatter.string(fromByteCount: 1_234_567, countStyle: .file)
        XCTAssertEqual(
            plain(LibraryInfoWording.full(.book(middlemarch), now: now, calendar: calendar, locale: locale)),
            "Middlemarch. By George Eliot. EPUB. In Classics. 42 percent. 2 hours, 5 minutes remaining. "
                + "Added September 1 at 9:00 AM. Last opened today at 3:05 PM. 3 bookmarks. File size \(plain(size)). "
                + "In Cloud. Kept on this Mac. Open in a reader window."
        )
    }

    /// What is unknown is left out of the full summary: no last opening, no
    /// measured size, no cloud note, not kept, not open; the bookmarks are
    /// counted even when there are none.
    func testABooksFullSummaryLeavesOutWhatIsUnknown() {
        var book = middlemarch
        book.lastOpened = nil
        book.isUnopened = true
        book.bookmarkCount = 0
        book.fileSize = nil
        book.cloudNote = nil
        book.isKeptOnThisMac = false
        book.isOpenInWindow = false
        XCTAssertEqual(
            plain(LibraryInfoWording.full(.book(book), now: now, calendar: calendar, locale: locale)),
            "Middlemarch. By George Eliot. EPUB. In Classics. 42 percent. 2 hours, 5 minutes remaining. Unopened. "
                + "Added September 1 at 9:00 AM. 0 bookmarks."
        )
        book.bookmarkCount = 1
        XCTAssertTrue(LibraryInfoWording.full(.book(book), now: now, calendar: calendar, locale: locale).hasSuffix(" 1 bookmark."))
    }

    // MARK: - A Folder

    /// A folder's brief summary counts its books, the unopened ones among
    /// them, and its feeds; the full one adds its subfolders and the time
    /// left in all its books.
    func testAFoldersSummariesCountItsBooksUnopenedFeedsAndSubfolders() {
        let classics = FolderInfoFacts(name: "Classics", bookCount: 12, unopenedCount: 3, feedCount: 2, subfolderCount: 4, timeRemaining: 50_580)
        XCTAssertEqual(LibraryInfoWording.brief(.folder(classics)), "Classics. Folder. 12 books, 3 unopened. 2 feeds.")
        XCTAssertEqual(
            LibraryInfoWording.full(.folder(classics), now: now, calendar: calendar, locale: locale),
            "Classics. Folder. 12 books, 3 unopened. 2 feeds. 4 subfolders. 14 hours, 3 minutes remaining in total."
        )
        let one = FolderInfoFacts(name: "Poems", bookCount: 1, unopenedCount: 1, feedCount: 1, subfolderCount: 1, timeRemaining: 60)
        XCTAssertEqual(
            LibraryInfoWording.full(.folder(one), now: now, calendar: calendar, locale: locale),
            "Poems. Folder. 1 book, 1 unopened. 1 feed. 1 subfolder. 1 minute remaining in total."
        )
    }

    /// Counts of nothing are left out, but the books are always counted, and
    /// an unknown time left is left out.
    func testAnEmptyFoldersSummariesCountItsBooksAlone() {
        let empty = FolderInfoFacts(name: "Empty", bookCount: 0, unopenedCount: 0, feedCount: 0, subfolderCount: 0, timeRemaining: nil)
        XCTAssertEqual(LibraryInfoWording.brief(.folder(empty)), "Empty. Folder. 0 books.")
        XCTAssertEqual(LibraryInfoWording.full(.folder(empty), now: now, calendar: calendar, locale: locale), "Empty. Folder. 0 books.")
    }

    // MARK: - A Feed

    /// A feed's brief summary counts its items as its row does, then the
    /// unplayed ones, and says its last check; the full one adds its folder
    /// and its address.
    func testAFeedsSummariesCountItsItemsAndSayItsCheckFolderAndAddress() {
        let counts = FeedItemCounts(listed: 12, downloaded: 3, downloading: 0, new: 2, unplayed: 5, noun: .episode)
        let feed = FeedInfoFacts(
            title: "Planet Money",
            counts: counts,
            check: "Checked today at 3:05 PM",
            folderPath: "Podcasts/Planet Money",
            address: "https://example.com/feed.xml"
        )
        XCTAssertEqual(
            LibraryInfoWording.brief(.feed(feed)),
            "Planet Money. Feed. 12 episodes, 3 downloaded, 2 new, 5 unplayed. Checked today at 3:05 PM."
        )
        XCTAssertEqual(
            LibraryInfoWording.full(.feed(feed), now: now, calendar: calendar, locale: locale),
            "Planet Money. Feed. 12 episodes, 3 downloaded, 2 new, 5 unplayed. Checked today at 3:05 PM. "
                + "In Podcasts/Planet Money. Address https://example.com/feed.xml."
        )
        // The row's own phrase, so the two never disagree.
        XCTAssertEqual(FeedWording.countsPhrase(counts), "12 episodes, 3 downloaded, 2 new, 5 unplayed")
        XCTAssertTrue(LibraryInfoWording.brief(.feed(feed)).contains(FeedWording.countsPhrase(counts)))
    }

    /// A feed that lists more entries than the library keeps says how many
    /// of them are kept, as its row does; a feed longer than TextMouth
    /// reads says it lists more.
    func testAFeedsSummarySaysHowManyOfItsEntriesAreKept() {
        var feed = FeedInfoFacts(
            title: "Planet Money",
            counts: FeedItemCounts(listed: 10, total: FeedEntryTotal(count: 381), downloaded: 3, downloading: 0, new: 2, unplayed: 5, noun: .episode),
            check: "Checked today at 3:05 PM",
            folderPath: "Podcasts/Planet Money",
            address: nil
        )
        XCTAssertEqual(
            LibraryInfoWording.brief(.feed(feed)),
            "Planet Money. Feed. 10 of 381 episodes listed, 3 downloaded, 2 new, 5 unplayed. Checked today at 3:05 PM."
        )
        feed.counts.total = FeedEntryTotal(count: 2_000, listsMore: true)
        XCTAssertEqual(
            LibraryInfoWording.brief(.feed(feed)),
            "Planet Money. Feed. 10 of more than 2000 episodes listed, 3 downloaded, 2 new, 5 unplayed. Checked today at 3:05 PM."
        )
    }

    /// Articles are unread rather than unplayed, nothing unplayed is left
    /// out, a feed whose folder is gone says so and names no folder, and a
    /// feed whose record is gone has no address to say (an unsubscribed one
    /// keeps its record and its address since FR11's branch D). A failed
    /// check's message, which ends with a period, is not given a second one.
    func testAFeedOfArticlesWithoutAFolderOrAnAddress() {
        var feed = FeedInfoFacts(
            title: "Harbour Notes",
            counts: FeedItemCounts(listed: 2, downloaded: 0, downloading: 0, new: 0, unplayed: 1, noun: .article),
            check: "Last check failed: The server feeds.example couldn't be found. Check the address.",
            folderPath: nil,
            address: nil
        )
        XCTAssertEqual(
            LibraryInfoWording.brief(.feed(feed)),
            "Harbour Notes. Feed. Folder missing. 2 articles, 1 unread. "
                + "Last check failed: The server feeds.example couldn't be found. Check the address."
        )
        XCTAssertEqual(LibraryInfoWording.full(.feed(feed), now: now, calendar: calendar, locale: locale), LibraryInfoWording.brief(.feed(feed)))
        feed.counts.unplayed = 0
        feed.check = "Not checked yet"
        XCTAssertEqual(LibraryInfoWording.brief(.feed(feed)), "Harbour Notes. Feed. Folder missing. 2 articles. Not checked yet.")
    }

    // MARK: - Sentences

    /// Each part becomes a sentence ended once: a part that already ends
    /// with a period, a question mark, an exclamation mark, or an ellipsis
    /// keeps its own; empty parts are left out.
    func testSentencesEndEachPartOnceAndLeaveOutEmptyOnes() {
        XCTAssertEqual(
            LibraryInfoWording.sentences(["Who Goes There?", "", "Check the address.", "Wait…", "Go!", "EPUB"]),
            "Who Goes There? Check the address. Wait… Go! EPUB."
        )
        XCTAssertEqual(LibraryInfoWording.sentences([]), "")
        XCTAssertEqual(LibraryInfoWording.remaining(3_600), "1 hour remaining")
    }

    /// The words of a press with nothing selected, and the notes the
    /// summaries use, are pinned.
    func testTheNotesArePinned() {
        XCTAssertEqual(LibraryInfoWording.nothingSelected, "Nothing is selected.")
        XCTAssertEqual(LibraryInfoWording.folderKind, "Folder")
        XCTAssertEqual(LibraryInfoWording.unopenedNote, "Unopened")
        XCTAssertEqual(LibraryInfoWording.noFolderNote, "Not in a folder")
        XCTAssertEqual(LibraryInfoWording.openInWindowNote, "Open in a reader window")
        XCTAssertEqual(LibraryInfoWording.readingListNote(ReadingListPlace(position: 3, count: 12)), "In reading list, 3 of 12")
    }

    // MARK: - The Reading List (FR09)

    /// A book in the reading list says its place there in its brief
    /// summary, after where it is, and so in its full one too; a book not
    /// in the list says nothing of it.
    func testABookInTheReadingListSaysItsPlaceInItsSummaries() {
        var listed = middlemarch
        listed.readingListPlace = ReadingListPlace(position: 3, count: 12)

        XCTAssertEqual(
            LibraryInfoWording.brief(.book(listed)),
            "Middlemarch. By George Eliot. EPUB. In Classics. In reading list, 3 of 12. 42 percent. 2 hours, 5 minutes remaining."
        )
        let full = LibraryInfoWording.full(.book(listed), now: now, calendar: calendar, locale: locale)
        XCTAssertTrue(full.hasPrefix(LibraryInfoWording.brief(.book(listed))), full)
        XCTAssertFalse(LibraryInfoWording.brief(.book(middlemarch)).contains("reading list"))
        XCTAssertFalse(LibraryInfoWording.full(.book(middlemarch), now: now, calendar: calendar, locale: locale).contains("reading list"))
    }
}
