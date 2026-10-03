import Darwin
import XCTest
@testable import TextMouth

/// The pieces of the opt-in real-drive tests that need no cloud drive
/// (FR02), checked in every ordinary run: above all, that those tests skip
/// unless asked and use only folders named “TextMouth Cloud Tests” in a
/// cloud drive's folder; then their run folders, waits, synthetic books,
/// file snapshots, download following, progress listening, and summary.
final class CloudDriveTestSupportTests: XCTestCase {

    /// The variable listing the folders, for brevity.
    private let variable = CloudDriveTestRoots.variableName

    /// The folder name the tests require, for brevity.
    private let folderName = CloudDriveTestRoots.folderName

    /// Places every folder in Dropbox, as a drive's own folder would be.
    private static func inDropbox(_ folder: URL) -> StorageLocation {
        .cloud(.dropbox)
    }

    /// Places every folder on this Mac's startup disk.
    private static func onThisMac(_ folder: URL) -> StorageLocation {
        .local
    }

    /// This test's scratch folder, made on first use and removed at the end.
    private var scratch: URL?

    // MARK: - Which Folders

    /// Unset, empty, or listing only colons, the variable asks for nothing.
    func testNothingIsRequestedWithoutAFolderListed() {
        let environments: [[String: String]] = [[:], [variable: ""], [variable: "::"]]
        for environment in environments {
            XCTAssertEqual(
                CloudDriveTestRoots.selection(in: environment, locate: Self.inDropbox),
                .notRequested,
                "\(environment)"
            )
        }
    }

    /// Asked for nothing, the opt-in tests skip rather than fail.
    func testRequiringFoldersSkipsWhenNoneIsListed() {
        XCTAssertThrowsError(try CloudDriveTestRoots.requireRoots(in: [:])) { error in
            XCTAssertTrue(error is XCTSkip, "\(error)")
        }
    }

    /// A folder named exactly “TextMouth Cloud Tests” in a cloud drive's
    /// folder is used, under the drive's name.
    func testAFolderWithTheNameInACloudDriveIsUsed() throws {
        let folder = try makeFolder(folderName)

        let selection = CloudDriveTestRoots.selection(in: [variable: folder.path], locate: Self.inDropbox)

        guard case .roots(let roots) = selection else { return XCTFail("\(selection)") }
        XCTAssertEqual(roots.map { Self.path($0.folder) }, [Self.path(folder)])
        XCTAssertEqual(roots.map(\.driveName), ["Dropbox"])
    }

    /// Several folders, separated by colons, are all used in the order
    /// listed, each under its own drive's name; a trailing colon lists
    /// nothing more.
    func testSeveralFoldersAreUsedInTheOrderListed() throws {
        let first = try makeFolder("Google/\(folderName)")
        let second = try makeFolder("Dropbox/\(folderName)")
        let byPath: (URL) -> StorageLocation = { folder in
            folder.path.contains("/Google/") ? .cloud(.googleDrive) : .cloud(.dropbox)
        }

        let selection = CloudDriveTestRoots.selection(in: [variable: "\(first.path):\(second.path):"], locate: byPath)

        guard case .roots(let roots) = selection else { return XCTFail("\(selection)") }
        XCTAssertEqual(roots.map { Self.path($0.folder) }, [Self.path(first), Self.path(second)])
        XCTAssertEqual(roots.map(\.driveName), ["Google Drive", "Dropbox"])
    }

    /// Any other name is refused: another name, the right one in other
    /// letter case, or with a space after it. Then no folder is used at all,
    /// not even a good one listed beside them.
    func testEveryOtherNameIsRefusedAndThenNoFolderIsUsed() throws {
        let good = try makeFolder("Good/\(folderName)")
        let others = try ["Dropbox", "textmouth cloud tests", "\(folderName) "].map { try makeFolder("Others/\($0)") }
        let listed = ([good] + others).map(\.path).joined(separator: ":")

        let selection = CloudDriveTestRoots.selection(in: [variable: listed], locate: Self.inDropbox)

        XCTAssertEqual(selection, .refused(others.map { "“\($0.path)” is not named “\(folderName)”." }))
    }

    /// A relative path, a missing folder, a file with the right name, a
    /// folder listed twice, and a folder outside every cloud drive are each
    /// refused with their reason.
    func testOtherProblemsAreRefusedEachWithItsReason() throws {
        let good = try makeFolder("Good/\(folderName)")
        let missing = try makeFolder("Missing").appendingPathComponent(folderName).path
        let file = try makeFolder("File").appendingPathComponent(folderName)
        try Data("not a folder".utf8).write(to: file)
        /// What listing `entries` selects, every folder placed in Dropbox,
        /// or on this Mac's startup disk when `inCloud` is false.
        func selection(_ entries: String, inCloud: Bool = true) -> CloudDriveTestRoots.Selection {
            CloudDriveTestRoots.selection(in: [variable: entries], locate: inCloud ? Self.inDropbox : Self.onThisMac)
        }

        XCTAssertEqual(selection("Dropbox/\(folderName)"), .refused(["“Dropbox/\(folderName)” is not an absolute path."]))
        XCTAssertEqual(selection(missing), .refused(["“\(missing)” is not an existing folder."]))
        XCTAssertEqual(selection(file.path), .refused(["“\(file.path)” is not an existing folder."]))
        XCTAssertEqual(
            selection("\(good.path):\(good.path)/"),
            .refused(["“\(good.path)/” names a folder listed already."])
        )
        XCTAssertEqual(
            selection(good.path, inCloud: false),
            .refused(["“\(good.path)” is not in a cloud drive's folder."])
        )
    }

    /// A link named “TextMouth Cloud Tests” is judged by the folder it leads
    /// to: refused when that folder has another name, and used, as that
    /// folder, when it has the name.
    func testALinkIsJudgedByTheFolderItLeadsTo() throws {
        let elsewhere = try makeFolder("Elsewhere/Documents")
        let badLink = try makeFolder("BadLink").appendingPathComponent(folderName)
        try FileManager.default.createSymbolicLink(at: badLink, withDestinationURL: elsewhere)
        let target = try makeFolder("Target/\(folderName)")
        let goodLink = try makeFolder("GoodLink").appendingPathComponent(folderName)
        try FileManager.default.createSymbolicLink(at: goodLink, withDestinationURL: target)

        let refused = CloudDriveTestRoots.selection(in: [variable: badLink.path], locate: Self.inDropbox)
        let used = CloudDriveTestRoots.selection(in: [variable: goodLink.path], locate: Self.inDropbox)

        guard case .refused(let reasons) = refused else { return XCTFail("\(refused)") }
        XCTAssertEqual(reasons.count, 1)
        XCTAssertTrue(reasons.first?.hasPrefix("“\(badLink.path)” leads to ") == true, "\(reasons)")
        guard case .roots(let roots) = used else { return XCTFail("\(used)") }
        XCTAssertEqual(roots.map { Self.path($0.folder) }, [Self.path(target)])
    }

    /// A refusal fails the opt-in tests rather than skipping them, and names
    /// every refused entry.
    func testRequiringRefusedFoldersThrowsTheRefusal() throws {
        let other = try makeFolder("Dropbox")

        XCTAssertThrowsError(try CloudDriveTestRoots.requireRoots(in: [variable: other.path])) { error in
            XCTAssertFalse(error is XCTSkip, "A refusal must fail the tests, not skip them")
            XCTAssertEqual(
                error as? CloudDriveTestRoots.Refusal,
                CloudDriveTestRoots.Refusal(reasons: ["“\(other.path)” is not named “\(folderName)”."])
            )
            XCTAssertTrue(error.localizedDescription.contains("no folder was used"), error.localizedDescription)
        }
    }

    // MARK: - Run Folders

    /// A run folder is named for its date and time, the process, and the
    /// test.
    func testRunFolderNamesGiveTheDateTheProcessAndTheTest() throws {
        let date = Date(timeIntervalSince1970: 1_759_470_312)
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))

        let runName = CloudDriveRunFolder.name(label: "round-trip", date: date, processIdentifier: 4242, timeZone: utc)

        XCTAssertEqual(runName, "run-20251003-054512-4242-round-trip")
    }

    /// A run folder is made new inside its test root, and its removal
    /// deletes everything in it while the test root stays.
    func testRunFoldersAreMadeInTheRootAndRemovedWhole() throws {
        let root = CloudDriveTestRoot(folder: try makeFolder(folderName), provider: .dropbox)

        let run = try CloudDriveRunFolder.make(in: root, label: "unit")
        _ = try SyntheticPackage.write(named: "Book.tmb", in: run, files: [.init(name: "a.bin", byteCount: 10)])
        try CloudDriveRunFolder.remove(run)

        XCTAssertEqual(Self.path(run.deletingLastPathComponent()), Self.path(root.folder))
        XCTAssertTrue(run.lastPathComponent.hasPrefix("run-"), run.lastPathComponent)
        XCTAssertTrue(
            run.lastPathComponent.hasSuffix("-\(ProcessInfo.processInfo.processIdentifier)-unit"),
            run.lastPathComponent
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.path), "The run folder is still there")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.folder.path), "The test root itself must stay")
    }

    // MARK: - Waiting

    /// A wait whose condition holds at once ends at once.
    func testAWaitEndsAtOnceWhenItsConditionHolds() async throws {
        let elapsed = try await CloudDriveWait.until(limit: CloudDriveWait.upload) { true }

        XCTAssertLessThan(try XCTUnwrap(elapsed), CloudDriveWait.interval)
    }

    /// A wait checks again a second later, and ends at the first check that
    /// finds its condition holding.
    func testAWaitChecksOnceASecond() async throws {
        var checks = 0

        let elapsed = try await CloudDriveWait.until(limit: .seconds(10)) {
            checks += 1
            return checks == 2
        }

        XCTAssertEqual(checks, 2)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(elapsed), CloudDriveWait.interval)
    }

    /// A wait whose condition never holds gives up at its limit and reports
    /// no time.
    func testAWaitGivesUpAtItsLimit() async throws {
        var checks = 0

        let elapsed = try await CloudDriveWait.until(limit: .zero) {
            checks += 1
            return false
        }

        XCTAssertNil(elapsed)
        XCTAssertEqual(checks, 1)
    }

    // MARK: - What a Drive Reports Uploaded

    /// A file counts as uploaded by its own upload flag when it carries sync
    /// flags, as on Google Drive and Dropbox, whatever its package says; one
    /// that carries none, as inside an iCloud Drive package, counts by its
    /// package's upload flag. A flag left out never counts as uploaded, nor
    /// does a file no sync service manages.
    func testAFileCountsAsUploadedByItsOwnFlagsOrElseByItsPackages() {
        typealias Metadata = UbiquitousItemStatusProvider.Metadata
        let packageUp = Metadata(isUbiquitousItem: true, downloadingStatus: .current, isUploaded: true)
        let packageUploading = Metadata(isUbiquitousItem: true, downloadingStatus: .current, isUploaded: false)
        let packageSaysNothing = Metadata(isUbiquitousItem: true)
        let googleFileUp = Metadata(isUbiquitousItem: true, downloadingStatus: .current, isUploaded: true)
        let googleFileUploading = Metadata(isUbiquitousItem: true, downloadingStatus: .current, isUploaded: false)
        let iCloudFile = Metadata(isUbiquitousItem: true, byteCount: 1_024)
        let localFile = Metadata(byteCount: 1_024)

        XCTAssertTrue(CloudDriveUploads.isUploaded(file: googleFileUp, package: nil))
        XCTAssertTrue(CloudDriveUploads.isUploaded(file: googleFileUp, package: packageUploading))
        XCTAssertFalse(CloudDriveUploads.isUploaded(file: googleFileUploading, package: packageUp), "the file's own flag")
        XCTAssertTrue(CloudDriveUploads.isUploaded(file: iCloudFile, package: packageUp))
        XCTAssertFalse(CloudDriveUploads.isUploaded(file: iCloudFile, package: packageUploading))
        XCTAssertFalse(CloudDriveUploads.isUploaded(file: iCloudFile, package: packageSaysNothing), "no flag anywhere")
        XCTAssertFalse(CloudDriveUploads.isUploaded(file: iCloudFile, package: nil), "in no package")
        XCTAssertFalse(CloudDriveUploads.isUploaded(file: localFile, package: packageUp), "managed by no sync service")
        XCTAssertFalse(CloudDriveUploads.isUploaded(file: nil, package: packageUp), "unreadable")
    }

    /// A file's package is the nearest folder above it, inside the test
    /// folder, with the package extension, in any letter case; a file in no
    /// package has none, and nothing above the test folder is a candidate.
    func testAFilesPackageIsTheNearestPackageFolderInsideTheRoot() {
        let root = URL(fileURLWithPath: "/Users/reader/Drive/Outer.tmb/TextMouth Cloud Tests", isDirectory: true)
        /// The URL of `path` inside the root.
        func inRoot(_ path: String) -> URL {
            root.appendingPathComponent(path)
        }

        XCTAssertEqual(
            CloudDriveUploads.package(holding: inRoot("run/Book.tmb/content.md"), inside: root)?.path,
            inRoot("run/Book.tmb").path
        )
        XCTAssertEqual(
            CloudDriveUploads.package(holding: inRoot("run/Book.tmb/audio/0001.mp3"), inside: root)?.path,
            inRoot("run/Book.tmb").path
        )
        XCTAssertEqual(
            CloudDriveUploads.package(holding: inRoot("Library/Alice.TMB/bookInfo.json"), inside: root)?.path,
            inRoot("Library/Alice.TMB").path
        )
        XCTAssertNil(CloudDriveUploads.package(holding: inRoot("Small Library/library.json"), inside: root))
        XCTAssertNil(CloudDriveUploads.package(holding: inRoot("loose.txt"), inside: root), "Outer.tmb is above the root")
        XCTAssertNil(CloudDriveUploads.package(holding: URL(fileURLWithPath: "/elsewhere/Book.tmb/a.txt"), inside: root))
    }

    // MARK: - Synthetic Books

    /// A synthetic package holds files of the sizes asked for, of random
    /// bytes, notices a file that changed or went, and is never written
    /// over.
    func testSyntheticPackagesHoldRandomFilesOfTheSizesAskedFor() throws {
        let folder = try makeFolder("Packages")

        let package = try SyntheticPackage.write(named: "Book.tmb", in: folder)

        XCTAssertEqual(package.files.map(\.lastPathComponent), ["large-5MB.bin", "medium-50KB.bin", "small-1KB.bin"])
        XCTAssertEqual(package.files.map { FileSnapshot.read($0)?.byteCount }, [5_242_880, 51_200, 1_024])
        XCTAssertEqual(package.filesNotIntact(), [])
        XCTAssertNotEqual(package.contents["small-1KB.bin"], Data(count: 1_024), "The bytes must be random, not zeros")
        XCTAssertEqual(
            package.bookPackage,
            BookPackage(bookID: package.bookID, url: package.url, isPackage: true, isAudio: true)
        )

        try Data("changed".utf8).write(to: package.files[2])
        try FileManager.default.removeItem(at: package.files[1])
        XCTAssertEqual(package.filesNotIntact(), ["medium-50KB.bin", "small-1KB.bin"])
        XCTAssertThrowsError(try SyntheticPackage.write(named: "Book.tmb", in: folder), "A package was written over")
    }

    /// A copy of a package, or the package moved, is checked at its own
    /// place and keeps the book's ID.
    func testSyntheticPackagesAreCheckedWhereverTheyAre() throws {
        let folder = try makeFolder("Copies")
        let package = try SyntheticPackage.write(named: "Book.tmb", in: folder, files: [.init(name: "a.bin", byteCount: 100)])
        let copy = folder.appendingPathComponent("Copy.tmb", isDirectory: true)
        try FileManager.default.copyItem(at: package.url, to: copy)

        let moved = package.moved(to: copy)

        XCTAssertEqual(package.filesNotIntact(at: { copy.appendingPathComponent($0.lastPathComponent) }), [])
        XCTAssertEqual(moved.bookID, package.bookID)
        XCTAssertEqual(moved.files, [copy.appendingPathComponent("a.bin")])
        XCTAssertEqual(moved.filesNotIntact(), [])
    }

    // MARK: - What lstat Says

    /// A snapshot reads a file's size and its modification time to the
    /// nanosecond, and nothing where no file is.
    func testSnapshotsReadTheSizeAndTheNanoseconds() throws {
        let file = try makeFolder("Snapshots").appendingPathComponent("file.bin")
        try Data(count: 1_234).write(to: file)
        let times = [
            timespec(tv_sec: 1_700_000_000, tv_nsec: 123_456_789),
            timespec(tv_sec: 1_700_000_000, tv_nsec: 123_456_789),
        ]
        let changed = file.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return utimensat(AT_FDCWD, path, times, 0)
        }
        XCTAssertEqual(changed, 0, "The test could not set the modification time")

        let snapshot = try XCTUnwrap(FileSnapshot.read(file))

        XCTAssertEqual(snapshot.byteCount, 1_234)
        XCTAssertEqual(snapshot.modificationTime, "1700000000.123456789")
        XCTAssertNil(FileSnapshot.read(file.deletingLastPathComponent().appendingPathComponent("missing")))
    }

    // MARK: - Following a Download

    /// A followed download that finishes keeps every progress in order and
    /// counts as finished.
    func testFollowingAFinishedDownloadKeepsEveryProgress() async {
        let steps = [Self.progress(0, of: 3), Self.progress(2, of: 3), Self.progress(3, of: 3)]
        let stream = AsyncThrowingStream<BookDownloadProgress, Error> { continuation in
            steps.forEach { continuation.yield($0) }
            continuation.finish()
        }

        let record = await CloudDriveDownloadRecord.follow(stream, limit: .seconds(10))

        XCTAssertTrue(record.finished, "\(record.outcome)")
        XCTAssertEqual(record.updates, steps)
        XCTAssertTrue(record.isInOrder)
    }

    /// A followed download that fails keeps its error and the progress
    /// before it.
    func testFollowingAFailedDownloadKeepsItsError() async {
        let stream = AsyncThrowingStream<BookDownloadProgress, Error> { continuation in
            continuation.yield(Self.progress(1, of: 3))
            continuation.finish(throwing: BookCloudError.stalled(seconds: 60))
        }

        let record = await CloudDriveDownloadRecord.follow(stream, limit: .seconds(10))

        guard case .failed(let error) = record.outcome else { return XCTFail("\(record.outcome)") }
        XCTAssertEqual(error as? BookCloudError, .stalled(seconds: 60))
        XCTAssertEqual(record.updates, [Self.progress(1, of: 3)])
        XCTAssertFalse(record.finished)
    }

    /// A download that outlasts its limit is stopped there: the record says
    /// so, and the stream ends, which stops the download's checks.
    func testFollowingStopsADownloadAtItsLimit() async {
        let ended = expectation(description: "The stream ended")
        let stream = AsyncThrowingStream<BookDownloadProgress, Error> { continuation in
            continuation.yield(Self.progress(0, of: 3))
            continuation.onTermination = { _ in ended.fulfill() }
        }

        let record = await CloudDriveDownloadRecord.follow(stream, limit: .milliseconds(200))

        guard case .timedOut = record.outcome else { return XCTFail("\(record.outcome)") }
        XCTAssertEqual(record.updates, [Self.progress(0, of: 3)])
        await fulfillment(of: [ended], timeout: 5)
    }

    /// Progress that falls back, or whose count of files changes, is out of
    /// order; progress that stays or moves forward is in order, and so is a
    /// package counted as one item to come that then arrives whole with
    /// every file, as on iCloud Drive, but no other change of the count.
    func testProgressThatGoesBackIsOutOfOrder() {
        /// A finished download that reported `updates`.
        func record(_ updates: [BookDownloadProgress]) -> CloudDriveDownloadRecord {
            CloudDriveDownloadRecord(updates: updates, outcome: .finished, elapsed: .zero)
        }
        var partOfThePackage = Self.progress(0, of: 1)
        partOfThePackage.partialFiles = 0.4

        XCTAssertTrue(record([]).isInOrder)
        XCTAssertTrue(record([Self.progress(1, of: 3), Self.progress(1, of: 3), Self.progress(3, of: 3)]).isInOrder)
        XCTAssertFalse(record([Self.progress(2, of: 3), Self.progress(1, of: 3)]).isInOrder)
        XCTAssertFalse(record([Self.progress(1, of: 4), Self.progress(1, of: 3)]).isInOrder)
        XCTAssertTrue(record([Self.progress(0, of: 1), partOfThePackage, Self.progress(3, of: 3)]).isInOrder)
        XCTAssertFalse(record([Self.progress(0, of: 1), Self.progress(1, of: 3)]).isInOrder, "arrived only in part")
        XCTAssertFalse(record([Self.progress(1, of: 2), Self.progress(3, of: 3)]).isInOrder, "no package counted as one")
    }

    // MARK: - Published Progress

    /// The recorder hears progress this process publishes for a file it
    /// listens to, through to its last fraction, and says it heard nothing
    /// for a file nobody publishes about. So a "No" on a real drive means
    /// the sync service's progress never arrived, not that the recorder
    /// cannot hear.
    func testThePublishedProgressRecorderHearsPublishedProgress() async throws {
        let folder = try makeFolder("Published")
        let heard = folder.appendingPathComponent("heard.bin")
        let quiet = folder.appendingPathComponent("quiet.bin")
        try Data(count: 10).write(to: heard)
        try Data(count: 10).write(to: quiet)
        let recorder = PublishedProgressRecorder()
        recorder.subscribe(to: [heard, quiet])
        defer { recorder.stop() }
        XCTAssertEqual(recorder.summary(of: [heard]), "No: no download progress was heard for any of 1 item.")

        let progress = Progress(totalUnitCount: 4)
        progress.kind = .file
        progress.fileOperationKind = .downloading
        progress.fileURL = heard
        progress.publish()
        defer { progress.unpublish() }
        // Published progress reaches subscribers asynchronously.
        let published = try await CloudDriveWait.until(limit: .seconds(10)) {
            recorder.summary(of: [heard, quiet]).hasPrefix("Yes")
        }
        XCTAssertNotNil(published, recorder.summary(of: [heard, quiet]))
        progress.completedUnitCount = 4
        let completed = try await CloudDriveWait.until(limit: .seconds(10)) {
            recorder.summary(of: [heard, quiet]).hasSuffix("to 100 percent.")
        }

        XCTAssertNotNil(completed, recorder.summary(of: [heard, quiet]))
        let summary = recorder.summary(of: [heard, quiet])
        XCTAssertTrue(summary.hasPrefix("Yes, for 1 of 2 items: heard.bin had "), summary)
        XCTAssertTrue(summary.contains("from 0 percent"), summary)
    }

    // MARK: - Answers

    /// The questions are numbered 1 to 8, as in the task brief.
    func testTheQuestionsAreNumberedAsInTheBrief() {
        XCTAssertEqual(CloudDriveQuestion.allCases.map(\.rawValue), Array(1...8))
    }

    /// The summary table has a row per answer naming its drive, by drive and
    /// question, with pipes and line breaks kept out of its cells.
    func testTheSummaryTableNamesTheDriveOnEveryRow() {
        let findings = [
            CloudDriveFinding(drive: "Dropbox", question: .dotFolder, answer: "Yes | uploaded\nin 2 s"),
            CloudDriveFinding(drive: "Dropbox", question: .downloadAndRemovalRequests, answer: "Yes"),
            CloudDriveFinding(drive: "Google Drive", question: .evictedFileSize, answer: "0"),
        ]

        XCTAssertEqual(CloudDriveFindings.table(of: findings), """
        | Drive | Question | Answer |
        | --- | --- | --- |
        | Dropbox | 1. Do startDownloadingUbiquitousItem and evictUbiquitousItem work? | Yes |
        | Dropbox | 7. Does a dot-folder sync? | Yes \\| uploaded in 2 s |
        | Google Drive | 3. Does an evicted file report its real size, or 0? | 0 |
        """)
    }

    /// An error is described by its words, its domain, and its code.
    func testErrorsAreDescribedWithTheirDomainAndCode() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY), userInfo: [NSLocalizedDescriptionKey: "Busy"])

        XCTAssertEqual(CloudDriveFindings.describe(error), "Busy (NSPOSIXErrorDomain 16)")
    }

    // MARK: - Helpers

    /// A download's progress counted by files: `done` of `total`.
    private static func progress(_ done: Int, of total: Int) -> BookDownloadProgress {
        BookDownloadProgress(completedFiles: done, totalFiles: total, completedBytes: 0, totalBytes: 0)
    }

    /// Makes the folder at `relativePath` inside this test's scratch folder,
    /// with any folders above it.
    private func makeFolder(_ relativePath: String) throws -> URL {
        let folder = try scratchFolder().appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// This test's scratch folder in the temporary directory, made on first
    /// use and removed when the test ends.
    private func scratchFolder() throws -> URL {
        if let scratch {
            return scratch
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudDriveTestSupportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        scratch = folder
        return folder
    }

    /// `url`'s path with links followed, for comparing folders.
    private static func path(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
