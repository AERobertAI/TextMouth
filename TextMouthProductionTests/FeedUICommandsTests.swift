import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// The feed reader's commands (FR03): what a feed and an item offer, by
/// where an item's download stands, and what each does through the engine,
/// against a stub server: Check Feed, Feed Info… with the feed's own
/// settings and folder, Mark All Played, Unsubscribe, which deletes nothing
/// here and so acts at once, saying the feed and its downloads stay (FR14),
/// Open, Download, Cancel Download, Delete Download (refused while the book
/// is open, in the engine's words), Mark Played and Unplayed, Show
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
        let book = UUID()

        XCTAssertEqual(titles(.notDownloaded), ["Open", "Download", "Mark Played", "Show Description…", "Delete Episode…"])
        XCTAssertEqual(titles(.downloading), ["Open", "Cancel Download", "Mark Played", "Show Description…", "Delete Episode…"])
        XCTAssertEqual(titles(.failed("gone"), played: true), ["Open", "Download", "Mark Unplayed", "Show Description…", "Delete Episode…"])
        XCTAssertEqual(
            titles(.downloaded(bookID: book)),
            ["Open", "Mark Played", "Show Description…", "Show in Finder", "Delete Download", "Delete Episode…"]
        )
        XCTAssertEqual(titles(.downloaded(bookID: book), onBookRow: true), ["Mark Played", "Show Description…", "Delete Download", "Delete Episode…"])
        XCTAssertEqual(titles(.notDownloaded, article: true), ["Open", "Download", "Mark Read", "Show Description…", "Delete Article…"])
        XCTAssertEqual(titles(.notDownloaded, played: true, article: true).dropFirst(2).first, "Mark Unread")
    }

    /// A subscribed feed offers Check Feed, Feed Info…, Mark All Played (Mark
    /// All Read for articles), Unsubscribe…, and Delete Feed… (FR14),
    /// always; an unsubscribed one's are `FeedSubscriptionShownTests`' (FR11,
    /// branch D).
    func testAFeedOffersItsCommands() {
        let feedID = UUID()
        XCTAssertEqual(
            FeedAction.actions(for: feedID, noun: .episode).map(\.title),
            ["Check Feed", "Feed Info…", "Mark All Played", "Unsubscribe…", "Delete Feed…"]
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
        // Listed in its feed's folder, by its feed link (FR11).
        let feedFolder = try XCTUnwrap(harness.world.library.feedFolderPath(forFolderID: harness.feed.folderID))
        XCTAssertEqual(book.feedLink?.feedID, harness.feed.id)
        XCTAssertEqual(
            harness.world.library.displayedBooks(at: LibraryLocation(category: .folders, folderPath: feedFolder)).map(\.id),
            [book.id]
        )
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
    /// the engine's words, naming the episode, shown in an alert, which
    /// VoiceOver reads as it appears, and never announced besides, which
    /// VoiceOver could read twice (REV14 feeds 6); the book stays.
    func testDeleteDownloadIsRefusedWhileTheBookIsOpen() async throws {
        let harness = try await Harness(self, label: "FeedUICommandsOpenBook")
        harness.presenter.perform(harness.action(.download), in: harness.context)
        let book = try await downloadedBook(harness.world, feed: harness.feed, item: Harness.episodeID)
        harness.world.library.openBookIDs.insert(book.id)

        harness.presenter.perform(harness.action(.deleteDownload), in: harness.context)

        let refusal = "“A map you can touch” is open in a reader. Close it, then try again."
        XCTAssertEqual(harness.presenter.notice?.title, FeedWording.deleteRefusedTitle)
        XCTAssertEqual(harness.presenter.notice?.message, refusal)
        XCTAssertFalse(harness.heard.contains(refusal), "the alert's words were announced too")
        XCTAssertNotNil(harness.world.library.bookByID(book.id), "an open book's download was deleted")
        harness.world.library.openBookIDs.remove(book.id)
    }

    /// Delete Download and Delete Episode… are refused while the episode is
    /// transcribed, whose transcript would be lost with its file (feed
    /// follow-ups item 1): the alert names it and says what to do, which
    /// VoiceOver reads as it appears, with nothing announced besides
    /// (REV14 feeds 6), and the episode, its file, and its row stay.
    func testDeleteDownloadAndDeleteEpisodeAreRefusedWhileTheEpisodeIsTranscribed() async throws {
        let harness = try await Harness(self, label: "FeedUICommandsTranscribing")
        harness.presenter.perform(harness.action(.download), in: harness.context)
        let book = try await downloadedBook(harness.world, feed: harness.feed, item: Harness.episodeID)
        let transcriptions = TranscribedBooks.shared
        let transcribingBefore = transcriptions.transcribingBookID
        addTeardownBlock { @MainActor in transcriptions.setTranscribing(transcribingBefore) }
        transcriptions.setTranscribing(book.id)
        let refusal = "“A map you can touch” is being transcribed, and deleting its download now would lose the transcript. "
            + "Wait until the transcription ends, or cancel it, then try again."

        harness.presenter.perform(harness.action(.deleteDownload), in: harness.context)

        XCTAssertEqual(harness.presenter.notice?.title, FeedWording.deleteRefusedTitle)
        XCTAssertEqual(harness.presenter.notice?.message, refusal)
        XCTAssertFalse(harness.heard.contains(refusal), "the alert's words were announced too")

        harness.presenter.notice = nil
        harness.presenter.perform(harness.action(.deleteItem), in: harness.context)
        harness.presenter.confirm(try XCTUnwrap(harness.presenter.confirmation), in: harness.context)

        XCTAssertEqual(harness.presenter.notice?.message, refusal)
        XCTAssertNotNil(harness.world.library.bookByID(book.id), "a download being transcribed was deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.bookFileURL.path))
        XCTAssertEqual(harness.item?.state, .downloaded(bookID: book.id))
        XCTAssertNil(harness.item?.deletedDate, "Delete Episode hid an episode being transcribed")
        transcriptions.setTranscribing(nil)
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
        // Said once the question's alert has closed, never as it closes
        // (REV13 item 1).
        XCTAssertNotEqual(harness.heard.last, "Deleted “A map you can touch”.", "said as the alert closed")
        await waitFor("the deletion is said") { harness.heard.last == "Deleted “A map you can touch”." }
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

    /// Unsubscribe, with nothing kept of removed downloads to delete, asks
    /// nothing (FR14): offered without an ellipsis, it stops checking at
    /// once, the feed and its download staying (FR11, branch D), and says so
    /// at once, there being no alert to wait for.
    func testUnsubscribeKeepsTheFeedAndItsDownload() async throws {
        let harness = try await Harness(self, label: "FeedUICommandsUnsubscribe")
        harness.presenter.perform(harness.action(.download), in: harness.context)
        let book = try await downloadedBook(harness.world, feed: harness.feed, item: Harness.episodeID)
        let unsubscribe = try XCTUnwrap(FeedAction.actions(for: harness.feed.id, in: harness.world.center).first { $0.command == .unsubscribe })
        XCTAssertEqual(unsubscribe.title, "Unsubscribe")
        XCTAssertNil(unsubscribe.role, "an Unsubscribe that deletes nothing was offered as destructive")

        harness.presenter.perform(unsubscribe, in: harness.context)

        XCTAssertNil(harness.presenter.confirmation, "an Unsubscribe that deletes nothing asked first")
        XCTAssertEqual(harness.world.center.feeds.map(\.id), [harness.feed.id])
        XCTAssertEqual(harness.record?.feed.isSubscribed, false)
        XCTAssertEqual(harness.world.library.bookByID(book.id)?.feedLink, book.feedLink, "unsubscribing took a download from its feed")
        XCTAssertEqual(
            harness.heard.last,
            "Unsubscribed from The Tactile Atlas: TextMouth no longer checks it for new episodes; its downloaded episode stays."
        )
    }

    /// Feed Info… opens the feed's sheet; its two settings follow the
    /// global ones until the listener gives the feed its own, and its
    /// folder can be changed for new downloads. Unchecking "Use the global
    /// setting" for List and download gives the feed the global choice as
    /// its own (FR11), a number out of range is moved into it, and checking
    /// the box again drops the feed's own.
    func testFeedInfoKeepsTheFeedsOwnSettings() async throws {
        let harness = try await Harness(self, label: "FeedUICommandsInfo")
        let info = try XCTUnwrap(FeedAction.actions(for: harness.feed.id, noun: .episode).first { $0.command == .feedInfo })

        harness.presenter.perform(info, in: harness.context)

        let model = try XCTUnwrap(harness.presenter.feedInfo)
        XCTAssertTrue(model.usesGlobalItemPolicy)
        XCTAssertEqual(model.itemPolicy, .standard)
        model.usesGlobalItemPolicy = false
        XCTAssertEqual(harness.record?.feed.itemPolicyOverride, .standard)
        XCTAssertFalse(model.usesGlobalItemPolicy)
        model.itemPolicy = FeedItemPolicy(choice: .onlyNewestListed, newestCount: 25)
        XCTAssertEqual(harness.record?.feed.itemPolicyOverride, FeedItemPolicy(choice: .onlyNewestListed, newestCount: 25))
        XCTAssertEqual(model.itemPolicy.listing, .newest(25))
        var tooMany = model.itemPolicy
        tooMany.newestCount = 9_000
        model.itemPolicy = tooMany
        XCTAssertEqual(harness.record?.feed.itemPolicyOverride?.newestCount, 2_000, "a number above the range was kept")
        model.usesGlobalItemPolicy = true
        XCTAssertNil(harness.record?.feed.itemPolicyOverride)
        XCTAssertEqual(model.itemPolicy, .standard)

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
        // One item marked: the words follow the item's kind, in both directions.
        XCTAssertEqual(FeedWording.marked(title: "Pilot", played: true, isArticle: false), "Marked “Pilot” played.")
        XCTAssertEqual(FeedWording.marked(title: "Pilot", played: false, isArticle: false), "Marked “Pilot” unplayed.")
        XCTAssertEqual(FeedWording.marked(title: "Memo", played: true, isArticle: true), "Marked “Memo” read.")
        XCTAssertEqual(FeedWording.marked(title: "Memo", played: false, isArticle: true), "Marked “Memo” unread.")

        // Unsubscribe's question and announcement say what happens now (FR11,
        // branch D): the feed stays, checking stops, and what it kept of
        // removed downloads goes, named by what those packages hold and
        // never "1 downloaded episode" (REV13 item 5).
        XCTAssertEqual(
            FeedWording.unsubscribeMessage(downloadCount: 0, keptCount: 0, keptParts: [], noun: .episode),
            "TextMouth stops checking this feed for new episodes. "
                + "The feed stays in your library with its settings, and Resubscribe checks it again."
        )
        XCTAssertEqual(
            FeedWording.unsubscribeMessage(downloadCount: 2, keptCount: 3, keptParts: [.place, .bookmarks], noun: .article),
            "TextMouth stops checking this feed for new articles. "
                + "The feed stays in your library with its settings and its 2 downloaded articles, and Resubscribe checks it again. "
                + "It also deletes the places and bookmarks kept for 3 removed downloads."
        )
        XCTAssertEqual(
            FeedWording.unsubscribeMessage(downloadCount: 1, keptCount: 1, keptParts: [.transcript], noun: .item),
            "TextMouth stops checking this feed for new items. "
                + "The feed stays in your library with its settings and its downloaded item, and Resubscribe checks it again. "
                + "It also deletes the transcript kept for 1 removed download."
        )
        XCTAssertEqual(
            FeedWording.unsubscribed(title: "Atlas", outcome: FeedUnsubscribeOutcome(downloadCount: 0, deletedKeptCount: 0), noun: .episode),
            "Unsubscribed from Atlas: TextMouth no longer checks it for new episodes."
        )
        XCTAssertEqual(
            FeedWording.unsubscribed(
                title: "Atlas",
                outcome: FeedUnsubscribeOutcome(downloadCount: 2, deletedKeptCount: 1),
                keptParts: [.place, .bookmarks],
                noun: .episode
            ),
            "Unsubscribed from Atlas: TextMouth no longer checks it for new episodes; its 2 downloaded episodes stay. "
                + "The place and bookmarks kept for 1 removed download were deleted."
        )
        XCTAssertEqual(
            FeedWording.unsubscribed(
                title: "Notes",
                outcome: FeedUnsubscribeOutcome(downloadCount: 1, deletedKeptCount: 1),
                keptParts: [.place],
                noun: .article
            ),
            "Unsubscribed from Notes: TextMouth no longer checks it for new articles; its downloaded article stays. "
                + "The place kept for 1 removed download was deleted."
        )
        XCTAssertEqual(
            FeedWording.unsubscribed(title: "Notes", outcome: FeedUnsubscribeOutcome(downloadCount: 0, deletedKeptCount: 4), noun: .article),
            "Unsubscribed from Notes: TextMouth no longer checks it for new articles. What was kept for 4 removed downloads was deleted."
        )
        XCTAssertEqual(FeedWording.unsubscribeTitle(asksFirst: true), "Unsubscribe…")
        XCTAssertEqual(FeedWording.unsubscribeTitle(asksFirst: false), "Unsubscribe")
    }

    /// Feed Info's folder line says what choosing another folder does since
    /// a feed's downloads stay in its own folder (FR11): the feed's items,
    /// those downloaded too, are listed in the new folder (REV11), where
    /// they once stayed behind.
    func testFeedInfoSaysTheDownloadsFollowItsFolder() {
        XCTAssertEqual(
            FeedWording.folderInfoHelp,
            "Choosing another folder lists the feed's episodes and articles there instead, those already downloaded too."
        )
    }

    // MARK: - The Sheets as Drawn

    /// Feed Info draws its two own settings, each with a "Use the global
    /// setting" checkbox: the List and download pop-up menu (FR11), its
    /// titles naming the feed's episodes, with its number, a stepper and a
    /// number field; and the days before deleting played downloads, with its
    /// off checkbox; and the folder pop-up. While a setting follows the
    /// global one its controls are unavailable; once the feed has its own,
    /// they are available, and VoiceOver hears the pop-up menu's choice in
    /// the feed's own words.
    func testFeedInfoDrawsItsLabelledControls() async throws {
        let harness = try await Harness(self, label: "FeedUICommandsInfoDrawn")
        let model = FeedInfoModel(feedID: harness.feed.id, center: harness.world.center, library: harness.world.library)
        let sheet = FeedInfoSheet(
            model: model,
            feedFolders: LibraryFeedFolders(center: harness.world.center),
            requestUnsubscribe: { nil },
            onUnsubscribe: { _ in },
            onDone: {}
        )

        withHostedView(sheet, size: NSSize(width: 560, height: 760), until: {
            self.descendants(of: $0, as: NSStepper.self).count == 2
        }) { hosting in
            let steppers = descendants(of: hosting, as: NSStepper.self)
            XCTAssertEqual(steppers.count, 2)
            XCTAssertTrue(steppers.allSatisfy { !$0.isEnabled }, "a stepper was available while following the global setting")
            XCTAssertEqual(feedCheckboxes(in: hosting).count, 5, "two Use the global setting checkboxes, an off checkbox, and the Skip finished and Download the next checkboxes")
            let popUps = descendants(of: hosting, as: NSPopUpButton.self)
            XCTAssertEqual(popUps.count, 3, "the List and download, folder, and When an episode ends pop-ups")
            let listAndDownload = popUps.first { $0.itemTitles.contains("Every episode listed, downloads by hand") }
            XCTAssertNotNil(listAndDownload, "no List and download pop-up in the feed's words: \(popUps.map(\.itemTitles))")
            XCTAssertEqual(listAndDownload?.isEnabled, false, "the pop-up was available while following the global setting")
            XCTAssertEqual(listAndDownload?.titleOfSelectedItem, "Every episode listed, newest 5 downloaded")
            let controls = accessibleControls(in: hosting)
            if !controls.isEmpty {
                let labels = controls.map(\.label)
                XCTAssertTrue(labels.contains(FeedWording.listAndDownloadLabel), "\(labels)")
                XCTAssertTrue(labels.contains(FeedWording.newestCountLabel), "\(labels)")
                XCTAssertTrue(labels.contains(FeedThresholdWording.deleteDownloadsAfterPlaying.label), "\(labels)")
                XCTAssertTrue(labels.contains(FeedWording.folderInfoLabel), "\(labels)")
                let number = controls.first { $0.role == .incrementor && $0.label == FeedWording.newestCountLabel }
                XCTAssertEqual(number?.valueDescription, "5 episodes")
            }

            // The feed's own choice: its controls are available.
            model.usesGlobalItemPolicy = false
            XCTAssertTrue(
                waitUntil {
                    hosting.layoutSubtreeIfNeeded()
                    return self.descendants(of: hosting, as: NSPopUpButton.self).contains {
                        $0.isEnabled && $0.itemTitles.contains("Every episode listed, downloads by hand")
                    }
                },
                "the pop-up stayed unavailable once the feed had its own choice"
            )
            XCTAssertTrue(
                waitUntil { self.descendants(of: hosting, as: NSStepper.self).filter(\.isEnabled).count == 1 },
                "the number stayed unavailable once the feed had its own choice"
            )
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

    /// The words of a description: the heading Feed Info shows, and the
    /// label of a text area, which names whose description it is.
    func testTheDescriptionsWords() {
        XCTAssertEqual(FeedWording.descriptionLabel, "Description")
        XCTAssertEqual(FeedWording.descriptionTextLabel(title: "The Tactile Atlas"), "Description of The Tactile Atlas")
        XCTAssertEqual(FeedWording.descriptionTextLabel(title: "Night trams"), "Description of Night trams")
    }

    /// Feed Info draws the feed's description, under its Description
    /// heading, in a text area labelled with the feed's title, so VoiceOver
    /// says the heading's word once and then whose description the text
    /// is; until October 6, 2026 the text area was labelled Description
    /// too, and VoiceOver said the word twice.
    func testFeedInfosDescriptionIsLabelledWithTheFeedsTitle() async throws {
        let harness = try await Harness(self, label: "FeedUICommandsInfoDescription")
        let summary = try XCTUnwrap(harness.record?.feed.summary?.plainText, "the feed has no description to draw")
        XCTAssertEqual(summary, "A show for tests.")
        let model = FeedInfoModel(feedID: harness.feed.id, center: harness.world.center, library: harness.world.library)
        let sheet = FeedInfoSheet(
            model: model,
            feedFolders: LibraryFeedFolders(center: harness.world.center),
            requestUnsubscribe: { nil },
            onUnsubscribe: { _ in },
            onDone: {}
        )

        withHostedView(sheet, size: NSSize(width: 560, height: 680), until: {
            self.descendants(of: $0, as: NSTextView.self).contains { $0.string == summary }
        }) { hosting in
            let textViews = descendants(of: hosting, as: NSTextView.self)
            let description = textViews.first { $0.string == summary }
            XCTAssertNotNil(description, "the description was not drawn as a text area")
            XCTAssertEqual(description?.accessibilityLabel(), "Description of The Tactile Atlas")
            XCTAssertFalse(
                textViews.contains { $0.accessibilityLabel() == FeedWording.descriptionLabel },
                "a text area is labelled with the heading's word alone"
            )
        }
    }

    /// Feed Info itself, with its folder picker's New Folder fields shown:
    /// Escape closes the fields and never Feed Info, its Done giving Escape
    /// up meanwhile, so the fields' Cancel New Folder alone takes it, as in
    /// the Move sheet; once they are closed, a second Escape presses Done
    /// (REV13 app 5, until then tested only through a stand-in sheet).
    func testEscapeClosesFeedInfosNewFolderFieldsBeforeFeedInfo() async throws {
        let harness = try await Harness(self, label: "FeedUICommandsInfoEscape")
        let model = FeedInfoModel(feedID: harness.feed.id, center: harness.world.center, library: harness.world.library)
        var dones = 0
        let sheet = FeedInfoSheet(
            model: model,
            feedFolders: LibraryFeedFolders(center: harness.world.center),
            requestUnsubscribe: { nil },
            onUnsubscribe: { _ in },
            onDone: { dones += 1 },
            makingFolder: true
        )

        try withHostedView(sheet, size: NSSize(width: 560, height: 680), until: {
            !self.newFolderNameFields(in: $0).isEmpty
        }) { hosting in
            try typeNewFolderName("Charts", in: hosting)
            guard pressKey(.escape, in: hosting) else {
                throw XCTSkip("This macOS hands an offscreen window no key equivalents")
            }
            XCTAssertTrue(waitUntil {
                hosting.layoutSubtreeIfNeeded()
                return self.newFolderNameFields(in: hosting).isEmpty
            }, "Escape left the New Folder fields open")
            XCTAssertEqual(dones, 0, "Done took Escape while the New Folder fields were shown")

            settleHostedView(hosting)
            XCTAssertTrue(pressKey(.escape, in: hosting), "nothing took the second Escape")
            XCTAssertEqual(dones, 1, "the second Escape did not press Done")
        }
    }

    /// Feed Info has no Return-key button of its own: Escape presses Done,
    /// and Return stays with the number fields, entering the number typed,
    /// so while the folder picker's New Folder fields are shown their
    /// Create is the one button Return presses, as in the Move sheet.
    func testReturnStaysWithTheNumberFieldsAndEscapePressesDone() async throws {
        let harness = try await Harness(self, label: "FeedUICommandsInfoReturn")
        let model = FeedInfoModel(feedID: harness.feed.id, center: harness.world.center, library: harness.world.library)
        // The feed has its own List and download choice, so its number
        // takes typing; the days still follow the global setting.
        model.usesGlobalItemPolicy = false
        var dones = 0
        let sheet = FeedInfoSheet(
            model: model,
            feedFolders: LibraryFeedFolders(center: harness.world.center),
            requestUnsubscribe: { nil },
            onUnsubscribe: { _ in },
            onDone: { dones += 1 }
        )

        try withHostedView(sheet, size: NSSize(width: 560, height: 680), until: {
            self.editableTextFields(in: $0).contains(where: \.isEnabled)
        }) { hosting in
            guard pressKeyEquivalent(.escape, in: hosting) else {
                throw XCTSkip("This macOS hands an offscreen window no key equivalents")
            }
            XCTAssertEqual(dones, 1, "Escape did not press Done")

            let fields = editableTextFields(in: hosting).filter(\.isEnabled)
            XCTAssertEqual(fields.count, 1, "fields taking typing: \(fields.map { $0.accessibilityLabel() ?? "" })")
            let field = try XCTUnwrap(fields.first)
            try typeReplacingText("25", in: field, of: hosting)

            XCTAssertFalse(pressReturnKey(in: hosting), "a button took Return from the number field")
            settleHostedView(hosting)
            XCTAssertEqual(model.itemPolicy.newestCount, 25, "Return did not enter the number typed")
            XCTAssertEqual(harness.record?.feed.itemPolicyOverride, FeedItemPolicy(choice: .everyListedNewestDownloaded, newestCount: 25))
            XCTAssertEqual(dones, 1, "Return pressed Done")
        }
    }

    /// Return presses Show Description's Close, as Escape does, from the
    /// text area the sheet starts in, each a key equivalent the window
    /// offers its views before the text area sees the key; until October 6,
    /// 2026 only Escape closed it, though the sheet's description promised
    /// both. The key Close's shortcut does not take is caught by a view
    /// that takes no space and is no element to VoiceOver.
    func testReturnAndEscapeCloseTheDescription() throws {
        let item = FeedItem(
            id: "guid:y",
            title: "Harbour lights",
            summary: FeedTextConverter.read(html: "<p>Which lamps are lit, and when.</p>"),
            firstSeen: Date()
        )
        let feed = Feed(feedURL: URL(fileURLWithPath: "/"), folderID: UUID(), subscribedDate: Date())
        let description = FeedItemDescription(item, of: feed)
        var closes = 0
        let sheet = FeedItemDescriptionSheet(description: description, onClose: { closes += 1 })

        try withHostedView(sheet, size: NSSize(width: 560, height: 480), until: {
            self.descendants(of: $0, as: NSTextView.self).contains { $0.string == description.text }
        }) { hosting in
            let window = try XCTUnwrap(hosting.window)
            let textView = try XCTUnwrap(descendants(of: hosting, as: NSTextView.self).first { $0.string == description.text })
            // The text area takes focus as the sheet appears; where the
            // hosted window is slow to give it, the test gives it, since
            // what is tested is the keys pressed from the text area.
            if !waitUntil(timeout: 2, { window.firstResponder === textView }) {
                window.makeFirstResponder(textView)
            }
            XCTAssertTrue(window.firstResponder === textView, "the text area has no focus")

            guard pressKeyEquivalent(.return, in: hosting) else {
                throw XCTSkip("This macOS hands an offscreen window no key equivalents")
            }
            XCTAssertTrue(waitUntil { closes == 1 }, "Return did not press Close")

            XCTAssertTrue(pressKeyEquivalent(.escape, in: hosting), "nothing took Escape")
            XCTAssertTrue(waitUntil { closes == 2 }, "Escape did not close the sheet from the text area")

            let catcher = try XCTUnwrap(descendants(of: hosting, as: SilentKeyEquivalentView.self).first)
            XCTAssertEqual(catcher.frame.size, .zero, "the key's view takes space")
            XCTAssertFalse(catcher.isAccessibilityElement(), "the key's view is an element to VoiceOver")
        }
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
