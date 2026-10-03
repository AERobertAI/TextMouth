import AppKit
import SystemConfiguration

/// This Mac's note, in a library another Mac can open too, that TextMouth
/// has the library open (FR02: two Macs, a warning and never a lock).
///
/// When the data directory is in a cloud location or on another volume
/// (`CloudServices.itemStatus.location(of:)`), TextMouth keeps one small file
/// for this Mac in the data directory: `Sessions/<this Mac's ID>.json`, with
/// the computer's name, when TextMouth was last active, and the app version.
/// It is written when the library opens, refreshed every minute while it is
/// open, and removed at quit. A library on the startup disk gets none.
///
/// When the file is written, at launch and at each refresh, another Mac's
/// file updated in the last three minutes means that Mac has the library
/// open too, and TextMouth warns, once a session, that using one library on
/// two Macs at the same time can lose reading positions and changes, with
/// Continue and Quit TextMouth. Files untouched for 30 days, left by Macs
/// that quit without removing theirs, are removed.
///
/// Everything here reads metadata, and only the small files of the Sessions
/// folder, inside `DatalessFiles.withoutDownloading`: a file only in the
/// cloud is judged by its modification date, and never waited for.
@MainActor
final class LibrarySessionLease {
    /// The lease the app holds.
    static let shared = LibrarySessionLease()

    /// One Mac's file in the Sessions folder.
    struct Record: Codable, Equatable, Sendable {
        /// The computer's name, as Sharing settings give it.
        var computerName: String
        /// When TextMouth was last active on that Mac.
        var lastActive: Date
        /// The version of TextMouth running there.
        var appVersion: String
    }

    /// Another Mac found with the library open.
    struct OtherMac: Equatable, Sendable {
        /// Its name, or "another Mac" when its file can't be read yet.
        let computerName: String
        /// Whole minutes since it was last active; never below zero, since
        /// another Mac's clock may run ahead.
        let minutesAgo: Int
    }

    /// How the user answered the warning.
    enum Choice: Equatable, Sendable {
        /// Keep using the library here.
        case continueHere
        /// Quit TextMouth on this Mac.
        case quit
    }

    /// The name of the folder of leases in the data directory.
    static let folderName = "Sessions"
    /// How recently another Mac must have been active to count as open.
    static let activeWindow: TimeInterval = 3 * 60
    /// How long a lease may go untouched before it is removed.
    static let staleAge: TimeInterval = 30 * 24 * 60 * 60

    /// This Mac's ID, kept in the preferences so it stays the same.
    nonisolated static let macIDPreference = StoredPreference<String?>(
        key: "textMouthSessionMacID",
        read: { store, key in store.string(forKey: key) },
        write: { value, store, key in
            if let value {
                store.set(value, forKey: key)
            } else {
                store.removeObject(forKey: key)
            }
        }
    )

    // MARK: Dependencies

    /// Answers the warning with the user's choice.
    typealias Answer = @MainActor @Sendable (Choice) -> Void

    /// The store holding this Mac's ID.
    private let preferences: UserDefaults
    /// The time now.
    private let clock: @MainActor () -> Date
    /// Seconds between refreshes while the library is open.
    let refreshInterval: TimeInterval
    /// The data directory in use now.
    private let rootProvider: @MainActor () -> URL
    /// Whether the data directory at a path can be opened by another Mac:
    /// it is in a cloud location or on another volume.
    private let isShared: @MainActor (URL) -> Bool
    /// This computer's name.
    private let computerName: @MainActor () -> String
    /// The version of TextMouth running here.
    private let appVersion: String
    /// Shows the warning about `OtherMac`, then answers with the choice.
    private let warn: @MainActor (OtherMac, @escaping Answer) -> Void
    /// Quits TextMouth.
    private let quit: @MainActor () -> Void

    // MARK: State

    /// The data directory this Mac's file was last written in, while it has
    /// one there.
    private(set) var heldRoot: URL?
    /// Whether another Mac was warned about this session.
    private(set) var hasWarned = false
    /// Refreshes the lease every `refreshInterval` while the library is open.
    private var timer: Timer?

    /// A lease. The app's uses its preferences, the system's clock and
    /// computer name, the data directory in use, the cloud services'
    /// reading of where it lives, and an alert; tests pass their own.
    init(
        preferences: UserDefaults = TextMouthRuntime.current.preferences,
        clock: @escaping @MainActor () -> Date = { Date() },
        refreshInterval: TimeInterval = 60,
        rootProvider: @escaping @MainActor () -> URL = { TextMouthPaths.root },
        isShared: @escaping @MainActor (URL) -> Bool = { CloudServices.itemStatus.location(of: $0) != .local },
        computerName: @escaping @MainActor () -> String = { LibrarySessionLease.systemComputerName() },
        appVersion: String = BuildIdentity.current.version,
        warn: @escaping @MainActor (OtherMac, @escaping Answer) -> Void = { other, answer in
            LibrarySessionLease.presentWarning(about: other, answer: answer)
        },
        quit: @escaping @MainActor () -> Void = { NSApplication.shared.terminate(nil) }
    ) {
        self.preferences = preferences
        self.clock = clock
        self.refreshInterval = refreshInterval
        self.rootProvider = rootProvider
        self.isShared = isShared
        self.computerName = computerName
        self.appVersion = appVersion
        self.warn = warn
        self.quit = quit
    }

    /// This Mac's ID, made and kept the first time it is needed.
    var macID: String {
        if let stored = Self.macIDPreference.read(from: preferences), UUID(uuidString: stored) != nil {
            return stored
        }
        let made = UUID().uuidString
        Self.macIDPreference.write(made, to: preferences)
        return made
    }

    // MARK: The Session

    /// Starts holding the lease as the library opens: refreshes it now, and
    /// every `refreshInterval` from then on.
    func begin() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Stops refreshing, as when the library is lost: the file stays, since
    /// its folder may be gone, and ages out unless `begin()` runs again.
    func pause() {
        timer?.invalidate()
        timer = nil
    }

    /// Stops refreshing and removes this Mac's file, as at quit.
    func end() {
        pause()
        if let heldRoot {
            removeOwnFile(in: heldRoot)
        }
        heldRoot = nil
    }

    /// Writes this Mac's file in the data directory in use, removes leases
    /// untouched for 30 days, and warns, once a session, about another Mac
    /// active in the last three minutes. After a move of the data directory,
    /// the file left in the old one is removed; in a library only this Mac
    /// can open, no file is kept.
    func refresh() {
        let root = rootProvider()
        if let heldRoot, heldRoot.standardizedFileURL.path != root.standardizedFileURL.path {
            removeOwnFile(in: heldRoot)
            self.heldRoot = nil
        }
        guard isShared(root) else {
            if let heldRoot {
                removeOwnFile(in: heldRoot)
                self.heldRoot = nil
            }
            return
        }
        let now = clock()
        if writeOwnFile(in: root, at: now) {
            heldRoot = root
        }
        let others = otherMacs(in: root, at: now)
        if !hasWarned, let newest = others.min(by: { $0.minutesAgo < $1.minutesAgo }) {
            hasWarned = true
            DiagnosticLog.event(
                .storage,
                "LIBRARY_SESSION: another Mac was active in the library \(newest.minutesAgo) minutes ago"
            )
            warn(newest) { [weak self] choice in
                if choice == .quit {
                    self?.quit()
                }
            }
        }
    }

    // MARK: Files

    /// The Sessions folder of the data directory at `root`.
    private static func folder(in root: URL) -> URL {
        root.appendingPathComponent(folderName, isDirectory: true)
    }

    /// This Mac's file in the data directory at `root`.
    private func ownFile(in root: URL) -> URL {
        Self.folder(in: root).appendingPathComponent("\(macID).json", isDirectory: false)
    }

    /// Writes this Mac's file, making the Sessions folder inside the
    /// existing data directory first; returns whether it was written. A
    /// failure is logged once and tried again at the next refresh.
    private func writeOwnFile(in root: URL, at now: Date) -> Bool {
        let record = Record(computerName: computerName(), lastActive: now, appVersion: appVersion)
        do {
            let folder = Self.folder(in: root)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            } catch CocoaError.fileWriteFileExists {
                // The folder is there already.
            }
            try Self.encoder.encode(record).write(to: ownFile(in: root), options: .atomic)
            return true
        } catch {
            DiagnosticLog.event(.storage, "LIBRARY_SESSION: could not write this Mac's lease: \(error.localizedDescription)")
            return false
        }
    }

    /// Removes this Mac's file from the data directory at `root`, if it is
    /// there.
    private func removeOwnFile(in root: URL) {
        try? FileManager.default.removeItem(at: ownFile(in: root))
    }

    /// The other Macs active in the library at `root` in the last three
    /// minutes at `now`, removing the leases untouched for 30 days.
    ///
    /// A sync service's conflict copy of this Mac's own lease, made when the
    /// file this Mac writes meets an older version on its way back, keeps
    /// the lease's name before its suffix ("<ID> 2.json", "<ID> (1).json"),
    /// so it is told apart by that name: it never counts as another Mac,
    /// and ages out as any lease does.
    private func otherMacs(in root: URL, at now: Date) -> [OtherMac] {
        let ownName = ownFile(in: root).lastPathComponent
        let ownID = macID
        return DatalessFiles.withoutDownloading {
            let folder = Self.folder(in: root)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            var active: [OtherMac] = []
            for name in names where name.hasSuffix(".json") && name != ownName {
                let file = folder.appendingPathComponent(name, isDirectory: false)
                guard let lease = Self.lease(at: file) else { continue }
                let age = now.timeIntervalSince(lease.lastActive)
                if age > Self.staleAge {
                    try? FileManager.default.removeItem(at: file)
                } else if age <= Self.activeWindow, !name.hasPrefix(ownID) {
                    active.append(OtherMac(computerName: lease.computerName, minutesAgo: max(0, Int(age / 60))))
                }
            }
            return active
        }
    }

    /// Another Mac's lease at `file`: its record when it can be read here,
    /// or, for a file only in the cloud, its modification date and no name.
    private static func lease(at file: URL) -> (computerName: String, lastActive: Date)? {
        if let data = try? Data(contentsOf: file), let record = try? decoder.decode(Record.self, from: data) {
            return (record.computerName, record.lastActive)
        }
        guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
            return nil
        }
        return (anotherMac, modified)
    }

    /// What a Mac whose lease can't be read yet is called.
    static let anotherMac = "another Mac"

    /// Writes a record as people can read it.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    /// Reads a record as `encoder` writes it.
    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: The Warning

    /// The warning's title.
    static let warningTitle = "TextMouth Is Open on Another Mac"
    /// The warning's button that keeps using the library here, the default.
    static let continueTitle = "Continue"
    /// The warning's button that quits.
    static let quitTitle = "Quit TextMouth"

    /// What the warning says about `other`.
    static func warningMessage(about other: OtherMac) -> String {
        let when = other.minutesAgo == 0
            ? "less than a minute ago"
            : "\(CountWording.phrase(other.minutesAgo, singular: "minute", plural: "minutes")) ago"
        return "TextMouth is also open on “\(other.computerName)” (active \(when)). "
            + "Using one library on two Macs at the same time can lose reading positions and changes."
    }

    /// Shows the warning as a sheet on the key Library window, or on its own
    /// when no window is key, and answers with the choice. Continue is the
    /// default button, on Return; VoiceOver reads the alert as it appears.
    static func presentWarning(about other: OtherMac, answer: @escaping Answer) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = warningTitle
        alert.informativeText = warningMessage(about: other)
        alert.addButton(withTitle: continueTitle)
        alert.addButton(withTitle: quitTitle)
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { answer(choice(after: response)) }
            }
        } else {
            answer(choice(after: alert.runModal()))
        }
    }

    /// The choice the warning's button `response` stands for.
    nonisolated static func choice(after response: NSApplication.ModalResponse) -> Choice {
        response == .alertSecondButtonReturn ? .quit : .continueHere
    }

    /// This computer's name, as Sharing settings give it.
    static func systemComputerName() -> String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "this Mac"
    }
}
