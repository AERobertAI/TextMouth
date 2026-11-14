import Foundation

/// Preserves a library index that TextMouth could not use, as a sibling file
/// named like `library.json.unreadable-20260929T142233Z`, before anything else
/// can touch it. Other files are preserved the same way under a marker of
/// their own: Edit Text keeps an edited content.md it cannot take, or one a
/// rebuild is about to replace, as `content.md.edited-20261004T123012Z`
/// (`BookTextEditSessions`, FR05).
///
/// The original file is never modified, moved, or deleted here. The copy
/// exists so the folders, order, sort settings, and per-book state that only
/// the index held stay recoverable, even after the user rebuilds the index.
///
/// Bytes that could be read are written to an independent file, so the copy
/// holds exactly what failed to decode. A file whose bytes cannot be read at
/// all (for example, one without read permission) is preserved with a hard
/// link instead: linking needs no read access, and the link keeps the original
/// contents alive when a rebuilt index later replaces `library.json` by an
/// atomic rename.
enum LibraryIndexQuarantine {
    /// Separates the index's own name from the timestamp in a copy's name,
    /// unless a caller passes a marker of its own.
    static let nameMarker = ".unreadable-"

    /// How many names to try for copies made within the same second.
    private static let maxNameAttempts = 100

    /// Preserves the index at `indexURL` and returns the copy, or nil when no
    /// copy could be made. Pass the bytes TextMouth read, when it read any, so
    /// the copy holds exactly those; pass nil when the file could not be read.
    ///
    /// An earlier copy of the same contents is returned instead of making a
    /// new one, so relaunching or pressing Try Again against the same damaged
    /// file does not pile up copies. `marker` separates the file's name from
    /// the timestamp, `nameMarker` unless the caller keeps copies of its own.
    static func preserve(_ indexURL: URL, bytes: Data?, marker: String = nameMarker, now: Date = Date()) -> URL? {
        if let bytes {
            return preserveBytes(bytes, of: indexURL, marker: marker, now: now)
        }
        return preserveByLinking(indexURL, marker: marker, now: now)
    }

    /// The copies already preserved next to `indexURL` under `marker`,
    /// oldest first: their timestamps sort chronologically.
    static func existingCopies(of indexURL: URL, marker: String = nameMarker) -> [URL] {
        let directory = indexURL.deletingLastPathComponent()
        let prefix = indexURL.lastPathComponent + marker
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasPrefix(prefix) }
            .sortedStably()
            .map { directory.appendingPathComponent($0) }
    }

    /// The name for a copy made at `date`. The timestamp uses the ISO 8601
    /// basic format (`20260929T142233Z`), which sorts chronologically and has
    /// no colons, which Finder would show as slashes. Later attempts within
    /// the same second add `-2`, `-3`, and so on. `marker` separates the
    /// file's name from the timestamp.
    static func copyURL(for indexURL: URL, at date: Date, attempt: Int = 1, marker: String = nameMarker) -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        var name = indexURL.lastPathComponent + marker + formatter.string(from: date)
        if attempt > 1 {
            name += "-\(attempt)"
        }
        return indexURL.deletingLastPathComponent().appendingPathComponent(name)
    }

    // MARK: - Private

    /// Writes `bytes` to a new independent file, unless an earlier independent
    /// copy already holds exactly these bytes.
    private static func preserveBytes(_ bytes: Data, of indexURL: URL, marker: String, now: Date) -> URL? {
        // A hard-linked copy shares the index's storage and changes with it
        // (for example, when the file is edited in place), so only a copy
        // stored separately counts as already preserving these bytes.
        let indexIdentity = fileIdentity(of: indexURL)
        let earlierCopy = existingCopies(of: indexURL, marker: marker).first { copy in
            fileIdentity(of: copy) != indexIdentity && contents(of: copy, match: bytes)
        }
        if let earlierCopy {
            return earlierCopy
        }
        return createCopy(of: indexURL, marker: marker, now: now) { destination in
            try bytes.write(to: destination, options: .withoutOverwriting)
        }
    }

    /// Preserves a file whose bytes could not be read by hard-linking it,
    /// falling back to a file copy on volumes without hard links.
    private static func preserveByLinking(_ indexURL: URL, marker: String, now: Date) -> URL? {
        // Nothing is left to preserve when the file vanished meanwhile.
        guard let identity = fileIdentity(of: indexURL) else { return nil }
        let earlierLink = existingCopies(of: indexURL, marker: marker).first { fileIdentity(of: $0) == identity }
        if let earlierLink {
            return earlierLink
        }
        let fileManager = FileManager.default
        let link = createCopy(of: indexURL, marker: marker, now: now) { destination in
            try fileManager.linkItem(at: indexURL, to: destination)
        }
        if let link {
            return link
        }
        // FAT volumes and many network shares have no hard links. A plain copy
        // still works whenever the read failed for a reason other than access.
        return createCopy(of: indexURL, marker: marker, now: now) { destination in
            try fileManager.copyItem(at: indexURL, to: destination)
        }
    }

    /// Runs `make` against successive unused names until one attempt succeeds.
    /// A name that is already taken is skipped, so an earlier copy is never
    /// overwritten. Any other failure removes whatever that attempt left
    /// behind (the name was unused, so a partial item there is its own) and
    /// gives up.
    private static func createCopy(
        of indexURL: URL,
        marker: String,
        now: Date,
        using make: (URL) throws -> Void
    ) -> URL? {
        for attempt in 1...maxNameAttempts {
            let destination = copyURL(for: indexURL, at: now, attempt: attempt, marker: marker)
            guard !itemExists(at: destination) else { continue }
            do {
                try make(destination)
                return destination
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                // Another writer claimed the name between the check and the write.
                continue
            } catch {
                try? FileManager.default.removeItem(at: destination)
                return nil
            }
        }
        return nil
    }

    /// Whether anything, even a dangling symbolic link, occupies `url`.
    private static func itemExists(at url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    /// Whether the file at `url` holds exactly `bytes`. Sizes are compared
    /// first, so unrelated copies are not read in full.
    private static func contents(of url: URL, match bytes: Data) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes?[.size] as? NSNumber, size.intValue == bytes.count else {
            return false
        }
        return (try? Data(contentsOf: url)) == bytes
    }

    /// The device and inode numbers of the item at `url`, which are equal
    /// exactly when two names are hard links to one file. They are read
    /// without opening the file, so its permissions do not matter.
    private static func fileIdentity(of url: URL) -> FileIdentity? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else {
            return nil
        }
        return FileIdentity(device: device.uint64Value, inode: inode.uint64Value)
    }

    /// Where a file's contents live, independent of the name used to reach it.
    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }
}
