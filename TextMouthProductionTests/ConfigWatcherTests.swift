import Combine
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

    // MARK: - Launch

    /// Launch applies a file edited while TextMouth was closed over
    /// preferences that disagree with it everywhere (an empty store, whose
    /// defaults differ from every value in the file, and which names no
    /// voice), and leaves the file exactly as it was: no write, the same
    /// file, modification date, and bytes, even once the watcher has had
    /// time to act.
    func testLaunchAdoptsAnEditedFileAndLeavesItUntouched() throws {
        let url = try makeConfigFileURL()
        let edited = launchConsistentConfig()
        let bytes = try ConfigService.fileData(for: edited)
        try bytes.write(to: url)
        let stamp = try fileStamp(url)
        let counter = FileOperationCounter()

        let (service, settings) = launch(url, defaults: try isolatedDefaults(), counter: counter)
        settle()

        var mirrored = edited
        settings.writePreferences(into: &mirrored)
        XCTAssertEqual(mirrored, edited, "every preference takes the file's value")
        XCTAssertEqual(service.config, edited)
        XCTAssertEqual(counter.writes, 0)
        XCTAssertEqual(try fileStamp(url), stamp)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    /// A file an older TextMouth wrote (laid out differently, without the
    /// newer fields, with speed unset, and with one value out of range) is
    /// rewritten once at launch. The file's values and the repaired one are
    /// kept, the preferences fill in the rest, and nothing answers that write
    /// with another.
    func testLaunchRewritesAStaleFileExactlyOnce() throws {
        let url = try makeConfigFileURL()
        try Data("""
        {
            "selectedVoiceID": "com.apple.voice.compact.fr-FR.Thomas",
            "wordsPerMinute": 0,
            "confirmBeforeDelete": false,
            "punctuationPauseLevel": 40
        }
        """.utf8).write(to: url)
        let defaults = try isolatedDefaults()
        defaults.set(333.0, forKey: "wordsPerMinute")
        let counter = FileOperationCounter()

        let (service, settings) = launch(url, defaults: defaults, counter: counter)
        settle()

        let written = try Data(contentsOf: url)
        let rewritten = try JSONDecoder().decode(ConfigService.AppConfig.self, from: written)
        XCTAssertEqual(counter.writes, 1)
        XCTAssertEqual(written, try ConfigService.fileData(for: service.config))
        XCTAssertEqual(rewritten.selectedVoiceID, "com.apple.voice.compact.fr-FR.Thomas")
        XCTAssertEqual(rewritten.wordsPerMinute, 333, "an unset speed keeps the stored one")
        XCTAssertFalse(rewritten.confirmBeforeDelete)
        XCTAssertEqual(rewritten.punctuationPauseLevel, 3)
        XCTAssertEqual(settings.punctuationPauseLevel, 3)
    }

    /// A file that cannot be read at launch is left for correction: nothing
    /// is written, its bytes stay, and the preferences keep their values.
    func testLaunchLeavesAnUnreadableFileForCorrection() throws {
        let url = try makeConfigFileURL()
        let broken = Data(#"{"wordsPerMinute": 300,,}"#.utf8)
        try broken.write(to: url)
        let defaults = try isolatedDefaults()
        defaults.set(250.0, forKey: "wordsPerMinute")
        let counter = FileOperationCounter()

        let (_, settings) = launch(url, defaults: defaults, counter: counter)
        settle()

        XCTAssertEqual(counter.writes, 0)
        XCTAssertEqual(try Data(contentsOf: url), broken)
        XCTAssertEqual(settings.wordsPerMinute, 250)
        XCTAssertEqual(debugLogLines(containing: url.path).count, 1)
    }

    // MARK: - Delivering external edits

    /// Settings changed in quick succession are announced once each and keep
    /// their last value. TextMouth's own saves are never replayed into the
    /// preferences; they used to be, a moment later, which rolled each change
    /// back to an older value and announced it again.
    func testRapidSettingChangesAreNeverReplayedBack() throws {
        let url = try makeConfigFileURL()
        try ConfigService.fileData(for: launchConsistentConfig()).write(to: url)
        let notificationCenter = NotificationCenter()
        let (service, settings) = launch(
            url,
            defaults: try isolatedDefaults(),
            counter: FileOperationCounter(),
            notificationCenter: notificationCenter
        )
        var speechChanges = 0
        let subscription = notificationCenter.publisher(for: .speechSettingsChanged)
            .sink { _ in speechChanges += 1 }

        settings.wordsPerMinute = 300
        settings.wordsPerMinute = 320
        settle()
        subscription.cancel()

        XCTAssertEqual(speechChanges, 2)
        XCTAssertEqual(settings.wordsPerMinute, 320)
        XCTAssertEqual(service.config.wordsPerMinute, 320)
        XCTAssertEqual(try ConfigService.decode(Data(contentsOf: url)).wordsPerMinute, 320)
    }

    /// An edit saved from outside TextMouth, noticed by the real file
    /// watcher, reaches the preferences exactly once and is not saved back.
    func testAnExternalEditReachesThePreferencesOnce() throws {
        let url = try makeConfigFileURL()
        var edit = launchConsistentConfig()
        try ConfigService.fileData(for: edit).write(to: url)
        let counter = FileOperationCounter()
        let (service, settings) = launch(url, defaults: try isolatedDefaults(), counter: counter)
        let recorder = EditRecorder(service)

        edit.sleepFadeOutDuration = 9
        try editorSave(ConfigService.fileData(for: edit), to: url)
        XCTAssertTrue(waitUntil(timeout: 5) { recorder.edits.count == 1 })
        settle()

        XCTAssertEqual(recorder.edits, [edit])
        XCTAssertEqual(settings.sleepFadeOutDuration, 9)
        XCTAssertEqual(counter.writes, 0)
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

    /// Launches the way the app does: a service that loads `url`, then a
    /// settings model on `defaults` that reconciles the two and starts the
    /// watcher, which stops when the test ends.
    private func launch(
        _ url: URL,
        defaults: UserDefaults,
        counter: FileOperationCounter,
        notificationCenter: NotificationCenter = NotificationCenter()
    ) -> (service: ConfigService, settings: SettingsViewModel) {
        let service = ConfigService(fileURL: url, fileOperations: counter.operations)
        addTeardownBlock { service.shutdown() }
        let settings = SettingsViewModel(
            notificationCenter: notificationCenter,
            initializeServices: true,
            userDefaults: defaults,
            configService: service
        )
        return (service, settings)
    }

    /// `everyFieldCustomized` with the data directory in use, so the settings
    /// model saves it back byte for byte: a launch on it has nothing to change.
    private func launchConsistentConfig() -> ConfigService.AppConfig {
        var config = ConfigService.AppConfig.everyFieldCustomized
        config.dataDirectoryPath = ConfigService.AppConfig.currentDataDirectoryPath
        return config
    }

    /// Lets file events, coalesced checks, and other queued main-actor work
    /// run for `seconds`, as the app's run loop would between two actions.
    private func settle(for seconds: TimeInterval = 0.5) {
        let quiet = expectation(description: "nothing is expected while settling")
        quiet.isInverted = true
        wait(for: [quiet], timeout: seconds)
    }

    /// Saves `data` over `url` the way editors do: into a temporary file
    /// beside it, which is then renamed over it, replacing the file in one
    /// step.
    private func editorSave(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary)
        guard rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Records the external edits a service publishes, in order.
    @MainActor
    private final class EditRecorder {
        /// Every edit published so far.
        private(set) var edits: [ConfigService.AppConfig] = []
        /// Keeps the subscription for the recorder's lifetime.
        private var subscription: AnyCancellable?

        init(_ service: ConfigService) {
            subscription = service.externalEdits.sink { [weak self] edit in
                self?.edits.append(edit)
            }
        }
    }

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
