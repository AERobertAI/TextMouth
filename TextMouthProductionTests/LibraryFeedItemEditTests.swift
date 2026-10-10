import XCTest
@testable import TextMouth

/// Feed items are not editable (FR11, question 4): Edit Text… and Edit Text
/// With… are not offered for an episode or an article in its feed's folder,
/// and an article edited before keeps its edit when its download goes: the
/// copies Edit Text kept stay in its kept package, and stay when it
/// downloads again, and its content.md, which holds the edit, goes through
/// the listener's own removal, which follows the Trash setting, rather than
/// for good with the caches (the A2 review's item E).
final class LibraryFeedItemEditTests: XCTestCase {

    // MARK: - Edit Text

    /// Edit Text is offered for a book of the library's own, and for no
    /// feed item: an article, or an episode even once transcribed.
    @MainActor
    func testEditTextIsNotOfferedForAFeedItem() {
        let link = FeedBookLink(feedID: UUID(), itemID: "guid:post-1")
        let article = Book(
            title: "Corkboard 7.1.2 Released",
            format: .html,
            filePath: "/Feeds/post.tmb/post.html",
            md5Hash: "post",
            tmbDirectoryName: "post.tmb",
            feedLink: link
        )
        var episode = article
        episode.format = .audio
        var book = article
        book.feedLink = nil

        XCTAssertFalse(BookTextEditor.canEditText(of: article, isTranscribed: false))
        XCTAssertFalse(BookTextEditor.canEditText(of: episode, isTranscribed: true))
        XCTAssertTrue(BookTextEditor.canEditText(of: book, isTranscribed: false))
    }

    // MARK: - What a Kept Package Keeps

    /// The copies Edit Text kept stay in a kept package whatever the book's
    /// format, while an article's content.md, made from its file, does not.
    func testTheCopiesEditTextKeptStayForEveryFormat() {
        let copy = "content.md\(TextMouthPaths.keptTextCopyMarker)20261010T020000Z"

        XCTAssertTrue(FeedItemPackage.staysWithoutTheFile(copy, format: .html))
        XCTAssertTrue(FeedItemPackage.staysWithoutTheFile(copy, format: .audio))
        XCTAssertFalse(FeedItemPackage.staysWithoutTheFile("content.md", format: .html))
        XCTAssertTrue(FeedItemPackage.staysWithoutTheFile("content.md", format: .audio))
    }

    /// Downloading a kept article again carries the copies Edit Text kept
    /// into its new package, beside its transcript, and not its record,
    /// which is written anew.
    func testDownloadingAgainKeepsTheCopiesEditTextKept() throws {
        let kept = try makeSandboxDirectory("LibraryFeedKeptArticle")
        let staged = try makeSandboxDirectory("LibraryFeedStagedArticle")
        let copy = "content.md\(TextMouthPaths.keptTextCopyMarker)20261010T020000Z"
        try Data("# An earlier edit".utf8).write(to: kept.appendingPathComponent(copy))
        try Data("{}".utf8).write(to: TextMouthPaths.transcriptPath(in: kept))
        try Data("{}".utf8).write(to: TextMouthPaths.bookInfoPath(in: kept))

        try FeedItemPackage.copyWhatANewDownloadKeeps(from: kept, to: staged)

        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: staged.path)),
            [copy, TextMouthPaths.transcriptPath(in: staged).lastPathComponent]
        )
    }

    // MARK: - Delete Download of an Edited Article

    /// Delete Download of an opened article whose text was edited sends its
    /// content.md, then its file, through the feed engine's removal, which
    /// in the app follows the Trash setting, and keeps its record and the
    /// copy Edit Text kept.
    @MainActor
    func testDeleteDownloadSendsAnEditedArticlesTextThroughTheListenersRemoval() async throws {
        let world = try FeedTestWorld(self, label: "LibraryFeedEditedArticle")
        let removed = RemovedItems()
        var environment = world.environment
        environment.removeItem = { url in
            removed.urls.append(url)
            try FileManager.default.removeItem(at: url)
        }
        let center = FeedCenter(environment: environment)
        addTeardownBlock { await MainActor.run { center.stop() } }
        world.library.feedEngine = center
        await center.start(library: world.library)?.value
        let paragraphs = (1...20).map { "<p>Paragraph \($0) of the release notes says what changed.</p>" }
        let item = FeedXML.Item(guid: "post-1", title: "Corkboard 7.1.2 Released", published: world.day(-1),
                                description: paragraphs.joined(), link: "https://news.example/corkboard-7-1-2")
        world.server.serve("/feed.xml", .feed(FeedXML.rss(title: "Corkboard News", items: [item])))
        let outcome = try await center.subscribe(to: world.server.url("/feed.xml").absoluteString, folderID: world.bookFolder.id)
        guard case .subscribed(let feed) = outcome else {
            XCTFail("subscribing offered a choice instead: \(outcome)")
            return
        }
        center.download("guid:post-1", of: feed.id)
        let article = try await downloadedBook(world, center: center, feed: feed, item: "guid:post-1")
        world.library.persistReadingPosition(bookID: article.id, position: ReadingPosition(chapterIndex: 0, characterOffset: 10))
        let package = article.tmbDirectory
        let text = TextMouthPaths.contentMarkdownPath(in: package)
        try "# Edited by hand".write(to: text, atomically: true, encoding: .utf8)
        let copy = package.appendingPathComponent("content.md\(TextMouthPaths.keptTextCopyMarker)20261010T020000Z")
        try "# An earlier edit".write(to: copy, atomically: true, encoding: .utf8)

        try center.deleteDownload("guid:post-1", of: feed.id)

        XCTAssertEqual(removed.urls.map(\.lastPathComponent), [text.lastPathComponent, article.bookFileURL.lastPathComponent])
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "# An earlier edit")
        XCTAssertFalse(FileManager.default.fileExists(atPath: text.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: TextMouthPaths.bookInfoPath(in: package).path))
        XCTAssertEqual(world.library.feedItemRows(of: feed.id).kept["guid:post-1"]?.id, article.id)
    }

    // MARK: - Fixtures

    /// The items the feed engine's removal was given, in order.
    @MainActor
    private final class RemovedItems {
        var urls: [URL] = []
    }
}
