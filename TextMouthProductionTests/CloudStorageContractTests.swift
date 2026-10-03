import Combine
import Darwin
import XCTest
@testable import TextMouth

/// The FR02 cloud contract's own logic (CloudStorageContract.swift): the
/// progress arithmetic, the wording of every state and error, the shared
/// store of book states, the local placeholders the app uses until the real
/// services are installed, and the dataless-file helpers. The real services
/// behind the protocols have test classes of their own.
@MainActor
final class CloudStorageContractTests: XCTestCase {

    // MARK: - Where a Folder Lives

    /// Each provider is named as TextMouth shows and speaks it, and another
    /// drive by its folder's name.
    func testEachProviderHasItsDisplayName() {
        XCTAssertEqual(CloudProvider.iCloudDrive.displayName, "iCloud Drive")
        XCTAssertEqual(CloudProvider.googleDrive.displayName, "Google Drive")
        XCTAssertEqual(CloudProvider.dropbox.displayName, "Dropbox")
        XCTAssertEqual(CloudProvider.other("OneDrive").displayName, "OneDrive")
    }

    /// Only a cloud location is cloud, and only it names a provider: an
    /// external drive is not a cloud location.
    func testOnlyACloudLocationIsCloudAndHasAProvider() {
        XCTAssertFalse(StorageLocation.local.isCloud)
        XCTAssertNil(StorageLocation.local.provider)
        XCTAssertFalse(StorageLocation.otherVolume(name: "Archive Disk").isCloud)
        XCTAssertNil(StorageLocation.otherVolume(name: "Archive Disk").provider)
        XCTAssertTrue(StorageLocation.cloud(.dropbox).isCloud)
        XCTAssertEqual(StorageLocation.cloud(.dropbox).provider, .dropbox)
    }

    // MARK: - One File

    /// A local file's status carries its size and nothing waiting: it counts
    /// as uploaded, with no conflicts and no error. A missing file's status
    /// has no size.
    func testLocalAndMissingStatuses() {
        XCTAssertEqual(
            CloudItemStatus.local(byteCount: 2_048),
            CloudItemStatus(state: .local, isUploaded: true, byteCount: 2_048, hasUnresolvedConflicts: false, downloadError: nil)
        )
        XCTAssertEqual(
            CloudItemStatus.missing,
            CloudItemStatus(state: .missing, isUploaded: true, byteCount: nil, hasUnresolvedConflicts: false, downloadError: nil)
        )
    }

    // MARK: - One Book

    /// A book with a package is described by its package folder, and an old
    /// book without one by its own file; an audiobook says so.
    func testABooksPackageIsItsFolderOrItsFile() {
        let audiobook = Book(
            title: "Ferry Timetables of the Inner Sound",
            author: "Odile Varga",
            format: .audio,
            filePath: "/nowhere/timetables.m4b",
            md5Hash: "",
            folderPath: "Travel",
            tmbDirectoryName: "Ferry_Timetables-Odile_Varga-1700000000-a.tmb"
        )
        let packaged = BookPackage(audiobook)
        XCTAssertEqual(packaged.bookID, audiobook.id)
        XCTAssertEqual(packaged.url, audiobook.tmbDirectory)
        XCTAssertTrue(packaged.isPackage)
        XCTAssertTrue(packaged.isAudio)

        let oldBook = Book(title: "Ledger of a Small Canal", format: .epub, filePath: "/nowhere/ledger.epub", md5Hash: "")
        let loose = BookPackage(oldBook)
        XCTAssertEqual(loose.bookID, oldBook.id)
        XCTAssertEqual(loose.url, URL(fileURLWithPath: "/nowhere/ledger.epub"))
        XCTAssertFalse(loose.isPackage)
        XCTAssertFalse(loose.isAudio)
    }

    // MARK: - Download Progress

    /// With sizes known, progress goes by bytes, whatever the file count says.
    func testProgressGoesByBytesWhenSizesAreKnown() {
        let progress = BookDownloadProgress(completedFiles: 1, totalFiles: 3, completedBytes: 400, totalBytes: 1_000)

        XCTAssertEqual(progress.fractionCompleted, 0.4, accuracy: 1e-9)
        XCTAssertEqual(progress.percent, 40)
    }

    /// With no size known, as when every file reports 0 bytes (evicted
    /// iCloud Drive files can), progress goes by files, rounded down.
    func testProgressGoesByFilesWhenNoSizeIsKnown() {
        let progress = BookDownloadProgress(completedFiles: 2, totalFiles: 3, completedBytes: 0, totalBytes: 0)

        XCTAssertEqual(progress.fractionCompleted, 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(progress.percent, 66)
    }

    /// A book with no files and no sizes has made no progress at all.
    func testProgressOfABookWithNothingCountedIsZero() {
        let progress = BookDownloadProgress(completedFiles: 0, totalFiles: 0, completedBytes: 0, totalBytes: 0)

        XCTAssertEqual(progress.fractionCompleted, 0)
        XCTAssertEqual(progress.percent, 0)
    }

    /// The percent rounds down, so a book never claims a whole percent it
    /// has not reached.
    func testPercentRoundsDown() {
        let progress = BookDownloadProgress(completedFiles: 2, totalFiles: 3, completedBytes: 999, totalBytes: 1_000)

        XCTAssertEqual(progress.percent, 99)
    }

    /// A missing file keeps the percent below 100 even when the files already
    /// here hold every reported byte, since a file can report a size of 0.
    func testPercentIsNever100WhileAFileIsStillMissing() {
        let progress = BookDownloadProgress(completedFiles: 2, totalFiles: 3, completedBytes: 1_000, totalBytes: 1_000)

        XCTAssertEqual(progress.fractionCompleted, 1)
        XCTAssertEqual(progress.percent, 99)
    }

    /// Every file here is 100 percent, whether counted by bytes or by files.
    func testEveryFileHereIs100Percent() {
        let bySize = BookDownloadProgress(completedFiles: 3, totalFiles: 3, completedBytes: 1_000, totalBytes: 1_000)
        let byCount = BookDownloadProgress(completedFiles: 3, totalFiles: 3, completedBytes: 0, totalBytes: 0)

        XCTAssertEqual(bySize.percent, 100)
        XCTAssertEqual(byCount.percent, 100)
    }

    /// Sizes that grow during a download, so the bytes here exceed the total
    /// counted earlier, never take progress past 1.
    func testProgressNeverPassesOne() {
        let progress = BookDownloadProgress(completedFiles: 3, totalFiles: 3, completedBytes: 1_500, totalBytes: 1_000)

        XCTAssertEqual(progress.fractionCompleted, 1)
        XCTAssertEqual(progress.percent, 100)
    }

    /// By files, the parts reported of files still arriving count as parts
    /// of a file: one file of two here and the other 40 percent here is 70
    /// percent. By size those parts are bytes, so `partialFiles` plays no
    /// part.
    func testPartsOfFilesStillArrivingCountByFiles() {
        let byFiles = BookDownloadProgress(completedFiles: 1, totalFiles: 2, completedBytes: 0, totalBytes: 0, partialFiles: 0.4)
        let bySize = BookDownloadProgress(completedFiles: 1, totalFiles: 2, completedBytes: 700, totalBytes: 1_000, partialFiles: 0.9)

        XCTAssertEqual(byFiles.fractionCompleted, 0.7, accuracy: 1e-9)
        XCTAssertEqual(byFiles.percent, 70)
        XCTAssertEqual(bySize.percent, 70)
    }

    /// A file reported whole a moment before it is on this Mac leaves the
    /// percent at 99 by files, as it does by size.
    func testAFileReportedWholeIsNotDoneUntilItIsHere() {
        let progress = BookDownloadProgress(completedFiles: 1, totalFiles: 2, completedBytes: 0, totalBytes: 0, partialFiles: 1)

        XCTAssertEqual(progress.fractionCompleted, 1)
        XCTAssertEqual(progress.percent, 99)
    }

    // MARK: - Book States

    /// The note the list shows and the note VoiceOver speaks, for every
    /// state. Only a download's progress is spoken differently, with its
    /// percent as a word; a local library says nothing.
    func testEveryStatesVisibleAndSpokenNotes() {
        let progress = BookDownloadProgress(completedFiles: 1, totalFiles: 3, completedBytes: 400, totalBytes: 1_000)
        // Every case of BookCloudState, with its visible and spoken notes.
        let expectations: [(state: BookCloudState, visible: String?, spoken: String?)] = [
            (.local, nil, nil),
            (.downloaded, "Downloaded", "Downloaded"),
            (.inCloud, "In Cloud", "In Cloud"),
            (.downloading(progress), "Downloading 40%", "Downloading, 40 percent"),
            (.downloadFailed("The network connection was lost."), "Download Failed", "Download Failed"),
            (.waitingForSync, "Waiting for Sync", "Waiting for Sync"),
        ]

        for expectation in expectations {
            XCTAssertEqual(expectation.state.visibleNote, expectation.visible, "\(expectation.state)")
            XCTAssertEqual(expectation.state.spokenNote, expectation.spoken, "\(expectation.state)")
        }
    }

    // MARK: - Errors

    /// Every error's sentence, naming the library's provider.
    func testEveryExplanationNamesTheProvider() {
        let drive = CloudProvider.googleDrive

        XCTAssertEqual(
            BookCloudError.offline.explanation(in: drive),
            "This Mac is offline, so the book can't be downloaded from Google Drive. "
                + "Connect to the internet and try again."
        )
        XCTAssertEqual(
            BookCloudError.stalled(seconds: 60).explanation(in: drive),
            "Google Drive hasn't downloaded anything for 60 seconds. It may be paused, signed out, or not running."
        )
        XCTAssertEqual(
            BookCloudError.provider("The disk is full.").explanation(in: drive),
            "Google Drive couldn't download the book: The disk is full."
        )
        XCTAssertEqual(
            BookCloudError.notUploaded.explanation(in: drive),
            "Some changes to this book haven't been uploaded to Google Drive yet, "
                + "so its download can't be removed. Try again in a moment."
        )
        XCTAssertEqual(
            BookCloudError.bookIsOpen.explanation(in: drive),
            "The book is open, so its download can't be removed. Close it first."
        )
        XCTAssertEqual(
            BookCloudError.removalFailed("The file is locked.").explanation(in: drive),
            "Google Drive couldn't remove the book's download: The file is locked."
        )
        XCTAssertEqual(
            BookCloudError.packageMissing.explanation(in: drive),
            "The book's files aren't on this Mac yet. Google Drive may still be syncing them."
        )
    }

    /// Another drive is named by its folder's name.
    func testAnExplanationNamesAnotherDriveByItsFolder() {
        XCTAssertEqual(
            BookCloudError.offline.explanation(in: .other("OneDrive")),
            "This Mac is offline, so the book can't be downloaded from OneDrive. Connect to the internet and try again."
        )
    }

    /// With no provider known, each sentence says "the cloud service" where
    /// it would name one, capitalized where it begins a sentence: a braille
    /// display shows the difference.
    func testEveryExplanationWithoutAProviderSaysTheCloudService() {
        XCTAssertEqual(
            BookCloudError.offline.explanation(in: nil),
            "This Mac is offline, so the book can't be downloaded from the cloud service. "
                + "Connect to the internet and try again."
        )
        XCTAssertEqual(
            BookCloudError.stalled(seconds: 45).explanation(in: nil),
            "The cloud service hasn't downloaded anything for 45 seconds. It may be paused, signed out, or not running."
        )
        XCTAssertEqual(
            BookCloudError.provider("Access denied.").explanation(in: nil),
            "The cloud service couldn't download the book: Access denied."
        )
        XCTAssertEqual(
            BookCloudError.notUploaded.explanation(in: nil),
            "Some changes to this book haven't been uploaded to the cloud service yet, "
                + "so its download can't be removed. Try again in a moment."
        )
        XCTAssertEqual(
            BookCloudError.bookIsOpen.explanation(in: nil),
            "The book is open, so its download can't be removed. Close it first."
        )
        XCTAssertEqual(
            BookCloudError.removalFailed("Access denied.").explanation(in: nil),
            "The cloud service couldn't remove the book's download: Access denied."
        )
        XCTAssertEqual(
            BookCloudError.packageMissing.explanation(in: nil),
            "The book's files aren't on this Mac yet. The cloud service may still be syncing them."
        )
    }

    // MARK: - The Shared Store

    /// Recording a state publishes a change; recording the same state again
    /// publishes nothing. A download's new progress is a change.
    func testRecordPublishesOnlyChanges() {
        let store = BookCloudStates()
        let bookID = UUID()
        var changes = 0
        let subscription = store.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }

        store.record(.inCloud, for: bookID)
        store.record(.inCloud, for: bookID)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(store.state(of: bookID), .inCloud)

        let quarter = BookDownloadProgress(completedFiles: 1, totalFiles: 4, completedBytes: 0, totalBytes: 0)
        let half = BookDownloadProgress(completedFiles: 2, totalFiles: 4, completedBytes: 0, totalBytes: 0)
        store.record(.downloading(quarter), for: bookID)
        store.record(.downloading(quarter), for: bookID)
        store.record(.downloading(half), for: bookID)
        XCTAssertEqual(changes, 3)
        XCTAssertEqual(store.state(of: bookID), .downloading(half))
    }

    /// A book that has not been checked has no state.
    func testABookNotCheckedHasNoState() {
        XCTAssertNil(BookCloudStates().state(of: UUID()))
    }

    /// Moving between cloud locations keeps every book's state, and the
    /// notes stay on.
    func testMovingBetweenCloudLocationsKeepsEveryState() {
        let store = BookCloudStates()
        let bookID = UUID()
        store.setLibraryLocation(.cloud(.iCloudDrive))
        store.record(.inCloud, for: bookID)

        store.setLibraryLocation(.cloud(.dropbox))

        XCTAssertEqual(store.libraryLocation, .cloud(.dropbox))
        XCTAssertTrue(store.showsCloudNotes)
        XCTAssertEqual(store.state(of: bookID), .inCloud)
    }

    /// Leaving a cloud location, for the startup disk or another volume,
    /// forgets every book's state and turns the notes off.
    func testSettingANonCloudLocationClearsEveryState() {
        for location in [StorageLocation.local, .otherVolume(name: "Archive Disk")] {
            let store = BookCloudStates()
            store.setLibraryLocation(.cloud(.googleDrive))
            store.record(.inCloud, for: UUID())
            store.record(.downloaded, for: UUID())
            XCTAssertTrue(store.showsCloudNotes)

            store.setLibraryLocation(location)

            XCTAssertEqual(store.libraryLocation, location)
            XCTAssertEqual(store.states, [:], "\(location)")
            XCTAssertFalse(store.showsCloudNotes, "\(location)")
        }
    }

    /// Setting the location the store already has publishes nothing.
    func testSettingTheSameLocationPublishesNothing() {
        let store = BookCloudStates()
        store.setLibraryLocation(.cloud(.iCloudDrive))
        var changes = 0
        let subscription = store.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }

        store.setLibraryLocation(.cloud(.iCloudDrive))

        XCTAssertEqual(changes, 0)
    }

    /// `reset()` forgets every book's state but keeps the location.
    func testResetForgetsEveryStateButKeepsTheLocation() {
        let store = BookCloudStates()
        store.setLibraryLocation(.cloud(.iCloudDrive))
        store.record(.inCloud, for: UUID())

        store.reset()

        XCTAssertEqual(store.states, [:])
        XCTAssertEqual(store.libraryLocation, .cloud(.iCloudDrive))
    }

    /// A refresh records where the library lives and the state of each book
    /// it was given.
    func testRefreshRecordsTheLocationAndEachBooksState() async {
        let storage = FakeBookCloudStorage(location: .cloud(.googleDrive))
        let inCloud = Self.package()
        let downloaded = Self.package()
        storage.setState(.inCloud, of: inCloud.bookID)
        let store = BookCloudStates()

        await store.refresh([inCloud, downloaded], using: storage)

        XCTAssertEqual(store.libraryLocation, .cloud(.googleDrive))
        XCTAssertEqual(store.state(of: inCloud.bookID), .inCloud)
        XCTAssertEqual(store.state(of: downloaded.bookID), .downloaded, "the fake's default state")
    }

    /// A book TextMouth is downloading keeps its download's progress through
    /// a refresh, which records the other books; once the download ends, a
    /// refresh records the book's state again.
    func testRefreshLeavesABookToItsRunningDownload() async {
        let storage = FakeBookCloudStorage(location: .cloud(.iCloudDrive))
        let downloading = Self.package()
        let other = Self.package()
        storage.setState(.inCloud, of: downloading.bookID)
        storage.setState(.inCloud, of: other.bookID)
        let progress = BookDownloadProgress(completedFiles: 1, totalFiles: 2, completedBytes: 10, totalBytes: 40)
        let store = BookCloudStates()
        store.setLibraryLocation(.cloud(.iCloudDrive))
        store.beginDownload(of: downloading.bookID)
        store.record(.downloading(progress), for: downloading.bookID)

        await store.refresh([downloading, other], using: storage)

        XCTAssertEqual(store.state(of: downloading.bookID), .downloading(progress))
        XCTAssertEqual(store.state(of: other.bookID), .inCloud)

        store.endDownload(of: downloading.bookID)
        await store.refresh([downloading, other], using: storage)

        XCTAssertEqual(store.state(of: downloading.bookID), .inCloud)
    }

    /// A download only the sync service reports, such as one Finder started,
    /// is refreshed like any other state, so its row never stays
    /// "Downloading" once it ends.
    func testRefreshFollowsADownloadNoOneInTextMouthRuns() async {
        let storage = FakeBookCloudStorage(location: .cloud(.dropbox))
        let book = Self.package()
        let progress = BookDownloadProgress(completedFiles: 0, totalFiles: 2, completedBytes: 0, totalBytes: 0)
        let store = BookCloudStates()

        storage.setState(.downloading(progress), of: book.bookID)
        await store.refresh([book], using: storage)
        XCTAssertEqual(store.state(of: book.bookID), .downloading(progress))

        storage.setState(.downloaded, of: book.bookID)
        await store.refresh([book], using: storage)
        XCTAssertEqual(store.state(of: book.bookID), .downloaded)
    }

    /// A refresh leaves a book alone until every download begun for it has
    /// ended, as when the reader and the list both download it.
    func testRefreshWaitsForEveryRunningDownloadOfABookToEnd() async {
        let storage = FakeBookCloudStorage(location: .cloud(.googleDrive))
        let book = Self.package()
        let progress = BookDownloadProgress(completedFiles: 1, totalFiles: 3, completedBytes: 0, totalBytes: 0)
        let store = BookCloudStates()
        store.beginDownload(of: book.bookID)
        store.beginDownload(of: book.bookID)
        store.record(.downloading(progress), for: book.bookID)

        store.endDownload(of: book.bookID)
        await store.refresh([book], using: storage)
        XCTAssertEqual(store.state(of: book.bookID), .downloading(progress), "one download still runs")

        store.endDownload(of: book.bookID)
        await store.refresh([book], using: storage)
        XCTAssertEqual(store.state(of: book.bookID), .downloaded, "the fake's default state")
    }

    /// A refresh that was reading while a book's download ended leaves the
    /// book alone: its reading is older than the state the download recorded.
    func testRefreshSkipsABookWhoseDownloadEndedWhileItWasReading() async {
        let progress = BookDownloadProgress(completedFiles: 1, totalFiles: 2, completedBytes: 0, totalBytes: 0)
        let storage = GatedBookStorage(reporting: .downloading(progress))
        let book = Self.package()
        let store = BookCloudStates()
        store.setLibraryLocation(.cloud(.iCloudDrive))
        store.beginDownload(of: book.bookID)
        store.record(.downloading(progress), for: book.bookID)

        let refresh = Task { await store.refresh([book], using: storage) }
        for await _ in storage.readingBegan { break }
        store.record(.downloaded, for: book.bookID)
        store.endDownload(of: book.bookID)
        storage.letReadingFinish()
        await refresh.value

        XCTAssertEqual(store.state(of: book.bookID), .downloaded)
    }

    /// Ending a download that never began changes nothing: it cannot cancel
    /// out a later download's beginning.
    func testEndingADownloadThatNeverBeganChangesNothing() async {
        let storage = FakeBookCloudStorage(location: .cloud(.iCloudDrive))
        let book = Self.package()
        let progress = BookDownloadProgress(completedFiles: 0, totalFiles: 1, completedBytes: 0, totalBytes: 9)
        let store = BookCloudStates()

        store.endDownload(of: book.bookID)
        store.beginDownload(of: book.bookID)
        store.record(.downloading(progress), for: book.bookID)
        await store.refresh([book], using: storage)

        XCTAssertEqual(store.state(of: book.bookID), .downloading(progress))
    }

    /// A refresh of a library that is not in a cloud location records the
    /// location and no state, and forgets the states recorded before.
    func testRefreshOfALocalLibraryRecordsNoState() async {
        let storage = FakeBookCloudStorage(location: .local)
        let book = Self.package()
        let store = BookCloudStates()
        store.setLibraryLocation(.cloud(.dropbox))
        store.record(.inCloud, for: book.bookID)

        await store.refresh([book], using: storage)

        XCTAssertEqual(store.libraryLocation, .local)
        XCTAssertEqual(store.states, [:])
    }

    // MARK: - The Local Placeholders

    /// The local item provider calls every folder local and reports a file's
    /// size; a folder is local too.
    func testLocalItemProviderReportsLocalFilesWithTheirSizes() throws {
        let folder = try makeSandboxDirectory("CloudContract")
        let file = folder.appendingPathComponent("chapter.txt")
        try Data("twelve bytes".utf8).write(to: file)
        let provider = LocalItemStatusProvider()

        XCTAssertEqual(provider.location(of: folder), .local)
        XCTAssertEqual(provider.status(of: file), .local(byteCount: 12))
        XCTAssertEqual(provider.status(of: folder).state, .local)
    }

    /// The local item provider reports a path with nothing at it as missing.
    func testLocalItemProviderReportsNothingAtAPathAsMissing() throws {
        let folder = try makeSandboxDirectory("CloudContract")

        XCTAssertEqual(LocalItemStatusProvider().status(of: folder.appendingPathComponent("absent.txt")), .missing)
    }

    /// The local item provider's download and removal change nothing: a
    /// local file has no copy in the cloud, so its content always stays.
    func testLocalItemProviderNeverDownloadsOrRemovesAnything() throws {
        let folder = try makeSandboxDirectory("CloudContract")
        let file = folder.appendingPathComponent("chapter.txt")
        try Data("still here".utf8).write(to: file)
        let provider = LocalItemStatusProvider()

        try provider.requestDownload(of: file)
        try provider.removeLocalCopy(of: file)

        XCTAssertEqual(try Data(contentsOf: file), Data("still here".utf8))
        XCTAssertEqual(provider.status(of: file), .local(byteCount: 10))
    }

    /// The local book storage calls every library and book local, finishes
    /// every download at once without progress, and removes nothing.
    func testLocalBookStorageTreatsEveryBookAsLocal() async throws {
        let storage = LocalBookStorage()
        let book = Self.package()

        XCTAssertEqual(storage.libraryLocation(), .local)
        XCTAssertEqual(storage.state(of: book), .local)
        var steps: [BookDownloadProgress] = []
        for try await step in storage.download(book) {
            steps.append(step)
        }
        XCTAssertEqual(steps, [])
        XCTAssertNoThrow(try storage.removeDownload(of: book))
    }

    // MARK: - Dataless Files

    /// The calling thread's policy for reading dataless files.
    private func materializationPolicy() -> Int32 {
        getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
    }

    /// Inside `withoutDownloading` the thread leaves dataless files in the
    /// cloud; afterwards its earlier policy is back.
    func testWithoutDownloadingTurnsMaterializationOffAndRestoresThePolicy() {
        let before = materializationPolicy()
        XCTAssertGreaterThanOrEqual(before, 0, "the thread's policy can be read")

        let inside = DatalessFiles.withoutDownloading { materializationPolicy() }

        XCTAssertEqual(inside, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        XCTAssertEqual(materializationPolicy(), before)
    }

    /// The earlier policy is back even when the body throws, and the body's
    /// own error arrives.
    func testWithoutDownloadingRestoresThePolicyWhenItsBodyThrows() {
        let before = materializationPolicy()

        XCTAssertThrowsError(try DatalessFiles.withoutDownloading { throw POSIXError(.EIO) }) { error in
            XCTAssertEqual(error as? POSIXError, POSIXError(.EIO))
        }
        XCTAssertEqual(materializationPolicy(), before)
    }

    /// A nested call puts back the outer call's policy, and the outer call
    /// the thread's own.
    func testNestedCallsEachRestoreTheirOwnPreviousPolicy() {
        let before = materializationPolicy()

        let (inner, afterInner) = DatalessFiles.withoutDownloading { () -> (Int32, Int32) in
            let inner = DatalessFiles.withoutDownloading { materializationPolicy() }
            return (inner, materializationPolicy())
        }

        XCTAssertEqual(inner, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        XCTAssertEqual(afterInner, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        XCTAssertEqual(materializationPolicy(), before)
    }

    /// A policy the thread chose for itself comes back too, not only the
    /// default.
    func testWithoutDownloadingRestoresAPolicyTheThreadChose() {
        let original = materializationPolicy()
        defer {
            _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, original)
        }
        XCTAssertEqual(
            setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_ON),
            0
        )

        DatalessFiles.withoutDownloading {}

        XCTAssertEqual(materializationPolicy(), IOPOL_MATERIALIZE_DATALESS_FILES_ON)
    }

    /// An ordinary file, a folder, and a path with nothing at it are not
    /// dataless.
    func testOrdinaryItemsAreNotDataless() throws {
        let folder = try makeSandboxDirectory("CloudContract")
        let file = folder.appendingPathComponent("chapter.txt")
        try Data("here".utf8).write(to: file)

        XCTAssertFalse(DatalessFiles.isDataless(file))
        XCTAssertFalse(DatalessFiles.isDataless(folder))
        XCTAssertFalse(DatalessFiles.isDataless(folder.appendingPathComponent("absent.txt")))
    }

    /// A POSIX `EDEADLK`, however it is made, is the refusal.
    func testAPOSIXDeadlockIsADownloadRefusal() {
        XCTAssertTrue(DatalessFiles.isDownloadRefusal(POSIXError(.EDEADLK)))
        XCTAssertTrue(DatalessFiles.isDownloadRefusal(NSError(domain: NSPOSIXErrorDomain, code: Int(EDEADLK))))
    }

    /// A Cocoa error that wraps the refusal, directly or through another
    /// error, is the refusal.
    func testACocoaErrorWrappingADeadlockIsADownloadRefusal() {
        let deadlock = NSError(domain: NSPOSIXErrorDomain, code: Int(EDEADLK))
        let wrapped = CocoaError(.fileReadUnknown, userInfo: [NSUnderlyingErrorKey: deadlock])
        let wrappedTwice = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.fileReadUnknown.rawValue,
            userInfo: [NSUnderlyingErrorKey: wrapped]
        )

        XCTAssertTrue(DatalessFiles.isDownloadRefusal(wrapped))
        XCTAssertTrue(DatalessFiles.isDownloadRefusal(wrappedTwice))
    }

    /// Other errors are not the refusal: another POSIX error, a Cocoa error
    /// wrapping one, a Cocoa error with nothing beneath it, and `EDEADLK`'s
    /// number in another domain.
    func testOtherErrorsAreNotDownloadRefusals() {
        let missing = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))

        XCTAssertFalse(DatalessFiles.isDownloadRefusal(POSIXError(.ENOENT)))
        XCTAssertFalse(DatalessFiles.isDownloadRefusal(CocoaError(.fileReadNoSuchFile, userInfo: [NSUnderlyingErrorKey: missing])))
        XCTAssertFalse(DatalessFiles.isDownloadRefusal(CocoaError(.fileReadUnknown)))
        XCTAssertFalse(DatalessFiles.isDownloadRefusal(NSError(domain: NSCocoaErrorDomain, code: Int(EDEADLK))))
    }

    // MARK: - This Mac's Folders

    /// This Mac's own folders are in the sandbox's Library under hosted
    /// tests, as they are in the user's Library in the app.
    func testThisMacsFoldersAreInTheSandboxsLibrary() {
        let library = HostedTestSandbox.home.appendingPathComponent("Library", isDirectory: true)
        let root = library.appendingPathComponent("Application Support/com.textmouth.TextMouth", isDirectory: true)

        XCTAssertEqual(MachineLocalPaths.root, root)
        XCTAssertEqual(MachineLocalPaths.logs, library.appendingPathComponent("Logs/TextMouth", isDirectory: true))
        XCTAssertEqual(MachineLocalPaths.workingCopies, root.appendingPathComponent("Working Copies", isDirectory: true))
        XCTAssertEqual(
            MachineLocalPaths.archiveExtraction,
            root.appendingPathComponent("Archive Extraction", isDirectory: true)
        )
        XCTAssertEqual(MachineLocalPaths.importStaging, root.appendingPathComponent("Import Staging", isDirectory: true))
        let caches = library.appendingPathComponent("Caches/com.textmouth.TextMouth", isDirectory: true)
        XCTAssertEqual(MachineLocalPaths.caches, caches)
        XCTAssertEqual(MachineLocalPaths.readingTextCache, caches.appendingPathComponent("Reading Text", isDirectory: true))
    }

    // MARK: - The Test Doubles

    /// A scripted download reports its steps, then succeeds and makes the
    /// book downloaded.
    func testAScriptedDownloadPlaysItsStepsAndSucceeds() async throws {
        let storage = FakeBookCloudStorage()
        let book = Self.package()
        let half = BookDownloadProgress(completedFiles: 1, totalFiles: 2, completedBytes: 0, totalBytes: 0)
        storage.setState(.inCloud, of: book.bookID)
        storage.scriptDownload(of: book.bookID, steps: [half])

        var steps: [BookDownloadProgress] = []
        for try await step in storage.download(book) {
            steps.append(step)
        }

        XCTAssertEqual(steps, [half])
        XCTAssertEqual(storage.state(of: book), .downloaded)
        XCTAssertEqual(storage.downloadsStarted, [book.bookID])
    }

    /// A held download can be finished as soon as it is seen started, with
    /// every step already delivered, and ends as the test says.
    func testAHeldDownloadCanBeFinishedAsSoonAsItIsSeenStarted() async {
        let storage = FakeBookCloudStorage()
        let book = Self.package()
        let half = BookDownloadProgress(completedFiles: 1, totalFiles: 2, completedBytes: 0, totalBytes: 0)
        storage.scriptDownload(of: book.bookID, steps: [half], holdsOpen: true)

        let download = storage.download(book)
        XCTAssertEqual(storage.downloadsStarted, [book.bookID])
        storage.finishHeldDownload(of: book.bookID, failingWith: .offline)

        var steps: [BookDownloadProgress] = []
        do {
            for try await step in download {
                steps.append(step)
            }
            XCTFail("the held download ends with the failure the test gave")
        } catch {
            XCTAssertEqual(error as? BookCloudError, .offline)
        }
        XCTAssertEqual(steps, [half])
    }

    /// Cancelling the task that iterates a held download is recorded.
    func testCancellingAHeldDownloadIsRecorded() async {
        let storage = FakeBookCloudStorage()
        let book = Self.package()
        storage.scriptDownload(of: book.bookID, steps: [], holdsOpen: true)
        let download = storage.download(book)

        let iterating = Task {
            for try await _ in download {}
        }
        iterating.cancel()
        _ = try? await iterating.value

        XCTAssertEqual(storage.downloadsCancelled, [book.bookID])
    }

    // MARK: - Helpers

    /// A package for a book that is never read: the fakes and placeholders
    /// look only at its ID.
    private static func package() -> BookPackage {
        BookPackage(
            bookID: UUID(),
            url: URL(fileURLWithPath: "/nowhere/Book.tmb", isDirectory: true),
            isPackage: true,
            isAudio: false
        )
    }
}

// MARK: - A Storage That Holds Its Readings

/// Book storage in iCloud Drive whose every reading of a book's state waits
/// until the test lets it finish, so a test can act while a refresh reads.
private final class GatedBookStorage: BookCloudStorage, @unchecked Sendable {
    /// The state every book reads as.
    private let reportedState: BookCloudState
    /// Yields once each time a reading begins.
    let readingBegan: AsyncStream<Void>
    /// Feeds `readingBegan`.
    private let readingBeganContinuation: AsyncStream<Void>.Continuation
    /// Holds each reading until `letReadingFinish()`.
    private let gate = DispatchSemaphore(value: 0)

    /// Storage whose books all read as `state`, once the test lets them.
    init(reporting state: BookCloudState) {
        reportedState = state
        (readingBegan, readingBeganContinuation) = AsyncStream<Void>.makeStream()
    }

    /// Lets one waiting reading finish.
    func letReadingFinish() {
        gate.signal()
    }

    /// Always iCloud Drive.
    func libraryLocation() -> StorageLocation {
        .cloud(.iCloudDrive)
    }

    /// Says a reading began, then waits for the test before reporting.
    func state(of package: BookPackage) -> BookCloudState {
        readingBeganContinuation.yield()
        gate.wait()
        return reportedState
    }

    /// Never used: finishes at once.
    func download(_ package: BookPackage) -> AsyncThrowingStream<BookDownloadProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    /// Never used: removes nothing.
    func removeDownload(of package: BookPackage) throws {}
}
