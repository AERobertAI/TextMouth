import Foundation

// PhoneSyncSettingsModel.swift: the decisions of the iPhone's Sync section
// (FR43, sync-iphone), in plain types the Mac's test host can run, as
// `PhoneSettingsModel` does for the rest of Settings. What the section says is the
// Mac's own: the commands and their refusals are `SyncSettingsModel`'s, the
// status line and the lines after it are `SyncStatusLine`'s, both with the iPhone's
// words under one platform flag (`ThisDevice`), so the two never differ (R9). What
// is the phone's alone is here: which controls show, the folder picker's scope, and
// Keep on All Devices. Every state is words, so VoiceOver and a braille display read
// all of it (rule R9 of research/CLOUD-SYNC-BUILD-PLAN-2026-11-25.md).

// MARK: - Which Device This Is

/// Which kind of device this build runs on, for the sentences that name it
/// ("this Mac", "this iPhone"): the one platform flag. A test passes the kind it
/// wants to a function's `isPhone` instead, so both sentences are pinned on the Mac.
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

// MARK: - The iPhone's Forms of the Sync Lines

/// The lines of the Sync section that differ on the iPhone from the Mac's: a sentence that names the other device, or this
/// one. They are `SyncWording`'s, with the Mac's lines beside them; each chooses by the platform flag.
extension SyncWording {
    /// The status when another device's changes haven't downloaded: the Mac's line names the iPhone, so the iPhone's names the Mac.
    static func statusNotDownloaded(isPhone: Bool) -> String {
        guard isPhone else { return statusNotDownloaded }
        // Translators: The Sync status on an iPhone when changes made on the Mac have not yet downloaded from iCloud Drive.
        return InterfaceText.line("phoneSync.status.notDownloaded", "Some changes from your Mac haven't downloaded yet. TextMouth will try again.")
    }

    /// The question asked before syncing stops: the Mac's names "this Mac", the iPhone's "this iPhone".
    static func stopQuestion(isPhone: Bool) -> String {
        guard isPhone else { return stopQuestion }
        // Translators: The confirmation asked on an iPhone before syncing stops. Nothing is deleted from the iPhone or from iCloud Drive.
        return InterfaceText.line("phoneSync.stopQuestion", "Stop syncing this library? Nothing is deleted, on this iPhone or in iCloud Drive.")
    }

    /// The confirmation's button that stops syncing, with no ellipsis: the question has been asked.
    static var stopButton: String {
        // Translators: The button of the confirmation that stops syncing on an iPhone. Title case.
        InterfaceText.line("phoneSync.stopButton", "Stop Syncing")
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

    /// What the control does, as its VoiceOver hint.
    var hint: String {
        switch self {
        case .setUp: return SyncWording.setUpHint
        case .join: return SyncWording.joinHint
        case .syncNow: return SyncWording.sectionSummary
        case .stop: return SyncWording.stopQuestion(isPhone: ThisDevice.isPhone)
        }
    }
}

/// What the Sync section holds.
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

    /// The status line for the iPhone, and the lines after it, as the section reads them: the shared function, in the
    /// iPhone's words.
    static func lines(for status: SyncStatus, isPhone: Bool = ThisDevice.isPhone, time: (Date) -> String = timeOfDay) -> [String] {
        [SyncStatusLine.text(for: status, isPhone: isPhone, time: time)] + SyncStatusLine.detailLines(for: status, time: time)
    }

    /// A date as a time of day, as the system writes one: "9:41 AM".
    static func timeOfDay(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
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

/// The Sync section's steps, which the view calls: choosing a folder, Sync Now, and Stop Syncing. The Mac's own model
/// (`SyncSettingsModel`) refuses a folder, runs the command, says what came of it, and announces it; this adds what the
/// phone alone does: the picked folder's security scope is held open while the sync makes its bookmark and reads it.
/// The services are passed in, so a test runs every step with none of the real ones (and never touches iCloud Drive).
@MainActor
final class PhoneSyncSettingsController: ObservableObject {
    /// The Mac's commands and the words they end in, for the iPhone.
    let model: SyncSettingsModel
    /// Opens the security scope of a URL from the picker and returns what closes it.
    private let openScope: (URL) -> () -> Void

    /// Whether the question before Stop Syncing is showing.
    @Published var isAskingToStop = false
    /// Whether a Set Up or Join is under way, so a second press does nothing.
    @Published private(set) var isWorking = false

    /// - Parameters:
    ///   - model: The commands; the app's own by default, for the iPhone.
    ///   - openScope: Opens the picked folder's scope; the system's by default.
    init(
        model: SyncSettingsModel = PhoneSyncSettingsController.appModel(),
        openScope: @escaping (URL) -> () -> Void = { url in
            let opened = url.startAccessingSecurityScopedResource()
            return { if opened { url.stopAccessingSecurityScopedResource() } }
        }
    ) {
        self.model = model
        self.openScope = openScope
    }

    /// The app's model for the iPhone. A Debug build's interface test that names a sandbox folder in `TEXTMOUTH_SYNC_FOLDER`
    /// (`SyncCenter.seamFolder()`) has chosen to sync there, so the model's own refusals (R6) let that folder and the
    /// library pass, as the center's do; a Release build has no such folder, and these are the ordinary checks.
    static func appModel() -> SyncSettingsModel {
        SyncSettingsModel(
            libraryLocation: {
                SyncCenter.seamFolder() != nil ? .local : CloudServices.itemStatus.location(of: TextMouthPaths.root)
            },
            locationOf: { folder in
                SyncCenter.isSeamFolder(folder) ? .cloud(.iCloudDrive) : CloudServices.itemStatus.location(of: folder)
            },
            isPhone: true
        )
    }

    /// The picker returned: sets up in the folder, or joins it, with the folder's scope open throughout.
    /// A picker the person cancelled, or that gave no folder, does nothing; one that failed is said.
    /// - Returns: Whether sync is now set up.
    @discardableResult
    func picked(_ result: Result<[URL], Error>, for pick: PhoneSyncPick) async -> Bool {
        guard !isWorking else { return false }
        let folder: URL
        switch result {
        case .failure(let error):
            // A person cancelling the picker is not a failure worth a word.
            if (error as NSError).code != NSUserCancelledError {
                model.say(SyncSettingsModel.sentence(for: error, isPhone: true))
            }
            return false
        case .success(let urls):
            guard let first = urls.first else { return false }
            folder = first
        }
        let closeScope = openScope(folder)
        defer { closeScope() }
        isWorking = true
        defer { isWorking = false }
        switch pick {
        case .setUp: return await model.setUp(in: folder)
        case .join: return await model.join(folder)
        }
    }

    /// Sync Now: the center announces "Syncing." and what came of it.
    func syncNow() { model.syncNow() }

    /// Stop Syncing was pressed: asks first.
    func askToStop() { isAskingToStop = true }

    /// The question was answered yes: stops, deleting nothing, and says sync is off.
    func confirmStop() {
        isAskingToStop = false
        model.stop()
    }
}

// MARK: - Keep on All Devices

/// Keep on All Devices (section 16), as the Mac does it: the choice is stamped in the sync, the set it reads follows at once,
/// and VoiceOver is told only when something changed.
@MainActor
enum PhoneKeepOnAllDevices {
    /// Whether `bookID` is kept on all devices that sync, as the rows and the switch read it.
    static func isKept(_ bookID: UUID) -> Bool {
        KeptBooks.shared.isKeptOnAllDevices(bookID)
    }

    /// Keeps `book` on all devices, or stops. A choice that is already so changes nothing and says nothing.
    /// - Returns: Whether anything was stamped.
    @discardableResult
    static func set(_ keeping: Bool, _ book: Book) -> Bool {
        guard isKept(book.id) != keeping else { return false }
        SyncCenter.shared.setKeep(keeping, for: [book.id])
        // The set follows at once, so the switch and the rows read the new value as VoiceOver asks, before the sync's own
        // registers say so.
        let ids = KeptBooks.shared.syncedBookIDs
        KeptBooks.shared.setSyncedBooks(keeping ? ids.union([book.id]) : ids.subtracting([book.id]))
        PhoneAnnouncer.say(keeping ? SyncWording.announceKeeping(title: book.title) : SyncWording.announceStoppedKeeping(title: book.title))
        return true
    }
}
