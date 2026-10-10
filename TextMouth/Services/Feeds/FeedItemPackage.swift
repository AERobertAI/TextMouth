import Foundation

// MARK: - A Feed Item's Package Without Its File (FR11)

/// What becomes of a feed item's package when its downloaded file is
/// removed (FR11, branch A2): by Delete Download, by the rule that deletes
/// played downloads, or by the library's Remove.
///
/// A package that holds something of the listener's stays, without the
/// file: its record (bookInfo.json, with the place, the playback times, the
/// bookmarks, and the item's own settings), its content index, and its
/// transcript with the transcript's text. Everything made from the file goes
/// with it: an article's content.md, the speech prepared for it
/// (cachedAudio), and any audio edits. Downloading the item again puts the
/// new file into the same package, under the same book ID
/// (`FeedEpisodeImporter`). A package that holds nothing of the listener's
/// goes whole, so an automatic download that aged out unopened leaves
/// nothing behind.
///
/// The order that keeps the listener's place, the record and the feed's
/// index written before any file goes, is the library model's
/// (`LibraryViewModel.removeFeedFiles(of:keepingPackages:remove:)`); this
/// type says what stays, and removes what goes.
enum FeedItemPackage {
    /// The name of a package's record, bookInfo.json.
    private static let recordName = TextMouthPaths.bookInfoPath(in: URL(fileURLWithPath: "/", isDirectory: true)).lastPathComponent
    /// The name of a package's text, content.md.
    private static let textName = TextMouthPaths.contentMarkdownPath(in: URL(fileURLWithPath: "/", isDirectory: true)).lastPathComponent

    // MARK: What Stays

    /// Whether the package at `package` of the feed item `row` holds
    /// something of the listener's: the item was opened, or it has a place,
    /// playback times, bookmarks, a setting of its own, a field of its
    /// metadata edited by hand (`Book.HandEdits`), or a transcript. Only
    /// such a package stays once its file is removed.
    static func holdsListenerState(_ row: Book, package: URL) -> Bool {
        row.lastOpened != nil
            || row.readingPosition != nil
            || !row.bookmarks.isEmpty
            || row.lastPlaybackStarted != nil
            || row.lastPlaybackStopped != nil
            || row.hasLocalVoiceSettings
            || !(row.skippedHeadingIDs ?? []).isEmpty
            || row.localEndOfBookBehavior != nil
            || row.localSkipForwardUnit != nil
            || row.localSkipBackwardUnit != nil
            || !(row.handEdits?.fields.isEmpty ?? true)
            || holdsTranscript(package)
    }

    /// Whether the package at `package` holds a transcript, or a copy of one
    /// kept beside it, looked for without downloading anything. A package
    /// that is there but cannot be listed, as one whose folder is only in
    /// the cloud or cannot be read, is taken to hold one, so it is kept
    /// rather than deleted on a guess.
    static func holdsTranscript(_ package: URL) -> Bool {
        guard let names = try? listedEntryNames(of: package) else { return true }
        return names.contains(where: TextMouthPaths.isTranscriptFile)
    }

    /// Whether the entry named `name` at the top of a package whose book is
    /// of `format` stays there once the book's file goes: the record, the
    /// content index, the transcript's files, and the copies Edit Text kept
    /// of an edited text, for every format, since they may hold the only
    /// copy of an edit; and, for an audiobook, its content.md, which is its
    /// transcript's text. An article's content.md is made from its file, and
    /// goes with it, as the listener's own deletion removes it
    /// (`FeedCenter`'s Delete Download, through `FeedEnvironment.removeItem`).
    static func staysWithoutTheFile(_ name: String, format: BookFormat) -> Bool {
        if name == recordName || name == TextMouthPaths.contentIndexFileName || TextMouthPaths.isTranscriptFile(name)
            || TextMouthPaths.isKeptTextCopy(name) {
            return true
        }
        return format.isAudio && name == textName
    }

    /// The names at the top of the package at `package`, listed without
    /// downloading anything; none when it cannot be listed, which only a
    /// removal of what may go can take as none, removing nothing then.
    static func entryNames(of package: URL) -> [String] {
        (try? listedEntryNames(of: package)) ?? []
    }

    /// The names at the top of the package at `package`, listed without
    /// downloading anything; none when no package is there.
    /// - Throws: why a package that is there could not be listed, as when
    ///   its folder is only in the cloud or cannot be read: what it holds is
    ///   then unknown, never taken for nothing.
    static func listedEntryNames(of package: URL) throws -> [String] {
        do {
            return try DatalessFiles.withoutDownloading {
                try FileManager.default.contentsOfDirectory(atPath: package.path)
            }
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
    }

    // MARK: Checking Before Removing

    /// The package of the feed item `row` in the data directory at `root`,
    /// checked before anything in it is removed: a `.tmb` folder directly
    /// inside its feed's own folder, as `Book.packageDirectory(inDataDirectory:)`
    /// places it, not a symbolic link, and holding the row's file.
    /// - Throws: `FeedItemPackageError.notAFeedPackage` when any of these
    ///   does not hold.
    static func packageForRemoval(of row: Book, in root: URL) throws -> URL {
        let name = row.tmbDirectoryName
        guard let link = row.feedLink, isPackageName(name) else {
            throw FeedItemPackageError.notAFeedPackage
        }
        let package = FeedPaths.packageDirectory(named: name, of: link.feedID, in: root)
        // A link in the feed's folder could point anywhere.
        guard (try? package.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true,
              !row.filePath.isEmpty, isInside(row.bookFileURL, package) else {
            throw FeedItemPackageError.notAFeedPackage
        }
        return package
    }

    /// Whether `name` names a package directly in a feed's folder: one
    /// component, not hidden, ending in ".tmb", as a download names one
    /// (`TextMouthPaths.tmbName`), so no row can name the folder itself, or
    /// a staged or set-aside package.
    static func isPackageName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && (name as NSString).lastPathComponent == name
            && name.lowercased().hasSuffix(".tmb")
    }

    /// Whether `item` is inside `folder`, comparing their paths as written
    /// and, failing that, with symbolic links resolved, as a temporary
    /// folder reached through /var and /private/var is one folder.
    private static func isInside(_ item: URL, _ folder: URL) -> Bool {
        let written = folder.standardizedFileURL.path + "/"
        if item.standardizedFileURL.path.hasPrefix(written) {
            return true
        }
        return item.resolvingSymlinksInPath().path.hasPrefix(folder.resolvingSymlinksInPath().path + "/")
    }

    /// The entry at the top of `package` that holds `row`'s file: the file
    /// itself, or the folder it is in for a book kept as a folder of files.
    static func fileEntry(of row: Book, in package: URL) -> URL {
        let prefix = package.standardizedFileURL.path + "/"
        let path = row.bookFileURL.standardizedFileURL.path
        guard path.hasPrefix(prefix), let first = path.dropFirst(prefix.count).split(separator: "/").first else {
            return row.bookFileURL
        }
        return package.appendingPathComponent(String(first))
    }

    // MARK: Removing

    /// Removes from `package` everything the file of `row` made that its
    /// removal leaves: each entry `staysWithoutTheFile(_:format:)` does not
    /// keep, for good, without downloading anything. An entry that cannot
    /// be removed is a cache, so it stays, with one FEED_DOWNLOAD_CACHE_LEFT
    /// line in the debug log; the listener loses nothing by it.
    static func removeWhatTheFileMade(of row: Book, from package: URL) {
        for name in entryNames(of: package) where !staysWithoutTheFile(name, format: row.format) {
            do {
                try DatalessFiles.withoutDownloading {
                    try FileManager.default.removeItem(at: package.appendingPathComponent(name))
                }
            } catch CocoaError.fileNoSuchFile {
                continue
            } catch {
                DiagnosticLog.event(.feeds, "FEED_DOWNLOAD_CACHE_LEFT: \(row.title): \(name) could not be removed: \(error.localizedDescription)")
            }
        }
    }

    /// Removes what `removal` says from the data directory at `root`, for
    /// good, without downloading anything, as the rule deleting played
    /// downloads does: the file and what it made, keeping the package, or
    /// the whole package. A file or package already gone counts as removed.
    /// - Throws: `FeedItemPackageError.notAFeedPackage` for a row whose
    ///   package is not where its feed keeps it, or why the file or package
    ///   could not be removed; nothing was removed then.
    static func removeForGood(_ removal: FeedFileRemoval, in root: URL) throws {
        let package = try packageForRemoval(of: removal.row, in: root)
        let target = removal.keepsPackage ? fileEntry(of: removal.row, in: package) : package
        do {
            try DatalessFiles.withoutDownloading {
                try FileManager.default.removeItem(at: target)
            }
        } catch CocoaError.fileNoSuchFile {
            // Already gone: what stays is what the removal wanted.
        }
        if removal.keepsPackage {
            removeWhatTheFileMade(of: removal.row, from: package)
        }
    }
}

// MARK: - Downloading Again (FR11)

extension FeedItemPackage {
    /// Copies into `staged`, the package a new download of a kept item is
    /// built in, what it keeps of the kept package at `kept`: the
    /// transcript's files and the copies Edit Text kept of an edited text,
    /// whatever the format, as the kept package kept them
    /// (`staysWithoutTheFile(_:format:)`). The record and the content index
    /// are written anew, and an audiobook's content.md is written again from
    /// its transcript when the episode opens (`TranscriptTextLoader`), or
    /// found stale when the new file's audio differs.
    /// - Throws: why the kept package, which is there, could not be listed,
    ///   or why one could not be copied: the download then fails and the
    ///   kept package stays as it was, so no transcript is lost. A listing
    ///   taken for empty would have copied nothing, and the new package
    ///   would then have taken the kept one's place, discarding it with
    ///   everything it held.
    static func copyWhatANewDownloadKeeps(from kept: URL, to staged: URL) throws {
        for name in try listedEntryNames(of: kept)
        where TextMouthPaths.isTranscriptFile(name) || TextMouthPaths.isKeptTextCopy(name) {
            try FileManager.default.copyItem(at: kept.appendingPathComponent(name), to: staged.appendingPathComponent(name))
        }
    }

    /// Puts the package `staging` built in place of the kept package at
    /// `kept`, which a new download of its item replaces: in one swap of
    /// the two folders where the volume allows it, after which the kept
    /// package is at the staged name, where `staging.discard()` removes it.
    /// On a volume that cannot swap two folders, the kept package steps
    /// aside under a hidden name beside it while the new one is published,
    /// and goes once it is, or comes back when it cannot be. With no
    /// package at `kept`, the new one is published as any import's is.
    /// - Throws: why the new package could not be put in place; the kept
    ///   package is then where it was.
    static func putInPlace(_ staging: ImportStaging, of kept: URL) throws {
        guard FileManager.default.fileExists(atPath: kept.path) else {
            try staging.publish()
            return
        }
        if swapItems(staging.directory, kept) {
            return
        }
        let aside = kept.deletingLastPathComponent()
            .appendingPathComponent(".replaced-\(UUID().uuidString).tmb", isDirectory: true)
        try FileManager.default.moveItem(at: kept, to: aside)
        do {
            try staging.publish()
        } catch {
            try? FileManager.default.moveItem(at: aside, to: kept)
            throw error
        }
        try? FileManager.default.removeItem(at: aside)
    }

    /// Swaps the items at `first` and `second`, on one volume, in one step
    /// (`renamex_np` with `RENAME_SWAP`), and says whether it did: a volume
    /// that cannot swap two folders leaves both where they were.
    private static func swapItems(_ first: URL, _ second: URL) -> Bool {
        first.withUnsafeFileSystemRepresentation { from in
            second.withUnsafeFileSystemRepresentation { to in
                guard let from, let to else { return false }
                return renamex_np(from, to, UInt32(RENAME_SWAP)) == 0
            }
        }
    }
}

// MARK: - One Removal

/// One feed item whose file is being removed (FR11, branch A2): its row as
/// the library held it, whether its package stays without the file, for the
/// listener's state it holds, or goes whole, and where the row was.
struct FeedFileRemoval: Equatable, Sendable {
    /// The row as the library held it when the removal began.
    let row: Book
    /// Whether the package stays, holding the listener's state, while the
    /// file and what it made go.
    let keepsPackage: Bool
    /// Whether the row was kept on its feed's shelf, its file gone already,
    /// as Delete Episode finds an item whose download was deleted; a row
    /// whose package cannot be deleted goes back there.
    var wasOnShelf = false
}

/// What removing feed items' files did (FR11, branch A2,
/// `LibraryViewModel.removeFeedFiles(of:keepingPackages:remove:)`).
struct FeedFileRemovalOutcome {
    /// The removals whose files went, in the order asked.
    var removed: [FeedFileRemoval] = []
    /// The rows whose files stayed, each with why: each is among the
    /// library's books again, as it was.
    var failures: [(row: Book, error: any Error)] = []
}

/// Why a feed item's file was not removed (FR11, branch A2), in sentences
/// the library shows and VoiceOver speaks.
enum FeedItemPackageError: LocalizedError, Equatable {
    /// The row names no package of its feed's own folder holding its file,
    /// as a download made before FR11 that has not yet moved into its feed's
    /// folder: nothing is removed.
    case notAFeedPackage
    /// The feed's index, which must hold the item's row before its file
    /// goes, could not be written: the file stays.
    case indexNotWritten
    /// Remove from Library Only was chosen for a feed item, which stays in
    /// its feed while its file is here: nothing is removed.
    case staysInItsFeed

    var errorDescription: String? {
        switch self {
        case .notAFeedPackage:
            return "This download isn't where its feed keeps its downloads, so TextMouth left its files as they are."
        case .indexNotWritten:
            return "TextMouth couldn't save its list of this feed's downloads, so the download was kept. "
                + "Try again once the library can be saved."
        case .staysInItsFeed:
            return "It belongs to its feed while it is downloaded. Delete Download removes its file and keeps its place and bookmarks."
        }
    }
}
