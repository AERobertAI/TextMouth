import Foundation

// PhoneSyncSettingsModel.swift: the decisions of the iPhone's Sync section
// (FR43, sync-iphone), in plain types the Mac's test host can run, as
// `PhoneSettingsModel` does for the rest of Settings: which controls the
// section holds in each state, what each says, what the status says, and what
// each step of setting up, joining, and stopping does. `PhoneSyncSettingsSection`,
// on iOS, only draws them. Every state is words, so VoiceOver and a braille
// display read all of it (rule R9 of research/CLOUD-SYNC-BUILD-PLAN-2026-11-25.md).

// MARK: - Which Device This Is

/// Which kind of device this build runs on, for the sentences that name it
/// ("this Mac", "this iPhone"). A test passes the kind it wants to a
/// function's `isPhone` instead, so both sentences are pinned on the Mac.
enum ThisDevice {
    /// Whether this build is the iPhone's.
    static let isPhone: Bool = {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }()
}

// MARK: - Wording the iPhone alone Needs

/// The lines of the Sync section that differ on the iPhone from the Mac's in
/// `SyncWording`: a sentence that names the other device, or this one.
enum PhoneSyncWording {
    /// The status when another device's changes haven't downloaded: the Mac's
    /// line names the iPhone, so the iPhone's names the Mac.
    static var statusNotDownloaded: String {
        // Translators: The Sync status on an iPhone when changes made on the Mac have not yet downloaded from iCloud Drive.
        InterfaceText.line("phoneSync.status.notDownloaded", "Some changes from your Mac haven't downloaded yet. TextMouth will try again.")
    }

    /// The question asked before syncing stops: the Mac's names "this Mac".
    static var stopQuestion: String {
        // Translators: The confirmation asked on an iPhone before syncing stops. Nothing is deleted from the iPhone or from iCloud Drive.
        InterfaceText.line("phoneSync.stopQuestion", "Stop syncing this library? Nothing is deleted, on this iPhone or in iCloud Drive.")
    }

    /// The alert's button that stops syncing, with no ellipsis: the question
    /// has been asked.
    static var stopButton: String {
        // Translators: The button of the confirmation that stops syncing on an iPhone. Title case.
        InterfaceText.line("phoneSync.stopButton", "Stop Syncing")
    }

    /// Announced after a person ends keeping a book on all devices.
    static func announceStoppedKeeping(title: String) -> String {
        // Translators: Said aloud after the person chooses Stop Keeping on All Devices. %@ is the book's title.
        InterfaceText.line("phoneSync.announce.stoppedKeeping", "Stopped keeping \(title) on all devices.")
    }

    /// The name of the other device in "Last heard from …": the iPhone hears
    /// from the Mac.
    static var otherDeviceName: String {
        // Translators: The name of the Mac, in the line "Last heard from Mac at 9:40 AM." shown on an iPhone.
        InterfaceText.line("phoneSync.otherDeviceName", "Mac")
    }
}

// MARK: - The Section's Controls

/// A control of the Sync section.
enum PhoneSyncControl: Hashable, Identifiable {
    case setUp
    case join
    case syncNow
    case stop

    var id: Self { self }

    /// What the control says, and what VoiceOver calls it.
    var title: String {
        switch self {
        case .setUp: return SyncWording.setUpTitle
        case .join: return SyncWording.joinTitle
        case .syncNow: return SyncWording.syncNowTitle
        case .stop: return SyncWording.stopTitle
        }
    }

    /// What the control does, as its VoiceOver hint; none for Sync Now and
    /// Stop Syncing, whose titles say it.
    var hint: String? {
        switch self {
        case .setUp: return SyncWording.setUpHint
        case .join: return SyncWording.joinHint
        case .syncNow, .stop: return nil
        }
    }
}

/// What the Sync section holds, and what its status says.
enum PhoneSyncSettingsModel {
    /// The controls to show, in order: with sync off, Set Up Sync and Join Sync
    /// Folder; with it on, Sync Now and Stop Syncing.
    static func controls(isOn: Bool) -> [PhoneSyncControl] {
        isOn ? [.syncNow, .stop] : [.setUp, .join]
    }

    /// Whether Sync Now is offered on the library's summary: only once sync is
    /// on (R1: nothing is added before a folder is chosen).
    static func offersSyncNowOnSummary(_ status: SyncStatus) -> Bool {
        status.isOn
    }

    // MARK: The Status Lines

    /// The status line, then the lines that follow it (who was last heard
    /// from, and the books' backup), as the section reads them. The first line
    /// is the first state that holds, in the plan's order (section 7).
    /// - Parameters:
    ///   - status: What `SyncCenter` reports.
    ///   - time: How a date is written as a time of day; the system's by
    ///     default, and a test's own.
    static func lines(for status: SyncStatus, time: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }) -> [String] {
        var lines = [headline(for: status, time: time)]
        guard status.isOn else { return lines }
        for (device, date) in status.lastHeard.sorted(by: { $0.key < $1.key }) {
            lines.append(SyncWording.lastHeard(from: heardDeviceName(device), at: time(date)))
        }
        if let toBackUp = status.booksToBackUp, let done = status.booksBackedUp, done < toBackUp {
            lines.append(SyncWording.backingUp(done: done, total: toBackUp))
        }
        return lines
    }

    /// The first state that holds. Only the Mac backs up books, so the books
    /// the phone counts as not uploaded are the Mac's backlog.
    static func headline(for status: SyncStatus, time: (Date) -> String) -> String {
        let device = SyncWording.thisDevice(isPhone: true)
        if !status.isOn { return SyncWording.statusOff }
        if status.isSyncing { return SyncWording.statusSyncing }
        if status.isOffline { return SyncWording.statusOffline(changes: status.pendingChanges, device: device) }
        switch status.problem {
        case .folderMissing?:
            return SyncWording.statusFolderMissing(device: device)
        case .outOfSpace?:
            let books = max(0, (status.booksToBackUp ?? 0) - (status.booksBackedUp ?? 0))
            return SyncWording.statusOutOfSpace(changes: status.pendingChanges, books: books, device: device)
        case .laterVersion?:
            return SyncWording.statusLaterVersion
        case .anotherStore?:
            return SyncWording.anotherStore
        case .notASyncFolder?:
            return SyncWording.notASyncFolder
        default:
            break
        }
        if status.pendingChanges > 0 { return SyncWording.statusUploading(changes: status.pendingChanges) }
        if case .notDownloaded? = status.problem { return PhoneSyncWording.statusNotDownloaded }
        if let last = status.lastSynced { return SyncWording.statusUpToDate(at: time(last)) }
        // On, with no sync finished yet: one is on its way.
        return SyncWording.statusSyncing
    }

    /// How a device is named in "Last heard from …": the one other kind of
    /// device a phone hears from is a Mac, whatever its own name.
    static func heardDeviceName(_ device: String) -> String {
        device.isEmpty ? PhoneSyncWording.otherDeviceName : device
    }

    // MARK: Refusals

    /// What a folder chosen outside iCloud Drive is told, or nil for one in it.
    static func refusal(forFolderInICloudDrive isInICloudDrive: Bool) -> String? {
        isInICloudDrive ? nil : SyncWording.notInICloudDrive
    }

    /// Whether the folder at `folder` is in iCloud Drive: by the path through
    /// `Mobile Documents`, or by a sync service managing it.
    static func isInICloudDrive(_ folder: URL) -> Bool {
        if UbiquitousItemStatusProvider.provider(forPath: folder) == .iCloudDrive { return true }
        return (try? folder.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
    }

    /// The words for a step that failed: a `SyncProblem` has its own, any other
    /// error says what the system said.
    static func message(for error: Error) -> String {
        guard let problem = error as? SyncProblem else { return error.localizedDescription }
        switch problem {
        case .offline, .notDownloaded: return SyncWording.waitingForFiles
        case .folderMissing: return SyncWording.statusFolderMissing(device: SyncWording.thisDevice(isPhone: true))
        case .notASyncFolder, .damaged: return SyncWording.notASyncFolder
        case .anotherStore: return SyncWording.anotherStore
        case .laterVersion: return SyncWording.statusLaterVersion
        case .outOfSpace: return SyncWording.statusOutOfSpace(changes: 0, books: 0, device: SyncWording.thisDevice(isPhone: true))
        case .exists: return SyncWording.folderAlreadyThere
        }
    }
}

// MARK: - What Each Step Does

/// What the section's folder picker is for.
enum PhoneSyncPick: Equatable {
    /// Choose the iCloud Drive folder to make TextMouth Sync in.
    case setUp
    /// Choose the TextMouth Sync folder another device made.
    case join
}

/// The Sync section's steps, which the view calls: choosing a folder, Sync
/// Now, and Stop Syncing. Each step says what happened through `announce`,
/// and a failure also through `alertMessage`, which the view shows in an
/// alert. The services are passed in, so a test runs every step with none of
/// the real ones (and never touches iCloud Drive).
@MainActor
final class PhoneSyncSettingsController: ObservableObject {
    /// What the steps use of the rest of the app.
    struct Services {
        /// Makes TextMouth Sync in the folder and joins (`SyncCenter.setUp(in:)`).
        var setUp: (URL) async throws -> Void
        /// Joins the sync folder (`SyncCenter.join(_:)`).
        var join: (URL) async throws -> Void
        /// Syncs now (`SyncCenter.syncNow()`).
        var syncNow: @MainActor () -> Void
        /// Stops syncing (`SyncCenter.stop()`).
        var stop: @MainActor () -> Void
        /// Whether a folder is in iCloud Drive.
        var isInICloudDrive: (URL) -> Bool
        /// Opens the security scope of a URL from the picker and returns what closes it.
        var openScope: (URL) -> () -> Void
        /// Speaks a line to VoiceOver.
        var announce: @MainActor (String) -> Void

        /// The app's own: `SyncCenter`, the path check, and VoiceOver.
        static var app: Services {
            Services(
                setUp: { try await SyncCenter.shared.setUp(in: $0) },
                join: { try await SyncCenter.shared.join($0) },
                syncNow: { SyncCenter.shared.syncNow() },
                stop: { SyncCenter.shared.stop() },
                isInICloudDrive: { PhoneSyncSettingsModel.isInICloudDrive($0) },
                openScope: { url in
                    let opened = url.startAccessingSecurityScopedResource()
                    return { if opened { url.stopAccessingSecurityScopedResource() } }
                },
                announce: { VoiceOverAnnouncer.announce($0) }
            )
        }
    }

    /// Whether a Set Up or Join is under way, so a second press does nothing.
    @Published private(set) var isWorking = false
    /// The words of the failure an alert shows, or nil for none.
    @Published var alertMessage: String?
    /// Whether the question before Stop Syncing is showing.
    @Published var isAskingToStop = false

    private let services: Services

    init(services: Services = .app) {
        self.services = services
    }

    /// The picker returned: makes or joins the sync folder, keeping the
    /// folder's scope open while `SyncCenter` makes its bookmark and reads it.
    /// A picker that failed or was dismissed (no URL) does nothing but say a
    /// failure. A folder outside iCloud Drive is refused, with nothing made.
    func picked(_ result: Result<[URL], Error>, for pick: PhoneSyncPick) async {
        guard !isWorking else { return }
        let folder: URL
        switch result {
        case .failure(let error):
            // A person cancelling the picker is not a failure worth an alert.
            if (error as NSError).code != NSUserCancelledError { fail(PhoneSyncSettingsModel.message(for: error)) }
            return
        case .success(let urls):
            guard let first = urls.first else { return }
            folder = first
        }
        let closeScope = services.openScope(folder)
        defer { closeScope() }
        if let refusal = PhoneSyncSettingsModel.refusal(forFolderInICloudDrive: services.isInICloudDrive(folder)) {
            fail(refusal)
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            switch pick {
            case .setUp: try await services.setUp(folder)
            case .join:
                // Joining may wait a minute for the folder's first file: say so, then say what came of it.
                services.announce(SyncWording.waitingForFiles)
                try await services.join(folder)
            }
            // Sync is on; the first sync is under way.
            services.announce(SyncWording.announceSyncing)
        } catch {
            fail(PhoneSyncSettingsModel.message(for: error))
        }
    }

    /// Sync Now: the center announces "Syncing." and the outcome itself.
    func syncNow() {
        services.syncNow()
    }

    /// Stop Syncing was pressed: asks first.
    func askToStop() {
        isAskingToStop = true
    }

    /// The question was answered yes: stops, deleting nothing, and says sync is off.
    func confirmStop() {
        isAskingToStop = false
        services.stop()
        services.announce(SyncWording.statusOff)
    }

    /// Shows `message` in the alert and speaks it.
    private func fail(_ message: String) {
        alertMessage = message
        services.announce(message)
    }
}
