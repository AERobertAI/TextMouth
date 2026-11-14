import Foundation
import os

/// The hidden copies a data-directory move leaves behind when it cannot
/// clean up after itself.
///
/// A move copies the whole data directory into a hidden folder beside its
/// destination (`DataDirectoryMigrator.stagingNamePrefix` and a UUID) and
/// removes that folder when the move ends. When the destination's volume is
/// unplugged mid-copy, or TextMouth is force-quit, the removal never
/// happens, and when the volume returns a half-copied library, as large as
/// the library, stays on it for good.
///
/// So that nothing but a folder a move itself made is ever removed, a small
/// journal on this Mac (`MachineLocalPaths.moveLeftovers`) lists the folders
/// moves have begun and not yet cleaned up. A move notes its folder before
/// it creates anything, forgets it once it has been published, and
/// forgets it after removing it. At launch `sweep` removes what the journal
/// still lists. The journal is never trusted further than that: a journalled
/// path is touched only if its last component is exactly a staging name, and
/// only if it is a real directory.
enum MigrationStagingLeftovers {
    /// One folder a move began: where it is, and when it was noted.
    struct Entry: Codable, Equatable {
        /// The folder's absolute path.
        let path: String
        /// When the move noted it.
        let noted: Date
    }

    /// How many entries the journal keeps; the newest win.
    static let journalLimit = 20

    /// How long a folder that cannot be seen stays in the journal. It may be
    /// on a volume that is away, so it is kept this long, then dropped.
    static let unseenLifetime: TimeInterval = 30 * 24 * 60 * 60

    /// The paths of the folders moves in this process are using right now,
    /// which a sweep must leave alone. The lock also serializes every read
    /// and write of the journal, so two threads never lose each other's
    /// entry.
    private static let inUse = OSAllocatedUnfairLock(initialState: Set<String>())

    // MARK: - Names

    /// Whether `name` is one a move gives its staging folder: exactly
    /// `DataDirectoryMigrator.stagingNamePrefix` followed by a UUID, nothing
    /// before it and nothing after.
    static func isStagingName(_ name: String) -> Bool {
        let prefix = DataDirectoryMigrator.stagingNamePrefix
        guard name.hasPrefix(prefix) else { return false }
        return UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }

    // MARK: - A Move's Part

    /// Records that a move is about to create `staging`, and marks it in use
    /// by this process. Called before anything is created, so a folder that
    /// exists is always noted.
    static func note(_ staging: URL, at now: Date = Date()) {
        let path = staging.path
        withJournal { used, entries in
            used.insert(path)
            entries.removeAll { $0.path == path }
            entries.append(Entry(path: path, noted: now))
            entries = newest(entries)
        }
    }

    /// Takes `staging` out of the journal and out of use: the move published
    /// it (renamed it into place), so nothing is left to clean up.
    static func forget(_ staging: URL) {
        let path = staging.path
        withJournal { used, entries in
            used.remove(path)
            entries.removeAll { $0.path == path }
        }
    }

    /// Removes `staging` when a move ends, whatever way it ended (after a
    /// publish there is nothing left to remove). The folder stops being in
    /// use. It is forgotten only when the removal succeeded: when the
    /// destination's volume has been unplugged, the folder can neither be
    /// seen nor removed, and "not there" cannot be told from "gone" (a mount
    /// point left on this Mac's disk keeps its parent folder, so even the
    /// parent's presence proves nothing). A later `sweep` tries again.
    static func discard(_ staging: URL, fileManager: FileManager = .default) {
        let path = staging.path
        do {
            try fileManager.removeItem(at: staging)
            forget(staging)
        } catch {
            withJournal { used, _ in used.remove(path) }
            // Say so only if the folder is still there; when it cannot be
            // seen at all, the sweep keeps the note and says nothing yet.
            if fileManager.fileExists(atPath: path) {
                log("MIGRATION_STAGING_LEFT", staging, "could not be removed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - The Sweep

    /// Removes the staging folders moves left, those the journal lists, and
    /// returns how many were removed. For each entry, in this order:
    /// 1. A path whose last component is not a staging name is dropped (a
    ///    hand-edited journal can never make this delete anything else).
    /// 2. A folder this process is using is skipped.
    /// 3. When nothing exists at the path, the entry is kept (the volume may
    ///    be away) until it is `unseenLifetime` old, then dropped.
    /// 4. When the path is not a real directory (a file, or a symbolic link,
    ///    which is never followed), the entry is dropped and nothing is
    ///    touched.
    /// 5. Otherwise the folder is removed: on success the entry is forgotten
    ///    and the removal logged; on failure it is kept and logged.
    @discardableResult
    static func sweep(fileManager: FileManager = .default, now: Date = Date()) -> Int {
        var removed = 0
        for entry in readEntries() {
            let url = URL(fileURLWithPath: entry.path, isDirectory: true)
            guard isStagingName(url.lastPathComponent) else {
                drop(entry)
                continue
            }
            guard !inUse.withLock({ $0.contains(entry.path) }) else { continue }

            // `attributesOfItem` does not follow a symbolic link, so a link
            // named like a staging folder is seen as a link.
            guard let type = (try? fileManager.attributesOfItem(atPath: entry.path))?[.type] as? FileAttributeType else {
                if now.timeIntervalSince(entry.noted) > unseenLifetime { drop(entry) }
                continue
            }
            guard type == .typeDirectory else {
                drop(entry)
                continue
            }
            do {
                try fileManager.removeItem(at: url)
                drop(entry)
                removed += 1
                log("MIGRATION_STAGING_REMOVED", url, "left by an interrupted move")
            } catch {
                log("MIGRATION_STAGING_LEFT", url, "could not be removed: \(error.localizedDescription)")
            }
        }
        return removed
    }

    /// Runs `sweep` once, off the main thread at utility priority. It does
    /// nothing in hosted tests.
    /// - Parameters:
    ///   - isHostedTest: Whether this is a hosted test run.
    ///   - completion: Called on the background queue when the sweep has
    ///     finished (tests wait on it); not called when nothing is run.
    static func sweepInBackground(
        isHostedTest: Bool = TextMouthRuntime.current.isHostedTest,
        completion: (@Sendable () -> Void)? = nil
    ) {
        guard !isHostedTest else { return }
        DispatchQueue.global(qos: .utility).async {
            sweep()
            completion?()
        }
    }

    // MARK: - The Journal

    /// The journal's entries, oldest first. A journal that is missing,
    /// unreadable, or damaged (not a list of entries) reads as empty; this
    /// never throws.
    static func readEntries() -> [Entry] {
        inUse.withLock { _ in readJournal() }
    }

    /// Reads the journal file without taking the lock.
    private static func readJournal() -> [Entry] {
        guard let data = try? Data(contentsOf: MachineLocalPaths.moveLeftovers) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Entry].self, from: data)) ?? []
    }

    /// Takes the lock, lets `change` edit the set of folders in use and the
    /// journal's entries, and writes the journal back if it changed.
    private static func withJournal(_ change: (inout Set<String>, inout [Entry]) -> Void) {
        inUse.withLockUnchecked { used in
            let before = readJournal()
            var entries = before
            change(&used, &entries)
            if entries != before { writeJournal(entries) }
        }
    }

    /// Takes `entry` out of the journal.
    private static func drop(_ entry: Entry) {
        withJournal { _, entries in entries.removeAll { $0.path == entry.path } }
    }

    /// The newest `journalLimit` of `entries`, oldest first (entries noted
    /// at the same moment keep their order).
    private static func newest(_ entries: [Entry]) -> [Entry] {
        let ordered = entries.enumerated()
            .sortedStably { ($0.element.noted, $0.offset) < ($1.element.noted, $1.offset) }
            .map(\.element)
        return Array(ordered.suffix(journalLimit))
    }

    /// Writes `entries` atomically, or removes the journal when none are
    /// left. A write that fails is lost quietly: the journal is a safety
    /// net, never a reason for a move to fail.
    private static func writeJournal(_ entries: [Entry]) {
        let file = MachineLocalPaths.moveLeftovers
        if entries.isEmpty {
            try? FileManager.default.removeItem(at: file)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: file, options: .atomic)
    }

    // MARK: - The Log

    /// Logs `tag: <folder's name>: <what happened>` as a storage event. The
    /// folder is named by `DiagnosticLog.loggablePath`, never by its
    /// absolute path.
    private static func log(_ tag: String, _ folder: URL, _ what: String) {
        DiagnosticLog.event(.storage, "\(tag): \(DiagnosticLog.loggablePath(folder)): \(what)")
    }
}
