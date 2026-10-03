import Combine
import XCTest
@testable import TextMouth

/// config.json and the data directory (FR02): an outside edit naming a
/// location that holds a library already starts no move, as one naming a
/// missing location doesn't (`DataDirectoryVerificationTests`); and while
/// the data directory is unavailable, config.json is neither read nor
/// written, then reconciled with the settings changed meanwhile once the
/// library is back.
@MainActor
final class DataDirectoryConfigTests: XCTestCase {

    // MARK: - The dataDirectoryPath Guard

    /// A location holding another library's identity starts no move.
    func testAnEditNamingAFolderHoldingAnotherLibraryRequestsNoMove() throws {
        let other = try makeSandboxDirectory("AnotherLibrary")
        _ = try LibraryIdentity.adopt(in: other)

        XCTAssertEqual(try requests(applying: other.path), [])
        XCTAssertEqual(DataDirectoryRequest.reasonToIgnore(other), "it holds a TextMouth library already")
    }

    /// A location holding a library from before identities starts no move
    /// either.
    func testAnEditNamingAFolderHoldingAnUnmarkedLibraryRequestsNoMove() throws {
        let other = try makeSandboxDirectory("UnmarkedLibrary")
        try Data("{}".utf8).write(to: other.appendingPathComponent("library.json"))

        XCTAssertEqual(try requests(applying: other.path), [])
    }

    /// A missing location is ignored, and an existing folder that holds no
    /// library may still ask for a move, which the move itself checks.
    func testOnlyAMissingOrLibraryHoldingLocationIsIgnored() throws {
        let scratch = try makeSandboxDirectory("Requests")
        let missing = scratch.appendingPathComponent("Not Here", isDirectory: true)
        let holdsFiles = scratch.appendingPathComponent("Holds Files", isDirectory: true)
        try FileManager.default.createDirectory(at: holdsFiles, withIntermediateDirectories: false)
        try Data("notes".utf8).write(to: holdsFiles.appendingPathComponent("notes.txt"))

        XCTAssertEqual(DataDirectoryRequest.reasonToIgnore(missing), "it doesn't exist on this Mac")
        XCTAssertNil(DataDirectoryRequest.reasonToIgnore(holdsFiles))
        XCTAssertEqual(try requests(applying: holdsFiles.path), [holdsFiles.path])
    }

    // MARK: - config.json While the Library Is Unavailable

    /// While the data directory is unavailable, the service following it
    /// reads nothing and writes nothing. When it is back, the file is
    /// reconciled: a setting changed meanwhile keeps its new value, every
    /// other one takes the file's, the result is published once and saved.
    func testConfigWaitsForTheLibraryAndIsReconciledWhenItReturns() throws {
        let root = try makeDataDirectoryMoveDestination("ConfigAway")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        var onDisk = ConfigService.AppConfig()
        onDisk.selectedVoiceID = "com.example.voice.file"
        onDisk.wordsPerMinute = 300
        let fileBytes = try ConfigService.fileData(for: onDisk)
        let file = root.appendingPathComponent("config.json")
        try fileBytes.write(to: file)
        StorageBoundary.shared.publish(root: root)
        DataDirectoryGate.close(root)
        addTeardownBlock { DataDirectoryGate.open(root) }

        let service = ConfigService()
        addTeardownBlock { service.shutdown() }
        var published: [ConfigService.AppConfig] = []
        let subscription = service.externalEdits.sink { published.append($0) }

        XCTAssertEqual(service.loadedFile, .missing, "the file was read while the library was unavailable")
        // The launch's save, then a change made while the library is away.
        service.saveToDisk()
        service.config.selectedLanguage = "fr"
        service.saveToDisk()
        XCTAssertEqual(try Data(contentsOf: file), fileBytes, "the file was written while the library was unavailable")

        DataDirectoryGate.open(root)
        NotificationCenter.default.post(name: .dataDirectoryDidBecomeAvailable, object: nil)

        XCTAssertEqual(service.config.selectedLanguage, "fr")
        XCTAssertEqual(service.config.selectedVoiceID, "com.example.voice.file")
        XCTAssertEqual(service.config.wordsPerMinute, 300)
        XCTAssertEqual(published.map(\.selectedLanguage), ["fr"])
        let saved = try ConfigService.decode(Data(contentsOf: file))
        XCTAssertEqual(saved.selectedLanguage, "fr")
        XCTAssertEqual(saved.selectedVoiceID, "com.example.voice.file")
        withExtendedLifetime(subscription) {}
    }

    /// A watcher that lost config.json while the library was away attaches to
    /// it again once the library is back, and applies an edit saved
    /// elsewhere meanwhile.
    func testTheWatcherFollowsConfigAgainOnceTheLibraryIsBack() throws {
        let root = try makeDataDirectoryMoveDestination("WatcherAway")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let file = root.appendingPathComponent("config.json")
        var before = ConfigService.AppConfig()
        before.wordsPerMinute = 250
        try ConfigService.fileData(for: before).write(to: file)
        StorageBoundary.shared.publish(root: root)
        addTeardownBlock { DataDirectoryGate.open(root) }
        let counter = WatchCounter()
        let service = ConfigService(fileOperations: counter.operations, coalescingDelay: .milliseconds(20))
        addTeardownBlock { service.shutdown() }
        var published: [ConfigService.AppConfig] = []
        let subscription = service.externalEdits.sink { published.append($0) }
        service.startWatching()
        XCTAssertEqual(counter.opens, 1)

        // The library goes away, and another Mac's edit replaces the file.
        DataDirectoryGate.close(root)
        var edited = before
        edited.wordsPerMinute = 410
        try ConfigService.fileData(for: edited).write(to: file, options: .atomic)
        XCTAssertTrue(waitUntil(timeout: 5) { counter.closes == 1 }, "the watcher kept following the file while away")

        DataDirectoryGate.open(root)
        NotificationCenter.default.post(name: .dataDirectoryDidBecomeAvailable, object: nil)

        XCTAssertEqual(counter.opens, 2, "the watcher did not attach to the file again")
        XCTAssertTrue(waitUntil(timeout: 5) { published.last?.wordsPerMinute == 410 }, "the edit made meanwhile was not applied")
        withExtendedLifetime(subscription) {}
    }

    // MARK: - Helpers

    /// The move requests a settings model, on a preferences store of its
    /// own, posts when config.json, edited outside TextMouth, names `path`
    /// as the data directory.
    private func requests(applying path: String) throws -> [String] {
        let center = NotificationCenter()
        let requested = CallLog<String>()
        let observer = center.addObserver(forName: .dataDirectoryChangeRequested, object: nil, queue: nil) { note in
            // Read first, so only a string crosses to the main actor.
            let path = note.userInfo?["path"] as? String ?? ""
            MainActor.assumeIsolated { requested.record(path) }
        }
        defer { center.removeObserver(observer) }
        let settings = SettingsViewModel(
            notificationCenter: center,
            initializeServices: false,
            userDefaults: try isolatedDefaults()
        )
        var config = ConfigService.AppConfig()
        config.dataDirectoryPath = path

        settings.applyConfigChanges(config)

        return requested.calls
    }
}

/// Counts the watch descriptors a config service opens and closes, doing
/// what the system's operations do.
@MainActor
private final class WatchCounter {
    /// Descriptors opened to watch config.json.
    private(set) var opens = 0
    /// Watch descriptors closed.
    private(set) var closes = 0

    /// The system's operations, with opens and closes counted.
    var operations: ConfigService.FileOperations {
        let system = ConfigService.FileOperations.system
        return ConfigService.FileOperations(
            write: system.write,
            openForEvents: { [self] path in
                let descriptor = system.openForEvents(path)
                if descriptor >= 0 {
                    opens += 1
                }
                return descriptor
            },
            close: { [self] descriptor in
                closes += 1
                system.close(descriptor)
            }
        )
    }
}
