import XCTest
@testable import TextMouth

/// A save of the listening statistics, the settings, or the substitution
/// rules that fails is reported to the failure center with the file's path
/// and a retry, instead of only being logged, and the next save that
/// succeeds settles it (TODO S09). Writes are made to fail by a read-only
/// folder, an injected write, or a folder standing where the file goes.
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
        let service = makeConfigService(fileURL: url, fileOperations: ConfigService.FileOperations(
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
        XCTAssertEqual(debugLogLines(naming: url).filter { $0.contains("CONFIG_FILE: could not save ") }.count, 1)

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
        let service = makeConfigService(fileURL: url)
        center.recordFailure(.configuration, path: url.path, error: WriteRefused())
        try ConfigService.fileData(for: service.config).write(to: url)

        service.saveToDisk()

        XCTAssertFalse(center.hasUnsavedChanges)
    }

    // MARK: - Substitution Rules

    /// A save of the substitution rules that cannot be written is reported
    /// with the file's path; Retry saves the same rules once the file can be
    /// written, and settles the failure. The rules file is the hosted app's,
    /// so it is put back as it was afterwards.
    func testAFailedSubstitutionSaveIsReportedAndRetrySavesTheRules() throws {
        let center = cleanSharedFailureCenter()
        let url = TextMouthPaths.substitutionsFile
        let obstruction = try WriteObstruction.place(at: url)
        addTeardownBlock { obstruction.restoreOriginal() }
        let rule = SubstitutionRule(name: "Failure fixture", pattern: "colour", replacement: "color")
        let service = TextSubstitutionService(rules: [])

        service.addRule(rule)

        let failure = try XCTUnwrap(center.outstandingFailures().first)
        XCTAssertEqual(failure.subject, .substitutions)
        XCTAssertEqual(failure.path, url.path)
        XCTAssertTrue(failure.sentence.hasPrefix("Text substitution rules could not be saved: "), failure.sentence)

        obstruction.clear()
        recordingAnnouncements { center.retry(.substitutions) }

        XCTAssertFalse(center.hasUnsavedChanges)
        XCTAssertEqual(try JSONDecoder().decode([SubstitutionRule].self, from: Data(contentsOf: url)), [rule])
    }

    // MARK: - Retry While Storage Work Is Held

    /// Retry pressed while a data-directory move holds the storage work, as
    /// Storage settings' Retry Saving can be during the move's copy, writes
    /// no statistics and leaves them unsaved; once the move ends they are
    /// saved by themselves. The retry used to write the file at once from
    /// the main thread, into the data directory being copied, and call the
    /// statistics saved, so the moved library could keep an older file.
    func testARetryDuringAMoveSavesTheStatisticsOnlyOnceTheMoveEnds() async throws {
        let center = cleanSharedFailureCenter()
        let (service, giveBackPermission) = try readOnlyStatisticsService()
        defer { service.shutdown() }
        service.markBookFinished(bookID: UUID(), title: "Read Through")
        ReadingStatsService.waitForQueuedSaves()
        XCTAssertTrue(center.hasUnsavedChanges)
        giveBackPermission()
        let hold = try StorageBoundary.shared.holdWork(for: .movingDataDirectory)
        defer { hold.release() }

        recordingAnnouncements { center.retry(.statistics) }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: service.fileURL.path),
            "the retry wrote the statistics while a move held the storage work"
        )
        XCTAssertEqual(center.outstandingFailures().map(\.sentence), [
            "Listening statistics could not be saved: TextMouth saves them once the move of its data directory ends.",
        ], "the statistics were called saved, or the wait was not said")

        hold.release()
        await waitForKeptRetries(of: center)

        XCTAssertFalse(center.hasUnsavedChanges)
        let relaunched = ReadingStatsService(fileURL: service.fileURL)
        defer { relaunched.shutdown() }
        XCTAssertEqual(relaunched.stats.finishedBooks.map(\.title), ["Read Through"])
    }

    /// Retry pressed while a folder edit holds the storage work writes no
    /// settings and leaves them unsaved, saying when they are saved; once
    /// the edit ends they are saved by themselves.
    func testARetryDuringAFolderEditSavesTheSettingsOnlyOnceItEnds() async throws {
        let center = cleanSharedFailureCenter()
        let refusing = FailureSwitch()
        let url = try makeTestDirectory("SettingsHeldRetry").appendingPathComponent("config.json")
        let service = makeConfigService(fileURL: url, fileOperations: ConfigService.FileOperations(
            write: { data, url in
                try refusing.throwIfOn()
                try data.write(to: url, options: .atomic)
            },
            openForEvents: { _ in -1 },
            close: { _ in }
        ))
        service.config.wordsPerMinute = 425
        service.saveToDisk()
        XCTAssertTrue(center.hasUnsavedChanges)
        refusing.isOn = false
        let hold = try StorageBoundary.shared.holdWork(for: .movingBooksBetweenFolders)
        defer { hold.release() }

        recordingAnnouncements { center.retry(.configuration) }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "the retry wrote the settings while a folder edit held the storage work"
        )
        XCTAssertEqual(center.outstandingFailures().map(\.sentence), [
            "Settings could not be saved: TextMouth saves them once it has finished moving books between folders.",
        ])

        hold.release()
        await waitForKeptRetries(of: center)

        XCTAssertFalse(center.hasUnsavedChanges)
        XCTAssertEqual(try ConfigService.decode(Data(contentsOf: url)).wordsPerMinute, 425)
        // The retry holds the service weakly: it must last until the retry ran.
        withExtendedLifetime(service) {}
    }

    /// Retry pressed during a data-directory move's copy writes no rules
    /// into the data directory being copied, and once the move has
    /// published they are saved by themselves into the moved library. The
    /// retry used to write the old data directory and call the rules saved,
    /// so the moved library kept the copy made before, without them.
    func testARetryDuringAMoveSavesTheRulesInTheMovedLibrary() async throws {
        let center = cleanSharedFailureCenter()
        let old = try makeCurrentDataDirectory("RulesRetryOld")
        let oldFile = TextMouthPaths.substitutionsFile
        XCTAssertTrue(oldFile.path.hasPrefix(old.path + "/"), "the rules are not in the test's data directory: \(oldFile.path)")
        let obstruction = try WriteObstruction.place(at: oldFile)
        let rule = SubstitutionRule(name: "Held retry", pattern: "harbour", replacement: "harbor")
        let service = TextSubstitutionService(rules: [])
        service.addRule(rule)
        XCTAssertTrue(center.hasUnsavedChanges)
        obstruction.clear()
        let hold = try StorageBoundary.shared.holdWork(for: .movingDataDirectory)
        defer { hold.release() }
        // The move's copy reaches the rules before Retry is pressed.
        let new = try makeDataDirectoryMoveDestination("RulesRetryNew")
        try FileManager.default.copyItem(at: old, to: new)

        recordingAnnouncements { center.retry(.substitutions) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path), "the retry wrote the data directory being copied")
        XCTAssertTrue(center.hasUnsavedChanges, "the rules were called saved before the move had them")

        StorageBoundary.shared.publish(root: new)
        hold.release()
        await waitForKeptRetries(of: center)

        let movedFile = TextMouthPaths.substitutionsFile
        XCTAssertTrue(movedFile.path.hasPrefix(new.path + "/"), "the move did not publish: \(movedFile.path)")
        XCTAssertEqual(
            try JSONDecoder().decode([SubstitutionRule].self, from: Data(contentsOf: movedFile)),
            [rule],
            "the moved library does not have the rules"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path), "the old data directory was written after the move")
        XCTAssertFalse(center.hasUnsavedChanges)
        // The retry holds the service weakly: it must last until the retry ran.
        withExtendedLifetime(service) {}
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
