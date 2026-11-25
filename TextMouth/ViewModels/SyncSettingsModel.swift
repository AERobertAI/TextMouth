import Foundation

// SyncSettingsModel.swift: what the Sync section of the settings says and
// does (FR43, sections 1, 7, and 10 of the build plan). The status line, the
// refusals of a folder chosen to sync through, and the commands are here,
// away from the view, so tests pin each word; the Mac's section
// (`SyncSettingsSection`) and the iPhone's settings both show them.

// MARK: - The Status Line

/// The sentence the Sync section's status line speaks: the first state that
/// holds, from section 7 of the plan, then the lines that follow it.
enum SyncStatusLine {
    /// The status line's sentence for `status`.
    /// - Parameters:
    ///   - status: What the sync reports.
    ///   - isPhone: Whether this device is an iPhone, which says "this iPhone".
    ///   - time: How a date is written as a time of day, the system's by default.
    static func sentence(
        for status: SyncStatus,
        isPhone: Bool,
        time: (Date) -> String = SyncStatusLine.systemTime
    ) -> String {
        let device = SyncWording.thisDevice(isPhone: isPhone)
        guard status.isOn else { return SyncWording.statusOff }
        if status.isSyncing { return SyncWording.statusSyncing }
        if status.isOffline {
            return SyncWording.statusOffline(changes: status.pendingChanges, device: device)
        }
        switch status.problem {
        case .folderMissing?:
            return SyncWording.statusFolderMissing(device: device)
        case .outOfSpace?:
            return SyncWording.statusOutOfSpace(
                changes: status.pendingChanges,
                books: max((status.booksToBackUp ?? 0) - (status.booksBackedUp ?? 0), 0),
                device: device
            )
        case .laterVersion?:
            return SyncWording.statusLaterVersion
        default:
            break
        }
        if status.pendingChanges > 0 { return SyncWording.statusUploading(changes: status.pendingChanges) }
        if case .notDownloaded? = status.problem { return SyncWording.statusNotDownloaded }
        return status.lastSynced.map { SyncWording.statusUpToDate(at: time($0)) } ?? SyncWording.statusSyncing
    }

    /// The lines after the sentence: when each other device was last heard
    /// from, newest first, then how far the backup of books has got.
    static func details(for status: SyncStatus, time: (Date) -> String = SyncStatusLine.systemTime) -> [String] {
        var lines = status.lastHeard
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .map { SyncWording.lastHeard(from: $0.key, at: time($0.value)) }
        if let done = status.booksBackedUp, let total = status.booksToBackUp, done < total {
            lines.append(SyncWording.backingUp(done: done, total: total))
        }
        return lines
    }

    /// A date as a time of day, as the system writes one: "9:41 AM".
    static func systemTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

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
    /// The command Set Up Sync gives the sync.
    private let setUpSync: (URL) async throws -> Void
    /// The command Join Sync Folder gives the sync.
    private let joinSync: (URL) async throws -> Void
    /// The command Stop Syncing gives the sync.
    private let stopSync: () -> Void
    /// The command Sync Now gives the sync.
    private let syncNowCommand: () -> Void

    /// The name of the folder Set Up Sync makes in the folder chosen.
    static let folderName = "TextMouth Sync" // l10n: no (the folder's name; the words say it is not translated)

    /// A model over the app's sync and library, or over stand-ins in tests.
    init(
        libraryLocation: @escaping () -> StorageLocation = { CloudServices.itemStatus.location(of: TextMouthPaths.root) },
        locationOf: @escaping (URL) -> StorageLocation = { CloudServices.itemStatus.location(of: $0) },
        exists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        setUp: @escaping (URL) async throws -> Void = { try await SyncCenter.shared.setUp(in: $0) },
        join: @escaping (URL) async throws -> Void = { try await SyncCenter.shared.join($0) },
        stop: @escaping () -> Void = { SyncCenter.shared.stop() },
        syncNow: @escaping () -> Void = { SyncCenter.shared.syncNow() }
    ) {
        self.libraryLocation = libraryLocation
        self.locationOf = locationOf
        self.exists = exists
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
        if libraryLocation() != .local { return SyncWording.libraryNotLocal }
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
        return await run { try await self.joinSync(folder) }
    }

    /// Stop Syncing, after the person has confirmed: the sync forgets the
    /// folder, and nothing is deleted.
    func stop() {
        message = nil
        stopSync()
    }

    /// Sync Now; the sync announces "Syncing." and what came of it.
    func syncNow() {
        message = nil
        syncNowCommand()
    }

    // MARK: Helpers

    /// Says `sentence` as the section's message, announced, and returns false.
    private func refuse(_ sentence: String) -> Bool {
        message = sentence
        VoiceOverAnnouncer.announce(sentence)
        return false
    }

    /// Runs a command of the sync, clearing the message first, and turns
    /// what it throws into one of `SyncWording`'s sentences.
    private func run(_ command: () async throws -> Void) async -> Bool {
        message = nil
        do {
            try await command()
            return true
        } catch let problem as SyncProblem {
            return refuse(Self.sentence(for: problem, isPhone: false))
        } catch {
            return refuse(SyncWording.notASyncFolder)
        }
    }

    /// The sentence that tells why a setting up or joining failed, on a Mac or an iPhone.
    static func sentence(for problem: SyncProblem, isPhone: Bool) -> String {
        switch problem {
        case .exists: return SyncWording.folderAlreadyThere
        case .anotherStore: return SyncWording.anotherStore
        case .laterVersion: return SyncWording.statusLaterVersion
        case .notDownloaded: return SyncWording.waitingForFiles
        case .folderMissing, .offline: return SyncWording.statusFolderMissing(device: SyncWording.thisDevice(isPhone: isPhone))
        case .notASyncFolder, .damaged, .outOfSpace: return SyncWording.notASyncFolder
        }
    }
}
