import Foundation

/// Every word of syncing the library between devices (FR43): the Sync
/// section's labels and hints, its refusals, the status line's states, and
/// what Sync Now announces (sections 7 and 10 of
/// research/CLOUD-SYNC-BUILD-PLAN-2026-11-25.md, rule R9). The wording is
/// pinned by tests. The device named in a sentence is a parameter, so the iPhone
/// says "this iPhone" where the Mac says "this Mac".
enum SyncWording {
    // MARK: - The section and its commands

    /// The section's heading and the name of the feature.
    static var sectionTitle: String {
        // Translators: Heading of the settings section for syncing the library between devices, and the name of the feature. Title case.
        InterfaceText.line("sync.sectionTitle", "Sync")
    }

    /// What the section does, spoken as its hint.
    static var sectionSummary: String {
        // Translators: Explains the Sync section: the library stays the same on the Mac and the iPhone, through iCloud Drive.
        InterfaceText.line("sync.sectionSummary", "Keeps your books, places, and bookmarks the same on your Mac and iPhone, through iCloud Drive.")
    }

    /// The button that makes a sync folder.
    static var setUpTitle: String {
        // Translators: Title of the button that makes a new sync folder. Title case; the ellipsis means a folder chooser opens.
        InterfaceText.line("sync.setUpTitle", "Set Up Sync…")
    }

    /// The hint of the Set Up Sync button.
    static var setUpHint: String {
        // Translators: VoiceOver hint of the Set Up Sync button. TextMouth Sync is the folder's name and is not translated.
        InterfaceText.line("sync.setUpHint", "Makes a folder named TextMouth Sync in the iCloud Drive folder you choose, and copies your books into it.")
    }

    /// The button that uses a sync folder another device made.
    static var joinTitle: String {
        // Translators: Title of the button that chooses a sync folder another device already made. Title case; the ellipsis means a folder chooser opens.
        InterfaceText.line("sync.joinTitle", "Join Sync Folder…")
    }

    /// The hint of the Join Sync Folder button.
    static var joinHint: String {
        // Translators: VoiceOver hint of the Join Sync Folder button. TextMouth Sync is the folder's name and is not translated.
        InterfaceText.line("sync.joinHint", "Chooses the TextMouth Sync folder that another device set up.")
    }

    /// The button and menu command that syncs now.
    static var syncNowTitle: String {
        // Translators: Title of the button and the Library menu command that syncs right now. Title case.
        InterfaceText.line("sync.syncNowTitle", "Sync Now")
    }

    /// The button that stops syncing.
    static var stopTitle: String {
        // Translators: Title of the button that stops syncing this library. Title case; the ellipsis means a confirmation follows.
        InterfaceText.line("sync.stopTitle", "Stop Syncing…")
    }

    /// The question a person answers before syncing stops.
    static var stopQuestion: String {
        // Translators: The confirmation asked before syncing stops. "This Mac" names the device the person is using.
        InterfaceText.line("sync.stopQuestion", "Stop syncing this library? Nothing is deleted, on this Mac or in iCloud Drive.")
    }

    // MARK: - Keep on All Devices (section 16)

    /// The command that keeps a book's files on every device that syncs.
    static var keepTitle: String {
        // Translators: Title of the command and button that keeps a book's files on every device that syncs. Title case.
        InterfaceText.line("sync.keepTitle", "Keep on All Devices")
    }

    /// The command that ends it.
    static var stopKeepingTitle: String {
        // Translators: Title of the command and button that ends keeping a book's files on every device that syncs. Title case.
        InterfaceText.line("sync.stopKeepingTitle", "Stop Keeping on All Devices")
    }

    /// The keep command for several books.
    static func keepTitle(count: Int) -> String {
        // Translators: Title of the command that keeps several selected books on every device that syncs. A plural line, title case. %lld is the number of books.
        InterfaceText.line("sync.keepCountTitle", "Keep \(number: count) Books on All Devices")
    }

    /// The stop-keeping command for several books.
    static func stopKeepingTitle(count: Int) -> String {
        // Translators: Title of the command that ends keeping several selected books on every device that syncs. A plural line, title case. %lld is the number of books.
        InterfaceText.line("sync.stopKeepingCountTitle", "Stop Keeping \(number: count) Books on All Devices")
    }

    /// The checkbox in Book Information, and a row's state.
    static var keptState: String {
        // Translators: Label of the Book Information checkbox, and the state a book's row speaks when its files are kept on every device that syncs.
        InterfaceText.line("sync.keptState", "Kept on all devices")
    }

    /// The hint of the Book Information checkbox.
    static var keepHint: String {
        // Translators: VoiceOver hint of the Kept on all devices checkbox in Book Information.
        InterfaceText.line("sync.keepHint", "Every device that syncs keeps this book's files, and downloads them when it can.")
    }

    /// Announced after a person keeps a book.
    static func announceKeeping(title: String) -> String {
        // Translators: Said aloud after the person chooses Keep on All Devices. %@ is the book's title.
        InterfaceText.line("sync.announce.keeping", "Keeping \(title) on all devices.")
    }

    /// Announced after a person stops keeping a book on all devices.
    static func announceStoppedKeeping(title: String) -> String {
        // Translators: Said aloud after the person chooses Stop Keeping on All Devices. %@ is the book's title.
        InterfaceText.line("sync.announce.stoppedKeeping", "No longer keeping \(title) on all devices.")
    }

    // MARK: - Refusals

    /// A folder chosen outside iCloud Drive.
    static var notInICloudDrive: String {
        // Translators: Shown when the person chose a folder that is not in iCloud Drive for syncing.
        InterfaceText.line("sync.notInICloudDrive", "That folder isn't in iCloud Drive. Choose a folder in iCloud Drive.")
    }

    /// A library that is itself kept in a cloud folder.
    static var libraryNotLocal: String {
        // Translators: Shown when syncing is refused because the library is kept in a cloud folder. Change Location is a button of the Storage settings.
        InterfaceText.line("sync.libraryNotLocal", "Sync is for a library kept on this Mac. Move this one here with Change Location first.")
    }

    /// Set Up Sync found the folder already made.
    static var folderAlreadyThere: String {
        // Translators: Shown when Set Up Sync finds a folder named TextMouth Sync already there. Join Sync Folder is a button. TextMouth Sync is the folder's name and is not translated.
        InterfaceText.line("sync.folderAlreadyThere", "A folder named TextMouth Sync is already there. To use it, choose Join Sync Folder.")
    }

    /// Join Sync Folder found no sync folder.
    static var notASyncFolder: String {
        // Translators: Shown when the folder chosen to join is not a TextMouth Sync folder, or its files have not arrived from iCloud Drive yet.
        InterfaceText.line("sync.notASyncFolder", "That isn't a TextMouth Sync folder, or its files haven't arrived from iCloud Drive yet.")
    }

    /// The folder now holds another library's sync.
    static var anotherStore: String {
        // Translators: Shown when the sync folder now belongs to another library's sync. Join Sync Folder is a button.
        InterfaceText.line("sync.anotherStore", "The sync folder now holds another library's sync. Choose Join Sync Folder again.")
    }

    /// Joining waits for the folder's first file.
    static var waitingForFiles: String {
        // Translators: Said while joining waits for the sync folder's files to arrive from iCloud Drive.
        InterfaceText.line("sync.waitingForFiles", "Waiting for the sync folder's files to arrive from iCloud Drive.")
    }

    // MARK: - Pieces of the status line

    /// The device's name in a sentence about this device: "this Mac" or "this iPhone".
    static func thisDevice(isPhone: Bool) -> String {
        isPhone
            // Translators: The device the person is using, in the middle of a sentence, on an iPhone.
            ? InterfaceText.line("sync.thisDevice.iPhone", "this iPhone")
            // Translators: The device the person is using, in the middle of a sentence, on a Mac.
            : InterfaceText.line("sync.thisDevice.mac", "this Mac")
    }

    /// A count of changes, a plural phrase that other sentences hold.
    static func changes(_ count: Int) -> String {
        // Translators: A plural phrase: how many changes, such as "3 changes". %lld is the count. It sits inside a longer sentence.
        InterfaceText.line("sync.changes", "\(number: count) changes")
    }

    /// A count of books, a plural phrase that other sentences hold.
    static func books(_ count: Int) -> String {
        // Translators: A plural phrase: how many books, such as "138 books". %lld is the count. It sits inside a longer sentence.
        InterfaceText.line("sync.books", "\(number: count) books")
    }

    // MARK: - The status line, in the order the first true state speaks

    /// Sync is not set up.
    static var statusOff: String {
        // Translators: The Sync status when syncing is not set up.
        InterfaceText.line("sync.status.off", "Sync is off.")
    }

    /// A sync is running.
    static var statusSyncing: String {
        // Translators: The Sync status while a sync runs. The ellipsis means it is not finished.
        InterfaceText.line("sync.status.syncing", "Syncing…")
    }

    /// No network: changes wait on the device.
    static func statusOffline(changes: Int, device: String) -> String {
        // Translators: The Sync status with no network. A plural line. %lld is how many changes wait, and %@ names the device ("this Mac" or "this iPhone"), which sends them.
        InterfaceText.line("sync.status.offline", "Offline. \(number: changes) changes wait on \(device), and will be sent when the network is back.")
    }

    /// The sync folder is missing.
    static func statusFolderMissing(device: String) -> String {
        // Translators: The Sync status when the TextMouth Sync folder cannot be found. %@ names the device ("this Mac" or "this iPhone"), whose library is unchanged. TextMouth Sync is the folder's name and is not translated.
        InterfaceText.line("sync.status.folderMissing", "TextMouth can't find the TextMouth Sync folder in iCloud Drive. It may have been moved or deleted, or iCloud Drive signed out. Your library on \(device) is as it was.")
    }

    /// iCloud Drive has no room.
    static func statusOutOfSpace(changes: Int, books: Int, device: String) -> String {
        // Translators: The Sync status when iCloud Drive is full. The first %@ is a phrase counting changes ("3 changes"), the second counts books ("138 books"), and the third names the device ("this Mac" or "this iPhone"), whose library is unchanged.
        InterfaceText.line("sync.status.outOfSpace", "iCloud Drive is full, so \(Self.changes(changes)) and \(Self.books(books)) aren't uploaded. Your library on \(device) is as it was.")
    }

    /// The folder was made by a later TextMouth.
    static var statusLaterVersion: String {
        // Translators: The Sync status when a newer TextMouth made the sync folder, so this one cannot use it.
        InterfaceText.line("sync.status.laterVersion", "A later TextMouth made this sync folder. Update TextMouth to use it.")
    }

    /// Changes wait for iCloud Drive to upload them.
    static func statusUploading(changes: Int) -> String {
        // Translators: The Sync status while iCloud Drive has not yet uploaded changes. A plural line. %lld is how many changes wait.
        InterfaceText.line("sync.status.uploading", "\(number: changes) changes are waiting for iCloud Drive to upload them.")
    }

    /// Another device's changes have not arrived.
    static var statusNotDownloaded: String {
        // Translators: The Sync status when changes another device made have not yet downloaded from iCloud Drive.
        InterfaceText.line("sync.status.notDownloaded", "Some changes from iPhone haven't downloaded yet. TextMouth will try again.")
    }

    /// Removals held back as a mass removal: of books, of feeds (FR56), or of both, each counted
    /// ("42 books", "5 feeds", "42 books, 5 feeds").
    static func heldRemovals(books: Int, feeds: Int = 0, device: String) -> String {
        let counts = (books > 0 || feeds == 0 ? [Self.books(books)] : []) + (feeds > 0 ? [CountWording.feeds(feeds)] : [])
        let removals = CountWording.joinedCounts(counts)
        // Translators: The Sync status when TextMouth held back removing many books at once because it looked like a mistake. The first %@ is a phrase counting books ("42 books"), and the second names the device ("this Mac" or "this iPhone"), whose library the person should check. Sync Now is the name of a command.
        return InterfaceText.line("sync.status.heldRemovals", "TextMouth held back removing \(removals), since it looked like a mistake. Check the library on \(device), then choose Sync Now.")
    }

    /// Everything is synced.
    static func statusUpToDate(at time: String) -> String {
        // Translators: The Sync status when everything is synced. %@ is the time of the last sync, written by the system, such as "9:41 AM".
        InterfaceText.line("sync.status.upToDate", "Up to date. Last synced at \(time).")
    }

    /// When another device last sent changes.
    static func lastHeard(from device: String, at time: String) -> String {
        // Translators: A line of the Sync status. The first %@ names a device, such as "iPhone", and the second is a time written by the system, such as "9:40 AM".
        InterfaceText.line("sync.lastHeard", "Last heard from \(device) at \(time).")
    }

    /// The backup of books into the folder.
    static func backingUp(done: Int, total: Int) -> String {
        // Translators: A line of the Sync status while books are copied into the sync folder. The first %lld is how many are done and the second how many there are, such as "612 of 750".
        InterfaceText.line("sync.backingUp", "Backing up books: \(number: done) of \(number: total).")
    }

    // MARK: - What Sync Now announces

    /// Announced when Sync Now starts.
    static var announceSyncing: String {
        // Translators: Said aloud when the person starts Sync Now.
        InterfaceText.line("sync.announce.syncing", "Syncing.")
    }

    /// Announced when Sync Now finished with changes from another device.
    static func announceSynced(changes: Int, from device: String) -> String {
        // Translators: Said aloud when Sync Now finishes. A plural line. %lld is how many changes arrived, and %@ names the device they came from, such as "iPhone".
        InterfaceText.line("sync.announce.synced", "Synced. \(number: changes) changes from \(device).")
    }

    /// Announced when Sync Now finished with nothing new.
    static var announceNothingNew: String {
        // Translators: Said aloud when Sync Now finishes and no other device had anything new.
        InterfaceText.line("sync.announce.nothingNew", "Synced. Nothing new.")
    }

    /// Announced when an open reader moves to the place another device saved.
    static func announceMovedToPlace(from device: String) -> String {
        // Translators: Said aloud when the open book moves to the place saved on another device. %@ names that device, such as "iPhone".
        InterfaceText.line("sync.announce.movedToPlace", "Moved to the place saved on \(device).")
    }

    // MARK: - A book that cannot be fetched

    /// A book's files stopped arriving from iCloud Drive.
    static var fetchStalled: String {
        // Translators: Why a book's download from the sync folder stopped: iCloud Drive stopped sending its files. Said in the download view.
        InterfaceText.line("sync.fetch.stalled", "iCloud Drive stopped sending this book's files.")
    }

    /// What to try when a fetch stalled on a cellular or hotspot connection.
    static var fetchCellularHint: String {
        // Translators: Added after the stalled-download sentence when the connection is cellular or a hotspot. iCloud Drive has a setting that stops it using cellular data.
        InterfaceText.line("sync.fetch.cellularHint", "If iCloud Drive can't use cellular data, connect to Wi-Fi.")
    }
}
