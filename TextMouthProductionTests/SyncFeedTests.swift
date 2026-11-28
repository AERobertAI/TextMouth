import XCTest
@testable import TextMouth

/// Feeds in the sync (FR56, phase 1): a subscription's keys, what changes
/// and what doesn't, a feed made from another device's entries, the same
/// feed subscribed on two devices, removals, folders, the launch, and an
/// older TextMouth's reading. Pure: no file, no network, no iCloud.
final class SyncFeedTests: XCTestCase {
    private typealias Fixtures = SyncTestFixtures

    /// A feed of `address` listing in folder `folderID`, subscribed at `subscribed` seconds.
    private func feed(
        id: UUID = UUID(), address: String = "https://example.com/show.xml", folderID: UUID, subscribed: TimeInterval = 1_000
    ) -> Feed {
        Feed(
            id: id, feedURL: URL(string: address) ?? URL(fileURLWithPath: "/"), folderID: folderID,
            subscribedDate: Date(timeIntervalSince1970: subscribed)
        )
    }

    /// The entries another device records for `feed`, every field stamped at `wall`.
    private func entries(of feed: Feed, wall: Int64, device: String = "b") -> [SyncEntry] {
        SyncFeedField.allCases.map { field in
            Fixtures.entry(.feed(feed.id, field), SyncFeedValues.value(of: field, in: feed), wall: wall, device: device)
        }
    }

    /// The merge of `entries` into `library` with `feeds` as this device's.
    private func apply(_ entries: [SyncEntry], to library: Library, feeds: [Feed]?) -> SyncApplication {
        SyncMerge.apply(Fixtures.registers(entries), to: library, feeds: feeds, voices: nil)
    }

    // MARK: Keys

    /// A feed's key reads back from its text, and a field this TextMouth doesn't know names no key.
    func testFeedKeyTextRoundTrips() {
        let id = Fixtures.id(7)
        for field in SyncFeedField.allCases {
            let key = SyncKey.feed(id, field)
            XCTAssertEqual(key.text, "feed/00000000-0000-0000-0000-000000000007/\(field.rawValue)")
            XCTAssertEqual(SyncKey(text: key.text), key)
        }
        XCTAssertNil(SyncKey(text: "feed/00000000-0000-0000-0000-000000000007/someLaterField"))
        XCTAssertNil(SyncKey(text: "feed/not-an-id/presence"))
        XCTAssertEqual(SyncKey.feed(id, .presence).feedID, id)
        XCTAssertNil(SyncKey.feed(id, .presence).bookID)
    }

    /// A change file holding a feed field a later TextMouth added reads, leaving that entry out.
    func testLaterFeedFieldIsLeftOutOfAChangeFile() throws {
        let folder = BookFolder(name: "Show")
        let known = try XCTUnwrap(entries(of: feed(folderID: folder.id), wall: 5).first)
        var file = SyncChangeFile(
            formatVersion: 1, deviceID: "b", incarnation: Fixtures.id(1), seq: 1, kind: .changes, count: 2, entries: [known]
        )
        var raw = SyncValueCoding.json(file)
        guard case .object(var members) = raw, case .array(var items)? = members["entries"], case .object(var later)? = items.first else {
            return XCTFail("The change file did not encode as an object")
        }
        later["key"] = .string("feed/00000000-0000-0000-0000-000000000009/someLaterField")
        items.append(.object(later))
        members["entries"] = .array(items)
        raw = .object(members)
        let data = try SyncFormats.encode(raw)
        file = try SyncFormats.decodeChangeFile(data, named: "000000000001.changes.json")
        XCTAssertEqual(file.entries, [known])
        XCTAssertEqual(file.count, 2)
    }

    // MARK: The projection

    /// A feed projects every field, a person's settings among them, and nothing a refresh reads.
    func testProjectionHoldsTheFeedsFields() {
        let folder = BookFolder(name: "Show")
        var show = feed(folderID: folder.id)
        show.itemPolicyOverride = FeedItemPolicy(choice: .onlyNewestListed, newestCount: 3)
        show.deleteDownloadsDaysAfterPlayedOverride = 4
        show.listeningOptions = ListeningOptions(skipsFinished: false)
        let projection = SyncProjection.of(Fixtures.library(folders: [folder]), contents: [:], feeds: [show])
        XCTAssertEqual(projection.values[.feed(show.id, .presence)], .bool(true))
        XCTAssertEqual(projection.values[.feed(show.id, .address)], .string("https://example.com/show.xml"))
        XCTAssertEqual(projection.values[.feed(show.id, .folder)], SyncValueCoding.id(folder.id))
        XCTAssertEqual(projection.values[.feed(show.id, .unsubscribed)], .null)
        XCTAssertEqual(projection.values[.feed(show.id, .deleteAfterPlayed)], .integer(4))
        XCTAssertEqual(
            SyncValueCoding.decode(SyncFeedItemPolicyValue.self, from: projection.values[.feed(show.id, .itemPolicy)] ?? .null)?.policy,
            show.itemPolicyOverride
        )
        XCTAssertEqual(projection.values.keys.filter { $0.feedID == show.id }.count, SyncFeedField.allCases.count)
        XCTAssertFalse(projection.leavesFeedsAlone)
    }

    /// Standard listening options project as none, as the record stores none.
    func testStandardListeningOptionsProjectAsNone() {
        let folder = BookFolder(name: "Show")
        var show = feed(folderID: folder.id)
        show.listeningOptions = .standard
        let projection = SyncProjection.of(Fixtures.library(folders: [folder]), contents: [:], feeds: [show])
        XCTAssertEqual(projection.values[.feed(show.id, .listening)], .null)
    }

    /// A projection made without the feeds holds no feed key and says so.
    func testProjectionWithoutFeedsLeavesThemAlone() {
        let projection = SyncProjection.of(Fixtures.library(), contents: [:])
        XCTAssertTrue(projection.leavesFeedsAlone)
        XCTAssertFalse(projection.values.keys.contains { $0.feedID != nil })
    }

    // MARK: What changed

    /// The baseline of `feeds` in `library`, as a device that recorded them holds it.
    private func baseline(of library: Library, feeds: [Feed]) -> SyncProjection {
        var baseline = SyncProjection()
        let now = SyncProjection.of(library, contents: [:], feeds: feeds)
        baseline.absorb(now.values.map { Fixtures.entry($0.key, $0.value, wall: 1) })
        return baseline
    }

    /// A refresh that changes the feed's own title, size, and newest date changes no key.
    func testRefreshAloneChangesNothing() {
        let folder = BookFolder(name: "Show")
        let library = Fixtures.library(folders: [folder])
        var show = feed(folderID: folder.id)
        let known = baseline(of: library, feeds: [show])
        show.title = "The Show, renamed by its publisher"
        show.entryTotal = FeedEntryTotal(count: 381)
        show.newestItemDate = Date(timeIntervalSince1970: 50_000)
        show.isSerial = true
        let now = SyncProjection.of(library, contents: [:], feeds: [show])
        XCTAssertTrue(SyncMerge.changes(from: known, to: now, atLaunch: false).isEmpty)
    }

    /// A setting a person changed is the one change.
    func testSettingChangeIsRecorded() {
        let folder = BookFolder(name: "Show")
        let library = Fixtures.library(folders: [folder])
        var show = feed(folderID: folder.id)
        let known = baseline(of: library, feeds: [show])
        show.unsubscribedDate = Date(timeIntervalSince1970: 9_000)
        let changes = SyncMerge.changes(from: known, to: SyncProjection.of(library, contents: [:], feeds: [show]), atLaunch: false)
        XCTAssertEqual(Array(changes.keys), [.feed(show.id, .unsubscribed)])
    }

    /// Without the feeds, nothing about them is reported; with none, each is reported removed once.
    func testFeedsNotLoadedReportNoRemoval() {
        let folder = BookFolder(name: "Show")
        let library = Fixtures.library(folders: [folder])
        let show = feed(folderID: folder.id)
        let known = baseline(of: library, feeds: [show])
        XCTAssertTrue(SyncMerge.changes(from: known, to: SyncProjection.of(library, contents: [:]), atLaunch: false).isEmpty)
        let gone = SyncMerge.changes(from: known, to: SyncProjection.of(library, contents: [:], feeds: []), atLaunch: false)
        XCTAssertEqual(gone, [.feed(show.id, .presence): .null])
        XCTAssertTrue(SyncMerge.changes(from: known, to: SyncProjection.of(library, contents: [:], feeds: []), atLaunch: true).isEmpty)
    }

    /// A listening option a later TextMouth added is no change here, so no copy without it is recorded (V04).
    func testLaterListeningFieldIsNoChange() {
        let folder = BookFolder(name: "Show")
        let library = Fixtures.library(folders: [folder])
        var show = feed(folderID: folder.id)
        show.listeningOptions = ListeningOptions(skipsFinished: false)
        guard case .object(var members) = SyncFeedValues.value(of: .listening, in: show) else { return XCTFail("No options") }
        members["someLaterOption"] = .bool(true)
        var known = SyncProjection()
        known.absorb(SyncProjection.of(library, contents: [:], feeds: [show]).values.map { Fixtures.entry($0.key, $0.value, wall: 1) })
        known.absorb([Fixtures.entry(.feed(show.id, .listening), .object(members), wall: 2)])
        XCTAssertTrue(SyncMerge.changes(from: known, to: SyncProjection.of(library, contents: [:], feeds: [show]), atLaunch: false).isEmpty)
        // And applying it changes nothing here.
        let application = apply([Fixtures.entry(.feed(show.id, .listening), .object(members), wall: 2)], to: library, feeds: [show])
        XCTAssertTrue(application.feeds.feedsToChange.isEmpty)
        XCTAssertTrue(application.appliedKeys.contains(.feed(show.id, .listening)))
    }

    /// A baseline holding feed keys saves and reads back as itself.
    func testBaselineWithFeedsRoundTrips() throws {
        let folder = BookFolder(name: "Show")
        let known = baseline(of: Fixtures.library(folders: [folder]), feeds: [feed(folderID: folder.id)])
        let data = try SyncValueCoding.makeEncoder().encode(known)
        XCTAssertEqual(try SyncValueCoding.makeDecoder().decode(SyncProjection.self, from: data), known)
    }

    // MARK: Applying to this device's feeds

    /// Another device's settings reach this device's feed, and are noted as applied.
    func testSettingsAreApplied() throws {
        let folder = BookFolder(name: "Show")
        let mine = feed(folderID: folder.id)
        var theirs = mine
        theirs.itemPolicyOverride = FeedItemPolicy(choice: .everyListedDownloadsByHand, newestCount: 7)
        theirs.deleteDownloadsDaysAfterPlayedOverride = 2
        theirs.listeningOptions = ListeningOptions(predownloadsNext: false)
        theirs.unsubscribedDate = Date(timeIntervalSince1970: 8_000)
        let application = apply(entries(of: theirs, wall: 5), to: Fixtures.library(folders: [folder]), feeds: [mine])
        let changed = try XCTUnwrap(application.feeds.feedsToChange.first)
        XCTAssertEqual(changed.itemPolicyOverride, theirs.itemPolicyOverride)
        XCTAssertEqual(changed.deleteDownloadsDaysAfterPlayedOverride, 2)
        XCTAssertEqual(changed.listeningOptions, theirs.listeningOptions)
        XCTAssertEqual(changed.unsubscribedDate, theirs.unsubscribedDate)
        XCTAssertEqual(changed.title, mine.title)
        for field in SyncFeedField.allCases { XCTAssertTrue(application.appliedKeys.contains(.feed(mine.id, field)), "\(field)") }
        XCTAssertTrue(application.feeds.feedsToAdd.isEmpty)
    }

    /// The same values again change nothing.
    func testSameValuesChangeNothing() {
        let folder = BookFolder(name: "Show")
        let mine = feed(folderID: folder.id)
        let application = apply(entries(of: mine, wall: 5), to: Fixtures.library(folders: [folder]), feeds: [mine])
        XCTAssertTrue(application.feeds.isEmpty)
    }

    /// A choice this TextMouth doesn't know is left alone and offered again.
    func testUnknownChoiceIsNotApplied() {
        let folder = BookFolder(name: "Show")
        let mine = feed(folderID: folder.id)
        let entry = Fixtures.entry(.feed(mine.id, .itemPolicy), .object(["choice": .string("later"), "newestCount": .integer(2)]), wall: 5)
        let application = apply([entry], to: Fixtures.library(folders: [folder]), feeds: [mine])
        XCTAssertTrue(application.feeds.feedsToChange.isEmpty)
        XCTAssertFalse(application.appliedKeys.contains(entry.key))
    }

    /// Without this device's feeds nothing is applied, and the application says feed keys wait.
    func testFeedsNotLoadedWait() {
        let folder = BookFolder(name: "Show")
        let show = feed(folderID: folder.id)
        let application = apply(entries(of: show, wall: 5), to: Fixtures.library(folders: [folder]), feeds: nil)
        XCTAssertTrue(application.feeds.waitsForFeeds)
        XCTAssertTrue(application.feeds.isEmpty)
        XCTAssertFalse(application.appliedKeys.contains { $0.feedID != nil })
        XCTAssertFalse(apply([], to: Fixtures.library(), feeds: nil).feeds.waitsForFeeds)
    }

    // MARK: Feeds another device added

    /// A feed another device subscribed to is made here from its address, date, folder, and settings.
    func testNewFeedIsAdded() throws {
        let folder = BookFolder(name: "Show")
        var theirs = feed(folderID: folder.id, subscribed: 4_000)
        theirs.itemPolicyOverride = FeedItemPolicy(choice: .onlyNewestListed, newestCount: 5)
        let library = Fixtures.library(folders: [folder])
        let application = apply(entries(of: theirs, wall: 5), to: library, feeds: [])
        let added = try XCTUnwrap(application.feeds.feedsToAdd.first)
        XCTAssertEqual(added.id, theirs.id)
        XCTAssertEqual(added.feedURL, theirs.feedURL)
        XCTAssertEqual(added.folderID, folder.id)
        XCTAssertEqual(added.subscribedDate, theirs.subscribedDate)
        XCTAssertEqual(added.itemPolicyOverride, theirs.itemPolicyOverride)
        XCTAssertTrue(added.isSubscribed)
        for field in SyncFeedField.allCases { XCTAssertTrue(application.appliedKeys.contains(.feed(theirs.id, field)), "\(field)") }
    }

    /// A feed arriving with its folder in the same merge lands in that folder.
    func testNewFeedLandsInItsNewFolder() throws {
        let folderID = Fixtures.id(40)
        let theirs = feed(folderID: folderID)
        let folderEntries = [
            Fixtures.entry(.folder(folderID, .presence), .bool(true), wall: 5, device: "b"),
            Fixtures.entry(.folder(folderID, .name), .string("Show"), wall: 5, device: "b"),
            Fixtures.entry(.folder(folderID, .parent), .null, wall: 5, device: "b"),
        ]
        let application = apply(folderEntries + entries(of: theirs, wall: 5), to: Fixtures.library(), feeds: [])
        XCTAssertEqual(application.library.folders.map(\.id), [folderID])
        XCTAssertEqual(application.feeds.feedsToAdd.map(\.folderID), [folderID])
    }

    /// A feed whose address, date, or folder hasn't arrived waits, its keys unapplied.
    func testIncompleteFeedWaits() {
        let folder = BookFolder(name: "Show")
        let theirs = feed(folderID: folder.id)
        let library = Fixtures.library(folders: [folder])
        for missing in SyncFeedValues.originFields {
            let partial = entries(of: theirs, wall: 5).filter { $0.key != .feed(theirs.id, missing) }
            let application = apply(partial, to: library, feeds: [])
            XCTAssertTrue(application.feeds.feedsToAdd.isEmpty, "\(missing)")
            XCTAssertFalse(application.appliedKeys.contains(.feed(theirs.id, .presence)), "\(missing)")
        }
        // A folder that lands nowhere: a feed needs a folder of its own.
        let elsewhere = feed(folderID: Fixtures.id(99))
        XCTAssertTrue(apply(entries(of: elsewhere, wall: 5), to: library, feeds: []).feeds.feedsToAdd.isEmpty)
    }

    /// A feed whose address this device subscribes already is not added again, whatever its scheme.
    func testSameAddressIsNotAddedTwice() {
        let folder = BookFolder(name: "Show")
        let other = BookFolder(name: "Show Again")
        let mine = feed(address: "https://Example.com/show.xml/", folderID: folder.id)
        let theirs = feed(address: "http://example.com/show.xml", folderID: other.id)
        let application = apply(entries(of: theirs, wall: 5), to: Fixtures.library(folders: [folder, other]), feeds: [mine])
        XCTAssertTrue(application.feeds.feedsToAdd.isEmpty)
        XCTAssertFalse(application.appliedKeys.contains(.feed(theirs.id, .presence)))
    }

    /// Of two new feeds of one address, the older is added, whichever order they come in.
    func testOlderOfTwoNewCopiesIsAdded() {
        let first = BookFolder(name: "One")
        let second = BookFolder(name: "Two")
        let older = feed(id: Fixtures.id(2), folderID: first.id, subscribed: 1_000)
        let younger = feed(id: Fixtures.id(1), folderID: second.id, subscribed: 2_000)
        let library = Fixtures.library(folders: [first, second])
        for order in [[older, younger], [younger, older]] {
            let application = apply(order.flatMap { entries(of: $0, wall: 5) }, to: library, feeds: [])
            XCTAssertEqual(application.feeds.feedsToAdd.map(\.id), [older.id])
            XCTAssertFalse(application.appliedKeys.contains(.feed(younger.id, .presence)))
        }
    }

    /// A new feed is not put in a folder another feed lists in.
    func testNewFeedIsNotPutInAnotherFeedsFolder() {
        let folder = BookFolder(name: "News")
        let mine = feed(address: "https://one.example/news.xml", folderID: folder.id)
        let theirs = feed(address: "https://two.example/news.xml", folderID: folder.id)
        let application = apply(entries(of: theirs, wall: 5), to: Fixtures.library(folders: [folder]), feeds: [mine])
        XCTAssertTrue(application.feeds.feedsToAdd.isEmpty)
        XCTAssertFalse(application.appliedKeys.contains(.feed(theirs.id, .presence)))
    }

    // MARK: Removals

    /// Delete Feed… elsewhere removes the feed here; a later setting elsewhere brings it back.
    func testRemovalStandsUnlessLater() {
        let folder = BookFolder(name: "Show")
        let mine = feed(folderID: folder.id)
        let library = Fixtures.library(folders: [folder])
        let removal = Fixtures.entry(.feed(mine.id, .presence), .null, wall: 9)
        let removed = apply(entries(of: mine, wall: 5) + [removal], to: library, feeds: [mine])
        XCTAssertEqual(removed.feeds.feedsToRemove, [mine.id])
        XCTAssertTrue(removed.appliedKeys.contains(removal.key))

        let later = Fixtures.entry(.feed(mine.id, .deleteAfterPlayed), .integer(3), wall: 12)
        let revived = apply(entries(of: mine, wall: 5) + [removal, later], to: library, feeds: [mine])
        XCTAssertTrue(revived.feeds.feedsToRemove.isEmpty)
        XCTAssertEqual(revived.entriesToRecord[.feed(mine.id, .presence)], .bool(true))
        XCTAssertEqual(revived.feeds.feedsToChange.first?.deleteDownloadsDaysAfterPlayedOverride, 3)
    }

    /// A feed this device lacks whose removal stands is not added.
    func testRemovedFeedIsNotAdded() {
        let folder = BookFolder(name: "Show")
        let theirs = feed(folderID: folder.id)
        let removal = Fixtures.entry(.feed(theirs.id, .presence), .null, wall: 9)
        let application = apply(entries(of: theirs, wall: 5) + [removal], to: Fixtures.library(folders: [folder]), feeds: [])
        XCTAssertTrue(application.feeds.feedsToAdd.isEmpty)
        XCTAssertTrue(application.feeds.feedsToRemove.isEmpty)
    }

    /// The baseline forgets every key of a feed whose removal it takes.
    func testBaselineForgetsARemovedFeed() {
        let folder = BookFolder(name: "Show")
        let show = feed(folderID: folder.id)
        var known = baseline(of: Fixtures.library(folders: [folder]), feeds: [show])
        known.absorb([Fixtures.entry(.feed(show.id, .presence), .null, wall: 9)])
        XCTAssertFalse(known.values.keys.contains { $0.feedID == show.id })
    }

    // MARK: Folders

    /// A feed whose folder was folded into another device's same-named folder follows it.
    func testFeedFollowsAFoldedFolder() throws {
        // This device's folder is the younger, so it folds into the other's.
        let mine = BookFolder(name: "Show", dateCreated: Date(timeIntervalSince1970: 50_000))
        let theirsID = Fixtures.id(60)
        let folderEntries = [
            Fixtures.entry(.folder(theirsID, .presence), .bool(true), wall: 1_000, device: "b"),
            Fixtures.entry(.folder(theirsID, .name), .string("Show"), wall: 1_000, device: "b"),
            Fixtures.entry(.folder(theirsID, .parent), .null, wall: 1_000, device: "b"),
        ]
        let show = feed(folderID: mine.id)
        let application = apply(folderEntries, to: Fixtures.library(folders: [mine]), feeds: [show])
        XCTAssertEqual(application.library.folders.map(\.id), [theirsID])
        XCTAssertEqual(try XCTUnwrap(application.feeds.feedsToChange.first).folderID, theirsID)
    }

    /// A folder entry naming a folder the plan doesn't know leaves the feed where it is.
    func testUnknownFolderLeavesTheFeed() {
        let folder = BookFolder(name: "Show")
        let mine = feed(folderID: folder.id)
        let entry = Fixtures.entry(.feed(mine.id, .folder), SyncValueCoding.id(Fixtures.id(77)), wall: 5)
        let application = apply([entry], to: Fixtures.library(folders: [folder]), feeds: [mine])
        XCTAssertTrue(application.feeds.feedsToChange.isEmpty)
        XCTAssertFalse(application.appliedKeys.contains(entry.key))
    }

    // MARK: The launch (R7)

    /// A feed missing at launch is not reported removed, even when the feeds load after the first record.
    func testFeedMissingAtLaunchIsHeld() {
        let folder = BookFolder(name: "Show")
        let library = Fixtures.library(folders: [folder])
        let show = feed(folderID: folder.id)
        var known = baseline(of: library, feeds: [show])
        var hold = SyncLaunchHold()
        // The first record has no feeds yet: nothing of them is held or reported.
        let first = SyncProjection.of(library, contents: [:])
        hold.observeLaunch(baseline: known, now: first)
        XCTAssertTrue(SyncMerge.changes(from: known, to: first, hold: hold).isEmpty)
        XCTAssertTrue(hold.awaitsFeeds)
        // The books' settle passes the feeds by.
        hold.settle(baseline: &known, now: first)
        XCTAssertTrue(hold.awaitsFeeds)
        // The feeds load, without the feed: it is held, not removed.
        let loaded = SyncProjection.of(library, contents: [:], feeds: [])
        hold.observeLaunch(baseline: known, now: loaded)
        XCTAssertTrue(hold.held.contains(.feed(show.id, .presence)))
        XCTAssertTrue(SyncMerge.changes(from: known, to: loaded, hold: hold).isEmpty)
        // A settle with the feeds forgets it, silently.
        hold.settle(baseline: &known, now: loaded)
        XCTAssertFalse(hold.awaitsFeeds)
        XCTAssertFalse(known.values.keys.contains { $0.feedID == show.id })
        XCTAssertTrue(SyncMerge.changes(from: known, to: loaded, hold: hold).isEmpty)
    }

    /// A feed removed in the running app, after the launch's hold, is reported removed.
    func testFeedRemovedWhileRunningIsReported() {
        let folder = BookFolder(name: "Show")
        let library = Fixtures.library(folders: [folder])
        let show = feed(folderID: folder.id)
        var known = baseline(of: library, feeds: [show])
        var hold = SyncLaunchHold()
        let atLaunch = SyncProjection.of(library, contents: [:], feeds: [show])
        hold.observeLaunch(baseline: known, now: atLaunch)
        hold.settle(baseline: &known, now: atLaunch)
        let gone = SyncMerge.changes(from: known, to: SyncProjection.of(library, contents: [:], feeds: []), hold: hold)
        XCTAssertEqual(gone, [.feed(show.id, .presence): .null])
    }
}
