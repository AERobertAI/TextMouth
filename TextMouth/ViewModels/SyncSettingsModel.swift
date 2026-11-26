import Foundation

// SyncSettingsModel.swift: what the Sync section of the settings says and
// does (FR43, sections 1, 7, and 10 of the build plan). The refusals of a folder chosen to sync through, and the commands are here,
// away from the view, so tests pin each word; the Mac's section
// (`SyncSettingsSection`) and the iPhone's settings both show them.

// MARK: - The Model

/// The Sync section's commands and the words they end in. Set Up Sync and
/// Join Sync Folder check what was chosen first (R6): the library is kept on
/// this device, and the folder is in iCloud Drive; each refusal is one of
/// `SyncWording`'s sentences, and nothing is made or read before it.
@MainActor
final class SyncSettingsModel: ObservableObject {
    /// What the last command said, for the section's message line: a refusal
    /// or what went wrong, in `SyncWording`'s words; nil when none.
    @Published private(set) var message: String?

    /// Where the library's data directory lives now.
    private let libraryLocation: () -> StorageLocation
    /// Where a chosen folder lives.
    private let locationOf: (URL) -> StorageLocation
    /// Whether anything is at a path: Set Up Sync's check for a folder already made.
    private let exists: (URL) -> Bool
    /// The names in a folder, listed without downloading anything.
    private let listFolder: (URL) -> [String]
    /// The command Set Up Sync gives the sync.
    private let setUpSync: (URL) async throws -> Void
    /// The command Join Sync Folder gives the sync.
    private let joinSync: (URL) async throws -> Void
    /// The command Stop Syncing gives the sync.
    private let stopSync: () -> Void
    /// The command Sync Now gives the sync.
    private let syncNowCommand: () -> Void
    /// Whether the words are the iPhone's ("this iPhone"); a Mac's by default there.
    private let isPhone: Bool

    /// The name of the folder Set Up Sync makes in the folder chosen.
    static let folderName = "TextMouth Sync" // l10n: no (the folder's name; the words say it is not translated)
    /// The file that names a sync folder's store, and iCloud Drive's stand-in for it before it has downloaded.
    static let storeFileName = "store.json" // l10n: no (a file name)
    static let storeStandInName = ".store.json.icloud" // l10n: no (a file name)

    /// A model over the app's sync and library, or over stand-ins in tests.
    init(
        libraryLocation: @escaping () -> StorageLocation = { CloudServices.itemStatus.location(of: TextMouthPaths.root) },
        locationOf: @escaping (URL) -> StorageLocation = { CloudServices.itemStatus.location(of: $0) },
        exists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        listFolder: @escaping (URL) -> [String] = { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? [] },
        setUp: @escaping (URL) async throws -> Void = { try await SyncCenter.shared.setUp(in: $0) },
        join: @escaping (URL) async throws -> Void = { try await SyncCenter.shared.join($0) },
        stop: @escaping () -> Void = { SyncCenter.shared.stop() },
        syncNow: @escaping () -> Void = { SyncCenter.shared.syncNow() },
        isPhone: Bool = ThisDevice.isPhone
    ) {
        self.isPhone = isPhone
        self.libraryLocation = libraryLocation
        self.locationOf = locationOf
        self.exists = exists
        self.listFolder = listFolder
        self.setUpSync = setUp
        self.joinSync = join
        self.stopSync = stop
        self.syncNowCommand = syncNow
    }

    // MARK: Refusals

    /// Why syncing cannot use `folder`, or nil when it can: the library must
    /// be kept on this device (not in a cloud folder or on another volume),
    /// and the folder must be in iCloud Drive.
    func refusal(forChosen folder: URL) -> String? {
        if libraryLocation() != .local { return SyncWording.libraryNotLocal(isPhone: isPhone) }
        if locationOf(folder) != .cloud(.iCloudDrive) { return SyncWording.notInICloudDrive }
        return nil
    }

    // MARK: Commands

    /// Set Up Sync: makes a TextMouth Sync folder in `parent`, a folder the
    /// person chose in iCloud Drive, and joins it. Refused, with nothing
    /// made, for a library not kept here, a folder outside iCloud Drive, and
    /// a TextMouth Sync folder already there (the person joins that).
    /// - Returns: Whether sync is set up.
    @discardableResult
    func setUp(in parent: URL) async -> Bool {
        if let refusal = refusal(forChosen: parent) { return refuse(refusal) }
        if exists(parent.appendingPathComponent(Self.folderName, isDirectory: true)) {
            return refuse(SyncWording.folderAlreadyThere)
        }
        return await run { try await self.setUpSync(parent) }
    }

    /// Join Sync Folder: uses `folder`, a TextMouth Sync folder another
    /// device made. Refused, with nothing read, for a library not kept here
    /// and a folder outside iCloud Drive.
    /// - Returns: Whether the folder is joined.
    @discardableResult
    func join(_ folder: URL) async -> Bool {
        if let refusal = refusal(forChosen: folder) { return refuse(refusal) }
        // A folder that is no sync folder is refused at once, not after the
        // minute joining waits for `store.json`: it is named TextMouth Sync,
        // or holds `store.json` (or iCloud Drive's stand-in for it).
        let names = listFolder(folder)
        let hasStore = names.contains(Self.storeFileName)
        guard hasStore || names.contains(Self.storeStandInName) || folder.lastPathComponent == Self.folderName else {
            return refuse(SyncWording.notASyncFolder)
        }
        // The wait for a `store.json` that has not arrived is said as it begins.
        if !hasStore { say(SyncWording.waitingForFiles) }
        return await run { try await self.joinSync(folder) }
    }

    /// Stop Syncing, after the person has confirmed: the sync forgets the
    /// folder, and nothing is deleted.
    func stop() {
        message = nil
        stopSync()
        VoiceOverAnnouncer.announce(SyncWording.statusOff)
    }

    /// Sync Now; the sync announces "Syncing." and what came of it.
    func syncNow() {
        message = nil
        syncNowCommand()
    }

    // MARK: Helpers

    /// Says `sentence` as the section's message, announced.
    func say(_ sentence: String) {
        message = sentence
        VoiceOverAnnouncer.announce(sentence)
    }

    /// Says `sentence`, and returns false.
    private func refuse(_ sentence: String) -> Bool {
        say(sentence)
        return false
    }

    /// Runs a command of the sync, clearing the message first, and turns
    /// what it throws into one of `SyncWording`'s sentences.
    private func run(_ command: () async throws -> Void) async -> Bool {
        let waiting = message == SyncWording.waitingForFiles ? message : nil
        message = waiting
        do {
            try await command()
            message = nil
            return true
        } catch let problem as SyncProblem {
            return refuse(Self.sentence(for: problem, isPhone: isPhone))
        } catch {
            return refuse(Self.sentence(for: error, isPhone: isPhone))
        }
    }

    /// The sentence for any error a setting up or joining ended in: a `SyncProblem`'s own, and for another error the
    /// sentence that says the folder is not a usable sync folder, never the system's text.
    static func sentence(for error: Error, isPhone: Bool) -> String {
        guard let problem = error as? SyncProblem else { return SyncWording.notASyncFolder }
        return sentence(for: problem, isPhone: isPhone)
    }

    /// The sentence that tells why a setting up or joining failed, on a Mac or an iPhone.
    static func sentence(for problem: SyncProblem, isPhone: Bool) -> String {
        switch problem {
        case .exists: return SyncWording.folderAlreadyThere
        case .anotherStore: return SyncWording.anotherStore
        case .laterVersion: return SyncWording.statusLaterVersion
        case .notDownloaded: return SyncWording.waitingForFiles
        case .folderMissing, .offline: return SyncWording.statusFolderMissing(device: SyncWording.thisDevice(isPhone: isPhone))
        case .notInICloudDrive: return SyncWording.notInICloudDrive
        case .libraryNotLocal: return SyncWording.libraryNotLocal(isPhone: isPhone)
        case .outOfSpace: return SyncWording.iCloudDriveFull
        case .notASyncFolder, .damaged: return SyncWording.notASyncFolder
        }
    }
}
