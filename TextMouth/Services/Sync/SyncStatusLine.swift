import Foundation

// MARK: - The Status Line (FR43, section 7)

/// The Sync section's status line, in the order of section 7: the first state
/// that holds is the one spoken. One function for the Mac and the iPhone, so
/// both say the same words (R9); the device in a sentence is a parameter.
enum SyncStatusLine {
    /// The first state of `status` that holds, in words.
    ///
    /// - Parameters:
    ///   - status: What the center knows now.
    ///   - isPhone: Whether this device is an iPhone, for "this iPhone" and "this Mac".
    ///   - time: Formats a time of day ("9:41 AM"); the caller's own formatter, so a test fixes the zone.
    static func text(for status: SyncStatus, isPhone: Bool, time: (Date) -> String) -> String {
        let device = SyncWording.thisDevice(isPhone: isPhone)
        guard status.isOn else { return SyncWording.statusOff }
        if status.isSyncing { return SyncWording.statusSyncing }
        switch status.problem {
        case .offline:
            return SyncWording.statusOffline(changes: status.pendingChanges, device: device)
        case .folderMissing:
            return SyncWording.statusFolderMissing(device: device)
        case .outOfSpace:
            let waiting = max(0, (status.booksToBackUp ?? 0) - (status.booksBackedUp ?? 0))
            return SyncWording.statusOutOfSpace(changes: status.pendingChanges, books: waiting, device: device)
        case .laterVersion:
            return SyncWording.statusLaterVersion
        case .notASyncFolder:
            return SyncWording.notASyncFolder
        case .anotherStore:
            return SyncWording.anotherStore
        case .notInICloudDrive:
            return SyncWording.notInICloudDrive
        case .libraryNotLocal:
            return SyncWording.libraryNotLocal(isPhone: isPhone)
        case .notDownloaded, .exists, .damaged, nil:
            break
        }
        // Removals held back as a mistake are said before anything is called up to date.
        if status.heldRemovals > 0 || status.heldFeedRemovals > 0 {
            return SyncWording.heldRemovals(books: status.heldRemovals, feeds: status.heldFeedRemovals, device: device)
        }
        if status.isOffline { return SyncWording.statusOffline(changes: status.pendingChanges, device: device) }
        if status.pendingChanges > 0 { return SyncWording.statusUploading(changes: status.pendingChanges) }
        if case .notDownloaded? = status.problem { return SyncWording.statusNotDownloaded(isPhone: isPhone) }
        guard let last = status.lastSynced else { return SyncWording.statusSyncing }
        return SyncWording.statusUpToDate(at: time(last))
    }

    /// The lines that follow the status line as they apply: when each other device was last
    /// heard from, how far the backup is, and what this device's choice of books left undone.
    static func detailLines(for status: SyncStatus, time: (Date) -> String, isPhone: Bool = ThisDevice.isPhone) -> [String] {
        var lines = status.lastHeard.sorted { $0.key < $1.key }.map { SyncWording.lastHeard(from: $0.key, at: time($0.value)) }
        if let done = status.booksBackedUp, let total = status.booksToBackUp, done < total {
            lines.append(SyncWording.backingUp(done: done, total: total))
        }
        // What a device's own choice of books leaves undone (FR45), said where a person reads the status.
        let device = SyncWording.thisDevice(isPhone: isPhone)
        if status.removalsWaiting > 0 { lines.append(SyncWording.removalsWaiting(books: status.removalsWaiting, device: device)) }
        if status.booksShortOfRoom > 0 { lines.append(SyncWording.shortOfRoom(books: status.booksShortOfRoom, device: device)) }
        return lines
    }
}
