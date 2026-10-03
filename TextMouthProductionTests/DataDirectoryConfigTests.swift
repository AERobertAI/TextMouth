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

    // MARK: - Helpers

    /// The move requests a settings model, on a preferences store of its
    /// own, posts when config.json, edited outside TextMouth, names `path`
    /// as the data directory.
    private func requests(applying path: String) throws -> [String] {
        let center = NotificationCenter()
        let requested = CallLog<String>()
        let observer = center.addObserver(forName: .dataDirectoryChangeRequested, object: nil, queue: nil) { note in
            MainActor.assumeIsolated { requested.record(note.userInfo?["path"] as? String ?? "") }
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
