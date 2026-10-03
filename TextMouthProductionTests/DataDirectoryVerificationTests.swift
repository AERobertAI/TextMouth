import XCTest
@testable import TextMouth

/// The hazards of a data directory that is missing at launch, or that
/// another Mac names (FR02 findings 1, 2, and 4), checked in folders inside
/// the test sandbox, never in /Volumes. Each failed on main before the fix:
/// - startup must neither load an empty library in place of a missing one
///   nor create anything where it was, so a save can never write an empty
///   index over the real one when the drive comes back;
/// - startup must create no missing parent of the data directory, so a
///   signed-out cloud folder never becomes a new local library;
/// - an outside edit of config.json naming a location this Mac doesn't have
///   must not start a move.
@MainActor
final class DataDirectoryVerificationTests: XCTestCase {

    // MARK: - (a) Missing at Launch

    /// A custom data directory holding a library goes missing, as an
    /// unplugged drive does, and TextMouth starts. The library is not
    /// available, nothing is created at its location, and when the folder
    /// comes back, a save leaves its library.json exactly as it was.
    func testStartupWithTheCustomDataDirectoryMissingNeitherCreatesNorOverwritesIt() throws {
        let root = try makeDataDirectoryMoveDestination("MissingAtLaunch")
        let originalIndex = try makeLibraryFolder(at: root)
        TextMouthPaths.setCustomRoot(root)
        StorageBoundary.shared.publish(root: root)
        addTeardownBlock { DataDirectoryGate.open(root) }
        // The drive goes away. It is copied aside and removed, rather than
        // moved, since the folder's bookmark would follow a move.
        let parked = root.deletingLastPathComponent().appendingPathComponent("Parked", isDirectory: true)
        try FileManager.default.copyItem(at: root, to: parked)
        try FileManager.default.removeItem(at: root)

        let model = LibraryViewModel()

        XCTAssertEqual(model.dataDirectoryUnavailability, .folderMissing(folder: root.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.path),
            "Startup created the missing data directory, holding \(Self.listing(of: root)); the model "
                + "shows \(model.library.books.count) books and \(model.library.folders.count) folders"
        )

        // The drive comes back, and the library saves.
        try FileManager.default.copyItem(at: parked, to: root)
        model.save()
        LibraryPersistenceService.flushPendingSave()

        let index = try Data(contentsOf: root.appendingPathComponent("library.json"))
        let written = try? JSONDecoder.libraryIndex.decode(Library.self, from: index)
        XCTAssertEqual(
            index,
            originalIndex,
            "The save replaced the returned library.json with \(written?.books.count ?? -1) books and "
                + "\(written?.folders.count ?? -1) folders (it held 0 books and 1 folder)"
        )
    }

    // MARK: - (b) Missing Parents

    /// A custom data directory whose parent folders are missing too, as a
    /// signed-out cloud drive's are: startup creates none of them.
    func testStartupCreatesNoMissingParentOfTheCustomDataDirectory() throws {
        let scratch = try makeDataDirectoryMoveDestination("MissingParents").deletingLastPathComponent()
        let drive = scratch.appendingPathComponent("GoogleDrive-reader", isDirectory: true)
        let root = drive.appendingPathComponent("My Drive/TextMouth", isDirectory: true)
        TextMouthPaths.setCustomRoot(root)
        StorageBoundary.shared.publish(root: root)
        addTeardownBlock { DataDirectoryGate.open(root) }

        let model = LibraryViewModel()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: drive.path),
            "Startup created the missing parents of the data directory: \(Self.listing(of: drive)); "
                + "the model shows \(model.library.books.count) books"
        )
    }

    // MARK: - (c) Another Mac's Location

    /// config.json, synced from another Mac, names that Mac's data directory,
    /// which doesn't exist on this one. The edit must not ask the library to
    /// move there.
    func testAnOutsideEditNamingAMissingLocationRequestsNoMove() throws {
        let scratch = try makeSandboxDirectory("AnotherMacsPath")
        let folderName = "TextMouth \(UUID().uuidString)"
        let otherMacsRoot = scratch.appendingPathComponent(
            "Users/another/Library/CloudStorage/GoogleDrive-another/\(folderName)",
            isDirectory: true
        )
        let center = NotificationCenter()
        let requests = CallLog<String>()
        let observer = center.addObserver(forName: .dataDirectoryChangeRequested, object: nil, queue: nil) { note in
            // Delivered on the posting thread, the main one, inside the edit.
            MainActor.assumeIsolated { requests.record(note.userInfo?["path"] as? String ?? "") }
        }
        addTeardownBlock { center.removeObserver(observer) }
        let url = try makeConfigFileURL()
        let service = ConfigService(fileURL: url)
        addTeardownBlock { service.shutdown() }
        let settings = SettingsViewModel(
            notificationCenter: center,
            initializeServices: true,
            userDefaults: try isolatedDefaults(),
            configService: service
        )

        // The other Mac's save arrives, and the watcher's settled batch
        // handles it.
        var edited = service.config
        edited.dataDirectoryPath = otherMacsRoot.path
        try ConfigService.fileData(for: edited).write(to: url, options: .atomic)
        service.handleFileEvent(.write)

        XCTAssertEqual(service.config.dataDirectoryPath, otherMacsRoot.path, "the edit was not applied")
        XCTAssertEqual(requests.calls, [], "The edit asked the library to move to another Mac's location")
        XCTAssertEqual(
            debugLogLines(containing: "CONFIG_FILE: ignored the dataDirectoryPath GoogleDrive-another/\(folderName)").count,
            1
        )
        withExtendedLifetime(settings) {}
    }

    // MARK: - Fixtures

    /// Lays out a library at `root`: a Library folder and a library.json
    /// holding one folder row and no books. Returns the index's bytes.
    private func makeLibraryFolder(at root: URL) throws -> Data {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Library/Sea Charts", isDirectory: true),
            withIntermediateDirectories: true
        )
        let index = try JSONEncoder.libraryIndex.encode(Library(folders: [BookFolder(name: "Sea Charts")]))
        try index.write(to: root.appendingPathComponent("library.json"))
        return index
    }

    /// Every item below `folder`, relative to it and sorted, for messages.
    private static func listing(of folder: URL) -> String {
        let items = FileManager.default.enumerator(atPath: folder.path)?.compactMap { $0 as? String } ?? []
        return items.isEmpty ? "nothing" : items.sorted().joined(separator: ", ")
    }
}

private extension JSONEncoder {
    /// Encodes a library the way library.json holds it.
    static var libraryIndex: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        return encoder
    }
}

private extension JSONDecoder {
    /// Decodes library.json the way the library loads it.
    static var libraryIndex: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
