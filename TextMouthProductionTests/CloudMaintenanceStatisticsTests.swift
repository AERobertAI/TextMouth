import XCTest
@testable import TextMouth

/// The statistics pass in a cloud library (FR02): a book whose source, text
/// cache, record, or audio tracks are in the cloud is left as it is and
/// counted in the pass's one `MAINTENANCE_SKIPPED_IN_CLOUD` line, a read
/// refused for a dataless file writes nothing, and nothing read from a file
/// that went to the cloud meanwhile is committed.
final class CloudMaintenanceStatisticsTests: CloudMaintenanceTestCase {

    /// The pass analyzes a book on this Mac and leaves one whose source is
    /// dataless: nothing of the latter is read or written, and the skip line
    /// counts it.
    @MainActor
    func testPassLeavesADatalessBookAndAnalyzesTheRest() async throws {
        let local = try makePackagedBook(title: "Local")
        let inCloud = try makePackagedBook(title: "In Cloud")
        cloud.markDataless(inCloud.bookFileURL)
        let skipLinesBefore = logLineCount(skipLine(.statistics, count: 1))
        let model = makeModel(with: [local, inCloud])

        await runStatisticsPass(of: model)

        XCTAssertNotNil(model.bookByID(local.id)?.totalWordCount)
        XCTAssertEqual(model.bookByID(inCloud.id), inCloud)
        XCTAssertNil(contents(of: MarkdownCacheService.cacheURL(for: inCloud)))
        XCTAssertNil(contents(of: TextMouthPaths.bookInfoPath(in: inCloud.tmbDirectory)))
        XCTAssertEqual(logLineCount(skipLine(.statistics, count: 1)), skipLinesBefore + 1)
    }

    /// An audiobook kept as a folder of tracks, one of them dataless, is
    /// left as it is: analyzing it would read every track.
    @MainActor
    func testPassLeavesAnAudiobookWithADatalessTrack() async throws {
        let packageName = "Tracks-\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: folderPath, tmbName: packageName)
        let tracks = package.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: tracks, withIntermediateDirectories: true)
        for name in ["01.mp3", "02.mp3"] {
            try Data("not really audio".utf8).write(to: tracks.appendingPathComponent(name))
        }
        let book = Book(
            title: "Tracks",
            format: .audio,
            filePath: tracks.path,
            md5Hash: UUID().uuidString,
            folderPath: folderPath,
            tmbDirectoryName: packageName
        )
        cloud.markDataless(tracks.appendingPathComponent("02.mp3"))
        let skipLinesBefore = logLineCount(skipLine(.statistics, count: 1))
        let model = makeModel(with: [book])

        await runStatisticsPass(of: model)

        XCTAssertEqual(model.bookByID(book.id), book)
        XCTAssertNil(contents(of: TextMouthPaths.bookInfoPath(in: package)))
        XCTAssertEqual(logLineCount(skipLine(.statistics, count: 1)), skipLinesBefore + 1)
    }

    /// A read of the source refused during the pass writes nothing: the
    /// record keeps its bytes, the row stays as it was, and the book is
    /// counted.
    @MainActor
    func testRefusedReadDuringThePassWritesNoRecord() async throws {
        var row = try commitCache(of: makePackagedBook())
        row.totalWordCount = nil
        let recordURL = TextMouthPaths.bookInfoPath(in: row.tmbDirectory)
        let recordBefore = contents(of: recordURL)
        cloud.refuseReads(of: row.bookFileURL)
        let skipLinesBefore = logLineCount(skipLine(.statistics, count: 1))
        let model = makeModel(with: [row])

        await runStatisticsPass(of: model)

        XCTAssertEqual(contents(of: recordURL), recordBefore, "the record was written")
        XCTAssertEqual(model.bookByID(row.id), row)
        XCTAssertEqual(logLineCount(skipLine(.statistics, count: 1)), skipLinesBefore + 1)
    }

    /// A file that goes to the cloud while the book is read keeps what was
    /// read from being committed: here the record goes while the text cache
    /// is written, so no record is written and the row stays as it was.
    @MainActor
    func testFileThatGoesToTheCloudMeanwhileKeepsTheAnalysisUncommitted() async throws {
        let book = try makePackagedBook()
        let recordURL = TextMouthPaths.bookInfoPath(in: book.tmbDirectory)
        let cloud = self.cloud
        MarkdownCacheService.extractionObserver = { generating in
            if generating.id == book.id {
                cloud.markDataless(recordURL)
            }
        }
        defer { MarkdownCacheService.extractionObserver = nil }
        let model = makeModel(with: [book])

        await runStatisticsPass(of: model)

        XCTAssertNil(contents(of: recordURL), "the analysis was committed")
        XCTAssertEqual(model.bookByID(book.id), book)
    }

    // MARK: - Fixtures

    /// Runs the statistics pass of `model` with this test's cloud, to its
    /// end.
    @MainActor
    private func runStatisticsPass(of model: LibraryViewModel) async {
        let finished = expectation(description: "The statistics pass finished")
        model.calculateMissingBookStats(access: cloud.access) { finished.fulfill() }
        await fulfillment(of: [finished], timeout: 10)
    }
}
