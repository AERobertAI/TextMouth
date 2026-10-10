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
    /// playback times, bookmarks, a setting of its own, or a transcript.
    /// Only such a package stays once its file is removed.
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
            || holdsTranscript(package)
    }

    /// Whether the package at `package` holds a transcript, or a copy of one
    /// kept beside it, looked for without downloading anything.
    static func holdsTranscript(_ package: URL) -> Bool {
        entryNames(of: package).contains(where: TextMouthPaths.isTranscriptFile)
    }

    /// Whether the entry named `name` at the top of a package whose book is
    /// of `format` stays there once the book's file goes: the record, the
    /// content index, and the transcript's files; and, for an audiobook, its
    /// content.md and the copies Edit Text kept beside it, which are its
    /// transcript's text. An article's content.md is made from its file, and
    /// goes with it.
    static func staysWithoutTheFile(_ name: String, format: BookFormat) -> Bool {
        if name == recordName || name == TextMouthPaths.contentIndexFileName || TextMouthPaths.isTranscriptFile(name) {
            return true
        }
        return format.isAudio && (name == textName || TextMouthPaths.isKeptTextCopy(name))
    }

    /// The names at the top of the package at `package`, listed without
    /// downloading anything; none when it cannot be listed.
    static func entryNames(of package: URL) -> [String] {
        DatalessFiles.withoutDownloading {
            (try? FileManager.default.contentsOfDirectory(atPath: package.path)) ?? []
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
        guard let link = row.feedLink, !name.isEmpty, !name.hasPrefix("."),
              (name as NSString).lastPathComponent == name, name.lowercased().hasSuffix(".tmb") else {
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

// MARK: - One Removal

/// One feed item whose file is being removed (FR11, branch A2): its row as
/// the library held it, and whether its package stays without the file,
/// for the listener's state it holds, or goes whole.
struct FeedFileRemoval: Equatable, Sendable {
    /// The row as the library held it when the removal began.
    let row: Book
    /// Whether the package stays, holding the listener's state, while the
    /// file and what it made go.
    let keepsPackage: Bool
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
