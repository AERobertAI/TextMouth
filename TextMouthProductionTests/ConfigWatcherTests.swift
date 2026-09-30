import XCTest
@testable import TextMouth

/// How config.json and the preferences meet: loading the file, reconciling it
/// with the preferences at launch, and following edits saved from outside
/// TextMouth. Every test uses a config.json of its own inside the isolated
/// test root and, where preferences are involved, a throwaway preferences
/// suite, so neither the running test host nor the user's settings are
/// touched.
@MainActor
final class ConfigWatcherTests: XCTestCase {
    // MARK: - Loading

    /// The service holds the file's values as soon as it exists, so no
    /// consumer created afterwards can read the defaults in their place.
    func testNewServiceHoldsTheFileValuesAtOnce() throws {
        let url = try makeConfigFileURL()
        let saved = ConfigService.AppConfig.everyFieldCustomized
        try ConfigService.fileData(for: saved).write(to: url)

        let service = ConfigService(fileURL: url)

        XCTAssertEqual(service.config, saved)
        XCTAssertEqual(service.loadedFile, .decoded)
        XCTAssertTrue(service.hasExistingConfig)
    }

    /// Any decodable file is an existing config, including one that leaves
    /// speed unset (0) as older files do: it still holds every other setting.
    func testADecodableFileIsAnExistingConfigEvenWithSpeedUnset() throws {
        let url = try makeConfigFileURL()
        try Data(#"{"wordsPerMinute": 0, "confirmBeforeDelete": false}"#.utf8).write(to: url)

        let service = ConfigService(fileURL: url)

        XCTAssertTrue(service.hasExistingConfig)
        XCTAssertEqual(service.loadedFile, .decoded)
        XCTAssertFalse(service.config.confirmBeforeDelete)
    }

    /// Without a file there is no existing config, and the defaults stand.
    func testAMissingFileIsNoExistingConfig() throws {
        let service = ConfigService(fileURL: try makeConfigFileURL())

        XCTAssertFalse(service.hasExistingConfig)
        XCTAssertEqual(service.loadedFile, .missing)
        XCTAssertEqual(service.config, ConfigService.AppConfig())
    }

    /// A file that is not JSON is no existing config either: the defaults
    /// stand, and the debug log names the file once.
    func testAnUndecodableFileIsLoggedAndIsNoExistingConfig() throws {
        let url = try makeConfigFileURL()
        try Data(#"{"wordsPerMinute": 300,,}"#.utf8).write(to: url)

        let service = ConfigService(fileURL: url)

        XCTAssertFalse(service.hasExistingConfig)
        XCTAssertEqual(service.loadedFile, .unreadable)
        XCTAssertEqual(service.config, ConfigService.AppConfig())
        XCTAssertEqual(debugLogLines(containing: url.path).count, 1)
    }

    // MARK: - Saving

    /// A save writes only when the file's bytes would change: saving the
    /// same settings again leaves the file and its modification date alone.
    func testSavingUnchangedSettingsWritesNothing() throws {
        let url = try makeConfigFileURL()
        let counter = FileOperationCounter()
        let service = ConfigService(fileURL: url, fileOperations: counter.operations)
        service.config = .everyFieldCustomized

        service.saveToDisk()
        let stamp = try fileStamp(url)
        service.saveToDisk()

        XCTAssertEqual(counter.writes, 1)
        XCTAssertEqual(try fileStamp(url), stamp)
        XCTAssertEqual(try Data(contentsOf: url), try ConfigService.fileData(for: .everyFieldCustomized))

        service.config.wordsPerMinute = 300
        service.saveToDisk()

        XCTAssertEqual(counter.writes, 2)
    }

    // MARK: - Helpers

    /// Counts the file-system calls a service makes, passing each on to the
    /// system.
    @MainActor
    private final class FileOperationCounter {
        /// Atomic writes of config.json.
        private(set) var writes = 0

        /// The system's operations, counted.
        var operations: ConfigService.FileOperations {
            let system = ConfigService.FileOperations.system
            return ConfigService.FileOperations(write: { [self] data, url in
                writes += 1
                try system.write(data, url)
            })
        }
    }

    /// One version of a file on disk: its identity, which an atomic write
    /// replaces, and its modification date.
    private struct FileStamp: Equatable {
        let identity: FileIdentity?
        let modified: Date?
    }

    /// The version of the file at `url` now.
    private func fileStamp(_ url: URL) throws -> FileStamp {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return FileStamp(identity: FileIdentity(of: url), modified: attributes[.modificationDate] as? Date)
    }

    /// A config.json location in a directory of this test's own inside the
    /// isolated test root. The directory is removed when the test ends.
    private func makeConfigFileURL() throws -> URL {
        let directory = TextMouthPaths.root
            .appendingPathComponent("ConfigWatcherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("config.json")
    }
}
