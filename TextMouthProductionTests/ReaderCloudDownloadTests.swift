import AVFoundation
import Combine
import SwiftUI
import XCTest
@testable import TextMouth

/// Opening a book that is in a cloud library (FR02): the reader checks the
/// book's state before reading it, downloads it first when any of its files
/// is only in the cloud, shows and speaks the download, and can cancel it or
/// try again; it never lets a read wait on the network, plays an audiobook
/// from a working copy, and checks each chapter's file when it has none.
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
        XCTAssertNil(reader.cloudSession.workingCopy, "A text book, read into memory, needs no working copy")
        XCTAssertEqual(Self.entries(of: cloud.copiesFolder), [])
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

    /// The one file left shows no percentage until its sync service reports
    /// a part of it, as a large audiobook's file can; from then on the bar
    /// shows the percentage, and VoiceOver hears the milestone the part
    /// reaches.
    func testAPartOfTheOneFileLeftGivesTheDownloadItsPercentage() throws {
        let cloud = try makeCloudReaders("Cloud Part of a File")
        let book = try makeTextBook("Quay Notes", in: cloud)
        let nothingYet = Self.progress(0, of: 1, bytes: 0, of: 312_000_000)
        let partway = Self.progress(0, of: 1, bytes: 187_200_000, of: 312_000_000)
        cloud.storage.setState(.inCloud, of: book.id)
        cloud.storage.scriptDownload(of: book.id, steps: [nothingYet, partway], holdsOpen: true)
        let mark = announcementMark()

        let reader = cloud.open(book)
        waitFor("the part reported") { reader.shownDownload?.progress == partway }

        let shown = try XCTUnwrap(reader.shownDownload)
        XCTAssertEqual(ReaderCloudWording.fraction(of: shown) ?? 0, 0.6, accuracy: 1e-9)
        XCTAssertEqual(ReaderCloudWording.progressValue(of: shown, elapsed: 0, spoken: true), "0 of 1 file, 60 percent")
        XCTAssertEqual(announcements(since: mark), ["Downloading Quay Notes from iCloud Drive.", "50 percent downloaded."])

        cloud.storage.finishHeldDownload(of: book.id)
        waitForReaderToLoad(reader)
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

    // MARK: - A Book Another Book Continued To

    /// A book only in the cloud that another book continued to, from its
    /// folder or through the reading list, keeps the request to start it
    /// for as long as its download takes, past the request's own 30
    /// seconds, and starts once it has downloaded and loaded; the request
    /// is claimed then, and held no longer.
    func testABookContinuedToKeepsItsRequestUntilItHasDownloadedAndPlays() throws {
        let cloud = try makeCloudReaders("Cloud Continued To")
        let book = try makeSingleFileAudioBook("Lantern Hours", in: cloud)
        let clock = RequestClock()
        let requests = ReaderAutoplayRequests(now: { clock.now })
        cloud.storage.setState(.inCloud, of: book.id)
        cloud.storage.scriptDownload(of: book.id, steps: [Self.halfway], holdsOpen: true)
        requests.request(for: book.id, from: UUID())

        let reader = cloud.open(book, autoplayRequests: requests)
        waitFor("the download's first step") { reader.shownDownload?.progress == Self.halfway }
        clock.now += ReaderAutoplayRequests.lifetime + 60

        XCTAssertTrue(requests.isHolding(book.id))
        XCTAssertTrue(requests.hasRequest(for: book.id), "the request lapsed while the book downloaded")

        cloud.storage.finishHeldDownload(of: book.id)
        waitForReaderToLoad(reader)
        waitFor("the book to start playing") { reader.audioPlaybackService.isPlaying }

        XCTAssertFalse(requests.hasRequest(for: book.id), "the request was left to claim again")
        XCTAssertFalse(requests.isHolding(book.id))
        reader.stop()
    }

    /// A later move from the old window, before a cloud book the first move
    /// asked for has downloaded, cancels the first book's start: its request,
    /// held while it downloads, is discarded and the timer's hold undone, so
    /// when the book has downloaded and loaded it neither plays nor takes the
    /// timer (the last move wins until its book has started).
    func testALaterMoveBeforeACloudTargetHasDownloadedCancelsItsStart() throws {
        preserveSleepTimers()
        let cloud = try makeCloudReaders("Cloud Last Move")
        let world = cloud.world
        // In folder order: A Volume, the old reader's B Volume, the cloud C Volume.
        _ = try world.makeSilentAudioBook(title: "A Volume", trackDurations: [5, 5], endOfBook: .continueNext)
        let current = try world.makeSilentAudioBook(title: "B Volume", trackDurations: [5, 5], endOfBook: .continueNext)
        let target = try makeSingleFileAudioBook("C Volume", in: cloud)
        world.library.library.folders = [BookFolder(name: world.folder.path)]
        world.settings.endOfBookBehavior = .continueNext
        world.settings.nextBookWindow = .newWindow
        cloud.storage.setState(.inCloud, of: target.id)
        cloud.storage.scriptDownload(of: target.id, steps: [Self.halfway], holdsOpen: true)
        let old = cloud.open(current)
        waitForReaderToLoad(old)
        // The old reader's window's timer, held for the next book by the move.
        let timer = old.sleepTimerService
        timer.start(duration: .minutes(30), ownerID: old.readerID, onExpire: {})
        old.isWhereAmIResumePending = true
        old.goThroughFolder(.down)
        waitFor("the move asks for the cloud book") { world.autoplayRequests.hasRequest(for: target.id) }
        let downloading = cloud.open(target)
        waitFor("the download's first step") { downloading.shownDownload?.progress == Self.halfway }

        old.goThroughFolder(.up)

        XCTAssertFalse(world.autoplayRequests.hasRequest(for: target.id), "The cloud book's request was left")
        XCTAssertFalse(timer.isHeld(forBook: target.id), "The cloud book's hold was left")
        cloud.storage.finishHeldDownload(of: target.id)
        waitForReaderToLoad(downloading)
        XCTAssertFalse(downloading.audioPlaybackService.isPlaying, "The cancelled book played")
        // The cancelled book's reader is in a window of its own: had it taken
        // the timer, that window's timer would be the one in effect.
        XCTAssertNotEqual(downloading.sleepTimerService.ownerID, downloading.readerID, "The cancelled book took the timer")
        XCTAssertFalse(downloading.sleepTimerService.isActive, "The cancelled book's window has a timer in effect")
    }

    /// A download that is cancelled, or fails, drops the request to start
    /// the book at once, whatever its age, so the book never starts by
    /// itself later, and its requests are held no longer.
    func testACancelledOrFailedDownloadDropsTheRequest() throws {
        let cloud = try makeCloudReaders("Cloud Continued To Ends")
        let clock = RequestClock()
        let requests = ReaderAutoplayRequests(now: { clock.now })

        let cancelled = try makeTextBook("Quay Notes", in: cloud)
        cloud.storage.setState(.inCloud, of: cancelled.id)
        cloud.storage.scriptDownload(of: cancelled.id, steps: [Self.halfway], holdsOpen: true)
        requests.request(for: cancelled.id, from: UUID())
        let first = cloud.open(cancelled, autoplayRequests: requests)
        waitFor("the download's first step") { first.shownDownload?.progress == Self.halfway }
        first.cancelDownload()
        XCTAssertFalse(requests.hasRequest(for: cancelled.id), "the cancelled book's request waited on")
        XCTAssertFalse(requests.isHolding(cancelled.id))

        let failed = try makeTextBook("Tide Tables", in: cloud)
        cloud.storage.setState(.inCloud, of: failed.id)
        cloud.storage.scriptDownload(of: failed.id, steps: [], failingWith: .offline)
        requests.request(for: failed.id, from: UUID())
        let second = cloud.open(failed, autoplayRequests: requests)
        waitFor("the offline failure") { second.cloudPhase == .failed(.download(.offline)) }
        XCTAssertFalse(requests.hasRequest(for: failed.id), "the failed book's request waited on")
        XCTAssertFalse(requests.isHolding(failed.id))
    }

    /// Closing the window during the download lets go of the request, which
    /// ages again from when it was made and lapses at its lifetime's end.
    func testClosingDuringTheDownloadLetsTheRequestAgeAgain() throws {
        let cloud = try makeCloudReaders("Cloud Continued To Closed")
        let book = try makeTextBook("Quay Notes", in: cloud)
        let clock = RequestClock()
        let requests = ReaderAutoplayRequests(now: { clock.now })
        cloud.storage.setState(.inCloud, of: book.id)
        cloud.storage.scriptDownload(of: book.id, steps: [Self.halfway], holdsOpen: true)
        requests.request(for: book.id, from: UUID())

        let reader = cloud.open(book, autoplayRequests: requests)
        waitFor("the download's first step") { reader.shownDownload?.progress == Self.halfway }
        XCTAssertTrue(requests.isHolding(book.id))
        reader.close()

        XCTAssertFalse(requests.isHolding(book.id))
        XCTAssertTrue(requests.hasRequest(for: book.id))
        clock.now += ReaderAutoplayRequests.lifetime + 1
        XCTAssertFalse(requests.hasRequest(for: book.id))
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

    // MARK: - The Working Copy

    /// A multi-file audiobook plays every chapter from its working copy,
    /// while the reader still names its files where the library has them;
    /// the copy is deleted when the reader closes.
    func testAudiobookPlaysFromItsWorkingCopyUntilItCloses() throws {
        let cloud = try makeCloudReaders("Cloud Working Copy")
        let book = try cloud.world.makeSilentAudioBook(title: "Ferry Timetable", trackDurations: [2, 2])

        let reader = cloud.open(book)
        waitForReaderToLoad(reader)
        let copy = try XCTUnwrap(reader.cloudSession.workingCopy, "No working copy was made")

        XCTAssertEqual(Self.entries(of: cloud.copiesFolder), [copy.folder.lastPathComponent])
        XCTAssertEqual(Self.path(copy.source), Self.path(book.tmbDirectory))
        XCTAssertEqual(reader.audioChapterFiles.count, 2)
        for file in reader.audioChapterFiles {
            XCTAssertTrue(Self.path(file).hasPrefix(Self.path(book.filePath) + "/"), "\(file) is not in the package")
        }

        reader.play()
        XCTAssertTrue(reader.audioPlaybackService.isPlaying, "Playback did not start")
        XCTAssertEqual(
            Self.path(try XCTUnwrap(reader.audioPlaybackService.loadedURL)),
            Self.path(copy.location(of: URL(fileURLWithPath: try chapterFile(number: 1, of: reader))))
        )
        reader.navigateTo(chapterIndex: 1, characterOffset: 0)
        XCTAssertEqual(
            Self.path(try XCTUnwrap(reader.audioPlaybackService.loadedURL)),
            Self.path(copy.location(of: URL(fileURLWithPath: try chapterFile(number: 2, of: reader))))
        )
        reader.stop()

        reader.close()

        waitFor("the copy to be deleted") { !FileManager.default.fileExists(atPath: copy.folder.path) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.filePath), "The package went with the copy")
    }

    /// A single-file audiobook plays its one file from the working copy.
    func testSingleFileAudiobookPlaysFromItsWorkingCopy() throws {
        let cloud = try makeCloudReaders("Cloud Single File Copy")
        let book = try makeSingleFileAudioBook("Lantern Hours", in: cloud)

        let reader = cloud.open(book)
        waitForReaderToLoad(reader)
        let copy = try XCTUnwrap(reader.cloudSession.workingCopy, "No working copy was made")
        reader.play()

        XCTAssertTrue(reader.audioPlaybackService.isPlaying, "Playback did not start")
        XCTAssertEqual(
            Self.path(try XCTUnwrap(reader.audioPlaybackService.loadedURL)),
            Self.path(copy.root.appendingPathComponent("Lantern Hours.wav"))
        )
        reader.stop()
    }

    /// A segmented audiobook plays each chapter's clips from the working
    /// copy's audio folder.
    func testSegmentedAudiobookPlaysItsClipsFromItsWorkingCopy() throws {
        let cloud = try makeCloudReaders("Cloud Segmented Copy")
        let book = try cloud.world.makeSegmentedAudioBook(
            title: "Weir Songs",
            files: ["intro.wav": 1, "a.wav": 1],
            sections: [
                AudioSegment(title: "Opening", file: "intro.wav", startTime: 0, endTime: 1),
                AudioSegment(title: "Weir", file: "a.wav", startTime: 0, endTime: 1),
            ]
        )

        let reader = cloud.open(book)
        waitForReaderToLoad(reader)
        let copy = try XCTUnwrap(reader.cloudSession.workingCopy, "No working copy was made")
        let audioFolder = URL(fileURLWithPath: book.filePath, isDirectory: true)

        XCTAssertEqual(
            reader.chapterAudioSource(forChapterAt: 1).files.map { Self.path($0) },
            [Self.path(copy.location(of: audioFolder.appendingPathComponent("a.wav")))]
        )
        reader.play()
        XCTAssertTrue(reader.audioPlaybackService.isPlaying, "Playback did not start")
        XCTAssertEqual(
            Self.path(try XCTUnwrap(reader.audioPlaybackService.loadedURL)),
            Self.path(copy.location(of: audioFolder.appendingPathComponent("intro.wav")))
        )
        reader.stop()
    }

    /// When the clone fails, the audiobook plays from its package, as it
    /// always did.
    func testAudiobookPlaysFromItsPackageWhenCloningFails() throws {
        let cloud = try makeCloudReaders("Cloud Clone Fails", clone: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        let book = try cloud.world.makeSilentAudioBook(title: "Ferry Timetable", trackDurations: [2])

        let reader = cloud.open(book)
        waitForReaderToLoad(reader)
        reader.play()

        XCTAssertNil(reader.cloudSession.workingCopy)
        XCTAssertEqual(Self.entries(of: cloud.copiesFolder), [])
        XCTAssertTrue(reader.audioPlaybackService.isPlaying, "Playback did not start")
        XCTAssertEqual(
            Self.path(try XCTUnwrap(reader.audioPlaybackService.loadedURL)),
            Self.path(try chapterFile(number: 1, of: reader))
        )
        reader.stop()
    }

    /// The library moves the package of an audiobook playing from its
    /// working copy: playback goes on from the copy through the move,
    /// without stopping, and the copy now comes from where the package is,
    /// so the next chapter, named where the book is now, plays from it too.
    func testPackageMoveKeepsPlaybackOnTheCopy() throws {
        let cloud = try makeCloudReaders("Cloud Move While Copy Plays")
        let book = try cloud.world.makeSilentAudioBook(
            title: "Ferry Timetable",
            trackDurations: [2, 2],
            savedPosition: ReadingPosition(chapterIndex: 0, characterOffset: 5)
        )
        let reader = cloud.open(book)
        waitForReaderToLoad(reader)
        let copy = try XCTUnwrap(reader.cloudSession.workingCopy, "No working copy was made")
        reader.play()
        let playing = try XCTUnwrap(reader.audioPlaybackService.loadedURL)
        let duringMove = PlayerDuringMove()

        try cloud.world.library.commitLibraryTransition(
            Self.library(cloud.world.library.library, moving: book.id, to: "\(cloud.world.folder.path)/Shelf"),
            affectedBookIDs: [book.id],
            disk: observingDisk(reader, into: duringMove)
        )

        XCTAssertEqual(duringMove.moves, 1)
        XCTAssertTrue(duringMove.wasPlaying, "Playback stopped while its package moved")
        XCTAssertEqual(duringMove.loadedURL, playing, "The player left the copy while the package moved")
        XCTAssertTrue(reader.audioPlaybackService.isPlaying, "Playback did not go on after the move")
        XCTAssertEqual(reader.audioPlaybackService.loadedURL, playing)

        let moved = try XCTUnwrap(cloud.world.library.bookByID(book.id))
        XCTAssertEqual(Self.path(try XCTUnwrap(reader.cloudSession.workingCopy).source), Self.path(moved.tmbDirectory))
        XCTAssertTrue(Self.path(try chapterFile(number: 2, of: reader)).hasPrefix(Self.path(moved.filePath) + "/"))

        reader.navigateTo(chapterIndex: 1, characterOffset: 0)
        XCTAssertEqual(
            Self.path(try XCTUnwrap(reader.audioPlaybackService.loadedURL)),
            Self.path(copy.root.appendingPathComponent("Tracks/02.wav"))
        )
        reader.stop()
    }

    // MARK: - Chapters Without a Working Copy

    /// Without a working copy, a chapter whose file is only in the cloud is
    /// downloaded before it plays, in the same view, as a short pause: the
    /// player is never handed the file meanwhile, and the chapter plays
    /// once it is here.
    func testChapterOnlyInTheCloudDownloadsBeforeItPlays() throws {
        let cloud = try makeCloudReaders("Cloud Chapter Download", clone: Self.failingClone)
        let book = try cloud.world.makeSilentAudioBook(title: "Ferry Timetable", trackDurations: [2, 2])
        let reader = cloud.open(book)
        waitForReaderToLoad(reader)
        XCTAssertNil(reader.cloudSession.workingCopy)
        let second = try chapterFile(number: 2, of: reader)
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
        let cloud = try makeCloudReaders("Cloud Chapter Offline", clone: Self.failingClone)
        let book = try cloud.world.makeSilentAudioBook(title: "Ferry Timetable", trackDurations: [2, 2])
        let reader = cloud.open(book)
        waitForReaderToLoad(reader)
        cloud.cloudOnly.mark(try chapterFile(number: 2, of: reader))
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
        let cloud = try makeCloudReaders("Cloud Chapter Still Missing", clone: Self.failingClone)
        let book = try cloud.world.makeSilentAudioBook(title: "Ferry Timetable", trackDurations: [2, 2])
        let reader = cloud.open(book)
        waitForReaderToLoad(reader)
        cloud.cloudOnly.mark(try chapterFile(number: 2, of: reader))
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
        let cloud = try makeCloudReaders("Cloud Chapter Cancel", clone: Self.failingClone)
        let book = try cloud.world.makeSilentAudioBook(title: "Ferry Timetable", trackDurations: [2, 2])
        let reader = cloud.open(book)
        waitForReaderToLoad(reader)
        let step = Self.progress(1, of: 2, bytes: 100, of: 200)
        cloud.cloudOnly.mark(try chapterFile(number: 2, of: reader))
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

    /// Pausing while a chapter's files download stops waiting for them: the
    /// reader is paused at the chapter, saying nothing of the download, the
    /// download's end plays nothing, and Play plays the chapter once its
    /// files are here.
    func testPausingDuringAChaptersDownloadStopsWaitingForIt() throws {
        let cloud = try makeCloudReaders("Cloud Chapter Pause", clone: Self.failingClone)
        let (reader, book) = try readerWaitingForSecondChapter(in: cloud)
        let second = try chapterFile(number: 2, of: reader)
        let mark = announcementMark()

        reader.pause()

        XCTAssertEqual(cloud.storage.downloadsCancelled, [book.id])
        XCTAssertNil(reader.cloudPhase)
        XCTAssertTrue(reader.isCurrentlyPlaying)
        XCTAssertTrue(reader.isCurrentlyPaused)
        XCTAssertEqual(reader.currentChapterIndex, 1)
        assertNothingPlaysOnceTheDownloadEnds(for: book, in: cloud, reader: reader)
        XCTAssertTrue(reader.isCurrentlyPaused)
        XCTAssertEqual(announcements(since: mark), [])

        reader.togglePlayPause()

        XCTAssertTrue(reader.audioPlaybackService.isPlaying, "Play did not play the chapter")
        XCTAssertEqual(Self.path(try XCTUnwrap(reader.audioPlaybackService.loadedURL)), Self.path(second))
        XCTAssertFalse(reader.isCurrentlyPaused)
        reader.stop()
    }

    /// Stop while a chapter's files download stops waiting for them, as a
    /// pause does, and so does Release Media Controls, which stops through
    /// it: the reader shows neither Playing nor the download, nothing is
    /// under way, and Play is heard at once: it waits for the chapter's
    /// download afresh, as Play from stopped does, and plays the chapter
    /// once its files are here. Before, the stop left the reader waiting,
    /// which kept playback under way, so Play did nothing until the
    /// download ended, and then nothing played.
    func testStoppingDuringAChaptersDownloadStopsWaitingForIt() throws {
        for releasing in [false, true] {
            let name = releasing ? "Release Media Controls" : "Stop"
            let cloud = try makeCloudReaders("Cloud Chapter \(name)", clone: Self.failingClone)
            // A coordinator of the test's own, so releasing the media
            // controls tells the system nothing.
            cloud.nowPlaying = NowPlayingService(installsSystemIntegrations: false)
            let (reader, book) = try readerWaitingForSecondChapter(in: cloud)
            let second = try chapterFile(number: 2, of: reader)
            let mark = announcementMark()

            if releasing {
                reader.releaseMediaControls()
            } else {
                reader.stop()
            }

            XCTAssertEqual(cloud.storage.downloadsCancelled, [book.id], "\(name): the download was waited for still")
            XCTAssertFalse(reader.isWaitingForChapterDownload, "\(name): the reader still waits for the chapter")
            XCTAssertFalse(reader.isPlaybackUnderWay, "\(name): playback is still under way")
            XCTAssertNil(reader.cloudPhase, "\(name): the download is still shown")
            XCTAssertFalse(reader.isCurrentlyPlaying, "\(name): the reader still shows Playing")
            XCTAssertEqual(reader.currentChapterIndex, 1, "\(name): the cursor left the chapter")
            XCTAssertEqual(announcements(since: mark), releasing ? [MediaControlsWording.released] : [], name)

            cloud.storage.scriptDownload(of: book.id, steps: [Self.halfway], holdsOpen: true)
            reader.togglePlayPause()

            waitFor("\(name): the chapter's download afresh") { reader.shownDownload?.progress == Self.halfway }
            XCTAssertTrue(reader.isWaitingForChapterDownload, "\(name): Play did not wait for the chapter")
            XCTAssertTrue(reader.isCurrentlyPlaying, "\(name): Play does not show Playing")
            XCTAssertEqual(cloud.storage.downloadsStarted, [book.id, book.id], name)
            cloud.cloudOnly.clear()
            cloud.storage.finishHeldDownload(of: book.id)
            waitFor("\(name): the chapter to play") { reader.audioPlaybackService.isPlaying }
            XCTAssertEqual(Self.path(try XCTUnwrap(reader.audioPlaybackService.loadedURL)), Self.path(second), name)
            reader.stop()
        }
    }

    /// The sleep timer running out while a chapter's files download pauses
    /// the reader for good: the download's end plays nothing.
    func testSleepTimerRunningOutDuringAChaptersDownloadLeavesTheReaderPaused() throws {
        preserveSleepTimers()
        let cloud = try makeCloudReaders("Cloud Chapter Sleep Timer", clone: Self.failingClone)
        // No fade, so the timer pauses the reader as it runs out.
        cloud.world.settings.sleepFadeOutDuration = 0
        let (reader, book) = try readerWaitingForSecondChapter(in: cloud)
        reader.startSleepTimer(duration: .minutes(5))
        let mark = announcementMark()

        reader.sleepTimerService._expireForTesting()

        XCTAssertEqual(cloud.storage.downloadsCancelled, [book.id])
        XCTAssertNil(reader.cloudPhase)
        XCTAssertTrue(reader.isCurrentlyPaused)
        assertNothingPlaysOnceTheDownloadEnds(for: book, in: cloud, reader: reader)
        XCTAssertTrue(reader.isCurrentlyPaused)
        XCTAssertEqual(announcements(since: mark), ["Sleep timer expired. Playback paused."])
    }

    /// Play/Pause while a chapter's files download pauses the reader, which
    /// shows Playing meanwhile, rather than asking it to play again: the
    /// reader stops waiting, and the download's end plays nothing.
    func testPlayPauseDuringAChaptersDownloadPausesTheReader() throws {
        let cloud = try makeCloudReaders("Cloud Chapter Play Pause", clone: Self.failingClone)
        let (reader, book) = try readerWaitingForSecondChapter(in: cloud)

        reader.togglePlayPause()

        XCTAssertEqual(cloud.storage.downloadsCancelled, [book.id])
        XCTAssertNil(reader.cloudPhase)
        XCTAssertTrue(reader.isCurrentlyPaused)
        assertNothingPlaysOnceTheDownloadEnds(for: book, in: cloud, reader: reader)
    }

    /// A reader waiting for its chapter's files counts as playing for the
    /// system's media commands, as it shows Playing: a recording starting
    /// pauses it, as it pauses every book playing, so it stops waiting and
    /// plays nothing once the download ends. Before, it counted as not
    /// playing, nothing paused it, and the chapter played under the
    /// recording (REV12's leftovers).
    func testARecordingStartingWhileAChapterDownloadsPausesTheReader() throws {
        let cloud = try makeCloudReaders("Cloud Chapter Recording", clone: Self.failingClone)
        let coordinator = NowPlayingService(installsSystemIntegrations: false)
        cloud.nowPlaying = coordinator
        let (reader, book) = try readerWaitingForSecondChapter(in: cloud)

        XCTAssertEqual(coordinator.pauseEveryPlayingReader(), 1, "The reader waiting for its chapter was not paused")

        XCTAssertEqual(cloud.storage.downloadsCancelled, [book.id])
        XCTAssertNil(reader.cloudPhase)
        XCTAssertTrue(reader.isCurrentlyPaused)
        assertNothingPlaysOnceTheDownloadEnds(for: book, in: cloud, reader: reader)
    }

    /// With Auto-play on navigate, a bookmark picked while a chapter's files
    /// download moves the reader to the bookmark and leaves it waiting: the
    /// download goes on, and the chapter plays once its files are here.
    /// Before, the auto-play went through Play/Pause, which took the waiting
    /// reader for one playing and paused it, so the download was stopped
    /// and nothing played.
    func testAutoPlayAfterABookmarkLeavesAChaptersDownloadToPlay() throws {
        let cloud = try makeCloudReaders("Cloud Chapter Auto-play", clone: Self.failingClone)
        cloud.world.settings.autoPlayOnNavigate = true
        let (reader, book) = try readerWaitingForSecondChapter(in: cloud)
        let halfASecond = Int(0.5 * ReaderViewModel.audioCharsPerSecond)

        reader.navigateToBookmark(Bookmark(number: 1, chapterIndex: 1, characterOffset: halfASecond))

        XCTAssertEqual(cloud.storage.downloadsCancelled, [], "Auto-play stopped the chapter's download")
        XCTAssertTrue(reader.isWaitingForChapterDownload, "The reader no longer waits for the chapter")
        XCTAssertFalse(reader.isCurrentlyPaused, "Auto-play paused the reader")
        XCTAssertEqual(reader.currentChapterIndex, 1)
        XCTAssertEqual(reader.currentCharacterOffset, halfASecond, "The bookmark did not move the cursor")

        cloud.cloudOnly.clear()
        cloud.storage.finishHeldDownload(of: book.id)
        waitFor("the chapter to play") { reader.audioPlaybackService.isPlaying }

        XCTAssertEqual(reader.audioPlaybackService.loadedURL?.lastPathComponent, "02.wav", "Another chapter played")
        reader.stop()
    }

    /// A second Play, from the AirPods or a media key, while an audiobook
    /// waits for its chapter's files starts nothing anew: no play sound is
    /// made, the chapter's play is not begun again, the download goes on, and
    /// the reader still shows Playing. The chapter plays once its files are
    /// here. Before, the second Play called `play()` again, which sounded the
    /// play sound a second time and began the chapter's play anew.
    func testASecondPlayWhileAChapterDownloadsStartsNothingAnew() throws {
        let cloud = try makeCloudReaders("Cloud Chapter Second Play", clone: Self.failingClone)
        let (reader, book) = try readerWaitingForSecondChapter(in: cloud)
        let sounds = RecordedSoundEffects(preferences: makeSandboxedPreferences("Cloud Chapter Second Play"))
        reader.soundEffectService = sounds
        let generationBefore = reader.chapterPlaybackGeneration

        reader.playOrResume()

        XCTAssertEqual(sounds.played, [], "The second Play made a sound")
        XCTAssertEqual(reader.chapterPlaybackGeneration, generationBefore, "The second Play began the chapter's play anew")
        XCTAssertEqual(cloud.storage.downloadsCancelled, [], "The second Play stopped the chapter's download")
        XCTAssertTrue(reader.isWaitingForChapterDownload, "The reader no longer waits for the chapter")
        XCTAssertTrue(reader.isCurrentlyPlaying, "The reader stopped showing Playing")
        XCTAssertFalse(reader.isCurrentlyPaused, "The second Play paused the reader")

        cloud.cloudOnly.clear()
        cloud.storage.finishHeldDownload(of: book.id)
        waitFor("the chapter to play") { reader.audioPlaybackService.isPlaying }

        XCTAssertEqual(reader.audioPlaybackService.loadedURL?.lastPathComponent, "02.wav", "Another chapter played")
        reader.stop()
    }

    /// A chapter whose files finish downloading while Where Am I? speaks
    /// waits for the announcement, as a Play pressed during it does: nothing
    /// plays under the announcement, the reader goes on showing Playing, and
    /// the chapter plays once the announcement's end sound has played.
    /// Before, the download's end started the chapter under the
    /// announcement (REV11).
    func testAChapterDownloadedDuringWhereAmIPlaysAsTheAnnouncementEnds() throws {
        let cloud = try makeCloudReaders("Cloud Chapter Where Am I", clone: Self.failingClone)
        let held = try chapterHeldForWhereAmI(in: cloud)
        let reader = held.reader

        XCTAssertNil(reader.audioPlaybackService.loadedURL, "The chapter played under the announcement")
        XCTAssertTrue(reader.isChapterHeldByWhereAmI)
        XCTAssertTrue(reader.isCurrentlyPlaying, "The reader stopped showing Playing")
        XCTAssertFalse(reader.isCurrentlyPaused)

        reader.whereAmIDelegate?.speechSynthesizer(AVSpeechSynthesizer(), didFinish: held.announcement)
        waitFor("the announcement's end") { !reader.isWhereAmISpeaking }
        XCTAssertNil(reader.audioPlaybackService.loadedURL, "The chapter played before the end sound")
        held.endSound.passEndSound()

        waitFor("the chapter to play") { reader.audioPlaybackService.isPlaying }
        XCTAssertEqual(Self.path(try XCTUnwrap(reader.audioPlaybackService.loadedURL)), Self.path(held.secondChapterFile))
        XCTAssertFalse(reader.isChapterHeldByWhereAmI)
        reader.stop()
    }

    /// A chapter whose files finish downloading in the moment after Where
    /// Am I? ends by itself, while its end sound still plays, waits for the
    /// end sound as one that finished while the announcement spoke does:
    /// nothing starts over the sound, the reader goes on showing Playing, and
    /// the chapter plays exactly once as the sound passes, with no sound
    /// beside Where Am I's own (no play sound). Before, only the
    /// announcement's speaking held the chapter, so the download's end in
    /// this moment started it under the end sound.
    func testAChapterDownloadedWhileWhereAmIsEndSoundPlaysOnceAfterTheSound() throws {
        let cloud = try makeCloudReaders("Cloud Chapter Where Am I End Sound", clone: Self.failingClone)
        let (reader, book) = try readerWaitingForSecondChapter(in: cloud)
        let second = try chapterFile(number: 2, of: reader)
        let sounds = RecordedSoundEffects(preferences: makeSandboxedPreferences("Cloud Chapter Where Am I End Sound"))
        reader.soundEffectService = sounds
        let announcement = try speakWhereAmI(in: reader)
        let endSound = WhereAmIEndSoundClock(holdingFor: reader)
        let generationBefore = reader.chapterPlaybackGeneration
        reader.whereAmIDelegate?.speechSynthesizer(AVSpeechSynthesizer(), didFinish: announcement)
        waitFor("the announcement's end") { !reader.isWhereAmISpeaking }
        XCTAssertTrue(endSound.hasWorkWaiting, "The end sound's work was not scheduled")

        // The files come in the window: the announcement is over, its end
        // sound has not passed.
        cloud.cloudOnly.clear()
        cloud.storage.finishHeldDownload(of: book.id)
        waitFor("the download's end") { reader.cloudPhase == nil }

        XCTAssertNil(reader.audioPlaybackService.loadedURL, "The chapter played over the end sound")
        XCTAssertTrue(reader.isChapterHeldByWhereAmI, "The chapter was not held for the end sound")
        XCTAssertTrue(reader.isCurrentlyPlaying, "The reader stopped showing Playing")
        XCTAssertFalse(reader.isCurrentlyPaused)
        XCTAssertEqual(reader.chapterPlaybackGeneration, generationBefore, "The chapter began before the end sound passed")

        endSound.passEndSound()

        waitFor("the chapter to play") { reader.audioPlaybackService.isPlaying }
        XCTAssertEqual(Self.path(try XCTUnwrap(reader.audioPlaybackService.loadedURL)), Self.path(second))
        XCTAssertFalse(reader.isChapterHeldByWhereAmI)
        XCTAssertEqual(reader.chapterPlaybackGeneration, generationBefore + 1, "The chapter was not started exactly once")
        XCTAssertEqual(sounds.played, [.whereAmIStart, .whereAmIEnd], "A sound beside Where Am I's own was made")
        reader.stop()
    }

    /// Where Am I? pressed again while it speaks stops it, and a chapter
    /// whose files came during it plays at once, as its end would have
    /// played it.
    func testAChapterDownloadedDuringWhereAmIPlaysAtOnceWhenAPressEndsIt() throws {
        let cloud = try makeCloudReaders("Cloud Chapter Where Am I Pressed", clone: Self.failingClone)
        let reader = try chapterHeldForWhereAmI(in: cloud).reader

        reader.whereAmI()

        XCTAssertFalse(reader.isWhereAmISpeaking, "The press did not stop the announcement")
        waitFor("the chapter to play") { reader.audioPlaybackService.isPlaying }
        reader.stop()
    }

    /// Play/Pause while Where Am I? speaks over a chapter whose files came
    /// during it ends the announcement and pauses the reader at the chapter,
    /// as it pauses a reader waiting for its chapter without Where Am I:
    /// nothing plays then, and Play plays the chapter.
    func testPlayPauseDuringWhereAmILetsAHeldChapterGo() throws {
        let cloud = try makeCloudReaders("Cloud Chapter Where Am I Play Pause", clone: Self.failingClone)
        let held = try chapterHeldForWhereAmI(in: cloud)
        let reader = held.reader

        reader.togglePlayPause()

        XCTAssertFalse(reader.isWhereAmISpeaking, "Play/Pause did not end the announcement")
        XCTAssertTrue(reader.isCurrentlyPaused, "The reader is not paused")
        XCTAssertFalse(reader.isChapterHeldByWhereAmI)
        XCTAssertFalse(held.endSound.hasWorkWaiting, "Work waits for an end sound")
        XCTAssertNil(reader.audioPlaybackService.loadedURL, "The chapter played")

        reader.togglePlayPause()

        XCTAssertTrue(reader.audioPlaybackService.isPlaying, "Play did not play the chapter")
        XCTAssertEqual(Self.path(try XCTUnwrap(reader.audioPlaybackService.loadedURL)), Self.path(held.secondChapterFile))
        reader.stop()
    }

    /// Play/Pause while Where Am I? speaks over a reader waiting for its
    /// chapter's files to download ends the announcement and pauses the
    /// reader, as it pauses one waiting without the announcement: the
    /// download is stopped, nothing plays once the sync service finishes it
    /// anyway, and Play plays the chapter. Before, the press ended only the
    /// announcement and left the reader waiting, so the chapter played once
    /// its files were here (open after the where-am-i-followups merge).
    func testPlayPauseDuringWhereAmIPausesAChapterStillDownloading() throws {
        let cloud = try makeCloudReaders("Cloud Chapter Where Am I Play Pause Downloading", clone: Self.failingClone)
        let (reader, book) = try readerWaitingForSecondChapter(in: cloud)
        let second = try chapterFile(number: 2, of: reader)
        _ = try speakWhereAmI(in: reader)

        reader.togglePlayPause()

        XCTAssertFalse(reader.isWhereAmISpeaking, "Play/Pause did not end the announcement")
        XCTAssertFalse(reader.isWaitingForChapterDownload, "The reader still waits for the chapter")
        XCTAssertEqual(cloud.storage.downloadsCancelled, [book.id], "The chapter's download goes on")
        XCTAssertTrue(reader.isCurrentlyPaused, "The reader is not paused")
        assertNothingPlaysOnceTheDownloadEnds(for: book, in: cloud, reader: reader)

        reader.togglePlayPause()

        XCTAssertTrue(reader.audioPlaybackService.isPlaying, "Play did not play the chapter")
        XCTAssertEqual(Self.path(try XCTUnwrap(reader.audioPlaybackService.loadedURL)), Self.path(second))
        reader.stop()
    }

    /// A Play in the moment after Where Am I? ends by itself, while the
    /// chapter whose files came during it waits for the end sound, changes
    /// nothing then, as a Play then does for a book the announcement paused:
    /// neither the AirPods' Play nor the menu's starts the chapter, which
    /// plays once the end sound has played, started once, and the end
    /// sound is the only sound made. Before, the Play started the chapter
    /// at once, under the end sound, with the play sound over it, and the
    /// end sound's moment then found nothing left to start (open after the
    /// where-am-i-followups merge).
    func testAPlayAsWhereAmIEndsLetsAHeldChapterStartOnceAsTheEndSoundPasses() throws {
        let cloud = try makeCloudReaders("Cloud Chapter Where Am I Ends Play", clone: Self.failingClone)
        let held = try chapterHeldForWhereAmI(in: cloud)
        let reader = held.reader
        let sounds = RecordedSoundEffects(preferences: makeSandboxedPreferences("Cloud Chapter Where Am I Ends Play"))
        reader.soundEffectService = sounds
        let generationBefore = reader.chapterPlaybackGeneration
        reader.whereAmIDelegate?.speechSynthesizer(AVSpeechSynthesizer(), didFinish: held.announcement)
        waitFor("the announcement's end") { !reader.isWhereAmISpeaking }

        reader.playOrResume()
        reader.play()

        XCTAssertNil(reader.audioPlaybackService.loadedURL, "A Play started the chapter before the end sound")
        XCTAssertTrue(reader.isChapterHeldByWhereAmI, "A Play took the chapter from Where Am I?")
        held.endSound.passEndSound()

        waitFor("the chapter to play") { reader.audioPlaybackService.isPlaying }
        XCTAssertEqual(Self.path(try XCTUnwrap(reader.audioPlaybackService.loadedURL)), Self.path(held.secondChapterFile))
        XCTAssertEqual(reader.chapterPlaybackGeneration, generationBefore + 1, "The chapter was not started exactly once")
        XCTAssertEqual(sounds.played, [.whereAmIEnd], "A sound beside the end sound was made")
        reader.stop()
    }

    /// The system cancelling Where Am I? on its own, as the speech engine
    /// does with a text it refuses, plays a chapter whose files came during
    /// the announcement at once, as the announcement's end would have
    /// played it: no end sound is owed, and the reader shows Playing.
    /// Before, the cancel paused the reader at the chapter, as Play/Pause
    /// does, and the play the listener had asked for was lost (REV13).
    func testAChapterHeldForWhereAmIPlaysAtOnceWhenTheSystemCancelsIt() throws {
        let cloud = try makeCloudReaders("Cloud Chapter Where Am I Cancelled", clone: Self.failingClone)
        let held = try chapterHeldForWhereAmI(in: cloud)
        let reader = held.reader

        reader.whereAmIDelegate?.speechSynthesizer(AVSpeechSynthesizer(), didCancel: held.announcement)

        waitFor("the chapter to play") { reader.audioPlaybackService.isPlaying }
        XCTAssertFalse(reader.isWhereAmISpeaking, "The cancel did not end the announcement")
        XCTAssertFalse(reader.isChapterHeldByWhereAmI)
        XCTAssertFalse(held.endSound.hasWorkWaiting, "Work waits for an end sound")
        XCTAssertTrue(reader.isCurrentlyPlaying)
        XCTAssertFalse(reader.isCurrentlyPaused, "The reader shows paused")
        XCTAssertEqual(Self.path(try XCTUnwrap(reader.audioPlaybackService.loadedURL)), Self.path(held.secondChapterFile))
        reader.stop()
    }

    /// The system cancelling Where Am I? while the files of the chapter
    /// about to play still download leaves the reader waiting for them, as
    /// the announcement's end would have: the download goes on, the reader
    /// shows Playing, and the chapter plays once its files are here.
    func testAChapterStillDownloadingWhenTheSystemCancelsWhereAmIPlaysOnceItIsHere() throws {
        let cloud = try makeCloudReaders("Cloud Chapter Where Am I Cancelled Downloading", clone: Self.failingClone)
        let (reader, book) = try readerWaitingForSecondChapter(in: cloud)
        let second = try chapterFile(number: 2, of: reader)
        let announcement = try speakWhereAmI(in: reader)
        let endSound = WhereAmIEndSoundClock(holdingFor: reader)

        reader.whereAmIDelegate?.speechSynthesizer(AVSpeechSynthesizer(), didCancel: announcement)
        waitFor("the cancel to end the announcement") { !reader.isWhereAmISpeaking }

        XCTAssertEqual(cloud.storage.downloadsCancelled, [], "The cancel stopped the chapter's download")
        XCTAssertTrue(reader.isWaitingForChapterDownload, "The reader no longer waits for the chapter")
        XCTAssertTrue(reader.isCurrentlyPlaying)
        XCTAssertFalse(reader.isCurrentlyPaused, "The cancel paused the reader")
        XCTAssertFalse(endSound.hasWorkWaiting, "Work waits for an end sound")

        cloud.cloudOnly.clear()
        cloud.storage.finishHeldDownload(of: book.id)

        waitFor("the chapter to play") { reader.audioPlaybackService.isPlaying }
        XCTAssertEqual(Self.path(try XCTUnwrap(reader.audioPlaybackService.loadedURL)), Self.path(second))
        reader.stop()
    }

    /// The library moves the package of a book whose chapter's files are
    /// downloading: the reader stops waiting before anything moves, since
    /// the download reads the package's files and plays them once they are
    /// here, and once the move is over it downloads the chapter again, from
    /// the package's new place, and plays it from there.
    func testPackageMoveDuringAChaptersDownloadDownloadsItAgainFromTheNewPlace() throws {
        let cloud = try makeCloudReaders("Cloud Chapter Move", clone: Self.failingClone)
        let (reader, book) = try readerWaitingForSecondChapter(in: cloud)
        cloud.storage.scriptDownload(of: book.id, steps: [Self.halfway], holdsOpen: true)
        let duringMove = PlayerDuringMove()
        let storage = cloud.storage
        let cloudOnly = cloud.cloudOnly
        let disk = LibraryTransitionDisk(
            moveItem: { source, destination in
                // `commitLibraryTransition` runs its disk work on the main
                // actor, where the reader lives.
                try MainActor.assumeIsolated {
                    duringMove.moves += 1
                    duringMove.loadedURL = reader.audioPlaybackService.loadedURL
                    duringMove.wasShowingDownload = reader.shownDownload != nil
                    duringMove.downloadsCancelled = storage.downloadsCancelled
                    try FileManager.default.moveItem(at: source, to: destination)
                    // A move within a cloud drive leaves the files in the cloud.
                    cloudOnly.markEverything()
                }
            },
            writeRecord: { book in
                try book.saveBookInfoThrowing()
            }
        )

        try cloud.world.library.commitLibraryTransition(
            Self.library(cloud.world.library.library, moving: book.id, to: "\(cloud.world.folder.path)/Shelf"),
            affectedBookIDs: [book.id],
            disk: disk
        )

        XCTAssertEqual(duringMove.moves, 1)
        XCTAssertEqual(duringMove.downloadsCancelled, [book.id], "The reader still waited while the package moved")
        XCTAssertFalse(duringMove.wasShowingDownload)
        XCTAssertNil(duringMove.loadedURL)
        waitFor("the chapter's download from the new place") { reader.shownDownload?.progress == Self.halfway }
        XCTAssertEqual(cloud.storage.downloadsStarted, [book.id, book.id])
        XCTAssertEqual(reader.shownDownload?.chapterNumber, 2)
        XCTAssertTrue(reader.isCurrentlyPlaying)

        cloud.cloudOnly.clear()
        cloud.storage.finishHeldDownload(of: book.id)

        try assertPlaysTheSecondChapterFromItsMovedPackage(book, reader: reader, in: cloud)
        reader.stop()
    }

    /// The library moves the package of a book whose chapter, downloaded
    /// while Where Am I? speaks, waits for the announcement: the chapter
    /// stays held through the move, nothing plays under the announcement,
    /// and the chapter plays from the package's new place once the
    /// announcement's end sound has played. Before, the move let the chapter
    /// go and its end played it at once, under the announcement.
    func testAPackageMoveKeepsAChapterHeldForWhereAmIUntilTheAnnouncementEnds() throws {
        let cloud = try makeCloudReaders("Cloud Chapter Where Am I Move", clone: Self.failingClone)
        let held = try chapterHeldForWhereAmI(in: cloud)
        let reader = held.reader

        try cloud.world.library.commitLibraryTransition(
            Self.library(cloud.world.library.library, moving: held.book.id, to: "\(cloud.world.folder.path)/Shelf"),
            affectedBookIDs: [held.book.id]
        )

        XCTAssertNil(reader.audioPlaybackService.loadedURL, "The chapter played under the announcement")
        XCTAssertTrue(reader.isChapterHeldByWhereAmI, "The move let go of the chapter Where Am I? holds")
        XCTAssertTrue(reader.isCurrentlyPlaying, "The reader stopped showing Playing")
        reader.whereAmIDelegate?.speechSynthesizer(AVSpeechSynthesizer(), didFinish: held.announcement)
        waitFor("the announcement's end") { !reader.isWhereAmISpeaking }
        XCTAssertNil(reader.audioPlaybackService.loadedURL, "The chapter played before the end sound")

        held.endSound.passEndSound()

        try assertPlaysTheSecondChapterFromItsMovedPackage(held.book, reader: reader, in: cloud)
        reader.stop()
    }

    /// Where Am I? ending by itself, and its end sound passing, while the
    /// package of a book holding a chapter for it moves, as a move made off
    /// the main thread allows, leaves the chapter to the move's end: nothing
    /// reads the package's files as they move, and the chapter plays from
    /// the new place once the move is over.
    func testAChapterHeldForWhereAmIThatEndsDuringAPackageMovePlaysOnceTheMoveIsOver() throws {
        let cloud = try makeCloudReaders("Cloud Chapter Where Am I Ends During Move", clone: Self.failingClone)
        let held = try chapterHeldForWhereAmI(in: cloud)
        let reader = held.reader
        let endSound = held.endSound
        let duringMove = PlayerDuringMove()
        let disk = LibraryTransitionDisk(
            moveItem: { source, destination in
                // `commitLibraryTransition` runs its disk work on the main
                // actor, where the reader lives.
                try MainActor.assumeIsolated {
                    reader.whereAmIAnnouncementFinished()
                    endSound.passEndSound()
                    duringMove.moves += 1
                    duringMove.loadedURL = reader.audioPlaybackService.loadedURL
                    try FileManager.default.moveItem(at: source, to: destination)
                }
            },
            writeRecord: { book in
                try book.saveBookInfoThrowing()
            }
        )

        try cloud.world.library.commitLibraryTransition(
            Self.library(cloud.world.library.library, moving: held.book.id, to: "\(cloud.world.folder.path)/Shelf"),
            affectedBookIDs: [held.book.id],
            disk: disk
        )

        XCTAssertEqual(duringMove.moves, 1)
        XCTAssertNil(duringMove.loadedURL, "The chapter played while its package moved")
        XCTAssertFalse(reader.isChapterHeldByWhereAmI, "Where Am I? still holds the chapter it left to the move")
        try assertPlaysTheSecondChapterFromItsMovedPackage(held.book, reader: reader, in: cloud)
        reader.stop()
    }

    /// In a library that is not in a cloud location, chapters play without
    /// any check, exactly as before.
    func testLocalLibraryPlaysChaptersWithoutCheckingThem() throws {
        let cloud = try makeCloudReaders("Cloud Local Chapters", location: .local, clone: Self.failingClone)
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

    // MARK: - The Next Chapter's File (PERF09)

    /// Without a working copy, the next chapter's file is named to follow the
    /// chapter playing, for the player to roll straight on into, only while
    /// it is on this Mac (TODO PERF09): a file only in the cloud is never
    /// queued, since the player would wait on the network for it, and its
    /// chapter downloads first when its turn comes, as it always has.
    func testNextChapterOnlyInTheCloudIsNotNamedToFollow() throws {
        let cloud = try makeCloudReaders("Cloud Next Chapter File", clone: Self.failingClone)
        let book = try cloud.world.makeSilentAudioBook(title: "Ferry Timetable", trackDurations: [2, 2])
        let reader = cloud.open(book)
        waitForReaderToLoad(reader)
        XCTAssertNil(reader.cloudSession.workingCopy)
        let files = reader.audioChapterFiles.map { Self.path($0) }
        cloud.cloudOnly.mark(try chapterFile(number: 2, of: reader))

        reader.play()

        XCTAssertTrue(reader.audioPlaybackService.isPlaying, "The first chapter did not play")
        XCTAssertEqual(reader.audioPlaybackService.queuedFilePaths, Array(files.prefix(1)), "A file only in the cloud was queued")

        reader.stop()
        cloud.cloudOnly.clear()
        reader.play()

        XCTAssertEqual(
            reader.audioPlaybackService.queuedFilePaths,
            files,
            "The next chapter's file, on this Mac now, was not queued"
        )
        reader.stop()
    }

    /// A working copy is on this Mac by construction, so the next chapter's
    /// file in the copy is named to follow, whatever the package's own files
    /// are doing in the cloud meanwhile.
    func testNextChapterFileOfAWorkingCopyIsNamedToFollow() throws {
        let cloud = try makeCloudReaders("Cloud Next Chapter Copy")
        let book = try cloud.world.makeSilentAudioBook(title: "Ferry Timetable", trackDurations: [2, 2])
        let reader = cloud.open(book)
        waitForReaderToLoad(reader)
        let copy = try XCTUnwrap(reader.cloudSession.workingCopy, "No working copy was made")
        cloud.cloudOnly.mark(try chapterFile(number: 2, of: reader))

        reader.play()

        XCTAssertEqual(
            reader.audioPlaybackService.queuedFilePaths,
            reader.audioChapterFiles.map { Self.path(copy.location(of: URL(fileURLWithPath: $0))) },
            "The next chapter's file in the working copy was not queued"
        )
        reader.stop()
    }

    /// A next chapter's file that goes back to the cloud after it was named
    /// to follow, as when the sync service removes its download meanwhile,
    /// never plays from the cloud: once the chapter before ends and the
    /// player has rolled on into it, the reader finds it only in the cloud,
    /// stops the player, and downloads the chapter first, showing Playing, as
    /// for any chapter only in the cloud. The chapter then plays from its
    /// start.
    func testPlaybackThatRolledOnIntoAFileGoneToTheCloudStopsWhileItDownloads() throws {
        let cloud = try makeCloudReaders("Cloud Next Chapter Gone", clone: Self.failingClone)
        let book = try cloud.world.makeSilentAudioBook(title: "Ferry Timetable", trackDurations: [0.6, 2])
        let reader = cloud.open(book)
        waitForReaderToLoad(reader)
        let second = try chapterFile(number: 2, of: reader)
        cloud.storage.scriptDownload(of: book.id, steps: [Self.halfway], holdsOpen: true)
        reader.play()
        XCTAssertEqual(
            reader.audioPlaybackService.queuedFilePaths,
            reader.audioChapterFiles.map { Self.path($0) },
            "The second chapter's file was not named to follow"
        )

        cloud.cloudOnly.mark(second)

        waitFor("the chapter's download") { reader.shownDownload?.progress == Self.halfway }
        XCTAssertEqual(reader.currentChapterIndex, 1)
        XCTAssertFalse(reader.audioPlaybackService.isPlaying, "The player went on playing a file only in the cloud")
        XCTAssertNil(reader.audioPlaybackService.loadedURL, "The player kept a file only in the cloud")
        XCTAssertTrue(reader.isCurrentlyPlaying, "The reader stopped showing Playing while it waited")

        cloud.cloudOnly.clear()
        cloud.storage.finishHeldDownload(of: book.id)
        waitFor("the chapter to play") { reader.audioPlaybackService.isPlaying }

        XCTAssertEqual(Self.path(try XCTUnwrap(reader.audioPlaybackService.loadedURL)), Self.path(second))
        XCTAssertEqual(reader.currentChapterIndex, 1)
        XCTAssertLessThan(reader.currentCharacterOffset, 10, "The chapter did not play from its start")
        reader.stop()
    }

    // MARK: - A Book Checked as Its Package Moves (TODO P10)

    /// The library moves a book's package in the moment its reader's load
    /// checks the book's cloud state, and the state found reaches the reader
    /// before the library says where the book is now. Checked where the book
    /// was, the package is gone, so the app's storage calls the book not
    /// arrived; or, in the middle of its move, the package cannot be listed,
    /// so the storage calls it not downloaded. The reader takes either for
    /// the move's doing: once the move is over it checks the book again where
    /// it is now and opens it, recording nothing of the first check, saying
    /// nothing of a sync, and downloading nothing. Before, it said the book
    /// had not arrived on this Mac, or downloaded it, and only Try Again
    /// opened it.
    func testABookCheckedAsItsPackageMovesOpensFromWhereItIsNow() throws {
        for foundDuringTheMove in [BookCloudState.waitingForSync, .inCloud] {
            let context = "\(foundDuringTheMove) found as the package moved"
            let cloud = try makeCloudReaders("Cloud Checked During Move \(foundDuringTheMove)")
            let book = try makeTextBook("Quay Notes", in: cloud)
            if foundDuringTheMove == .waitingForSync {
                cloud.observed.answerWaitingForSyncForMissingPackages()
            }
            let loads = holdLoads()
            let reader = cloud.open(book, loadQueue: loads.queue)
            let mark = announcementMark()
            let storage = cloud.storage

            try cloud.world.library.commitLibraryTransition(
                Self.library(cloud.world.library.library, moving: book.id, to: "\(cloud.world.folder.path)/Shelf"),
                affectedBookIDs: [book.id],
                disk: .movingPackages {
                    // A package in the middle of its move cannot be listed.
                    if foundDuringTheMove == .inCloud {
                        storage.setState(.inCloud, of: book.id)
                    }
                    loads.letReadAndHandOver()
                    storage.setState(.downloaded, of: book.id)
                }
            )

            assertOpensWithNothingSaid(reader, book, in: cloud, since: mark, context)
        }
    }

    /// The library's whole move of a book's package is over after the
    /// reader's load began but before it checks the book's cloud state. The
    /// check, made where the book was, finds no package there, so the app's
    /// storage calls the book not arrived; the reader, told where the book
    /// is now, checks it again there and opens it, saying nothing of a sync.
    func testABookCheckedAfterItsPackageMovedOpensFromWhereItIsNow() throws {
        let cloud = try makeCloudReaders("Cloud Checked After Move")
        let book = try makeTextBook("Quay Notes", in: cloud)
        cloud.observed.answerWaitingForSyncForMissingPackages()
        let loads = holdLoads()
        let reader = cloud.open(book, loadQueue: loads.queue)
        let mark = announcementMark()

        let move = outcome { await cloud.world.library.moveBooksReturningOutcome([book], toFolder: "\(cloud.world.folder.path)/Shelf") }
        XCTAssertTrue(move.succeeded, move.failureMessage ?? "")
        loads.letRead()

        assertOpensWithNothingSaid(reader, book, in: cloud, since: mark, "checked after the move")
    }

    /// A book is found downloaded just before the library moves its
    /// package, and what was found reaches the reader once the package has
    /// moved, so the reader goes on to read it while the move is under way.
    /// It reads nothing of the book until the move is over, not even where
    /// the book was: no file is checked, as every read of a book in a cloud
    /// library checks first that its files are on this Mac, though the
    /// reader's loads are let read. Then it checks the book again where it
    /// is now and opens it, saying nothing.
    func testABookFoundDownloadedAsItsPackageMovesIsReadOnceTheMoveIsOver() throws {
        let cloud = try makeCloudReaders("Cloud Read After Move")
        let book = try makeTextBook("Quay Notes", in: cloud)
        let loads = holdLoads()
        let reader = cloud.open(book, loadQueue: loads.queue)
        let mark = announcementMark()
        // The check finds the book downloaded before the move begins; what
        // it found waits on the main queue until the package has moved.
        loads.letReadBeforeHandingOver()
        let cloudOnly = cloud.cloudOnly
        let checksBefore = cloudOnly.checksMade
        let duringMove = ChecksDuringMove()

        try cloud.world.library.commitLibraryTransition(
            Self.library(cloud.world.library.library, moving: book.id, to: "\(cloud.world.folder.path)/Shelf"),
            affectedBookIDs: [book.id],
            disk: .movingPackages {
                // The first turn hands the reader what its check found; the
                // second lets any read that began then run and hand over.
                loads.letReadAndHandOver()
                loads.letReadAndHandOver()
                duringMove.checks = cloudOnly.checksMade - checksBefore
            }
        )

        XCTAssertEqual(duringMove.checks, 0, "The reader read the book as its package moved")
        assertOpensWithNothingSaid(reader, book, in: cloud, since: mark, "found downloaded as the package moved")
    }

    // MARK: - Fixtures

    /// How many of a book's files were checked while its package moved.
    @MainActor
    private final class ChecksDuringMove {
        var checks: Int?
    }

    /// Waits for `reader` to open `book` or stop, and checks that it opened
    /// from where the book is now, with no error, no cloud phase, and no
    /// download, the library list holding the book as downloaded, and
    /// nothing announced since `mark`; `context` begins each failure.
    private func assertOpensWithNothingSaid(
        _ reader: ReaderViewModel,
        _ book: Book,
        in cloud: CloudReaders,
        since mark: Int,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        waitFor("\(context): the book to open, or the reader to stop", file: file, line: line) {
            !reader.isLoading || reader.cloudPhase != nil
        }
        XCTAssertNil(reader.cloudPhase, "\(context): the reader stopped", file: file, line: line)
        XCTAssertNotNil(reader.content, "\(context): the book did not open", file: file, line: line)
        XCTAssertNil(reader.errorMessage, "\(context): the book did not open", file: file, line: line)
        XCTAssertEqual(
            reader.book.filePath,
            cloud.world.library.bookByID(book.id)?.filePath,
            "\(context): the reader does not name the book where it is now",
            file: file,
            line: line
        )
        XCTAssertEqual(cloud.storage.downloadsStarted, [], "\(context): the book was downloaded", file: file, line: line)
        XCTAssertEqual(cloud.states.state(of: book.id), .downloaded, "\(context): the library list", file: file, line: line)
        XCTAssertEqual(announcements(since: mark), [], "\(context): what was said", file: file, line: line)
    }

    /// Progress of `files` of `totalFiles` files, `bytes` of `totalBytes`.
    private static func progress(_ files: Int, of totalFiles: Int, bytes: Int64, of totalBytes: Int64) -> BookDownloadProgress {
        BookDownloadProgress(completedFiles: files, totalFiles: totalFiles, completedBytes: bytes, totalBytes: totalBytes)
    }

    /// A four-file download at 0, 25, 50, and 75 percent.
    private static let quarterSteps = (0...3).map { progress($0, of: 4, bytes: Int64($0) * 100, of: 400) }

    /// A two-file download with one file here.
    private static let halfway = progress(1, of: 2, bytes: 100, of: 200)

    /// A reader of a two-chapter audiobook in `cloud`'s library, playing
    /// without a working copy and waiting for the download of its second
    /// chapter, whose file is only in the cloud: the download has reported
    /// `halfway` and is held open.
    private func readerWaitingForSecondChapter(in cloud: CloudReaders) throws -> (ReaderViewModel, Book) {
        let book = try cloud.world.makeSilentAudioBook(title: "Ferry Timetable", trackDurations: [2, 2])
        let reader = cloud.open(book)
        waitForReaderToLoad(reader)
        cloud.cloudOnly.mark(try chapterFile(number: 2, of: reader))
        cloud.storage.scriptDownload(of: book.id, steps: [Self.halfway], holdsOpen: true)
        reader.play()
        reader.navigateTo(chapterIndex: 1, characterOffset: 0)
        waitFor("the chapter's download") { reader.shownDownload?.progress == Self.halfway }
        return (reader, book)
    }

    /// A reader holding the second chapter of its book for a Where Am I?
    /// announcement, and what a test needs of it.
    private struct ChapterHeldForWhereAmI {
        let reader: ReaderViewModel
        let book: Book
        /// The file the held chapter plays from where the book was opened.
        let secondChapterFile: String
        /// The announcement speaking, handed over in place of the synthesizer.
        let announcement: AVSpeechUtterance
        /// Holds what the announcement leaves for once its end sound has
        /// played, until the test lets the sound pass.
        let endSound: WhereAmIEndSoundClock
    }

    /// A reader of a two-chapter audiobook in `cloud`'s library, waiting for
    /// the download of its second chapter (`readerWaitingForSecondChapter`),
    /// whose files come while Where Am I? speaks, so that the chapter waits
    /// for the announcement's end to play.
    private func chapterHeldForWhereAmI(
        in cloud: CloudReaders,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ChapterHeldForWhereAmI {
        let (reader, book) = try readerWaitingForSecondChapter(in: cloud)
        let second = try chapterFile(number: 2, of: reader, file: file, line: line)
        let announcement = try speakWhereAmI(in: reader, file: file, line: line)
        let endSound = WhereAmIEndSoundClock(holdingFor: reader)
        cloud.cloudOnly.clear()
        cloud.storage.finishHeldDownload(of: book.id)
        waitFor("the download's end", file: file, line: line) { reader.cloudPhase == nil }
        return ChapterHeldForWhereAmI(
            reader: reader,
            book: book,
            secondChapterFile: second,
            announcement: announcement,
            endSound: endSound
        )
    }

    /// Waits for `reader` to play, and checks that it plays `book`'s second
    /// chapter from the book's package where the library has moved it.
    private func assertPlaysTheSecondChapterFromItsMovedPackage(
        _ book: Book,
        reader: ReaderViewModel,
        in cloud: CloudReaders,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        waitFor("the chapter to play", file: file, line: line) { reader.audioPlaybackService.isPlaying }
        let moved = try XCTUnwrap(cloud.world.library.bookByID(book.id), "The book left the library", file: file, line: line)
        let playing = try XCTUnwrap(reader.audioPlaybackService.loadedURL, "Nothing plays", file: file, line: line)
        XCTAssertTrue(
            Self.path(playing).hasPrefix(Self.path(moved.filePath) + "/"),
            "\(playing.path) is not in the moved package",
            file: file,
            line: line
        )
        XCTAssertEqual(reader.currentChapterIndex, 1, "Another chapter plays", file: file, line: line)
    }

    /// Presses Where Am I? in `reader`, which hands its announcement to a
    /// recorder in place of its synthesizer, so that nothing is heard, and
    /// returns the announcement handed over.
    private func speakWhereAmI(
        in reader: ReaderViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> AVSpeechUtterance {
        let handedOver = HandedOverWhereAmI()
        reader._whereAmIUtteranceRecorderForTesting = { handedOver.utterances.append($0) }
        reader.whereAmI()
        XCTAssertTrue(reader.isWhereAmISpeaking, "Where Am I does not speak", file: file, line: line)
        return try XCTUnwrap(handedOver.utterances.last, "No announcement was handed over", file: file, line: line)
    }

    /// Checks that `reader`, which stopped waiting for its chapter's
    /// download, plays nothing when the sync service finishes the download
    /// anyway, with the chapter's files then on this Mac.
    private func assertNothingPlaysOnceTheDownloadEnds(
        for book: Book,
        in cloud: CloudReaders,
        reader: ReaderViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        cloud.cloudOnly.clear()
        cloud.storage.finishHeldDownload(of: book.id)
        // A download that ends plays its chapter within a turn or two of the
        // main run loop; give it far longer before deciding it never will.
        let played = waitUntil(timeout: 0.5) { reader.audioPlaybackService.loadedURL != nil }
        XCTAssertFalse(played, "The chapter played once its download ended", file: file, line: line)
        XCTAssertNil(reader.cloudPhase, file: file, line: line)
    }

    /// A cloner that always fails, so a reader has no working copy.
    private static let failingClone: ReaderWorkingCopies.Cloner = { _, _ in throw CocoaError(.fileWriteUnknown) }

    /// A text book titled `title`, imported into `cloud`'s library folder.
    private func makeTextBook(_ title: String, in cloud: CloudReaders) throws -> Book {
        let source = try makeSandboxDirectory("\(title) Source").appendingPathComponent("\(title).txt")
        try "\(title)\n\nThe tide came in over the mudflats and lifted the moored boats one by one."
            .write(to: source, atomically: true, encoding: .utf8)
        return try cloud.world.importBook(from: source)
    }

    /// A single-file audiobook titled `title`: one silent WAV file in a
    /// package of its own in `cloud`'s library folder, indexed as an import
    /// indexes it and listed in the library.
    private func makeSingleFileAudioBook(_ title: String, in cloud: CloudReaders) throws -> Book {
        let world = cloud.world
        let packageName = "\(UUID().uuidString).tmb"
        let file = TextMouthPaths.tmbPath(folderPath: world.folder.path, tmbName: packageName)
            .appendingPathComponent("\(title).wav")
        try AudioTestFixtures.writeSilence(to: file, duration: 2)
        let book = Book(
            title: title,
            format: .audio,
            filePath: file.path,
            md5Hash: UUID().uuidString,
            folderPath: world.folder.path,
            tmbDirectoryName: packageName,
            localEndOfBookBehavior: EndOfBookBehavior.stop.rawValue
        )
        let analysis = try BookContentAnalysisService.load(book: book)
        try book.saveBookInfoThrowing(contentIndex: analysis.index)
        world.library.library.addBook(book)
        return book
    }

    /// `library` with the book `bookID` in the folder `folderPath`, as Move
    /// to Folder… proposes it to the library's transition.
    private static func library(_ library: Library, moving bookID: UUID, to folderPath: String) -> Library {
        var proposed = library
        for index in proposed.books.indices where proposed.books[index].id == bookID {
            proposed.books[index].folderPath = folderPath
        }
        return proposed
    }

    /// What a reader's player was doing as a package moved. Main-actor
    /// isolated, as the disk operations of `commitLibraryTransition` run
    /// there.
    @MainActor
    private final class PlayerDuringMove {
        /// How many packages moved.
        var moves = 0
        /// Whether the player was playing at the last move.
        var wasPlaying = false
        /// The file it held at the last move.
        var loadedURL: URL?
        /// Whether the reader showed a chapter's download at the last move.
        var wasShowingDownload = false
        /// The books whose downloads the storage had seen cancelled by the
        /// last move.
        var downloadsCancelled: [UUID] = []
    }

    /// The disk operations of a library transition, noting into `observation`
    /// what `reader`'s player does as each package moves.
    private func observingDisk(_ reader: ReaderViewModel, into observation: PlayerDuringMove) -> LibraryTransitionDisk {
        LibraryTransitionDisk(
            moveItem: { source, destination in
                // `commitLibraryTransition` runs its disk work on the main
                // actor, where the reader lives.
                try MainActor.assumeIsolated {
                    observation.moves += 1
                    observation.wasPlaying = reader.audioPlaybackService.isPlaying
                    observation.loadedURL = reader.audioPlaybackService.loadedURL
                    try FileManager.default.moveItem(at: source, to: destination)
                }
            },
            writeRecord: { book in
                try book.saveBookInfoThrowing()
            }
        )
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

    /// The file `reader` plays chapter `number` from, counted from one, as
    /// the reader found the book's chapter files. A book without that
    /// chapter fails the test rather than trapping, since every test host
    /// that traps shows the user a crash dialog.
    private func chapterFile(
        number: Int,
        of reader: ReaderViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        let files = reader.audioChapterFiles
        let index = number - 1
        return try XCTUnwrap(
            files.indices.contains(index) ? files[index] : nil,
            "\(reader.book.title) has no chapter \(number) among \(files.count) chapter files",
            file: file,
            line: line
        )
    }

    /// The names in `folder`, or none when it does not exist.
    private static func entries(of folder: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
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
/// is and how each download goes, a store of cloud states, a Working Copies
/// folder, and the files the test says are only in the cloud.
@MainActor
private final class CloudReaders {
    /// The readers' surroundings and the library folder of their books.
    let world: IntegrationWorld
    /// Where the library is, each book's state, and its downloads.
    let storage: FakeBookCloudStorage
    /// The storage the readers ask: `storage`'s answers, except that a test
    /// can have it find a package missing from disk waiting for sync, as the
    /// app's storage does (TODO P10).
    let observed: ObservedBookStorage
    /// What the readers record for the library list.
    let states = BookCloudStates()
    /// The Working Copies folder.
    let copiesFolder: URL
    /// The working copies made there.
    let copies: ReaderWorkingCopies
    /// The files only in the cloud.
    let cloudOnly = CloudOnlyFiles()
    /// How often the readers announce a download without a percentage.
    var quietAnnouncementInterval: TimeInterval = 30
    /// The Now Playing coordinator the readers opened from now on join: the
    /// app's shared one unless a test gives its own, to send the readers
    /// the system's commands as MediaPlayer does.
    var nowPlaying: NowPlayingService?
    /// Every reader opened, closed when the test ends.
    private(set) var readers: [ReaderViewModel] = []

    init(world: IntegrationWorld, location: StorageLocation, copiesFolder: URL, clone: ReaderWorkingCopies.Cloner?) {
        self.world = world
        storage = FakeBookCloudStorage(location: location)
        observed = ObservedBookStorage(storage)
        self.copiesFolder = copiesFolder
        copies = clone.map { ReaderWorkingCopies(folder: copiesFolder, clone: $0) }
            ?? ReaderWorkingCopies(folder: copiesFolder)
    }

    /// The sync service of the library's location.
    var provider: CloudProvider? {
        storage.libraryLocation().provider
    }

    /// Opens a reader for `book`, which starts getting it ready at once,
    /// claiming its autoplay requests from `autoplayRequests`, or from the
    /// world's when nil, and reading the book on `loadQueue`, which a test
    /// can hold (a global queue when nil, as in the app).
    ///
    /// The reader is in a window of its own, as a book opened from the
    /// Library is: it gets `sleepTimer`, or a sleep timer of its own when nil,
    /// so no two readers opened here share one.
    func open(
        _ book: Book,
        autoplayRequests: ReaderAutoplayRequests? = nil,
        loadQueue: DispatchQueue? = nil,
        sleepTimer: SleepTimerService? = nil
    ) -> ReaderViewModel {
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: world.library,
            settingsViewModel: world.settings,
            substitutionService: TextSubstitutionService(rules: []),
            autoplayRequests: autoplayRequests ?? world.autoplayRequests,
            notificationCenter: world.notifications,
            cloud: ReaderCloudServices(
                storage: observed,
                states: states,
                isDataless: cloudOnly.check,
                workingCopies: copies,
                quietAnnouncementInterval: quietAnnouncementInterval
            ),
            nowPlaying: nowPlaying,
            loadQueue: loadQueue,
            sleepTimer: sleepTimer ?? SleepTimerService()
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
    /// `location`, whose working copies `clone` makes (the app's clone when
    /// nil). Its readers are closed when the test ends, before its folders
    /// are removed.
    @MainActor
    fileprivate func makeCloudReaders(
        _ label: String,
        location: StorageLocation = .cloud(.iCloudDrive),
        clone: ReaderWorkingCopies.Cloner? = nil
    ) throws -> CloudReaders {
        let world = try makeIntegrationWorld(label)
        let copiesFolder = try makeSandboxDirectory("\(label) Working Copies")
        let cloud = CloudReaders(world: world, location: location, copiesFolder: copiesFolder, clone: clone)
        addTeardownBlock { cloud.closeReaders() }
        return cloud
    }
}

/// The utterances a reader's Where Am I? handed over in place of its
/// synthesizer, oldest first.
private final class HandedOverWhereAmI {
    var utterances: [AVSpeechUtterance] = []
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
    /// How many checks were made.
    private var checks = 0

    /// How many checks were made so far: each read of a book in a cloud
    /// library begins with one (`LocalBookFiles.requireOnThisMac`), as
    /// does each check of a chapter's files.
    var checksMade: Int {
        lock.withLock { checks }
    }

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
            checks += 1
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

/// A clock a test moves by hand, which dates and ages autoplay requests.
/// Read and moved only on the main actor, by the test and the store.
private final class RequestClock {
    /// The time the clock reads now.
    var now = Date(timeIntervalSinceReferenceDate: 812_000_000)
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

    /// A part of the one file left, reported by its sync service, gives the
    /// bar its percentage in the words of any other, "0 of 1 file, 40%"
    /// shown and "0 of 1 file, 40 percent" spoken, whether progress goes by
    /// size or by files. A part under 1 percent gives none yet.
    func testAPartOfTheOneFileLeftGivesThePercentage() {
        let parts = [
            BookDownloadProgress(completedFiles: 0, totalFiles: 1, completedBytes: 124_800_000, totalBytes: 312_000_000),
            BookDownloadProgress(completedFiles: 0, totalFiles: 1, completedBytes: 0, totalBytes: 0, partialFiles: 0.4),
        ]

        for progress in parts {
            let download = Self.download(progress: progress)
            XCTAssertEqual(ReaderCloudWording.fraction(of: download) ?? 0, 0.4, accuracy: 1e-9, "\(progress)")
            XCTAssertEqual(ReaderCloudWording.progressValue(of: download, elapsed: 65, spoken: false), "0 of 1 file, 40%")
            XCTAssertEqual(ReaderCloudWording.progressValue(of: download, elapsed: 65, spoken: true), "0 of 1 file, 40 percent")
        }
        let tinyPart = BookDownloadProgress(completedFiles: 0, totalFiles: 1, completedBytes: 0, totalBytes: 0, partialFiles: 0.005)
        XCTAssertTrue(ReaderCloudWording.showsNoPercentage(tinyPart))
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
