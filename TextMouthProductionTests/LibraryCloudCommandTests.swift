import Combine
import XCTest
@testable import TextMouth

/// The library list's cloud commands (FR02): which a book or a selection
/// offers, what they are called, and what they do and say. Download Now and
/// Remove Download appear only in a cloud library; Show in Finder in every
/// library. Commands act on the clicked book or on the selection it belongs
/// to, and their titles count the books they act on.
@MainActor
final class LibraryCloudCommandTests: XCTestCase {
    /// A download partway done.
    private let partway = BookDownloadProgress(completedFiles: 1, totalFiles: 2, completedBytes: 300, totalBytes: 900)

    // MARK: - Commands Offered

    /// A local library offers only Show in Finder, whatever was recorded,
    /// and whether or not the book is kept.
    func testLocalLibraryOffersOnlyShowInFinder() {
        let book = cloudTestBook()
        let states = BookCloudStates()
        states.record(.inCloud, for: book.id)

        XCTAssertEqual(
            titles(of: LibraryCloudCommand.commands(for: [book], isSelection: false, states: states, kept: [])),
            ["Show in Finder"]
        )
        XCTAssertEqual(
            titles(of: LibraryCloudCommand.commands(for: [book], isSelection: false, states: states, kept: [book.id])),
            ["Show in Finder"]
        )
    }

    /// In a cloud library each state offers its commands: Download Now for
    /// a book in the cloud or whose download failed, Remove Download for a
    /// downloaded one, Keep on This Mac for every book this Mac doesn't keep
    /// yet, and Show in Finder for every book whose package is on this Mac.
    /// A book not checked yet offers only Keep on This Mac and Show in
    /// Finder.
    func testCloudLibraryOffersCommandsByState() {
        let expected: [(BookCloudState?, [String])] = [
            (nil, ["Keep on This Mac", "Show in Finder"]),
            (.downloaded, ["Remove Download", "Keep on This Mac", "Show in Finder"]),
            (.inCloud, ["Download Now", "Keep on This Mac", "Show in Finder"]),
            (.downloadFailed("It failed."), ["Download Now", "Keep on This Mac", "Show in Finder"]),
            (.downloading(partway), ["Keep on This Mac", "Show in Finder"]),
            (.waitingForSync, ["Keep on This Mac"]),
            (.local, ["Keep on This Mac", "Show in Finder"]),
        ]
        for (state, commandTitles) in expected {
            let book = cloudTestBook()
            let states = cloudStates(recording: state.map { [book.id: $0] } ?? [:])

            XCTAssertEqual(
                titles(of: LibraryCloudCommand.commands(for: [book], isSelection: false, states: states, kept: [])),
                commandTitles,
                "\(String(describing: state))"
            )
        }
    }

    /// For a selection, each command acts on the books it suits and its
    /// title counts them, as "Move 3 Books to Folder…" does.
    func testSelectionCommandsActOnTheBooksTheySuit() {
        let books = [
            cloudTestBook("Moby-Dick"),
            cloudTestBook("Middlemarch", author: "George Eliot"),
            cloudTestBook("Bleak House", author: "Charles Dickens"),
            cloudTestBook("Cranford", author: "Elizabeth Gaskell"),
        ]
        let states = cloudStates(recording: [
            books[0].id: .inCloud,
            books[1].id: .downloadFailed("It failed."),
            books[2].id: .downloaded,
            books[3].id: .waitingForSync,
        ])

        let commands = LibraryCloudCommand.commands(for: books, isSelection: true, states: states, kept: [books[2].id])

        XCTAssertEqual(titles(of: commands), [
            "Download 2 Books",
            "Remove Download of 1 Book",
            "Keep 3 Books on This Mac",
            "Stop Keeping 1 Book on This Mac",
            "Show 3 Books in Finder",
        ])
        XCTAssertEqual(commands.map { $0.books.map(\.title) }, [
            ["Moby-Dick", "Middlemarch"],
            ["Bleak House"],
            ["Moby-Dick", "Middlemarch", "Cranford"],
            ["Bleak House"],
            ["Moby-Dick", "Middlemarch", "Bleak House"],
        ])
    }

    /// A selection of downloaded books removes all their downloads, and a
    /// selection of books in the cloud downloads them all; either can be
    /// kept on this Mac, or stop being kept, all together.
    func testSelectionTitlesCountEveryBook() {
        let books = [cloudTestBook("Moby-Dick"), cloudTestBook("Middlemarch"), cloudTestBook("Bleak House")]
        let downloaded = cloudStates(recording: Dictionary(uniqueKeysWithValues: books.map {
            ($0.id, BookCloudState.downloaded)
        }))
        let inCloud = cloudStates(recording: Dictionary(uniqueKeysWithValues: books.map {
            ($0.id, BookCloudState.inCloud)
        }))

        XCTAssertEqual(
            titles(of: LibraryCloudCommand.commands(for: books, isSelection: true, states: downloaded, kept: [])),
            ["Remove Downloads of 3 Books", "Keep 3 Books on This Mac", "Show 3 Books in Finder"]
        )
        XCTAssertEqual(
            titles(of: LibraryCloudCommand.commands(for: books, isSelection: true, states: inCloud, kept: Set(books.map(\.id)))),
            ["Download 3 Books", "Stop Keeping 3 Books on This Mac", "Show 3 Books in Finder"]
        )
    }

    // MARK: - Download Now

    /// Three steps of a download, by size.
    private let steps = [
        BookDownloadProgress(completedFiles: 0, totalFiles: 3, completedBytes: 100, totalBytes: 900),
        BookDownloadProgress(completedFiles: 1, totalFiles: 3, completedBytes: 400, totalBytes: 900),
        BookDownloadProgress(completedFiles: 2, totalFiles: 3, completedBytes: 800, totalBytes: 900),
    ]

    /// Download Now shows "Downloading 0%" at once, records each step of
    /// progress in order, then "Downloaded", and says when it starts and
    /// when it ends.
    func testDownloadNowRecordsProgressInOrderThenDownloaded() async {
        let book = cloudTestBook()
        let fixture = CommandFixture(books: [book], states: [book.id: .inCloud])
        fixture.fake.scriptDownload(of: book.id, steps: steps)

        var recorded: [BookCloudState?] = []
        let said = await announcements {
            recorded = await fixture.recordedStates(of: book.id) {
                await fixture.downloadAndWait([book])
            }
        }

        XCTAssertEqual(recorded, [.downloading(.notStarted)] + steps.map { .downloading($0) } + [.downloaded])
        XCTAssertEqual(said, ["Downloading Moby-Dick", "Moby-Dick downloaded"])
        XCTAssertEqual(fixture.fake.downloadsStarted, [book.id])
        XCTAssertTrue(fixture.commands.booksDownloading.isEmpty)
        XCTAssertEqual(fixture.storage.mainThreadCalls, 0, "the storage is never asked on the main thread")
    }

    /// Each way a download can fail records "Download Failed" with the
    /// failure's explanation, which the end announcement says after naming
    /// the book.
    func testEachDownloadFailureRecordsAndSaysItsExplanation() async {
        let failures: [BookCloudError] = [.offline, .stalled(seconds: 60), .provider("The account is full."), .packageMissing]
        for failure in failures {
            let book = cloudTestBook()
            let fixture = CommandFixture(books: [book], states: [book.id: .inCloud])
            fixture.fake.scriptDownload(of: book.id, steps: [steps[0]], failingWith: failure)
            let explanation = failure.explanation(in: .iCloudDrive)

            var recorded: [BookCloudState?] = []
            let said = await announcements {
                recorded = await fixture.recordedStates(of: book.id) {
                    await fixture.downloadAndWait([book])
                }
            }

            XCTAssertEqual(
                recorded,
                [.downloading(.notStarted), .downloading(steps[0]), .downloadFailed(explanation)],
                "\(failure)"
            )
            XCTAssertEqual(said, ["Downloading Moby-Dick", "Moby-Dick wasn't downloaded. " + explanation], "\(failure)")
        }
    }

    /// Download Now for a selection downloads its books one after another
    /// and says one summary as it starts and one as it ends.
    func testDownloadingASelectionSaysOneSummary() async {
        let books = [
            cloudTestBook("Moby-Dick"),
            cloudTestBook("Middlemarch", author: "George Eliot"),
            cloudTestBook("Bleak House", author: "Charles Dickens"),
        ]
        let fixture = CommandFixture(books: books, states: Dictionary(uniqueKeysWithValues: books.map {
            ($0.id, BookCloudState.inCloud)
        }))
        fixture.fake.scriptDownload(of: books[2].id, steps: [], failingWith: .offline)
        let offline = BookCloudError.offline.explanation(in: .iCloudDrive)

        let said = await announcements {
            await fixture.downloadAndWait(books)
        }

        XCTAssertEqual(said, ["Downloading 3 books", "Downloaded 2 books. Bleak House wasn't downloaded. " + offline])
        XCTAssertEqual(fixture.fake.downloadsStarted, books.map(\.id))
        XCTAssertEqual(
            books.map { fixture.states.state(of: $0.id) },
            [.downloaded, .downloaded, .downloadFailed(offline)]
        )
    }

    /// Every book of a Download Now shows "Downloading 0%" as soon as the
    /// command starts, while it waits for its turn.
    func testWaitingBooksShowAsDownloadingAtOnce() async {
        let books = [cloudTestBook("Moby-Dick"), cloudTestBook("Middlemarch"), cloudTestBook("Bleak House")]
        let fixture = CommandFixture(books: books, states: Dictionary(uniqueKeysWithValues: books.map {
            ($0.id, BookCloudState.inCloud)
        }))
        fixture.fake.scriptDownload(of: books[0].id, steps: [steps[0]], holdsOpen: true)

        let task = fixture.commands.download(books, in: fixture.model, from: nil)

        XCTAssertEqual(
            books.map { fixture.states.state(of: $0.id) },
            Array(repeating: .downloading(.notStarted), count: 3)
        )
        XCTAssertEqual(fixture.commands.booksDownloading, Set(books.map(\.id)))
        await waitUntil(fixture.states, records: .downloading(steps[0]), for: books[0].id)
        XCTAssertEqual(
            books.dropFirst().map { fixture.states.state(of: $0.id) },
            [.downloading(.notStarted), .downloading(.notStarted)],
            "the others wait their turn"
        )
        fixture.fake.finishHeldDownload(of: books[0].id)
        await task?.value
        XCTAssertEqual(books.map { fixture.states.state(of: $0.id) }, [.downloaded, .downloaded, .downloaded])
    }

    /// A book the list is downloading is not started again, and a book that
    /// is downloaded already is not started at all.
    func testOnlyBooksThatNeedItAreDownloaded() async {
        let inCloud = cloudTestBook("Moby-Dick")
        let downloaded = cloudTestBook("Middlemarch")
        let fixture = CommandFixture(books: [inCloud, downloaded], states: [
            inCloud.id: .inCloud,
            downloaded.id: .downloaded,
        ])
        fixture.fake.scriptDownload(of: inCloud.id, steps: [steps[0]], holdsOpen: true)

        let first = fixture.commands.download([inCloud], in: fixture.model, from: nil)
        XCTAssertNotNil(first)
        XCTAssertNil(fixture.commands.download([inCloud], in: fixture.model, from: nil), "it is downloading already")
        XCTAssertNil(fixture.commands.download([downloaded], in: fixture.model, from: nil), "it is downloaded")
        await waitUntil(fixture.states, records: .downloading(steps[0]), for: inCloud.id)
        fixture.fake.finishHeldDownload(of: inCloud.id)
        await first?.value

        XCTAssertEqual(fixture.fake.downloadsStarted, [inCloud.id])
        XCTAssertEqual(fixture.states.state(of: inCloud.id), .downloaded)
    }

    /// While the list downloads a book, a refresh leaves its progress alone,
    /// even when the storage reports the book in the cloud meanwhile.
    func testARefreshLeavesTheListsDownloadAlone() async {
        let book = cloudTestBook()
        let fixture = CommandFixture(books: [book], states: [book.id: .inCloud])
        fixture.fake.scriptDownload(of: book.id, steps: [steps[1]], holdsOpen: true)

        let task = fixture.commands.download([book], in: fixture.model, from: nil)
        await waitUntil(fixture.states, records: .downloading(steps[1]), for: book.id)
        await fixture.states.refresh([BookPackage(book)], using: fixture.fake)

        XCTAssertEqual(fixture.states.state(of: book.id), .downloading(steps[1]))
        fixture.fake.finishHeldDownload(of: book.id)
        await task?.value
        XCTAssertEqual(fixture.states.state(of: book.id), .downloaded)
    }

    /// A book removed from the library while it waits for its turn is
    /// skipped quietly, and the summary names only the books that ended.
    func testABookThatLeavesTheLibraryIsSkippedQuietly() async {
        let moby = cloudTestBook("Moby-Dick")
        let emma = cloudTestBook("Emma", author: "Jane Austen")
        let fixture = CommandFixture(books: [moby, emma], states: [moby.id: .inCloud, emma.id: .inCloud])
        fixture.fake.scriptDownload(of: moby.id, steps: [steps[0]], holdsOpen: true)

        let said = await announcements {
            let task = fixture.commands.download([moby, emma], in: fixture.model, from: nil)
            await waitUntil(fixture.states, records: .downloading(steps[0]), for: moby.id)
            fixture.model.library.books.removeAll { $0.id == emma.id }
            fixture.fake.finishHeldDownload(of: moby.id)
            await task?.value
        }

        XCTAssertEqual(said, ["Downloading 2 books", "Moby-Dick downloaded"])
        XCTAssertEqual(fixture.fake.downloadsStarted, [moby.id])
        XCTAssertTrue(fixture.commands.booksDownloading.isEmpty)
    }

    // MARK: - Remove Download

    /// Remove Download removes the book's local copy, records it in the
    /// cloud, asks for a refresh, and says where the book stays.
    func testRemoveDownloadSaysWhereTheBookStays() async {
        let book = cloudTestBook()
        let fixture = CommandFixture(books: [book], states: [book.id: .downloaded])

        var refusal: LibraryCloudRefusal?
        let said = await announcements {
            refusal = await fixture.commands.removeDownloads(of: [book], in: fixture.model, from: nil)
        }

        XCTAssertNil(refusal)
        XCTAssertEqual(said, ["Removed the download of Moby-Dick. It stays in iCloud Drive."])
        XCTAssertEqual(fixture.fake.downloadsRemoved, [book.id])
        XCTAssertEqual(fixture.states.state(of: book.id), .inCloud)
        XCTAssertEqual(fixture.refreshRequests.count, 1)
        XCTAssertEqual(fixture.storage.mainThreadCalls, 0, "the removal runs off the main thread")
    }

    /// A book open in a reader still offers Remove Download, which refuses
    /// without asking the storage, and shows why in an alert. The refusal is
    /// shown, not said: nothing is announced besides (#2094).
    func testRemoveDownloadRefusesAnOpenBook() async {
        let book = cloudTestBook()
        let fixture = CommandFixture(books: [book], states: [book.id: .downloaded])
        fixture.model.openBookIDs = [book.id]
        let explanation = BookCloudError.bookIsOpen.explanation(in: .iCloudDrive)

        XCTAssertEqual(
            LibraryCloudCommand.commands(for: [book], isSelection: false, states: fixture.states, kept: []).map(\.kind),
            [.removeDownload, .keepOnThisMac, .showInFinder]
        )
        var refusal: LibraryCloudRefusal?
        let said = await announcements {
            refusal = await fixture.commands.removeDownloads(of: [book], in: fixture.model, from: nil)
        }

        XCTAssertEqual(said, [], "the alert alone says it")
        XCTAssertEqual(refusal, LibraryCloudRefusal(title: "Download Not Removed", message: explanation))
        XCTAssertEqual(fixture.fake.downloadsRemoved, [])
        XCTAssertEqual(fixture.states.state(of: book.id), .downloaded)
        XCTAssertEqual(fixture.refreshRequests.count, 0, "nothing changed")
    }

    /// A book whose changes are not uploaded yet keeps its download, and the
    /// storage's refusal is shown, not said, naming the service.
    func testRemoveDownloadRefusesChangesNotUploaded() async {
        let book = cloudTestBook()
        let fixture = CommandFixture(books: [book], states: [book.id: .downloaded])
        fixture.fake.failRemoval(of: book.id, with: .notUploaded)
        let explanation = BookCloudError.notUploaded.explanation(in: .iCloudDrive)

        var refusal: LibraryCloudRefusal?
        let said = await announcements {
            refusal = await fixture.commands.removeDownloads(of: [book], in: fixture.model, from: nil)
        }

        XCTAssertEqual(said, [], "the alert alone says it")
        XCTAssertTrue(explanation.contains("iCloud Drive"), explanation)
        XCTAssertEqual(refusal, LibraryCloudRefusal(title: "Download Not Removed", message: explanation))
        XCTAssertEqual(fixture.states.state(of: book.id), .downloaded)
    }

    /// A removal the sync service fails is shown, not said, as a download
    /// that could not be removed, naming the service, never as a book that
    /// could not download; the book keeps its download.
    func testRemoveDownloadTheServiceFailsSaysTheRemovalFailed() async {
        let book = cloudTestBook()
        let fixture = CommandFixture(books: [book], states: [book.id: .downloaded])
        fixture.fake.failRemoval(of: book.id, with: .removalFailed("The file is locked."))
        let explanation = "iCloud Drive couldn't remove the book's download: The file is locked."

        var refusal: LibraryCloudRefusal?
        let said = await announcements {
            refusal = await fixture.commands.removeDownloads(of: [book], in: fixture.model, from: nil)
        }

        XCTAssertEqual(said, [], "the alert alone says it")
        XCTAssertEqual(refusal, LibraryCloudRefusal(title: "Download Not Removed", message: explanation))
        XCTAssertEqual(fixture.states.state(of: book.id), .downloaded)
    }

    /// For a selection, the books that can go are removed, and one summary
    /// says what was removed, where it stays, and which stayed and why. When
    /// any stayed, that one summary is shown in the refusal's alert, not
    /// said: nothing is announced besides (#2094).
    func testRemovingASelectionSaysOneSummary() async {
        let books = [
            cloudTestBook("Moby-Dick"),
            cloudTestBook("Emma", author: "Jane Austen"),
            cloudTestBook("Cranford", author: "Elizabeth Gaskell"),
        ]
        let fixture = CommandFixture(books: books, states: Dictionary(uniqueKeysWithValues: books.map {
            ($0.id, BookCloudState.downloaded)
        }))
        fixture.model.openBookIDs = [books[1].id]
        let open = BookCloudError.bookIsOpen.explanation(in: .iCloudDrive)
        let expected = "Removed the downloads of 2 books. They stay in iCloud Drive. "
            + "The download of Emma wasn't removed. " + open

        var refusal: LibraryCloudRefusal?
        let said = await announcements {
            refusal = await fixture.commands.removeDownloads(of: books, in: fixture.model, from: nil)
        }

        XCTAssertEqual(said, [], "the alert alone says it")
        XCTAssertEqual(refusal, LibraryCloudRefusal(title: "Download Not Removed", message: expected))
        XCTAssertEqual(fixture.fake.downloadsRemoved, [books[0].id, books[2].id])
        XCTAssertEqual(books.map { fixture.states.state(of: $0.id) }, [.inCloud, .downloaded, .inCloud])
    }

    /// Asking again while a removal runs removes nothing more: the second
    /// request finds the book's removal already in hand, and says nothing.
    func testRemovingTwiceAtOnceRemovesOnce() async {
        let book = cloudTestBook()
        let fixture = CommandFixture(books: [book], states: [book.id: .downloaded])
        let removing = expectation(description: "the first removal reaches the storage")
        fixture.storage.holdRemovals { removing.fulfill() }

        let first = Task { await fixture.commands.removeDownloads(of: [book], in: fixture.model, from: nil) }
        await fulfillment(of: [removing], timeout: 10)
        XCTAssertEqual(fixture.commands.booksBeingRemoved, [book.id])
        let second = await fixture.commands.removeDownloads(of: [book], in: fixture.model, from: nil)
        fixture.storage.releaseRemovals()
        let firstRefusal = await first.value

        XCTAssertNil(second)
        XCTAssertNil(firstRefusal)
        XCTAssertEqual(fixture.fake.downloadsRemoved, [book.id])
        XCTAssertTrue(fixture.commands.booksBeingRemoved.isEmpty)
    }

    /// Only downloaded books are removed: a book in the cloud has nothing to
    /// remove, so nothing happens and nothing is said.
    func testOnlyDownloadedBooksAreRemoved() async {
        let book = cloudTestBook()
        let fixture = CommandFixture(books: [book], states: [book.id: .inCloud])

        let said = await announcements {
            _ = await fixture.commands.removeDownloads(of: [book], in: fixture.model, from: nil)
        }

        XCTAssertEqual(said, [])
        XCTAssertEqual(fixture.fake.downloadsRemoved, [])
    }

    // MARK: - Logging

    /// Each command's start, its failures and refusals, and its end are
    /// events whose tags name the command, apart from the storage service's
    /// own CLOUD_DOWNLOAD lines.
    func testCommandsLogUnderTheirOwnTags() async {
        let marker = UUID().uuidString
        let failing = cloudTestBook("Failing \(marker)")
        let open = cloudTestBook("Open \(marker)")
        let fixture = CommandFixture(books: [failing, open], states: [failing.id: .inCloud, open.id: .downloaded])
        fixture.fake.scriptDownload(of: failing.id, steps: [], failingWith: .offline)
        fixture.model.openBookIDs = [open.id]

        _ = await announcements {
            await fixture.downloadAndWait([failing])
            _ = await fixture.commands.removeDownloads(of: [open], in: fixture.model, from: nil)
        }

        let lines = debugLogLines(containing: marker)
        for tag in ["DOWNLOAD_NOW_STARTED", "DOWNLOAD_NOW_FAILED", "REMOVE_DOWNLOAD_STARTED", "REMOVE_DOWNLOAD_REFUSED"] {
            XCTAssertTrue(lines.contains { $0.contains(": \(tag): ") }, "\(tag) is missing from \(lines)")
        }
        XCTAssertFalse(lines.contains { $0.contains("CLOUD_DOWNLOAD") }, "the service's tags are its own")
    }

    // MARK: - Show in Finder

    /// Show in Finder selects each book's package: its .tmb folder, or the
    /// file of an old book without one.
    func testShowInFinderSelectsEachBooksPackage() {
        var packaged = cloudTestBook("Moby-Dick")
        packaged.tmbDirectoryName = "Moby-Dick-Herman Melville-1-abc.tmb"
        let loose = cloudTestBook("Emma", author: "Jane Austen")
        let fixture = CommandFixture(books: [packaged, loose], states: [:])

        fixture.commands.showInFinder([packaged, loose])
        fixture.commands.showInFinder([])

        XCTAssertEqual(fixture.revealed.files, [[packaged.tmbDirectory, loose.bookFileURL]], "nothing is shown for no books")
    }

    // MARK: - Running From the List

    /// The list runs each command by its kind: Download Now starts the
    /// downloads, Remove Download hands back its refusal for the window,
    /// Keep on This Mac and Stop Keeping on This Mac change which books are
    /// kept, and Show in Finder selects the packages.
    func testPerformRunsEachKindOfCommand() async {
        let inCloud = cloudTestBook("Moby-Dick")
        let open = cloudTestBook("Emma", author: "Jane Austen")
        let fixture = CommandFixture(books: [inCloud, open], states: [inCloud.id: .inCloud, open.id: .downloaded])
        fixture.model.openBookIDs = [open.id]
        fixture.kept.keep([open.id])
        let commands = LibraryCloudCommand.commands(
            for: [inCloud, open],
            isSelection: true,
            states: fixture.states,
            kept: fixture.kept.bookIDs
        )
        XCTAssertEqual(
            commands.map(\.kind),
            [.download, .removeDownload, .keepOnThisMac, .stopKeepingOnThisMac, .showInFinder]
        )

        var refusals: [LibraryCloudRefusal?] = []
        _ = await announcements {
            for command in commands {
                refusals.append(await fixture.commands.perform(command, in: fixture.model, from: nil))
            }
            await waitUntil(fixture.states, records: .downloaded, for: inCloud.id)
        }

        XCTAssertEqual(refusals, [
            nil,
            LibraryCloudRefusal(
                title: "Download Not Removed",
                message: BookCloudError.bookIsOpen.explanation(in: .iCloudDrive)
            ),
            nil,
            nil,
            nil,
        ])
        XCTAssertEqual(fixture.fake.downloadsStarted, [inCloud.id], "keeping a book downloading already starts no second download")
        XCTAssertEqual(fixture.kept.bookIDs, [inCloud.id])
        XCTAssertEqual(fixture.revealed.files, [[inCloud.bookFileURL, open.bookFileURL]])
    }

    // MARK: - VoiceOver Actions

    /// A row's VoiceOver actions are its cloud commands, under the names its
    /// context menu gives them; a row without commands has none of its own.
    ///
    /// The row is checked through the list it builds: hosted offscreen
    /// without a screen reader, SwiftUI exposes no custom actions to read
    /// back (tried with `withHostedView`, a list, and a wait of 5 seconds).
    func testRowsVoiceOverActionsAreItsCloudCommands() {
        let book = cloudTestBook()
        let states = cloudStates(recording: [book.id: .inCloud])
        let commands = LibraryCloudCommand.commands(for: [book], isSelection: false, states: states, kept: [])

        XCTAssertEqual(
            BookRow(book: book, cloudState: .inCloud, cloudCommands: commands).accessibilityActionNames,
            ["Download Now", "Keep on This Mac", "Show in Finder"]
        )
        XCTAssertEqual(BookRow(book: book).accessibilityActionNames, [])
    }

    // MARK: - Wording

    /// A command that ended nothing says nothing.
    func testNothingEndedSaysNothing() {
        XCTAssertNil(LibraryCloudWording.downloadFinished(downloaded: [], failed: []))
        XCTAssertNil(LibraryCloudWording.removalFinished(removed: [], refused: [], provider: .dropbox))
    }

    /// The same reason for several books is said once.
    func testASharedReasonIsSaidOnce() {
        let offline = BookCloudError.offline.explanation(in: .googleDrive)

        XCTAssertEqual(
            LibraryCloudWording.downloadFinished(
                downloaded: [],
                failed: [(title: "Moby-Dick", explanation: offline), (title: "Emma", explanation: offline)]
            ),
            "2 books weren't downloaded: Moby-Dick and Emma. " + offline
        )
    }

    // MARK: - Helpers

    /// The titles of `commands`, in order.
    private func titles(of commands: [LibraryCloudCommand]) -> [String] {
        commands.map(\.title)
    }

    /// A store for a library in iCloud Drive with `recorded` states.
    private func cloudStates(recording recorded: [UUID: BookCloudState]) -> BookCloudStates {
        let states = BookCloudStates()
        states.setLibraryLocation(.cloud(.iCloudDrive))
        for (bookID, state) in recorded {
            states.record(state, for: bookID)
        }
        return states
    }
}

/// The library list's cloud commands with everything of their own: a store
/// and fake storage for a library in iCloud Drive whose books start in the
/// states given, a set of kept books in memory, empty at first, a clock the
/// test sets, and an inert library model holding the books. The storage
/// counts the calls made on the main thread, and the fixture counts the
/// refreshes the commands ask for.
@MainActor
final class CommandFixture {
    let states: BookCloudStates
    /// The books this Mac keeps downloaded, in memory only.
    let kept: KeptBooks
    let fake: FakeBookCloudStorage
    let storage: CountingBookCloudStorage
    let model: LibraryViewModel
    let commands: LibraryCloudCommands
    /// The refreshes the commands asked for.
    let refreshRequests: RequestCounter
    /// What the commands showed in Finder, one list of files each time.
    let revealed: RevealLog
    /// The time the commands read, which only the test moves.
    let clock: CommandClock
    /// The free space the commands read: roomy until a test narrows it.
    let space: FreeSpaceStandIn

    init(books: [Book], states recorded: [UUID: BookCloudState]) {
        let states = BookCloudStates()
        let kept = KeptBooks(file: nil)
        let fake = FakeBookCloudStorage(location: .cloud(.iCloudDrive))
        let storage = CountingBookCloudStorage(fake)
        let refreshRequests = RequestCounter()
        let revealed = RevealLog()
        let clock = CommandClock()
        let space = FreeSpaceStandIn()
        self.space = space
        self.states = states
        self.kept = kept
        self.fake = fake
        self.storage = storage
        self.refreshRequests = refreshRequests
        self.revealed = revealed
        self.clock = clock
        model = LibraryViewModel(initializeServices: false)
        commands = LibraryCloudCommands(
            states: states,
            kept: kept,
            storage: { storage },
            refreshAfterRemoval: { refreshRequests.count += 1 },
            revealInFinder: { revealed.files.append($0) },
            now: { clock.now },
            freeSpace: { _ in space.free }
        )
        model.library = Library(books: books)
        states.setLibraryLocation(.cloud(.iCloudDrive))
        for (bookID, state) in recorded {
            states.record(state, for: bookID)
            fake.setState(state, of: bookID)
        }
    }

    /// Runs Download Now for `books`, from no window, and waits until it
    /// has ended.
    func downloadAndWait(_ books: [Book]) async {
        await commands.download(books, in: model, from: nil)?.value
    }

    /// Every state recorded for the book `bookID` while `body` runs, in
    /// order, starting after the one it had before.
    func recordedStates(of bookID: UUID, during body: () async -> Void) async -> [BookCloudState?] {
        var recorded: [BookCloudState?] = []
        let subscription = states.$states
            .map { $0[bookID] }
            .removeDuplicates()
            .dropFirst()
            .sink { recorded.append($0) }
        await body()
        subscription.cancel()
        return recorded
    }
}

/// The free space on the library's volume as a test says it, in place of
/// the real volume's, which no test reads: a terabyte until a test sets
/// another figure, or nil for a volume that cannot tell. Read by the
/// commands off the main thread.
final class FreeSpaceStandIn: @unchecked Sendable {
    /// Guards `figure`.
    private let lock = NSLock()
    /// The bytes free.
    private var figure: Int64? = 1_000_000_000_000

    /// The figures the next reads return, one each, before `free` answers
    /// again: a volume that fills as the first download lands.
    private var scripted: [Int64?] = []
    /// How many times the free space was read.
    private var reads = 0

    /// The bytes free, or nil when the volume cannot tell. Each read is
    /// counted (`readCount`) and takes the next scripted figure, if any.
    var free: Int64? {
        get {
            lock.withLock {
                reads += 1
                return scripted.isEmpty ? figure : scripted.removeFirst()
            }
        }
        set { lock.withLock { figure = newValue } }
    }

    /// Makes the next reads return `figures`, one each, in order.
    func script(_ figures: [Int64?]) {
        lock.withLock { scripted = figures }
    }

    /// How many times the free space was read.
    var readCount: Int {
        lock.withLock { reads }
    }
}

/// Counts requests, such as the refreshes the commands ask for.
@MainActor
final class RequestCounter {
    /// How many requests were made.
    var count = 0
}

/// The files Show in Finder would have selected, instead of Finder.
@MainActor
final class RevealLog {
    /// One list of files for each time Finder was asked.
    var files: [[URL]] = []
}

/// A clock the cloud commands read, which only the test moves.
@MainActor
final class CommandClock {
    /// The time now, as the commands see it.
    var now = Date(timeIntervalSince1970: 1_790_000_000)

    /// Moves the time on by `seconds`.
    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}
