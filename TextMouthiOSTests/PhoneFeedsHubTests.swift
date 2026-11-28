import XCTest
@testable import TextMouth

/// What the iPhone adds to the feed reader (FR53, phase F1): the hub that opens
/// the Add Feed sheet once the Add to Library sheet has closed and hands a row's
/// command to the Mac's runner, and, in debug builds, the stand-in feed server
/// a UI test subscribes to. The Mac's models and words are tested on the Mac
/// (`PhoneFeedRowsTests`, `FeedUIAddFeedTests`); these test what only the
/// iPhone compiles. Nothing here reaches the network, plays, or speaks.
@MainActor
final class PhoneFeedsHubTests: XCTestCase {
    // MARK: - Fixtures

    /// A library of folders at `paths`, with no services running and no book.
    private func library(folders paths: [String]) -> LibraryViewModel {
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(folders: paths.map { BookFolder(name: $0) })
        return model
    }

    /// Lets the main queue run what was put on it before now, where the hub puts the sheet it opens.
    private func drainMainQueue() {
        let drained = expectation(description: "the main queue ran")
        DispatchQueue.main.async { drained.fulfill() } // lint-ok: one block, so fulfilled once
        wait(for: [drained], timeout: 5)
    }

    // MARK: - Add Feed…

    /// Add Feed… opens its sheet, once the Add to Library sheet has closed, with the feed's folder first going in
    /// the folder the Library showed; before that, and after, nothing opens.
    func testAddFeedOpensOnceAfterItWasChosen() {
        let model = library(folders: ["Podcasts"])
        let hub = PhoneFeedsHub(presenter: LibraryFeedsPresenter())

        hub.showRequestedAddFeed(in: model)
        drainMainQueue()
        XCTAssertNil(hub.presenter.addFeed, "A sheet opened that nobody chose")

        hub.requestAddFeed(parentPath: "Podcasts")
        XCTAssertNil(hub.presenter.addFeed, "The sheet opened while the Add to Library sheet was still open")
        hub.showRequestedAddFeed(in: model)
        drainMainQueue()
        XCTAssertEqual(hub.presenter.addFeed?.parentPath, "Podcasts")

        hub.presenter.cancelAddFeed()
        hub.showRequestedAddFeed(in: model)
        drainMainQueue()
        XCTAssertNil(hub.presenter.addFeed, "The same choice opened the sheet twice")
    }

    /// A folder the sheet can't put a feed in, a feed's own or one that has gone, gives the top.
    func testAFolderThatCannotHoldAFeedGivesTheTop() {
        let model = library(folders: ["Podcasts"])
        let hub = PhoneFeedsHub(presenter: LibraryFeedsPresenter())

        hub.requestAddFeed(parentPath: "Gone")
        hub.showRequestedAddFeed(in: model)
        drainMainQueue()

        XCTAssertEqual(hub.presenter.addFeed?.parentPath, "")
    }

    // MARK: - What the Commands Say

    /// What a command says goes to VoiceOver through the phone's announcer, queued after VoiceOver's own speech.
    func testACommandsWordsGoThroughThePhonesAnnouncer() {
        let hub = PhoneFeedsHub(presenter: LibraryFeedsPresenter())
        let previous = PhoneAnnouncer.schedule
        PhoneAnnouncer.schedule = { _, work in work() }
        defer { PhoneAnnouncer.schedule = previous }
        let before = VoiceOverAnnouncer.recordedAnnouncements.count

        hub.presenter.announce("Downloading First map.", nil)

        XCTAssertEqual(VoiceOverAnnouncer.recordedAnnouncements.count, before + 1)
        XCTAssertEqual(VoiceOverAnnouncer.recordedAnnouncements.last?.message, "Downloading First map.")
        XCTAssertEqual(VoiceOverAnnouncer.recordedAnnouncements.last?.priority, .low)
    }

    /// A command for a feed or an item that is gone does nothing and says nothing.
    func testACommandForAFeedThatIsGoneDoesNothing() {
        let model = library(folders: [])
        let hub = PhoneFeedsHub(presenter: LibraryFeedsPresenter())
        let before = VoiceOverAnnouncer.recordedAnnouncements.count

        hub.perform(.checkFeed, feedID: UUID(), in: model)
        hub.perform(.markPlayed, feedID: UUID(), itemID: "guid:none", in: model)

        XCTAssertEqual(VoiceOverAnnouncer.recordedAnnouncements.count, before)
        XCTAssertNil(hub.presenter.feedInfo)
        XCTAssertNil(hub.presenter.confirmation)
    }

    // The stand-in feed server is a debug build's alone.
    #if DEBUG

    // MARK: - The Stand-In Feed Server

    /// The stand-in answers its own host and no other, so it can never answer a real feed.
    func testTheStandInAnswersItsOwnHostOnly() throws {
        let ours = URLRequest(url: try XCTUnwrap(URL(string: PhoneUITestFeedStub.feedAddress)))
        let other = URLRequest(url: try XCTUnwrap(URL(string: "https://example.com/atlas.xml")))

        XCTAssertTrue(PhoneUITestFeedStub.canInit(with: ours))
        XCTAssertFalse(PhoneUITestFeedStub.canInit(with: other))
    }

    /// It is on only in a sandboxed launch that named an episode file.
    func testTheStandInIsOnOnlyWhenAskedFor() {
        let sandbox = PhoneLaunchRequest.sandboxVariable
        let episode = PhoneLaunchRequest.feedEpisodeVariable
        XCTAssertTrue(PhoneUITestFeedStub.isOn([sandbox: "1", episode: "/tone.wav"]))
        XCTAssertFalse(PhoneUITestFeedStub.isOn([sandbox: "1"]), "no episode file named")
        XCTAssertFalse(PhoneUITestFeedStub.isOn([episode: "/tone.wav"]), "no sandbox")
        XCTAssertFalse(PhoneUITestFeedStub.isOn([sandbox: "1", episode: "tone.wav"]), "a relative path")
    }

    /// The feed it serves is one the app's own parser reads, with the two episodes, newest first, each with its audio.
    func testTheStandInsFeedParsesWithTheAppsParser() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PhoneUITestFeedStub.self]
        let session = URLSession(configuration: configuration)
        let url = try XCTUnwrap(URL(string: PhoneUITestFeedStub.feedAddress))

        let (data, response) = try await session.data(from: url)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let parsed = try FeedParser.parse(data, baseURL: url)
        XCTAssertEqual(parsed.title, PhoneUITestFeedStub.feedTitle)
        XCTAssertEqual(parsed.items.map(\.title), PhoneUITestFeedStub.episodeTitles)
        XCTAssertTrue(parsed.items.allSatisfy { $0.enclosure?.url.host == PhoneUITestFeedStub.host })
    }

    /// An address the stand-in doesn't know fails, as a missing file does.
    func testTheStandInFailsAnUnknownAddress() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PhoneUITestFeedStub.self]
        let session = URLSession(configuration: configuration)
        let url = try XCTUnwrap(URL(string: "https://\(PhoneUITestFeedStub.host)/nothing.xml"))

        do {
            _ = try await session.data(from: url)
            XCTFail("An unknown address was answered")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .fileDoesNotExist)
        }
    }

    #endif
}
