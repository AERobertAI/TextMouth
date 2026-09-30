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

    // MARK: - Helpers

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
