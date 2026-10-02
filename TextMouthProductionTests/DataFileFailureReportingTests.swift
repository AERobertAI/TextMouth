import XCTest
@testable import TextMouth

/// A save of the listening statistics or the settings that fails is
/// reported to the failure center with the file's path and a retry, instead
/// of only being logged, and the next save that succeeds settles it (TODO
/// S09). Each test writes a file of its own, made to fail by a read-only
/// folder or an injected write.
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

    // MARK: - Settings

    /// A settings save that cannot be written is reported with config.json's
    /// path, in place of only the debug log line; Retry saves the settings
    /// once writing works again, and settles the failure.
    func testAFailedSettingsSaveIsReportedAndRetrySavesTheSettings() throws {
        let center = cleanSharedFailureCenter()
        let refusing = FailureSwitch()
        let url = try makeTestDirectory("SettingsFailure").appendingPathComponent("config.json")
        let service = ConfigService(fileURL: url, fileOperations: ConfigService.FileOperations(
            write: { data, url in
                try refusing.throwIfOn()
                try data.write(to: url, options: .atomic)
            },
            openForEvents: { _ in -1 },
            close: { _ in }
        ))

        service.config.wordsPerMinute = 425
        service.saveToDisk()

        let failure = try XCTUnwrap(center.outstandingFailures().first)
        XCTAssertEqual(failure.subject, .configuration)
        XCTAssertEqual(failure.path, url.path)
        XCTAssertEqual(failure.sentence, "Settings could not be saved: The volume is read-only.")
        XCTAssertEqual(debugLogLines(containing: "CONFIG_FILE: could not save \(url.path)").count, 1)

        refusing.isOn = false
        recordingAnnouncements { center.retry(.configuration) }

        XCTAssertFalse(center.hasUnsavedChanges)
        XCTAssertEqual(try ConfigService.decode(Data(contentsOf: url)).wordsPerMinute, 425)
    }

    /// A save that finds config.json already holding the settings has
    /// nothing to write, and still settles an earlier failure: the settings
    /// are on disk.
    func testASaveThatFindsTheSettingsOnDiskSettlesAFailure() throws {
        let center = cleanSharedFailureCenter()
        let url = try makeTestDirectory("SettingsOnDisk").appendingPathComponent("config.json")
        let service = ConfigService(fileURL: url)
        center.recordFailure(.configuration, path: url.path, error: WriteRefused())
        try ConfigService.fileData(for: service.config).write(to: url)

        service.saveToDisk()

        XCTAssertFalse(center.hasUnsavedChanges)
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
