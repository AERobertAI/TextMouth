import XCTest
@testable import TextMouth

/// Keep on This Mac (FR02 polish): the set of books this Mac keeps
/// downloaded is this Mac's own, saved in its own folder and never in the
/// library, which every Mac reads.
@MainActor
final class KeepOnThisMacTests: XCTestCase {

    // MARK: - The Set and Its File

    /// The set round-trips through its file: a new set made from the same
    /// file holds what the last one kept, and stopping keeping a book takes
    /// it out of the file too.
    func testTheSetRoundTripsThroughItsFile() throws {
        let file = try makeSandboxDirectory("KeptBooks").appendingPathComponent("Kept Books.json")
        let first = UUID()
        let second = UUID()

        let kept = KeptBooks(file: file)
        kept.keep([first, second])

        XCTAssertEqual(KeptBooks(file: file).bookIDs, [first, second])

        kept.stopKeeping([first])

        XCTAssertEqual(KeptBooks(file: file).bookIDs, [second])
    }

    /// The file lists the kept books' IDs in order, so the same set always
    /// writes the same bytes, and people can read it.
    func testTheFileListsTheIDsInOrder() throws {
        let file = try makeSandboxDirectory("KeptBooksOrder").appendingPathComponent("Kept Books.json")
        let ids = (0..<3).map { _ in UUID() }

        KeptBooks(file: file).keep(ids)

        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: [String]]
        XCTAssertEqual(saved?["books"], ids.map(\.uuidString).sorted())
    }

    /// With no file yet, as on this Mac's first launch, no book is kept,
    /// and nothing is written until a book is kept.
    func testNoFileKeepsNoBook() throws {
        let file = try makeSandboxDirectory("KeptBooksNone").appendingPathComponent("Kept Books.json")

        let kept = KeptBooks(file: file)

        XCTAssertTrue(kept.bookIDs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// A damaged file keeps no book, and is preserved beside itself before
    /// the next save replaces it, so nothing it held is lost.
    func testADamagedFileKeepsNoBookAndIsPreserved() throws {
        let folder = try makeSandboxDirectory("KeptBooksDamaged")
        let file = folder.appendingPathComponent("Kept Books.json")
        let damaged = Data("{\"books\": [\"0F".utf8)
        try damaged.write(to: file)

        let kept = KeptBooks(file: file)

        XCTAssertTrue(kept.bookIDs.isEmpty)
        let copies = LibraryIndexQuarantine.existingCopies(of: file)
        XCTAssertEqual(copies.count, 1, "the damaged file was not preserved")
        XCTAssertEqual(try copies.first.map { try Data(contentsOf: $0) }, damaged)

        kept.keep([UUID()])

        XCTAssertEqual(try copies.first.map { try Data(contentsOf: $0) }, damaged, "the preserved copy changed")
    }

    /// Keeping and stopping report the books they changed, and change
    /// nothing, writing nothing, for books already as asked.
    func testKeepingAndStoppingReportWhatChanged() throws {
        let file = try makeSandboxDirectory("KeptBooksChanges").appendingPathComponent("Kept Books.json")
        let first = UUID()
        let second = UUID()
        let kept = KeptBooks(file: file)

        XCTAssertEqual(kept.keep([first]), [first])
        XCTAssertEqual(kept.keep([first, second]), [second])
        XCTAssertEqual(kept.keep([first]), [])
        XCTAssertEqual(kept.stopKeeping([first, UUID()]), [first])
        XCTAssertEqual(kept.stopKeeping([first]), [])
        XCTAssertEqual(kept.bookIDs, [second])
    }

    /// The set counts the kept books among those it is given.
    func testTheSetCountsKeptBooks() {
        let books = [cloudTestBook("Moby-Dick"), cloudTestBook("Emma"), cloudTestBook("Dracula")]
        let kept = KeptBooks(file: nil)

        XCTAssertEqual(kept.count(of: books), 0)

        kept.keep([books[0].id, books[2].id, UUID()])

        XCTAssertEqual(kept.count(of: books), 2)
        XCTAssertTrue(kept.contains(books[0].id))
        XCTAssertFalse(kept.contains(books[1].id))
    }

    /// The app's set is saved in this Mac's own folder, which never syncs,
    /// and never in the data directory, which another Mac can open.
    func testTheAppsSetIsSavedInThisMacsOwnFolder() {
        let file = MachineLocalPaths.keptBooks
        XCTAssertEqual(KeptBooks.shared.file, file)
        XCTAssertEqual(file.deletingLastPathComponent().standardizedFileURL, MachineLocalPaths.root.standardizedFileURL)
        XCTAssertFalse(
            file.standardizedFileURL.path.hasPrefix(TextMouthPaths.root.standardizedFileURL.path + "/"),
            "the set must not sync with the library"
        )
    }

    // MARK: - Keep on This Mac

    /// Keeping a book that is only in the cloud downloads it at once, as
    /// Download Now does: its row shows "Downloading 0%" first, then
    /// "Downloaded", and VoiceOver hears one sentence for the keep and the
    /// download, then how the download ended.
    func testKeepingABookInTheCloudDownloadsItAtOnce() async {
        let book = cloudTestBook()
        let fixture = CommandFixture(books: [book], states: [book.id: .inCloud])

        var recorded: [BookCloudState?] = []
        let said = await announcements {
            recorded = await fixture.recordedStates(of: book.id) {
                await fixture.commands.keep([book], in: fixture.model, from: nil)?.value
            }
        }

        XCTAssertEqual(fixture.kept.bookIDs, [book.id])
        XCTAssertEqual(fixture.fake.downloadsStarted, [book.id])
        XCTAssertEqual(recorded, [.downloading(.notStarted), .downloaded])
        XCTAssertEqual(said, ["Keeping Moby-Dick on this Mac. Downloading it now", "Moby-Dick downloaded"])
        XCTAssertEqual(fixture.storage.mainThreadCalls, 0, "the download is asked for off the main thread")
    }

    /// Keeping a downloaded book downloads nothing; VoiceOver hears that it
    /// is kept.
    func testKeepingADownloadedBookDownloadsNothing() async {
        let book = cloudTestBook()
        let fixture = CommandFixture(books: [book], states: [book.id: .downloaded])

        var task: Task<Void, Never>?
        let said = await announcements {
            task = fixture.commands.keep([book], in: fixture.model, from: nil)
        }

        XCTAssertNil(task)
        XCTAssertEqual(fixture.kept.bookIDs, [book.id])
        XCTAssertEqual(fixture.fake.downloadsStarted, [])
        XCTAssertEqual(said, ["Keeping Moby-Dick on this Mac"])
    }

    /// Keeping a selection keeps every book and downloads those whose state
    /// lets them download, in the cloud or left there by a failed download;
    /// one waiting for sync is kept for when it arrives.
    func testKeepingASelectionDownloadsTheBooksInTheCloud() async {
        let books = [
            cloudTestBook("Moby-Dick"),
            cloudTestBook("Middlemarch", author: "George Eliot"),
            cloudTestBook("Bleak House", author: "Charles Dickens"),
            cloudTestBook("Cranford", author: "Elizabeth Gaskell"),
        ]
        let fixture = CommandFixture(books: books, states: [
            books[0].id: .inCloud,
            books[1].id: .downloadFailed("It failed."),
            books[2].id: .downloaded,
            books[3].id: .waitingForSync,
        ])

        let said = await announcements {
            await fixture.commands.keep(books, in: fixture.model, from: nil)?.value
        }

        XCTAssertEqual(fixture.kept.bookIDs, Set(books.map(\.id)))
        XCTAssertEqual(fixture.fake.downloadsStarted, [books[0].id, books[1].id])
        XCTAssertEqual(said, ["Keeping 4 books on this Mac. Downloading 2 of them now", "Downloaded 2 books"])
    }

    /// Keeping books kept already changes nothing and says nothing.
    func testKeepingAgainChangesNothing() async {
        let book = cloudTestBook()
        let fixture = CommandFixture(books: [book], states: [book.id: .inCloud])
        fixture.kept.keep([book.id])

        var task: Task<Void, Never>?
        let said = await announcements {
            task = fixture.commands.keep([book], in: fixture.model, from: nil)
        }

        XCTAssertNil(task)
        XCTAssertEqual(said, [])
        XCTAssertEqual(fixture.fake.downloadsStarted, [])
    }

    /// Stopping keeping a book leaves its download where it is, says so to
    /// VoiceOver, and lets Remove Download remove it again.
    func testStoppingKeepingReleasesTheBook() async {
        let book = cloudTestBook()
        let fixture = CommandFixture(books: [book], states: [book.id: .downloaded])
        fixture.kept.keep([book.id])

        let said = await announcements {
            fixture.commands.stopKeeping([book], from: nil)
            fixture.commands.stopKeeping([book], from: nil)
        }

        XCTAssertEqual(said, ["Stopped keeping Moby-Dick on this Mac"], "a book not kept says nothing more")
        XCTAssertTrue(fixture.kept.bookIDs.isEmpty)
        XCTAssertEqual(fixture.fake.downloadsRemoved, [], "stopping removes no download")
        XCTAssertEqual(fixture.states.state(of: book.id), .downloaded)

        let refusal = await fixture.commands.removeDownloads(of: [book], in: fixture.model, from: nil)

        XCTAssertNil(refusal)
        XCTAssertEqual(fixture.fake.downloadsRemoved, [book.id])
    }

    /// A kept book offers Stop Keeping on This Mac in its row's menu and
    /// VoiceOver actions, and a book not kept offers Keep on This Mac.
    func testTheRowOffersTheCommandForItsChoice() {
        let book = cloudTestBook()
        let fixture = CommandFixture(books: [book], states: [book.id: .downloaded])

        let notKept = LibraryCloudCommand.commands(for: [book], isSelection: false, states: fixture.states, kept: [])
        let kept = LibraryCloudCommand.commands(for: [book], isSelection: false, states: fixture.states, kept: [book.id])

        XCTAssertEqual(
            BookRow(book: book, cloudState: .downloaded, cloudCommands: notKept).accessibilityActionNames,
            ["Remove Download", "Keep on This Mac", "Show in Finder"]
        )
        XCTAssertEqual(
            BookRow(book: book, cloudState: .downloaded, cloudCommands: kept).accessibilityActionNames,
            ["Remove Download", "Stop Keeping on This Mac", "Show in Finder"]
        )
    }

    /// Keeping and stopping are logged under KEEP_ON_MAC, and the downloads
    /// a keep starts under tags of their own, apart from Download Now's.
    func testKeepingLogsUnderItsOwnTags() async {
        let marker = UUID().uuidString
        let arriving = cloudTestBook("Arriving \(marker)")
        let failing = cloudTestBook("Failing \(marker)")
        let fixture = CommandFixture(books: [arriving, failing], states: [arriving.id: .inCloud, failing.id: .inCloud])
        fixture.fake.scriptDownload(of: failing.id, steps: [], failingWith: .offline)

        _ = await announcements {
            await fixture.commands.keep([arriving, failing], in: fixture.model, from: nil)?.value
            fixture.commands.stopKeeping([arriving], from: nil)
        }

        let lines = debugLogLines(containing: marker)
        for tag in ["KEEP_ON_MAC", "KEPT_BOOK_DOWNLOAD_STARTED", "KEPT_BOOK_DOWNLOAD_FAILED"] {
            XCTAssertTrue(lines.contains { $0.contains(": \(tag): ") }, "\(tag) is missing from \(lines)")
        }
        XCTAssertEqual(lines.filter { $0.contains(": KEEP_ON_MAC: ") }.count, 2, "one line to keep, one to stop")
        XCTAssertFalse(lines.contains { $0.contains("DOWNLOAD_NOW") }, "a keep's downloads are not Download Now's")
    }

    // MARK: - Downloading Again After Eviction

    /// A kept book whose download the drive removes is downloaded again at
    /// the next cloud refresh, quietly: its row shows the download, and
    /// VoiceOver hears nothing, since nobody asked just then.
    func testAKeptBookEvictedIsDownloadedAgainAtTheNextRefresh() async {
        let book = cloudTestBook()
        let fixture = CommandFixture(books: [book], states: [book.id: .downloaded])
        fixture.kept.keep([book.id])
        let refresher = makeRefresher(for: fixture)
        await refresher.waitForRefreshes()
        XCTAssertEqual(fixture.fake.downloadsStarted, [], "a downloaded book needs nothing")

        // The drive removes the book's download.
        fixture.fake.setState(.inCloud, of: book.id)
        let said = await announcements {
            refresher.requestRefresh()
            await refresher.waitForRefreshes()
            await waitUntil(fixture.states, records: .downloaded, for: book.id)
        }

        XCTAssertEqual(fixture.fake.downloadsStarted, [book.id])
        XCTAssertEqual(said, [])
        XCTAssertEqual(fixture.storage.mainThreadCalls, 0)
    }

    /// A refresh downloads no book this Mac doesn't keep.
    func testARefreshDownloadsNoBookNotKept() async {
        let book = cloudTestBook()
        let fixture = CommandFixture(books: [book], states: [book.id: .inCloud])
        let refresher = makeRefresher(for: fixture)

        await refresher.waitForRefreshes()

        XCTAssertEqual(fixture.fake.downloadsStarted, [])
        XCTAssertEqual(fixture.states.state(of: book.id), .inCloud)
    }

    /// A kept book whose download failed waits before a refresh tries it
    /// again, so a Mac offline isn't asked every minute; once the wait is
    /// over, the next refresh downloads it.
    func testAFailedKeptBookWaitsBeforeTheNextTry() async {
        let book = cloudTestBook()
        let fixture = CommandFixture(books: [book], states: [book.id: .inCloud])
        fixture.kept.keep([book.id])
        fixture.fake.scriptDownload(of: book.id, steps: [], failingWith: .offline)
        let failure = BookCloudError.offline.explanation(in: .iCloudDrive)

        // The first refresh tries, and the download fails.
        let refresher = makeRefresher(for: fixture)
        await refresher.waitForRefreshes()
        await waitUntil(fixture.states, records: .downloadFailed(failure), for: book.id)
        XCTAssertEqual(fixture.fake.downloadsStarted, [book.id])

        // A refresh within the wait finds the book in the cloud and leaves it.
        fixture.clock.advance(by: LibraryCloudCommands.keptBookRetryDelay - 1)
        refresher.requestRefresh()
        await refresher.waitForRefreshes()
        XCTAssertEqual(fixture.states.state(of: book.id), .inCloud)
        XCTAssertEqual(fixture.fake.downloadsStarted, [book.id])

        // The first refresh after the wait downloads it.
        fixture.clock.advance(by: 1)
        refresher.requestRefresh()
        await refresher.waitForRefreshes()
        await waitUntil(fixture.states, records: .downloaded, for: book.id)
        XCTAssertEqual(fixture.fake.downloadsStarted, [book.id, book.id])
    }

    /// A kept book that hasn't arrived from the sync service yet is kept
    /// for when it does: the first refresh that finds it in the cloud
    /// downloads it.
    func testAKeptBookWaitingForSyncDownloadsOnceItArrives() async {
        let book = cloudTestBook()
        let fixture = CommandFixture(books: [book], states: [book.id: .waitingForSync])
        fixture.kept.keep([book.id])
        let refresher = makeRefresher(for: fixture)
        await refresher.waitForRefreshes()
        XCTAssertEqual(fixture.fake.downloadsStarted, [])

        fixture.fake.setState(.inCloud, of: book.id)
        refresher.requestRefresh()
        await refresher.waitForRefreshes()
        await waitUntil(fixture.states, records: .downloaded, for: book.id)

        XCTAssertEqual(fixture.fake.downloadsStarted, [book.id])
    }

    /// A library outside the cloud downloads nothing, kept or not: its
    /// books are always on this Mac.
    func testALibraryOutsideTheCloudDownloadsNothing() async {
        let book = cloudTestBook()
        let fixture = CommandFixture(books: [book], states: [book.id: .inCloud])
        fixture.kept.keep([book.id])
        fixture.fake.setLibraryLocation(.otherVolume(name: "Archive Disk"))
        let refresher = makeRefresher(for: fixture)

        await refresher.waitForRefreshes()

        XCTAssertNil(fixture.commands.downloadEvictedKeptBooks(in: fixture.model))
        XCTAssertEqual(fixture.fake.downloadsStarted, [])
    }

    // MARK: - Wording

    /// The commands' titles name one book plainly and count a selection's.
    func testTheTitlesCountASelection() {
        XCTAssertEqual(LibraryCloudWording.keepTitle(count: 1, forSelection: false), "Keep on This Mac")
        XCTAssertEqual(LibraryCloudWording.keepTitle(count: 1, forSelection: true), "Keep 1 Book on This Mac")
        XCTAssertEqual(LibraryCloudWording.keepTitle(count: 3, forSelection: true), "Keep 3 Books on This Mac")
        XCTAssertEqual(LibraryCloudWording.stopKeepingTitle(count: 1, forSelection: false), "Stop Keeping on This Mac")
        XCTAssertEqual(LibraryCloudWording.stopKeepingTitle(count: 2, forSelection: true), "Stop Keeping 2 Books on This Mac")
    }

    /// Keeping says which books, and how many of them download now.
    func testTheKeepAnnouncementSaysWhatDownloads() {
        XCTAssertEqual(LibraryCloudWording.keepStarted(titles: ["Emma"], downloading: 0), "Keeping Emma on this Mac")
        XCTAssertEqual(
            LibraryCloudWording.keepStarted(titles: ["Emma"], downloading: 1),
            "Keeping Emma on this Mac. Downloading it now"
        )
        XCTAssertEqual(
            LibraryCloudWording.keepStarted(titles: ["Emma", "Dracula"], downloading: 2),
            "Keeping 2 books on this Mac. Downloading them now"
        )
        XCTAssertEqual(
            LibraryCloudWording.keepStarted(titles: ["Emma", "Dracula", "Cranford"], downloading: 1),
            "Keeping 3 books on this Mac. Downloading 1 of them now"
        )
        XCTAssertEqual(LibraryCloudWording.stoppedKeeping(titles: ["Emma"]), "Stopped keeping Emma on this Mac")
        XCTAssertEqual(
            LibraryCloudWording.stoppedKeeping(titles: ["Emma", "Dracula"]),
            "Stopped keeping 2 books on this Mac"
        )
    }

    // MARK: - Remove Download

    /// Remove Download refuses a kept book without asking the storage: the
    /// book keeps its download, and the window shows, and VoiceOver hears,
    /// why and what to do.
    func testRemoveDownloadRefusesAKeptBook() async {
        let book = cloudTestBook()
        let fixture = CommandFixture(books: [book], states: [book.id: .downloaded])
        fixture.kept.keep([book.id])

        var refusal: LibraryCloudRefusal?
        let said = await announcements {
            refusal = await fixture.commands.removeDownloads(of: [book], in: fixture.model, from: nil)
        }

        let explanation = BookCloudError.keptOnThisMac.explanation(in: .iCloudDrive)
        XCTAssertEqual(refusal, LibraryCloudRefusal(title: "Download Not Removed", message: explanation))
        XCTAssertEqual(said, [explanation])
        XCTAssertEqual(fixture.fake.downloadsRemoved, [])
        XCTAssertEqual(fixture.states.state(of: book.id), .downloaded)
        XCTAssertEqual(fixture.storage.mainThreadCalls, 0)
    }

    /// In a selection, the books not kept lose their downloads, and the kept
    /// one keeps its own, with the reason said once.
    func testRemoveDownloadOfASelectionSparesTheKeptBooks() async {
        let kept = cloudTestBook("Moby-Dick")
        let other = cloudTestBook("Emma", author: "Jane Austen")
        let fixture = CommandFixture(books: [kept, other], states: [kept.id: .downloaded, other.id: .downloaded])
        fixture.kept.keep([kept.id])

        var refusal: LibraryCloudRefusal?
        _ = await announcements {
            refusal = await fixture.commands.removeDownloads(of: [kept, other], in: fixture.model, from: nil)
        }

        XCTAssertEqual(fixture.fake.downloadsRemoved, [other.id])
        XCTAssertEqual(fixture.states.state(of: other.id), .inCloud)
        XCTAssertEqual(fixture.states.state(of: kept.id), .downloaded)
        XCTAssertEqual(
            refusal?.message,
            "Removed the download of Emma. It stays in iCloud Drive. The download of Moby-Dick wasn't removed. "
                + BookCloudError.keptOnThisMac.explanation(in: .iCloudDrive)
        )
    }

    /// The refusal says why, and names the command that lifts it.
    func testTheRefusalNamesTheCommandThatLiftsIt() {
        XCTAssertEqual(
            BookCloudError.keptOnThisMac.explanation(in: .dropbox),
            "The book is kept on this Mac, so its download can't be removed. Choose Stop Keeping on This Mac first."
        )
    }

    // MARK: - Helpers

    /// A refresher over `fixture`'s store and storage, whose timer sleeps
    /// until the test wakes it, which it never does here, and which hands
    /// each refresh to the fixture's commands to download again the kept
    /// books it found in the cloud, as the app's refresher does. Its Library
    /// window appears now, which starts one refresh, and disappears when the
    /// test ends, which stops the timer.
    private func makeRefresher(for fixture: CommandFixture) -> LibraryCloudRefresher {
        let sleep = SteppedSleep()
        let storage = fixture.storage
        let commands = fixture.commands
        let refresher = LibraryCloudRefresher(
            states: fixture.states,
            storage: { storage },
            sleep: { try await sleep.sleep($0) },
            notificationCenter: NotificationCenter(),
            afterRefresh: { commands.downloadEvictedKeptBooks(in: $0) }
        )
        let window = UUID()
        refresher.libraryWindowAppeared(window, showing: fixture.model)
        addTeardownBlock { @MainActor in refresher.libraryWindowDisappeared(window) }
        return refresher
    }
}
