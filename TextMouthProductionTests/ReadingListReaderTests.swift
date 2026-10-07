import Combine
import XCTest
@testable import TextMouth

/// A book read from the reading list (FR09, the reader's part): the request
/// a Library window leaves as it opens a book from the Reading List, and the
/// book's reader claiming it, once, as the open makes the reader or brings
/// its window forward; and the mark that says so: the window's title, the
/// header's line, and the full Where Am I?, which follow the list as it
/// changes and end when the book leaves it.
///
/// Every book is a package of silent audio tracks, or a text book that no
/// test plays, so nothing is heard. Each test's readers share a private
/// request store and listen on a private notification center (the
/// integration world's), so the running app's own windows never see these
/// requests, and announcements are recorded instead of spoken.
@MainActor
final class ReadingListReaderTests: XCTestCase {

    // MARK: - The Request Store

    /// A request waits for its book alone and is claimed once: another
    /// book's reader finds nothing, the book's reader finds it, and nothing
    /// finds it again. A newer request for the same book replaces it.
    func testARequestIsClaimedOnceByItsBookAlone() {
        let requests = ReadingListOpenRequests()
        let book = UUID()
        let other = UUID()

        let made = requests.request(for: book)

        XCTAssertEqual(made.bookID, book)
        XCTAssertTrue(requests.hasRequest(for: book))
        XCTAssertFalse(requests.hasRequest(for: other))
        XCTAssertNil(requests.consume(for: other))
        XCTAssertEqual(requests.consume(for: book), made)
        XCTAssertNil(requests.consume(for: book), "claimed twice")
        XCTAssertFalse(requests.hasRequest(for: book))

        requests.request(for: book)
        let newer = requests.request(for: book)
        XCTAssertEqual(requests.consume(for: book), newer)
        XCTAssertNil(requests.consume(for: book), "the replaced request was kept too")
    }

    /// A request older than its lifetime, which is the autoplay request's,
    /// is thrown away rather than claimed, and so is one dated after a
    /// clock set back; one at its lifetime's edge is still claimed.
    func testARequestOlderThanItsLifetimeIsThrownAway() {
        XCTAssertEqual(ReadingListOpenRequests.lifetime, ReaderAutoplayRequests.lifetime)
        var now = Date(timeIntervalSince1970: 1_791_000_000)
        let requests = ReadingListOpenRequests(now: { now })
        let book = UUID()

        requests.request(for: book)
        now += ReadingListOpenRequests.lifetime
        XCTAssertTrue(requests.hasRequest(for: book), "thrown away at its lifetime's edge")
        now += 1
        XCTAssertFalse(requests.hasRequest(for: book))
        XCTAssertNil(requests.consume(for: book))
        // Even with the clock back where it was, the request is gone.
        now -= ReadingListOpenRequests.lifetime + 1
        XCTAssertNil(requests.consume(for: book))

        // A clock set back as far keeps a request no longer either.
        requests.request(for: book)
        now -= ReadingListOpenRequests.lifetime + 1
        XCTAssertNil(requests.consume(for: book))
    }

    /// Each request is told as it is made, once, with its book, after it
    /// waits, so whoever hears of it can claim it there and then.
    func testEachRequestIsToldAsItIsMadeAndCanBeClaimedThen() {
        let requests = ReadingListOpenRequests()
        let first = UUID()
        let second = UUID()
        var told: [UUID] = []
        var claimedAsTold: [Bool] = []
        let subscription = requests.requestsMade.sink { bookID in
            told.append(bookID)
            claimedAsTold.append(requests.consume(for: bookID) != nil)
        }
        defer { subscription.cancel() }

        requests.request(for: first)
        requests.request(for: second)

        XCTAssertEqual(told, [first, second])
        XCTAssertEqual(claimedAsTold, [true, true])
        XCTAssertFalse(requests.hasRequest(for: first))
        XCTAssertFalse(requests.hasRequest(for: second))
    }

    /// A Library window marks the books it opens only at the Reading List:
    /// there the request is made before the book opens, so a reader the
    /// open makes finds it; in every other category the book opens as it
    /// always has, with no request, even when the book is in the list. No
    /// request is made while the library moves, when the window refuses
    /// the open; the open is still asked for, and refuses itself.
    func testOnlyTheReadingListMarksTheBooksItOpens() {
        let book = ReadingListTests.book("Harbour Charts")
        for category in LibraryCategory.allCases {
            for libraryIsMoving in [false, true] {
                let requests = ReadingListOpenRequests()
                var opened: [UUID] = []
                var requestedWhenOpened: [Bool] = []
                let marks = category == .readingList && !libraryIsMoving

                requests.open(book, shownIn: category, libraryIsMoving: libraryIsMoving) { opening in
                    opened.append(opening.id)
                    requestedWhenOpened.append(requests.hasRequest(for: opening.id))
                }

                let name = "\(category.rawValue), library moving: \(libraryIsMoving)"
                XCTAssertEqual(
                    ReadingListOpenRequests.marksOpens(in: category, libraryIsMoving: libraryIsMoving),
                    marks,
                    name
                )
                XCTAssertEqual(opened, [book.id], name)
                XCTAssertEqual(requestedWhenOpened, [marks], name)
                XCTAssertEqual(requests.hasRequest(for: book.id), marks, name)
            }
        }
    }

    // MARK: - The Claim

    /// A reader made for a book opened from the Reading List reads it from
    /// the list from the moment it is made, at the book's place in the list
    /// as the window shows it, and uses the request up: an audiobook, and a
    /// text book alike.
    func testAReaderOpenedFromTheReadingListReadsFromIt() throws {
        let world = try makeIntegrationWorld("ReadingListClaim")
        let requests = ReadingListOpenRequests()
        let first = try makeAudioBook("First Crossing", in: world)
        let text = try makeTextBook("Tide Tables", in: world)
        let third = try makeAudioBook("Third Crossing", in: world)
        list([first, text, third], in: world)

        for (book, place) in [(text, ReadingListPlace(position: 2, count: 3)), (third, ReadingListPlace(position: 3, count: 3))] {
            requests.request(for: book.id)
            let reader = makeReader(for: book, in: world, requests: requests)

            XCTAssertTrue(reader.isOpenedFromReadingList, book.title)
            XCTAssertEqual(reader.readingListPlace, place, book.title)
            XCTAssertFalse(requests.hasRequest(for: book.id), "\(book.title): the request was left to claim again")

            // Loading the book changes nothing.
            waitForReaderToLoad(reader)
            XCTAssertNil(reader.loadErrorMessage, book.title)
            XCTAssertEqual(reader.readingListPlace, place, book.title)
        }
    }

    /// A book opened any other way is not read from the list, though it is
    /// in it: from a folder, All Items, Recent, Unopened, or Continue
    /// Listening, none of which leaves a request.
    func testABookOpenedAnyOtherWayIsNotReadFromTheList() throws {
        let world = try makeIntegrationWorld("ReadingListNoClaim")
        let requests = ReadingListOpenRequests()
        let book = try makeAudioBook("First Crossing", in: world)
        list([book], in: world)

        let reader = makeReader(for: book, in: world, requests: requests)
        waitForReaderToLoad(reader)

        XCTAssertFalse(reader.isOpenedFromReadingList)
        XCTAssertNil(reader.readingListPlace)
    }

    /// A book whose window is open already, opened from a folder, reads
    /// from the list as soon as it is opened from the Reading List, which
    /// brings its window forward rather than making another, and uses the
    /// request up.
    func testAnOpenWindowBroughtForwardFromTheReadingListClaimsAtOnce() throws {
        let world = try makeIntegrationWorld("ReadingListBroughtForward")
        let requests = ReadingListOpenRequests()
        let first = try makeAudioBook("First Crossing", in: world)
        let second = try makeAudioBook("Second Crossing", in: world)
        list([first, second], in: world)
        let reader = makeReader(for: second, in: world, requests: requests)
        waitForReaderToLoad(reader)
        XCTAssertFalse(reader.isOpenedFromReadingList)

        requests.open(second, shownIn: .readingList, libraryIsMoving: false) { _ in }

        XCTAssertTrue(reader.isOpenedFromReadingList)
        XCTAssertEqual(reader.readingListPlace, ReadingListPlace(position: 2, count: 2))
        XCTAssertFalse(requests.hasRequest(for: second.id))
    }

    /// A request for another book leaves an open reader as it was, and
    /// waits for that book's own reader.
    func testARequestForAnotherBookIsLeftForItsReader() throws {
        let world = try makeIntegrationWorld("ReadingListOtherBook")
        let requests = ReadingListOpenRequests()
        let first = try makeAudioBook("First Crossing", in: world)
        let second = try makeAudioBook("Second Crossing", in: world)
        list([first, second], in: world)
        let reader = makeReader(for: first, in: world, requests: requests)

        requests.request(for: second.id)

        XCTAssertFalse(reader.isOpenedFromReadingList)
        XCTAssertTrue(requests.hasRequest(for: second.id))
    }

    /// A closed reader claims nothing: SwiftUI keeps a closed window's
    /// reader, but opening the book again makes a new one, which claims the
    /// request instead.
    func testAClosedReaderClaimsNothing() throws {
        let world = try makeIntegrationWorld("ReadingListClosed")
        let requests = ReadingListOpenRequests()
        let book = try makeAudioBook("First Crossing", in: world)
        list([book], in: world)
        let closed = makeReader(for: book, in: world, requests: requests)
        waitForReaderToLoad(closed)
        closed.close()

        requests.request(for: book.id)

        XCTAssertFalse(closed.isOpenedFromReadingList)
        XCTAssertTrue(requests.hasRequest(for: book.id))
        let reopened = makeReader(for: book, in: world, requests: requests)
        XCTAssertTrue(reopened.isOpenedFromReadingList)
        XCTAssertFalse(requests.hasRequest(for: book.id))
    }

    /// A request older than its lifetime when the reader is made, as when
    /// the book's window never opened, marks nothing, so the book opened
    /// later from a folder reads as any book does.
    func testAStaleRequestMarksNothing() throws {
        let world = try makeIntegrationWorld("ReadingListStale")
        var now = Date()
        let requests = ReadingListOpenRequests(now: { now })
        let book = try makeAudioBook("First Crossing", in: world)
        list([book], in: world)
        requests.request(for: book.id)
        now += ReadingListOpenRequests.lifetime + 1

        let reader = makeReader(for: book, in: world, requests: requests)

        XCTAssertFalse(reader.isOpenedFromReadingList)
        XCTAssertFalse(requests.hasRequest(for: book.id))
    }

    /// A book taken off the list between the open and its reader's claim is
    /// not read from the list, and its request is used up all the same.
    func testABookOffTheListByItsClaimIsNotReadFromIt() throws {
        let world = try makeIntegrationWorld("ReadingListLeftFirst")
        let requests = ReadingListOpenRequests()
        let first = try makeAudioBook("First Crossing", in: world)
        let second = try makeAudioBook("Second Crossing", in: world)
        list([first, second], in: world)
        requests.request(for: second.id)
        world.library.removeFromReadingList([second.id])

        let reader = makeReader(for: second, in: world, requests: requests)

        XCTAssertFalse(reader.isOpenedFromReadingList)
        XCTAssertNil(reader.readingListPlace)
        XCTAssertFalse(requests.hasRequest(for: second.id))
    }

    /// A book's place counts the books the Reading List shows, passing over
    /// an ID that names no book, as the window does; a book not in the list
    /// has no place.
    func testAPlaceCountsTheBooksTheListShows() {
        let almanac = ReadingListTests.book("Almanac")
        let bestiary = ReadingListTests.book("Bestiary")
        let codex = ReadingListTests.book("Codex")
        let library = Library(
            books: [almanac, bestiary, codex],
            readingList: ReadingList(bookIDs: [almanac.id, UUID(), bestiary.id])
        )

        XCTAssertEqual(ReadingListPlace(of: almanac.id, in: library), ReadingListPlace(position: 1, count: 2))
        XCTAssertEqual(ReadingListPlace(of: bestiary.id, in: library), ReadingListPlace(position: 2, count: 2))
        XCTAssertNil(ReadingListPlace(of: codex.id, in: library))
        XCTAssertNil(ReadingListPlace(of: UUID(), in: library))
    }

    // MARK: - The Mark

    /// A reader window is titled "Book: <title> by <author>", or "Book:
    /// <title>" when no author is known; a book read from the reading list
    /// says "Reading List" in place of "Book", which VoiceOver speaks as the
    /// window's title.
    func testTheWindowTitleSaysTheBookIsReadFromTheReadingList() {
        let known = Book(title: "The Salt Road", author: "Wanjiru Abernethy", format: .txt, filePath: "", md5Hash: "")
        let unknown = Book(title: "The Salt Road", format: .txt, filePath: "", md5Hash: "")

        XCTAssertEqual(BookReaderWindowView.windowTitlePrefix, "Book")
        XCTAssertEqual(ReadingListReaderWording.windowTitlePrefix, "Reading List")
        XCTAssertEqual(
            BookReaderWindowView.windowTitle(for: known, readFromReadingList: true),
            "Reading List: The Salt Road by Wanjiru Abernethy"
        )
        XCTAssertEqual(BookReaderWindowView.windowTitle(for: unknown, readFromReadingList: true), "Reading List: The Salt Road")
        XCTAssertEqual(
            BookReaderWindowView.windowTitle(for: known, readFromReadingList: false),
            "Book: The Salt Road by Wanjiru Abernethy"
        )
        XCTAssertEqual(BookReaderWindowView.windowTitle(for: unknown, readFromReadingList: false), "Book: The Salt Road")
    }

    /// The full Where Am I? says where a book read from the list stands in
    /// it, after the times and before a transcript's quoted sentence; for
    /// any other book it is as it was. The header line says the same words.
    func testTheFullWhereAmISaysWhereTheBookStandsInTheList() {
        let headings = (0..<20).map { Heading(level: 2, text: "Part \($0 + 1)", characterOffset: $0 * 100) }
        let position = HeadingPosition(in: headings, chapterIndex: 0, characterOffset: 450)
        func full(place: ReadingListPlace?, heard: String? = nil) -> String {
            ReaderViewModel.fullWhereAmISummary(
                bookTitle: "My Book",
                locationTitle: "The Battle",
                headingPosition: position,
                percentComplete: 25,
                timeRemaining: 10_800,
                timeRemainingInHeading: 900,
                totalTime: 14_400,
                readingListPlace: place,
                heardSentence: heard
            )
        }
        let times = "My Book. The Battle. Heading 5 of 20. 25 percent through the book. "
            + "3 hours remaining. 15 minutes remaining in this heading. Total book time: 4 hours."
        let third = ReadingListPlace(position: 3, count: 12)

        XCTAssertEqual(ReadingListReaderWording.place(third), "Reading list, book 3 of 12")
        XCTAssertEqual(full(place: third), times + " Reading list, book 3 of 12.")
        XCTAssertEqual(
            full(place: third, heard: "The salt road bends east."),
            times + " Reading list, book 3 of 12. The salt road bends east."
        )
        XCTAssertEqual(full(place: nil), times)
    }

    /// A reader reading its book from the list says the book's place in the
    /// full Where Am I? alone: the brief one, pressed often while listening,
    /// is as it was. A reader of the same book opened another way says
    /// nothing of the list.
    func testAReaderReadFromTheListSaysItsPlaceInTheFullWhereAmIAlone() throws {
        let world = try makeIntegrationWorld("ReadingListWhereAmI")
        let requests = ReadingListOpenRequests()
        let first = try makeAudioBook("First Crossing", in: world)
        let second = try makeAudioBook("Second Crossing", in: world)
        let third = try makeAudioBook("Third Crossing", in: world)
        list([first, second, third], in: world)
        requests.request(for: second.id)
        let fromList = makeReader(for: second, in: world, requests: requests)
        let fromFolder = makeReader(for: third, in: world, requests: requests)
        waitForReaderToLoad(fromList)
        waitForReaderToLoad(fromFolder)

        let full = fromList.buildFullWhereAmI(content: try XCTUnwrap(fromList.content))
        let totalTime = TimeFormatting.spoken(fromList.totalEstimatedTime)
        XCTAssertTrue(full.hasSuffix("Total book time: \(totalTime). Reading list, book 2 of 3."), full)
        XCTAssertFalse(fromList.buildBriefWhereAmI().contains("Reading list"), fromList.buildBriefWhereAmI())
        let other = fromFolder.buildFullWhereAmI(content: try XCTUnwrap(fromFolder.content))
        XCTAssertFalse(other.contains("Reading list"), other)
    }

    /// The place follows the list as the Library window changes it: a move,
    /// an addition, and another book's removal each move it, while a change
    /// of the list's options leaves it.
    func testThePlaceFollowsTheListAsItChanges() throws {
        let world = try makeIntegrationWorld("ReadingListPlaceFollows")
        let requests = ReadingListOpenRequests()
        let first = try makeAudioBook("First Crossing", in: world)
        let second = try makeAudioBook("Second Crossing", in: world)
        let third = try makeAudioBook("Third Crossing", in: world)
        let fourth = try makeAudioBook("Fourth Crossing", in: world)
        list([first, second, third], in: world)
        requests.request(for: second.id)
        let reader = makeReader(for: second, in: world, requests: requests)
        XCTAssertEqual(reader.readingListPlace, ReadingListPlace(position: 2, count: 3))

        world.library.moveInReadingList(bookID: second.id, direction: .up)
        XCTAssertEqual(reader.readingListPlace, ReadingListPlace(position: 1, count: 3), "a move")
        world.library.addToReadingList([fourth.id])
        XCTAssertEqual(reader.readingListPlace, ReadingListPlace(position: 1, count: 4), "an addition")
        world.library.moveInReadingList(bookID: third.id, direction: .up)
        world.library.moveInReadingList(bookID: third.id, direction: .up)
        XCTAssertEqual(reader.readingListPlace, ReadingListPlace(position: 2, count: 4), "a book moved above it")
        world.library.removeFromReadingList([first.id])
        XCTAssertEqual(reader.readingListPlace, ReadingListPlace(position: 2, count: 3), "another book's removal")
        world.library.setReadingListContinuation(.stop)
        world.library.setReadingListSkipsFinished(false)
        XCTAssertEqual(reader.readingListPlace, ReadingListPlace(position: 2, count: 3), "an option")
    }

    /// A book taken off the list while its reader is open is no longer read
    /// from it: its title says "Book" again. Put back on the list, it stays
    /// as any book until it is opened from the list again.
    func testABookTakenOffTheListWhileOpenIsNoLongerReadFromIt() throws {
        let world = try makeIntegrationWorld("ReadingListLeaves")
        let requests = ReadingListOpenRequests()
        let first = try makeAudioBook("First Crossing", in: world)
        let second = try makeAudioBook("Second Crossing", in: world)
        list([first, second], in: world)
        requests.request(for: second.id)
        let reader = makeReader(for: second, in: world, requests: requests)
        waitForReaderToLoad(reader)
        XCTAssertEqual(title(of: reader), "Reading List: Second Crossing")

        world.library.removeFromReadingList([second.id])

        XCTAssertFalse(reader.isOpenedFromReadingList)
        XCTAssertNil(reader.readingListPlace)
        XCTAssertEqual(title(of: reader), "Book: Second Crossing")
        world.library.addToReadingList([second.id])
        XCTAssertFalse(reader.isOpenedFromReadingList, "put back on the list, it was read from it again unasked")
        requests.request(for: second.id)
        XCTAssertEqual(reader.readingListPlace, ReadingListPlace(position: 2, count: 2), "opened from the list again")
    }

    /// A book removed from the library while its reader is open leaves the
    /// list with it, so it is no longer read from the list either.
    func testABookRemovedFromTheLibraryWhileOpenIsNoLongerReadFromTheList() throws {
        let world = try makeIntegrationWorld("ReadingListRemoved")
        let requests = ReadingListOpenRequests()
        let first = try makeAudioBook("First Crossing", in: world)
        let second = try makeAudioBook("Second Crossing", in: world)
        list([first, second], in: world)
        requests.request(for: second.id)
        let reader = makeReader(for: second, in: world, requests: requests)
        XCTAssertTrue(reader.isOpenedFromReadingList)

        world.library.library.removeBook(id: second.id)

        XCTAssertFalse(reader.isOpenedFromReadingList)
        XCTAssertEqual(title(of: reader), "Book: Second Crossing")
    }

    // MARK: - Fixtures

    /// The title `reader`'s window shows now.
    private func title(of reader: ReaderViewModel) -> String {
        BookReaderWindowView.windowTitle(for: reader.book, readFromReadingList: reader.isOpenedFromReadingList)
    }

    /// The tracks of every fixture audiobook, in seconds: longer than any
    /// test runs, so no chapter ends by itself.
    private static let trackDurations: [TimeInterval] = [5, 5]

    /// A silent audiobook titled `title` in `world`, listed in its library,
    /// ending as `endOfBook` says when read from anywhere but the list.
    private func makeAudioBook(
        _ title: String,
        in world: IntegrationWorld,
        endOfBook: EndOfBookBehavior = .stop
    ) throws -> Book {
        try world.makeSilentAudioBook(title: title, trackDurations: Self.trackDurations, endOfBook: endOfBook)
    }

    /// A text book titled `title`, imported into `world` as a chosen file
    /// is and listed in its library. No test plays one, so it is never
    /// heard.
    private func makeTextBook(_ title: String, in world: IntegrationWorld) throws -> Book {
        let source = try makeSandboxDirectory("ReadingListText").appendingPathComponent("\(title).txt")
        try Data("\(title)\n\nThe ferry leaves the slip at first light.\n\nGulls follow it past the breakwater.\n".utf8)
            .write(to: source)
        return try world.importBook(from: source)
    }

    /// Makes `books`, in that order, the reading list of `world`'s library,
    /// with the options given, as library.json holds it. Nothing is saved.
    private func list(
        _ books: [Book],
        in world: IntegrationWorld,
        continuation: ReadingList.Continuation = .playBookBelow,
        skipsFinished: Bool = true
    ) {
        world.library.library.readingList = ReadingList(
            bookIDs: books.map(\.id),
            continuation: continuation,
            skipsFinished: skipsFinished
        )
    }

    /// A reader for `book` in `world`, which starts loading at once, and
    /// claims what `requests` holds for its book, as a reader window's
    /// model does. It is closed when the test ends, before the world is
    /// taken apart.
    private func makeReader(
        for book: Book,
        in world: IntegrationWorld,
        requests: ReadingListOpenRequests
    ) -> ReaderViewModel {
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: world.library,
            settingsViewModel: world.settings,
            substitutionService: TextSubstitutionService(rules: []),
            autoplayRequests: world.autoplayRequests,
            readingListRequests: requests,
            notificationCenter: world.notifications
        )
        addTeardownBlock { reader.close() }
        return reader
    }
}
