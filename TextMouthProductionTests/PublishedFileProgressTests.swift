import XCTest
@testable import TextMouth

/// The app's listener for the progress the system publishes for a file
/// (FR02, `PublishedFileProgress`), heard through progress this process
/// publishes itself, as a sync service publishes its downloads, so no cloud
/// drive is needed. The system hands each publication to its listeners on
/// the main thread a moment later, so each test waits, up to a limit, for
/// what it expects to hear.
final class PublishedFileProgressTests: XCTestCase {

    /// A listener hears the fraction already done when progress is
    /// published for its file, then each later one, through to the whole.
    func testAListenerHearsEachFractionPublishedForItsFile() async throws {
        let file = try makeFile("Harbor Charts.m4b")
        let heard = HeardFractions()
        let listening = PublishedFileProgress.listen(to: file) { heard.append($0) }
        defer { listening.stop() }

        let download = Self.publish(.downloading, of: file, totalUnitCount: 4)
        defer { download.unpublish() }
        try await waitFor("the publication") { heard.all.contains(0) }
        download.completedUnitCount = 1
        try await waitFor("a quarter") { heard.all.last == 0.25 }
        download.completedUnitCount = 4
        try await waitFor("the whole") { heard.all.last == 1 }

        XCTAssertEqual(heard.changes, [0, 0.25, 1])
    }

    /// A listener hears only its own file, and nothing once it stops: a
    /// listener on another file hears that file's progress, and one on the
    /// same file that goes on listening hears what the stopped one would
    /// have.
    func testAListenerHearsOnlyItsFileAndNothingOnceStopped() async throws {
        let file = try makeFile("Breakwater Survey.m4b")
        let otherFile = try makeFile("Ferry Timetable.m4b")
        let stopped = HeardFractions()
        let goingOn = HeardFractions()
        let other = HeardFractions()
        let stopping = PublishedFileProgress.listen(to: file) { stopped.append($0) }
        let listening = PublishedFileProgress.listen(to: file) { goingOn.append($0) }
        let otherListening = PublishedFileProgress.listen(to: otherFile) { other.append($0) }
        defer {
            listening.stop()
            otherListening.stop()
        }

        let otherDownload = Self.publish(.downloading, of: otherFile, totalUnitCount: 2)
        defer { otherDownload.unpublish() }
        otherDownload.completedUnitCount = 1
        let download = Self.publish(.downloading, of: file, totalUnitCount: 8)
        defer { download.unpublish() }
        download.completedUnitCount = 3
        try await waitFor("each file's fraction") {
            other.all.contains(0.5) && stopped.all.contains(0.375) && goingOn.all.contains(0.375)
        }
        stopping.stop()
        stopping.stop()
        download.completedUnitCount = 8
        try await waitFor("the whole, by the listener going on") { goingOn.all.last == 1 }

        XCTAssertFalse(stopped.all.contains(0.5), "a listener heard another file's progress: \(stopped.all)")
        XCTAssertFalse(stopped.all.contains(1), "a listener heard progress after it stopped: \(stopped.all)")
    }

    /// A listener on a folder, such as a book's package, hears the progress
    /// published for the folder itself, and none of what the system hands
    /// it for a file inside the folder, which that file's own listener hears:
    /// on Google Drive a package's listener is handed every file's progress.
    func testAListenerOnAFolderHearsOnlyTheFoldersOwnProgress() async throws {
        let folder = try makeSandboxDirectory("PublishedProgress").appendingPathComponent("Pier Ledger.tmb", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("chapter.m4b")
        try Data(count: 16).write(to: file)
        let folderHeard = HeardFractions()
        let fileHeard = HeardFractions()
        let folderListening = PublishedFileProgress.listen(to: folder) { folderHeard.append($0) }
        let fileListening = PublishedFileProgress.listen(to: file) { fileHeard.append($0) }
        defer {
            folderListening.stop()
            fileListening.stop()
        }

        // The file's progress is published first, so a folder listener that
        // followed it would hear it before the folder's own.
        let fileDownload = Self.publish(.downloading, of: file, totalUnitCount: 4, completedUnitCount: 3)
        defer { fileDownload.unpublish() }
        let folderDownload = Self.publish(.downloading, of: folder, totalUnitCount: 10, completedUnitCount: 1)
        defer { folderDownload.unpublish() }
        try await waitFor("the file's progress, by its own listener") { fileHeard.all.contains(0.75) }
        try await waitFor("the folder's progress") { folderHeard.all.contains(0.1) }
        folderDownload.completedUnitCount = 7
        try await waitFor("the folder's later fraction") { folderHeard.all.last == 0.7 }

        XCTAssertEqual(folderHeard.changes, [0.1, 0.7], "the folder's listener heard the file's progress")
    }

    /// A listener hears only downloads of its item, never an upload: iCloud
    /// Drive publishes a package's uploads for the package as well.
    func testAListenerHearsNoUpload() async throws {
        let file = try makeFile("Tide Tables.m4b")
        let heard = HeardFractions()
        let listening = PublishedFileProgress.listen(to: file) { heard.append($0) }
        defer { listening.stop() }

        // The upload is published first, and moves before the download does,
        // so a listener that followed it would hear it first.
        let upload = Self.publish(.uploading, of: file, totalUnitCount: 2, completedUnitCount: 1)
        defer { upload.unpublish() }
        let download = Self.publish(.downloading, of: file, totalUnitCount: 4, completedUnitCount: 1)
        defer { download.unpublish() }
        try await waitFor("the download") { heard.all.contains(0.25) }
        upload.completedUnitCount = 2
        download.completedUnitCount = 3
        try await waitFor("the download's later fraction") { heard.all.last == 0.75 }

        XCTAssertEqual(heard.changes, [0.25, 0.75], "the listener heard an upload")
    }

    /// Progress that names its item is a download of the listened item only
    /// when it bears that item's name, letter case aside; progress that
    /// names no item is taken as the item's, and an upload never counts.
    func testADownloadOfTheItemItselfIsRecognizedByItsName() {
        let package = URL(fileURLWithPath: "/Users/reader/Library/Mobile Documents/com~apple~CloudDocs/Ferry Log.tmb", isDirectory: true)
        /// Progress of `operation` published for `item`, or naming no item.
        func progress(_ operation: Progress.FileOperationKind, of item: URL?) -> Progress {
            let progress = Progress(totalUnitCount: 1)
            progress.kind = .file
            progress.fileOperationKind = operation
            progress.fileURL = item
            return progress
        }

        XCTAssertTrue(PublishedFileProgress.isDownload(progress(.downloading, of: package), of: package))
        XCTAssertTrue(PublishedFileProgress.isDownload(
            progress(.downloading, of: URL(fileURLWithPath: "/Volumes/Elsewhere/ferry log.tmb", isDirectory: true)),
            of: package
        ))
        XCTAssertTrue(PublishedFileProgress.isDownload(progress(.downloading, of: nil), of: package))
        XCTAssertFalse(PublishedFileProgress.isDownload(
            progress(.downloading, of: package.appendingPathComponent("content.md")),
            of: package
        ))
        XCTAssertFalse(PublishedFileProgress.isDownload(progress(.uploading, of: package), of: package))
    }

    // MARK: - Helpers

    /// A small file named `name` in a scratch folder of the test's own.
    private func makeFile(_ name: String) throws -> URL {
        let file = try makeSandboxDirectory("PublishedProgress").appendingPathComponent(name)
        try Data(count: 16).write(to: file)
        return file
    }

    /// The progress of `operation`, a download or an upload, of `item` in
    /// `totalUnitCount` units, `completedUnitCount` of them done, published
    /// as a sync service publishes its transfers. The caller unpublishes it.
    private static func publish(
        _ operation: Progress.FileOperationKind,
        of item: URL,
        totalUnitCount: Int64,
        completedUnitCount: Int64 = 0
    ) -> Progress {
        let progress = Progress(totalUnitCount: totalUnitCount)
        progress.kind = .file
        progress.fileOperationKind = operation
        progress.fileURL = item
        progress.completedUnitCount = completedUnitCount
        progress.publish()
        return progress
    }

    /// Waits until `condition` holds, checking every 20 milliseconds, and
    /// fails the test, naming `what` it waited to hear, after 10 seconds.
    private func waitFor(
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        until condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while !condition() {
            guard clock.now < deadline else {
                return XCTFail("Never heard \(what)", file: file, line: line)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// The fractions a listener heard, in order, from whichever thread it heard
/// them on.
private final class HeardFractions: @unchecked Sendable {
    /// Guards `fractions`.
    private let lock = NSLock()
    /// Every fraction heard, in order.
    private var fractions: [Double] = []

    /// Notes that `fraction` was heard.
    func append(_ fraction: Double) {
        lock.withLock { fractions.append(fraction) }
    }

    /// Every fraction heard so far, in order.
    var all: [Double] {
        lock.withLock { fractions }
    }

    /// Every fraction heard so far, a fraction heard again at once counted
    /// once: the system may report one fraction twice.
    var changes: [Double] {
        all.reduce(into: []) { changes, fraction in
            if changes.last != fraction { changes.append(fraction) }
        }
    }
}
