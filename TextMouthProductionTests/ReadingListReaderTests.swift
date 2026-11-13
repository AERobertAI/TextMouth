import AppKit
import Combine
import XCTest
@testable import TextMouth

/// A book read from the reading list (FR09, the reader's part): the request
/// a Library window leaves as it opens a book from the Reading List, and the
/// book's reader claiming it, once, as the open makes the reader or brings
/// its window forward; the mark that says so: the window's title, the
/// header's line, and the full Where Am I?, which follow the list as it
/// changes and end when the book leaves it; and the end of a book read from
/// the list, which goes where the list's options say, in place of the
/// book's own end-of-book behavior, under the sleep timer's rules; and
/// Next in Reading List and Previous in Reading List.
///
/// Every book is a package of silent audio tracks, or a text book that no
/// test plays, so nothing is heard. Each test's readers share a private
/// request store and listen on a private notification center (the
/// integration world's), so the running app's own windows never see these
/// requests, and announcements are recorded instead of spoken.
@MainActor
final class ReadingListReaderTests: XCTestCase {
    /// Subscriptions a test keeps until it ends.
    private var subscriptions = Set<AnyCancellable>()

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

    // MARK: - The End of a Book

    /// Every way a book ends words what the ways share alike: "Finished:
    /// <title>" alone, with no full stop, or followed by each reason as a
    /// sentence of its own, the sleep timer's last; "Starting: <title>" for
    /// the book that follows; "Restarting: <title>" for a book that loops.
    /// These are the words a book's own end-of-book behavior has always
    /// said.
    func testEveryEndOfABookIsWordedInOnePlace() {
        let title = "The Salt Road"
        XCTAssertEqual(EndOfBookWording.finished(title), "Finished: The Salt Road")
        XCTAssertEqual(EndOfBookWording.finished(title, sleepTimerExpired: true), "Finished: The Salt Road. Sleep timer expired.")
        XCTAssertEqual(
            EndOfBookWording.finished(title, notes: [EndOfBookWording.noMoreBooksInFolderNote]),
            "Finished: The Salt Road. No more books in folder."
        )
        XCTAssertEqual(
            EndOfBookWording.finished(title, notes: [EndOfBookWording.noMoreBooksInFolderNote], sleepTimerExpired: true),
            "Finished: The Salt Road. No more books in folder. Sleep timer expired."
        )
        XCTAssertEqual(
            EndOfBookWording.finished(title, notes: [EndOfBookWording.nextBookNotStartedNote]),
            "Finished: The Salt Road. Next book not started because of the sleep timer."
        )
        XCTAssertEqual(
            EndOfBookWording.finished(title, notes: [EndOfBookWording.notRestartedNote]),
            "Finished: The Salt Road. Not restarted because of the sleep timer."
        )
        XCTAssertEqual(EndOfBookWording.starting(title), "Starting: The Salt Road")
        XCTAssertEqual(EndOfBookWording.restarting(title), "Restarting: The Salt Road")
    }

    // MARK: - The End of a Book Read from the List

    /// A book read from the list that ends goes on to the book below it, as
    /// the list's default says: it says "Starting: <title>" once, counts the
    /// book finished, and after a moment leaves the next book a request to
    /// be read from the list and one to start playing, then asks for its
    /// window, naming both books. The reader the window makes reads the
    /// next book from the list and plays it. The book that continued rests
    /// at its end no longer, as one that continues in its folder does: the
    /// next book takes the media controls (REV07, speech finding 5).
    func testABookReadFromTheListContinuesToTheBookBelow() throws {
        let world = try makeIntegrationWorld("ReadingListContinuesDown")
        let requests = ReadingListOpenRequests()
        let first = try makeAudioBook("First Crossing", in: world)
        let second = try makeAudioBook("Second Crossing", in: world)
        let third = try makeAudioBook("Third Crossing", in: world)
        list([first, second, third], in: world)
        let reader = makeReaderFromList(for: first, in: world, requests: requests)
        let asked = record(.continueToNextBook, in: world)

        let recorder = recordingAnnouncements {
            reader.handleEndOfBook()
            XCTAssertTrue(asked().isEmpty, "Asked before the announcement had a moment")
            XCTAssertFalse(requests.hasRequest(for: second.id), "Requested before the announcement had a moment")
            XCTAssertTrue(eventually { !asked().isEmpty }, "Never asked for the next book")
            // Long enough for any second request to arrive.
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Starting: Second Crossing"])
        XCTAssertEqual(asked().map(\.nextBookID), [second.id])
        XCTAssertEqual(asked().first?.userInfo?[Notification.ContinueToNextBookKey.previousBookID] as? UUID, first.id)
        XCTAssertTrue(requests.hasRequest(for: second.id), "No request to read the next book from the list")
        XCTAssertTrue(world.autoplayRequests.hasRequest(for: second.id), "No request to start the next book")
        XCTAssertEqual(ReadingStatsService.shared.stats.finishedBooks.map(\.bookID), [first.id.uuidString])
        XCTAssertFalse(reader.hasFinishedBook, "The book that continued through the list still rests finished at its end")
        // It played to its end, and is saved exactly there (TODO P07).
        XCTAssertTrue(reader.cursorRestsAtEnd, "The book that continued is not at its end")
        XCTAssertEqual(
            world.library.bookByID(first.id)?.readingPosition?.globalCharacterOffset,
            reader.content?.totalCharacterCount,
            "The book that continued is not saved at its end"
        )
        XCTAssertFalse(reader.isCurrentlyPlaying)

        // The window opened for the requests makes the next book's reader.
        let next = makeReader(for: second, in: world, requests: requests)
        XCTAssertEqual(next.readingListPlace, ReadingListPlace(position: 2, count: 3))
        XCTAssertTrue(eventually(within: Self.playbackStartTimeout) { next.isCurrentlyPlaying }, "The next book never started")
        XCTAssertTrue(next.audioPlaybackService.isPlaying)
        XCTAssertFalse(world.autoplayRequests.hasRequest(for: second.id))
    }

    /// With "Play the book above" chosen, a book read from the list goes on
    /// to the book above it.
    func testABookReadFromTheListContinuesToTheBookAboveWhenTheListSaysSo() throws {
        let world = try makeIntegrationWorld("ReadingListContinuesUp")
        let requests = ReadingListOpenRequests()
        let first = try makeAudioBook("First Crossing", in: world)
        let second = try makeAudioBook("Second Crossing", in: world)
        let third = try makeAudioBook("Third Crossing", in: world)
        list([first, second, third], in: world, continuation: .playBookAbove)
        let reader = makeReaderFromList(for: third, in: world, requests: requests)
        let asked = record(.continueToNextBook, in: world)

        let recorder = recordingAnnouncements {
            reader.handleEndOfBook()
            XCTAssertTrue(eventually { !asked().isEmpty }, "Never asked for the book above")
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Starting: Second Crossing"])
        XCTAssertEqual(asked().map(\.nextBookID), [second.id])
        XCTAssertTrue(requests.hasRequest(for: second.id))
    }

    // MARK: - Removing a Finished Book

    /// With "Remove books when finished" on and the list playing the book
    /// below, the book read from the list that ends goes on to the book that
    /// followed it, and then leaves the list; the end says what it always
    /// says, and nothing more.
    func testARemovedFinishedBookStillContinuesToTheBookBelow() throws {
        try checkTheEndOfASecondBookRemovesItAndContinues(.playBookBelow, toward: "Third Crossing")
    }

    /// The same going up: the book that preceded the finished one follows.
    func testARemovedFinishedBookStillContinuesToTheBookAbove() throws {
        try checkTheEndOfASecondBookRemovesItAndContinues(.playBookAbove, toward: "First Crossing")
    }

    /// The same with Stop: nothing follows, the end says why as it always
    /// did, and the finished book leaves the list all the same.
    func testARemovedFinishedBookStopsWhenTheListSaysStop() throws {
        try checkTheEndOfASecondBookRemovesItAndContinues(.stop, toward: nil)
    }

    /// With Skip Finished Books on as well, the books after the removed one
    /// are still passed over when finished: the finished book beside it
    /// stays on the list, since it was finished before the option could act,
    /// and the book after that follows.
    func testSkippingFinishedBooksStillAppliesAfterARemoval() throws {
        let world = try makeIntegrationWorld("ReadingListRemovesAndSkips")
        let requests = ReadingListOpenRequests()
        let first = try makeAudioBook("First Crossing", in: world)
        let second = try makeAudioBook("Second Crossing", in: world)
        let third = try makeAudioBook("Third Crossing", in: world)
        let fourth = try makeAudioBook("Fourth Crossing", in: world)
        list([first, second, third, fourth], in: world, skipsFinished: true, removesFinished: true)
        // The third book was finished before; Books Finished says so.
        ReadingStatsService.shared.markBookFinished(bookID: third.id, title: third.title)
        let reader = makeReaderFromList(for: second, in: world, requests: requests)
        world.library.observeFinishedBooks()
        let asked = record(.continueToNextBook, in: world)

        let recorder = recordingAnnouncements {
            reader.handleEndOfBook()
            XCTAssertTrue(world.library.readingList.contains(second.id), "removed within the end, before the list was asked what follows")
            XCTAssertTrue(eventually { !asked().isEmpty }, "Never asked for the next book")
            XCTAssertTrue(eventually { !world.library.readingList.contains(second.id) }, "never removed once the reader moved on")
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Starting: Fourth Crossing"])
        XCTAssertEqual(asked().map(\.nextBookID), [fourth.id])
        XCTAssertEqual(world.library.readingList.bookIDs, [first.id, third.id, fourth.id])
    }

    /// A book finished while not opened from the list leaves it too, the
    /// end saying what the book's own end-of-book behavior says and nothing
    /// of the list.
    func testABookFinishedOutsideTheListLeavesItWhenTheOptionIsOn() throws {
        let world = try makeIntegrationWorld("ReadingListRemovesAnyFinishedBook")
        let requests = ReadingListOpenRequests()
        let first = try makeAudioBook("First Crossing", in: world)
        let second = try makeAudioBook("Second Crossing", in: world)
        list([first, second], in: world, removesFinished: true)
        // Opened from the library, not the list.
        let reader = makeReader(for: second, in: world, requests: requests)
        waitForReaderToLoad(reader)
        XCTAssertFalse(reader.isOpenedFromReadingList)
        world.library.observeFinishedBooks()

        let recorder = recordingAnnouncements {
            reader.handleEndOfBook()
            XCTAssertTrue(eventually { !world.library.readingList.contains(second.id) }, "never removed")
        }

        XCTAssertEqual(world.library.readingList.bookIDs, [first.id])
        XCTAssertEqual(recorder.announcements.map(\.message), [EndOfBookWording.finished(second.title)])
    }

    /// With the option off, which is how a list starts, a finished book stays
    /// on the list, whether it was opened from it or not, as before.
    func testAFinishedBookStaysOnTheListWhenTheOptionIsOff() throws {
        let world = try makeIntegrationWorld("ReadingListKeepsFinishedBooks")
        let requests = ReadingListOpenRequests()
        let first = try makeAudioBook("First Crossing", in: world)
        let second = try makeAudioBook("Second Crossing", in: world)
        list([first, second], in: world, continuation: .stop)
        let reader = makeReaderFromList(for: first, in: world, requests: requests)
        world.library.observeFinishedBooks()

        reader.handleEndOfBook()
        spinMainRunLoop(for: 0.3)

        XCTAssertEqual(world.library.readingList.bookIDs, [first.id, second.id])
        XCTAssertEqual(ReadingStatsService.shared.stats.finishedBooks.map(\.bookID), [first.id.uuidString])
    }

    /// A finished book stays the list's while its reader rests on it, so a
    /// rewind's replay of the end obeys the list, not the book's own end
    /// rule (the user, October 7, 2026): with the list set to Stop, a book
    /// that loops on its own stops again, and stays on the list.
    func testAReplayedEndObeysTheListWhileTheFinishedBookStaysOnIt() throws {
        let world = try makeIntegrationWorld("ReadingListRemovesThenReplays")
        let requests = ReadingListOpenRequests()
        let first = try makeAudioBook("First Crossing", in: world)
        let second = try makeAudioBook("Second Crossing", in: world, endOfBook: .loop)
        list([first, second], in: world, continuation: .stop, removesFinished: true)
        let reader = makeReaderFromList(for: second, in: world, requests: requests)
        world.library.observeFinishedBooks()
        reader.handleEndOfBook()
        spinMainRunLoop(for: 0.3)
        XCTAssertTrue(world.library.readingList.contains(second.id), "removed while its reader rests on it")
        XCTAssertTrue(reader.isOpenedFromReadingList, "the reader forgot the list at its book's end")

        // A rewind after the end plays it again, and the end replays.
        let recorder = recordingAnnouncements {
            reader.replaysFinishedEnd = true
            reader.handleEndOfBook()
            spinMainRunLoop(for: 0.3)
        }

        XCTAssertEqual(
            recorder.announcements.map(\.message),
            [EndOfBookWording.finished(second.title, notes: [ReadingListReaderWording.stopNote])],
            "the replayed end did not obey the list's Stop"
        )
        XCTAssertTrue(world.library.readingList.contains(second.id))
        XCTAssertEqual(ReadingStatsService.shared.stats.finishedBooks.map(\.bookID), [second.id.uuidString], "a replay counted anew")
    }

    /// Play at the end of a finished book, which the list stopped, still goes
    /// on to the list's next book once the list says to: the reader still
    /// reads the book from the list, and the book leaves the list when it
    /// has handed over.
    func testPlayAtTheEndStillGoesOnThroughTheListAndThenTheBookLeaves() throws {
        let world = try makeIntegrationWorld("ReadingListRemovesThenPlays")
        let requests = ReadingListOpenRequests()
        let first = try makeAudioBook("First Crossing", in: world)
        let second = try makeAudioBook("Second Crossing", in: world)
        list([first, second], in: world, continuation: .stop, removesFinished: true)
        let reader = makeReaderFromList(for: first, in: world, requests: requests)
        world.library.observeFinishedBooks()
        let asked = record(.continueToNextBook, in: world)
        reader.handleEndOfBook()
        spinMainRunLoop(for: 0.3)
        XCTAssertTrue(world.library.readingList.contains(first.id), "removed while its reader rests on it")

        list([first, second], in: world, continuation: .playBookBelow, removesFinished: true)
        let recorder = recordingAnnouncements {
            reader.play()
            XCTAssertTrue(eventually { !asked().isEmpty }, "Play at the end never asked for the book below")
            XCTAssertTrue(eventually { !world.library.readingList.contains(first.id) }, "never removed once the reader moved on")
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Starting: Second Crossing"])
        XCTAssertEqual(asked().map(\.nextBookID), [second.id])
        XCTAssertEqual(world.library.readingList.bookIDs, [second.id])
    }

    /// Next in Reading List after a Stop at the end of a finished book still
    /// works, since the book is still the list's, and the book leaves the list
    /// once the reader has moved to the next book.
    func testNextInReadingListAfterTheEndStillWorksThenTheBookLeaves() throws {
        let world = try makeIntegrationWorld("ReadingListRemovesThenNext")
        let requests = ReadingListOpenRequests()
        let first = try makeAudioBook("First Crossing", in: world)
        let second = try makeAudioBook("Second Crossing", in: world)
        list([first, second], in: world, continuation: .stop, removesFinished: true)
        let reader = makeReaderFromList(for: first, in: world, requests: requests)
        world.library.observeFinishedBooks()
        let opened = record(.openBookWindow, in: world)
        reader.handleEndOfBook()
        spinMainRunLoop(for: 0.3)

        let recorder = recordingAnnouncements {
            reader.goThroughReadingList(.down)
            XCTAssertTrue(eventually { !opened().isEmpty }, "Never opened the next book")
            XCTAssertTrue(eventually { !world.library.readingList.contains(first.id) }, "never removed once the reader moved on")
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }

        XCTAssertFalse(
            recorder.announcements.map(\.message).contains(ReadingListReaderWording.notReadFromReadingList),
            "Next said the book was not read from the list"
        )
        XCTAssertEqual(opened().map { $0.object as? UUID }, [second.id])
        XCTAssertEqual(world.library.readingList.bookIDs, [second.id])
    }

    /// A reader gone before the end is told, or no reader at all (a book
    /// finished elsewhere, as a feed item marked played), leaves nothing
    /// holding the book: it leaves the list at once, one turn after the end.
    func testAFinishedBookWithNoReaderRestingOnItLeavesAtOnce() throws {
        let world = try makeIntegrationWorld("ReadingListRemovesWithNoReader")
        let requests = ReadingListOpenRequests()
        let first = try makeAudioBook("First Crossing", in: world)
        let second = try makeAudioBook("Second Crossing", in: world)
        list([first, second], in: world, continuation: .stop, removesFinished: true)
        world.library.observeFinishedBooks()

        // No reader: the book is finished where the library hears of it alone.
        ReadingStatsService.shared.markBookFinished(bookID: first.id, title: first.title)
        XCTAssertTrue(eventually { !world.library.readingList.contains(first.id) }, "never removed with no reader")

        // A reader that read the book from the list and closed before its end
        // was told (a hold made and released) holds nothing.
        let reader = makeReaderFromList(for: second, in: world, requests: requests)
        reader.holdFinishedBookOnReadingList()
        reader.close()
        ReadingStatsService.shared.markBookFinished(bookID: second.id, title: second.title)
        XCTAssertTrue(eventually { !world.library.readingList.contains(second.id) }, "never removed after its reader closed")
        XCTAssertTrue(world.library.finishedBooksAwaitingRelease.isEmpty)
        XCTAssertTrue(world.library.readingListHoldCounts.isEmpty)
    }

    /// A book held by two readers (two windows of one book) leaves the list
    /// only when the last of them lets go.
    func testAFinishedBookHeldTwiceLeavesWhenTheLastHoldIsReleased() throws {
        let world = try makeIntegrationWorld("ReadingListRemovesHeldTwice")
        let first = try makeAudioBook("First Crossing", in: world)
        list([first], in: world, removesFinished: true)
        world.library.observeFinishedBooks()
        world.library.holdFinishedBookOnReadingList(first.id)
        world.library.holdFinishedBookOnReadingList(first.id)
        ReadingStatsService.shared.markBookFinished(bookID: first.id, title: first.title)
        spinMainRunLoop(for: 0.3)

        world.library.releaseFinishedBookFromReadingList(first.id)
        XCTAssertTrue(world.library.readingList.contains(first.id), "left with a hold remaining")
        world.library.releaseFinishedBookFromReadingList(first.id)
        XCTAssertFalse(world.library.readingList.contains(first.id), "stayed after the last hold was released")
    }

    /// The library started as the app starts it (`startLibrary()`) hears of
    /// finished books and of changes to the list by itself: a listed book
    /// leaves the list when Books Finished counts it, and the kept books
    /// receive the list's IDs, then drop the one that left. Nothing here
    /// calls an observer: deleting either observer's line from `startLibrary()`
    /// fails this test, as the app would lose the feature. The library is a
    /// sandbox's, never the user's.
    func testALibraryStartedAsTheAppStartsItWiresBothReadingListObservers() async throws {
        let fixture = try LibraryFixture(test: self, label: "ReadingListWiring")
        let model = LibraryViewModel(dataDirectoryEnvironment: fixture.environment)
        XCTAssertTrue(model.hasStartedLibrary, "the library did not start")
        let kept = KeptBooks(file: nil)
        model.cloudCommands = LibraryCloudCommands(
            states: BookCloudStates(),
            kept: kept,
            storage: { FakeBookCloudStorage(location: .local) }
        )
        let first = cloudTestBook("First Crossing")
        let second = cloudTestBook("Second Crossing")
        model.library = Library(books: [first, second])

        // The list changes: the kept books receive its books.
        model.library.readingList = ReadingList(bookIDs: [first.id, second.id], removesFinished: true)
        await drainMainQueue()
        XCTAssertEqual(kept.readingListBookIDs, [first.id, second.id], "the list's books never reached the kept books")

        // A listed book is finished: it leaves the list, and is no longer kept for it.
        ReadingStatsService.shared.markBookFinished(bookID: first.id, title: first.title)
        let left = await eventually { model.library.readingList.bookIDs == [second.id] }
        XCTAssertTrue(left, "the finished book never left the list")
        await drainMainQueue()
        XCTAssertEqual(kept.readingListBookIDs, [second.id])
    }

    /// Three books on a list with the option on, the second read from the
    /// list under `continuation`: the end counts the book finished and says
    /// "Starting: <title>" of `next`, or why nothing follows when it is nil;
    /// the second book is still on the list when the end returns, so the
    /// list could be asked what follows it, and leaves it once its reader has
    /// moved on to the next book, or closed when nothing followed; and the
    /// others keep their order.
    private func checkTheEndOfASecondBookRemovesItAndContinues(
        _ continuation: ReadingList.Continuation,
        toward next: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let world = try makeIntegrationWorld("ReadingListRemoves\(continuation.rawValue)")
        let requests = ReadingListOpenRequests()
        let first = try makeAudioBook("First Crossing", in: world)
        let second = try makeAudioBook("Second Crossing", in: world)
        let third = try makeAudioBook("Third Crossing", in: world)
        list([first, second, third], in: world, continuation: continuation, removesFinished: true)
        let reader = makeReaderFromList(for: second, in: world, requests: requests, file: file, line: line)
        world.library.observeFinishedBooks()
        let asked = record(.continueToNextBook, in: world)
        let nextBook = [first, third].first { $0.title == next }

        let recorder = recordingAnnouncements {
            reader.handleEndOfBook()
            XCTAssertTrue(
                world.library.readingList.contains(second.id),
                "removed within the end, before the list was asked what follows", file: file, line: line
            )
            if nextBook != nil {
                XCTAssertTrue(eventually { !asked().isEmpty }, "Never asked for the next book", file: file, line: line)
                // The book leaves once its reader has moved on to the next.
                XCTAssertTrue(
                    eventually { !world.library.readingList.contains(second.id) },
                    "never removed once the reader moved on", file: file, line: line
                )
            }
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }
        if nextBook == nil {
            // Nothing followed: the reader rests on its book, still the
            // list's, until it closes.
            XCTAssertTrue(world.library.readingList.contains(second.id), "removed while its reader rested on it", file: file, line: line)
            XCTAssertTrue(reader.isOpenedFromReadingList, file: file, line: line)
            reader.close()
            XCTAssertTrue(eventually { !world.library.readingList.contains(second.id) }, "never removed once the reader closed", file: file, line: line)
        }

        XCTAssertEqual(world.library.readingList.bookIDs, [first.id, third.id], file: file, line: line)
        XCTAssertEqual(world.library.readingList.continuation, continuation, file: file, line: line)
        XCTAssertEqual(ReadingStatsService.shared.stats.finishedBooks.map(\.bookID), [second.id.uuidString], file: file, line: line)
        XCTAssertEqual(asked().map(\.nextBookID), nextBook.map { [$0.id] } ?? [], file: file, line: line)
        let expectedWords = next.map { "Starting: \($0)" }
            ?? EndOfBookWording.finished(second.title, notes: [ReadingListReaderWording.stopNote])
        XCTAssertEqual(recorder.announcements.map(\.message), [expectedWords], file: file, line: line)
        if let nextBook {
            XCTAssertTrue(requests.hasRequest(for: nextBook.id), "No request to read the next book from the list", file: file, line: line)
        }
    }

    /// The list's choice overrides the book's own end-of-book behavior, as
    /// the user decided on October 7: a book set to loop stops when the
    /// list says Stop, and a book set to continue in its folder goes on to
    /// the list's next book, not its folder's.
    func testTheListsChoiceOverridesTheBooksOwnEndOfBookBehavior() throws {
        let world = try makeIntegrationWorld("ReadingListOverrides")
        let requests = ReadingListOpenRequests()
        // In the folder, by title: Alpha, Beta, Delta, Gamma.
        let alpha = try makeAudioBook("Alpha Crossing", in: world, endOfBook: .loop)
        let beta = try makeAudioBook("Beta Crossing", in: world, endOfBook: .continueNext)
        _ = try makeAudioBook("Delta Crossing", in: world)
        let gamma = try makeAudioBook("Gamma Crossing", in: world)
        let asked = record(.continueToNextBook, in: world)

        list([alpha, gamma], in: world, continuation: .stop)
        let looping = makeReaderFromList(for: alpha, in: world, requests: requests)
        let stopping = recordingAnnouncements {
            looping.handleEndOfBook()
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }
        XCTAssertEqual(
            stopping.announcements.map(\.message),
            ["Finished: Alpha Crossing. The reading list is set to stop when a book ends."]
        )
        XCTAssertTrue(looping.hasFinishedBook, "the book looped back to its beginning")
        XCTAssertFalse(looping.audioPlaybackService.isPlaying, "the book started again")
        XCTAssertTrue(asked().isEmpty)

        list([beta, gamma], in: world)
        let continuing = makeReaderFromList(for: beta, in: world, requests: requests)
        XCTAssertEqual(world.library.nextBookInFolder(after: beta)?.title, "Delta Crossing")
        let starting = recordingAnnouncements {
            continuing.handleEndOfBook()
            XCTAssertTrue(eventually { !asked().isEmpty }, "Never asked for the list's next book")
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }
        XCTAssertEqual(starting.announcements.map(\.message), ["Starting: Gamma Crossing"])
        XCTAssertEqual(asked().map(\.nextBookID), [gamma.id])
        XCTAssertTrue(requests.hasRequest(for: gamma.id))
    }

    /// Finished books, as Books Finished records them, are passed over while
    /// the list says so: the book goes on past every finished book to the
    /// nearest one not finished; with Skip Finished Books off, to the
    /// finished book beside it.
    func testFinishedBooksArePassedOverWhileTheListSaysSo() throws {
        let world = try makeIntegrationWorld("ReadingListSkipsFinished")
        let requests = ReadingListOpenRequests()
        let first = try makeAudioBook("First Crossing", in: world)
        let second = try makeAudioBook("Second Crossing", in: world)
        let third = try makeAudioBook("Third Crossing", in: world)
        list([first, second, third], in: world)
        ReadingStatsService.shared.markBookFinished(bookID: second.id, title: second.title)
        let reader = makeReaderFromList(for: first, in: world, requests: requests)
        let asked = record(.continueToNextBook, in: world)

        let skipping = recordingAnnouncements {
            reader.handleEndOfBook()
            XCTAssertTrue(eventually { asked().count == 1 }, "Never asked for the next book")
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }
        XCTAssertEqual(skipping.announcements.map(\.message), ["Starting: Third Crossing"])
        XCTAssertEqual(asked().map(\.nextBookID), [third.id])

        world.library.setReadingListSkipsFinished(false)
        let notSkipping = recordingAnnouncements {
            reader.handleEndOfBook()
            XCTAssertTrue(eventually { asked().count == 2 }, "Never asked for the finished book")
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }
        XCTAssertEqual(notSkipping.announcements.map(\.message), ["Starting: Second Crossing"])
        XCTAssertEqual(asked().map(\.nextBookID), [third.id, second.id])
    }

    /// A book with nothing after it in the list stops there and says why:
    /// Stop chosen, the end of the list going down, its start going up, or
    /// only finished books beyond, either way. It asks for nothing, rests
    /// finished, and is counted in Books Finished.
    func testABookWithNothingAfterItInTheListStopsAndSaysWhy() throws {
        let world = try makeIntegrationWorld("ReadingListStops")
        let requests = ReadingListOpenRequests()
        let first = try makeAudioBook("First Crossing", in: world)
        let second = try makeAudioBook("Second Crossing", in: world)
        let third = try makeAudioBook("Third Crossing", in: world)
        let asked = record(.continueToNextBook, in: world)
        let cases: [(continuation: ReadingList.Continuation, reading: Book, finished: [Book], announcement: String)] = [
            (.stop, second, [], "Finished: Second Crossing. The reading list is set to stop when a book ends."),
            (.playBookBelow, third, [], "Finished: Third Crossing. End of the reading list."),
            (.playBookAbove, first, [], "Finished: First Crossing. Start of the reading list."),
            (.playBookBelow, first, [second, third], "Finished: First Crossing. Every book below it in the reading list is finished."),
            (.playBookAbove, third, [first, second], "Finished: Third Crossing. Every book above it in the reading list is finished."),
        ]
        for testCase in cases {
            list([first, second, third], in: world, continuation: testCase.continuation)
            let finished = Set(testCase.finished.map(\.id))
            world.library.finishedBookIDs = { finished }
            let reader = makeReaderFromList(for: testCase.reading, in: world, requests: requests)

            let recorder = recordingAnnouncements {
                reader.handleEndOfBook()
                spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
            }

            XCTAssertEqual(recorder.announcements.map(\.message), [testCase.announcement], testCase.announcement)
            XCTAssertTrue(asked().isEmpty, testCase.announcement)
            for book in [first, second, third] {
                XCTAssertFalse(requests.hasRequest(for: book.id), "\(testCase.announcement): requested \(book.title)")
                XCTAssertFalse(world.autoplayRequests.hasRequest(for: book.id), "\(testCase.announcement): started \(book.title)")
            }
            XCTAssertTrue(reader.hasFinishedBook, testCase.announcement)
            XCTAssertTrue(reader.cursorRestsAtEnd, "\(testCase.announcement): not at the end")
            // Counted once, though a book ends here in two of the cases
            // (TODO P07: one finish per book).
            XCTAssertTrue(
                ReadingStatsService.shared.stats.finishedBookIDs.contains(testCase.reading.id),
                "\(testCase.announcement): not counted"
            )
            // Its window closes, so the next case opens its book afresh.
            reader.close()
        }
    }

    /// Play on a finished book read from the list does what the list's end
    /// did, without playing the end again or counting it again (TODO P07;
    /// the user, October 10, 2026, question 13): with the list set to stop,
    /// it says so again and plays nothing; once the list plays the book
    /// below, Play goes on to that book, "Starting: <title>", as the end
    /// would have.
    func testPlayOnAFinishedBookReadFromTheListDoesWhatTheListsEndDoes() throws {
        let world = try makeIntegrationWorld("ReadingListPlayAtTheEnd")
        let requests = ReadingListOpenRequests()
        let first = try makeAudioBook("First Crossing", in: world)
        let second = try makeAudioBook("Second Crossing", in: world)
        list([first, second], in: world, continuation: .stop)
        let reader = makeReaderFromList(for: first, in: world, requests: requests)
        let asked = record(.continueToNextBook, in: world)
        reader.handleEndOfBook()
        XCTAssertTrue(reader.cursorRestsAtEnd, "The book did not rest at its end")

        let stopping = recordingAnnouncements {
            reader.play()
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }
        XCTAssertEqual(
            stopping.announcements.map(\.message),
            ["Finished: First Crossing. The reading list is set to stop when a book ends."]
        )
        XCTAssertFalse(reader.audioPlaybackService.isPlaying, "Play at the end played the book")
        XCTAssertTrue(asked().isEmpty, "Play at the end asked for a book while the list stops")

        list([first, second], in: world, continuation: .playBookBelow)
        let continuing = recordingAnnouncements {
            reader.play()
            XCTAssertTrue(eventually { !asked().isEmpty }, "Play at the end never asked for the book below")
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }
        XCTAssertEqual(continuing.announcements.map(\.message), ["Starting: Second Crossing"])
        XCTAssertEqual(asked().map(\.nextBookID), [second.id])
        XCTAssertFalse(reader.audioPlaybackService.isPlaying, "Play at the end played the book")
        XCTAssertEqual(ReadingStatsService.shared.stats.finishedBooks.map(\.bookID), [first.id.uuidString])
    }

    /// The sleep timer keeps its rules for a book read from the list where it
    /// ends listening: a timer of this reader's set for the end of a heading
    /// or of the book starts nothing in the list, and says so; a timer that
    /// stopped playback at the book's end is said after why nothing follows.
    /// Another reader's timer does not stop the list. A timer counting minutes
    /// goes on with the next book instead (0.2.5).
    func testTheSleepTimerKeepsItsRulesForABookReadFromTheList() throws {
        preserveSharedSleepTimer()
        let world = try makeIntegrationWorld("ReadingListSleepTimer")
        let requests = ReadingListOpenRequests()
        let first = try makeAudioBook("First Crossing", in: world)
        let second = try makeAudioBook("Second Crossing", in: world)
        let asked = record(.continueToNextBook, in: world)
        let timer = SleepTimerService.shared
        // Each case ends a book, which counts it finished; no book counts
        // as finished here, so the list always offers the book beside.
        world.library.finishedBookIDs = { [] }
        let cases: [(duration: SleepTimerDuration, continuation: ReadingList.Continuation, reading: Book, announcement: String)] = [
            (.endOfBook, .playBookBelow, first, "Finished: First Crossing. Next book not started because of the sleep timer."),
            (
                .endOfBook, .stop, first,
                "Finished: First Crossing. The reading list is set to stop when a book ends. Sleep timer expired."
            ),
            (.endOfHeading, .playBookBelow, second, "Finished: Second Crossing. End of the reading list. Sleep timer expired."),
        ]
        for testCase in cases {
            list([first, second], in: world, continuation: testCase.continuation)
            let reader = makeReaderFromList(for: testCase.reading, in: world, requests: requests)
            timer.start(duration: testCase.duration, ownerID: reader.readerID, onExpire: {})

            let recorder = recordingAnnouncements {
                reader.handleEndOfBook()
                spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
            }
            timer.stop(reason: "the case ended")

            XCTAssertEqual(recorder.announcements.map(\.message), [testCase.announcement], testCase.announcement)
            XCTAssertTrue(asked().isEmpty, "\(testCase.announcement): asked for a book")
            XCTAssertFalse(requests.hasRequest(for: second.id), "\(testCase.announcement): requested the next book")
            XCTAssertFalse(world.autoplayRequests.hasRequest(for: second.id), "\(testCase.announcement): started the next book")
            // Its window closes, so the next case opens its book afresh.
            reader.close()
        }

        // Another reader's timer pauses only that reader: the list goes on.
        list([first, second], in: world)
        let reader = makeReaderFromList(for: first, in: world, requests: requests)
        timer.start(duration: .minutes(30), ownerID: UUID(), onExpire: {})
        let recorder = recordingAnnouncements {
            reader.handleEndOfBook()
            XCTAssertTrue(eventually { !asked().isEmpty }, "Another reader's timer kept the next book from starting")
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }
        timer.stop(reason: "the test ended")
        XCTAssertEqual(recorder.announcements.map(\.message), ["Starting: Second Crossing"])
    }

    /// A sleep timer counting minutes goes on with the next book of the
    /// reading list (0.2.5): the next book starts, "Starting: <title>", and the
    /// reader of that book owns the timer, still running.
    func testAMinutesTimerGoesOnWithTheNextBookInTheReadingList() throws {
        preserveSharedSleepTimer()
        let world = try makeIntegrationWorld("ReadingListTimerGoesOn")
        let requests = ReadingListOpenRequests()
        let first = try makeAudioBook("First Crossing", in: world)
        let second = try makeAudioBook("Second Crossing", in: world)
        list([first, second], in: world)
        world.library.finishedBookIDs = { [] }
        let reader = makeReaderFromList(for: first, in: world, requests: requests)
        let next = makeReader(for: second, in: world, requests: requests)
        waitForReaderToLoad(next)
        let timer = SleepTimerService.shared
        timer.start(duration: .minutes(30), ownerID: reader.readerID, onExpire: {})
        let before = timer.remainingSeconds
        let asked = record(.continueToNextBook, in: world)

        let recorder = recordingAnnouncements {
            reader.handleEndOfBook()
            XCTAssertTrue(eventually { !asked().isEmpty }, "The timer kept the next book from starting")
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Starting: Second Crossing"])
        XCTAssertTrue(timer.isActive, "The timer ended with the book")
        XCTAssertEqual(timer.ownerID, next.readerID)
        XCTAssertLessThanOrEqual(timer.remainingSeconds, before)
        XCTAssertGreaterThan(timer.remainingSeconds, before - 60)
    }

    /// A book taken off the list while it is read ends as its own
    /// end-of-book behavior says, since the list has nothing to say of it:
    /// Stop says "Finished: <title>", and Continue to Next Book goes on to
    /// the next book in its folder, which is not read from the list.
    func testABookTakenOffTheListMidReadEndsAsItsOwnBehaviorSays() throws {
        let world = try makeIntegrationWorld("ReadingListLeftMidRead")
        let requests = ReadingListOpenRequests()
        // In the folder, by title: Alpha, Beta, Gamma.
        let alpha = try makeAudioBook("Alpha Crossing", in: world)
        let beta = try makeAudioBook("Beta Crossing", in: world, endOfBook: .continueNext)
        let gamma = try makeAudioBook("Gamma Crossing", in: world)
        list([alpha, beta, gamma], in: world)
        let asked = record(.continueToNextBook, in: world)

        let stopping = makeReaderFromList(for: alpha, in: world, requests: requests)
        world.library.removeFromReadingList([alpha.id])
        let stopped = recordingAnnouncements {
            stopping.handleEndOfBook()
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }
        XCTAssertEqual(stopped.announcements.map(\.message), ["Finished: Alpha Crossing"])
        XCTAssertTrue(asked().isEmpty)

        let continuing = makeReaderFromList(for: beta, in: world, requests: requests)
        world.library.removeFromReadingList([beta.id])
        let continued = recordingAnnouncements {
            continuing.handleEndOfBook()
            XCTAssertTrue(eventually { !asked().isEmpty }, "Never continued in the folder")
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }
        XCTAssertEqual(continued.announcements.map(\.message), ["Starting: Gamma Crossing"])
        XCTAssertEqual(asked().map(\.nextBookID), [gamma.id])
        XCTAssertTrue(world.autoplayRequests.hasRequest(for: gamma.id))
        XCTAssertFalse(requests.hasRequest(for: gamma.id), "the folder's next book was asked to be read from the list")
    }

    /// A text book read from the list continues through it as an audiobook
    /// does. (It is never played: its end is reached directly.)
    func testATextBookReadFromTheListContinuesThroughIt() throws {
        let world = try makeIntegrationWorld("ReadingListTextBook")
        let requests = ReadingListOpenRequests()
        let text = try makeTextBook("Tide Tables", in: world)
        let audio = try makeAudioBook("Second Crossing", in: world)
        list([text, audio], in: world)
        let reader = makeReaderFromList(for: text, in: world, requests: requests)
        XCTAssertFalse(reader.isAudioBook)
        let asked = record(.continueToNextBook, in: world)

        let recorder = recordingAnnouncements {
            reader.handleEndOfBook()
            XCTAssertTrue(eventually { !asked().isEmpty }, "Never asked for the next book")
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Starting: Second Crossing"])
        XCTAssertEqual(asked().map(\.nextBookID), [audio.id])
        XCTAssertTrue(requests.hasRequest(for: audio.id))
        XCTAssertFalse(reader.speechService.isSpeaking)
    }

    /// The next book's window already open from a folder is brought
    /// forward, and its reader reads it from the list from then on and
    /// plays it, once.
    func testTheNextBookAlreadyOpenIsReadFromTheListAndPlays() throws {
        let world = try makeIntegrationWorld("ReadingListNextOpen")
        let requests = ReadingListOpenRequests()
        let first = try makeAudioBook("First Crossing", in: world)
        let second = try makeAudioBook("Second Crossing", in: world)
        list([first, second], in: world)
        let next = makeReader(for: second, in: world, requests: requests)
        waitForReaderToLoad(next)
        XCTAssertFalse(next.isOpenedFromReadingList)
        let reader = makeReaderFromList(for: first, in: world, requests: requests)

        let recorder = recordingAnnouncements {
            reader.handleEndOfBook()
            XCTAssertTrue(eventually(within: Self.playbackStartTimeout) { next.isCurrentlyPlaying }, "The next book never started")
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Starting: Second Crossing"])
        XCTAssertEqual(next.readingListPlace, ReadingListPlace(position: 2, count: 2))
        XCTAssertTrue(next.audioPlaybackService.isPlaying)
        XCTAssertFalse(requests.hasRequest(for: second.id))
        XCTAssertFalse(world.autoplayRequests.hasRequest(for: second.id))
        XCTAssertNil(next.lastAnnouncement)
    }

    /// With Skip Finished Books off, a book read from the list hands over to
    /// the finished book beside it, whose open reader plays it from its
    /// beginning (REV18a, finding 5): it does not run its own end rule, which
    /// would hand over to the book after it and play none of it. With the
    /// option on, the finished book is still passed over.
    func testTheListHandsOverToAFinishedBookWhichPlaysFromItsBeginning() throws {
        let world = try makeIntegrationWorld("ReadingListFinishedHandOver")
        let requests = ReadingListOpenRequests()
        let first = try makeAudioBook("First Crossing", in: world)
        let second = try makeAudioBook("Second Crossing", in: world)
        let third = try makeAudioBook("Third Crossing", in: world)
        list([first, second, third], in: world, skipsFinished: false)
        // The second book's window is open, resting at its end.
        let next = makeReader(for: second, in: world, requests: requests)
        waitForReaderToLoad(next)
        next.restAtEnd()
        next.hasFinishedBook = true
        let finishedRow = world.library.library.books.first { $0.id == second.id }
        XCTAssertEqual(finishedRow?.restsAtEnd, true, "The second book does not rest at its end in the library")
        // The list counts a book finished as Books Finished does.
        ReadingStatsService.shared.markBookFinished(bookID: second.id, title: second.title)
        XCTAssertEqual(
            world.library.readingListNeighbor(of: first.id, direction: .down, skippingFinished: true)?.id,
            third.id,
            "The finished book is not passed over while the list skips finished books"
        )
        let reader = makeReaderFromList(for: first, in: world, requests: requests)
        let asked = record(.continueToNextBook, in: world)

        let recorder = recordingAnnouncements {
            reader.handleEndOfBook()
            XCTAssertTrue(
                eventually(within: Self.playbackStartTimeout) { next.audioPlaybackService.isPlaying },
                "The finished book never played"
            )
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Starting: Second Crossing"])
        XCTAssertEqual(asked().map(\.nextBookID), [second.id], "The finished book handed over to another")
        XCTAssertEqual(next.currentChapterIndex, 0)
        XCTAssertLessThan(next.audioPlaybackService.currentTime, 1.5, "It did not play from its beginning")
        XCTAssertFalse(next.hasFinishedBook)
        XCTAssertFalse(next.cursorRestsAtEnd)
        XCTAssertEqual(
            world.library.library.books.first { $0.id == second.id }?.restsAtEnd,
            false,
            "The library still shows it finished"
        )
    }

    /// The list as it is when the book ends decides what follows, whatever
    /// it was when the book started: a book playing while the list is
    /// rearranged and its option changed goes on to the book now beside it
    /// that way, and its place follows the changes as it plays.
    func testTheListAsChangedWhileABookPlaysDecidesWhatFollows() throws {
        let world = try makeIntegrationWorld("ReadingListChangedWhilePlaying")
        let requests = ReadingListOpenRequests()
        let first = try makeAudioBook("First Crossing", in: world)
        let second = try makeAudioBook("Second Crossing", in: world)
        let third = try makeAudioBook("Third Crossing", in: world)
        list([first, second, third], in: world)
        let reader = makeReaderFromList(for: second, in: world, requests: requests)
        reader.play()
        XCTAssertTrue(eventually(within: Self.playbackStartTimeout) { reader.audioPlaybackService.isPlaying }, "The book did not play")
        let asked = record(.continueToNextBook, in: world)

        // While it plays: Third moves to the top, and the list now plays
        // the book above.
        world.library.moveInReadingList(bookID: third.id, direction: .up)
        world.library.moveInReadingList(bookID: third.id, direction: .up)
        world.library.setReadingListContinuation(.playBookAbove)
        XCTAssertEqual(reader.readingListPlace, ReadingListPlace(position: 3, count: 3))
        XCTAssertTrue(reader.audioPlaybackService.isPlaying, "a change to the list stopped the book")

        // The book's audio reaches its end, which then ends the book.
        reader.audioPlaybackService.stop()
        let recorder = recordingAnnouncements {
            reader.handleEndOfBook()
            XCTAssertTrue(eventually { !asked().isEmpty }, "Never asked for the book above")
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Starting: First Crossing"])
        XCTAssertEqual(asked().map(\.nextBookID), [first.id])
        XCTAssertTrue(requests.hasRequest(for: first.id))
    }

    // MARK: - Next and Previous in Reading List

    /// The two commands are named for the menu and Settings as the actions
    /// are, listed under Navigation with no keys until the user gives them
    /// some, in the app's scope, each posting its own notification.
    func testNextAndPreviousInReadingListHaveNoKeysUntilGivenSome() {
        XCTAssertEqual(ShortcutAction.nextInReadingList.rawValue, "Next in Reading List")
        XCTAssertEqual(ShortcutAction.previousInReadingList.rawValue, "Previous in Reading List")
        for action in [ShortcutAction.nextInReadingList, .previousInReadingList] {
            XCTAssertEqual(action.title, action.rawValue)
            XCTAssertEqual(action.category, "Navigation", action.rawValue)
            XCTAssertEqual(action.defaultScope, .app, action.rawValue)
            XCTAssertEqual(ShortcutAction.defaultBindings[action], [], action.rawValue)
        }
        XCTAssertEqual(ShortcutAction.nextInReadingList.notificationName, .nextInReadingList)
        XCTAssertEqual(ShortcutAction.previousInReadingList.notificationName, .previousInReadingList)
        XCTAssertEqual(Notification.Name.nextInReadingList.rawValue, "nextInReadingList")
        XCTAssertEqual(Notification.Name.previousInReadingList.rawValue, "previousInReadingList")
    }

    /// The reader's Navigate menu offers both, named as the actions are,
    /// one after the other, below Previous Heading.
    func testTheNavigateMenuOffersNextAndPreviousInReadingList() throws {
        let mainMenu = try XCTUnwrap(NSApp.mainMenu)
        let navigate = try XCTUnwrap(mainMenu.items.first { $0.title == "Navigate" }?.submenu, "no Navigate menu")
        let titles = navigate.items.map(\.title)
        let listed = titles.joined(separator: ", ")
        let previousHeading = try XCTUnwrap(titles.firstIndex(of: "Previous Heading"), listed)
        let next = try XCTUnwrap(titles.firstIndex(of: ShortcutAction.nextInReadingList.title), listed)
        XCTAssertEqual(titles.firstIndex(of: ShortcutAction.previousInReadingList.title), next + 1, listed)
        XCTAssertGreaterThan(next, previousHeading, listed)
        XCTAssertTrue(MenuVisibilityManager.readerMenuTitles.contains("Navigate"))
    }

    /// Next in Reading List from a playing book opens the book below it to
    /// be read from the list, and plays it: this book pauses where it is,
    /// "Starting: <title>" is said, and after a moment the book is asked
    /// for as a book that ends continues to it. The reader its window makes
    /// reads it from the list and plays.
    func testNextInReadingListFromAPlayingBookStartsTheBookBelow() throws {
        let world = try makeIntegrationWorld("ReadingListNextPlaying")
        let requests = ReadingListOpenRequests()
        let first = try makeAudioBook("First Crossing", in: world)
        let second = try makeAudioBook("Second Crossing", in: world)
        let third = try makeAudioBook("Third Crossing", in: world)
        list([first, second, third], in: world)
        let reader = makeReaderFromList(for: first, in: world, requests: requests)
        reader.play()
        XCTAssertTrue(eventually(within: Self.playbackStartTimeout) { reader.audioPlaybackService.isPlaying }, "The book did not play")
        let asked = record(.continueToNextBook, in: world)
        let opened = record(.openBookWindow, in: world)

        let recorder = recordingAnnouncements {
            world.notifications.post(name: .nextInReadingList, object: nil)
            XCTAssertTrue(asked().isEmpty, "Asked before the announcement had a moment")
            XCTAssertTrue(eventually { !asked().isEmpty }, "Never asked for the next book")
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Starting: Second Crossing"])
        XCTAssertTrue(reader.audioPlaybackService.isPaused, "This book was not paused")
        XCTAssertFalse(reader.hasFinishedBook)
        XCTAssertEqual(asked().map(\.nextBookID), [second.id])
        XCTAssertEqual(asked().first?.userInfo?[Notification.ContinueToNextBookKey.previousBookID] as? UUID, first.id)
        XCTAssertTrue(opened().isEmpty, "Opened the book a second way")
        XCTAssertTrue(requests.hasRequest(for: second.id))
        XCTAssertTrue(world.autoplayRequests.hasRequest(for: second.id))

        let next = makeReader(for: second, in: world, requests: requests)
        XCTAssertEqual(next.readingListPlace, ReadingListPlace(position: 2, count: 3))
        XCTAssertTrue(eventually(within: Self.playbackStartTimeout) { next.isCurrentlyPlaying }, "The next book never started")
        XCTAssertTrue(next.audioPlaybackService.isPlaying)
    }

    /// Next in Reading List from a book not playing opens the book below it
    /// to be read from the list, and starts nothing: "Opening: <title>",
    /// then, after a moment, its window alone is asked for.
    func testNextInReadingListFromABookNotPlayingOpensTheBookBelow() throws {
        let world = try makeIntegrationWorld("ReadingListNextQuiet")
        let requests = ReadingListOpenRequests()
        let first = try makeAudioBook("First Crossing", in: world)
        let second = try makeAudioBook("Second Crossing", in: world)
        list([first, second], in: world)
        let reader = makeReaderFromList(for: first, in: world, requests: requests)
        let asked = record(.continueToNextBook, in: world)
        let opened = record(.openBookWindow, in: world)

        let recorder = recordingAnnouncements {
            reader.goThroughReadingList(.down)
            XCTAssertTrue(opened().isEmpty, "Opened before the announcement had a moment")
            XCTAssertTrue(eventually { !opened().isEmpty }, "Never opened the next book")
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Opening: Second Crossing"])
        XCTAssertEqual(opened().map { $0.object as? UUID }, [second.id])
        XCTAssertTrue(asked().isEmpty, "Asked for the next book to start")
        XCTAssertTrue(requests.hasRequest(for: second.id))
        XCTAssertFalse(world.autoplayRequests.hasRequest(for: second.id))

        let next = makeReader(for: second, in: world, requests: requests)
        waitForReaderToLoad(next)
        XCTAssertEqual(next.readingListPlace, ReadingListPlace(position: 2, count: 2))
        XCTAssertFalse(next.isCurrentlyPlaying)
    }

    /// Previous in Reading List opens the book above, from its command's
    /// notification.
    func testPreviousInReadingListOpensTheBookAbove() throws {
        let world = try makeIntegrationWorld("ReadingListPrevious")
        let requests = ReadingListOpenRequests()
        let first = try makeAudioBook("First Crossing", in: world)
        let second = try makeAudioBook("Second Crossing", in: world)
        let third = try makeAudioBook("Third Crossing", in: world)
        list([first, second, third], in: world)
        let reader = makeReaderFromList(for: third, in: world, requests: requests)
        let opened = record(.openBookWindow, in: world)

        let recorder = recordingAnnouncements {
            world.notifications.post(name: .previousInReadingList, object: nil)
            XCTAssertTrue(eventually { !opened().isEmpty }, "Never opened the book above")
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Opening: Second Crossing"])
        XCTAssertEqual(opened().map { $0.object as? UUID }, [second.id])
        XCTAssertTrue(requests.hasRequest(for: second.id))
        XCTAssertTrue(reader.isOpenedFromReadingList, "this book is no longer read from the list")
    }

    /// With nowhere to go, Next and Previous say so and open nothing: at
    /// the list's ends, and past only finished books while the list passes
    /// over them. With Skip Finished Books off, the finished book beside is
    /// where they go.
    func testNextAndPreviousSayWhenThereIsNowhereToGo() throws {
        let world = try makeIntegrationWorld("ReadingListNowhere")
        let requests = ReadingListOpenRequests()
        let first = try makeAudioBook("First Crossing", in: world)
        let second = try makeAudioBook("Second Crossing", in: world)
        let third = try makeAudioBook("Third Crossing", in: world)
        list([first, second, third], in: world)
        let asked = record(.continueToNextBook, in: world)
        let opened = record(.openBookWindow, in: world)
        let cases: [(reading: Book, direction: ReadingList.Direction, finished: [Book], announcement: String)] = [
            (first, .up, [], "No previous book in the reading list."),
            (third, .down, [], "No next book in the reading list."),
            (first, .down, [second, third], "No next book in the reading list: every book below this one is finished."),
            (third, .up, [first, second], "No previous book in the reading list: every book above this one is finished."),
        ]
        for testCase in cases {
            let finished = Set(testCase.finished.map(\.id))
            world.library.finishedBookIDs = { finished }
            let reader = makeReaderFromList(for: testCase.reading, in: world, requests: requests)

            let recorder = recordingAnnouncements {
                reader.goThroughReadingList(testCase.direction)
                spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
            }

            XCTAssertEqual(recorder.announcements.map(\.message), [testCase.announcement], testCase.announcement)
            XCTAssertTrue(asked().isEmpty, testCase.announcement)
            XCTAssertTrue(opened().isEmpty, testCase.announcement)
            for book in [first, second, third] {
                XCTAssertFalse(requests.hasRequest(for: book.id), "\(testCase.announcement): requested \(book.title)")
            }
            // Its window closes, so the next case opens its book afresh.
            reader.close()
        }

        world.library.setReadingListSkipsFinished(false)
        let finished = Set([second.id, third.id])
        world.library.finishedBookIDs = { finished }
        let reader = makeReaderFromList(for: first, in: world, requests: requests)
        let recorder = recordingAnnouncements {
            reader.goThroughReadingList(.down)
            XCTAssertTrue(eventually { !opened().isEmpty }, "Never opened the finished book beside")
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }
        XCTAssertEqual(recorder.announcements.map(\.message), ["Opening: Second Crossing"])
        XCTAssertEqual(opened().map { $0.object as? UUID }, [second.id])
    }

    /// A book not read from the list says so and opens nothing: the
    /// Navigate menu offers the commands only for a book read from the
    /// list, but a key given them still reaches the reader.
    func testNextAndPreviousFromABookNotReadFromTheListSaySo() throws {
        let world = try makeIntegrationWorld("ReadingListNotFromList")
        let requests = ReadingListOpenRequests()
        let first = try makeAudioBook("First Crossing", in: world)
        let second = try makeAudioBook("Second Crossing", in: world)
        list([first, second], in: world)
        let reader = makeReader(for: first, in: world, requests: requests)
        waitForReaderToLoad(reader)
        let asked = record(.continueToNextBook, in: world)
        let opened = record(.openBookWindow, in: world)

        let recorder = recordingAnnouncements {
            world.notifications.post(name: .nextInReadingList, object: nil)
            world.notifications.post(name: .previousInReadingList, object: nil)
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }

        XCTAssertEqual(
            recorder.announcements.map(\.message),
            Array(repeating: "This book was not opened from the reading list.", count: 2)
        )
        XCTAssertTrue(asked().isEmpty)
        XCTAssertTrue(opened().isEmpty)
        XCTAssertFalse(requests.hasRequest(for: second.id))
    }

    /// This reader's running sleep timer goes on with the book Next in
    /// Reading List goes to (0.2.5): the book starts, "Starting: <title>", as
    /// any playing book's next does, the book it left is paused, and the
    /// timer is asked for by the book's reader, still this reader's until that
    /// reader takes it.
    func testTheSleepTimerGoesOnWithNextInReadingList() throws {
        preserveSharedSleepTimer()
        let world = try makeIntegrationWorld("ReadingListNextSleepTimer")
        let requests = ReadingListOpenRequests()
        let first = try makeAudioBook("First Crossing", in: world)
        let second = try makeAudioBook("Second Crossing", in: world)
        list([first, second], in: world)
        let reader = makeReaderFromList(for: first, in: world, requests: requests)
        reader.play()
        XCTAssertTrue(eventually(within: Self.playbackStartTimeout) { reader.audioPlaybackService.isPlaying }, "The book did not play")
        let timer = SleepTimerService.shared
        timer.start(duration: .minutes(30), ownerID: reader.readerID, onExpire: {})
        let asked = record(.continueToNextBook, in: world)
        let opened = record(.openBookWindow, in: world)

        let recorder = recordingAnnouncements {
            reader.goThroughReadingList(.down)
            XCTAssertTrue(eventually { !asked().isEmpty }, "Never asked for the next book")
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }
        let waiting = timer.isHeld(forBook: second.id)
        let stillActive = timer.isActive
        timer.stop(reason: "the test ended")

        XCTAssertEqual(recorder.announcements.map(\.message), ["Starting: Second Crossing"])
        XCTAssertEqual(asked().map(\.nextBookID), [second.id])
        XCTAssertTrue(opened().isEmpty)
        XCTAssertTrue(world.autoplayRequests.hasRequest(for: second.id))
        XCTAssertTrue(waiting, "The timer was not held for the next book")
        XCTAssertTrue(stillActive, "The timer stopped with the move")
        XCTAssertTrue(reader.audioPlaybackService.isPaused, "This book plays on")
    }

    /// Next in Reading List during a Where Am I announcement that paused a
    /// playing book ends the announcement, leaves this book paused, and
    /// starts the next book, since this one was playing.
    func testNextInReadingListDuringWhereAmIStartsTheNextBook() throws {
        let world = try makeIntegrationWorld("ReadingListNextWhereAmI")
        let requests = ReadingListOpenRequests()
        let first = try makeAudioBook("First Crossing", in: world)
        let second = try makeAudioBook("Second Crossing", in: world)
        list([first, second], in: world)
        let reader = makeReaderFromList(for: first, in: world, requests: requests)
        // The announcement is handed to this, in place of its synthesizer,
        // so nothing is heard.
        reader._whereAmIUtteranceRecorderForTesting = { _ in }
        reader.play()
        XCTAssertTrue(eventually(within: Self.playbackStartTimeout) { reader.audioPlaybackService.isPlaying }, "The book did not play")
        reader.whereAmI()
        XCTAssertTrue(reader.isWhereAmISpeaking)
        XCTAssertTrue(reader.audioPlaybackService.isPaused, "Where Am I did not pause the book")
        let asked = record(.continueToNextBook, in: world)

        let recorder = recordingAnnouncements {
            reader.goThroughReadingList(.down)
            XCTAssertTrue(eventually { !asked().isEmpty }, "Never asked for the next book")
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Starting: Second Crossing"])
        XCTAssertFalse(reader.isWhereAmISpeaking)
        XCTAssertFalse(reader.wasPlayingBeforeWhereAmI)
        XCTAssertTrue(reader.audioPlaybackService.isPaused, "This book resumed")
        XCTAssertEqual(asked().map(\.nextBookID), [second.id])
        XCTAssertTrue(world.autoplayRequests.hasRequest(for: second.id))
    }

    /// Next in Reading List during a Where Am I announcement over a book
    /// that was not playing ends the announcement too, so that it never
    /// speaks over the next book's, and opens the next book without starting
    /// it, this one left as it was.
    func testNextInReadingListDuringWhereAmIOverABookNotPlayingOpensTheNextBook() throws {
        let world = try makeIntegrationWorld("ReadingListNextWhereAmINotPlaying")
        let requests = ReadingListOpenRequests()
        let first = try makeAudioBook("First Crossing", in: world)
        let second = try makeAudioBook("Second Crossing", in: world)
        list([first, second], in: world)
        let reader = makeReaderFromList(for: first, in: world, requests: requests)
        // The announcement is handed to this, in place of its synthesizer,
        // so nothing is heard.
        reader._whereAmIUtteranceRecorderForTesting = { _ in }
        reader.whereAmI()
        XCTAssertTrue(reader.isWhereAmISpeaking)
        let asked = record(.continueToNextBook, in: world)
        let opened = record(.openBookWindow, in: world)

        let recorder = recordingAnnouncements {
            reader.goThroughReadingList(.down)
            XCTAssertTrue(eventually { !opened().isEmpty }, "Never opened the next book")
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Opening: Second Crossing"])
        XCTAssertFalse(reader.isWhereAmISpeaking, "The announcement speaks over the next book's")
        XCTAssertEqual(opened().map { $0.object as? UUID }, [second.id])
        XCTAssertTrue(asked().isEmpty, "Asked for the next book to start")
        XCTAssertFalse(reader.audioPlaybackService.isPlaying, "This book started")
    }

    // MARK: - Fixtures

    /// The title `reader`'s window shows now.
    private func title(of reader: ReaderViewModel) -> String {
        BookReaderWindowView.windowTitle(for: reader.book, readFromReadingList: reader.isOpenedFromReadingList)
    }

    /// The tracks of every fixture audiobook, in seconds: longer than any
    /// test runs, so no chapter ends by itself.
    private static let trackDurations: [TimeInterval] = [5, 5]

    /// How long a test waits for a book to start playing: a fresh test
    /// host's first audio takes about five seconds to start, as long as
    /// `eventually`'s own limit, and a busy Mac takes longer still.
    private static let playbackStartTimeout: TimeInterval = 15

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
        skipsFinished: Bool = true,
        removesFinished: Bool = false
    ) {
        world.library.library.readingList = ReadingList(
            bookIDs: books.map(\.id),
            continuation: continuation,
            skipsFinished: skipsFinished,
            removesFinished: removesFinished
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

    /// A reader for `book` opened from the Reading List of `world`, as the
    /// row's Open item opens it there, once it has loaded. In the app a
    /// book has one window, which an open brings forward, so a test closes
    /// a reader of the book before opening it from the list again: an open
    /// reader of the book claims the request at once.
    private func makeReaderFromList(
        for book: Book,
        in world: IntegrationWorld,
        requests: ReadingListOpenRequests,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> ReaderViewModel {
        requests.request(for: book.id)
        let reader = makeReader(for: book, in: world, requests: requests)
        waitForReaderToLoad(reader, file: file, line: line)
        XCTAssertTrue(reader.isOpenedFromReadingList, "\(book.title) is not read from the list", file: file, line: line)
        return reader
    }

    /// Records every notification named `name` posted on `world`'s
    /// notification center from now on.
    ///
    /// - Returns: A function reading the notifications posted so far.
    private func record(_ name: Notification.Name, in world: IntegrationWorld) -> () -> [Notification] {
        var posted: [Notification] = []
        world.notifications.publisher(for: name)
            .sink { posted.append($0) }
            .store(in: &subscriptions)
        return { posted }
    }
}
