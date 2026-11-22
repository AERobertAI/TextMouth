import Foundation

// MARK: - Conflict Copies of the Library's Files (Phase 0 of the local-first design)

/// Which file names a sync service gives the copy it sets aside when two
/// Macs wrote one file, so the library's conflict copies can be told from
/// its own files. The names are the ones the October 2026 cloud tests and
/// `MultiMacCrashSafetyTests` found:
///
/// - iCloud Drive: "library 2.json", "library 3.json";
/// - Google Drive: "library (1).json", "library (2).json";
/// - Dropbox: "library (Galley's conflicted copy 2026-10-03).json", with
///   " (1)" after it for a second one that day, and "library (Case
///   Conflict).json" for names that differ only in case.
enum ConflictCopyNames {
    /// What may stand between a file's name and its extension in a conflict
    /// copy's name, whole.
    private static let suffixPattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^( [0-9]+| \([0-9]+\)| \(.+ conflicted copy [0-9]{4}-[0-9]{2}-[0-9]{2}\)( \([0-9]+\))?| \(Case Conflict( [0-9]+)?\))$"#
    )

    /// Whether the file named `name` is a sync service's conflict copy of the
    /// file named `original`: the same name and extension, with only a
    /// service's suffix added between them. The file itself is not one.
    static func isConflictCopy(_ name: String, of original: String) -> Bool {
        let stem = (original as NSString).deletingPathExtension
        let suffix = original.contains(".") ? "." + (original as NSString).pathExtension : ""
        guard name != original, name.hasPrefix(stem), name.hasSuffix(suffix),
              name.count > stem.count + suffix.count else { return false }
        let middle = String(name.dropFirst(stem.count).dropLast(suffix.count))
        let range = NSRange(middle.startIndex..., in: middle)
        return suffixPattern?.firstMatch(in: middle, range: range) != nil
    }
}

/// An unresolved version a sync service keeps of one file (iCloud Drive's
/// conflicting versions), as far as TextMouth tells them.
struct ConflictVersion: Equatable, Sendable {
    /// The computer that saved it, as the sync service names it.
    var computerName: String?
    /// When it was saved.
    var modified: Date?
}

/// One conflict copy of a library file that a sync service set aside, found
/// beside the file or as an unresolved version of it, and what it holds.
struct ConflictCopyFinding: Equatable, Sendable, Identifiable {
    /// What the file is.
    enum Subject: Equatable, Sendable {
        /// library.json.
        case libraryIndex
        /// A feed's record in the Feeds folder.
        case feedRecord
        /// A feed's own index of its packages, Feeds/<feed ID>/library.json.
        case feedIndex
        /// A book's record, bookInfo.json.
        case bookRecord
    }

    /// Where the copy is: its own file, or the file it is a version of.
    enum Place: Equatable, Sendable {
        /// A file of its own, named so (`ConflictCopyNames`), at this path.
        case file(path: String)
        /// A version the sync service keeps of the file at this path.
        case version(ConflictVersion, ofFileAt: String)
    }

    var subject: Subject
    var place: Place
    /// The report's sentence about it, which says what it holds and that
    /// nothing was merged or removed.
    var sentence: String
    /// The key by which it is remembered as reported: its path and the date
    /// it was saved, so a later conflict copy of the same name is a new one.
    var key: String

    var id: String { key }

    /// The folder to show for it in Finder: the one holding the copy or the
    /// file it is a version of.
    var folderPath: String {
        switch place {
        case .file(let path), .version(_, let path):
            return (path as NSString).deletingLastPathComponent
        }
    }
}

// MARK: - Finding Them

/// Finds the conflict copies in a library kept in a cloud location, off the
/// main thread, without downloading or changing anything: folders are
/// listed with downloads refused, and a copy is read only when it is on this
/// Mac already.
struct ConflictCopyFinder: Sendable {
    /// The sync service's word on each file, and where the library lives.
    var itemStatus: any CloudItemStatusProviding
    /// The unresolved versions of the file at a URL, where the sync service
    /// keeps them apart from the file (iCloud Drive's).
    var versions: @Sendable (URL) -> [ConflictVersion] = { ConflictCopyFinder.systemVersions(of: $0) }

    /// How deep a folder of the library may be searched for packages.
    private static let deepestFolder = 8

    /// Every conflict copy in the library at `root`, the index first, then
    /// the feeds' records, then the books' records. Nothing for a library
    /// that is not in a cloud location, where no sync service makes them.
    func findAll(in root: URL) -> [ConflictCopyFinding] {
        guard let provider = itemStatus.location(of: root).provider else { return [] }
        let service = provider.displayName
        var found: [ConflictCopyFinding] = []
        found += copies(of: root.appendingPathComponent("library.json"), subject: .libraryIndex, service: service)
        let feeds = FeedPaths.recordsFolder(in: root)
        for name in listing(feeds).sortedStably() {
            if let id = Self.feedID(ofCopyNamed: name) {
                let record = FeedPaths.recordFile(of: id, in: feeds)
                found += conflictCopyFindings(named: name, of: record, subject: .feedRecord, service: service)
            }
        }
        for record in feedRecordFiles(in: feeds) {
            found += versionFindings(of: record, subject: .feedRecord, service: service)
        }
        let feedItemFolders = feedFolders(in: feeds, of: root)
        // Each feed's own index holds its episodes' places and bookmarks.
        for folder in feedItemFolders {
            found += copies(of: folder.appendingPathComponent(FeedPaths.indexFileName), subject: .feedIndex, service: service)
        }
        for package in packages(in: [root.appendingPathComponent(TextMouthPaths.libraryFolderName, isDirectory: true)] + feedItemFolders) {
            let record = copies(of: TextMouthPaths.bookInfoPath(in: package), subject: .bookRecord, service: service)
            found += record
            // iCloud Drive syncs a package as one item, so its conflicts sit
            // on the package, whose files carry no flags: ask it too, unless
            // the record's own flags already reported a version.
            if !record.contains(where: { if case .version = $0.place { return true } else { return false } }) {
                found += versionFindings(of: package, subject: .bookRecord, service: service)
            }
        }
        return found
    }

    // MARK: One File

    /// The conflict copies of `file`, beside it, and its unresolved versions.
    private func copies(of file: URL, subject: ConflictCopyFinding.Subject, service: String) -> [ConflictCopyFinding] {
        let folder = file.deletingLastPathComponent()
        let original = file.lastPathComponent
        var found: [ConflictCopyFinding] = []
        for name in listing(folder).sortedStably() where ConflictCopyNames.isConflictCopy(name, of: original) {
            found += conflictCopyFindings(named: name, of: file, subject: subject, service: service)
        }
        return found + versionFindings(of: file, subject: subject, service: service)
    }

    /// The finding for the file named `name` beside `original`, which is a
    /// conflict copy of it.
    private func conflictCopyFindings(
        named name: String,
        of original: URL,
        subject: ConflictCopyFinding.Subject,
        service: String
    ) -> [ConflictCopyFinding] {
        let copy = original.deletingLastPathComponent().appendingPathComponent(name)
        let holds = describe(copy: copy, original: original, subject: subject)
        let modified = (try? copy.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let words = ConflictCopyWording.sentence(
            service: service,
            subject: subject,
            original: original.lastPathComponent,
            copyName: name,
            folder: original.deletingLastPathComponent().path,
            holds: holds
        )
        return [ConflictCopyFinding(
            subject: subject,
            place: .file(path: copy.path),
            sentence: words,
            key: "\(copy.path)|\(Int(modified?.timeIntervalSince1970 ?? 0))"
        )]
    }

    /// The findings for the unresolved versions the sync service keeps of
    /// `file`, when its status says there are any.
    private func versionFindings(of file: URL, subject: ConflictCopyFinding.Subject, service: String) -> [ConflictCopyFinding] {
        guard itemStatus.status(of: file).hasUnresolvedConflicts else { return [] }
        return versions(file).map { version in
            ConflictCopyFinding(
                subject: subject,
                place: .version(version, ofFileAt: file.path),
                sentence: ConflictCopyWording.versionSentence(service: service, subject: subject, file: file.lastPathComponent, version: version),
                key: "\(file.path)|version|\(version.computerName ?? "")|\(Int(version.modified?.timeIntervalSince1970 ?? 0))"
            )
        }
    }

    // MARK: Walking the Library

    /// The names in `folder`, listed with downloads refused; none when it
    /// is only in the cloud, or can't be listed.
    private func listing(_ folder: URL) -> [String] {
        DatalessFiles.withoutDownloading { (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] }
    }

    /// The feed whose record a conflict copy named `name` copies: a feed's
    /// ID, a suffix, and ".json".
    private static func feedID(ofCopyNamed name: String) -> UUID? {
        guard name.hasSuffix(".json"), name.count > 36 else { return nil }
        let id = String(name.prefix(36))
        guard let uuid = UUID(uuidString: id), uuid.uuidString == id else { return nil }
        return ConflictCopyNames.isConflictCopy(name, of: "\(id).json") ? uuid : nil
    }

    /// The feeds' record files in `folder`, by their names.
    private func feedRecordFiles(in folder: URL) -> [URL] {
        listing(folder).sortedStably().compactMap { name in
            FeedPaths.feedID(ofRecordNamed: name).map { FeedPaths.recordFile(of: $0, in: folder) }
        }
    }

    /// The folders of the feeds' own packages in the Feeds folder `folder` of
    /// the data directory at `root`, one for each feed.
    private func feedFolders(in folder: URL, of root: URL) -> [URL] {
        listing(folder).sortedStably().compactMap { name in
            FeedPaths.feedID(ofItemsFolderNamed: name).map { FeedPaths.itemsFolder(of: $0, in: root) }
        }
    }

    /// Every package, a folder named ".tmb", under `folders`, looking into
    /// folders that are not packages to a limited depth.
    private func packages(in folders: [URL], depth: Int = 0) -> [URL] {
        var found: [URL] = []
        for folder in folders {
            for name in listing(folder).sortedStably() where !name.hasPrefix(".") {
                let child = folder.appendingPathComponent(name, isDirectory: true)
                if name.hasSuffix(".tmb") {
                    found.append(child)
                } else if depth < Self.deepestFolder, isFolder(child) {
                    found += packages(in: [child], depth: depth + 1)
                }
            }
        }
        return found
    }

    /// Whether a folder, not a file, is at `url`.
    private func isFolder(_ url: URL) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue
    }

    // MARK: What a Copy Holds

    /// What the copy at `copy` holds, set against `original`, in words; both
    /// are read only when they are on this Mac already, since this runs at
    /// launch and downloads nothing.
    private func describe(copy: URL, original: URL, subject: ConflictCopyFinding.Subject) -> String {
        guard let copyBytes = bytesOnThisMac(copy) else {
            return ConflictCopyWording.notOnThisMac
        }
        let originalBytes = bytesOnThisMac(original)
        switch subject {
        case .libraryIndex:
            return ConflictCopyWording.libraryHolds(
                copy: try? LibraryPersistenceService.decodeIndex(from: copyBytes),
                original: originalBytes.flatMap { try? LibraryPersistenceService.decodeIndex(from: $0) }
            )
        case .bookRecord:
            return ConflictCopyWording.bookRecordHolds(
                copy: try? BookInfo.decodeRecordFile(copyBytes),
                original: originalBytes.flatMap { try? BookInfo.decodeRecordFile($0) }
            )
        case .feedIndex:
            // A feed's index is its own layout (a feed ID and rows, no folders).
            return ConflictCopyWording.feedIndexHolds(
                copy: try? FeedIndexFiles.decoded(copyBytes),
                original: originalBytes.flatMap { try? FeedIndexFiles.decoded($0) }
            )
        case .feedRecord:
            let decoder = FeedRecordCoding.decoder()
            return ConflictCopyWording.feedRecordHolds(
                copy: try? decoder.decode(FeedRecord.self, from: copyBytes),
                original: originalBytes.flatMap { try? decoder.decode(FeedRecord.self, from: $0) }
            )
        }
    }

    /// The bytes of the file at `file` when it is on this Mac, read without
    /// downloading; nil when it is only in the cloud or can't be read.
    private func bytesOnThisMac(_ file: URL) -> Data? {
        let state = itemStatus.status(of: file).state
        guard state == .downloaded || state == .local else { return nil }
        return DatalessFiles.withoutDownloading { try? Data(contentsOf: file) }
    }

    // MARK: The System's Versions

    /// iCloud Drive's unresolved versions of `file`: the ones
    /// `NSFileVersion` lists for a file in conflict. None where the system
    /// has none, and always none on iOS, whose app has no such listing.
    static func systemVersions(of file: URL) -> [ConflictVersion] {
        #if os(macOS)
        let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: file) ?? []
        return versions.map { ConflictVersion(computerName: $0.localizedNameOfSavingComputer, modified: $0.modificationDate) }
        #else
        return []
        #endif
    }
}

// MARK: - Remembering What Was Reported

/// The conflict copies this Mac has already reported, so each is reported
/// once and never again: a small file of this Mac's own (never in the data
/// directory, since another Mac reports for itself), holding each reported
/// copy's key, newest kept.
struct ConflictCopyMemory: Sendable {
    /// How many reported copies are kept in mind.
    static let limit = 500

    /// The file the memory is kept in.
    var file: URL

    /// The memory this Mac keeps.
    static var thisMac: ConflictCopyMemory {
        ConflictCopyMemory(file: MachineLocalPaths.conflictCopiesReported)
    }

    /// The reported keys, in the order they were reported; none for a file
    /// that is missing or unreadable.
    func reportedKeys() -> [String] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    /// The findings among `findings` not reported before.
    func unreported(_ findings: [ConflictCopyFinding]) -> [ConflictCopyFinding] {
        let known = Set(reportedKeys())
        return findings.filter { !known.contains($0.key) }
    }

    /// Notes `findings` as reported, keeping the newest `limit` keys. Failing
    /// to write only means they are reported again next time.
    func remember(_ findings: [ConflictCopyFinding]) {
        let known = reportedKeys()
        let keys = known + findings.map(\.key).filter { !known.contains($0) }
        guard let data = try? JSONEncoder().encode(Array(keys.suffix(Self.limit))) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

// MARK: - The Words

/// The sentences of the conflict report, each built in one place for the
/// alert, VoiceOver, and a braille display alike.
enum ConflictCopyWording {
    /// The alert's title.
    static var alertTitle: String {
        // Translators: Title of the alert that reports conflicting copies of the library's files, set aside by a sync service.
        InterfaceText.line("conflictCopy.alertTitle", "Conflicting Copies Found")
    }
    /// The alert's button that closes it, the default.
    static var okTitle: String {
        // Translators: Button that closes an alert and changes nothing.
        InterfaceText.line("common.ok", "OK")
    }
    /// The alert's button that shows the first copy's folder in Finder.
    static var showTitle: String {
        // Translators: Button that shows a file or folder in the Finder.
        InterfaceText.line("common.showInFinder", "Show in Finder")
    }
    /// What a copy not yet on this Mac holds, which TextMouth does not
    /// download to find out.
    static var notOnThisMac: String {
        // Translators: Part of the report of a conflicting copy: the copy's file is only in the cloud, so TextMouth did not download it to look inside. "It" is the copy.
        InterfaceText.line("conflictCopy.notOnThisMac", "Its contents aren't on this Mac yet, so TextMouth hasn't looked inside it.")
    }
    /// What is said last of every report: nothing was done.
    static var untouched: String {
        // Translators: Last sentence of the report of a conflicting copy: nothing was done with it. "It" is the copy.
        InterfaceText.line("conflictCopy.untouched", "TextMouth hasn't merged it or removed it.")
    }

    /// What the file called `file` is, in a sentence.
    private static func name(of subject: ConflictCopyFinding.Subject, file: String) -> String {
        switch subject {
        case .libraryIndex:
            // Translators: A phrase naming the library index file inside a sentence about a conflicting copy. %@ is the file's name, which stays as written.
            return InterfaceText.line("conflictCopy.name.libraryIndex", "the library index, \(file)")
        case .feedRecord:
            // Translators: A phrase naming a feed's record file inside a sentence about a conflicting copy. %@ is the file's name, which stays as written.
            return InterfaceText.line("conflictCopy.name.feedRecord", "a feed's record, \(file)")
        case .feedIndex:
            // Translators: A phrase naming a feed's index file inside a sentence about a conflicting copy. %@ is the file's name, which stays as written.
            return InterfaceText.line("conflictCopy.name.feedIndex", "a feed's index of its episodes, \(file)")
        case .bookRecord:
            // Translators: A phrase naming a book's record file inside a sentence about a conflicting copy. %@ is the file's name, which stays as written.
            return InterfaceText.line("conflictCopy.name.bookRecord", "a book's record, \(file)")
        }
    }

    /// The report of one conflict copy of the file called `original`.
    static func sentence(
        service: String,
        subject: ConflictCopyFinding.Subject,
        original: String,
        copyName: String,
        folder: String,
        holds: String
    ) -> String {
        SentenceWording.joined([
            // Translators: First sentence of the report of a conflicting copy. %1$@ is the sync service's name; %2$@ is a phrase naming the original file; %3$@ is the copy's name; %4$@ is the folder's path.
            InterfaceText.line("conflictCopy.setAsideConflicting", "\(service) set aside a conflicting copy of \(name(of: subject, file: original)): “\(copyName)”, in \(folder)."),
            holds,
            untouched,
        ])
    }

    /// The report of one unresolved version of a file.
    static func versionSentence(
        service: String,
        subject: ConflictCopyFinding.Subject,
        file: String,
        version: ConflictVersion
    ) -> String {
        let what = name(of: subject, file: file)
        let modified = version.modified?.formatted(date: .abbreviated, time: .shortened)
        // One whole sentence for each way of knowing where and when it was saved.
        let held: String
        switch (version.computerName, modified) {
        case let (computer?, modified?):
            // Translators: First sentence of the report of an unresolved version of a file. %1$@ is the sync service's name; %2$@ is a phrase naming the file; %3$@ is the name of the computer that saved it; %4$@ is the date and time it was saved.
            held = InterfaceText.line("conflictCopy.holdsVersionOnNameAndDate", "\(service) holds a conflicting version of \(what), saved on “\(computer)” on \(modified).")
        case let (computer?, nil):
            // Translators: First sentence of the report of an unresolved version of a file. %1$@ is the sync service's name; %2$@ is a phrase naming the file; %3$@ is the name of the computer that saved it.
            held = InterfaceText.line("conflictCopy.holdsVersionOnName", "\(service) holds a conflicting version of \(what), saved on “\(computer)”.")
        case let (nil, modified?):
            // Translators: First sentence of the report of an unresolved version of a file. %1$@ is the sync service's name; %2$@ is a phrase naming the file; %3$@ is the date and time it was saved.
            held = InterfaceText.line("conflictCopy.holdsVersionOnDate", "\(service) holds a conflicting version of \(what), saved on \(modified).")
        case (nil, nil):
            // Translators: First sentence of the report of an unresolved version of a file whose computer and time of saving are not known. %1$@ is the sync service's name; %2$@ is a phrase naming the file.
            held = InterfaceText.line("conflictCopy.holdsConflictingVersionSavedAnother", "\(service) holds a conflicting version of \(what), saved at another time.")
        }
        return SentenceWording.joined([held, untouched])
    }

    /// What a copy of the library index holds, set against the index itself.
    static func libraryHolds(copy: Library?, original: Library?) -> String {
        guard let copy else { return couldNotBeRead }
        guard let original else {
            // Translators: What a conflicting copy of the library index holds. %@ is its counts as a list, such as "3 books, 1 folder, and 2 books on the reading list".
            return InterfaceText.line("common.itHoldsValue", "It holds \(libraryCounts(copy)).")
        }
        // Translators: What a conflicting copy of the library index holds, set against the index itself. %1$@ and %2$@ are counts as a list, such as "3 books, 1 folder, and 2 books on the reading list". library.json is a file name and stays as written.
        return InterfaceText.line("conflictCopy.libraryHolds", "It holds \(libraryCounts(copy)); library.json holds \(libraryCounts(original)).")
    }

    /// Said of a copy that could not be read.
    private static var couldNotBeRead: String {
        // Translators: Part of the report of a conflicting copy: the copy's file could not be read. "It" is the copy.
        InterfaceText.line("conflictCopy.couldNotBeRead", "It couldn't be read.")
    }

    /// A library's counts in words: its books, folders, and the books on its reading list.
    private static func libraryCounts(_ library: Library) -> String {
        // Translators: A count of folders in a list of counts about a conflicting copy of the library. %lld is the number of folders.
        let folders = InterfaceText.line("conflictCopy.libraryCounts.folders", "\(number: library.folders.count) folders")
        // Translators: A count of the books on the reading list in a list of counts about a conflicting copy of the library. %lld is the number of books.
        let list = InterfaceText.line("conflictCopy.libraryCounts.reading", "\(number: library.readingList.bookIDs.count) books on the reading list")
        return CountWording.list([CountWording.books(library.libraryBookCount), folders, list])
    }

    /// What a copy of a book's record holds, set against the record itself.
    static func bookRecordHolds(copy: BookInfo?, original: BookInfo?) -> String {
        guard let copy else { return couldNotBeRead }
        guard let original else {
            // Translators: What a conflicting copy of a book's record holds. %1$@ is the book's title; %2$@ is the record's place and bookmarks, such as "chapter 3, saved Nov 18, 2026, and 2 bookmarks".
            return InterfaceText.line("conflictCopy.bookRecordHolds.ofBook", "It holds the record of “\(copy.metadata.title)”: \(recordState(copy)).")
        }
        // Translators: What a conflicting copy of a book's record holds, set against the record itself. %1$@ is the book's title; %2$@ and %3$@ are a record's place and bookmarks, such as "chapter 3, saved Nov 18, 2026, and 2 bookmarks".
        return InterfaceText.line("conflictCopy.bookRecordHolds.ofBookIndexHolds", "It holds the record of “\(copy.metadata.title)”: \(recordState(copy)); the record holds \(recordState(original)).")
    }

    /// A record's place and bookmarks in words.
    private static func recordState(_ info: BookInfo) -> String {
        let bookmarks = CountWording.bookmarks(info.bookmarks.count)
        guard let place = info.state.readingPosition else {
            // Translators: A record's place and bookmarks inside a sentence about a conflicting copy of a book's record: no reading place was saved. %@ is a count of bookmarks, such as "2 bookmarks".
            return InterfaceText.line("conflictCopy.recordState.place", "no place saved, and \(bookmarks)")
        }
        let saved = place.lastUpdated.formatted(date: .abbreviated, time: .shortened)
        // The chapter's number names the chapter, so it is written without digit grouping.
        // Translators: A record's place and bookmarks inside a sentence about a conflicting copy of a book's record. %1$@ is the chapter's number, an identifier written without digit grouping; %2$@ is the date and time the place was saved; %3$@ is a count of bookmarks, such as "2 bookmarks".
        return InterfaceText.line("conflictCopy.recordState.chapter", "chapter \(String(place.chapterIndex + 1)), saved \(saved), and \(bookmarks)")
    }

    /// What a copy of a feed's own index holds, set against the index itself.
    static func feedIndexHolds(copy: FeedIndex?, original: FeedIndex?) -> String {
        guard let copy else { return couldNotBeRead }
        guard let original else {
            // Translators: What a conflicting copy of a feed's index holds. %@ is a count of episodes, such as "12 episodes".
            return InterfaceText.line("common.itHoldsValue", "It holds \(CountWording.episodes(copy.books.count)).")
        }
        // Translators: What a conflicting copy of a feed's index holds, set against the index itself. %1$@ and %2$@ are counts of episodes, such as "12 episodes".
        return InterfaceText.line("conflictCopy.feedIndexHolds", "It holds \(CountWording.episodes(copy.books.count)); the index holds \(CountWording.episodes(original.books.count)).")
    }

    /// `count` items of a feed: "1 item", "2 items".
    private static func items(_ count: Int) -> String {
        // Translators: A count of a feed's items inside a sentence about a conflicting copy of the feed's record. %lld is the number of items.
        InterfaceText.line("common.countItems", "\(number: count) items")
    }

    /// What a copy of a feed's record holds, set against the record itself.
    static func feedRecordHolds(copy: FeedRecord?, original: FeedRecord?) -> String {
        guard let copy else { return couldNotBeRead }
        guard let original else {
            // Translators: What a conflicting copy of a feed's record holds. %1$@ is the feed's title; %2$@ is a count of items, such as "12 items".
            return InterfaceText.line("conflictCopy.feedRecordHolds.named", "It holds the feed “\(copy.feed.title)” with \(items(copy.items.count)).")
        }
        // Translators: What a conflicting copy of a feed's record holds, set against the record itself. %1$@ is the feed's title; %2$@ and %3$@ are counts of items, such as "12 items".
        return InterfaceText.line("conflictCopy.feedRecordHolds.namedIndexHolds", "It holds the feed “\(copy.feed.title)” with \(items(copy.items.count)); the record holds \(items(original.items.count)).")
    }

    /// The alert's message for `findings`: each one's sentence, a few at most
    /// and then how many more there are.
    static func message(for findings: [ConflictCopyFinding], shown limit: Int = 5) -> String {
        var parts = findings.prefix(limit).map(\.sentence)
        if findings.count > limit {
            // Translators: Last paragraph of the report of conflicting copies: how many more copies there are than the report names. %lld is the number of copies.
            parts.append(InterfaceText.line("conflictCopy.message", "And \(number: findings.count - limit) more copies, which the log lists."))
        }
        return parts.joined(separator: "\n\n")
    }
}
