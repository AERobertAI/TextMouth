import XCTest
@testable import TextMouth

/// Delete Feed… as the listener meets it (FR14): last among a feed's
/// commands, in its menus, its VoiceOver actions, and Feed Info; a question
/// first, saying what goes and pointing to Move to Library…; once
/// confirmed, the feed deleted, Feed Info closed, and VoiceOver told only
/// once the question's alert has closed (REV13 item 1); a refusal said in
/// an alert. Feed Info's subscription button is one button whose title,
/// role, and hint follow the feed's state (REV13 item 2). Against a stub
/// server; nothing is played, and nothing goes to the Trash.
@MainActor
final class FeedUIDeleteFeedTests: XCTestCase {

    // MARK: - The Words

    /// The question names the feed and says what goes, to the Trash or for
    /// good as the removal setting says, naming only what the kept packages
    /// hold; the folder goes when nothing else is in it; and a feed with
    /// downloads points to Move to Library… for one to keep.
    func testTheQuestionSaysWhatGoes() {
        XCTAssertEqual(FeedWording.deleteFeedQuestion(title: "Finish It!"), "Delete the feed “Finish It!”?")
        XCTAssertEqual(FeedWording.deleteFeedButton, "Delete Feed")
        XCTAssertEqual(FeedWording.deleteFeedTitle, "Delete Feed…")
        XCTAssertEqual(
            FeedWording.deleteFeedMessage(
                downloads: 5,
                kept: 3,
                keptParts: [.place, .bookmarks],
                noun: .episode,
                folderPath: "Podcasts/Finish It!",
                mode: .moveToTrash
            ),
            "The feed leaves your library, with its list of episodes and its settings. It deletes its 5 downloaded episodes "
                + "and the places and bookmarks kept for 3 removed downloads: they go to the Trash, where you can recover them "
                + "until the Trash is emptied. Its folder “Podcasts/Finish It!” goes too when nothing else is in it. "
                + "To keep an episode, choose Move to Library… on its row first."
        )
        XCTAssertEqual(
            FeedWording.deleteFeedMessage(downloads: 1, kept: 0, keptParts: [], noun: .article, folderPath: "Notes", mode: .deletePermanently),
            "The feed leaves your library, with its list of articles and its settings. It deletes its downloaded article: "
                + "it is deleted permanently and cannot be recovered. Its folder “Notes” goes too when nothing else is in it. "
                + "To keep an article, choose Move to Library… on its row first."
        )
        XCTAssertEqual(
            FeedWording.deleteFeedMessage(downloads: 0, kept: 1, keptParts: [.transcript], noun: .item, folderPath: nil, mode: .moveToTrash),
            "The feed leaves your library, with its list of items and its settings. It deletes the transcript kept for "
                + "1 removed download: it goes to the Trash, where you can recover it until the Trash is emptied."
        )
        XCTAssertEqual(
            FeedWording.deleteFeedMessage(downloads: 0, kept: 0, keptParts: [], noun: .episode, folderPath: "", mode: .moveToTrash),
            "The feed leaves your library, with its list of episodes and its settings."
        )
    }

    /// What VoiceOver hears once a feed is deleted names what went and what
    /// became of its folder; one download is never "1 downloaded episode".
    func testWhatIsSaidOnceAFeedIsDeleted() {
        let all = FeedDeleteOutcome(title: "Finish It!", deletedDownloads: 5, deletedKeptPlaces: 3, folder: .deleted(path: "Podcasts/Finish It!"))
        XCTAssertEqual(
            FeedWording.deletedFeed(all, noun: .episode),
            "Deleted the feed “Finish It!”, its 5 downloaded episodes, and what it kept for 3 removed downloads. "
                + "Its folder “Podcasts/Finish It!” is gone too."
        )
        let one = FeedDeleteOutcome(title: "Corkboard", deletedDownloads: 1, deletedKeptPlaces: 0, folder: .stays(path: "Notes"))
        XCTAssertEqual(
            FeedWording.deletedFeed(one, noun: .article),
            "Deleted the feed “Corkboard” and its downloaded article. Its folder “Notes” stays, as something else is in it."
        )
        let bare = FeedDeleteOutcome(title: "Atlas", deletedDownloads: 0, deletedKeptPlaces: 0, folder: .none)
        XCTAssertEqual(FeedWording.deletedFeed(bare, noun: .episode), "Deleted the feed “Atlas”.")
        let stuck = FeedDeleteOutcome(title: "Atlas", deletedDownloads: 0, deletedKeptPlaces: 1, folder: .notDeleted(path: "Atlas"))
        XCTAssertEqual(
            FeedWording.deletedFeed(stuck, noun: .episode),
            "Deleted the feed “Atlas” and what it kept for 1 removed download. Its folder “Atlas” is empty, but could not be deleted."
        )
    }

    /// Why Delete Feed… left a feed is said in the removal setting's words,
    /// naming what stayed.
    func testWhyAFeedStays() {
        XCTAssertEqual(
            FeedWording.deleteFeedRefused(.downloadIsOpen(title: "Ep. 368"), title: "Finish It!", mode: .moveToTrash),
            "“Ep. 368” is open in a reader. Close it, then choose Delete Feed… again."
        )
        XCTAssertEqual(
            FeedWording.deleteFeedRefused(.indexNotWritten, title: "Finish It!", mode: .moveToTrash),
            "TextMouth couldn't save the library before deleting the feed “Finish It!”, so nothing was deleted."
        )
        XCTAssertEqual(
            FeedWording.deleteFeedRefused(.filesStayed(["Ep. 368: No permission."]), title: "Finish It!", mode: .moveToTrash),
            "This item could not be moved to the Trash and remains in the library:\nEp. 368: No permission.\n"
                + "The feed “Finish It!” stays with it."
        )
    }

    /// A removal's outcome agrees with one thing or several, and the files
    /// clause built on it reads as it always did.
    func testTheRemovalOutcomeAgreesWithItsSubject() {
        XCTAssertEqual(RemovalMode.moveToTrash.outcomePhrase(plural: false), "goes to the Trash, where you can recover it until the Trash is emptied")
        XCTAssertEqual(RemovalMode.deletePermanently.outcomePhrase(plural: true), "are deleted permanently and cannot be recovered")
        XCTAssertEqual(RemovalMode.keepFiles.outcomePhrase(plural: false), "stays in the TextMouth library folder")
        XCTAssertEqual(
            RemovalMode.moveToTrash.filesClause(of: "its"),
            "its files go to the Trash, where you can recover them until the Trash is emptied"
        )
        XCTAssertEqual(RemovalMode.deletePermanently.filesClause(of: "their"), "their files are deleted permanently and cannot be recovered")
        XCTAssertEqual(RemovalMode.keepFiles.filesClause(of: "its"), "its files stay in the TextMouth library folder")
    }

    /// What a feed kept is named by what its packages hold, for one or
    /// several, or as what was kept when they hold none of the parts named;
    /// one download is "downloaded episode", never "1 downloaded episode".
    func testWhatAFeedKeptIsNamedByWhatItHolds() {
        XCTAssertEqual(FeedWording.keptPhrase(count: 1, parts: [.place, .bookmarks]), "the place and bookmarks kept for 1 removed download")
        XCTAssertEqual(
            FeedWording.keptPhrase(count: 3, parts: [.place, .settings, .transcript]),
            "the places, own settings, and transcripts kept for 3 removed downloads"
        )
        XCTAssertEqual(FeedWording.keptPhrase(count: 2, parts: []), "what was kept for 2 removed downloads")
        XCTAssertEqual(FeedWording.downloadsPhrase(1, .episode), "downloaded episode")
        XCTAssertEqual(FeedWording.downloadsPhrase(2, .item), "2 downloaded items")
        XCTAssertEqual(FeedWording.KeptParts([.place, .bookmarks]).sentenceSubject, "Its place and bookmarks are", "Delete Download's words changed")
    }

    // MARK: - Feed Info's Buttons

    /// Feed Info's subscription button is Unsubscribe…, destructive, for a
    /// subscribed feed, and Resubscribe for an unsubscribed one, each with
    /// its hint: one button whose words follow the state (REV13 item 2).
    /// Delete Feed… beside it has a hint of its own.
    func testFeedInfosSubscriptionButtonFollowsTheFeedsState() {
        let subscribed = FeedSubscriptionToggle(isSubscribed: true)
        XCTAssertEqual(subscribed.title, "Unsubscribe…")
        XCTAssertTrue(subscribed.isDestructive)
        XCTAssertEqual(subscribed.hint, FeedWording.unsubscribeHint)
        let unsubscribed = FeedSubscriptionToggle(isSubscribed: false)
        XCTAssertEqual(unsubscribed.title, "Resubscribe")
        XCTAssertFalse(unsubscribed.isDestructive)
        XCTAssertEqual(unsubscribed.hint, FeedWording.resubscribeHint)
        XCTAssertEqual(
            FeedWording.deleteFeedHint,
            "Asks first, then deletes this feed, its downloads, and what it kept of downloads you removed"
        )
    }

    // MARK: - The Command

    /// Delete Feed… asks first, in the words above, counting what goes;
    /// confirmed, the feed is deleted and VoiceOver hears so, not as the
    /// alert closes, but once it has (REV13 item 1).
    func testDeleteFeedAsksFirstThenSaysWhatWentOnceTheAlertHasClosed() async throws {
        let harness = try await Harness(self, label: "FeedUIDeleteFeed")
        let action = try XCTUnwrap(FeedAction.actions(for: harness.feed.id, in: harness.world.center).last)
        XCTAssertEqual(action.command, .deleteFeed)
        XCTAssertEqual(action.role, .destructive)

        harness.presenter.perform(action, in: harness.context)

        let question = try XCTUnwrap(harness.presenter.confirmation)
        let folderPath = try XCTUnwrap(harness.world.library.feedFolderPath(forFolderID: harness.feed.folderID))
        XCTAssertEqual(question.kind, .deleteFeed(feedID: harness.feed.id))
        XCTAssertEqual(question.title, "Delete the feed “The Tactile Atlas”?")
        XCTAssertEqual(question.confirmTitle, "Delete Feed")
        XCTAssertEqual(question.message, FeedWording.deleteFeedMessage(
            downloads: 1,
            kept: 0,
            keptParts: [],
            noun: .episode,
            folderPath: folderPath,
            mode: harness.world.library.removalPreferences.deletionMode
        ))
        XCTAssertNotNil(harness.world.center.store.record(of: harness.feed.id), "deleted before it was confirmed")

        harness.presenter.confirm(question, in: harness.context)
        await waitFor("the feed is deleted") { harness.world.center.store.record(of: harness.feed.id) == nil }

        let said = "Deleted the feed “The Tactile Atlas” and its downloaded episode. Its folder “\(folderPath)” is gone too."
        XCTAssertNotEqual(harness.heard.last, said, "said as the alert closed")
        await waitFor("the deletion is said") { harness.heard.last == said }
        XCTAssertEqual(harness.world.library.everyRow(ofFeed: harness.feed.id), [])
    }

    /// Delete Feed… from Feed Info closes Feed Info, and the feed goes.
    func testDeleteFeedFromFeedInfoClosesIt() async throws {
        let harness = try await Harness(self, label: "FeedUIDeleteFeedInfo")
        let info = try XCTUnwrap(FeedAction.actions(for: harness.feed.id, in: harness.world.center).first { $0.command == .feedInfo })
        harness.presenter.perform(info, in: harness.context)
        XCTAssertNotNil(harness.presenter.feedInfo)
        let question = try XCTUnwrap(harness.presenter.deleteFeedConfirmation(for: harness.feed.id, in: harness.context))
        XCTAssertEqual(question.kind, .deleteFeed(feedID: harness.feed.id))

        let deletion = harness.presenter.deleteFeed(harness.feed.id, in: harness.context)

        XCTAssertNil(harness.presenter.feedInfo, "Feed Info stayed open on a deleted feed")
        await deletion?.value
        XCTAssertNil(harness.world.center.store.record(of: harness.feed.id))
        XCTAssertNil(harness.presenter.deleteFeedConfirmation(for: harness.feed.id, in: harness.context), "a deleted feed was asked about")
    }

    /// A Delete Feed… refused, as while a download is open in a reader, says
    /// why in an alert, which VoiceOver hears, and the feed stays.
    func testARefusedDeleteFeedSaysWhyInAnAlert() async throws {
        let harness = try await Harness(self, label: "FeedUIDeleteFeedRefused")
        harness.world.library.openBookIDs.insert(harness.book.id)
        defer { harness.world.library.openBookIDs.remove(harness.book.id) }

        await harness.presenter.deleteFeed(harness.feed.id, in: harness.context)?.value

        let refusal = "“Episode 1” is open in a reader. Close it, then choose Delete Feed… again."
        XCTAssertEqual(harness.presenter.notice?.title, FeedWording.deleteRefusedTitle)
        XCTAssertEqual(harness.presenter.notice?.message, refusal)
        XCTAssertEqual(harness.heard.last, refusal)
        XCTAssertNotNil(harness.world.center.store.record(of: harness.feed.id))
    }

    // MARK: - Harness

    /// A feed of two episodes, the first downloaded, in a folder of its own
    /// inside the world's folder, and a presenter whose announcements the
    /// test hears.
    @MainActor
    private final class Harness {
        let world: FeedTestWorld
        let feed: Feed
        /// The first episode's download.
        let book: Book
        let presenter = LibraryFeedsPresenter()
        /// What VoiceOver was asked to say, in order.
        private(set) var heard: [String] = []

        /// A harness for `test`.
        init(_ test: XCTestCase, label: String) async throws {
            world = try FeedTestWorld(test, label: label)
            let (feed, books) = try await test.feedWithDownloads(
                episodes: 2,
                downloading: 1,
                in: world,
                into: .newFolder(inParentPath: world.folder.path)
            )
            self.feed = feed
            book = try XCTUnwrap(books.first)
            presenter.announce = { [weak self] message, _ in self?.heard.append(message) }
        }

        /// What the commands work with.
        var context: FeedCommandContext {
            FeedCommandContext(center: world.center, library: world.library, window: nil)
        }
    }
}
