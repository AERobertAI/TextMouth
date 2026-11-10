#if os(macOS)
import AppKit
import SystemConfiguration
#else
import UIKit
#endif

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
///
/// The disk work (judging where the data directory lives, writing this
/// Mac's file, reading and tidying the Sessions folder, and removing this
/// Mac's file) runs off the main actor, on the lease's own serial queue, in
/// the order it was asked for: on a Mac whose Sessions folder has not synced
/// down yet, the first write or read can wait on the network, which the main
/// thread never does. What a refresh finds is published on the main actor:
/// where this Mac's file is, and the warning.
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
    nonisolated static let folderName = "Sessions"
    /// How recently another Mac must have been active to count as open.
    nonisolated static let activeWindow: TimeInterval = 3 * 60
    /// How long a lease may go untouched before it is removed.
    nonisolated static let staleAge: TimeInterval = 30 * 24 * 60 * 60
    /// How long quitting waits for this Mac's file to be removed, behind
    /// any write of it still under way, before it goes on without: a file
    /// left then ages out, as one left by a Mac that crashed does.
    static let removalWait: DispatchTimeInterval = .seconds(2)

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
    /// The cloud services' file-level provider in use, asked on the main
    /// actor at each refresh. The refresh's disk work asks it, off the main
    /// actor, whether the data directory can be opened by another Mac: it is
    /// in a cloud location or on another volume.
    private let itemStatus: @MainActor () -> any CloudItemStatusProviding
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
    /// The refresh under way, if any; nil once it is done. Refreshes never
    /// overlap.
    private var refreshUnderWay: Task<Void, Never>?
    /// The data directory the refresh under way writes this Mac's file in,
    /// so that `end()` removes the file from there too.
    private var refreshingRoot: URL?
    /// How many times the lease has ended (`end()`): a refresh asked for
    /// before an end publishes nothing, and writes nothing if it has not
    /// begun.
    private var endedSessions = 0
    /// The lease's disk work, one piece at a time, in the order asked for,
    /// so that the removal of this Mac's file at quit follows any write of
    /// it still under way.
    private let diskQueue = DispatchQueue(label: "com.textmouth.session-lease", qos: .utility)

    /// A lease. The app's uses its preferences, the system's clock and
    /// computer name, the data directory in use, the cloud services'
    /// reading of where it lives, and an alert; tests pass their own.
    init(
        preferences: UserDefaults = TextMouthRuntime.current.preferences,
        clock: @escaping @MainActor () -> Date = { Date() },
        refreshInterval: TimeInterval = 60,
        rootProvider: @escaping @MainActor () -> URL = { TextMouthPaths.root },
        itemStatus: @escaping @MainActor () -> any CloudItemStatusProviding = { CloudServices.itemStatus },
        computerName: @escaping @MainActor () -> String = { LibrarySessionLease.systemComputerName() },
        appVersion: String = BuildIdentity.current.version,
        warn: @escaping @MainActor (OtherMac, @escaping Answer) -> Void = { other, answer in
            LibrarySessionLease.presentWarning(about: other, answer: answer)
        },
        // The Mac terminates the app. An iPhone app never ends itself (the
        // system decides), so on iOS quitting does nothing.
        quit: @escaping @MainActor () -> Void = {
            #if os(macOS)
            QuitRequest.ask()
            #endif
        }
    ) {
        self.preferences = preferences
        self.clock = clock
        self.refreshInterval = refreshInterval
        self.rootProvider = rootProvider
        self.itemStatus = itemStatus
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
    /// every `refreshInterval` from then on (`refresh()`).
    func begin() {
        requestRefresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshOnSchedule() }
        }
    }

    /// Stops refreshing, as when the library is lost: the file stays, since
    /// its folder may be gone, and ages out unless `begin()` runs again.
    func pause() {
        timer?.invalidate()
        timer = nil
    }

    /// Stops refreshing and removes this Mac's file, as at quit: from the
    /// data directory it was written in, and from the one a refresh still
    /// under way writes it in, after that write, on the lease's queue. A
    /// refresh still under way then publishes nothing, and one asked for and
    /// not yet begun does nothing.
    ///
    /// The main thread waits for the removal, so that it is done before
    /// TextMouth quits, but at most `removalWait`: a write of the file that
    /// waits on the network holds the removal back, and the file left then
    /// ages out.
    func end() {
        pause()
        endedSessions += 1
        let roots = [heldRoot, refreshingRoot].compactMap { $0 }
        heldRoot = nil
        guard !roots.isEmpty else { return }
        let macID = macID
        let removed = DispatchSemaphore(value: 0)
        diskQueue.async {
            for root in roots {
                Self.removeFile(of: macID, in: root)
            }
            removed.signal()
        }
        if removed.wait(timeout: .now() + Self.removalWait) == .timedOut {
            DiagnosticLog.event(
                .storage,
                "LIBRARY_SESSION: this Mac's lease was not removed in time, behind disk work still under way; it ages out"
            )
        }
    }

    /// Refreshes the lease, and returns once the refresh is done: writes
    /// this Mac's file in the data directory in use, removes leases
    /// untouched for 30 days, and warns, once a session, about another Mac
    /// active in the last three minutes. After a move of the data directory,
    /// the file left in the old one is removed; in a library only this Mac
    /// can open, no file is kept.
    ///
    /// The disk work runs off the main actor, on the lease's queue, and what
    /// it finds is published here, on the main actor (`refreshOnce()`).
    /// Refreshes never overlap: one asked for while another is under way
    /// waits for it, since that one may have read the data directory before
    /// a change the caller made, and then refreshes.
    func refresh() async {
        await refresh(askedInSession: endedSessions)
    }

    /// Asks for a refresh without waiting for it, as `begin()` and the
    /// refresh timer do. Asked for now: should the lease end before the
    /// refresh begins, the refresh does nothing.
    private func requestRefresh() {
        let session = endedSessions
        Task { [weak self] in await self?.refresh(askedInSession: session) }
    }

    /// The refresh timer's tick: a refresh, unless one is under way still,
    /// as when its disk work waits on the network, so ticks never pile up
    /// behind it.
    private func refreshOnSchedule() {
        guard refreshUnderWay == nil else { return }
        requestRefresh()
    }

    /// A refresh asked for while the lease had ended `session` times: it
    /// waits for any refresh under way, then refreshes, unless the lease has
    /// ended since it was asked for.
    private func refresh(askedInSession session: Int) async {
        while let underWay = refreshUnderWay {
            await underWay.value
        }
        guard session == endedSessions else { return }
        // Nothing runs on the main actor between making the task and
        // keeping it, so the task cannot clear it first.
        let task = Task { [weak self] in
            await self?.refreshOnce()
            self?.refreshUnderWay = nil
        }
        refreshUnderWay = task
        await task.value
    }

    /// One refresh: what the disk work needs is gathered here, on the main
    /// actor; the work runs on the lease's queue (`refreshFiles(_:)`); and
    /// what it found is published here once it is done, unless the lease
    /// ended meanwhile.
    private func refreshOnce() async {
        let session = endedSessions
        let request = RefreshRequest(
            root: rootProvider(),
            previousRoot: heldRoot,
            macID: macID,
            record: Record(computerName: computerName(), lastActive: clock(), appVersion: appVersion),
            itemStatus: itemStatus()
        )
        refreshingRoot = request.root
        defer { refreshingRoot = nil }
        let found = await OffMainWork.run(on: diskQueue) { Self.refreshFiles(request) }
        guard session == endedSessions else { return }
        heldRoot = found.heldRoot
        warnOnce(about: found.otherMacs)
    }

    /// Warns about the Mac among `others` active most recently, once a
    /// session; Quit TextMouth in the warning quits.
    private func warnOnce(about others: [OtherMac]) {
        guard !hasWarned, let newest = others.min(by: { $0.minutesAgo < $1.minutesAgo }) else { return }
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

    // MARK: Files

    /// What one refresh asks of the disk, gathered on the main actor.
    private struct RefreshRequest: Sendable {
        /// The data directory in use.
        let root: URL
        /// The data directory this Mac's file was last written in, if any.
        let previousRoot: URL?
        /// This Mac's ID, which names its file.
        let macID: String
        /// This Mac's record, as it is written now.
        let record: Record
        /// The cloud services' file-level provider, which judges where the
        /// data directory lives.
        let itemStatus: any CloudItemStatusProviding
    }

    /// What one refresh found on the disk, published on the main actor.
    private struct RefreshResult: Sendable {
        /// The data directory holding this Mac's file now, if any.
        let heldRoot: URL?
        /// The other Macs active in the last three minutes.
        let otherMacs: [OtherMac]
    }

    /// The disk work of one refresh, on the lease's queue: removes this
    /// Mac's file from a data directory it no longer uses; in a data
    /// directory another Mac can open, writes this Mac's file and finds the
    /// other Macs active there, removing the leases untouched for 30 days;
    /// and in one only this Mac can open, keeps no file.
    nonisolated private static func refreshFiles(_ request: RefreshRequest) -> RefreshResult {
        var heldRoot = request.previousRoot
        if let previous = heldRoot, previous.standardizedFileURL.path != request.root.standardizedFileURL.path {
            removeFile(of: request.macID, in: previous)
            heldRoot = nil
        }
        guard request.itemStatus.location(of: request.root) != .local else {
            if let heldRoot {
                removeFile(of: request.macID, in: heldRoot)
            }
            return RefreshResult(heldRoot: nil, otherMacs: [])
        }
        if writeFile(request.record, of: request.macID, in: request.root) {
            heldRoot = request.root
        }
        let others = otherMacs(in: request.root, besides: request.macID, at: request.record.lastActive)
        return RefreshResult(heldRoot: heldRoot, otherMacs: others)
    }

    /// The Sessions folder of the data directory at `root`.
    nonisolated private static func folder(in root: URL) -> URL {
        root.appendingPathComponent(folderName, isDirectory: true)
    }

    /// The file of the Mac whose ID is `macID` in the data directory at
    /// `root`.
    nonisolated private static func file(of macID: String, in root: URL) -> URL {
        folder(in: root).appendingPathComponent("\(macID).json", isDirectory: false)
    }

    /// Writes `record` as the file of the Mac whose ID is `macID`, making the
    /// Sessions folder inside the existing data directory at `root` first;
    /// returns whether it was written. A failure is logged and tried again
    /// at the next refresh.
    nonisolated private static func writeFile(_ record: Record, of macID: String, in root: URL) -> Bool {
        do {
            do {
                try FileManager.default.createDirectory(at: folder(in: root), withIntermediateDirectories: false)
            } catch CocoaError.fileWriteFileExists {
                // The folder is there already.
            }
            try encoder.encode(record).write(to: file(of: macID, in: root), options: .atomic)
            return true
        } catch {
            DiagnosticLog.event(.storage, "LIBRARY_SESSION: could not write this Mac's lease: \(error.localizedDescription)")
            return false
        }
    }

    /// Removes the file of the Mac whose ID is `macID` from the data
    /// directory at `root`, if it is there.
    nonisolated private static func removeFile(of macID: String, in root: URL) {
        try? FileManager.default.removeItem(at: file(of: macID, in: root))
    }

    /// The other Macs active in the library at `root` in the last three
    /// minutes at `now`, besides this Mac, whose ID is `macID`, removing the
    /// leases untouched for 30 days.
    ///
    /// A sync service's conflict copy of this Mac's own lease, made when the
    /// file this Mac writes meets an older version on its way back, keeps
    /// the lease's name before its suffix ("<ID> 2.json", "<ID> (1).json"),
    /// so it is told apart by that name: it never counts as another Mac,
    /// and ages out as any lease does.
    nonisolated private static func otherMacs(in root: URL, besides macID: String, at now: Date) -> [OtherMac] {
        let ownName = file(of: macID, in: root).lastPathComponent
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
                } else if age <= Self.activeWindow, !name.hasPrefix(macID) {
                    active.append(OtherMac(computerName: lease.computerName, minutesAgo: max(0, Int(age / 60))))
                }
            }
            return active
        }
    }

    /// Another Mac's lease at `file`: its record when it can be read here,
    /// or, for a file only in the cloud, its modification date and no name.
    nonisolated private static func lease(at file: URL) -> (computerName: String, lastActive: Date)? {
        if let data = try? Data(contentsOf: file), let record = try? decoder.decode(Record.self, from: data) {
            return (record.computerName, record.lastActive)
        }
        guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
            return nil
        }
        return (anotherMac, modified)
    }

    /// What a Mac whose lease can't be read yet is called.
    nonisolated static let anotherMac = "another Mac"

    /// Writes a record as people can read it.
    nonisolated private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    /// Reads a record as `encoder` writes it.
    nonisolated private static var decoder: JSONDecoder {
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
            : "\(CountWording.minutes(other.minutesAgo)) ago"
        return "TextMouth is also open on “\(other.computerName)” (active \(when)). "
            + "Using one library on two Macs at the same time can lose reading positions and changes."
    }

    #if os(macOS)
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
    #else
    /// Phase 0 on iOS shows no alert: it answers Continue, the warning's
    /// default, so the library stays usable. A phase 1 alert replaces this.
    static func presentWarning(about other: OtherMac, answer: @escaping Answer) {
        answer(.continueHere)
    }
    #endif

    /// This computer's name, as Sharing settings give it.
    static func systemComputerName() -> String {
        #if os(macOS)
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "this Mac"
        #else
        UIDevice.current.name
        #endif
    }
}
