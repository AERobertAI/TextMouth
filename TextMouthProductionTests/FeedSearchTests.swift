import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// Searching for podcasts from Add Feed (FR03): the sheet's Search asks the
/// podcast directory, Apple's iTunes Search API, for podcasts alone, and
/// lists each one it finds that names a feed, with its title, publisher,
/// and episode count, read as one line; a result's Subscribe fills the
/// address and subscribes as for an address typed; a search that finds
/// nothing or fails says so in the sheet and to VoiceOver. The directory is
/// a stub server answering with a saved answer of Apple's
/// (TestData/feeds/itunes-search-*.json, its text replaced), so no test
/// reaches the network.
@MainActor
final class FeedSearchTests: XCTestCase {

    // MARK: - Searching

    /// A search lists the podcasts the directory found that name a feed,
    /// each feed once, in the directory's order, and says how many; the
    /// request asks for podcasts alone, with the words typed, an "&" among
    /// them, searched for as they are.
    func testASearchListsThePodcastsTheDirectoryFound() async throws {
        let world = try FeedTestWorld(self, label: "FeedSearchFound")
        world.server.serve("/search", try .directoryAnswer("itunes-search-podcasts.json", feedsOn: world.server))
        var heard: [String] = []
        let model = AddFeedModel(center: world.center, parentPath: world.folder.path, announce: { heard.append($0) })
        model.searchTerm = "  dots & dashes "

        await model.search()?.value

        XCTAssertEqual(model.searchResults.map(\.title), [
            "Dots and Dashes: Braille at the Kitchen Table", "Ledger Lines", "Raised Line Radio",
        ], "the result without a feed, or naming a feed listed already, was kept")
        let first = try XCTUnwrap(model.searchResults.first)
        XCTAssertEqual(first.author, "Small Hours Audio")
        XCTAssertEqual(first.episodeCount, 23)
        XCTAssertEqual(first.feedURL, world.server.url("/dots-and-dashes/rss"))
        let last = try XCTUnwrap(model.searchResults.last)
        XCTAssertNil(last.author)
        XCTAssertNil(last.episodeCount)
        XCTAssertEqual(heard, [FeedWording.searching, "3 podcasts found for “dots & dashes”."])
        XCTAssertFalse(model.isSearching)
        XCTAssertNil(model.searchNote)
        XCTAssertNil(model.searchFailure)

        let request = try XCTUnwrap(world.server.requests(to: "/search").first)
        XCTAssertEqual(
            request.url?.absoluteString,
            world.server.url("/search").absoluteString + "?media=podcast&entity=podcast&limit=50&term=dots%20%26%20dashes"
        )
        XCTAssertEqual(request.allowsExpensiveNetworkAccess, true, "a search the listener asked for waited for another network")
        XCTAssertEqual(world.server.requests.count, 1, "the search fetched more than its answer")
    }

    /// A search that finds nothing says so in the sheet and to VoiceOver,
    /// and lists nothing; changing the words clears the note in the sheet.
    func testASearchThatFindsNothingSaysSo() async throws {
        let world = try FeedTestWorld(self, label: "FeedSearchNothing")
        world.server.serve("/search", try .directoryAnswer("itunes-search-empty.json", feedsOn: world.server))
        var heard: [String] = []
        let model = AddFeedModel(center: world.center, parentPath: "", announce: { heard.append($0) })
        model.searchTerm = "zzzz"

        await model.search()?.value

        let expected = "No podcasts were found for “zzzz”. Try other words, or type the feed's address."
        XCTAssertEqual(FeedWording.noPodcastsFound(term: "zzzz"), expected)
        XCTAssertEqual(model.searchNote, expected)
        XCTAssertEqual(heard, [FeedWording.searching, expected])
        XCTAssertTrue(model.searchResults.isEmpty)
        XCTAssertNil(model.searchFailure)
    }

    /// A search that fails says why, in the sheet and to VoiceOver: the
    /// directory refusing a search past its limit, a server error, an answer
    /// that is no list of results, and this Mac being offline. A new search
    /// clears what the last one said.
    func testASearchThatFailsSaysWhy() async throws {
        let world = try FeedTestWorld(self, label: "FeedSearchFailed")
        let page = StubResponse(headers: ["Content-Type": "text/html"], body: Data("<html><body>Busy</body></html>".utf8))
        world.server.serve("/search", StubResponse(status: 403), StubResponse(status: 503), page)
        var heard: [String] = []
        let model = AddFeedModel(center: world.center, parentPath: "", announce: { heard.append($0) })
        model.searchTerm = "ledger"

        await model.search()?.value
        XCTAssertEqual(
            model.searchFailure,
            "The podcast directory refused the search. It allows about 20 searches a minute, so wait a minute and try again."
        )
        XCTAssertEqual(heard.last, model.searchFailure)

        await model.search()?.value
        XCTAssertEqual(
            model.searchFailure,
            "The podcast directory at \(world.server.host) couldn't answer the search (error 503). Try again later."
        )

        await model.search()?.value
        XCTAssertEqual(model.searchFailure, FeedSearchError.unreadableAnswer.message)
        XCTAssertEqual(model.searchFailure, "The podcast directory sent an answer TextMouth can't read. Try again later.")

        world.online.value = false
        await model.search()?.value
        XCTAssertEqual(
            model.searchFailure,
            "This Mac is offline, so the podcast directory can't be searched. Connect to the internet and try again."
        )
        XCTAssertEqual(world.server.requests(to: "/search").count, 3, "an offline search was sent")
        XCTAssertTrue(model.searchResults.isEmpty)
        XCTAssertNil(model.searchNote)
        XCTAssertEqual(heard.filter { $0 == FeedWording.searching }.count, 4)

        // A search that works clears the failure.
        world.online.value = true
        world.server.serve("/search", try .directoryAnswer("itunes-search-podcasts.json", feedsOn: world.server))
        await model.search()?.value
        XCTAssertNil(model.searchFailure)
        XCTAssertEqual(model.searchResults.count, 3)
    }

    /// Search waits for words to search for, and runs one search at a time.
    func testSearchWaitsForWords() async throws {
        let world = try FeedTestWorld(self, label: "FeedSearchWaits")
        var slow = try StubResponse.directoryAnswer("itunes-search-podcasts.json", feedsOn: world.server)
        slow.pause = 0.2
        world.server.serve("/search", slow)
        let model = AddFeedModel(center: world.center, parentPath: "", announce: { _ in })

        XCTAssertFalse(model.canSearch)
        model.searchTerm = "   "
        XCTAssertFalse(model.canSearch)
        XCTAssertNil(model.search())
        model.searchTerm = "ledger"
        XCTAssertTrue(model.canSearch)

        let work = model.search()
        XCTAssertTrue(model.isSearching)
        XCTAssertFalse(model.canSearch)
        XCTAssertNil(model.search(), "a second search started while one ran")
        await work?.value
        XCTAssertTrue(model.canSearch)
        XCTAssertEqual(world.server.requests(to: "/search").count, 1)
    }

    /// Cancel stops a search under way: nothing is listed or said after it.
    func testCancelStopsASearch() async throws {
        let world = try FeedTestWorld(self, label: "FeedSearchCancel")
        var slow = try StubResponse.directoryAnswer("itunes-search-podcasts.json", feedsOn: world.server)
        slow.pause = 0.3
        world.server.serve("/search", slow)
        var heard: [String] = []
        let model = AddFeedModel(center: world.center, parentPath: "", announce: { heard.append($0) })
        model.searchTerm = "ledger"

        let work = model.search()
        model.cancel()
        await work?.value

        XCTAssertTrue(model.searchResults.isEmpty)
        XCTAssertNil(model.searchFailure)
        XCTAssertEqual(heard, [FeedWording.searching])
        XCTAssertFalse(model.isSearching)
    }

    // MARK: - Subscribing to a Result

    /// A result's Subscribe puts its feed's address in the address field and
    /// subscribes as for an address typed: the feed's folder is made inside
    /// the folder chosen, and the sheet's owner is handed the feed.
    func testSubscribingToAResultFillsTheAddressAndSubscribes() async throws {
        let world = try FeedTestWorld(self, label: "FeedSearchSubscribe")
        world.server.serve("/search", try .directoryAnswer("itunes-search-podcasts.json", feedsOn: world.server))
        world.server.serve("/dots-and-dashes/rss", try .fixture("anchor-episodic.xml"))
        await world.start()
        var heard: [String] = []
        let model = AddFeedModel(center: world.center, parentPath: world.folder.path, announce: { heard.append($0) })
        model.searchTerm = "braille"
        await model.search()?.value
        let result = try XCTUnwrap(model.searchResults.first)

        await model.subscribe(to: result)?.value

        XCTAssertEqual(model.address, world.server.url("/dots-and-dashes/rss").absoluteString)
        let feed = try XCTUnwrap(model.subscribedFeed)
        XCTAssertEqual(feed.title, "Dots and Dashes: Braille at the Kitchen Table")
        XCTAssertEqual(feed.feedURL, result.feedURL)
        XCTAssertEqual(
            world.library.feedFolderPath(forFolderID: feed.folderID),
            "\(world.folder.path)/Dots and Dashes: Braille at the Kitchen Table"
        )
        XCTAssertEqual(heard.last, FeedWording.checkingAddress)
        XCTAssertNil(model.failureMessage)
    }

    /// A result's Subscribe does nothing while a subscription runs.
    func testAResultWaitsForASubscriptionUnderWay() async throws {
        let world = try FeedTestWorld(self, label: "FeedSearchBusy")
        world.server.serve("/search", try .directoryAnswer("itunes-search-podcasts.json", feedsOn: world.server))
        var slowFeed = try StubResponse.fixture("npr-episodic.xml")
        slowFeed.pause = 0.2
        world.server.serve("/ledger-lines/podcast.xml", slowFeed)
        await world.start()
        let model = AddFeedModel(center: world.center, parentPath: world.folder.path, announce: { _ in })
        model.searchTerm = "ledger"
        await model.search()?.value
        let results = model.searchResults

        let first = model.subscribe(to: results[1])
        XCTAssertTrue(model.isWorking)
        XCTAssertNil(model.subscribe(to: results[0]), "a second subscription started while one ran")
        XCTAssertFalse(model.canSearch, "a search could start while a subscription ran")
        await first?.value

        XCTAssertEqual(model.subscribedFeed?.title, "Ledger Lines")
        XCTAssertEqual(world.server.requests(to: "/dots-and-dashes/rss"), [])
    }

    // MARK: - The Directory

    /// The directory's answer is read field by field: a count written as a
    /// string still counts, an author of the wrong type is left out, a feed
    /// that isn't a web address or is missing leaves its result out, as does
    /// a feed listed already whatever its scheme or trailing slash, and
    /// anything that is no object is skipped. An answer that is no list of
    /// results reads as none.
    func testTheDirectorysAnswerIsReadFieldByField() throws {
        let answer = """
        {"resultCount": 6, "results": [
          {"collectionName": "Counted", "artistName": 7, "trackCount": "12", "feedUrl": "https://a.example/feed"},
          {"collectionName": "Again", "feedUrl": "http://A.example/feed/"},
          {"collectionName": "Local", "feedUrl": "file:///Users/someone/feed.xml"},
          {"collectionName": "None"},
          "not an object",
          {"trackName": "Track Only", "trackCount": 0, "feedUrl": "https://b.example/rss"}
        ]}
        """
        let results = try XCTUnwrap(FeedDirectory.results(in: Data(answer.utf8)))

        XCTAssertEqual(results.map(\.title), ["Counted", "Track Only"])
        XCTAssertEqual(results.first?.episodeCount, 12)
        XCTAssertNil(results.first?.author)
        XCTAssertNil(results.last?.episodeCount, "a count of 0 was given")
        XCTAssertNil(FeedDirectory.results(in: Data(#"{"results": "none"}"#.utf8)))
        XCTAssertNil(FeedDirectory.results(in: Data("[]".utf8)))
        XCTAssertNil(FeedDirectory.results(in: Data("<html></html>".utf8)))
        XCTAssertEqual(FeedDirectory.results(in: Data(#"{"resultCount": 0, "results": []}"#.utf8)), [])
    }

    /// Apple's search address asks for podcasts alone, at most 50, with
    /// every character of the words but letters, digits, and "-._~"
    /// percent-encoded, so "&", "+", and letters beyond ASCII are searched
    /// for as they are.
    func testTheSearchAddressAsksForPodcastsAlone() {
        XCTAssertEqual(
            FeedDirectory.apple.searchURL(for: "Q&A + café")?.absoluteString,
            "https://itunes.apple.com/search?media=podcast&entity=podcast&limit=50&term=Q%26A%20%2B%20caf%C3%A9"
        )
        XCTAssertEqual(FeedDirectory.resultLimit, 50)
        XCTAssertEqual(FeedEnvironment.app.directory, .apple)
    }

    // MARK: - Words

    /// A podcast found reads as its title, then who publishes it and its
    /// episodes, as far as the directory says; its Subscribe names it.
    func testAPodcastFoundReadsAsOneLine() throws {
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example/rss"))
        let full = FeedDirectoryResult(title: "Ledger Lines", author: "Example Public Radio", episodeCount: 1, feedURL: feedURL)
        let bare = FeedDirectoryResult(title: "Raised Line Radio", author: nil, episodeCount: nil, feedURL: feedURL)

        XCTAssertEqual(FeedWording.searchResultLabel(full), "Ledger Lines, by Example Public Radio, 1 episode")
        XCTAssertEqual(FeedWording.searchResultDetails(full), "by Example Public Radio, 1 episode")
        XCTAssertEqual(FeedWording.searchResultLabel(bare), "Raised Line Radio")
        XCTAssertNil(FeedWording.searchResultDetails(bare))
        XCTAssertEqual(FeedWording.subscribeToResultLabel(full), "Subscribe to Ledger Lines")
        XCTAssertEqual(FeedWording.podcastsFound(count: 1, term: "ledger"), "1 podcast found for “ledger”.")
        XCTAssertEqual(FeedWording.searchResultsLabel(count: 2), "Search results, 2 podcasts")
    }

    // MARK: - The Sheet as Drawn

    /// The sheet draws the Search field beside the address field, and lists
    /// the podcasts found in a scrolling list only once a search has found
    /// some. (SwiftUI draws its push buttons, and so each result's
    /// Subscribe, without AppKit views a test can count; their words are
    /// pinned above.)
    func testTheSheetListsResultsOnlyOnceASearchFoundSome() async throws {
        let world = try FeedTestWorld(self, label: "FeedSearchDrawn")
        world.server.serve("/search", try .directoryAnswer("itunes-search-podcasts.json", feedsOn: world.server))
        let before = AddFeedModel(center: world.center, parentPath: "", announce: { _ in })
        let after = AddFeedModel(center: world.center, parentPath: "", announce: { _ in })
        after.searchTerm = "braille"
        await after.search()?.value
        XCTAssertEqual(after.searchResults.count, 3)

        var scrollViewsBefore = 0
        withHostedView(sheet(before, in: world), size: NSSize(width: 520, height: 720), until: {
            self.feedEditableFields(in: $0).count == 2
        }) { hosting in
            XCTAssertEqual(feedEditableFields(in: hosting).count, 2, "the address and Search fields")
            scrollViewsBefore = descendants(of: hosting, as: NSScrollView.self).count
        }
        withHostedView(sheet(after, in: world), size: NSSize(width: 520, height: 720), until: {
            self.descendants(of: $0, as: NSScrollView.self).count > scrollViewsBefore
        }) { hosting in
            XCTAssertEqual(feedEditableFields(in: hosting).count, 2, "a result drew a field of its own")
            XCTAssertEqual(
                descendants(of: hosting, as: NSScrollView.self).count,
                scrollViewsBefore + 1,
                "the podcasts found are not listed in a scrolling list of their own"
            )
        }
    }

    /// An Add Feed sheet doing `model`'s work in `world`'s library.
    private func sheet(_ model: AddFeedModel, in world: FeedTestWorld) -> AddFeedSheet {
        AddFeedSheet(
            model: model,
            library: world.library.library,
            feedFolders: LibraryFeedFolders(center: world.center),
            onCreateFolder: { _, _ in .success(nil) },
            onSubscribed: { _ in },
            onCancel: {}
        )
    }
}
