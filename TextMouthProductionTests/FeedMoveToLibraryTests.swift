import XCTest
@testable import TextMouth

// MARK: - The "In Library" State (FR11, Branch D)

/// An item moved into the library by Move to Library… (FR11, branch D, item
/// 7; the listener's answer 5: "its feed then lists it as 'In Library' and
/// never downloads it again"): its record says "in library" with its book's
/// ID, which round-trips; its feed lists it "In Library", whose Open opens
/// the book; every refresh keeps it; it counts among the newest-N rule's
/// newest and is never downloaded again; Mark Played and Delete Episode…
/// stay on its row, Delete Episode hiding the row and leaving the book;
/// once its book leaves the library, it is not downloaded; and finishing
/// its book plays it, Books Finished counting it as an episode. Each item
/// is put in the library here through its record and a book row, as the
/// move leaves them. No test reaches the network: every request goes to the
/// world's stub server.
@MainActor
final class FeedInLibraryStateTests: XCTestCase {

    // MARK: - The State

    /// The state round-trips through a record, names its book, and says "In
    /// Library"; one missing its book reads as not downloaded, as any state
    /// a TextMouth cannot make sense of does.
    func testTheStateRoundTripsAndSaysInLibrary() throws {
        let bookID = UUID()
        let state = FeedItemState.inLibrary(bookID: bookID)

        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(FeedItemState.self, from: data), state)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["kind"] as? String, "inLibrary")
        XCTAssertEqual(object["bookID"] as? String, bookID.uuidString)
        XCTAssertEqual(try JSONDecoder().decode(FeedItemState.self, from: Data(#"{"kind": "inLibrary"}"#.utf8)), .notDownloaded)

        XCTAssertEqual(state.visibleNote, "In Library")
        XCTAssertEqual(state.spokenNote, "In Library")
        XCTAssertNil(state.bookID, "a book moved into the library was taken for its feed's download")
        XCTAssertEqual(state.libraryBookID, bookID)
        XCTAssertEqual(state.linkedBookID, bookID)
        XCTAssertEqual(FeedItemState.downloaded(bookID: bookID).linkedBookID, bookID)
        XCTAssertFalse(state.isTransient)
        XCTAssertEqual(state, FeedRecord(feed: Feed(feedURL: try XCTUnwrap(URL(string: "https://a.example/f.xml")), folderID: UUID(), subscribedDate: Date()), items: [
            FeedItem(id: "a", title: "A", firstSeen: Date(), state: state),
        ]).durable.items.first?.state, "a record file did not keep the state")
    }

    // MARK: - Its Row

    /// The item's row says "In Library" after its title, with its date and
    /// duration, and opens its book in the library; it offers Open, Mark
    /// Played, Show Description…, and Delete Episode…, which asks first,
    /// saying the book stays, hides the row, and leaves the book.
    func testTheRowSaysInLibraryAndDeleteEpisodeLeavesTheBook() async throws {
        let world = try FeedTestWorld(self, label: "FeedInLibraryRow")
        let (feed, book) = try await feedWithAnEpisodeInTheLibrary(world)
        // Published after the subscription began, so it would be new if it
        // were not in the library.
        world.center.store.updateItem("guid:ep-1", of: feed.id) { item in
            item.duration = 64 * 60
            item.published = world.day(1)
        }
        let item = try XCTUnwrap(world.center.store.record(of: feed.id)?.item("guid:ep-1"))

        let content = FeedItemRowContent(item, of: feed, in: world.center, wordsPerMinute: 200)

        let date = try XCTUnwrap(item.published)
        XCTAssertEqual(content.label, "Episode 1, In Library, \(FeedWording.itemDate(date)), \(TimeFormatting.spoken(64 * 60))")
        XCTAssertFalse(content.isNew, "an episode in the library was new")
        XCTAssertEqual(FeedWording.itemRowHint(content.state), "Opens its book in your library")
        let actions = FeedItemAction.actions(for: content)
        XCTAssertEqual(actions.map(\.title), ["Open", "Mark Played", "Show Description…", "Delete Episode…"])

        let presenter = LibraryFeedsPresenter()
        var heard: [String] = []
        presenter.announce = { message, _ in heard.append(message) }
        let context = FeedCommandContext(center: world.center, library: world.library, window: nil)
        presenter.perform(try XCTUnwrap(actions.last), in: context)
        let question = try XCTUnwrap(presenter.confirmation)
        XCTAssertEqual(
            question.message,
            "The episode leaves the list for good; the book it became in your library stays. Checking the feed won't bring it back."
        )
        presenter.confirm(question, in: context)

        XCTAssertEqual(heard.last, "Deleted “Episode 1” from its feed; its book stays in your library.")
        XCTAssertNotNil(world.library.bookByID(book.id), "Delete Episode took the book from the library")
        XCTAssertFalse(world.center.listedItems(of: feed.id).contains { $0.id == "guid:ep-1" })
        XCTAssertEqual(world.center.store.record(of: feed.id)?.item("guid:ep-1")?.state, .inLibrary(bookID: book.id))
    }

    // MARK: - The Rules

    /// While its book is in the library, the item is never downloaded again:
    /// the newest-N rule counts it among the newest and asks for the next
    /// one alone; Download asks for nothing; Open opens the book. It is not
    /// counted as a download of its feed. A refresh that leaves it outside
    /// the short list's newest 2, unplayed, keeps it, in the library; and
    /// played, it stays listed there.
    func testAnItemInTheLibraryIsKeptAndNeverDownloadedAgain() async throws {
        let world = try FeedTestWorld(self, label: "FeedInLibraryRules")
        FeedSettings.newestCountPreference.write(2, to: world.preferences)
        let (feed, book) = try await feedWithAnEpisodeInTheLibrary(world)
        var opened: [UUID] = []
        world.library.readerOpener = { opened.append($0) }

        let pass = await world.center.applyItemPolicy(to: [feed.id])
        XCTAssertEqual(pass.requestedItemIDs, ["guid:ep-2"], "the rule's newest did not count the episode in the library")
        _ = try await downloadedBook(world, feed: feed, item: "guid:ep-2")
        world.center.download("guid:ep-1", of: feed.id)
        world.center.open("guid:ep-1", of: feed.id)

        XCTAssertEqual(world.server.requests(to: "/audio/1.m4a"), [], "an episode in the library was downloaded again")
        XCTAssertEqual(opened, [book.id])
        XCTAssertEqual(world.center.counts(of: feed.id).downloaded, 1)

        world.center.setItemPolicy(FeedItemPolicy(choice: .onlyNewestListed, newestCount: 2), of: feed.id)
        let newer = [0.1, 0.2].map { age in
            FeedXML.Item(guid: "newer-\(age)", title: "Newer \(age)", published: world.day(-age),
                         enclosure: world.server.url("/audio/newer-\(age).m4a").absoluteString, enclosureType: "audio/mp4")
        }
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: newer + Self.episodes(world))))
        _ = await world.center.refresh(feed.id)
        XCTAssertEqual(
            world.center.store.record(of: feed.id)?.item("guid:ep-1")?.state,
            .inLibrary(bookID: book.id),
            "a refresh let go of an episode in the library outside the newest"
        )
        world.center.markPlayed("guid:ep-1", of: feed.id)
        XCTAssertTrue(world.center.listedItems(of: feed.id).contains { $0.id == "guid:ep-1" }, "the short list hid the played episode in the library")
        XCTAssertEqual(world.server.requests(to: "/audio/1.m4a"), [])
    }

    /// Once its book leaves the library the item reads not downloaded, and
    /// the after-playing sweep notes it so, leaving it the listener's; the
    /// listener's Download then downloads it.
    func testAnItemWhoseBookLeftTheLibraryIsNotDownloaded() async throws {
        let world = try FeedTestWorld(self, label: "FeedInLibraryGone")
        let (feed, book) = try await feedWithAnEpisodeInTheLibrary(world)
        let item = try XCTUnwrap(world.center.store.record(of: feed.id)?.item("guid:ep-1"))
        XCTAssertEqual(world.center.state(of: item, in: feed.id), .inLibrary(bookID: book.id))

        world.library.library.books.removeAll { $0.id == book.id }

        XCTAssertEqual(world.center.state(of: item, in: feed.id), .notDownloaded)
        let sweep = await world.center.sweepPlayedDownloads()
        XCTAssertEqual(sweep.forgottenItemIDs, ["guid:ep-1"])
        let noted = try XCTUnwrap(world.center.store.record(of: feed.id)?.item("guid:ep-1"))
        XCTAssertEqual(noted.state, .notDownloaded)
        XCTAssertEqual(noted.downloadDeletedDate, world.clock.value)
        XCTAssertEqual(noted.downloadOrigin, .listener)
        world.center.download("guid:ep-1", of: feed.id)
        let again = try await downloadedBook(world, feed: feed, item: "guid:ep-1")
        XCTAssertNotEqual(again.id, book.id)
    }

    /// Finishing the book an episode became in the library plays the
    /// episode, and Books Finished counts it as a podcast episode, as the
    /// record of where it came from says.
    func testFinishingTheBookPlaysTheItemAndCountsAnEpisode() async throws {
        let world = try FeedTestWorld(self, label: "FeedInLibraryFinished")
        let (feed, book) = try await feedWithAnEpisodeInTheLibrary(world)

        world.stats.markBookFinished(bookID: book.id, title: book.title)

        XCTAssertEqual(world.center.store.record(of: feed.id)?.item("guid:ep-1")?.playedDate, world.clock.value)
        XCTAssertEqual(world.center.finishedBookKind(of: book.id), .episode)
        XCTAssertEqual(world.stats.booksFinishedAllTimeByKind, FinishedBookCounts(episodes: 1))
    }

    // MARK: - Fixtures

    /// Three episodes, "guid:ep-1" the newest, each served as a second of
    /// silence at /audio/<number>.m4a.
    private static func episodes(_ world: FeedTestWorld) -> [FeedXML.Item] {
        (1...3).map { number in
            FeedXML.Item(guid: "ep-\(number)", title: "Episode \(number)", published: world.day(-Double(number)),
                         enclosure: world.server.url("/audio/\(number).m4a").absoluteString, enclosureType: "audio/mp4")
        }
    }

    /// Subscribes `world` to a feed of three episodes, serving each, and
    /// puts the newest in the library as Move to Library… leaves it: a book
    /// of the library's own, its item "in library" with the book's ID, and
    /// the listener's.
    private func feedWithAnEpisodeInTheLibrary(_ world: FeedTestWorld) async throws -> (Feed, Book) {
        let audio = try FeedMediaFixtures.silentAAC()
        for number in 1...3 {
            world.server.serve("/audio/\(number).m4a", FeedMediaFixtures.file(audio, mimeType: "audio/mp4"))
        }
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: Self.episodes(world))))
        let feed = try await world.subscribe("/feed.xml")
        let book = Book(title: "Episode 1", format: .audio, filePath: "/nonexistent/Episode 1.m4a", md5Hash: UUID().uuidString, folderPath: world.folder.path)
        world.library.library.books.append(book)
        world.center.store.updateItem("guid:ep-1", of: feed.id) { item in
            item.state = .inLibrary(bookID: book.id)
            item.downloadOrigin = .listener
        }
        return (feed, book)
    }
}
