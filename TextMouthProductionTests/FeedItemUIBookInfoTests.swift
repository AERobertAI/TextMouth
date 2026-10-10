import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// What an episode or article loses while it belongs to its feed (FR11,
/// branch C; the user's answer to late question 4): its Book Info is
/// read-only, in the Library and in the reader, with a line saying why and
/// no field that takes typing, and the reader's Book Info button says so;
/// and its transcript is never cleaned up, while it can still be made and
/// deleted. A book of the library's own keeps all of these.
@MainActor
final class FeedItemUIBookInfoTests: XCTestCase {

    // MARK: - Which Book Info

    /// Book Info is read-only for an episode or article in its feed, and
    /// edits any book of the library's own; the reader's Book Info button
    /// says which, and the line under the heading says why.
    func testBookInfoIsReadOnlyForAFeedItem() {
        XCTAssertFalse(Self.book.hasReadOnlyBookInfo)
        XCTAssertFalse(Self.audiobook.hasReadOnlyBookInfo)
        XCTAssertTrue(Self.episode.hasReadOnlyBookInfo)
        XCTAssertTrue(Self.article.hasReadOnlyBookInfo)
        XCTAssertEqual(FeedItemBookInfoWording.readerButtonLabel(readOnly: false), "Edit book metadata")
        XCTAssertEqual(FeedItemBookInfoWording.readerButtonLabel(readOnly: true), "Show book information")
        XCTAssertEqual(FeedItemBookInfoWording.heading, "Book Information")
        XCTAssertEqual(FeedItemBookInfoWording.whyReadOnly(isArticle: false), "An episode's details come from its feed.")
        XCTAssertEqual(FeedItemBookInfoWording.whyReadOnly(isArticle: true), "An article's details come from its feed.")
        XCTAssertEqual(FeedItemBookInfoWording.done, "Done")
    }

    /// An episode's details, in order, as its tags and the library give
    /// them: its title, artist, feed, album, genre, the measured duration
    /// shown as the clock shows it and spoken in words, its format, and
    /// when it was added and last opened; a detail without a value is left
    /// out, a duration never measured is the tags' as given, and a feed no
    /// longer subscribed is not named.
    func testAnEpisodesDetails() {
        var episode = Self.episode
        episode.audioDuration = 3_840
        episode.lastOpened = Self.opened
        let metadata = AudioMetadata(
            title: "Ep. 368", artist: "Small Hours Audio", album: "Finish It!", genre: "Podcast", year: "",
            duration: "1:04:00", fileFormat: "MP3"
        )

        let details = FeedItemBookInfoWording.details(of: episode, info: .audio(metadata, isCloudOnly: false), feedTitle: "Finish It!")

        XCTAssertEqual(details, [
            BookInfoDetail(label: "Title", value: "Ep. 368"),
            BookInfoDetail(label: "Artist", value: "Small Hours Audio"),
            BookInfoDetail(label: "Feed", value: "Finish It!"),
            BookInfoDetail(label: "Album", value: "Finish It!"),
            BookInfoDetail(label: "Genre", value: "Podcast"),
            BookInfoDetail(label: "Duration", value: "1:04:00", spokenValue: "1 hour, 4 minutes"),
            BookInfoDetail(label: "Format", value: "MP3"),
            BookInfoDetail(label: "Added", value: FeedWording.itemDate(Self.added)),
            BookInfoDetail(label: "Last opened", value: FeedWording.itemDate(Self.opened)),
        ])

        episode.audioDuration = nil
        let unmeasured = FeedItemBookInfoWording.details(of: episode, info: .audio(metadata, isCloudOnly: true), feedTitle: nil)
        XCTAssertEqual(unmeasured.first { $0.label == "Duration" }, BookInfoDetail(label: "Duration", value: "1:04:00"))
        XCTAssertFalse(unmeasured.contains { $0.label == "Feed" }, "a feed no longer subscribed was named")
        XCTAssertTrue(LibraryBookInfo.audio(metadata, isCloudOnly: true).isCloudOnly)
        XCTAssertFalse(LibraryBookInfo.simple.isCloudOnly)
    }

    /// An article's details: its title, author, feed, format, word count,
    /// and when it was added; it was never opened, so no last opening.
    func testAnArticlesDetails() {
        var article = Self.article
        article.totalWordCount = 1_240

        XCTAssertEqual(FeedItemBookInfoWording.details(of: article, info: .simple, feedTitle: "City Notes"), [
            BookInfoDetail(label: "Title", value: "Night trams"),
            BookInfoDetail(label: "Author", value: "Wren Oduya"),
            BookInfoDetail(label: "Feed", value: "City Notes"),
            BookInfoDetail(label: "Format", value: "HTML"),
            BookInfoDetail(label: "Word count", value: "1240"),
            BookInfoDetail(label: "Added", value: FeedWording.itemDate(Self.added)),
        ])
    }

    // MARK: - The Sheets as Drawn

    /// No field of a feed item's Book Info takes typing, where the editor of
    /// a book of the library's own has its title and author fields, hosted
    /// the same way.
    func testTheReadOnlySheetHasNoFieldToType() {
        let editor = LibraryBookInfoSheet(book: Self.book, libraryViewModel: LibraryViewModel(initializeServices: false))
        withHostedView(editor, until: { self.feedEditableFields(in: $0).count >= 2 }) { hosting in
            XCTAssertEqual(feedEditableFields(in: hosting).count, 2, "the editor's title and author fields were not drawn")
        }

        let sheet = FeedItemBookInfoSheet(book: Self.episode, info: .audio(AudioMetadata(title: "Ep. 368"), isCloudOnly: false), feedTitle: "Finish It!")
        withHostedView(sheet, until: { !self.descendants(of: $0, as: NSScrollView.self).isEmpty }) { hosting in
            XCTAssertFalse(descendants(of: hosting, as: NSScrollView.self).isEmpty, "the read-only sheet was not drawn")
            XCTAssertEqual(feedEditableFields(in: hosting).count, 0, "a field of a feed item's Book Info takes typing")
        }
    }

    /// The reader's Book Info for an article downloaded from its feed is the
    /// read-only sheet, with no field that takes typing.
    func testTheReadersBookInfoOfAFeedItemIsReadOnly() async throws {
        let world = try FeedTestWorld(self, label: "FeedItemUIReaderInfo")
        let page = "<html><body><article><h2>Night trams</h2><p>The tram climbs past the depot.</p></article></body></html>"
        world.server.serve("/stories/trams", StubResponse(headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(page.utf8)))
        let item = FeedXML.Item(
            guid: "story-1", title: "Night trams", published: world.day(-1),
            description: "Which routes still run [...]", link: world.server.url("/stories/trams").absoluteString
        )
        world.server.serve("/feed.xml", .feed(FeedXML.rss(title: "City Notes", items: [item])))
        let feed = try await world.subscribe("/feed.xml")
        world.center.download("guid:story-1", of: feed.id)
        let book = try await downloadedBook(world, feed: feed, item: "guid:story-1")
        XCTAssertTrue(book.hasReadOnlyBookInfo)
        XCTAssertEqual(world.library.feedTitle(of: book), "City Notes")

        let reader = try openReader(for: book, in: world)
        await waitFor("the article loads in its reader") { !reader.isLoading }
        XCTAssertNil(reader.errorMessage)
        withHostedView(ReaderBookInfoSheet(viewModel: reader), until: { !self.descendants(of: $0, as: NSScrollView.self).isEmpty }) { hosting in
            XCTAssertFalse(descendants(of: hosting, as: NSScrollView.self).isEmpty, "the reader's Book Info was not drawn")
            XCTAssertEqual(feedEditableFields(in: hosting).count, 0, "the reader's Book Info of a feed item takes typing")
        }
    }

    // MARK: - Transcript Cleanup

    /// A transcribed episode in its feed offers Transcribe Audio… and Delete
    /// Transcript… but not Clean Up Transcript (Experimental)…, whose sheet
    /// holds Undo Cleanup too; an audiobook of the library's own offers all
    /// of them.
    func testAFeedItemsTranscriptIsNotCleanedUp() {
        let episode = Self.episode
        let audiobook = Self.audiobook
        XCTAssertEqual(
            LibraryAudioCommand.commands(for: [episode], isTranscribed: { _ in true }),
            [.transcribe([episode]), .deleteTranscript(episode)]
        )
        XCTAssertEqual(
            LibraryAudioCommand.commands(for: [audiobook], isTranscribed: { _ in true }),
            [.editAudio(audiobook), .transcribe([audiobook]), .cleanUpTranscript(audiobook), .deleteTranscript(audiobook)]
        )
        XCTAssertFalse(LibraryAudioCommand.isTranscriptCleanable(episode))
        XCTAssertTrue(LibraryAudioCommand.isTranscriptCleanable(audiobook))
    }

    // MARK: - Helpers

    /// When the books below were added.
    private static let added = Date(timeIntervalSince1970: 1_791_000_000)
    /// When the episode below was last opened, in the tests that open it.
    private static let opened = Date(timeIntervalSince1970: 1_791_086_400)

    /// A text book of the library's own.
    private static let book = Book(title: "Field notes", author: "Ines Varga", format: .txt, filePath: "/notes.txt", md5Hash: "")

    /// An audiobook of the library's own, in a package of its own.
    private static let audiobook = Book(
        title: "Breakwater Soundings", format: .audio, filePath: "/Breakwater.m4a", md5Hash: "", tmbDirectoryName: "Breakwater.tmb"
    )

    /// An episode in its feed, in a package of its own.
    private static var episode: Book {
        var episode = Book(
            title: "Ep. 368", format: .audio, filePath: "/Ep. 368.m4a", md5Hash: "", tmbDirectoryName: "Ep. 368.tmb",
            feedLink: FeedBookLink(feedID: UUID(), itemID: "guid:368")
        )
        episode.dateAdded = added
        return episode
    }

    /// An article in its feed.
    private static var article: Book {
        var article = Book(
            title: "Night trams", author: "Wren Oduya", format: .html, filePath: "/Night trams.html", md5Hash: "",
            tmbDirectoryName: "Night trams.tmb", feedLink: FeedBookLink(feedID: UUID(), itemID: "guid:story-1")
        )
        article.dateAdded = added
        return article
    }

    /// A reader of `book` in `world`'s library, as a reader window makes
    /// one, with settings of the test's own; closed when the test ends.
    private func openReader(for book: Book, in world: FeedTestWorld) throws -> ReaderViewModel {
        let configFile = try makeSandboxDirectory("FeedItemUIReaderConfig").appendingPathComponent("config.json")
        let settings = SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false,
            userDefaults: makeSandboxedPreferences("FeedItemUIReaderSettings"),
            configService: ConfigService(fileURL: configFile)
        )
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: world.library,
            settingsViewModel: settings,
            substitutionService: TextSubstitutionService(rules: []),
            autoplayRequests: ReaderAutoplayRequests(),
            notificationCenter: NotificationCenter(),
            renderScheduler: nil
        )
        addTeardownBlock { @MainActor in reader.close() }
        return reader
    }
}
