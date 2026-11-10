import Foundation

// MARK: - A Feed Item's Package Without Its File (FR11)

/// What becomes of a feed item's package when its downloaded file is
/// removed (FR11, branch A2): by Delete Download, by the library's Remove,
/// or by one of the engine's rules, which delete played downloads and keep
/// the newest.
///
/// A package that holds something of the listener's stays, without the
/// file: its record (bookInfo.json, with the place, the playback times, the
/// bookmarks, and the item's own settings), its content index, its
/// transcript, the copies Edit Text kept of an edited text, and its
/// content.md, which is an audiobook's transcript text and may hold an edit
/// of an article's text made with Edit Text before feed items lost it. No
/// rule of the engine ever deletes an article's content.md; the listener's
/// own Delete Download takes it with the file, as one item, as the Trash
/// setting says (`removeFileAndText(of:in:remove:)`). Everything else made
/// from the file goes with it: the speech prepared for it (cachedAudio),
/// and any audio edits. Downloading the item again puts the new file into
/// the same package, under the same book ID (`FeedEpisodeImporter`),
/// keeping an article's earlier text beside the new one as an `.edited-`
/// copy when they differ (`keepEarlierText(_:in:)`). A package that holds nothing of the listener's
/// goes whole, so an automatic download that aged out unopened leaves
/// nothing behind.
///
/// The order that keeps the listener's place, the record and the feed's
/// index written before any file goes, is the library model's
/// (`LibraryViewModel.removeFeedFiles(of:keepingPackages:remove:)`); this
/// type says what stays, and removes what goes.
enum FeedItemPackage {
    // MARK: What Stays

    /// Whether the package at `package` of the feed item `row` holds
    /// something of the listener's: the item was opened, or it has a place,
    /// playback times, bookmarks, a setting of its own, a field of its
    /// metadata edited by hand (`Book.HandEdits`), or files of the
    /// listener's (`holdsListenersFiles(_:)`). Only such a package stays
    /// once its file is removed.
    ///
    /// The last test reads the package's folder and, for a transcript, its
    /// transcript.json, which is slow for a long transcript on a cloud
    /// drive. A caller on the main thread that has the answer already, read
    /// off it (`listenersFilesHeld(in:)`), passes it as `holdsListenersFiles`
    /// and nothing is read here; without it the package is read here.
    static func holdsListenerState(_ row: Book, package: URL, holdsListenersFiles known: Bool? = nil) -> Bool {
        !row.isUnopened
            || row.readingPosition != nil
            || !row.bookmarks.isEmpty
            || row.lastPlaybackStarted != nil
            || row.lastPlaybackStopped != nil
            || row.hasOwnSettings
            || !(row.handEdits?.fields.isEmpty ?? true)
            || (known ?? holdsListenersFiles(package))
    }

    /// For each of `packages`, by the ID of the book it belongs to, whether
    /// it holds files of the listener's (`holdsListenersFiles(_:)`). The
    /// reads are slow enough to be felt (about 70 ms for a transcript of
    /// 16 MB, once for each episode a rule removes), so a caller on the main
    /// thread has them made on another and passes the answers to
    /// `holdsListenerState(_:package:holdsListenersFiles:)`. Safe to call
    /// from any thread.
    static func listenersFilesHeld(in packages: [UUID: URL]) -> [UUID: Bool] {
        packages.mapValues { holdsListenersFiles($0) }
    }

    /// Whether the package at `package` holds files of the listener's: a
    /// transcript, a copy of one kept beside it, or a copy Edit Text kept of
    /// an edited text, which may be the only copy of the edit. A podcast's
    /// own transcript the listener has not touched is not the listener's
    /// (FMT25): it came with the download and comes again with the next, so
    /// an automatic download that ages out unopened still leaves nothing
    /// behind (`TranscriptStore.holdsUntouchedPodcastTranscript(in:)`).
    /// Looked for without downloading anything; a package that is there but
    /// cannot be listed, as one whose folder is only in the cloud or cannot
    /// be read, is taken to hold them, so it is kept rather than deleted on a
    /// guess.
    static func holdsListenersFiles(_ package: URL) -> Bool {
        guard let names = try? listedEntryNames(of: package) else { return true }
        return names.contains { name in
            if name == TextMouthPaths.transcriptFileName {
                return !TranscriptStore.holdsUntouchedPodcastTranscript(in: package)
            }
            return TextMouthPaths.isTranscriptFile(name) || TextMouthPaths.isKeptTextCopy(name)
        }
    }

    /// Whether the entry named `name` at the top of a package stays there
    /// once the book's file goes, whatever the book's format: the record,
    /// the content index, the transcript's files, the copies Edit Text kept
    /// of an edited text, and content.md, which is an audiobook's transcript
    /// text and may hold an edit of an article's text made with Edit Text.
    /// Each may hold the only copy of something the listener made, so no
    /// rule of the engine removes it; only the listener's own Delete
    /// Download takes an article's content.md, with its file
    /// (`FeedCenter`'s Delete Download, through `FeedEnvironment.removeItem`).
    static func staysWithoutTheFile(_ name: String) -> Bool {
        name == TextMouthPaths.bookInfoFileName || name == TextMouthPaths.contentIndexFileName
            || name == TextMouthPaths.contentMarkdownFileName
            || TextMouthPaths.isTranscriptFile(name) || TextMouthPaths.isKeptTextCopy(name)
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
    /// checked before anything in it is removed, as the library checks a
    /// book's package before deleting it
    /// (`FileImportService.managedPackageURLForDeletion`): a `.tmb` folder
    /// directly inside its feed's own folder, as
    /// `Book.packageDirectory(inDataDirectory:)` places it, not a symbolic
    /// link, and holding the row's file.
    /// - Throws: `FeedItemPackageError.notAFeedPackage` when any of these
    ///   does not hold.
    static func packageForRemoval(of row: Book, in root: URL) throws -> URL {
        let name = row.tmbDirectoryName
        guard let link = row.feedLink, isPackageName(name) else {
            throw FeedItemPackageError.notAFeedPackage
        }
        let package = FeedPaths.packageDirectory(named: name, of: link.feedID, in: root)
        guard !FileImportService.isSymbolicLink(package), !row.filePath.isEmpty, isInside(row.bookFileURL, package) else {
            throw FeedItemPackageError.notAFeedPackage
        }
        return package
    }

    /// Whether `name` names a package directly in a feed's folder: as the
    /// library names one (`FileImportService.isManagedPackageName(_:)`), and
    /// not hidden, as a download names one (`TextMouthPaths.tmbName`), so no
    /// row can name the folder itself, or a staged or set-aside package.
    static func isPackageName(_ name: String) -> Bool {
        !name.hasPrefix(".") && FileImportService.isManagedPackageName(name)
    }

    /// Whether `item` is inside `folder`, comparing their paths as written
    /// and, failing that, with symbolic links resolved, as a temporary
    /// folder reached through /var and /private/var is one folder.
    private static func isInside(_ item: URL, _ folder: URL) -> Bool {
        MaintenanceFileAccess.isItem(item, inside: folder)
            || MaintenanceFileAccess.isItem(item.resolvingSymlinksInPath(), inside: folder.resolvingSymlinksInPath())
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

    /// Removes the package of the feed item `row` whole through `remove`
    /// (REV14 feeds 8): as Delete Episode deletes an item's package,
    /// Unsubscribe and Delete Feed… the packages kept for removed downloads,
    /// through the listener's own removal, and as an import discards the
    /// package it published for an item that gets no row. One rule for all
    /// of them: a package already gone counts as removed, nothing of it
    /// being left to keep, so its row goes.
    /// - Throws: `FeedItemPackageError.notAFeedPackage` for a row naming no
    ///   package of its feed's own folder (`packageForRemoval(of:in:)`), or
    ///   why the package could not be removed; nothing was removed then.
    @MainActor
    static func removeWhole(_ row: Book, in root: URL, remove: @MainActor (URL) throws -> Void) throws {
        let package = try packageForRemoval(of: row, in: root)
        guard MaintenanceFileAccess.hasItem(at: package) else { return }
        try remove(package)
    }

    /// Removes from `package` everything the file of `row` made that its
    /// removal leaves: each entry `staysWithoutTheFile(_:)` does not keep,
    /// for good, without downloading anything. An entry that cannot be
    /// removed is a cache, so it stays, with one FEED_DOWNLOAD_CACHE_LEFT
    /// line in the debug log; the listener loses nothing by it.
    static func removeWhatTheFileMade(of row: Book, from package: URL) {
        for name in entryNames(of: package) where !staysWithoutTheFile(name) {
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

    /// What begins the hidden name of the folder an article's file and text
    /// wait in, beside its package, while the listener's Delete Download
    /// removes them as one item (`removeFileAndText(of:in:remove:)`).
    /// Hidden, it is no package of the feed's folder (`isPackageName(_:)`).
    static let removalHolderPrefix = ".removing-"

    /// The hidden holder `removeFileAndText(of:in:remove:)` makes beside
    /// `package` for `row`'s file and text: named after the row's book ID,
    /// so the launch's sweep can tell whose they are
    /// (`bookID(ofRemovalHolderNamed:)`), then a name of its own, so a
    /// holder left from before never stands in a new one's way.
    static func removalHolder(for row: Book, beside package: URL) -> URL {
        package.deletingLastPathComponent().appendingPathComponent(
            removalHolderPrefix + row.id.uuidString + "-" + UUID().uuidString,
            isDirectory: true
        )
    }

    /// The book ID the holder named `name` is named after
    /// (`removalHolder(for:beside:)`); nil for any name not a holder's. A
    /// holder named before REV14, by a name of its own alone, gives that
    /// name, which no book has.
    static func bookID(ofRemovalHolderNamed name: String) -> UUID? {
        guard name.hasPrefix(removalHolderPrefix) else { return nil }
        return UUID(uuidString: String(name.dropFirst(removalHolderPrefix.count).prefix(36)))
    }

    /// Removes `row`'s file from `package` through `remove`, as the
    /// listener's own Delete Download does, to the Trash or for good as the
    /// removal setting says: for a text book, an article, with its
    /// content.md, which may hold an edit, as one item, so the Trash holds
    /// one folder with both (REV11). Both first move, by rename, into a
    /// folder named after the file, inside a hidden holder beside the
    /// package in its feed's folder, named for the row
    /// (`removalHolder(for:beside:)`), which is then deleted, so the Trash's
    /// Put Back cannot return them into the package (#1935). A refusal puts
    /// both back in the package. Should something keep them from going
    /// back, they stay in the holder, which is then left, with one log
    /// line, rather than lost, and the next launch puts them back into the
    /// package of the row, which still names them; it sends a holder a
    /// crash left, once the deletion went ahead, as Removal Behavior says
    /// (`FeedCenter.sweepRemovalHolders()`, REV14 feeds 3).
    /// - Throws: why the file, or the file and its text, could not be
    ///   removed; nothing was removed then.
    @MainActor
    static func removeFileAndText(of row: Book, in package: URL, remove: @MainActor (URL) throws -> Void) throws {
        let file = fileEntry(of: row, in: package)
        let text = TextMouthPaths.contentMarkdownPath(in: package)
        let fileManager = FileManager.default
        guard !row.format.isAudio, fileManager.fileExists(atPath: text.path) else {
            try remove(file)
            return
        }
        let holder = removalHolder(for: row, beside: package)
        let together = holder.appendingPathComponent(file.deletingPathExtension().lastPathComponent, isDirectory: true)
        try fileManager.createDirectory(at: together, withIntermediateDirectories: true)
        var moved: [(from: URL, to: URL)] = []
        do {
            for entry in [file, text] {
                let destination = together.appendingPathComponent(entry.lastPathComponent)
                try fileManager.moveItem(at: entry, to: destination)
                moved.append((entry, destination))
            }
            try remove(together)
        } catch {
            for step in moved.reversed() {
                try? fileManager.moveItem(at: step.to, to: step.from)
            }
            removeHolderIfEmpty(holder, of: row)
            throw error
        }
        removeHolderIfEmpty(holder, of: row)
    }

    /// The holders of `removeFileAndText(of:in:remove:)` left in the feeds'
    /// own folders of the data directory at `root`: each folder directly in
    /// a feed's folder whose name begins with `removalHolderPrefix`, as a
    /// crash between moving an article's file and text into one and the
    /// Trash taking it leaves one, or a refusal whose files could not go
    /// back (FEED_DOWNLOAD_HELD_ASIDE). Listed without downloading
    /// anything; a folder that cannot be listed is passed over.
    static func removalHolders(in root: URL) -> [URL] {
        let feeds = FeedPaths.recordsFolder(in: root)
        let fileManager = FileManager.default
        let names = (try? DatalessFiles.withoutDownloading { try fileManager.contentsOfDirectory(atPath: feeds.path) }) ?? []
        return names.sorted().flatMap { name -> [URL] in
            // A feed's own folder is named by its ID alone (FR11).
            guard let feedID = FeedPaths.feedID(ofItemsFolderNamed: name) else { return [] }
            let folder = FeedPaths.itemsFolder(of: feedID, in: root)
            let entries = (try? DatalessFiles.withoutDownloading { try fileManager.contentsOfDirectory(atPath: folder.path) }) ?? []
            return entries.filter { $0.hasPrefix(removalHolderPrefix) }.sorted().map {
                folder.appendingPathComponent($0, isDirectory: true)
            }
        }
    }

    /// Removes the holder `holder` of `removeFileAndText(of:in:remove:)`
    /// once nothing is left in it but an empty folder; anything still in it
    /// stays, with one FEED_DOWNLOAD_HELD_ASIDE line naming `row`, for the
    /// next launch to put back.
    private static func removeHolderIfEmpty(_ holder: URL, of row: Book) {
        guard !holdsFiles(holder) else {
            DiagnosticLog.event(
                .feeds,
                "FEED_DOWNLOAD_HELD_ASIDE: \(row.title): its file or text could not go back into its package and waits in "
                    + "\(holder.lastPathComponent), which the next launch puts back"
            )
            return
        }
        try? FileManager.default.removeItem(at: holder)
    }

    /// Whether `item` is a file, or a folder holding a file at any depth:
    /// an empty folder, or one of empty folders, holds nothing of anyone's.
    /// Looked at without downloading anything.
    private static func holdsFiles(_ item: URL) -> Bool {
        let fileManager = FileManager.default
        var isFolder: ObjCBool = false
        guard fileManager.fileExists(atPath: item.path, isDirectory: &isFolder) else { return false }
        guard isFolder.boolValue else { return true }
        let paths = (try? DatalessFiles.withoutDownloading { try fileManager.subpathsOfDirectory(atPath: item.path) }) ?? []
        return paths.contains { path in
            var isSubfolder: ObjCBool = false
            _ = fileManager.fileExists(atPath: item.appendingPathComponent(path).path, isDirectory: &isSubfolder)
            return !isSubfolder.boolValue
        }
    }

    /// What the launch's sweep did with one holder
    /// (`sweepHolder(_:puttingBackInto:remove:)`), as its log line says it.
    struct HolderSweep: Equatable, Sendable {
        /// The names of the files put back into their package.
        var putBack: [String] = []
        /// The names of the folders sent as Removal Behavior says.
        var removed: [String] = []
    }

    /// Empties the holder `holder` of `removeFileAndText(of:in:remove:)` as
    /// the launch finds it (REV14 feeds 3), then removes it. Each folder in
    /// it, named after an article's file, holds the file, its text, or both.
    ///
    /// With `package`, the package of a row the library still lists as
    /// downloaded, whose Delete Download was refused and whose files could
    /// not go back (FEED_DOWNLOAD_HELD_ASIDE), each that the package lacks
    /// goes back into it, by rename, so its row has its file again. What is
    /// left belongs to no row: a deletion that went ahead, cut short by a
    /// crash, or a copy whose package has its own. Each folder of it goes
    /// through `remove`, the listener's own removal, to the Trash or for
    /// good as Removal Behavior says, under its own name, never the holder's
    /// hidden one, so the Trash shows it. Empty folders, and a stray hidden
    /// file such as .DS_Store, go with the holder.
    /// - Throws: why something could not go back, or be removed; what is
    ///   left stays in the holder, for the next launch.
    @MainActor
    static func sweepHolder(_ holder: URL, puttingBackInto package: URL?, remove: @MainActor (URL) throws -> Void) throws -> HolderSweep {
        var sweep = HolderSweep()
        let fileManager = FileManager.default
        for name in try listedEntryNames(of: holder) where !name.hasPrefix(".") {
            let together = holder.appendingPathComponent(name)
            var isFolder: ObjCBool = false
            if let package, fileManager.fileExists(atPath: together.path, isDirectory: &isFolder), isFolder.boolValue {
                for entry in try listedEntryNames(of: together) where !entry.hasPrefix(".") {
                    let destination = package.appendingPathComponent(entry)
                    guard !MaintenanceFileAccess.hasItem(at: destination) else { continue }
                    try fileManager.moveItem(at: together.appendingPathComponent(entry), to: destination)
                    sweep.putBack.append(entry)
                }
            }
            if holdsFiles(together) {
                try remove(together)
                sweep.removed.append(name)
            } else {
                try fileManager.removeItem(at: together)
            }
        }
        try fileManager.removeItem(at: holder)
        return sweep
    }

    /// Removes what `removal` says from the data directory at `root`, for
    /// good, without downloading anything, as the engine's rules do: the
    /// file and what it made, keeping the package with what stays in it
    /// (`staysWithoutTheFile(_:)`, an article's content.md among it), or the
    /// whole package. A file or package already gone counts as removed.
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
    /// (`staysWithoutTheFile(_:)`). The record and the content index are
    /// written anew, and so is content.md: an article's from its new file,
    /// as every import writes it, and an audiobook's from its transcript
    /// when the episode opens (`TranscriptTextLoader`), or found stale when
    /// the new file's audio differs.
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

    /// The text the kept package at `package` holds, its content.md's
    /// bytes, read without downloading anything; nil when it has none.
    /// - Throws: why a content.md that is there could not be read, as one
    ///   only in the cloud: the download then fails, and the kept package
    ///   stays as it was, so no edit in it is lost.
    static func keptText(of package: URL) throws -> Data? {
        let text = TextMouthPaths.contentMarkdownPath(in: package)
        do {
            return try DatalessFiles.withoutDownloading { try Data(contentsOf: text) }
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }

    /// The text the kept audiobook package at `package` holds that its
    /// record's transcript layer does not account for, or nil when there is
    /// none: its content.md's bytes when they differ from the digest the
    /// layer recorded for the content.md it wrote
    /// (`BookContentTranscriptIndex.textCacheFingerprint`), as a save made
    /// to the text of an episode whose download a rule had meanwhile
    /// removed leaves it (the editing session found no row, so no check
    /// took the save). Nil too for a package with no transcript layer, no
    /// record, or no content.md; a record that cannot be read for another
    /// reason than its being in the cloud counts as none. Nothing is
    /// downloaded.
    /// - Throws: why a content.md that is there could not be read
    ///   (`keptText(of:)`), or that the record is only in the cloud: the
    ///   download then fails, and the kept package stays as it was, so no
    ///   save in it is lost.
    static func unrecordedTranscriptText(of package: URL) throws -> Data? {
        let layer: BookContentTranscriptIndex?
        do {
            layer = try DatalessFiles.withoutDownloading { try BookInfo.load(from: package) }.contentIndex?.transcript
        } catch where DatalessFiles.isDownloadRefusal(error) {
            throw error
        } catch {
            // A record that is missing or damaged says nothing about the text.
            return nil
        }
        guard let recorded = layer?.textCacheFingerprint.cache.digest,
              let text = try keptText(of: package),
              FingerprintHasher.md5.digestOfData(text) != recorded else { return nil }
        return text
    }

    /// Keeps `earlier`, the text a kept package held, in `staged`, the
    /// package a new download of its article built, as an `.edited-` copy
    /// beside the new text, whenever the two differ (REV11): the new text is
    /// written from the new file, and the earlier one may hold an edit made
    /// with Edit Text before feed items lost it, which the engine's rules
    /// kept. A copy of the same bytes already there, carried over from the
    /// kept package, serves (`BookTextEditSessions.keepCopy(of:bytes:)`).
    /// - Returns: The copy kept, or nil when none was needed.
    /// - Throws: `FeedItemPackageError.earlierTextNotKept` when no copy
    ///   could be written: the download then fails, and the kept package,
    ///   with its text, stays as it was.
    @discardableResult
    static func keepEarlierText(_ earlier: Data?, in staged: URL) throws -> URL? {
        guard let earlier else { return nil }
        let text = TextMouthPaths.contentMarkdownPath(in: staged)
        guard (try? Data(contentsOf: text)) != earlier else { return nil }
        guard let copy = BookTextEditSessions.keepCopy(of: text, bytes: earlier) else {
            throw FeedItemPackageError.earlierTextNotKept
        }
        return copy
    }

    /// Puts the package `staging` built in place of the kept package at
    /// `kept`, which a new download of its item replaces: in one swap of
    /// the two folders where the volume allows it (`swap`, which only a test
    /// gives), after which the kept package is at the staged name, where
    /// `staging.discard()` removes it.
    ///
    /// On a volume that cannot swap two folders, one FEED_PACKAGE_SWAP_FAILED
    /// line gives the swap's errno, and the kept package steps aside, under
    /// a hidden name made from its own (`setAsideURL(of:)`), while the new
    /// one is published; it goes once the new one is, or comes back when the
    /// new one cannot be. A crash in between leaves it there for the item's
    /// next download to put right (`recoverSetAside(of:)`). With no package
    /// at `kept`, the new one is published as any import's is.
    /// - Throws: why the new package could not be put in place; the kept
    ///   package is then where it was.
    static func putInPlace(
        _ staging: ImportStaging,
        of kept: URL,
        swap: (URL, URL) -> Int32? = swapItems
    ) throws {
        guard FileManager.default.fileExists(atPath: kept.path) else {
            try staging.publish()
            return
        }
        guard let failure = swap(staging.directory, kept) else { return }
        DiagnosticLog.event(
            .feeds,
            "FEED_PACKAGE_SWAP_FAILED: \(kept.lastPathComponent): errno \(failure) (\(String(cString: strerror(failure)))); "
                + "the kept package steps aside while the new one is published"
        )
        let aside = setAsideURL(of: kept)
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
    /// (`renamex_np` with `RENAME_SWAP`): nil once it did, or the errno that
    /// kept it from it, as ENOTSUP on a volume that cannot swap two folders,
    /// which leaves both where they were.
    static func swapItems(_ first: URL, _ second: URL) -> Int32? {
        first.withUnsafeFileSystemRepresentation { from in
            second.withUnsafeFileSystemRepresentation { to in
                guard let from, let to else { return EINVAL }
                return renamex_np(from, to, UInt32(RENAME_SWAP)) == 0 ? nil : errno
            }
        }
    }

    // MARK: A Kept Package Set Aside

    /// What begins the hidden name a kept package stands aside under while
    /// a new one is published in its place (`setAsideURL(of:)`).
    static let setAsidePrefix = ".replaced-"

    /// Where `putInPlace(_:of:swap:)` sets aside the kept package at `kept`
    /// on a volume that cannot swap two folders: beside it, under its own
    /// name after `setAsidePrefix`, so the item's next download finds it
    /// after a crash. Hidden, it is no package of the feed's folder
    /// (`isPackageName(_:)`, `FeedIndexFiles`).
    static func setAsideURL(of kept: URL) -> URL {
        kept.deletingLastPathComponent().appendingPathComponent(setAsidePrefix + kept.lastPathComponent, isDirectory: true)
    }

    /// Puts right what a crash during `putInPlace(_:of:swap:)`'s fallback
    /// left of the kept package at `kept`, before a new download of its item
    /// reads it, each case in one line of the debug log; both are looked for
    /// by their metadata alone, so nothing is downloaded:
    ///
    /// - set aside, with nothing in its place: the crash came before the new
    ///   package was published, so the kept one moves back, with what it
    ///   holds (FEED_PACKAGE_PUT_BACK);
    /// - set aside, with a package in its place: the crash came once the new
    ///   package was published, which holds everything the kept one kept,
    ///   so the one set aside is a leftover, and goes
    ///   (FEED_PACKAGE_SET_ASIDE_REMOVED). One that cannot go stays
    ///   (FEED_PACKAGE_SET_ASIDE_LEFT), and only a volume that cannot swap
    ///   two folders then fails the download, needing its name.
    /// - Throws: why a kept package set aside could not move back: the
    ///   download then fails, rather than publish a package without what the
    ///   kept one holds.
    static func recoverSetAside(of kept: URL) throws {
        let aside = setAsideURL(of: kept)
        guard MaintenanceFileAccess.hasItem(at: aside) else { return }
        guard MaintenanceFileAccess.hasItem(at: kept) else {
            try FileManager.default.moveItem(at: aside, to: kept)
            DiagnosticLog.event(
                .feeds,
                "FEED_PACKAGE_PUT_BACK: \(kept.lastPathComponent): the kept package a download set aside before it stopped is back in its place"
            )
            return
        }
        do {
            try FileManager.default.removeItem(at: aside)
            DiagnosticLog.event(
                .feeds,
                "FEED_PACKAGE_SET_ASIDE_REMOVED: \(kept.lastPathComponent): the kept package a download set aside, left beside "
                    + "the one it published before it stopped, is gone"
            )
        } catch {
            DiagnosticLog.event(
                .feeds,
                "FEED_PACKAGE_SET_ASIDE_LEFT: \(kept.lastPathComponent): the kept package a download set aside could not be "
                    + "removed: \(error.localizedDescription)"
            )
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
    /// The rows whose files stayed, each with why: each is back where it
    /// was, among the library's books, or on its feed's shelf for a row kept
    /// there after its file went (`FeedFileRemoval.wasOnShelf`).
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
    /// A new download of an article could not keep its earlier text beside
    /// the new one (REV11): the download fails, and the kept package stays
    /// as it was.
    case earlierTextNotKept

    var errorDescription: String? {
        switch self {
        case .notAFeedPackage:
            return "This download isn't where its feed keeps its downloads, so TextMouth left its files as they are."
        case .indexNotWritten:
            return "TextMouth couldn't save its list of this feed's downloads, so the download was kept. "
                + "Try again once the library can be saved."
        case .staysInItsFeed:
            return "It belongs to its feed while it is downloaded. Delete Download removes its file and keeps its place and bookmarks."
        case .earlierTextNotKept:
            return "TextMouth couldn't keep the article's earlier text beside the new download, so it kept the article as it was."
        }
    }
}
