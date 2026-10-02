import XCTest
@testable import TextMouth

/// A save of the listening statistics that fails is reported to the failure
/// center with the file's path and a retry, instead of only being printed,
/// and the next save that succeeds settles it (TODO S09). Each test writes
/// a file of its own in a folder it makes read-only.
@MainActor
final class DataFileFailureReportingTests: XCTestCase {
    // MARK: - Statistics

    /// A statistics save that cannot be written is reported with the file's
    /// path once the queued write has run, and the next save that succeeds
    /// settles it.
    func testAFailedStatisticsSaveIsReportedUntilASaveSucceeds() throws {
        let center = cleanSharedFailureCenter()
        let (service, giveBackPermission) = try readOnlyStatisticsService()
        defer { service.shutdown() }

        service.markBookFinished(bookID: UUID(), title: "Read Through")
        ReadingStatsService.waitForQueuedSaves()

        let failure = try XCTUnwrap(center.outstandingFailures().first)
        XCTAssertEqual(failure.subject, .statistics)
        XCTAssertEqual(failure.path, service.fileURL.path)
        XCTAssertNotNil(failure.retry)

        giveBackPermission()
        service.markBookFinished(bookID: UUID(), title: "Read Again")
        ReadingStatsService.waitForQueuedSaves()

        XCTAssertFalse(center.hasUnsavedChanges)
    }

    /// Retry writes the statistics that could not be saved, waiting for the
    /// write, and settles the failure.
    func testRetrySavesTheStatisticsAndSettlesTheFailure() throws {
        let center = cleanSharedFailureCenter()
        let (service, giveBackPermission) = try readOnlyStatisticsService()
        defer { service.shutdown() }
        service.markBookFinished(bookID: UUID(), title: "Read Through")
        ReadingStatsService.waitForQueuedSaves()
        XCTAssertTrue(center.hasUnsavedChanges)

        giveBackPermission()
        let recorder = recordingAnnouncements { center.retry(.statistics) }

        XCTAssertFalse(center.hasUnsavedChanges)
        let relaunched = ReadingStatsService(fileURL: service.fileURL)
        defer { relaunched.shutdown() }
        XCTAssertEqual(relaunched.stats.finishedBooks.map(\.title), ["Read Through"])
        XCTAssertEqual(recorder.announcements.map(\.message), ["Listening statistics saved."])
    }

    // MARK: - Helpers

    /// A statistics service over a file in a folder of the test's own,
    /// which is read-only until the returned function gives back write
    /// permission.
    private func readOnlyStatisticsService() throws -> (ReadingStatsService, @Sendable () -> Void) {
        let directory = try makeTestDirectory("StatisticsFailure")
        let service = ReadingStatsService(fileURL: directory.appendingPathComponent("reading_stats.json"))
        return (service, makeReadOnly(directory))
    }
}
