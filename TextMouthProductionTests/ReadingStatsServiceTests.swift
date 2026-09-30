import XCTest
@testable import TextMouth

/// Listening statistics are read from and written to one file. Each test
/// drives its own services over a disposable statistics file under the
/// isolated test data root, so neither the shared service nor another test's
/// numbers are touched. Set-up and tear-down hold only plain values; each
/// test makes its services on the main actor.
final class ReadingStatsServiceTests: XCTestCase {
    /// Directory holding this test's statistics file, removed afterwards.
    private var directory: URL!
    /// The statistics file this test's services read and write.
    private var fileURL: URL!
    /// Local noon on an ordinary summer day (15 July 2026), far from
    /// midnight and from any daylight-saving change, so a session starting
    /// here stays on one day. Whole-second times keep every sum exact.
    private var noon: Date!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = TextMouthPaths.root.appendingPathComponent(
            "ReadingStatsServiceTests-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("reading_stats.json")
        noon = try XCTUnwrap(Calendar.current.date(
            bySettingHour: 12, minute: 0, second: 0,
            of: Date(timeIntervalSince1970: 1_784_116_800) // 2026-07-15 12:00 UTC
        ))
    }

    override func tearDownWithError() throws {
        // Queued writes target the directory; let them land before removing it.
        ReadingStatsService.waitForQueuedSaves()
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    // MARK: - Statistics file

    /// A service given its own file saves there, and a new service over the
    /// same file starts with what was saved, as the next launch does.
    @MainActor
    func testServiceSavesToItsOwnFileAndTheNextLaunchLoadsIt() {
        let service = makeService()
        let book = UUID()
        service.startSession(bookID: book, at: noon)
        service.endSession(at: noon + 90)

        let relaunched = relaunchedService()
        XCTAssertEqual(relaunched.stats.totalListeningSeconds, 90)
        XCTAssertEqual(relaunched.stats.bookListeningSeconds, [book.uuidString: 90])
        XCTAssertFalse(relaunched.hasActiveSession)
    }

    /// The app's service follows the data directory in use, which the user
    /// can move, instead of a file fixed when the service was created.
    @MainActor
    func testSharedServiceFollowsTheDataDirectory() {
        XCTAssertEqual(ReadingStatsService.shared.fileURL, TextMouthPaths.readingStatsFile)
    }

    // MARK: - Helpers

    /// A service over this test's file. Its timer stops when the test ends.
    @MainActor
    private func makeService() -> ReadingStatsService {
        let service = ReadingStatsService(fileURL: fileURL)
        addTeardownBlock { @MainActor in service.shutdown() }
        return service
    }

    /// What the next launch would find: waits for every queued write, then
    /// loads the file into a fresh service, as startup does.
    @MainActor
    private func relaunchedService() -> ReadingStatsService {
        ReadingStatsService.waitForQueuedSaves()
        return makeService()
    }
}
