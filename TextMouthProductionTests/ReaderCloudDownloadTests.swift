import Combine
import SwiftUI
import XCTest
@testable import TextMouth

/// Opening a book that is in a cloud library (FR02): the reader checks the
/// book's state before reading it, downloads it first when any of its files
/// is only in the cloud, shows and speaks the download, and can cancel it or
/// try again; it never lets a read wait on the network, and checks each
/// chapter's file before it plays.
///
/// Every reader here is real, on real packages in a library folder of the
/// test's own; only the cloud is a fake (`FakeBookCloudStorage`), so each
/// test chooses the library's location, each book's state, and how each
/// download goes. Waiting is for what the reader does, never a fixed sleep.
@MainActor
final class ReaderCloudDownloadTests: XCTestCase {

    // MARK: - Routing by State

    /// In a library that is not in a cloud location, the book is read as
    /// it always was: its cloud state is never asked for or recorded,
    /// nothing downloads, and no working copy is made.
    func testBookInALocalLibraryLoadsAsBefore() throws {
        let cloud = try makeCloudReaders("Cloud Local Library", location: .local)
        let book = try makeTextBook("Quay Notes", in: cloud)
        cloud.storage.setState(.inCloud, of: book.id)

        let reader = cloud.open(book)
        waitForReaderToLoad(reader)

        XCTAssertNotNil(reader.content, "The book did not open")
        XCTAssertNil(reader.cloudPhase)
        XCTAssertNil(reader.cloudSession.location)
        XCTAssertEqual(cloud.storage.downloadsStarted, [])
        XCTAssertEqual(cloud.states.libraryLocation, .local)
        XCTAssertEqual(cloud.states.states, [:])
    }

    /// A downloaded book in a cloud library loads at once, and what the
    /// reader learned is recorded for the library list.
    func testDownloadedBookLoadsWithoutDownloading() throws {
        let cloud = try makeCloudReaders("Cloud Downloaded")
        let book = try makeTextBook("Quay Notes", in: cloud)
        cloud.storage.setState(.downloaded, of: book.id)

        let reader = cloud.open(book)
        waitForReaderToLoad(reader)

        XCTAssertNotNil(reader.content, "The book did not open")
        XCTAssertNil(reader.cloudPhase)
        XCTAssertEqual(reader.cloudSession.location, .cloud(.iCloudDrive))
        XCTAssertEqual(cloud.storage.downloadsStarted, [])
        XCTAssertEqual(cloud.states.libraryLocation, .cloud(.iCloudDrive))
        XCTAssertEqual(cloud.states.state(of: book.id), .downloaded)
    }

    /// A book with a file only in the cloud, one whose last download
    /// failed, and one the library list is downloading all download in the
    /// reader before they load; the reader's own wait for a download
    /// already running is harmless, since the sync service takes the same
    /// request once.
    func testBookNotWhollyHereDownloadsBeforeLoading() throws {
        let cloud = try makeCloudReaders("Cloud Downloads First")
        let states: [BookCloudState] = [
            .inCloud,
            .downloadFailed("iCloud Drive couldn't download the book: the server is busy."),
            .downloading(Self.progress(0, of: 2, bytes: 0, of: 200)),
        ]
        for (number, state) in states.enumerated() {
            let book = try makeTextBook("Quay Notes \(number + 1)", in: cloud)
            cloud.storage.setState(state, of: book.id)
            cloud.storage.scriptDownload(of: book.id, steps: [Self.progress(1, of: 2, bytes: 100, of: 200)])

            let reader = cloud.open(book)
            waitForReaderToLoad(reader)

            XCTAssertNotNil(reader.content, "\(state): the book did not open")
            XCTAssertEqual(cloud.storage.downloadsStarted.last, book.id, "\(state): nothing downloaded")
            XCTAssertEqual(cloud.states.state(of: book.id), .downloaded, "\(state)")
            XCTAssertNil(reader.cloudPhase, "\(state)")
        }
        XCTAssertEqual(cloud.storage.downloadsStarted.count, states.count)
    }

    /// A book whose package has not arrived says so, and offers Try Again,
    /// which opens it once it is here. Nothing is downloaded meanwhile.
    func testBookWaitingForSyncSaysSoUntilItArrives() throws {
        let cloud = try makeCloudReaders("Cloud Waiting For Sync")
        let book = try makeTextBook("Quay Notes", in: cloud)
        cloud.storage.setState(.waitingForSync, of: book.id)
        let mark = announcementMark()

        let reader = cloud.open(book)
        waitFor("the waiting message") { reader.cloudPhase == .waitingForSync }

        let message = "Quay Notes hasn't arrived on this Mac yet. iCloud Drive may still be syncing it."
        XCTAssertEqual(ReaderCloudWording.waitingForSync(title: book.title, provider: cloud.provider), message)
        XCTAssertEqual(announcements(since: mark), [message])
        XCTAssertEqual(cloud.storage.downloadsStarted, [])
        XCTAssertEqual(cloud.states.state(of: book.id), .waitingForSync)
        XCTAssertNil(reader.content)

        cloud.storage.setState(.downloaded, of: book.id)
        reader.retryOpening()
        waitForReaderToLoad(reader)

        XCTAssertNotNil(reader.content, "Try Again did not open the book")
        XCTAssertNil(reader.cloudPhase)
    }

    // MARK: - Progress and Announcements

    /// Each step of a download shows in the reader's download view and is
    /// recorded for the library list, in order, from the state the reader
    /// found to the end of the download.
    func testProgressIsShownAndRecordedInOrder() throws {
        let cloud = try makeCloudReaders("Cloud Progress")
        let book = try makeTextBook("Quay Notes", in: cloud)
        let steps = Self.quarterSteps
        cloud.storage.setState(.inCloud, of: book.id)
        cloud.storage.scriptDownload(of: book.id, steps: steps, holdsOpen: true)

        let reader = cloud.open(book)
        var shown: [BookDownloadProgress?] = []
        var recorded: [BookCloudState] = []
        let subscriptions = [
            reader.$cloudPhase.sink { phase in
                if case .downloading(let download)? = phase { shown.append(download.progress) }
            },
            cloud.states.$states.map { $0[book.id] }.removeDuplicates().sink { state in
                if let state { recorded.append(state) }
            },
        ]
        defer { subscriptions.forEach { $0.cancel() } }
        waitFor("every step to show") { shown.count == steps.count + 1 }

        let expectedShown: [BookDownloadProgress?] = [nil] + steps.map(Optional.some)
        let expectedRecorded: [BookCloudState] = [.inCloud] + steps.map { BookCloudState.downloading($0) }
        XCTAssertEqual(shown, expectedShown)
        XCTAssertEqual(recorded, expectedRecorded)
        XCTAssertEqual(reader.shownDownload?.provider, .iCloudDrive)
        XCTAssertNil(reader.shownDownload?.chapterNumber)

        cloud.storage.finishHeldDownload(of: book.id)
        waitForReaderToLoad(reader)

        XCTAssertEqual(recorded.last, .downloaded)
        XCTAssertNotNil(reader.content)
    }

    /// VoiceOver hears the download start, each quarter-way milestone once,
    /// and its end; the milestones at a lower priority, so they need not
    /// interrupt.
    func testDownloadAnnouncesItsStartMilestonesAndEnd() throws {
        let cloud = try makeCloudReaders("Cloud Announcements")
        let book = try makeTextBook("Quay Notes", in: cloud)
        cloud.storage.setState(.inCloud, of: book.id)
        cloud.storage.scriptDownload(of: book.id, steps: Self.quarterSteps + [Self.quarterSteps[3]])
        let mark = announcementMark()

        let reader = cloud.open(book)
        waitForReaderToLoad(reader)

        let heard = Array(VoiceOverAnnouncer.recordedAnnouncements.dropFirst(mark))
        XCTAssertEqual(heard.map(\.message), [
            "Downloading Quay Notes from iCloud Drive.",
            "25 percent downloaded.",
            "50 percent downloaded.",
            "75 percent downloaded.",
            "Downloaded. Loading.",
        ])
        XCTAssertEqual(heard.map(\.priority), [.high, .medium, .medium, .medium, .high])
    }

    /// A download without a percentage, such as one file still to come with
    /// nothing counted yet, is announced every so often (every 30 seconds in
    /// the app; this reader's interval is short) with the time waited, and
    /// its bar says the size and the time instead of a percentage.
    func testDownloadWithoutAPercentageIsAnnouncedEverySoOften() throws {
        let cloud = try makeCloudReaders("Cloud Quiet Download")
        cloud.quietAnnouncementInterval = 0.05
        let book = try makeTextBook("Quay Notes", in: cloud)
        let oneFile = Self.progress(0, of: 1, bytes: 0, of: 312_000_000)
        cloud.storage.setState(.inCloud, of: book.id)
        cloud.storage.scriptDownload(of: book.id, steps: [oneFile], holdsOpen: true)
        let mark = announcementMark()

        let reader = cloud.open(book)
        waitFor("the download's one step") { reader.shownDownload?.progress == oneFile }
        waitFor("two announcements of the wait") {
            self.announcements(since: mark).filter { $0.hasPrefix("Still downloading, ") }.count >= 2
        }

        let download = try XCTUnwrap(reader.shownDownload)
        XCTAssertNil(ReaderCloudWording.fraction(of: download))
        XCTAssertEqual(
            ReaderCloudWording.progressValue(of: download, elapsed: 65, spoken: true),
            "1 file left, 312 MB, 1 minute, 5 seconds elapsed"
        )
        XCTAssertTrue(announcements(since: mark).allSatisfy { !$0.contains("percent") })

        cloud.storage.finishHeldDownload(of: book.id)
        waitForReaderToLoad(reader)
        XCTAssertNil(reader.cloudSession.quietAnnouncementTask, "The announcements outlived the download")
    }

    // MARK: - Cancel

    /// Cancel stops waiting for the download, which the storage sees as the
    /// iteration ending, says the book isn't downloaded, offers Download and
    /// Close, and records the book's state as found afterwards. Download
    /// then downloads and opens it.
    func testCancelLeavesTheBookNotDownloadedUntilDownloadIsChosen() throws {
        let cloud = try makeCloudReaders("Cloud Cancel")
        let book = try makeTextBook("Quay Notes", in: cloud)
        let firstStep = Self.quarterSteps[0]
        cloud.storage.setState(.inCloud, of: book.id)
        cloud.storage.scriptDownload(of: book.id, steps: [firstStep], holdsOpen: true)

        let reader = cloud.open(book)
        waitFor("the download's first step") { reader.shownDownload?.progress == firstStep }
        let mark = announcementMark()

        reader.cancelDownload()

        XCTAssertEqual(cloud.storage.downloadsCancelled, [book.id])
        XCTAssertEqual(reader.cloudPhase, .notDownloaded)
        XCTAssertEqual(announcements(since: mark), ["Quay Notes isn't downloaded."])
        XCTAssertEqual(ReaderCloudWording.notDownloaded(title: book.title), "Quay Notes isn't downloaded.")
        waitFor("the state found after the cancel") { cloud.states.state(of: book.id) == .inCloud }
        XCTAssertNil(reader.content)

        cloud.storage.scriptDownload(of: book.id, steps: [Self.quarterSteps[1]])
        reader.downloadAgain()
        waitForReaderToLoad(reader)

        XCTAssertEqual(cloud.storage.downloadsStarted, [book.id, book.id])
        XCTAssertNotNil(reader.content, "Download did not open the book")
        XCTAssertEqual(cloud.states.state(of: book.id), .downloaded)
    }

    // MARK: - Failures

    /// Each way a download can fail is shown and spoken in the contract's
    /// words, naming the sync service, recorded for the library list, and
    /// offers Try Again and Close. Offline fails at once.
    func testEachFailureIsExplained() throws {
        let cloud = try makeCloudReaders("Cloud Failures")
        let failures: [BookCloudError] = [.offline, .stalled(seconds: 60), .provider("The server is busy."), .packageMissing]
        for (number, failure) in failures.enumerated() {
            let book = try makeTextBook("Quay Notes \(number + 1)", in: cloud)
            cloud.storage.setState(.inCloud, of: book.id)
            cloud.storage.scriptDownload(of: book.id, steps: [], failingWith: failure)
            let mark = announcementMark()

            let reader = cloud.open(book)
            waitFor("\(failure) to be shown") { reader.cloudPhase == .failed(.download(failure)) }

            let explanation = failure.explanation(in: .iCloudDrive)
            XCTAssertEqual(
                ReaderCloudWording.message(for: .download(failure), title: book.title, provider: cloud.provider),
                explanation
            )
            XCTAssertEqual(announcements(since: mark), ["Downloading \(book.title) from iCloud Drive.", explanation])
            XCTAssertEqual(cloud.states.state(of: book.id), .downloadFailed(explanation))
            XCTAssertNil(reader.content)
            reader.close()
        }
        XCTAssertEqual(
            BookCloudError.offline.explanation(in: .iCloudDrive),
            "This Mac is offline, so the book can't be downloaded from iCloud Drive. Connect to the internet and try again."
        )
    }

    /// Try Again after a failure opens the book once its download works.
    func testTryAgainAfterAFailureOpensTheBook() throws {
        let cloud = try makeCloudReaders("Cloud Try Again")
        let book = try makeTextBook("Quay Notes", in: cloud)
        cloud.storage.setState(.inCloud, of: book.id)
        cloud.storage.scriptDownload(of: book.id, steps: [], failingWith: .offline)

        let reader = cloud.open(book)
        waitFor("the offline failure") { reader.cloudPhase == .failed(.download(.offline)) }

        cloud.storage.scriptDownload(of: book.id, steps: [Self.quarterSteps[2]])
        reader.retryOpening()
        waitForReaderToLoad(reader)

        XCTAssertNotNil(reader.content, "Try Again did not open the book")
        XCTAssertNil(reader.cloudPhase)
        XCTAssertEqual(cloud.storage.downloadsStarted, [book.id, book.id])
    }

    // MARK: - Closing

    /// Closing the window during a download stops waiting for it and records
    /// the book's state as found afterwards. The download no longer counts
    /// as running, so the library list's next refresh records the book's
    /// state again.
    func testClosingDuringADownloadStopsItAndRecordsTheStateFound() throws {
        let cloud = try makeCloudReaders("Cloud Close During Download")
        let book = try makeTextBook("Quay Notes", in: cloud)
        let firstStep = Self.quarterSteps[0]
        cloud.storage.setState(.inCloud, of: book.id)
        cloud.storage.scriptDownload(of: book.id, steps: [firstStep], holdsOpen: true)

        let reader = cloud.open(book)
        waitFor("the download's first step") { reader.shownDownload?.progress == firstStep }
        XCTAssertEqual(cloud.states.state(of: book.id), .downloading(firstStep))

        reader.close()

        XCTAssertEqual(cloud.storage.downloadsCancelled, [book.id])
        waitFor("the state found after closing") { cloud.states.state(of: book.id) == .inCloud }

        cloud.storage.setState(.downloaded, of: book.id)
        let states = cloud.states
        let storage = cloud.storage
        let package = BookPackage(book)
        Task { await states.refresh([package], using: storage) }
        waitFor("the list's refresh to record the book again") { cloud.states.state(of: book.id) == .downloaded }
    }

    // MARK: - Reads Never Wait on the Network

    /// A file found only in the cloud again when the book is read sends the
    /// reader back to the download step once, after which it loads.
    func testRefusedReadGoesBackToTheDownloadOnce() throws {
        let cloud = try makeCloudReaders("Cloud Refused Once")
        let book = try makeTextBook("Quay Notes", in: cloud)
        cloud.storage.setState(.downloaded, of: book.id)
        cloud.cloudOnly.mark(book.filePath, times: 1)
        let mark = announcementMark()

        let reader = cloud.open(book)
        waitForReaderToLoad(reader)

        XCTAssertNotNil(reader.content, "The book did not open after its second download")
        XCTAssertEqual(cloud.storage.downloadsStarted, [book.id])
        XCTAssertEqual(announcements(since: mark), ["Downloading Quay Notes from iCloud Drive.", "Downloaded. Loading."])
    }

    /// A file still only in the cloud after the download back ends the
    /// opening with "Part of <title> isn't on this Mac." and Try Again,
    /// which opens the book once the file is here.
    func testSecondRefusedReadEndsTheOpening() throws {
        let cloud = try makeCloudReaders("Cloud Refused Twice")
        let book = try makeTextBook("Quay Notes", in: cloud)
        cloud.storage.setState(.downloaded, of: book.id)
        cloud.cloudOnly.mark(book.filePath)
        let mark = announcementMark()

        let reader = cloud.open(book)
        waitFor("the opening to end") { reader.cloudPhase == .failed(.partNotOnThisMac) }

        XCTAssertEqual(cloud.storage.downloadsStarted, [book.id], "The reader downloaded more than once")
        XCTAssertEqual(announcements(since: mark).last, "Part of Quay Notes isn't on this Mac.")
        XCTAssertEqual(
            ReaderCloudWording.message(for: .partNotOnThisMac, title: book.title, provider: cloud.provider),
            "Part of Quay Notes isn't on this Mac."
        )
        XCTAssertNil(reader.content)

        cloud.cloudOnly.clear()
        reader.retryOpening()
        waitForReaderToLoad(reader)

        XCTAssertNotNil(reader.content, "Try Again did not open the book")
    }

    // MARK: - Chapters Only in the Cloud

    /// A chapter whose file is only in the cloud is downloaded before it
    /// plays, in the same view, as a short pause: the player is never
    /// handed the file meanwhile, and the chapter plays once it is here.
    func testChapterOnlyInTheCloudDownloadsBeforeItPlays() throws {
        let cloud = try makeCloudReaders("Cloud Chapter Download")
        let book = try cloud.world.makeSilentAudioBook(title: "Ferry Timetable", trackDurations: [2, 2])
        let reader = cloud.open(book)
        waitForReaderToLoad(reader)
        let second = reader.audioChapterFiles[1]
        let step = Self.progress(1, of: 2, bytes: 100, of: 200)
        cloud.cloudOnly.mark(second)
        cloud.storage.scriptDownload(of: book.id, steps: [step], holdsOpen: true)
        reader.play()
        XCTAssertTrue(reader.audioPlaybackService.isPlaying, "The first chapter did not play")
        let mark = announcementMark()

        reader.navigateTo(chapterIndex: 1, characterOffset: 0)

        waitFor("the chapter's download") { reader.shownDownload?.progress == step }
        XCTAssertEqual(reader.shownDownload?.chapterNumber, 2)
        XCTAssertNil(reader.audioPlaybackService.loadedURL, "The player was handed a file only in the cloud")
        XCTAssertTrue(reader.isCurrentlyPlaying, "The reader stopped showing Playing while it waited")
        XCTAssertEqual(cloud.storage.downloadsStarted, [book.id])

        cloud.cloudOnly.clear()
        cloud.storage.finishHeldDownload(of: book.id)
        waitFor("the chapter to play") { reader.audioPlaybackService.isPlaying }

        XCTAssertNil(reader.cloudPhase)
        XCTAssertEqual(reader.currentChapterIndex, 1)
        XCTAssertEqual(Self.path(try XCTUnwrap(reader.audioPlaybackService.loadedURL)), Self.path(second))
        XCTAssertEqual(announcements(since: mark), [
            "Chapter 2 isn't on this Mac. Downloading Ferry Timetable from iCloud Drive.",
            "50 percent downloaded.",
            "Downloaded.",
        ])
        reader.stop()
    }

    /// Offline, a chapter only in the cloud stops the reader at the chapter
    /// with the offline explanation and Try Again, which plays it once it
    /// is here.
    func testChapterOnlyInTheCloudStopsAtTheChapterOffline() throws {
        let cloud = try makeCloudReaders("Cloud Chapter Offline")
        let book = try cloud.world.makeSilentAudioBook(title: "Ferry Timetable", trackDurations: [2, 2])
        let reader = cloud.open(book)
        waitForReaderToLoad(reader)
        cloud.cloudOnly.mark(reader.audioChapterFiles[1])
        cloud.storage.scriptDownload(of: book.id, steps: [], failingWith: .offline)
        reader.play()
        let mark = announcementMark()

        reader.navigateTo(chapterIndex: 1, characterOffset: 0)
        waitFor("the offline alert") { reader.errorAlert != nil }

        let explanation = BookCloudError.offline.explanation(in: .iCloudDrive)
        XCTAssertEqual(reader.errorAlert, ReaderViewModel.ErrorAlert(
            title: "Chapter Not Downloaded",
            message: explanation,
            offersRetry: true,
            retryTitle: "Try Again"
        ))
        XCTAssertFalse(reader.isCurrentlyPlaying)
        XCTAssertNil(reader.audioPlaybackService.loadedURL)
        XCTAssertEqual(reader.currentChapterIndex, 1)
        XCTAssertNil(reader.cloudPhase)
        XCTAssertEqual(announcements(since: mark).last, explanation)

        cloud.cloudOnly.clear()
        reader.retryAudioPlayback()

        XCTAssertTrue(reader.audioPlaybackService.isPlaying, "Try Again did not play the chapter")
        XCTAssertNil(reader.errorAlert)
        reader.stop()
    }

    /// A chapter still only in the cloud right after its download stops the
    /// reader there rather than download again and again.
    func testChapterStillInTheCloudAfterItsDownloadStopsThere() throws {
        let cloud = try makeCloudReaders("Cloud Chapter Still Missing")
        let book = try cloud.world.makeSilentAudioBook(title: "Ferry Timetable", trackDurations: [2, 2])
        let reader = cloud.open(book)
        waitForReaderToLoad(reader)
        cloud.cloudOnly.mark(reader.audioChapterFiles[1])
        reader.play()

        reader.navigateTo(chapterIndex: 1, characterOffset: 0)
        waitFor("the alert") { reader.errorAlert != nil }

        XCTAssertEqual(reader.errorAlert?.message, "Part of Ferry Timetable isn't on this Mac.")
        XCTAssertEqual(reader.errorAlert?.retryTitle, "Try Again")
        XCTAssertEqual(cloud.storage.downloadsStarted, [book.id])
        XCTAssertFalse(reader.isCurrentlyPlaying)
    }

    /// Cancel during a chapter's download stops the reader at that chapter.
    func testCancellingAChaptersDownloadStopsAtTheChapter() throws {
        let cloud = try makeCloudReaders("Cloud Chapter Cancel")
        let book = try cloud.world.makeSilentAudioBook(title: "Ferry Timetable", trackDurations: [2, 2])
        let reader = cloud.open(book)
        waitForReaderToLoad(reader)
        let step = Self.progress(1, of: 2, bytes: 100, of: 200)
        cloud.cloudOnly.mark(reader.audioChapterFiles[1])
        cloud.storage.scriptDownload(of: book.id, steps: [step], holdsOpen: true)
        reader.play()
        reader.navigateTo(chapterIndex: 1, characterOffset: 0)
        waitFor("the chapter's download") { reader.shownDownload?.progress == step }
        let mark = announcementMark()

        reader.cancelDownload()

        XCTAssertEqual(cloud.storage.downloadsCancelled, [book.id])
        XCTAssertNil(reader.cloudPhase)
        XCTAssertFalse(reader.isCurrentlyPlaying)
        XCTAssertEqual(reader.currentChapterIndex, 1)
        XCTAssertEqual(announcements(since: mark), ["Chapter 2 of Ferry Timetable isn't downloaded."])
    }

    /// In a library that is not in a cloud location, chapters play without
    /// any check, exactly as before.
    func testLocalLibraryPlaysChaptersWithoutCheckingThem() throws {
        let cloud = try makeCloudReaders("Cloud Local Chapters", location: .local)
        let book = try cloud.world.makeSilentAudioBook(title: "Ferry Timetable", trackDurations: [2, 2])
        let reader = cloud.open(book)
        waitForReaderToLoad(reader)
        cloud.cloudOnly.markEverything()

        reader.play()
        reader.navigateTo(chapterIndex: 1, characterOffset: 0)

        XCTAssertTrue(reader.audioPlaybackService.isPlaying)
        XCTAssertEqual(cloud.storage.downloadsStarted, [])
        XCTAssertNil(reader.cloudPhase)
        reader.stop()
    }

    // MARK: - Fixtures

    /// Progress of `files` of `totalFiles` files, `bytes` of `totalBytes`.
    private static func progress(_ files: Int, of totalFiles: Int, bytes: Int64, of totalBytes: Int64) -> BookDownloadProgress {
        BookDownloadProgress(completedFiles: files, totalFiles: totalFiles, completedBytes: bytes, totalBytes: totalBytes)
    }

    /// A four-file download at 0, 25, 50, and 75 percent.
    private static let quarterSteps = (0...3).map { progress($0, of: 4, bytes: Int64($0) * 100, of: 400) }

    /// A text book titled `title`, imported into `cloud`'s library folder.
    private func makeTextBook(_ title: String, in cloud: CloudReaders) throws -> Book {
        let source = try makeSandboxDirectory("\(title) Source").appendingPathComponent("\(title).txt")
        try "\(title)\n\nThe tide came in over the mudflats and lifted the moored boats one by one."
            .write(to: source, atomically: true, encoding: .utf8)
        return try cloud.world.importBook(from: source)
    }

    // MARK: - Helpers

    /// Where the announcements recorded from now on begin.
    private func announcementMark() -> Int {
        VoiceOverAnnouncer.recordedAnnouncements.count
    }

    /// The messages announced since `mark`, through the announcer's
    /// recording delivery.
    private func announcements(since mark: Int) -> [String] {
        VoiceOverAnnouncer.recordedAnnouncements.dropFirst(mark).map(\.message)
    }

    /// Waits until `condition` holds, failing the test when it never does.
    private func waitFor(
        _ what: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) {
        XCTAssertTrue(waitUntil(timeout: timeout, condition), "Timed out waiting for \(what)", file: file, line: line)
    }

    /// `path` with symbolic links resolved and standardized, so spellings of
    /// one place compare equal.
    private static func path(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// The path of `url`, as `path(_:)` spells it.
    private static func path(_ url: URL) -> String {
        path(url.path)
    }
}

// MARK: - A Cloud Library of the Test's Own

/// Readers on books in a cloud library of one test's own (FR02): a world of
/// readers (`IntegrationWorld`), a fake book storage saying where the library
/// is and how each download goes, a store of cloud states, and the files
/// the test says are only in the cloud.
@MainActor
private final class CloudReaders {
    /// The readers' surroundings and the library folder of their books.
    let world: IntegrationWorld
    /// Where the library is, each book's state, and its downloads.
    let storage: FakeBookCloudStorage
    /// What the readers record for the library list.
    let states = BookCloudStates()
    /// The files only in the cloud.
    let cloudOnly = CloudOnlyFiles()
    /// How often the readers announce a download without a percentage.
    var quietAnnouncementInterval: TimeInterval = 30
    /// Every reader opened, closed when the test ends.
    private(set) var readers: [ReaderViewModel] = []

    init(world: IntegrationWorld, location: StorageLocation) {
        self.world = world
        storage = FakeBookCloudStorage(location: location)
    }

    /// The sync service of the library's location.
    var provider: CloudProvider? {
        storage.libraryLocation().provider
    }

    /// Opens a reader for `book`, which starts getting it ready at once.
    func open(_ book: Book) -> ReaderViewModel {
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: world.library,
            settingsViewModel: world.settings,
            substitutionService: TextSubstitutionService(rules: []),
            autoplayRequests: world.autoplayRequests,
            notificationCenter: world.notifications,
            cloud: ReaderCloudServices(
                storage: storage,
                states: states,
                isDataless: cloudOnly.check,
                quietAnnouncementInterval: quietAnnouncementInterval
            )
        )
        readers.append(reader)
        return reader
    }

    /// Closes every reader opened.
    func closeReaders() {
        for reader in readers {
            reader.close()
        }
    }
}

extension XCTestCase {
    /// A cloud library of this test's own, named after `label`, at
    /// `location`. Its readers are closed when the test ends, before its
    /// folders are removed.
    @MainActor
    fileprivate func makeCloudReaders(
        _ label: String,
        location: StorageLocation = .cloud(.iCloudDrive)
    ) throws -> CloudReaders {
        let world = try makeIntegrationWorld(label)
        let cloud = CloudReaders(world: world, location: location)
        addTeardownBlock { cloud.closeReaders() }
        return cloud
    }
}

/// The files a test says are only in the cloud, as a reader's dataless
/// check finds them from any thread. `@unchecked Sendable`: every property
/// is read and written with `lock` held.
private final class CloudOnlyFiles: @unchecked Sendable {
    private let lock = NSLock()
    /// Paths only in the cloud however often they are checked.
    private var always: Set<String> = []
    /// Paths only in the cloud for this many more checks.
    private var forChecks: [String: Int] = [:]
    /// Whether every file is only in the cloud.
    private var everything = false

    /// Says the file at `path` is only in the cloud: for its next `times`
    /// checks, or for every check when `times` is nil.
    func mark(_ path: String, times: Int? = nil) {
        let key = Self.key(URL(fileURLWithPath: path))
        lock.withLock {
            if let times {
                forChecks[key] = times
            } else {
                always.insert(key)
            }
        }
    }

    /// Says every file is only in the cloud.
    func markEverything() {
        lock.withLock { everything = true }
    }

    /// Says every file is on this Mac.
    func clear() {
        lock.withLock {
            always = []
            forChecks = [:]
            everything = false
        }
    }

    /// The dataless check a reader uses.
    var check: @Sendable (URL) -> Bool {
        { [self] url in isDataless(url) }
    }

    /// Whether the file at `url` is only in the cloud now.
    private func isDataless(_ url: URL) -> Bool {
        let key = Self.key(url)
        return lock.withLock {
            if everything || always.contains(key) {
                return true
            }
            guard let remaining = forChecks[key], remaining > 0 else { return false }
            forChecks[key] = remaining - 1
            return true
        }
    }

    /// How a file is looked up: its path with symbolic links resolved.
    private static func key(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

extension ReaderViewModel {
    /// The download the reader shows, if any.
    fileprivate var shownDownload: ReaderDownload? {
        if case .downloading(let download)? = cloudPhase {
            return download
        }
        return nil
    }
}

// MARK: - What Is Shown and Spoken

/// The words and values of the download view and its announcements (FR02),
/// and what VoiceOver finds in the view.
@MainActor
final class ReaderCloudWordingTests: XCTestCase {

    /// The bar's value counts files and percent: "40%" shown, "40 percent"
    /// spoken.
    func testProgressValueCountsFilesAndPercent() {
        let download = Self.download(progress: BookDownloadProgress(completedFiles: 2, totalFiles: 3, completedBytes: 400, totalBytes: 1000))

        XCTAssertEqual(ReaderCloudWording.progressValue(of: download, elapsed: 65, spoken: false), "2 of 3 files, 40%")
        XCTAssertEqual(ReaderCloudWording.progressValue(of: download, elapsed: 65, spoken: true), "2 of 3 files, 40 percent")
        XCTAssertEqual(ReaderCloudWording.fraction(of: download), 0.4)
    }

    /// With a single file left and nothing counted, there is no percentage:
    /// the bar is indeterminate, with the file's size, when known, and the
    /// time waited. One file left after others counted keeps its percentage.
    func testOneFileLeftWithNothingCountedHasNoPercentage() {
        let sized = Self.download(progress: BookDownloadProgress(completedFiles: 0, totalFiles: 1, completedBytes: 0, totalBytes: 312_000_000))
        XCTAssertNil(ReaderCloudWording.fraction(of: sized))
        XCTAssertEqual(ReaderCloudWording.progressValue(of: sized, elapsed: 65, spoken: false), "1 file left, 312 MB, 1:05 elapsed")
        XCTAssertEqual(
            ReaderCloudWording.progressValue(of: sized, elapsed: 65, spoken: true),
            "1 file left, 312 MB, 1 minute, 5 seconds elapsed"
        )

        let unsized = Self.download(progress: BookDownloadProgress(completedFiles: 1, totalFiles: 2, completedBytes: 0, totalBytes: 0))
        XCTAssertEqual(ReaderCloudWording.fraction(of: unsized), 0.5, "By files, one of two is half")

        let tinyFirst = Self.download(progress: BookDownloadProgress(completedFiles: 1, totalFiles: 2, completedBytes: 2, totalBytes: 9_000_000))
        XCTAssertNil(ReaderCloudWording.fraction(of: tinyFirst))
        XCTAssertEqual(ReaderCloudWording.progressValue(of: tinyFirst, elapsed: 5, spoken: true), "1 file left, 9 MB, 5 seconds elapsed")

        let lastOfThree = Self.download(progress: BookDownloadProgress(completedFiles: 2, totalFiles: 3, completedBytes: 400, totalBytes: 1000))
        XCTAssertFalse(ReaderCloudWording.showsNoPercentage(lastOfThree.progress))
    }

    /// Before the first report, the download is starting, with the time
    /// waited, and its bar is indeterminate.
    func testBeforeAnyReportTheDownloadIsStarting() {
        let download = Self.download(progress: nil)

        XCTAssertNil(ReaderCloudWording.fraction(of: download))
        XCTAssertEqual(ReaderCloudWording.progressValue(of: download, elapsed: 5, spoken: false), "Starting, 0:05 elapsed")
        XCTAssertEqual(ReaderCloudWording.progressValue(of: download, elapsed: 5, spoken: true), "Starting, 5 seconds elapsed")
    }

    /// The time waited steps every five seconds and never goes below zero.
    func testElapsedTimeStepsEveryFiveSeconds() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertEqual(ReaderCloudWording.elapsed(since: start, at: start.addingTimeInterval(7.9)), 5)
        XCTAssertEqual(ReaderCloudWording.elapsed(since: start, at: start.addingTimeInterval(10)), 10)
        XCTAssertEqual(ReaderCloudWording.elapsed(since: start, at: start.addingTimeInterval(-3)), 0)
    }

    /// Each milestone is announced once, and a jump past several announces
    /// only the highest.
    func testMilestonesAreAnnouncedOnceEachAndOnlyTheHighestOfAJump() {
        var announcements = ReaderDownloadAnnouncements()
        func percent(_ completed: Int64) -> BookDownloadProgress {
            BookDownloadProgress(completedFiles: Int(completed / 100), totalFiles: 4, completedBytes: completed, totalBytes: 400)
        }

        XCTAssertNil(announcements.milestone(reachedBy: percent(0)))
        XCTAssertEqual(announcements.milestone(reachedBy: percent(100)), 25)
        XCTAssertNil(announcements.milestone(reachedBy: percent(100)))
        XCTAssertEqual(announcements.milestone(reachedBy: percent(300)), 75)
        XCTAssertNil(announcements.milestone(reachedBy: percent(200)))
        XCTAssertNil(announcements.milestone(reachedBy: percent(400)))
    }

    /// The heading, the line below it, and what is said as a download
    /// starts, for the book and for a chapter, naming the sync service, or
    /// "the cloud service" when it is unknown.
    func testHeadingSourceAndStartWording() {
        XCTAssertEqual(ReaderCloudWording.heading(title: "Tide Tables"), "Downloading Tide Tables")
        XCTAssertEqual(ReaderCloudWording.source(provider: .iCloudDrive, chapterNumber: nil), "From iCloud Drive")
        XCTAssertEqual(ReaderCloudWording.source(provider: .googleDrive, chapterNumber: 6), "Chapter 6, from Google Drive")
        XCTAssertEqual(ReaderCloudWording.source(provider: nil, chapterNumber: nil), "From the cloud service")
        XCTAssertEqual(
            ReaderCloudWording.downloadStarted(title: "Tide Tables", provider: .dropbox, chapterNumber: nil),
            "Downloading Tide Tables from Dropbox."
        )
        XCTAssertEqual(
            ReaderCloudWording.downloadStarted(title: "Tide Tables", provider: .other("Box"), chapterNumber: 6),
            "Chapter 6 isn't on this Mac. Downloading Tide Tables from Box."
        )
        XCTAssertEqual(ReaderCloudWording.milestone(50), "50 percent downloaded.")
        XCTAssertEqual(ReaderCloudWording.stillDownloading(elapsed: 90), "Still downloading, 1 minute, 30 seconds elapsed.")
    }

    /// What is shown and spoken when the book isn't ready.
    func testWordingWhenTheBookIsNotReady() {
        XCTAssertEqual(
            ReaderCloudWording.waitingForSync(title: "Tide Tables", provider: .dropbox),
            "Tide Tables hasn't arrived on this Mac yet. Dropbox may still be syncing it."
        )
        XCTAssertEqual(
            ReaderCloudWording.waitingForSync(title: "Tide Tables", provider: nil),
            "Tide Tables hasn't arrived on this Mac yet. The cloud service may still be syncing it."
        )
        XCTAssertEqual(ReaderCloudWording.chapterNotDownloaded(number: 3, title: "Tide Tables"), "Chapter 3 of Tide Tables isn't downloaded.")
        XCTAssertEqual(
            ReaderCloudWording.message(for: .download(.stalled(seconds: 60)), title: "Tide Tables", provider: .googleDrive),
            BookCloudError.stalled(seconds: 60).explanation(in: .googleDrive)
        )
    }

    /// The download view draws a native progress bar, VoiceOver's
    /// progress indicator, at the download's fraction, and asks for
    /// VoiceOver's focus to move to it. Without a percentage the bar is
    /// indeterminate. (SwiftUI builds the bar's spoken label and value only
    /// for a connected assistive app, so those are pinned through the
    /// wording they come from: `progressLabel` and `progressValue`.)
    func testDownloadViewShowsANativeProgressBarThatTakesVoiceOverFocus() {
        let measured = BookDownloadProgress(completedFiles: 2, totalFiles: 3, completedBytes: 400, totalBytes: 1000)
        withHostedDownloadView(progress: measured) { bar, hostingView in
            XCTAssertEqual(bar.accessibilityRole(), .progressIndicator)
            XCTAssertFalse(bar.isIndeterminate)
            XCTAssertEqual(bar.doubleValue / bar.maxValue, 0.4, accuracy: 0.0001)
            XCTAssertFalse(
                descendants(of: hostingView, as: VoiceOverFocusTriggerView.self).isEmpty,
                "The bar does not ask for VoiceOver's focus"
            )
        }
        withHostedDownloadView(progress: nil) { bar, _ in
            XCTAssertTrue(bar.isIndeterminate, "A download without a percentage showed one")
        }

        XCTAssertEqual(ReaderCloudWording.progressLabel, "Download progress")
        XCTAssertEqual(
            ReaderCloudWording.progressValue(of: Self.download(progress: measured), elapsed: 0, spoken: true),
            "2 of 3 files, 40 percent"
        )
    }

    // MARK: Helpers

    /// A download from iCloud Drive, opening the book, at `progress`.
    private static func download(progress: BookDownloadProgress?) -> ReaderDownload {
        ReaderDownload(provider: .iCloudDrive, chapterNumber: nil, startedAt: Date(), progress: progress)
    }

    /// Hosts the download view of a download at `progress` offscreen and
    /// hands `body` its progress bar and the hosting view, failing the test
    /// when no bar is drawn.
    private func withHostedDownloadView(
        progress: BookDownloadProgress?,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: (NSProgressIndicator, NSView) -> Void
    ) {
        let view = ReaderCloudPhaseView(
            phase: .downloading(Self.download(progress: progress)),
            title: "Tide Tables",
            provider: .iCloudDrive,
            actions: ReaderCloudPhaseView.Actions(cancel: {}, download: {}, tryAgain: {}, close: {})
        )
        withHostedView(view, until: { !self.descendants(of: $0, as: NSProgressIndicator.self).isEmpty }) { hostingView in
            guard let bar = descendants(of: hostingView, as: NSProgressIndicator.self).first else {
                return XCTFail("No progress bar was drawn", file: file, line: line)
            }
            body(bar, hostingView)
        }
    }
}
