import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// The feed reader's commands (FR03): what a feed and an item offer, by
/// where an item's download stands, and what each does through the engine,
/// against a stub server: Check Feed, Feed Info… with the feed's own
/// settings and folder, Mark All Played, Unsubscribe… naming the books left
/// behind, Open, Download, Cancel Download, Delete Download (refused while
/// the book is open, in the engine's words), Mark Played and Unplayed, Show
/// Description…, Show in Finder, and Delete Episode… after a confirmation.
/// No episode is played aloud: a download only becomes a book.
@MainActor
final class FeedUICommandsTests: XCTestCase {

    // MARK: - What Each Offers

    /// An item offers its commands by where its download stands, worded
    /// for an episode or an article, and a downloaded item's book row
    /// leaves Open and Show in Finder to the book's own menu.
    func testAnItemOffersItsCommandsByItsState() {
        let feedID = UUID()
        func titles(_ state: FeedItemState, played: Bool = false, article: Bool = false, onBookRow: Bool = false) -> [String] {
            FeedItemAction.actions(
                feedID: feedID,
                itemID: "guid:1",
                itemTitle: "Item",
                state: state,
                isPlayed: played,
                isArticle: article,
                onBookRow: onBookRow
            ).map(\.title)
        }
        let progress = BookDownloadProgress(completedFiles: 0, totalFiles: 1, completedBytes: 1, totalBytes: 2)
        let book = UUID()

        XCTAssertEqual(titles(.notDownloaded), ["Open", "Download", "Mark Played", "Show Description…", "Delete Episode…"])
        XCTAssertEqual(titles(.downloading(progress)), ["Open", "Cancel Download", "Mark Played", "Show Description…", "Delete Episode…"])
        XCTAssertEqual(titles(.failed("gone"), played: true), ["Open", "Download", "Mark Unplayed", "Show Description…", "Delete Episode…"])
        XCTAssertEqual(
            titles(.downloaded(bookID: book)),
            ["Open", "Mark Played", "Show Description…", "Show in Finder", "Delete Download", "Delete Episode…"]
        )
        XCTAssertEqual(titles(.downloaded(bookID: book), onBookRow: true), ["Mark Played", "Show Description…", "Delete Download", "Delete Episode…"])
        XCTAssertEqual(titles(.notDownloaded, article: true), ["Open", "Download", "Mark Read", "Show Description…", "Delete Article…"])
        XCTAssertEqual(titles(.notDownloaded, played: true, article: true).dropFirst(2).first, "Mark Unread")
    }

    /// A feed offers Check Feed, Feed Info…, Mark All Played (Mark All Read
    /// for articles), and Unsubscribe…, always.
    func testAFeedOffersItsCommands() {
        let feedID = UUID()
        XCTAssertEqual(
            FeedAction.actions(for: feedID, noun: .episode).map(\.title),
            ["Check Feed", "Feed Info…", "Mark All Played", "Unsubscribe…"]
        )
        XCTAssertEqual(FeedAction.actions(for: feedID, noun: .article).map(\.title).dropFirst(2).first, "Mark All Read")
        XCTAssertTrue(FeedAction.actions(for: feedID, noun: .item).allSatisfy { $0.feedID == feedID })
    }

    // MARK: - Downloads

    /// Download downloads the item into its feed's folder and says so;
    /// Open on a downloaded item opens its book; Delete Download deletes
    /// the book and keeps the item; Show in Finder shows the package.
    func testDownloadOpenShowAndDeleteADownload() async throws {
        let harness = try await Harness(self, label: "FeedUICommandsDownload")
        let download = harness.action(.download)

        harness.presenter.perform(download, in: harness.context)

        let book = try await downloadedBook(harness.world, feed: harness.feed, item: Harness.episodeID)
        XCTAssertEqual(book.folderPath, harness.world.library.feedFolderPath(forFolderID: harness.feed.folderID))
        XCTAssertEqual(harness.heard.first, "Downloading “A map you can touch”.")

        var opened: [UUID] = []
        harness.world.library.readerOpener = { opened.append($0) }
        harness.presenter.perform(harness.action(.open), in: harness.context)
        XCTAssertEqual(opened, [book.id])

        var revealed: [Book] = []
        harness.presenter.revealBooks = { revealed += $0 }
        harness.presenter.perform(harness.action(.showInFinder), in: harness.context)
        XCTAssertEqual(revealed.map(\.id), [book.id])

        harness.presenter.perform(harness.action(.deleteDownload), in: harness.context)
        XCTAssertNil(harness.world.library.bookByID(book.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: book.tmbDirectory.path))
        XCTAssertEqual(harness.item?.state, .notDownloaded)
        XCTAssertEqual(harness.heard.last, "Deleted the download of “A map you can touch”. It can be downloaded again.")
    }

    /// Delete Download is refused while the book is open in a reader, in
    /// the engine's words, shown and spoken, and the book stays.
    func testDeleteDownloadIsRefusedWhileTheBookIsOpen() async throws {
        let harness = try await Harness(self, label: "FeedUICommandsOpenBook")
        harness.presenter.perform(harness.action(.download), in: harness.context)
        let book = try await downloadedBook(harness.world, feed: harness.feed, item: Harness.episodeID)
        harness.world.library.openBookIDs.insert(book.id)

        harness.presenter.perform(harness.action(.deleteDownload), in: harness.context)

        let refusal = BookCloudError.bookIsOpen.explanation(in: nil)
        XCTAssertEqual(harness.presenter.notice?.title, FeedWording.deleteRefusedTitle)
        XCTAssertEqual(harness.presenter.notice?.message, refusal)
        XCTAssertEqual(harness.heard.last, refusal)
        XCTAssertNotNil(harness.world.library.bookByID(book.id), "an open book's download was deleted")
        harness.world.library.openBookIDs.remove(book.id)
    }

    /// Open on an item not downloaded says it downloads first, then opens
    /// its book once it is in the library.
    func testOpenDownloadsFirstThenOpens() async throws {
        let harness = try await Harness(self, label: "FeedUICommandsOpen")
        var opened: [UUID] = []
        harness.world.library.readerOpener = { opened.append($0) }

        harness.presenter.perform(harness.action(.open), in: harness.context)

        XCTAssertEqual(harness.heard, [FeedWording.downloadingToOpen(title: "A map you can touch")])
        await waitFor("the episode downloads and opens", timeout: 20) { !opened.isEmpty }
        let bookID = try XCTUnwrap(opened.first)
        XCTAssertEqual(harness.item?.state, .downloaded(bookID: bookID))
    }

    /// Cancel Download stops a download under way; the item is not
    /// downloaded, and nothing joins the library.
    func testCancelDownloadStopsIt() async throws {
        let harness = try await Harness(self, label: "FeedUICommandsCancel", slowDownload: true)
        harness.presenter.perform(harness.action(.download), in: harness.context)
        XCTAssertTrue(harness.item?.state.isDownloading ?? false)
        XCTAssertEqual(harness.action(.cancelDownload).title, "Cancel Download")

        harness.presenter.perform(harness.action(.cancelDownload), in: harness.context)

        await waitFor("the download stops") {
            harness.item?.state == .notDownloaded && !harness.world.center.downloads.isDownloading(Harness.episodeID, of: harness.feed.id)
        }
        XCTAssertEqual(harness.heard.last, "Stopped downloading “A map you can touch”.")
        XCTAssertTrue(harness.world.library.library.books.isEmpty)
    }

    // MARK: - Played, Descriptions, and Deleting

    /// Mark Played and Mark Unplayed change the item and say so; Mark All
    /// Played marks every unplayed item in one change, then says there is
    /// nothing left to mark.
    func testMarkingPlayed() async throws {
        let harness = try await Harness(self, label: "FeedUICommandsPlayed")

        harness.presenter.perform(harness.action(.markPlayed), in: harness.context)
        XCTAssertNotNil(harness.item?.playedDate)
        XCTAssertEqual(harness.heard.last, "Marked “A map you can touch” played.")

        harness.presenter.perform(harness.action(.markUnplayed), in: harness.context)
        XCTAssertNil(harness.item?.playedDate)
        XCTAssertEqual(harness.heard.last, "Marked “A map you can touch” unplayed.")

        let markAll = try XCTUnwrap(FeedAction.actions(for: harness.feed.id, noun: .episode).first { $0.command == .markAllPlayed })
        harness.presenter.perform(markAll, in: harness.context)
        XCTAssertTrue(harness.world.center.listedItems(of: harness.feed.id).allSatisfy { $0.playedDate != nil })
        XCTAssertEqual(harness.heard.last, "Marked 2 episodes of The Tactile Atlas played.")
        harness.presenter.perform(markAll, in: harness.context)
        XCTAssertEqual(harness.heard.last, "Every episode of The Tactile Atlas is already played.")
    }

    /// Show Description… shows the item's text, its feed and date, and its
    /// web page, or says it has none.
    func testShowDescriptionShowsTheItemsText() async throws {
        let harness = try await Harness(self, label: "FeedUICommandsDescription")

        harness.presenter.perform(harness.action(.showDescription), in: harness.context)

        let shown = try XCTUnwrap(harness.presenter.itemDescription)
        XCTAssertEqual(shown.title, "A map you can touch")
        XCTAssertEqual(shown.text, "Raised lines and dots, read by hand.")
        XCTAssertTrue(shown.details.hasPrefix("The Tactile Atlas"), shown.details)
        XCTAssertEqual(shown.link?.absoluteString, "https://atlas.example/maps")

        harness.presenter.perform(harness.action(.showDescription, item: Harness.secondID), in: harness.context)
        XCTAssertEqual(harness.presenter.itemDescription?.text, "This episode has no description.")
    }

    /// Delete Episode… asks first; confirmed, it hides the item for good,
    /// so checking the feed never brings it back.
    func testDeleteEpisodeAsksFirstAndHidesItForGood() async throws {
        let harness = try await Harness(self, label: "FeedUICommandsDeleteItem")

        harness.presenter.perform(harness.action(.deleteItem), in: harness.context)

        let confirmation = try XCTUnwrap(harness.presenter.confirmation)
        XCTAssertEqual(confirmation.title, "Delete “A map you can touch”?")
        XCTAssertEqual(confirmation.confirmTitle, "Delete Episode")
        XCTAssertEqual(confirmation.message, FeedWording.deleteItemMessage(isArticle: false))
        XCTAssertNotNil(harness.item, "the episode is gone")
        XCTAssertNil(harness.item?.deletedDate, "deleted before it was confirmed")

        harness.presenter.confirm(confirmation, in: harness.context)

        XCTAssertNotNil(harness.item?.deletedDate)
        XCTAssertEqual(harness.world.center.listedItems(of: harness.feed.id).map(\.id), [Harness.secondID])
        XCTAssertEqual(harness.heard.last, "Deleted “A map you can touch”.")
        await harness.world.center.refresh(harness.feed.id)
        XCTAssertEqual(harness.world.center.listedItems(of: harness.feed.id).map(\.id), [Harness.secondID], "a check brought it back")
    }

    // MARK: - A Feed's Commands

    /// Check Feed says it is checking, then how many new items came.
    func testCheckFeedSaysWhatCame() async throws {
        let harness = try await Harness(self, label: "FeedUICommandsCheck")
        let newer = FeedXML.Item(
            guid: "ep-3",
            title: "A third map",
            published: harness.world.day(2),
            enclosure: harness.world.server.url("/audio/3.m4a").absoluteString,
            enclosureType: "audio/mp4"
        )
        harness.world.server.serve("/feed.xml", .feed(FeedXML.rss(items: [newer] + Harness.items(harness.world))))
        harness.world.advance(by: 3 * 86_400)
        let check = try XCTUnwrap(FeedAction.actions(for: harness.feed.id, noun: .episode).first { $0.command == .checkFeed })

        await harness.presenter.perform(check, in: harness.context)?.value

        XCTAssertEqual(harness.heard, ["Checking The Tactile Atlas…", "The Tactile Atlas: 1 new episode."])
        await harness.presenter.perform(check, in: harness.context)?.value
        XCTAssertEqual(harness.heard.last, "The Tactile Atlas: no new episodes.")
    }

    /// Unsubscribe… asks first, naming the books its downloads made, which
    /// stay; confirmed, the feed goes and its books stay.
    func testUnsubscribeNamesTheBooksLeftBehind() async throws {
        let harness = try await Harness(self, label: "FeedUICommandsUnsubscribe")
        harness.presenter.perform(harness.action(.download), in: harness.context)
        let book = try await downloadedBook(harness.world, feed: harness.feed, item: Harness.episodeID)
        let unsubscribe = try XCTUnwrap(FeedAction.actions(for: harness.feed.id, noun: .episode).last)
        let folderPath = harness.world.library.feedFolderPath(forFolderID: harness.feed.folderID)

        harness.presenter.perform(unsubscribe, in: harness.context)

        let confirmation = try XCTUnwrap(harness.presenter.confirmation)
        XCTAssertEqual(confirmation.title, "Unsubscribe from The Tactile Atlas?")
        XCTAssertEqual(confirmation.message, FeedWording.unsubscribeMessage(bookTitles: [book.title], folderPath: folderPath))
        XCTAssertTrue(confirmation.message.contains("“A map you can touch”"), confirmation.message)

        harness.presenter.confirm(confirmation, in: harness.context)

        XCTAssertTrue(harness.world.center.feeds.isEmpty)
        XCTAssertNotNil(harness.world.library.bookByID(book.id), "unsubscribing deleted a download")
        XCTAssertEqual(harness.heard.last, "Unsubscribed from The Tactile Atlas. 1 book it downloaded stays in the library.")
    }

    /// Feed Info… opens the feed's sheet; its two settings follow the
    /// global ones until the listener gives the feed its own, and its
    /// folder can be changed for new downloads.
    func testFeedInfoKeepsTheFeedsOwnSettings() async throws {
        let harness = try await Harness(self, label: "FeedUICommandsInfo")
        let info = try XCTUnwrap(FeedAction.actions(for: harness.feed.id, noun: .episode).first { $0.command == .feedInfo })

        harness.presenter.perform(info, in: harness.context)

        let model = try XCTUnwrap(harness.presenter.feedInfo)
        XCTAssertTrue(model.keepsGlobalEntries)
        XCTAssertEqual(model.keepEntries, 10)
        model.keepsGlobalEntries = false
        XCTAssertEqual(harness.record?.feed.keepEntriesOverride, 10)
        model.keepEntries = 25
        XCTAssertEqual(harness.record?.feed.keepEntriesOverride, 25)
        model.keepEntries = -7
        XCTAssertEqual(harness.record?.feed.keepEntriesOverride, -1, "a value below the off value is the off value")
        model.keepsGlobalEntries = true
        XCTAssertNil(harness.record?.feed.keepEntriesOverride)

        XCTAssertTrue(model.deletesAfterGlobalDays)
        model.deletesAfterGlobalDays = false
        model.deleteDaysAfterPlaying = 0
        XCTAssertEqual(harness.record?.feed.deleteDownloadsDaysAfterPlayedOverride, 0)
        model.deletesAfterGlobalDays = true
        XCTAssertNil(harness.record?.feed.deleteDownloadsDaysAfterPlayedOverride)

        // The folder: any but another feed's, here the world's own folder.
        let options = model.folderOptions(feedFolders: LibraryFeedFolders(center: harness.world.center)).map(\.path)
        XCTAssertTrue(options.contains(harness.world.folder.path))
        XCTAssertFalse(options.contains(""), "the top level was offered as a feed's folder")
        model.chooseFolder(atPath: harness.world.folder.path)
        XCTAssertEqual(harness.record?.feed.folderID, harness.world.bookFolder.id)
    }

    // MARK: - The Words

    /// The words Check Feed, Mark All Played, and Unsubscribe use.
    func testTheCommandsWords() {
        let feedID = UUID()
        func report(_ outcome: FeedRefreshReport.Outcome) -> FeedRefreshReport {
            FeedRefreshReport(feedID: feedID, feedTitle: "Atlas", origin: .listener, outcome: outcome)
        }
        XCTAssertEqual(FeedWording.checked(report(.updated(newItemIDs: ["a", "b"])), noun: .episode), "Atlas: 2 new episodes.")
        XCTAssertEqual(FeedWording.checked(report(.updated(newItemIDs: ["a"])), noun: .article), "Atlas: 1 new article.")
        XCTAssertEqual(FeedWording.checked(report(.unchanged), noun: .episode), "Atlas: no new episodes.")
        XCTAssertEqual(FeedWording.checked(report(.failed("The publisher has removed this feed.")), noun: .episode), "The publisher has removed this feed.")
        XCTAssertEqual(FeedWording.markedAll(count: 1, title: "Notes", noun: .article), "Marked 1 article of Notes read.")
        XCTAssertEqual(FeedWording.markedAll(count: 0, title: "Notes", noun: .article), "Every article of Notes is already read.")

        let stops = "TextMouth stops checking this feed and forgets the items it hasn't downloaded."
        XCTAssertEqual(FeedWording.unsubscribeMessage(bookTitles: [], folderPath: "Shows/Atlas"), "\(stops) Nothing it downloaded is left; its folder stays in Shows/Atlas.")
        XCTAssertEqual(FeedWording.unsubscribeMessage(bookTitles: [], folderPath: nil), "\(stops) Nothing it downloaded is left.")
        XCTAssertEqual(
            FeedWording.unsubscribeMessage(bookTitles: ["One", "Two"], folderPath: "Atlas"),
            "\(stops) These 2 books it downloaded stay in Atlas: “One” and “Two”."
        )
        XCTAssertEqual(
            FeedWording.unsubscribeMessage(bookTitles: ["One", "Two", "Three", "Four", "Five"], folderPath: "Atlas"),
            "\(stops) These 5 books it downloaded stay in Atlas: “One”, “Two”, “Three”, and 2 more."
        )
        XCTAssertEqual(FeedWording.unsubscribed(title: "Atlas", bookCount: 0), "Unsubscribed from Atlas.")
        XCTAssertEqual(FeedWording.unsubscribed(title: "Atlas", bookCount: 3), "Unsubscribed from Atlas. 3 books it downloaded stay in the library.")
    }

    // MARK: - The Sheets as Drawn

    /// Feed Info draws its two own settings, each a stepper and a number
    /// field labelled with the setting, a "Use the global setting" checkbox
    /// and an off checkbox, and the folder pop-up; while a setting follows
    /// the global one its stepper is unavailable.
    func testFeedInfoDrawsItsLabelledControls() async throws {
        let harness = try await Harness(self, label: "FeedUICommandsInfoDrawn")
        let model = FeedInfoModel(feedID: harness.feed.id, center: harness.world.center, library: harness.world.library)
        let sheet = FeedInfoSheet(
            model: model,
            feedFolders: LibraryFeedFolders(center: harness.world.center),
            unsubscribeConfirmation: { nil },
            onUnsubscribe: {},
            onDone: {}
        )

        withHostedView(sheet, size: NSSize(width: 560, height: 680), until: {
            self.descendants(of: $0, as: NSStepper.self).count == 2
        }) { hosting in
            let steppers = descendants(of: hosting, as: NSStepper.self)
            XCTAssertEqual(steppers.count, 2)
            XCTAssertTrue(steppers.allSatisfy { !$0.isEnabled }, "a stepper was available while following the global setting")
            XCTAssertEqual(feedCheckboxes(in: hosting).count, 4, "two Use the global setting and two off checkboxes")
            XCTAssertFalse(descendants(of: hosting, as: NSPopUpButton.self).isEmpty, "no folder pop-up")
            let controls = accessibleControls(in: hosting)
            if !controls.isEmpty {
                let labels = controls.map(\.label)
                XCTAssertTrue(labels.contains(FeedThresholdWording.keepEntries.label), "\(labels)")
                XCTAssertTrue(labels.contains(FeedThresholdWording.deleteDownloadsAfterPlaying.label), "\(labels)")
                XCTAssertTrue(labels.contains(FeedWording.folderInfoLabel), "\(labels)")
            }
        }
    }

    /// Feed Info's "Use the global setting" hint points to Settings, Feeds,
    /// as every other spoken pointer in the app names the window Settings.
    func testFeedInfosHintNamesTheSettingsWindow() {
        XCTAssertEqual(
            FeedWording.useGlobalHint,
            "When checked, this feed follows the setting in Settings, Feeds; uncheck it to give the feed its own"
        )
    }

    /// Show Description… draws the text in a text area that can be read
    /// and selected but not typed in, labelled with the item's title.
    func testTheDescriptionIsATextAreaToRead() throws {
        let item = FeedItem(
            id: "guid:x",
            title: "Night trams",
            summary: FeedTextConverter.read(html: "<p>Which routes still run after midnight.</p>"),
            firstSeen: Date()
        )
        let feed = Feed(feedURL: URL(fileURLWithPath: "/"), folderID: UUID(), subscribedDate: Date())
        let description = FeedItemDescription(item, of: feed)
        XCTAssertEqual(description.text, "Which routes still run after midnight.")

        withHostedView(FeedItemDescriptionSheet(description: description, onClose: {}), size: NSSize(width: 560, height: 480), until: {
            !self.descendants(of: $0, as: NSTextView.self).isEmpty
        }) { hosting in
            let textView = descendants(of: hosting, as: NSTextView.self).first { $0.string == description.text }
            XCTAssertNotNil(textView, "the description's text was not drawn")
            XCTAssertEqual(textView?.isEditable, false)
            XCTAssertEqual(textView?.isSelectable, true)
            XCTAssertEqual(textView?.accessibilityLabel(), FeedWording.descriptionTextLabel(title: "Night trams"))
        }
    }

    // MARK: - Harness

    /// A feed of two episodes, the first with a playable enclosure and a
    /// description, subscribed into a folder of its own, and a presenter
    /// whose announcements the test hears.
    @MainActor
    private final class Harness {
        /// The first episode's identity.
        static let episodeID = "guid:ep-1"
        /// The second episode's identity.
        static let secondID = "guid:ep-2"

        let world: FeedTestWorld
        let feed: Feed
        let presenter = LibraryFeedsPresenter()
        /// What VoiceOver was asked to say, in order.
        private(set) var heard: [String] = []

        /// The feed's items, as `world`'s server lists them.
        static func items(_ world: FeedTestWorld) -> [FeedXML.Item] {
            [
                FeedXML.Item(
                    guid: "ep-1",
                    title: "A map you can touch",
                    published: world.day(1),
                    enclosure: world.server.url("/audio/1.m4a").absoluteString,
                    enclosureType: "audio/mp4",
                    description: "<p>Raised lines and dots, read by hand.</p>",
                    link: "https://atlas.example/maps"
                ),
                // An episode too, though no test downloads it.
                FeedXML.Item(
                    guid: "ep-2",
                    title: "The first visit",
                    published: world.day(0.5),
                    enclosure: world.server.url("/audio/2.m4a").absoluteString,
                    enclosureType: "audio/mp4"
                ),
            ]
        }

        /// A harness for `test`; with `slowDownload`, the episode's file
        /// arrives slowly enough to be cancelled.
        init(_ test: XCTestCase, label: String, slowDownload: Bool = false) async throws {
            world = try FeedTestWorld(test, label: label)
            var file = FeedMediaFixtures.file(try FeedMediaFixtures.silentAAC(duration: 1), mimeType: "audio/mp4")
            if slowDownload {
                file.chunkSize = 64
                file.pause = 0.2
            }
            world.server.serve("/audio/1.m4a", file)
            world.server.serve("/feed.xml", .feed(FeedXML.rss(items: Self.items(world))))
            await world.start()
            let outcome = try await world.center.subscribe(
                to: world.server.url("/feed.xml").absoluteString,
                into: .newFolder(inParentPath: world.folder.path)
            )
            guard case .subscribed(let feed) = outcome else {
                throw NSError(domain: "FeedUICommandsTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(outcome)"])
            }
            self.feed = feed
            presenter.announce = { [weak self] message, _ in self?.heard.append(message) }
        }

        /// What the commands work with.
        var context: FeedCommandContext {
            FeedCommandContext(center: world.center, library: world.library, window: nil)
        }

        /// The feed's record now.
        var record: FeedRecord? {
            world.center.store.record(of: feed.id)
        }

        /// The first episode now.
        var item: FeedItem? {
            record?.item(Self.episodeID)
        }

        /// The command `command` for the item `itemID`, as its row offers it.
        func action(_ command: FeedItemCommand, item itemID: FeedItem.ID = episodeID) -> FeedItemAction {
            let item = record?.item(itemID)
            return FeedItemAction(
                command: command,
                feedID: feed.id,
                itemID: itemID,
                itemTitle: item?.title ?? "",
                isArticle: item?.isArticle ?? false,
                title: FeedWording.title(of: command, isArticle: item?.isArticle ?? false)
            )
        }
    }
}
