import Combine
import XCTest
import os
@testable import TextMouth

/// config.json follows the settings without writing at every step (PERF17):
/// a change asks for a save, which writes the file once changes pause, and
/// quitting, a data-directory move, or an immediate save writes it at once.
/// The file is read with dataless files left in the cloud, so one only in
/// the cloud is neither waited for nor written over.
@MainActor
final class ConfigSaveCoalescingTests: XCTestCase {

    // MARK: - Coalesced Saves

    /// Saves asked for in a burst write the file once, after the burst, with
    /// the last settings.
    func testSavesAskedForInABurstWriteTheFileOnce() async throws {
        let (service, writes, file) = try makeService()

        for speed in [210.0, 220, 230, 240] {
            service.config.wordsPerMinute = speed
            service.scheduleSave()
        }
        XCTAssertEqual(writes.count, 0, "the file was written before the changes paused")
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(writes.count, 1)
        XCTAssertFalse(service.hasScheduledSave)
        XCTAssertEqual(try ConfigService.decode(Data(contentsOf: file)).wordsPerMinute, 240)
    }

    /// An immediate save writes at once and takes the place of a save that
    /// was waiting, which then writes nothing more.
    func testAnImmediateSaveTakesThePlaceOfAWaitingOne() async throws {
        let (service, writes, _) = try makeService()
        service.config.wordsPerMinute = 260
        service.scheduleSave()

        service.saveToDisk()
        XCTAssertEqual(writes.count, 1)
        XCTAssertFalse(service.hasScheduledSave)
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(writes.count, 1, "the waiting save wrote the file again")
    }

    /// A flush writes a waiting save at once, and nothing when none waits;
    /// shutting down, as TextMouth quits, flushes too.
    func testAFlushAndShutdownWriteAWaitingSave() throws {
        let (service, writes, file) = try makeService()

        service.flushScheduledSave()
        XCTAssertEqual(writes.count, 0, "a flush with no save waiting wrote the file")

        service.config.wordsPerMinute = 270
        service.scheduleSave()
        service.flushScheduledSave()
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(try ConfigService.decode(Data(contentsOf: file)).wordsPerMinute, 270)

        service.config.wordsPerMinute = 280
        service.scheduleSave()
        service.shutdown()
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(try ConfigService.decode(Data(contentsOf: file)).wordsPerMinute, 280)
    }

    /// Quitting's check for unsaved changes writes the shared service's
    /// waiting save, so a failure to save it is shown before TextMouth quits.
    func testTheQuitCheckWritesTheWaitingSave() {
        let shared = ConfigService.shared
        shared.scheduleSave()
        XCTAssertTrue(shared.hasScheduledSave)

        UnsavedChangesTerminationGuard.flushPendingWrites()

        XCTAssertFalse(shared.hasScheduledSave)
    }

    /// An edit made outside TextMouth that the watcher applies while a save
    /// waits keeps the change that save is waiting to write: the two are
    /// merged and published together, and the save then writes both, so
    /// neither the settings nor the file lose the change made here.
    func testAnEditAppliedWhileASaveWaitsKeepsTheWaitingChange() throws {
        let (service, writes, file) = try makeService(startingWith: ConfigService.AppConfig())
        var published: [ConfigService.AppConfig] = []
        let subscription = service.externalEdits.sink { published.append($0) }
        service.config.wordsPerMinute = 330
        service.scheduleSave()
        // An editor saves another setting before TextMouth's save is due.
        var edit = ConfigService.AppConfig()
        edit.sleepFadeOutDuration = 9
        try ConfigService.fileData(for: edit).write(to: file, options: .atomic)

        service.handleFileEvent(.write)

        XCTAssertEqual(service.config.wordsPerMinute, 330, "the edit replaced the change waiting to be saved")
        XCTAssertEqual(service.config.sleepFadeOutDuration, 9)
        XCTAssertEqual(published.map(\.wordsPerMinute), [330], "the published edit undid the change")
        XCTAssertEqual(writes.count, 0)
        XCTAssertTrue(service.hasScheduledSave)

        service.flushScheduledSave()

        let saved = try ConfigService.decode(Data(contentsOf: file))
        XCTAssertEqual(saved.wordsPerMinute, 330)
        XCTAssertEqual(saved.sleepFadeOutDuration, 9)
        subscription.cancel()
    }

    /// A save a test leaves waiting on the shared service is written as that
    /// test ends, by the observer the test bundle registers, so it cannot
    /// land during the next test.
    func testASaveLeftWaitingIsWrittenAsItsTestEnds() {
        XCTAssertTrue(ConfigSaveFlush.shared.sawBundleStart, "the test bundle did not register the observer")
        let shared = ConfigService.shared
        shared.scheduleSave()
        XCTAssertTrue(shared.hasScheduledSave)

        ConfigSaveFlush.shared.testCaseDidFinish(self)

        XCTAssertFalse(shared.hasScheduledSave)
    }

    // MARK: - A File Only in the Cloud

    /// A config.json only in the cloud is neither read, which would wait on
    /// the network, nor written over, which would replace another Mac's
    /// settings; the debug log says so once. Once the file is on this Mac,
    /// the next save merges it: the change made meanwhile stands, and every
    /// other setting takes the file's value.
    func testAFileOnlyInTheCloudIsNeitherReadNorWrittenOver() throws {
        let inCloud = OSAllocatedUnfairLock(initialState: false)
        let (service, writes, file) = try makeService(
            startingWith: ConfigService.AppConfig(),
            refusingReadsWhile: inCloud
        )
        XCTAssertEqual(service.loadedFile, .decoded)
        let notedLine = "CONFIG_FILE: config.json is only in the cloud"
        let notedBefore = debugLogLines(containing: notedLine).count
        // Another Mac saved settings this Mac has not seen, and the file went
        // to the cloud.
        var elsewhere = service.config
        elsewhere.punctuationPauseLevel = 3
        try ConfigService.fileData(for: elsewhere).write(to: file, options: .atomic)
        inCloud.withLock { $0 = true }

        service.config.wordsPerMinute = 290
        service.saveToDisk()
        service.saveToDisk()

        XCTAssertEqual(writes.count, 0, "a file only in the cloud was written over")
        XCTAssertEqual(debugLogLines(containing: notedLine).count, notedBefore + 1)

        inCloud.withLock { $0 = false }
        service.saveToDisk()

        XCTAssertEqual(writes.count, 1)
        let saved = try ConfigService.decode(Data(contentsOf: file))
        XCTAssertEqual(saved.wordsPerMinute, 290, "the change made meanwhile was lost")
        XCTAssertEqual(saved.punctuationPauseLevel, 3, "the other Mac's setting was lost")
    }

    /// A launch that finds config.json only in the cloud applies none of it
    /// and waits for nothing: the preferences stand until the file is here.
    func testLaunchLeavesAFileOnlyInTheCloudUnapplied() throws {
        let file = try makeConfigFileURL()
        var elsewhere = ConfigService.AppConfig()
        elsewhere.wordsPerMinute = 410
        try ConfigService.fileData(for: elsewhere).write(to: file, options: .atomic)
        let inCloud = OSAllocatedUnfairLock(initialState: true)

        let service = ConfigService(fileURL: file, fileOperations: Self.operations(refusingReadsWhile: inCloud))

        XCTAssertEqual(service.loadedFile, .missing)
        XCTAssertFalse(service.hasExistingConfig)
        XCTAssertEqual(service.config, ConfigService.AppConfig())
    }

    // MARK: - Fixtures

    /// A service bound to a config.json of the test's own, holding `initial`
    /// when it starts (no file when nil), its writes counted and its reads
    /// refused, as a dataless file's are, while `inCloud` holds true. Its
    /// watcher never starts.
    private func makeService(
        startingWith initial: ConfigService.AppConfig? = nil,
        refusingReadsWhile inCloud: OSAllocatedUnfairLock<Bool> = OSAllocatedUnfairLock(initialState: false)
    ) throws -> (ConfigService, WriteCount, URL) {
        let file = try makeConfigFileURL()
        if let initial {
            try ConfigService.fileData(for: initial).write(to: file, options: .atomic)
        }
        let writes = WriteCount()
        var operations = Self.operations(refusingReadsWhile: inCloud)
        operations.write = { data, url in
            writes.increment()
            try data.write(to: url, options: .atomic)
        }
        let service = ConfigService(fileURL: file, fileOperations: operations, saveDelay: .milliseconds(100))
        return (service, writes, file)
    }

    /// File operations that read as the app does, except that a read is
    /// refused, as a dataless file's is, while `inCloud` holds true.
    private static func operations(refusingReadsWhile inCloud: OSAllocatedUnfairLock<Bool>) -> ConfigService.FileOperations {
        var operations = ConfigService.FileOperations(
            write: { data, url in try data.write(to: url, options: .atomic) },
            openForEvents: { _ in -1 },
            close: { _ in }
        )
        let read = operations.read
        operations.read = { url in
            if inCloud.withLock({ $0 }) {
                throw MaintenanceFileAccess.refusal(of: url)
            }
            return try read(url)
        }
        return operations
    }
}

/// How many times a test's config.json was written. Main-actor isolated,
/// as the service's file operations are.
@MainActor
private final class WriteCount {
    /// The writes so far.
    private(set) var count = 0

    /// Counts one write.
    func increment() {
        count += 1
    }
}
