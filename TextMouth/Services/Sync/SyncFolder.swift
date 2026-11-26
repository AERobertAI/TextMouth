import Foundation

// MARK: - The Sync Folder (FR43, section 3)

/// The TextMouth Sync folder as the engine sees it: its layout, its
/// `store.json`, and the device folders. Every read and write goes through
/// the `SyncFolderAccess`, which the Mac and the iPhone make differently.
///
/// Rule R4: `store.json` is made once and never replaced, and only
/// `device.json` is ever written over; everything else is written once.
struct SyncFolder: Sendable {
    /// The folder's URL, valid inside `SyncFolderAccess.withFolder`.
    let root: URL
    /// How the folder is reached.
    let access: any SyncFolderAccess

    /// `store.json`.
    var storeURL: URL { root.appendingPathComponent(SyncNames.storeFile) }
    /// `Devices/`.
    var devicesFolder: URL { root.appendingPathComponent(SyncNames.devicesFolder, isDirectory: true) }
    /// `Books/`.
    var booksFolder: URL { root.appendingPathComponent(SyncNames.booksFolder, isDirectory: true) }

    /// `Devices/<id>/`.
    func deviceFolder(_ deviceID: String) -> URL {
        devicesFolder.appendingPathComponent(deviceID, isDirectory: true)
    }

    /// `Books/<book id>/`.
    func bookFolder(_ bookID: UUID) -> URL {
        booksFolder.appendingPathComponent(SyncNames.id(bookID), isDirectory: true)
    }

    // MARK: Making a folder

    /// Makes the folder `TextMouth Sync` in `parent`, and `store.json` in it,
    /// and returns the folder. Refuses a parent that already holds a folder
    /// of that name (`.exists`), so a second device is never made a second
    /// store; the person is told to Join instead.
    static func create(in parent: URL, creator: String, version: String, now: Date = Date()) throws -> (folder: URL, store: SyncStoreFile) {
        let folder = parent.appendingPathComponent(SyncNames.folderName, isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) { throw SyncProblem.exists }
        let store = SyncStoreFile(
            formatVersion: SyncFormats.currentVersion, storeID: UUID(), created: now,
            createdBy: creator, createdByVersion: version
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Written whole under a hidden name and moved in, which never goes over a file: only a folder just made gets a store file (R4).
        let staged = folder.appendingPathComponent(".partial-" + UUID().uuidString.lowercased())
        try SyncFormats.encode(store).write(to: staged)
        try FileManager.default.moveItem(at: staged, to: folder.appendingPathComponent(SyncNames.storeFile))
        return (folder, store)
    }

    // MARK: Reading the store

    /// The folder's `store.json`: `.notASyncFolder` when it is missing or
    /// doesn't decode, `.laterVersion` when a later TextMouth made it.
    func readStore(within limit: Duration) async throws -> SyncStoreFile {
        let data: Data
        do {
            data = try await access.read(storeURL, within: limit)
        } catch let problem as SyncProblem {
            if case .notDownloaded = problem { throw problem }
            if problem == .offline { throw problem }
            throw SyncProblem.notASyncFolder
        } catch {
            throw SyncProblem.notASyncFolder
        }
        // A later TextMouth's file is told from a damaged one by core's reader.
        do {
            return try SyncFormats.decodeStoreFile(data)
        } catch SyncProblem.laterVersion {
            throw SyncProblem.laterVersion
        } catch {
            throw SyncProblem.notASyncFolder
        }
    }

    /// Reads `store.json`, and for a device that joined before checks it names `expected`.
    func readStore(expecting expected: UUID?, within limit: Duration) async throws -> SyncStoreFile {
        let store = try await readStore(within: limit)
        if let expected, store.storeID != expected { throw SyncProblem.anotherStore }
        return store
    }

    /// Waits for `store.json` to arrive from iCloud Drive, trying again
    /// every `interval` until `timeout` has passed (Join waits 60 seconds
    /// and never makes one). `sleep` is the clock, so a test passes its own.
    func waitForStore(
        timeout: Duration = .seconds(60), interval: Duration = .seconds(2),
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> SyncStoreFile {
        var waited = Duration.zero
        while true {
            do {
                return try await readStore(within: interval)
            } catch let problem as SyncProblem {
                // Only a file that hasn't arrived is waited for; anything else is the answer.
                let arriving: Bool
                switch problem {
                case .notASyncFolder, .notDownloaded: arriving = true
                default: arriving = false
                }
                if !arriving || waited >= timeout { throw problem }
            }
            try await sleep(interval)
            waited += interval
        }
    }

    // MARK: The devices

    /// Writes this device's `device.json`, or the new version of it; the
    /// access makes the device's folder, as `write` and `copyIn` make the
    /// folder of any file they put.
    func publishDevice(_ file: SyncDeviceFile) async throws {
        try await access.writeOffActor(try SyncFormats.encode(file), to: deviceFolder(file.deviceID).appendingPathComponent(SyncNames.deviceFile), replacing: true)
    }

    /// The IDs of the devices that have a folder here, in order.
    func deviceIDs() throws -> [String] {
        try access.list(devicesFolder).map(\.name).filter { !$0.hasPrefix(".") }.sorted()
    }
}
