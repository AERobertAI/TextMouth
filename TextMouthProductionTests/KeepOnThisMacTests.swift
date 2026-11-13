import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// Keep on This Mac (FR02 polish): the set of books this Mac keeps
/// downloaded is this Mac's own, saved in its own folder and never in the
/// library, which every Mac reads. In a cloud library each row offers to
/// keep its book or stop keeping it; a kept book in the cloud downloads at
/// once, downloads again whenever a refresh finds it evicted, refuses Remove
/// Download, and says "Kept on this Mac" after its cloud note, while the
/// summary bar counts the kept books.
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

    /// A damaged choice file reads the choice as on, so the reading list's
    /// books stay kept, and the log line says that, not that no book is kept,
    /// which is what a damaged file of kept books does.
    func testADamagedChoiceFileSaysWhatReallyHappens() throws {
        let folder = try makeSandboxDirectory("KeepChoiceDamaged")
        let file = folder.appendingPathComponent("Keep Reading List Books.json")
        try Data("{\"keepsReadingL".utf8).write(to: file)

        let kept = KeptBooks(file: nil, settingFile: file)
        kept.setReadingListBooks([UUID()])

        XCTAssertTrue(kept.keepsReadingListBooks, "an unreadable choice file did not read as on")
        XCTAssertTrue(kept.keepsAnyBook, "the reading list's books are not kept")
        let lines = debugLogLines(containing: "could not read Keep Reading List Books.json")
        XCTAssertTrue(
            lines.contains {
                $0.contains(
                    "the choice reads as on, so the reading list's books stay kept on this Mac until it is cleared again"
                )
            },
            "\(lines)"
        )
        XCTAssertFalse(lines.contains { $0.contains("no book is kept on this Mac") }, "\(lines)")
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

    // MARK: - The Row's Note and the Summary

    /// A kept book's row says "Kept on this Mac" right after its cloud note,
    /// whatever the state, and a row not kept reads as before.
    func testAKeptRowSaysSoAfterItsCloudNote() {
        let book = readBook()
        let partway = BookDownloadProgress(completedFiles: 2, totalFiles: 5, completedBytes: 400, totalBytes: 1_000)
        let expected: [(BookCloudState, String)] = [
            (.downloaded, "Moby-Dick, by Herman Melville, Downloaded, Kept on this Mac, 42 percent, EPUB"),
            (.inCloud, "Moby-Dick, by Herman Melville, In Cloud, Kept on this Mac, 42 percent, EPUB"),
            (
                .downloading(partway),
                "Moby-Dick, by Herman Melville, Downloading, 40 percent, Kept on this Mac, 42 percent read, EPUB"
            ),
            (.waitingForSync, "Moby-Dick, by Herman Melville, Waiting for Sync, Kept on this Mac, 42 percent, EPUB"),
        ]
        for (state, label) in expected {
            XCTAssertEqual(BookRow(book: book, cloudState: state, isKeptOnThisMac: true).rowAccessibilityLabel, label)
        }
        XCTAssertEqual(
            BookRow(book: book, cloudState: .downloaded).rowAccessibilityLabel,
            "Moby-Dick, by Herman Melville, Downloaded, 42 percent, EPUB"
        )
    }

    /// The list says a book is kept only in a cloud library, where its rows
    /// have cloud notes; elsewhere a kept book's row reads as any other.
    func testTheListSaysKeptOnlyInACloudLibrary() {
        let book = cloudTestBook()
        let kept = KeptBooks(file: nil)
        kept.keep([book.id])
        let states = BookCloudStates()

        for location in [StorageLocation.local, .otherVolume(name: "Archive Disk")] {
            states.setLibraryLocation(location)
            XCTAssertFalse(states.listsAsKept(book.id, in: kept), "\(location)")
            XCTAssertEqual(states.countKept([book], in: kept), 0, "\(location)")
        }
        states.setLibraryLocation(.cloud(.googleDrive))
        XCTAssertTrue(states.listsAsKept(book.id, in: kept))
        XCTAssertFalse(states.listsAsKept(UUID(), in: kept))
        XCTAssertEqual(states.countKept([book, cloudTestBook("Emma")], in: kept), 1)
    }

    /// The summary bar shows and speaks how many books are kept on this Mac,
    /// after how many are in the cloud, and says nothing of it when none is.
    func testTheSummaryCountsTheKeptBooks() {
        let books = [cloudTestBook(), cloudTestBook("Emma"), cloudTestBook("Dracula")]

        XCTAssertEqual(
            TimeRemainingBar(books: books, wpm: 200, booksInCloud: 1, booksKept: 2).summaryAccessibilityLabel,
            "3 books. 3 books have not been opened yet. 1 book is in the cloud. 2 books are kept on this Mac"
        )
        XCTAssertEqual(
            TimeRemainingBar(books: books, wpm: 200, booksKept: 1).summaryAccessibilityLabel,
            "3 books. 3 books have not been opened yet. 1 book is kept on this Mac"
        )
        XCTAssertEqual(
            TimeRemainingBar(books: books, wpm: 200, booksInCloud: 2).summaryAccessibilityLabel,
            "3 books. 3 books have not been opened yet. 2 books are in the cloud"
        )
        XCTAssertEqual(TimeRemainingBar.keptCountText(1), "1 book kept on this Mac")
        XCTAssertEqual(TimeRemainingBar.keptCountText(4), "4 books kept on this Mac")
    }

    /// The note's picture exists in SF Symbols, so no row draws an empty
    /// space where it belongs.
    func testTheKeptNotesPictureExists() {
        XCTAssertNotNil(NSImage(systemSymbolName: KeptOnThisMacNote.symbolName, accessibilityDescription: nil))
    }

    /// Hosted in a window, a kept book's row is one element whose label says
    /// it is kept, after its cloud note; when SwiftUI also exposes the row's
    /// VoiceOver actions, which it does only for an assistive app, they name
    /// the command that stops keeping it.
    func testAHostedKeptRowSpeaksItsNote() throws {
        let book = readBook()
        let states = BookCloudStates()
        states.setLibraryLocation(.cloud(.iCloudDrive))
        states.record(.downloaded, for: book.id)
        let commands = LibraryCloudCommand.commands(for: [book], isSelection: false, states: states, kept: [book.id])
        let row = BookRow(book: book, cloudState: .downloaded, isKeptOnThisMac: true, cloudCommands: commands)
        let label = row.rowAccessibilityLabel
        XCTAssertEqual(label, "Moby-Dick, by Herman Melville, Downloaded, Kept on this Mac, 42 percent, EPUB")
        // The label above is checked without a window; what follows reads
        // SwiftUI's own elements in-process.
        try skipUnlessSwiftUIExposesItsOwnElements()

        try withHostedView(row, until: { !self.accessibilityElements(labelled: label, in: $0).isEmpty }) { hostingView in
            let found = accessibilityElements(labelled: label, in: hostingView)
            guard let element = found.first else {
                throw XCTSkip("SwiftUI exposed no accessibility elements without an assistive app")
            }
            XCTAssertEqual(found.count, 1, "the row is one element")
            let actions = (element.accessibilityCustomActions() ?? []).map(\.name)
            if !actions.isEmpty {
                XCTAssertEqual(actions, ["Remove Download", "Stop Keeping on This Mac", "Show in Finder"])
            }
        }
    }

    // MARK: - The Library Menu

    /// Library > Keep on This Mac keeps the selected books not kept yet,
    /// and downloads those in the cloud, as a row's command does.
    func testTheMenuKeepsTheSelectedBooks() async {
        let books = [cloudTestBook("Moby-Dick"), cloudTestBook("Emma", author: "Jane Austen")]
        let fixture = CommandFixture(books: books, states: [books[0].id: .inCloud, books[1].id: .downloaded])
        fixture.kept.keep([books[1].id])

        let said = await announcements {
            await fixture.commands.setKeptFromMenu(true, for: books, in: fixture.model, from: nil)?.value
        }

        XCTAssertEqual(fixture.kept.bookIDs, Set(books.map(\.id)))
        XCTAssertEqual(fixture.fake.downloadsStarted, [books[0].id])
        XCTAssertEqual(said, ["Keeping Moby-Dick on this Mac. Downloading it now", "Moby-Dick downloaded"])
    }

    /// Library > Stop Keeping on This Mac stops keeping the selected books
    /// that are kept, and only those.
    func testTheMenuStopsKeepingTheSelectedBooks() async {
        let books = [cloudTestBook("Moby-Dick"), cloudTestBook("Emma", author: "Jane Austen"), cloudTestBook("Dracula")]
        let fixture = CommandFixture(books: books, states: Dictionary(uniqueKeysWithValues: books.map {
            ($0.id, BookCloudState.downloaded)
        }))
        fixture.kept.keep([books[0].id, books[2].id])

        let said = await announcements {
            fixture.commands.setKeptFromMenu(false, for: Array(books.prefix(2)), in: fixture.model, from: nil)
        }

        XCTAssertEqual(fixture.kept.bookIDs, [books[2].id])
        XCTAssertEqual(said, ["Stopped keeping Moby-Dick on this Mac"])
    }

    /// When the menu's command can change nothing, VoiceOver hears why: no
    /// book is selected, every one is already as asked, or the library isn't
    /// in the cloud.
    func testTheMenuSaysWhyNothingChanged() async {
        let books = [cloudTestBook("Moby-Dick"), cloudTestBook("Emma", author: "Jane Austen")]
        let fixture = CommandFixture(books: books, states: [books[0].id: .downloaded, books[1].id: .downloaded])

        let said = await announcements {
            fixture.commands.setKeptFromMenu(true, for: [], in: fixture.model, from: nil)
            fixture.commands.setKeptFromMenu(false, for: books, in: fixture.model, from: nil)
            fixture.kept.keep([books[0].id])
            fixture.commands.setKeptFromMenu(true, for: [books[0]], in: fixture.model, from: nil)
            fixture.states.setLibraryLocation(.local)
            fixture.commands.setKeptFromMenu(true, for: books, in: fixture.model, from: nil)
        }

        XCTAssertEqual(said, [
            "No books are selected.",
            "None of the 2 selected books is kept on this Mac.",
            "Moby-Dick is already kept on this Mac.",
            "The library isn't in a cloud folder, so its books are always on this Mac.",
        ])
        XCTAssertEqual(fixture.kept.bookIDs, [books[0].id])
        XCTAssertEqual(fixture.fake.downloadsStarted, [])
    }

    /// The menu's refusals cover one book and several, either way.
    func testTheMenusRefusalsAreWordedForOneBookOrSeveral() {
        XCTAssertEqual(
            LibraryCloudWording.keepMenuRefusal(keeping: false, selected: ["Emma"], inCloudLibrary: true),
            "Emma isn't kept on this Mac."
        )
        XCTAssertEqual(
            LibraryCloudWording.keepMenuRefusal(keeping: true, selected: ["Emma", "Dracula"], inCloudLibrary: true),
            "The 2 selected books are already kept on this Mac."
        )
        XCTAssertEqual(
            LibraryCloudWording.keepMenuRefusal(keeping: false, selected: [], inCloudLibrary: false),
            "The library isn't in a cloud folder, so its books are always on this Mac."
        )
    }

    /// The Library menu names its commands as a row's menu does for one
    /// book.
    func testTheLibraryMenuNamesItsCommandsAsTheRowsDo() {
        XCTAssertEqual(LibraryCloudWording.keepName, "Keep on This Mac")
        XCTAssertEqual(LibraryCloudWording.stopKeepingName, "Stop Keeping on This Mac")
        XCTAssertEqual(LibraryCloudCommand.Kind.keepOnThisMac.title(count: 1, forSelection: false), LibraryCloudWording.keepName)
        XCTAssertEqual(
            LibraryCloudCommand.Kind.stopKeepingOnThisMac.title(count: 1, forSelection: false),
            LibraryCloudWording.stopKeepingName
        )
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
    /// book keeps its download, and the window shows why and what to do in
    /// an alert. The refusal is shown, not said: nothing is announced
    /// besides (#2094).
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
        XCTAssertEqual(said, [], "the alert alone says it")
        XCTAssertEqual(fixture.fake.downloadsRemoved, [])
        XCTAssertEqual(fixture.states.state(of: book.id), .downloaded)
        XCTAssertEqual(fixture.storage.mainThreadCalls, 0)
    }

    /// In a selection, the books not kept lose their downloads, and the kept
    /// one keeps its own, with the reason shown once, by the alert, and
    /// nothing announced (#2094).
    func testRemoveDownloadOfASelectionSparesTheKeptBooks() async {
        let kept = cloudTestBook("Moby-Dick")
        let other = cloudTestBook("Emma", author: "Jane Austen")
        let fixture = CommandFixture(books: [kept, other], states: [kept.id: .downloaded, other.id: .downloaded])
        fixture.kept.keep([kept.id])

        var refusal: LibraryCloudRefusal?
        let said = await announcements {
            refusal = await fixture.commands.removeDownloads(of: [kept, other], in: fixture.model, from: nil)
        }

        XCTAssertEqual(said, [], "the alert alone says it")
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

    // MARK: - The Reading List's Books

    /// The reading list's books are kept while this Mac keeps them, apart
    /// from the books the listener kept: `contains` answers for the
    /// listener's own choice alone, `isKept` for either reason. A book that
    /// leaves the list stops being kept for it, a book the listener kept
    /// themselves stays kept, and clearing the choice keeps no list book.
    func testTheListsBooksAreKeptApartFromTheListenersOwn() {
        let (listed, both, own) = (UUID(), UUID(), UUID())
        let kept = KeptBooks(file: nil)
        kept.keep([both, own])
        kept.setReadingListBooks([listed, both])

        XCTAssertTrue(kept.keepsReadingListBooks, "on until cleared")
        XCTAssertEqual(kept.bookIDs, [both, own], "the list's books joined the listener's own choices")
        XCTAssertTrue(kept.isKept(listed))
        XCTAssertFalse(kept.contains(listed))
        XCTAssertTrue(kept.isKeptOnlyForReadingList(listed))
        XCTAssertTrue(kept.isKept(both))
        XCTAssertFalse(kept.isKeptOnlyForReadingList(both), "the listener's own choice keeps it too")
        XCTAssertTrue(kept.isKept(own))
        XCTAssertFalse(kept.isKept(UUID()))
        XCTAssertEqual(kept.count(of: [cloudTestBook(), cloudTestBook("Emma")]), 0)

        // A book that leaves the list stops being kept for it; the
        // listener's own keeps stay.
        kept.setReadingListBooks([both])
        XCTAssertFalse(kept.isKept(listed))
        XCTAssertTrue(kept.isKept(both))
        XCTAssertTrue(kept.isKept(own))

        // Clearing the choice keeps no list book, and keeps the others.
        kept.setReadingListBooks([listed, both])
        kept.setKeepsReadingListBooks(false)
        XCTAssertFalse(kept.isKept(listed))
        XCTAssertTrue(kept.isKept(both))
        XCTAssertTrue(kept.keepsAnyBook)
    }

    /// Stopping a keep leaves a book on the list kept for the list, and
    /// counting the kept books counts both reasons once each.
    func testStoppingAKeepLeavesAListBookKeptForTheList() {
        let (first, second) = (cloudTestBook(), cloudTestBook("Emma"))
        let kept = KeptBooks(file: nil)
        kept.keep([first.id])
        kept.setReadingListBooks([first.id, second.id])

        XCTAssertEqual(kept.count(of: [first, second, cloudTestBook("Dracula")]), 2)
        kept.stopKeeping([first.id])

        XCTAssertFalse(kept.contains(first.id))
        XCTAssertTrue(kept.isKept(first.id))
        XCTAssertTrue(kept.isKeptOnlyForReadingList(first.id))
        XCTAssertEqual(kept.count(of: [first, second]), 2)
    }

    /// The list's books never reach the file of kept books, which holds only
    /// what the listener chose; the choice to keep them is saved apart,
    /// beside it in this Mac's own folder, and read back by a new set. A
    /// choice never made reads as on, and so does an unreadable file, which
    /// is preserved beside itself.
    func testOnlyTheChoiceIsSavedNeverTheListsBooks() throws {
        let folder = try makeSandboxDirectory("KeptListChoice")
        let file = folder.appendingPathComponent("Kept Books.json")
        let settingFile = folder.appendingPathComponent("Keep Reading List Books.json")
        let (listed, chosen) = (UUID(), UUID())

        let kept = KeptBooks(file: file, settingFile: settingFile)
        kept.setReadingListBooks([listed])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the list's books were saved")
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingFile.path), "a choice never made was saved")
        kept.keep([chosen])
        kept.setReadingListBooks([listed, chosen])
        XCTAssertEqual(KeptBooks(file: file, settingFile: settingFile).bookIDs, [chosen])
        XCTAssertEqual(KeptBooks(file: file, settingFile: settingFile).readingListBookIDs, [])

        kept.setKeepsReadingListBooks(false)
        XCTAssertFalse(KeptBooks(file: file, settingFile: settingFile).keepsReadingListBooks)
        kept.setKeepsReadingListBooks(true)
        XCTAssertTrue(KeptBooks(file: file, settingFile: settingFile).keepsReadingListBooks)

        try Data("not json".utf8).write(to: settingFile)
        XCTAssertTrue(KeptBooks(file: file, settingFile: settingFile).keepsReadingListBooks)
        XCTAssertEqual(KeptBooks(file: file, settingFile: settingFile).bookIDs, [chosen], "the kept books went with it")
    }

    /// The choice is saved in this Mac's own folder, beside the kept books,
    /// never in the library or the reading list, which every Mac reads.
    func testTheChoiceLivesBesideTheKeptBooksInThisMacsFolder() throws {
        XCTAssertEqual(MachineLocalPaths.keepReadingListBooks.lastPathComponent, "Keep Reading List Books.json")
        XCTAssertEqual(
            MachineLocalPaths.keepReadingListBooks.deletingLastPathComponent(),
            MachineLocalPaths.keptBooks.deletingLastPathComponent()
        )
        // The reading list, which the library saves for every Mac, carries
        // nothing of it.
        let saved = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(ReadingList())) as? [String: Any]
        )
        XCTAssertEqual(Set(saved.keys), ["bookIDs", "continuation", "skipsFinished", "removesFinished"])
    }

    /// A list book that the sync service evicted downloads again after a
    /// refresh, as a kept book does; with the choice cleared, or in a library
    /// outside the cloud, nothing downloads. Nobody asked just then, so
    /// VoiceOver hears one notice of it, at medium priority, the first time
    /// and never again for the same book.
    func testAnEvictedListBookDownloadsAgainAfterARefresh() async {
        let book = cloudTestBook()
        let fixture = CommandFixture(books: [book], states: [book.id: .inCloud])
        fixture.kept.setReadingListBooks([book.id])
        let refresher = makeRefresher(for: fixture)

        let said = await announcementsWithPriority {
            await refresher.waitForRefreshes()
            await waitForPlanning(of: fixture.commands)
        }
        await waitUntil(fixture.states, records: .downloaded, for: book.id)

        XCTAssertEqual(fixture.fake.downloadsStarted, [book.id])
        XCTAssertEqual(said, [VoiceOverAnnouncement(message: "Downloading Moby-Dick", priority: .medium)])

        // Evicted again, it downloads again and says nothing more.
        fixture.fake.setState(.inCloud, of: book.id)
        fixture.states.record(.inCloud, for: book.id)
        let saidAgain = await announcements {
            refresher.requestRefresh()
            await refresher.waitForRefreshes()
            await waitForPlanning(of: fixture.commands)
            await waitUntil(fixture.states, records: .downloaded, for: book.id)
        }
        XCTAssertEqual(fixture.fake.downloadsStarted, [book.id, book.id])
        XCTAssertEqual(saidAgain, [])
    }

    /// The notice's words, word for word: the books that start, in the
    /// listener's own words or the quiet ones, and the books that found no
    /// room.
    func testTheReadingListDownloadNoticeIsWordedInOnePlace() {
        let notice = LibraryCloudWording.readingListDownloadsStarted(titles:short:quietly:)
        XCTAssertEqual(notice(["Moby-Dick"], 0, false), "Downloading Moby-Dick")
        XCTAssertEqual(notice(["Moby-Dick"], 0, true), "Downloading Moby-Dick")
        XCTAssertEqual(notice(["Moby-Dick", "Emma"], 0, false), "Downloading 2 books")
        XCTAssertEqual(notice(["Moby-Dick", "Emma"], 0, true), "Downloading 2 reading list books")
        XCTAssertEqual(
            notice(["Moby-Dick", "Emma"], 3, true),
            "Downloading 2 reading list books. There isn't enough free space for 3 more books"
        )
        XCTAssertEqual(
            notice(["Moby-Dick"], 1, true),
            "Downloading Moby-Dick. There isn't enough free space for 1 more book"
        )
        XCTAssertEqual(notice([], 1, true), "There isn't enough free space to download 1 reading list book")
        XCTAssertEqual(notice([], 4, false), "There isn't enough free space to download 4 reading list books")
    }

    /// Only the list books that fit in the free space, less the reserve an
    /// import leaves, start downloading; the notice says how many download
    /// and that space ran short, once, at medium priority. A refresh that
    /// finds the rest still short says nothing more, and they download,
    /// quietly, once space is free.
    func testOnlyTheListBooksThatFitStartDownloading() async {
        let books = [cloudTestBook("One"), cloudTestBook("Two"), cloudTestBook("Three")]
        let fixture = CommandFixture(books: books, states: Dictionary(uniqueKeysWithValues: books.map { ($0.id, .inCloud) }))
        for book in books {
            fixture.fake.setBytesToDownload(400_000_000, of: book.id)
        }
        // Room for two of the three, with the reserve left over.
        fixture.space.free = ArchiveLimits.standard.freeSpaceReserve + 900_000_000
        fixture.kept.setReadingListBooks(Set(books.map(\.id)))
        let refresher = makeRefresher(for: fixture)

        let said = await announcementsWithPriority {
            await refresher.waitForRefreshes()
            await waitForPlanning(of: fixture.commands)
            await waitUntil(fixture.states, records: .downloaded, for: books[1].id)
        }

        XCTAssertEqual(fixture.fake.downloadsStarted, [books[0].id, books[1].id], "a book that did not fit downloaded")
        XCTAssertEqual(
            said,
            [VoiceOverAnnouncement(
                message: "Downloading 2 reading list books. There isn't enough free space for 1 more book",
                priority: .medium
            )]
        )

        // Still short: the two downloads took 800 MB of the 900 free, as they
        // would on a real volume, so the third book still doesn't fit; the
        // refresh tries it again and says nothing.
        fixture.space.free = ArchiveLimits.standard.freeSpaceReserve + 100_000_000
        let saidAgain = await announcements {
            refresher.requestRefresh()
            await refresher.waitForRefreshes()
            await waitForPlanning(of: fixture.commands)
        }
        XCTAssertEqual(saidAgain, [])
        XCTAssertEqual(fixture.fake.downloadsStarted, [books[0].id, books[1].id])

        // Space is free again: the third book downloads, with no notice.
        fixture.space.free = ArchiveLimits.standard.freeSpaceReserve + 5_000_000_000
        let saidLast = await announcements {
            refresher.requestRefresh()
            await refresher.waitForRefreshes()
            await waitForPlanning(of: fixture.commands)
            await waitUntil(fixture.states, records: .downloaded, for: books[2].id)
        }
        XCTAssertEqual(fixture.fake.downloadsStarted, books.map(\.id))
        XCTAssertEqual(saidLast, [])
    }

    /// With less free than the reserve, no list book starts, whatever its
    /// size, and the notice says so.
    func testNoListBookStartsBelowTheReserve() async {
        let book = cloudTestBook()
        let fixture = CommandFixture(books: [book], states: [book.id: .inCloud])
        fixture.space.free = ArchiveLimits.standard.freeSpaceReserve - 1
        fixture.kept.setReadingListBooks([book.id])
        let refresher = makeRefresher(for: fixture)

        let said = await announcementsWithPriority {
            await refresher.waitForRefreshes()
            await waitForPlanning(of: fixture.commands)
        }

        XCTAssertEqual(fixture.fake.downloadsStarted, [])
        XCTAssertEqual(
            said,
            [VoiceOverAnnouncement(
                message: "There isn't enough free space to download 1 reading list book",
                priority: .medium
            )]
        )
        XCTAssertEqual(fixture.states.state(of: book.id), .inCloud, "the book showed a download that never started")
    }

    /// Clearing the choice keeps no list book downloaded, and a library
    /// outside the cloud downloads nothing for the list.
    func testNoListBookDownloadsWhenTheChoiceIsClearOrTheLibraryIsLocal() async {
        let book = cloudTestBook()
        let fixture = CommandFixture(books: [book], states: [book.id: .inCloud])
        fixture.kept.setReadingListBooks([book.id])
        fixture.kept.setKeepsReadingListBooks(false)
        XCTAssertNil(fixture.commands.downloadEvictedKeptBooks(in: fixture.model))

        fixture.kept.setKeepsReadingListBooks(true)
        fixture.fake.setLibraryLocation(.otherVolume(name: "Archive Disk"))
        let refresher = makeRefresher(for: fixture)
        await refresher.waitForRefreshes()

        XCTAssertNil(fixture.commands.downloadEvictedKeptBooks(in: fixture.model))
        XCTAssertEqual(fixture.fake.downloadsStarted, [])
    }

    /// A list book whose download failed waits the kept books' five minutes
    /// before a refresh tries it again, then downloads it.
    func testAFailedListBookWaitsBeforeTheNextTry() async {
        let book = cloudTestBook()
        let fixture = CommandFixture(books: [book], states: [book.id: .inCloud])
        fixture.kept.setReadingListBooks([book.id])
        fixture.fake.scriptDownload(of: book.id, steps: [], failingWith: .offline)
        let failure = BookCloudError.offline.explanation(in: .iCloudDrive)

        let refresher = makeRefresher(for: fixture)
        await refresher.waitForRefreshes()
        await waitUntil(fixture.states, records: .downloadFailed(failure), for: book.id)
        XCTAssertEqual(fixture.fake.downloadsStarted, [book.id])

        fixture.clock.advance(by: LibraryCloudCommands.keptBookRetryDelay - 1)
        refresher.requestRefresh()
        await refresher.waitForRefreshes()
        XCTAssertEqual(fixture.fake.downloadsStarted, [book.id], "tried again within the wait")

        fixture.clock.advance(by: 1)
        refresher.requestRefresh()
        await refresher.waitForRefreshes()
        await waitUntil(fixture.states, records: .downloaded, for: book.id)
        XCTAssertEqual(fixture.fake.downloadsStarted, [book.id, book.id])
    }

    /// Remove Download refuses a list book with a sentence of its own, word
    /// for word, that says it is on the reading list and how to let it go;
    /// a book the listener kept says the older words, whether or not it is
    /// on the list too.
    func testRemoveDownloadRefusesAListBookInItsOwnWords() async {
        let book = cloudTestBook()
        let fixture = CommandFixture(books: [book], states: [book.id: .downloaded])
        fixture.kept.setReadingListBooks([book.id])

        var refusal: LibraryCloudRefusal?
        let said = await announcements {
            refusal = await fixture.commands.removeDownloads(of: [book], in: fixture.model, from: nil)
        }

        XCTAssertEqual(
            refusal?.message,
            "The book is on the reading list, which this Mac keeps downloaded, so its download can't be removed. "
                + "Take it off the reading list, or clear Keep these books on this Mac in the Reading List's options first."
        )
        XCTAssertEqual(said, [], "the alert alone says it")
        XCTAssertEqual(fixture.fake.downloadsRemoved, [])
        XCTAssertEqual(fixture.states.state(of: book.id), .downloaded)

        // Kept by the listener too, it names both reasons at once, so the
        // advice never leads to a second refusal.
        fixture.kept.keep([book.id])
        let again = await fixture.commands.removeDownloads(of: [book], in: fixture.model, from: nil)
        XCTAssertEqual(
            again?.message,
            "The book is kept on this Mac, and is on the reading list, which this Mac keeps downloaded, "
                + "so its download can't be removed. Choose Stop Keeping on This Mac first. "
                + "Then take it off the reading list, or clear Keep these books on this Mac in the Reading List's options."
        )

        // Following it: after Stop Keeping, the list's refusal is the one the
        // first refusal ended on.
        fixture.commands.stopKeeping([book], from: nil)
        let last = await fixture.commands.removeDownloads(of: [book], in: fixture.model, from: nil)
        XCTAssertEqual(last?.message, BookCloudError.keptForReadingList.explanation(in: .iCloudDrive))
        XCTAssertTrue(
            again?.message.hasSuffix(
                "take it off the reading list, or clear Keep these books on this Mac in the Reading List's options."
            ) == true
        )
        XCTAssertEqual(fixture.fake.downloadsRemoved, [])
    }

    /// With the choice cleared, Remove Download takes a list book's download
    /// away; the list keeps nothing.
    func testRemoveDownloadWorksOnAListBookOnceTheChoiceIsClear() async {
        let book = cloudTestBook()
        let fixture = CommandFixture(books: [book], states: [book.id: .downloaded])
        fixture.kept.setReadingListBooks([book.id])
        fixture.kept.setKeepsReadingListBooks(false)

        let refusal = await fixture.commands.removeDownloads(of: [book], in: fixture.model, from: nil)

        XCTAssertNil(refusal)
        XCTAssertEqual(fixture.fake.downloadsRemoved, [book.id])
    }

    /// Stop Keeping on This Mac is offered only for a book the listener's
    /// own choice keeps; a book kept only for the list offers Keep on This
    /// Mac, which would make the keep their own, and nothing to stop.
    func testStopKeepingIsNotOfferedForAListBook() {
        let book = cloudTestBook()
        let states = BookCloudStates()
        states.setLibraryLocation(.cloud(.iCloudDrive))
        states.record(.downloaded, for: book.id)
        let kept = KeptBooks(file: nil)
        kept.setReadingListBooks([book.id])

        func kinds() -> [LibraryCloudCommand.Kind] {
            LibraryCloudCommand.commands(for: [book], isSelection: false, states: states, kept: kept.bookIDs).map(\.kind)
        }
        XCTAssertTrue(kinds().contains(.keepOnThisMac))
        XCTAssertFalse(kinds().contains(.stopKeepingOnThisMac))

        kept.keep([book.id])
        XCTAssertTrue(kinds().contains(.stopKeepingOnThisMac))
    }

    /// Stop Keeping in the Library menu, on a book only the reading list
    /// keeps, stops nothing and says so in words that agree with the book's
    /// row ("Kept on this Mac"): it is kept for the reading list, and how to
    /// let it go; never that it isn't kept.
    func testTheMenuStopsNothingForAListBook() async {
        let book = cloudTestBook()
        let fixture = CommandFixture(books: [book], states: [book.id: .downloaded])
        fixture.kept.setReadingListBooks([book.id])

        let said = await announcements {
            fixture.commands.setKeptFromMenu(false, for: [book], in: fixture.model, from: nil)
        }

        XCTAssertEqual(
            said,
            [
                "Moby-Dick is kept on this Mac for the reading list. "
                    + "To let it go, take it off the reading list, or clear Keep these books on this Mac in the Reading List's options.",
            ]
        )
        XCTAssertTrue(fixture.kept.isKept(book.id))
    }

    /// The same refusal for a selection, word for word: all kept for the
    /// list, some, and the plain words for a library outside the list's
    /// keep.
    func testTheMenusRefusalNamesTheReadingListsKeepForASelection() {
        let refusal = { (titles: [String], onlyList: Int) in
            LibraryCloudWording.keepMenuRefusal(
                keeping: false,
                selected: titles,
                inCloudLibrary: true,
                keptOnlyForReadingList: onlyList
            )
        }
        XCTAssertEqual(
            refusal(["Emma", "Dracula"], 2),
            "The 2 selected books are kept on this Mac for the reading list. "
                + "To let them go, take them off the reading list, or clear Keep these books on this Mac in the Reading List's options."
        )
        XCTAssertEqual(
            refusal(["Emma", "Dracula", "Ulysses"], 2),
            "None of the 3 selected books is kept on this Mac by your choice, and 2 are kept for the reading list. "
                + "To let them go, take them off the reading list, or clear Keep these books on this Mac in the Reading List's options."
        )
        XCTAssertEqual(
            refusal(["Emma", "Dracula"], 1),
            "None of the 2 selected books is kept on this Mac by your choice, and 1 is kept for the reading list. "
                + "To let it go, take it off the reading list, or clear Keep these books on this Mac in the Reading List's options."
        )
        XCTAssertEqual(refusal(["Emma"], 0), "Emma isn't kept on this Mac.")
    }

    /// Stop Keeping on a book kept for both reasons stops the listener's own
    /// keep and says the reading list still keeps it, since the book stays
    /// kept; a selection says how many.
    func testStopKeepingSaysWhenTheReadingListStillKeepsTheBook() async {
        let book = cloudTestBook()
        let plain = cloudTestBook("Emma")
        let fixture = CommandFixture(books: [book, plain], states: [book.id: .downloaded, plain.id: .downloaded])
        fixture.kept.keep([book.id, plain.id])
        fixture.kept.setReadingListBooks([book.id])

        let alone = await announcements { fixture.commands.stopKeeping([book], from: nil) }
        XCTAssertEqual(alone, ["Stopped keeping Moby-Dick on this Mac. The reading list still keeps it downloaded"])
        XCTAssertTrue(fixture.kept.isKept(book.id), "the list stopped keeping the book")
        XCTAssertFalse(fixture.kept.contains(book.id))

        fixture.kept.keep([book.id])
        let both = await announcements { fixture.commands.stopKeeping([book, plain], from: nil) }
        XCTAssertEqual(both, ["Stopped keeping 2 books on this Mac. The reading list still keeps 1 of them downloaded"])

        // The words themselves.
        XCTAssertEqual(
            LibraryCloudWording.stoppedKeeping(titles: ["Emma", "Dracula"], stillKept: 2),
            "Stopped keeping 2 books on this Mac. The reading list still keeps them downloaded"
        )
        XCTAssertEqual(LibraryCloudWording.stoppedKeeping(titles: ["Emma"]), "Stopped keeping Emma on this Mac")
    }

    /// A list book's row says "Kept on this Mac", as any kept book's does,
    /// and the summary counts it, in a cloud library only; Book Information
    /// adds the reason when the list alone keeps the book.
    func testAListBooksRowAndInformationSayItIsKept() {
        let book = cloudTestBook()
        let kept = KeptBooks(file: nil)
        kept.setReadingListBooks([book.id])
        let states = BookCloudStates()

        states.setLibraryLocation(.local)
        XCTAssertFalse(states.listsAsKept(book.id, in: kept))
        XCTAssertEqual(states.countKept([book], in: kept), 0)
        states.setLibraryLocation(.cloud(.googleDrive))
        XCTAssertTrue(states.listsAsKept(book.id, in: kept))
        XCTAssertEqual(states.countKept([book], in: kept), 1)
        XCTAssertTrue(states.listsAsKeptOnlyForReadingList(book.id, in: kept))
        XCTAssertEqual(KeptOnThisMacNote.text, "Kept on this Mac")
        XCTAssertEqual(KeptOnThisMacNote.forReadingListText, "Kept on this Mac for the reading list")

        let library = LibraryViewModel(initializeServices: false)
        library.library = Library(books: [book])
        func spoken() -> [String] {
            let facts = BookInfoFacts(
                book,
                library: library,
                wordsPerMinute: 200,
                cloudStates: states,
                keptBooks: kept,
                measuresFileSize: false
            )
            return LibraryInfoWording.fullParts(of: facts, now: Date(), calendar: Calendar.current, locale: Locale.current)
        }
        XCTAssertTrue(spoken().contains("Kept on this Mac for the reading list"))
        XCTAssertFalse(spoken().contains("Kept on this Mac"))

        // The listener's own keep says the plain words.
        kept.keep([book.id])
        XCTAssertTrue(spoken().contains("Kept on this Mac"))
        XCTAssertFalse(spoken().contains("Kept on this Mac for the reading list"))
    }

    /// The library model hands the list's books to the kept books one turn
    /// after the list changes, and downloads those only in the cloud,
    /// quietly: a book that reached the list through a sync downloads here.
    func testTheLibraryKeepsTheBooksThatReachTheList() async {
        let book = cloudTestBook()
        let other = cloudTestBook("Emma")
        let fixture = CommandFixture(books: [book, other], states: [book.id: .inCloud, other.id: .inCloud])
        fixture.model.cloudCommands = fixture.commands
        fixture.model.observeReadingListKeeping()
        await drainMainQueue()
        XCTAssertEqual(fixture.kept.readingListBookIDs, [])

        let said = await announcementsWithPriority {
            fixture.model.library.readingList = ReadingList(bookIDs: [book.id])
            await drainMainQueue()
            await waitForPlanning(of: fixture.commands)
            await waitUntil(fixture.states, records: .downloaded, for: book.id)
        }

        XCTAssertEqual(fixture.kept.readingListBookIDs, [book.id])
        XCTAssertEqual(fixture.fake.downloadsStarted, [book.id], "a book not on the list downloaded")
        XCTAssertEqual(
            said,
            [VoiceOverAnnouncement(message: "Downloading Moby-Dick", priority: .medium)],
            "a sync's books download with one notice, at medium priority"
        )

        // A book taken off the list is no longer kept for it, and nothing
        // is removed.
        fixture.model.library.readingList = ReadingList()
        await drainMainQueue()
        XCTAssertEqual(fixture.kept.readingListBookIDs, [])
        XCTAssertFalse(fixture.kept.isKept(book.id))
        XCTAssertEqual(fixture.fake.downloadsRemoved, [])
        XCTAssertEqual(fixture.states.state(of: book.id), .downloaded)
    }

    /// A book the listener adds to the list in a cloud library downloads at
    /// once, and only once when the library's observation follows. VoiceOver
    /// hears the add's own words at high priority, then one notice of the
    /// download at medium priority, which waits for them rather than cutting
    /// them off (as the import's follow-up does), then the download's end as
    /// Download Now's.
    func testABookTheListenerAddsDownloadsUnderOneNoticeAfterTheAdd() async {
        let book = cloudTestBook()
        let fixture = CommandFixture(books: [book], states: [book.id: .inCloud])
        fixture.model.cloudCommands = fixture.commands
        fixture.model.observeReadingListKeeping()
        await drainMainQueue()

        let said = await announcementsWithPriority {
            fixture.model.addToReadingList([book], announcingFrom: nil)
            await drainMainQueue()
            await waitForPlanning(of: fixture.commands)
            await waitUntil(fixture.states, records: .downloaded, for: book.id)
            await drainMainQueue()
        }

        XCTAssertEqual(
            Array(said.prefix(2)),
            [
                VoiceOverAnnouncement(
                    message: ReadingListWording.addedAnnouncement(added: [book.title], alreadyIn: 0),
                    priority: .high
                ),
                VoiceOverAnnouncement(message: "Downloading Moby-Dick", priority: .medium),
            ]
        )
        XCTAssertEqual(said.filter { $0.message.hasPrefix("Downloading") }.count, 1, "\(said)")
        XCTAssertEqual(fixture.fake.downloadsStarted, [book.id], "downloaded twice")
    }

    /// Adding books to the list checks the room as the refresh does: those
    /// that fit download, and the notice says that space ran short.
    func testAddingToTheListDownloadsOnlyWhatFits() async {
        let books = [cloudTestBook("One"), cloudTestBook("Two")]
        let fixture = CommandFixture(books: books, states: Dictionary(uniqueKeysWithValues: books.map { ($0.id, .inCloud) }))
        fixture.model.cloudCommands = fixture.commands
        for book in books {
            fixture.fake.setBytesToDownload(600_000_000, of: book.id)
        }
        fixture.space.free = ArchiveLimits.standard.freeSpaceReserve + 700_000_000

        let said = await announcementsWithPriority {
            fixture.model.addToReadingList(books, announcingFrom: nil)
            await waitForPlanning(of: fixture.commands)
            await waitUntil(fixture.states, records: .downloaded, for: books[0].id)
        }

        XCTAssertEqual(fixture.fake.downloadsStarted, [books[0].id])
        XCTAssertTrue(
            said.contains(VoiceOverAnnouncement(
                message: "Downloading One. There isn't enough free space for 1 more book",
                priority: .medium
            )),
            "\(said)"
        )
    }

    /// With the choice cleared, or outside the cloud, adding a book to the
    /// list downloads nothing.
    func testAddingToTheListDownloadsNothingWhenTheChoiceIsClearOrTheLibraryIsLocal() async {
        let book = cloudTestBook()
        let fixture = CommandFixture(books: [book], states: [book.id: .inCloud])
        fixture.model.cloudCommands = fixture.commands
        fixture.kept.setKeepsReadingListBooks(false)
        XCTAssertNil(fixture.commands.downloadBooksAddedToReadingList([book], in: fixture.model, from: nil))

        fixture.kept.setKeepsReadingListBooks(true)
        fixture.states.setLibraryLocation(.local)
        XCTAssertNil(fixture.commands.downloadBooksAddedToReadingList([book], in: fixture.model, from: nil))
        XCTAssertEqual(fixture.fake.downloadsStarted, [])
    }

    /// Turning the choice on keeps the list's books and downloads those only
    /// in the cloud; turning it off removes nothing.
    func testTurningTheChoiceOnDownloadsTheListsBooks() async {
        let book = cloudTestBook()
        let fixture = CommandFixture(books: [book], states: [book.id: .inCloud])
        fixture.model.cloudCommands = fixture.commands
        fixture.model.library.readingList = ReadingList(bookIDs: [book.id])
        fixture.kept.setReadingListBooks([book.id])
        fixture.kept.setKeepsReadingListBooks(false)

        // Checking the box says what it starts, at medium priority, after
        // VoiceOver's own "checked".
        let said = await announcementsWithPriority {
            fixture.model.setKeepsReadingListBooks(true)
            await waitForPlanning(of: fixture.commands)
            await waitUntil(fixture.states, records: .downloaded, for: book.id)
        }
        XCTAssertEqual(fixture.fake.downloadsStarted, [book.id])
        XCTAssertTrue(fixture.kept.keepsReadingListBooks)
        XCTAssertEqual(said, [VoiceOverAnnouncement(message: "Downloading Moby-Dick", priority: .medium)])

        fixture.model.setKeepsReadingListBooks(false)
        XCTAssertFalse(fixture.kept.keepsReadingListBooks)
        XCTAssertEqual(fixture.fake.downloadsRemoved, [])
        XCTAssertEqual(fixture.states.state(of: book.id), .downloaded)
    }

    // MARK: - Helpers

    /// An EPUB of Moby-Dick, opened before and 42 percent read, as the
    /// library rows' own tests describe it, so its label holds every part.
    private func readBook() -> Book {
        Book(
            title: "Moby-Dick",
            author: "Herman Melville",
            format: .epub,
            filePath: "/Keep on This Mac/Moby-Dick.epub",
            md5Hash: "",
            lastOpened: Date(),
            readingPosition: ReadingPosition(chapterIndex: 0, characterOffset: 0, globalCharacterOffset: 420),
            totalCharacterCount: 1_000
        )
    }

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
