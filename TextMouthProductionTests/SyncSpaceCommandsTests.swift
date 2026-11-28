import XCTest
@testable import TextMouth

/// Saving space on a device that syncs (FR45, FR46), where the library's commands meet it: which books Remove
/// Download is offered for, what it refuses and says, the sweep that removes the downloads of books unopened for
/// some days, and the downloads of "All books". Each test names the behavior it pins and fails when that behavior
/// is taken out. The storage is a stand-in that records what it was asked, never a real drive.
@MainActor
final class SyncSpaceCommandsTests: XCTestCase {
    /// The seconds in a day.
    private let day = SyncSpacePolicy.secondsInDay

    // MARK: - Which books offer Remove Download

    /// A synced library offers Remove Download for a book whole on this device, and not for one in the cloud, one
    /// downloading, a feed's item, or a library that is not synced.
    func testASyncedLibraryOffersRemoveDownloadForABookWholeHere() {
        let whole = cloudTestBook("Whole")
        let away = cloudTestBook("Away")
        let downloading = cloudTestBook("Downloading")
        var feedItem = cloudTestBook("Episode")
        feedItem.feedLink = FeedBookLink(feedID: UUID(), itemID: "episode")
        let states = BookCloudStates()
        states.setSyncIsOn(true)
        states.record(.inCloud, for: away.id)
        states.record(.downloading(.notStarted), for: downloading.id)

        for (book, offered) in [(whole, true), (away, false), (downloading, false), (feedItem, false)] {
            let kinds = LibraryCloudCommand.commands(for: [book], isSelection: false, states: states, kept: []).map(\.kind)
            XCTAssertEqual(kinds.contains(.removeDownload), offered, book.title)
            XCTAssertEqual(states.canRemoveDownload(book), offered, book.title)
        }
        // A book recorded as downloaded or local is whole too.
        states.record(.downloaded, for: whole.id)
        XCTAssertTrue(states.canRemoveDownload(whole))

        let notSynced = BookCloudStates()
        XCTAssertFalse(notSynced.canRemoveDownload(whole), "a library that is not synced has nothing to remove")
        XCTAssertFalse(LibraryCloudCommand.commands(for: [whole], isSelection: false, states: notSynced, kept: []).map(\.kind).contains(.removeDownload))
    }

    /// In a cloud library the rule is as it was: a downloaded book offers it, a book not checked does not.
    func testACloudLibraryKeepsItsOwnRule() {
        let book = cloudTestBook()
        let states = BookCloudStates()
        states.setLibraryLocation(.cloud(.iCloudDrive))
        XCTAssertFalse(states.canRemoveDownload(book), "not checked yet")
        states.record(.downloaded, for: book.id)
        XCTAssertTrue(states.canRemoveDownload(book))
    }

    /// The iPhone's row offers it, after Download Now's place, only where the book is whole here.
    func testTheIPhoneRowOffersRemoveDownloadWhereItApplies() {
        let book = cloudTestBook()
        let removal = RemovalPreferences(confirmsFirst: true, movesToTrash: true)
        let withIt = PhoneLibraryOffer.bookCommands(for: book, isInReadingList: false, moves: nil, removal: removal, isKeptOnAllDevices: false, canRemoveDownload: true)
        let without = PhoneLibraryOffer.bookCommands(for: book, isInReadingList: false, moves: nil, removal: removal, isKeptOnAllDevices: false)
        XCTAssertEqual(withIt.first { $0.action == .removeDownload }?.title, "Remove Download")
        XCTAssertNil(without.first { $0.action == .removeDownload })
        let titles = withIt.map(\.title)
        XCTAssertLessThan(titles.firstIndex(of: "Remove Download") ?? .max, titles.firstIndex(of: "Keep on All Devices") ?? 0, "before the keep command, as the Mac lists it")
    }

    // MARK: - Remove Download in a synced library

    /// A person's Remove Download asks for the proof with downloads allowed, records the book In Cloud, asks for a
    /// refresh, and says where the book stays: iCloud Drive.
    func testRemoveDownloadProvesTheCopyAndSaysWhereTheBookStays() async {
        let book = cloudTestBook()
        let fixture = SpaceFixture(books: [book])
        var refusal: LibraryCloudRefusal?
        let said = await announcements {
            refusal = await fixture.commands.removeDownloads(of: [book], in: fixture.model, from: nil)
        }
        XCTAssertNil(refusal)
        XCTAssertEqual(said, ["Removed the download of Moby-Dick. It stays in iCloud Drive. Opening a book downloads it again."], "under All books, which the fixture has, it says the book is not downloaded again until opened")
        XCTAssertEqual(fixture.storage.proofs, [SpaceFixture.Proof(bookID: book.id, mayDownload: true)])
        XCTAssertEqual(fixture.states.state(of: book.id), .inCloud)
        XCTAssertEqual(fixture.refreshRequests.count, 1)
    }

    /// A book kept on all devices keeps its files: the refusal names Stop Keeping on All Devices, is shown in the
    /// alert and not said, and the proof is never asked for.
    func testABookKeptOnAllDevicesIsRefused() async {
        let book = cloudTestBook()
        let fixture = SpaceFixture(books: [book])
        fixture.kept.setSyncedBooks([book.id])
        var refusal: LibraryCloudRefusal?
        let said = await announcements {
            refusal = await fixture.commands.removeDownloads(of: [book], in: fixture.model, from: nil)
        }
        XCTAssertEqual(said, [], "the alert alone says it")
        XCTAssertEqual(refusal?.title, "Download Not Removed")
        XCTAssertEqual(refusal?.message, BookCloudError.keptOnAllDevices.explanation(in: .iCloudDrive))
        XCTAssertEqual(fixture.storage.proofs, [])
        XCTAssertNil(fixture.states.state(of: book.id))
    }

    /// A book on the reading list, and one open in a reader, are refused without asking for the proof.
    func testAListedBookAndAnOpenBookAreRefused() async {
        let listed = cloudTestBook("Listed")
        let open = cloudTestBook("Open")
        let fixture = SpaceFixture(books: [listed, open])
        fixture.kept.setReadingListBooks([listed.id])
        fixture.model.openBookIDs = [open.id]

        let listedRefusal = await fixture.commands.removeDownloads(of: [listed], in: fixture.model, from: nil)
        XCTAssertEqual(listedRefusal?.message, BookCloudError.keptForReadingList.explanation(in: .iCloudDrive))
        let openRefusal = await fixture.commands.removeDownloads(of: [open], in: fixture.model, from: nil)
        XCTAssertEqual(openRefusal?.message, BookCloudError.bookIsOpen.explanation(in: .iCloudDrive))
        XCTAssertEqual(fixture.storage.proofs, [])
    }

    /// A proof that falls short leaves the book whole, shows why in words in the alert, says nothing aloud, and
    /// records nothing: the book is still whole here.
    func testAProofThatFallsShortIsShownInWords() async {
        let book = cloudTestBook()
        let fixture = SpaceFixture(books: [book])
        fixture.storage.refuse(book.id, with: .syncRemoval(.notUploaded("a blob")))
        var refusal: LibraryCloudRefusal?
        let said = await announcements {
            refusal = await fixture.commands.removeDownloads(of: [book], in: fixture.model, from: nil)
        }
        XCTAssertEqual(said, [])
        XCTAssertEqual(refusal?.message, SyncWording.removalRefusal(.notUploaded("a blob"), isPhone: false))
        XCTAssertNil(fixture.states.state(of: book.id), "still whole here: nothing recorded")
        XCTAssertEqual(fixture.refreshRequests.count, 0)
    }

    /// Several books are removed one at a time and one summary says them; a book the proof refused is named in the
    /// same alert.
    func testASelectionIsRemovedOneByOneWithOneSummary() async {
        let books = [cloudTestBook("One"), cloudTestBook("Two"), cloudTestBook("Three")]
        let fixture = SpaceFixture(books: books)
        var refusal: LibraryCloudRefusal?
        let said = await announcements {
            refusal = await fixture.commands.removeDownloads(of: books, in: fixture.model, from: nil)
        }
        XCTAssertNil(refusal)
        XCTAssertEqual(said, ["Removed the downloads of 3 books. They stay in iCloud Drive. Opening a book downloads it again."])
        XCTAssertEqual(fixture.storage.proofs.map(\.bookID), books.map(\.id), "in list order")
    }

    // MARK: - Removing the downloads of books unopened for some days

    /// Under "Books you open or keep" with days set, a book unopened for the days goes; one opened within them stays.
    func testOnlyABookUnopenedForTheDaysGoes() async {
        let old = fixtureBook("Old", openedDaysAgo: 8)
        let recent = fixtureBook("Recent", openedDaysAgo: 6)
        let fixture = SpaceFixture(books: [old, recent])
        let report = await fixture.sweep(settings: fixture.settings(days: 7))
        XCTAssertEqual(report.removed, [old.id])
        XCTAssertEqual(fixture.storage.proofs.map(\.bookID), [old.id])
        XCTAssertEqual(fixture.states.state(of: old.id), .inCloud)
        XCTAssertNil(fixture.states.state(of: recent.id))
    }

    /// A play here counts as opening, whatever the book's last opening says.
    func testAPlayHereCountsAsOpening() async {
        var played = fixtureBook("Played", openedDaysAgo: 100)
        played.lastPlaybackStopped = SpaceFixture.start.addingTimeInterval(-2 * day)
        let fixture = SpaceFixture(books: [played])
        let report = await fixture.sweep(settings: fixture.settings(days: 7))
        XCTAssertEqual(report.removed, [])
    }

    /// A book's files arriving here count as use: a book fetched yesterday stays whatever its opening says.
    func testFilesThatArrivedRecentlyHoldTheBook() async {
        let arrived = fixtureBook("Arrived", openedDaysAgo: 100)
        let fixture = SpaceFixture(books: [arrived])
        fixture.arrivals.set(SpaceFixture.start.addingTimeInterval(-1 * day))
        let held = await fixture.sweep(settings: fixture.settings(days: 7))
        XCTAssertEqual(held.removed, [])
        fixture.clock.advance(by: 7 * day)
        let released = await fixture.sweep(settings: fixture.settings(days: 7))
        XCTAssertEqual(released.removed, [arrived.id], "seven days after it arrived")
    }

    /// The days count from the day the removal began: a book unopened for a year goes only once the days have passed
    /// since, so turning the setting on removes nothing at once.
    func testTheDaysCountFromTheDayTheRemovalBegan() async {
        let old = fixtureBook("Old", openedDaysAgo: 400)
        let fixture = SpaceFixture(books: [old])
        let justBegun = fixture.settings(days: 7, began: SpaceFixture.start.addingTimeInterval(-2 * day))
        let first = await fixture.sweep(settings: justBegun)
        XCTAssertEqual(first.removed, [], "nothing at once")
        fixture.clock.advance(by: 5 * day)
        let later = await fixture.sweep(settings: justBegun)
        XCTAssertEqual(later.removed, [old.id], "seven days after the removal began")
    }

    /// A time zone change moves nothing: the days are counted in hours between instants.
    func testTheDaysAreCountedAcrossATimeZoneChange() async throws {
        let format = ISO8601DateFormatter()
        let opened = try XCTUnwrap(format.date(from: "2026-03-01T12:00:00-05:00"))
        var book = cloudTestBook("Traveller")
        book.lastOpened = opened
        let fixture = SpaceFixture(books: [book])
        let began = opened.addingTimeInterval(-30 * day)
        // Seven calendar days later in New York, which held the 23-hour day of the change to summer time.
        fixture.clock.now = try XCTUnwrap(format.date(from: "2026-03-08T12:00:00-04:00"))
        let early = await fixture.sweep(settings: SyncDeviceSettings(books: .openedOrKept, removeAfterDays: 7, removalsBeganAt: began))
        XCTAssertEqual(early.removed, [])
        // The same moment as a clock in Tokyo reads it, an hour later: due.
        fixture.clock.now = try XCTUnwrap(format.date(from: "2026-03-09T02:00:00+09:00"))
        let due = await fixture.sweep(settings: SyncDeviceSettings(books: .openedOrKept, removeAfterDays: 7, removalsBeganAt: began))
        XCTAssertEqual(due.removed, [book.id])
    }

    /// Nothing is removed under "All books", with the days Off, or before the date the removal began is known; and
    /// nothing while sync is off.
    func testNothingIsRemovedWhereTheSettingsSayNo() async {
        let old = fixtureBook("Old", openedDaysAgo: 400)
        let fixture = SpaceFixture(books: [old])
        let began = SpaceFixture.start.addingTimeInterval(-30 * day)
        let settings: [SyncDeviceSettings] = [
            SyncDeviceSettings(books: .allBooks, removeAfterDays: 7, removalsBeganAt: began),
            SyncDeviceSettings(books: .openedOrKept, removeAfterDays: nil, removalsBeganAt: began),
            SyncDeviceSettings(books: .openedOrKept, removeAfterDays: 7, removalsBeganAt: nil),
        ]
        for setting in settings {
            let report = await fixture.sweep(settings: setting)
            XCTAssertEqual(report.removed, [], "\(setting)")
        }
        fixture.states.setSyncIsOn(false)
        let off = await fixture.sweep(settings: fixture.settings(days: 7))
        XCTAssertEqual(off.removed, [], "sync is off")
        XCTAssertEqual(fixture.storage.proofs, [])
    }

    /// A book the library protects (kept, listed, in use) is never asked about, and a feed's item is never swept;
    /// the others go.
    func testProtectedBooksAndFeedItemsAreNeverRemoved() async {
        var feedItem = fixtureBook("Episode", openedDaysAgo: 100)
        feedItem.feedLink = FeedBookLink(feedID: UUID(), itemID: "episode")
        let kept = fixtureBook("Kept", openedDaysAgo: 100)
        let busy = fixtureBook("Busy", openedDaysAgo: 100)
        let plain = fixtureBook("Plain", openedDaysAgo: 100)
        let fixture = SpaceFixture(books: [feedItem, kept, busy, plain])
        let protected: Set<UUID> = [kept.id, busy.id]
        let report = await fixture.sweep(settings: fixture.settings(days: 7), isProtected: { protected.contains($0.id) })
        XCTAssertEqual(report.removed, [plain.id])
        XCTAssertEqual(fixture.storage.proofs.map(\.bookID), [plain.id])
    }

    /// What the library protects: a book the person keeps, one kept on all devices, one on the reading list, one open
    /// now, and a feed's item.
    func testTheLibraryProtectsEveryKindOfBookThatMustStay() {
        let model = LibraryViewModel(initializeServices: false)
        let kept = KeptBooks(file: nil)
        model.cloudCommands = LibraryCloudCommands(
            states: BookCloudStates(), kept: kept, storage: { LocalBookStorage() }, refreshAfterRemoval: {}, revealInFinder: { _ in }
        )
        let plain = cloudTestBook("Plain")
        let own = cloudTestBook("Own")
        let allDevices = cloudTestBook("All devices")
        let listed = cloudTestBook("Listed")
        let open = cloudTestBook("Open")
        var feedItem = cloudTestBook("Episode")
        feedItem.feedLink = FeedBookLink(feedID: UUID(), itemID: "episode")
        model.library = Library(books: [plain, own, allDevices, listed, open, feedItem])
        kept.keep([own.id])
        kept.setSyncedBooks([allDevices.id])
        _ = model.library.readingList.append([listed.id])
        model.openBookIDs = [open.id]

        XCTAssertFalse(model.isProtectedFromUnopenedRemoval(plain))
        for protected in [own, allDevices, listed, open, feedItem] {
            XCTAssertTrue(model.isProtectedFromUnopenedRemoval(protected), protected.title)
        }
    }

    /// A proof that falls short leaves the book, which the status counts as waiting; one that costs a look at the files
    /// is not tried again for a day, and one that costs nothing is tried at the next sync.
    func testABookWhoseCopyIsNotProvenWaits() async {
        let notYet = fixtureBook("Not uploaded yet", openedDaysAgo: 100)
        let changed = fixtureBook("Changed here", openedDaysAgo: 100)
        let fixture = SpaceFixture(books: [notYet, changed])
        fixture.storage.refuse(notYet.id, with: .syncRemoval(.notUploaded("a blob")))
        fixture.storage.refuse(changed.id, with: .syncRemoval(.changedHere("book.txt")))

        let first = await fixture.sweep(settings: fixture.settings(days: 7))
        XCTAssertEqual(first.removed, [])
        XCTAssertEqual(first.waiting, 2)
        XCTAssertNil(fixture.states.state(of: notYet.id))

        let second = await fixture.sweep(settings: fixture.settings(days: 7))
        XCTAssertEqual(second.waiting, 2, "both still wait, the changed one out its day")
        XCTAssertEqual(fixture.storage.proofs.map(\.bookID).filter { $0 == changed.id }.count, 1)

        fixture.clock.advance(by: day)
        let third = await fixture.sweep(settings: fixture.settings(days: 7))
        XCTAssertEqual(third.waiting, 2, "a day later the changed book is looked at again")
        XCTAssertEqual(fixture.storage.proofs.map(\.bookID).filter { $0 == changed.id }.count, 2)
    }

    /// The sweep passes on whether files away in iCloud Drive may be downloaded to read the copy back: a costly
    /// connection says no.
    func testTheSweepPassesOnWhetherItMayDownload() async {
        let old = fixtureBook("Old", openedDaysAgo: 100)
        let fixture = SpaceFixture(books: [old])
        _ = await fixture.sweep(settings: fixture.settings(days: 7), mayDownload: false)
        XCTAssertEqual(fixture.storage.proofs, [SpaceFixture.Proof(bookID: old.id, mayDownload: false)])
    }

    /// One summary says the whole sweep, never one for each book, and nothing for a book that stayed.
    func testASweepSaysOneSummary() async {
        let books = (1...3).map { fixtureBook("Book \($0)", openedDaysAgo: 100) }
        let stays = fixtureBook("Stays", openedDaysAgo: 100)
        let fixture = SpaceFixture(books: books + [stays])
        fixture.storage.refuse(stays.id, with: .syncRemoval(.notUploaded("a blob")))
        let said = await announcements {
            _ = await fixture.sweep(settings: fixture.settings(days: 7))
        }
        XCTAssertEqual(said, ["Removed downloads of 3 books not opened in 7 days. All stay in iCloud Drive."])
        XCTAssertEqual(fixture.refreshRequests.count, 1)
    }

    /// A sweep that removes nothing says nothing.
    func testASweepThatRemovesNothingSaysNothing() async {
        let recent = fixtureBook("Recent", openedDaysAgo: 1)
        let fixture = SpaceFixture(books: [recent])
        let said = await announcements {
            _ = await fixture.sweep(settings: fixture.settings(days: 7))
        }
        XCTAssertEqual(said, [])
        XCTAssertEqual(fixture.refreshRequests.count, 0)
    }

    /// One sweep takes at most 25 books off the device; the rest wait for the next sync.
    func testASweepTakesAtMostTwentyFiveBooks() async {
        let books = (1...30).map { fixtureBook("Book \($0)", openedDaysAgo: Double(100 + $0)) }
        let fixture = SpaceFixture(books: books)
        let first = await fixture.sweep(settings: fixture.settings(days: 7))
        XCTAssertEqual(first.removed.count, LibraryCloudCommands.unopenedBooksPerSweep)
        let second = await fixture.sweep(settings: fixture.settings(days: 7))
        XCTAssertEqual(second.removed.count, 5)
    }

    /// A book already in the cloud has no download: it is not asked about.
    func testABookAlreadyInTheCloudIsSkipped() async {
        let away = fixtureBook("Away", openedDaysAgo: 100)
        let fixture = SpaceFixture(books: [away])
        fixture.states.record(.inCloud, for: away.id)
        let report = await fixture.sweep(settings: fixture.settings(days: 7))
        XCTAssertEqual(report.removed, [])
        XCTAssertEqual(fixture.storage.proofs, [])
    }

    // MARK: - All books

    /// Under "All books" each book this device lacks downloads, one at a time and quietly: the rows show it, and
    /// VoiceOver hears nothing.
    func testAllBooksDownloadsEveryMissingBookQuietly() async {
        let books = [cloudTestBook("One"), cloudTestBook("Two"), cloudTestBook("Three")]
        let fixture = SpaceFixture(books: books, recorded: .inCloud)
        let said = await announcements {
            await fixture.commands.downloadMissingBooks(in: fixture.model)?.value
        }
        XCTAssertEqual(said, [])
        XCTAssertEqual(fixture.fake.downloadsStarted, books.map(\.id), "one after another, in list order")
        for book in books { XCTAssertEqual(fixture.states.state(of: book.id), .downloaded, book.title) }
        XCTAssertEqual(fixture.rooms.counts.last, 0)
    }

    /// Under "Books you open or keep" nothing downloads by itself, and with sync off nothing does either.
    func testOtherwiseNothingIsDownloadedByItself() async {
        let book = cloudTestBook()
        let fixture = SpaceFixture(books: [book], recorded: .inCloud)
        fixture.choice.value = .openedOrKept
        let none = fixture.commands.downloadMissingBooks(in: fixture.model)
        XCTAssertNil(none)

        fixture.choice.value = .allBooks
        fixture.states.setSyncIsOn(false)
        XCTAssertNil(fixture.commands.downloadMissingBooks(in: fixture.model))
        XCTAssertEqual(fixture.fake.downloadsStarted, [])
    }

    /// A device short of room stops downloading and keeps what is there: no book that does not fit is started, and
    /// the status is told how many were left.
    func testAShortOfRoomDeviceStopsAndSaysSo() async {
        let books = [cloudTestBook("One"), cloudTestBook("Two")]
        let fixture = SpaceFixture(books: books, recorded: .inCloud)
        for book in books { fixture.fake.setBytesToDownload(5_000_000_000, of: book.id) }
        fixture.space.free = 1_000_000

        await fixture.commands.downloadMissingBooks(in: fixture.model)?.value
        XCTAssertEqual(fixture.fake.downloadsStarted, [], "nothing was started")
        XCTAssertEqual(fixture.rooms.counts.last, 2)
        for book in books { XCTAssertEqual(fixture.states.state(of: book.id), .inCloud, "what is there stays") }

        // Room is made: the next pass downloads them and clears the notice.
        fixture.space.free = 100_000_000_000_000
        await fixture.commands.downloadMissingBooks(in: fixture.model)?.value
        XCTAssertEqual(fixture.fake.downloadsStarted.count, 2)
        XCTAssertEqual(fixture.rooms.counts.last, 0)
    }

    /// A book whose download failed waits before the next sync tries it again.
    func testAFailedDownloadWaitsBeforeItIsTriedAgain() async {
        let book = cloudTestBook()
        let fixture = SpaceFixture(books: [book], recorded: .inCloud)
        fixture.fake.scriptDownload(of: book.id, steps: [], failingWith: .offline)
        await fixture.commands.downloadMissingBooks(in: fixture.model)?.value
        XCTAssertEqual(fixture.fake.downloadsStarted, [book.id])

        // The sync records the placeholder as In Cloud again; the book waits all the same.
        fixture.states.record(.inCloud, for: book.id)
        XCTAssertNil(fixture.commands.downloadMissingBooks(in: fixture.model), "waiting")
        fixture.clock.advance(by: LibraryCloudCommands.keptBookRetryDelay + 1)
        fixture.fake.setState(.inCloud, of: book.id)
        await fixture.commands.downloadMissingBooks(in: fixture.model)?.value
        XCTAssertEqual(fixture.fake.downloadsStarted, [book.id, book.id])
    }

    // MARK: - The review's fixes

    /// The library's last look runs right before the files go, and says no when the book was kept, opened, or its
    /// setting turned off meanwhile: the book stays, and nothing is recorded as removed.
    func testTheLastLookStopsABookThatBecameProtectedMeanwhile() async {
        let book = fixtureBook("Old", openedDaysAgo: 100)
        let other = fixtureBook("Other", openedDaysAgo: 101)
        let fixture = SpaceFixture(books: [book, other])
        let protected = Box<Set<UUID>>([])
        // While the proof runs on the book, the person keeps it.
        fixture.storage.duringTheProof { id in
            if id == book.id { Task { @MainActor in protected.value.insert(id) } }
        }
        let report = await fixture.sweep(settings: fixture.settings(days: 7), isProtected: { protected.value.contains($0.id) })
        XCTAssertEqual(report.removed, [other.id])
        XCTAssertEqual(fixture.storage.lastLookAnswers[other.id], true)
        XCTAssertEqual(fixture.storage.lastLookAnswers[book.id], false, "kept after the proof, so the last look said no")
        XCTAssertNil(fixture.states.state(of: book.id), "and it is still whole here")
    }

    /// The setting turned off between the proof and the removal stops it, and so does a book that left the library.
    func testTheLastLookStopsARemovalWhoseSettingChanged() async {
        let book = fixtureBook("Old", openedDaysAgo: 100)
        let fixture = SpaceFixture(books: [book])
        fixture.storage.duringTheProof { [fixture] _ in
            // The person turns the removal off while the copy is read back.
            Task { @MainActor in fixture.settingsNow.value.removeAfterDays = nil }
        }
        let report = await fixture.sweep(settings: fixture.settings(days: 7))
        XCTAssertEqual(report.removed, [])
        XCTAssertEqual(fixture.storage.lastLookAnswers[book.id], false)
        XCTAssertNil(fixture.states.state(of: book.id), "still whole here")
    }

    /// The sweep's last look asks again whether the book is due: one opened and closed while its copy was checked, or
    /// whose days were made longer meanwhile, stays whole, though nothing protects it by then.
    func testTheLastLookStopsABookOpenedOrNoLongerDueMeanwhile() async {
        // Opened and closed during the proof: its row's last opening is now, and no reader has it open.
        let opened = fixtureBook("Opened", openedDaysAgo: 100)
        let fixture = SpaceFixture(books: [opened])
        fixture.storage.duringTheProof { [fixture] _ in
            Task { @MainActor in
                var row = opened
                row.lastOpened = fixture.clock.now
                fixture.model.library = Library(books: [row])
            }
        }
        let report = await fixture.sweep(settings: fixture.settings(days: 7))
        XCTAssertEqual(report.removed, [])
        XCTAssertEqual(report.waiting, 0, "a book the last look turned away is not waiting for its copy in iCloud Drive")
        XCTAssertEqual(fixture.storage.lastLookAnswers[opened.id], false)
        XCTAssertNil(fixture.states.state(of: opened.id), "still whole here")

        // Unopened for 10 days: due under 7 days, not under the 30 chosen while its copy was checked.
        let tenDays = fixtureBook("Ten days", openedDaysAgo: 10)
        let later = SpaceFixture(books: [tenDays])
        later.storage.duringTheProof { [later] _ in
            Task { @MainActor in later.settingsNow.value.removeAfterDays = 30 }
        }
        let laterReport = await later.sweep(settings: later.settings(days: 7))
        XCTAssertEqual(laterReport.removed, [])
        XCTAssertEqual(later.storage.lastLookAnswers[tenDays.id], false)
        XCTAssertNil(later.states.state(of: tenDays.id))
    }

    /// A person's own Remove Download is looked at again too: a book kept while its copy was read back stays.
    func testTheLastLookStopsAPersonsRemovalOfABookKeptMeanwhile() async {
        let book = cloudTestBook()
        let fixture = SpaceFixture(books: [book])
        fixture.storage.duringTheProof { [fixture] id in
            Task { @MainActor in _ = fixture.kept.keep([id]) }
        }
        let refusal = await fixture.commandsRemoving([book])
        XCTAssertEqual(fixture.storage.lastLookAnswers[book.id], false)
        XCTAssertEqual(refusal?.message, SyncWording.removeBookInUse)
        XCTAssertNil(fixture.states.state(of: book.id))
    }

    /// Only removals count toward the sweep's 25: books that cannot be proven are looked at and left, and never keep
    /// the books behind them from going.
    func testBooksThatCannotBeProvenDoNotStarveTheRest() async {
        let stuck = (1...30).map { fixtureBook("Stuck \($0)", openedDaysAgo: Double(200 + $0)) }
        let good = (1...25).map { fixtureBook("Good \($0)", openedDaysAgo: Double(100 + $0)) }
        let fixture = SpaceFixture(books: stuck + good)
        for book in stuck { fixture.storage.refuse(book.id, with: .syncRemoval(.notUploaded("a blob"))) }
        let report = await fixture.sweep(settings: fixture.settings(days: 7))
        XCTAssertEqual(report.removed.count, LibraryCloudCommands.unopenedBooksPerSweep)
        XCTAssertEqual(report.waiting, 30)
    }

    /// Two sweeps never overlap: one asked for while another is under way does nothing.
    func testSweepsRunOneAtATime() async {
        let books = (1...3).map { fixtureBook("Book \($0)", openedDaysAgo: 100) }
        let fixture = SpaceFixture(books: books)
        let first = Task { await fixture.sweep(settings: fixture.settings(days: 7)) }
        // Let the first begin: it runs until its first wait, with its sweep marked as under way.
        await Task.yield()
        let second = await fixture.sweep(settings: fixture.settings(days: 7))
        let done = await first.value
        XCTAssertEqual(second.removed, [], "the second found the first under way")
        XCTAssertEqual(done.removed.count, 3)
        XCTAssertEqual(fixture.storage.proofs.count, 3, "no book was asked about twice")
    }

    /// The count of books waiting stays the same while a book waits out its day, and is not asked again until then.
    func testTheWaitingCountIsSteadyThroughTheBooksDay() async {
        let changed = fixtureBook("Changed here", openedDaysAgo: 100)
        let fixture = SpaceFixture(books: [changed])
        fixture.storage.refuse(changed.id, with: .syncRemoval(.changedHere("book.txt")))
        let first = await fixture.sweep(settings: fixture.settings(days: 7))
        let second = await fixture.sweep(settings: fixture.settings(days: 7))
        XCTAssertEqual(first.waiting, 1)
        XCTAssertEqual(second.waiting, 1, "it waits out its day, and is still counted")
        XCTAssertEqual(fixture.storage.proofs.count, 1, "and is not read again until then")
    }

    /// A book with no file of its own here (a placeholder no row said so of yet) was not removed: it is recorded In
    /// Cloud, counted neither removed nor waiting, and nothing is said.
    func testABookAlreadyAwayIsNotCountedRemoved() async {
        let away = fixtureBook("Away", openedDaysAgo: 100)
        let fixture = SpaceFixture(books: [away])
        fixture.storage.refuse(away.id, with: .syncRemoval(.nothingToRemove))
        let said = await announcements {
            let report = await fixture.sweep(settings: fixture.settings(days: 7))
            XCTAssertEqual(report.removed, [])
            XCTAssertEqual(report.waiting, 0)
        }
        XCTAssertEqual(said, [])
        XCTAssertEqual(fixture.states.state(of: away.id), .inCloud)
    }

    /// Under "All books" a book a person freed stays freed: the next sync does not download it again until it is
    /// opened, and then it does.
    func testAllBooksLeavesWhatAPersonFreedUntilItIsOpened() async {
        // Never opened, so nothing opens it after the removal until the test says so.
        var book = cloudTestBook()
        book.lastOpened = nil
        let fixture = SpaceFixture(books: [book])
        _ = await fixture.commands.removeDownloads(of: [book], in: fixture.model, from: nil)
        XCTAssertEqual(fixture.states.state(of: book.id), .inCloud)

        // The next sync records the placeholder and asks for the missing books.
        XCTAssertNil(fixture.commands.downloadMissingBooks(in: fixture.model), "freed on purpose: left")
        XCTAssertEqual(fixture.fake.downloadsStarted, [])

        // The person opens it: a later opening, then it is an ordinary missing book again.
        fixture.clock.advance(by: 60)
        var opened = book
        opened.lastOpened = fixture.clock.now.addingTimeInterval(1)
        fixture.model.library = Library(books: [opened])
        await fixture.commands.downloadMissingBooks(in: fixture.model)?.value
        XCTAssertEqual(fixture.fake.downloadsStarted, [book.id])
    }

    /// "All books" goes on only while the path does not cost and it is still the choice: a path that began to cost, or a
    /// choice changed, after the queue started stops the books still queued, and their rows say In Cloud.
    func testAllBooksChecksThePathAndTheChoiceBeforeEachBook() async {
        for change in ["path", "choice"] {
            let books = [cloudTestBook("One"), cloudTestBook("Two"), cloudTestBook("Three")]
            let fixture = SpaceFixture(books: books, recorded: .inCloud)
            let task = fixture.commands.downloadMissingBooks(in: fixture.model)
            // The queue has begun planning; nothing has downloaded yet. Then the world changes.
            if change == "path" { fixture.costly.value = true } else { fixture.choice.value = .openedOrKept }
            await task?.value
            XCTAssertEqual(fixture.fake.downloadsStarted, [], change)
            for book in books { XCTAssertEqual(fixture.states.state(of: book.id), .inCloud, "\(change): \(book.title)") }
        }
        // And nothing starts at all while the path costs.
        let book = cloudTestBook()
        let fixture = SpaceFixture(books: [book], recorded: .inCloud)
        fixture.costly.value = true
        XCTAssertNil(fixture.commands.downloadMissingBooks(in: fixture.model))
    }

    /// A person's Remove Download on a path that costs asks for no download: it says the copy needs Wi-Fi.
    func testRemoveDownloadOnACostlyPathDoesNotDownloadToProve() async {
        let book = cloudTestBook()
        let fixture = SpaceFixture(books: [book])
        fixture.costly.value = true
        _ = await fixture.commands.removeDownloads(of: [book], in: fixture.model, from: nil)
        XCTAssertEqual(fixture.storage.proofs, [SpaceFixture.Proof(bookID: book.id, mayDownload: false)])
    }

    /// An unexpected error is said in the app's words, never the system's, which can name a file of the book.
    func testAnUnexpectedErrorIsSaidInTheAppsWords() async {
        let book = cloudTestBook()
        let fixture = SpaceFixture(books: [book])
        fixture.storage.refuse(book.id, with: .syncRemoval(.couldNotRemove("")))
        let refusal = await fixture.commands.removeDownloads(of: [book], in: fixture.model, from: nil)
        XCTAssertEqual(refusal?.message, "TextMouth couldn't remove all of this book's files.")
    }

    /// Stop Syncing's question counts the books only in iCloud Drive, from their packages, not from the rows' recorded
    /// states (which a launch has not filled yet, and which keep books removed since): a placeholder, a book freed or
    /// fetched only in part, and a placeholder whose pointer lists no files yet count; a whole book and one never
    /// backed up (no pointer) do not. It says they need the sync folder.
    func testStopSyncingCountsTheBooksOnlyInTheSyncFolder() throws {
        let sandbox = try makeSandboxDirectory("space-stop-count")
        let storeID = UUID()
        func package(_ name: String, here: [Bool]?) throws -> URL {
            let url = sandbox.appendingPathComponent("\(name).tmb", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            guard let here else { return url }
            let files = here.enumerated().map { index, isHere in
                StorePointer.File(path: "file\(index)", sha256: String(repeating: "a", count: 64), size: 1, modified: 0, onThisDevice: isHere)
            }
            let pointer = StorePointer(
                formatVersion: SyncFormats.currentVersion, storeID: storeID, bookID: UUID(),
                manifest: "m.json", uploaded: "m.json", files: files
            )
            try StoreFetch.write(pointer, in: url)
            return url
        }
        let packages = [
            try package("Placeholder", here: [false, false]),
            try package("Freed", here: [false, true]),
            try package("Listed later", here: []),
            try package("Whole", here: [true, true]),
            try package("Never backed up", here: nil),
        ]
        XCTAssertEqual(StoreFetch.countMissingFiles(in: packages), 3)
        XCTAssertEqual(StoreFetch.countMissingFiles(in: []), 0)
        let question = SyncWording.stopQuestion(isPhone: false, onlyInCloud: 3)
        XCTAssertEqual(
            question,
            "Stop syncing this library? Nothing is deleted, on this Mac or in iCloud Drive. 3 books: only in iCloud Drive. Keep the TextMouth Sync folder to open them."
        )
        XCTAssertEqual(SyncWording.stopQuestion(isPhone: false, onlyInCloud: 0), SyncWording.stopQuestion(isPhone: false))
    }

    /// The backup's own state forbids freeing a book it still has queued or awaits, and one the registers do not hold.
    func testTheBackupForbidsFreeingABookItHasNotFinishedWith() {
        let id = UUID()
        let other = UUID()
        XCTAssertTrue(SyncCenter.backupForbidsFreeing(id, queued: [id], awaiting: [], recordedContent: [id]), "queued")
        XCTAssertTrue(SyncCenter.backupForbidsFreeing(id, queued: [], awaiting: [id], recordedContent: [id]), "awaiting its upload record")
        XCTAssertTrue(SyncCenter.backupForbidsFreeing(id, queued: [], awaiting: [], recordedContent: [other]), "content not recorded")
        XCTAssertFalse(SyncCenter.backupForbidsFreeing(id, queued: [other], awaiting: [other], recordedContent: [id]))
    }

    /// Each way a book can be in use refuses its removal: open, in the audio editor, downloading; and a book being
    /// exported, transcribed, or text edited is in `feedBooksInUse`, which `isBookBusyForSync` reads too.
    func testABookInUseIsRefused() async {
        let editing = cloudTestBook("Editing audio")
        let open = cloudTestBook("Open")
        let fixture = SpaceFixture(books: [editing, open])
        fixture.model.audioEditActivity.beginUse(of: editing.id)
        fixture.model.openBookIDs = [open.id]
        XCTAssertTrue(fixture.model.isBookBusyForSync(editing.id))

        let editingRefusal = await fixture.commands.removeDownloads(of: [editing], in: fixture.model, from: nil)
        XCTAssertEqual(editingRefusal?.message, BookCloudError.bookInUse.explanation(in: .iCloudDrive))
        let openRefusal = await fixture.commands.removeDownloads(of: [open], in: fixture.model, from: nil)
        XCTAssertEqual(openRefusal?.message, BookCloudError.bookIsOpen.explanation(in: .iCloudDrive))
        XCTAssertEqual(fixture.storage.proofs, [])

        // A book downloading has nothing to remove: the command is not offered for it.
        let downloading = cloudTestBook("Downloading")
        fixture.states.record(.downloading(.notStarted), for: downloading.id)
        XCTAssertFalse(fixture.states.canRemoveDownload(downloading))
    }

    // MARK: - The book held busy while its files go

    /// From the last look's yes to the row's change the book is held busy, for a person's command and for a sweep
    /// alike: the library's `booksBeingFreed` holds it, a reader's load waits for it as for a package move, and a
    /// sync's removal leaves it. Once its row says In Cloud the hold is over.
    func testABookIsHeldBusyFromTheLastLookToTheRowsChange() async {
        for path in ["command", "sweep"] {
            let book = fixtureBook("Old", openedDaysAgo: 100)
            let fixture = SpaceFixture(books: [book])
            let seen = Box<[String]>([])
            fixture.storage.afterTheLastLook { [fixture] id in
                seen.value.append("freeing \(fixture.model.booksBeingFreed.contains(id))")
                seen.value.append("moving \(fixture.model.bookUpdates.isPackageMoving(id))")
                seen.value.append("busy \(fixture.model.isBookBusyForSync(id))")
                seen.value.append("row \(fixture.states.state(of: id).map { "\($0)" } ?? "unchanged")")
            }
            if path == "command" {
                _ = await fixture.commandsRemoving([book])
            } else {
                _ = await fixture.sweep(settings: fixture.settings(days: 7))
            }
            XCTAssertEqual(seen.value, ["freeing true", "moving true", "busy true", "row unchanged"], path)
            XCTAssertEqual(fixture.states.state(of: book.id), .inCloud, path)
            XCTAssertFalse(fixture.model.booksBeingFreed.contains(book.id), "\(path): the hold ended with the row's change")
            XCTAssertFalse(fixture.model.bookUpdates.isPackageMoving(book.id), path)
        }
    }

    /// A removal that fails after the last look said yes ends the hold all the same, and the row keeps its state; a
    /// last look that says no never begins one.
    func testTheHoldEndsHoweverTheRemovalEnds() async {
        let failing = cloudTestBook("Fails")
        let refused = cloudTestBook("Refused")
        let fixture = SpaceFixture(books: [failing, refused])
        fixture.fake.failRemoval(of: failing.id, with: .syncRemoval(.couldNotRemove("")))
        let held = Box<[UUID]>([])
        fixture.storage.afterTheLastLook { [fixture] id in
            if fixture.model.booksBeingFreed.contains(id) { held.value.append(id) }
        }
        _ = await fixture.commandsRemoving([failing])
        XCTAssertEqual(held.value, [failing.id])
        XCTAssertFalse(fixture.model.booksBeingFreed.contains(failing.id))
        XCTAssertFalse(fixture.model.bookUpdates.isPackageMoving(failing.id))
        XCTAssertNil(fixture.states.state(of: failing.id))

        // The person keeps the other book while its copy is checked: the last look says no, and nothing is held.
        fixture.storage.duringTheProof { [fixture] id in
            Task { @MainActor in _ = fixture.kept.keep([id]) }
        }
        _ = await fixture.commandsRemoving([refused])
        XCTAssertEqual(fixture.storage.lastLookAnswers[refused.id], false)
        XCTAssertEqual(held.value, [failing.id])
        XCTAssertFalse(fixture.model.booksBeingFreed.contains(refused.id))
    }

    /// The audio editor waits while a book's files go: its render and its opening begin only once the removal is
    /// over, then look at the book as it is (here gone from the library, which each says).
    func testTheAudioEditorWaitsWhileABooksFilesGo() async {
        let id = UUID()
        let model = LibraryViewModel(initializeServices: false)
        for step in ["render", "open"] {
            let order = Box<[String]>([])
            model.booksBeingFreed.begin(id)
            let running = Task { @MainActor in
                if step == "render" {
                    _ = try? await model.saveAudioEdits(ofBook: id)
                } else {
                    _ = try? await AudioEditSession.open(bookID: id, in: model)
                }
                order.value.append("\(step) went on")
            }
            // Its first turns run it to its wait.
            for _ in 0..<20 { await Task.yield() }
            order.value.append("removal over")
            model.booksBeingFreed.end(id)
            await running.value
            XCTAssertEqual(order.value, ["removal over", "\(step) went on"], step)
        }
    }

    /// The hold's wait returns at once for books not being freed, outlasts every removal it waits for, and wakes when
    /// the last of them ends.
    func testWaitingForBooksBeingFreed() async {
        let freed = BooksBeingFreed()
        let one = UUID()
        let two = UUID()
        await freed.waitUntilFreed([one, two])
        freed.begin(one)
        freed.begin(two)
        let order = Box<[String]>([])
        let waiting = Task { @MainActor in
            await freed.waitUntilFreed([one, two])
            order.value.append("woke")
        }
        for _ in 0..<20 { await Task.yield() }
        order.value.append("one ended")
        freed.end(one)
        for _ in 0..<20 { await Task.yield() }
        order.value.append("two ended")
        freed.end(two)
        await waiting.value
        XCTAssertEqual(order.value, ["one ended", "two ended", "woke"])
        freed.end(two)
        XCTAssertFalse(freed.contains(two), "ending twice changes nothing")
    }

    /// Exporting, transcribing, and Edit Text each hold a book: Remove Download refuses it as in use, the sweep leaves
    /// it, and one of them begun while the copy is checked makes the last look say no, the book left whole.
    func testABookExportedTranscribedOrTextEditedIsRefused() async {
        let sessions = BookTextEditSessions()
        let baseline = BookTextBaseline(source: nil, cache: FileFingerprint(stamp: FileStamp(byteCount: 0, modificationTimeNanoseconds: 0), digest: ""))
        let transcribingBefore = TranscribedBooks.shared.transcribingBookID
        defer { TranscribedBooks.shared.setTranscribing(transcribingBefore) }
        // Each use, begun and ended as the app's own begins and ends it.
        let uses: [(name: String, begin: @MainActor @Sendable (UUID) -> Void, end: @MainActor @Sendable (UUID) -> Void)] = [
            ("exporting", { BookExportModel.noteExportStarted([$0]) }, { BookExportModel.noteExportEnded([$0]) }),
            ("transcribing", { TranscribedBooks.shared.setTranscribing($0) }, { _ in TranscribedBooks.shared.setTranscribing(transcribingBefore) }),
            ("Edit Text", { sessions.begin($0, BookTextEditSessions.Session(baseline: baseline, report: { _, _ in })) }, { sessions.end($0) }),
        ]
        for use in uses {
            let book = fixtureBook(use.name, openedDaysAgo: 100)
            let fixture = SpaceFixture(books: [book])
            fixture.model.textEditSessions = sessions

            // In use already: refused before any proof, and left by the sweep.
            use.begin(book.id)
            XCTAssertTrue(fixture.model.isBookBusyForSync(book.id), use.name)
            XCTAssertTrue(fixture.model.isProtectedFromUnopenedRemoval(book), use.name)
            let refusal = await fixture.commandsRemoving([book])
            XCTAssertEqual(refusal?.message, BookCloudError.bookInUse.explanation(in: .iCloudDrive), use.name)
            XCTAssertEqual(fixture.storage.proofs, [], "\(use.name): no proof was asked for")
            use.end(book.id)

            // Begun while the copy is checked: the last look says no, and the book stays whole.
            fixture.storage.duringTheProof { id in
                Task { @MainActor in use.begin(id) }
            }
            let report = await fixture.sweep(settings: fixture.settings(days: 7)) { [fixture] in
                fixture.model.isProtectedFromUnopenedRemoval($0)
            }
            XCTAssertEqual(report.removed, [], use.name)
            XCTAssertEqual(fixture.storage.lastLookAnswers[book.id], false, use.name)
            XCTAssertNil(fixture.states.state(of: book.id), "\(use.name): still whole here")
            use.end(book.id)
        }
    }

    // MARK: - The arrival date

    /// The date a book's files arrived is the pointer's last write; a package with no pointer has none.
    func testTheArrivalDateIsThePointersLastWrite() throws {
        let package = try makeSandboxDirectory("space-arrival").appendingPathComponent("A.tmb", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        XCTAssertNil(SyncPlaceholder.arrivedAt(package))
        let pointer = package.appendingPathComponent(StorePointer.fileName)
        try Data("{}".utf8).write(to: pointer)
        let written = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: pointer.path)
        XCTAssertEqual(SyncPlaceholder.arrivedAt(package)?.timeIntervalSince1970 ?? 0, written.timeIntervalSince1970, accuracy: 1)
    }

    // MARK: - Helpers

    /// A book last opened `days` days before the fixture's clock.
    private func fixtureBook(_ title: String, openedDaysAgo days: Double) -> Book {
        var book = cloudTestBook(title)
        book.lastOpened = SpaceFixture.start.addingTimeInterval(-days * day)
        return book
    }
}

// MARK: - The fixture

/// What a book storage was asked, and what it refuses, for a library whose sync is on: it answers for every book
/// as whole here, removes by recording the ask, and can refuse a book's removal as the proof does.
private final class ProvingStorage: BookCloudStorage, @unchecked Sendable {
    /// The scripted storage behind it.
    let fake: FakeBookCloudStorage
    private let lock = NSLock()
    private var asked: [SpaceFixture.Proof] = []
    private var refusals: [UUID: BookCloudError] = [:]
    private var lastLooks: [UUID: Bool] = [:]
    private var between: (@Sendable (UUID) -> Void)?
    private var afterYes: (@MainActor @Sendable (UUID) -> Void)?

    init(_ fake: FakeBookCloudStorage) { self.fake = fake }

    /// Runs `action` on the main actor after the last look said yes and before the files go, where the library holds
    /// the book busy.
    func afterTheLastLook(_ action: (@MainActor @Sendable (UUID) -> Void)?) { lock.withLock { afterYes = action } }

    /// What the library's last look (`FreeingCheck`) answered for each book at the moment its files would go.
    var lastLookAnswers: [UUID: Bool] { lock.withLock { lastLooks } }

    /// Runs `action` after the proof and before the last look, as a book opened during a read-back would.
    func duringTheProof(_ action: (@Sendable (UUID) -> Void)?) { lock.withLock { between = action } }

    /// Every removal asked for, in order.
    var proofs: [SpaceFixture.Proof] { lock.withLock { asked } }

    /// Makes the removal of the book `bookID` fail with `error`.
    func refuse(_ bookID: UUID, with error: BookCloudError) { lock.withLock { refusals[bookID] = error } }

    func libraryLocation() -> StorageLocation { fake.libraryLocation() }
    func state(of package: BookPackage) -> BookCloudState { fake.state(of: package) }
    func download(_ package: BookPackage) -> AsyncThrowingStream<BookDownloadProgress, Error> { fake.download(package) }
    func removeDownload(of package: BookPackage) throws { try fake.removeDownload(of: package) }
    func bytesToDownload(of package: BookPackage) -> Int64? { fake.bytesToDownload(of: package) }

    func removeDownloadAsync(of package: BookPackage, mayDownload: Bool) async throws {
        let refusal = lock.withLock { () -> BookCloudError? in
            asked.append(SpaceFixture.Proof(bookID: package.bookID, mayDownload: mayDownload))
            return refusals[package.bookID]
        }
        if let refusal { throw refusal }
        let action = lock.withLock { between }
        action?(package.bookID)
        // The storage asks the last look right before it deletes, about the package it is removing; the double records
        // its answer, and deletes only on yes.
        let answer = await FreeingCheck.current?(package.url) ?? true
        lock.withLock { lastLooks[package.bookID] = answer }
        guard answer else { throw BookCloudError.syncRemoval(.busy) }
        if let action = lock.withLock({ afterYes }) { await action(package.bookID) }
        try fake.removeDownload(of: package)
    }
}

/// A box a test changes and a closure reads.
@MainActor
private final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// The room notices the commands gave, in order.
@MainActor
private final class RoomLog {
    var counts: [Int] = []
}

/// Whether the network path costs, which a test sets.
private final class CostlyStandIn: @unchecked Sendable {
    private let lock = NSLock()
    private var costly = false
    var value: Bool {
        get { lock.withLock { costly } }
        set { lock.withLock { costly = newValue } }
    }
}

/// The arrival date the commands read for every package, which a test sets.
private final class ArrivalStandIn: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date?
    func set(_ new: Date?) { lock.withLock { date = new } }
    var current: Date? { lock.withLock { date } }
}

/// The library's cloud commands for a synced library, with a storage that records the proof asked for.
@MainActor
private final class SpaceFixture {
    /// What a removal asked the storage for.
    struct Proof: Equatable {
        var bookID: UUID
        var mayDownload: Bool
    }

    /// The time the fixture's clock starts at.
    static let start = Date(timeIntervalSince1970: 1_790_000_000)

    let states = BookCloudStates()
    let kept = KeptBooks(file: nil)
    let fake = FakeBookCloudStorage(location: .local)
    let storage: ProvingStorage
    let model = LibraryViewModel(initializeServices: false)
    let commands: LibraryCloudCommands
    let refreshRequests = RequestCounter()
    let clock = CommandClock()
    let space = FreeSpaceStandIn()
    let rooms = RoomLog()
    let choice = Box(BooksOnThisDevice.allBooks)
    let arrivals = ArrivalStandIn()
    /// Whether the network path costs, as the commands read it.
    let costly = CostlyStandIn()
    /// The settings the commands read again just before a removal deletes.
    let settingsNow = Box(SyncDeviceSettings(books: .openedOrKept, removeAfterDays: 7, removalsBeganAt: nil))
    /// The books a person freed, kept in a sandbox.
    let freed: BooksFreedOnPurpose

    /// A synced library of `books`, each recorded as `recorded` when one is given.
    init(books: [Book], recorded: BookCloudState? = nil) {
        let storage = ProvingStorage(fake)
        self.storage = storage
        let states = states
        let refreshRequests = refreshRequests
        let clock = clock
        let space = space
        let rooms = rooms
        let choice = choice
        let arrivals = arrivals
        let costly = costly
        let settingsNow = settingsNow
        let freed = BooksFreedOnPurpose(store: UserDefaults(suiteName: "SyncSpaceFixture-\(UUID().uuidString)") ?? .standard)
        self.freed = freed
        commands = LibraryCloudCommands(
            states: states,
            kept: kept,
            storage: { storage },
            refreshAfterRemoval: { refreshRequests.count += 1 },
            revealInFinder: { _ in },
            now: { clock.now },
            freeSpace: { _ in space.next() },
            booksChoice: { choice.value },
            roomNotice: { rooms.counts.append($0) },
            packageArrival: { _ in arrivals.current },
            pathIsCostly: { costly.value },
            currentSettings: { settingsNow.value },
            freedOnPurpose: { freed }
        )
        clock.now = Self.start
        model.library = Library(books: books)
        states.setSyncIsOn(true)
        if let recorded {
            for book in books {
                states.record(recorded, for: book.id)
                fake.setState(recorded, of: book.id)
            }
        }
    }

    /// Settings under which the removal applies for `days`, from the day it began (30 days before the clock by default).
    func settings(days: Int, began: Date? = nil) -> SyncDeviceSettings {
        SyncDeviceSettings(books: .openedOrKept, removeAfterDays: days, removalsBeganAt: began ?? Self.start.addingTimeInterval(-30 * SyncSpacePolicy.secondsInDay))
    }

    /// Runs the person's Remove Download for `books`.
    func commandsRemoving(_ books: [Book]) async -> LibraryCloudRefusal? {
        await commands.removeDownloads(of: books, in: model, from: nil)
    }

    /// One sweep over the model's books.
    func sweep(
        settings: SyncDeviceSettings, mayDownload: Bool = true, isProtected: @escaping @MainActor @Sendable (Book) -> Bool = { _ in false }
    ) async -> LibraryCloudCommands.UnopenedRemovalReport {
        settingsNow.value = settings
        return await commands.removeUnopenedDownloads(
            of: model.library.books, in: model, settings: settings, mayDownload: mayDownload, isProtected: isProtected
        )
    }
}
