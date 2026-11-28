import Foundation

extension SyncMerge {
    /// What the merged state `winners` does to `library`: the library as it
    /// becomes, the books another device added (their rows, for the host to
    /// give a placeholder package), the books to remove, and which keys were
    /// applied. Pure: the same registers and library always give the same
    /// answer, and applying the same registers again to the library it gave
    /// changes nothing.
    ///
    /// - Parameters:
    ///   - voices: the voices this device has; a book's voice is applied only
    ///     if it is one of them (nil: every voice counts as there). A voice
    ///     the device lacks leaves the book's own voice as it is.
    ///   - feeds: this device's subscriptions (FR56), or nil when the host has none to give yet:
    ///     no feed key is then applied, and `SyncFeedApplication.waitsForFeeds` says whether any waits.
    /// - Note: In `SyncApplication.library` the books to remove are gone and
    ///   the reading list names the books to add, whose rows the host adds
    ///   (so the list is whole once it has). A new book's row has no
    ///   package: its `filePath` and `tmbDirectoryName` are empty, for the
    ///   host to fill when it makes the placeholder.
    static func apply(_ winners: SyncRegisters, to library: Library, feeds: [Feed]? = nil, voices: Set<String>?) -> SyncApplication {
        var applier = SyncApplier(entries: winners.entries, source: library, feeds: feeds, voices: voices)
        return applier.run()
    }
}

/// The work of `SyncMerge.apply`, kept in a value so each step is a small function.
private struct SyncApplier {
    let entries: [SyncKey: SyncEntry]
    let source: Library
    /// This device's subscriptions, or nil when the host gave none (FR56).
    let sourceFeeds: [Feed]?
    let voices: Set<String>?

    /// The library as it is being made.
    var library: Library
    var plan: SyncFolderPlan
    var booksToAdd: [SyncNewBook] = []
    var booksToRemove: [UUID] = []
    var movesPackages = false
    var entriesToRecord: [SyncKey: JSONValue] = [:]
    var appliedKeys: Set<SyncKey> = []
    var feeds = SyncFeedApplication()

    /// The winning entries of each book, by book.
    private let entriesOfBook: [UUID: [SyncKey: SyncEntry]]
    /// The winning entries of each feed, by feed and field.
    private let entriesOfFeed: [UUID: [SyncFeedField: SyncEntry]]

    init(entries: [SyncKey: SyncEntry], source: Library, feeds: [Feed]?, voices: Set<String>?) {
        self.entries = entries
        self.source = source
        sourceFeeds = feeds
        self.voices = voices
        library = source
        plan = SyncFolderPlan(library: source, entries: entries)
        var grouped: [UUID: [SyncKey: SyncEntry]] = [:]
        var groupedFeeds: [UUID: [SyncFeedField: SyncEntry]] = [:]
        for (key, entry) in entries {
            if let book = key.bookID { grouped[book, default: [:]][key] = entry }
            if case .feed(let feed, let field) = key { groupedFeeds[feed, default: [:]][field] = entry }
        }
        entriesOfBook = grouped
        entriesOfFeed = groupedFeeds
    }

    /// Applies folders, books, the reading list, and the feeds, in that order:
    /// a feed lands in a folder the folders' step has made.
    mutating func run() -> SyncApplication {
        applyFolders()
        applyBooks()
        applyReadingList()
        applyFeeds()
        return SyncApplication(
            library: library, booksToAdd: booksToAdd, booksToRemove: booksToRemove,
            movesPackages: movesPackages, entriesToRecord: entriesToRecord, appliedKeys: appliedKeys,
            feeds: feeds
        )
    }

    // MARK: - Folders

    /// Puts the planned folders in the library, with the sort settings of the folders that moved.
    private mutating func applyFolders() {
        entriesToRecord.merge(plan.entriesToRecord, uniquingKeysWith: { _, new in new })
        appliedKeys.formUnion(plan.appliedKeys)
        guard plan.changesFolders else { return }
        library.folders = plan.folders
        movesPackages = true
        // A folder's sort setting is named by its path, so it follows the folder.
        var settings: [String: FolderSortSetting] = [:]
        for (path, setting) in source.folderSortSettings {
            if plan.removedPaths.contains(path) { continue }
            settings[plan.renamedPaths[path] ?? path] = setting
        }
        library.folderSortSettings = settings
    }

    // MARK: - Books

    /// Whether a book's removal mark stands: it is later than every other entry of the book.
    private func isRemoved(_ id: UUID) -> Bool {
        guard let mark = entries[.book(id, .presence)], mark.value == .null else { return false }
        let later = (entriesOfBook[id] ?? [:]).values.contains { entry in
            if case .book(_, .presence) = entry.key { return false }
            // Only keeping a book is a sign it is wanted; stopping to keep it is not.
            if case .book(_, .keep) = entry.key, entry.value != .bool(true) { return false }
            // A bookmark or list place that was only removed is no sign the book lives. A Keep on
            // All Devices that came later is one: a person wanted the book.
            if entry.key.marksRemoval(entry.value) { return false }
            return entry.stamp > mark.stamp
        }
        return !later
    }

    /// Removes the books that were removed, changes the others, and adds the books other devices made.
    private mutating func applyBooks() {
        let index = SyncFolderIndex(source.folders)
        var removed: [UUID] = []
        for position in library.books.indices {
            let book = library.books[position]
            if book.isFeedItem { continue }
            if isRemoved(book.id) {
                removed.append(book.id)
                appliedKeys.insert(.book(book.id, .presence))
                continue
            }
            let updated = apply(to: book, folderID: index.id(atPath: book.folderPath))
            if updated != book { library.books[position] = updated }
        }
        booksToRemove = removed.sorted { $0.uuidString < $1.uuidString }
        for id in booksToRemove {
            library.removeBook(id: id)
            movesPackages = true
        }
        addNewBooks()
    }

    /// Changes `book`, a row of this library, to what the winners say.
    private mutating func apply(to book: Book, folderID: UUID?) -> Book {
        var book = book
        let id = book.id
        // The details and settings, each only when its value differs.
        for field in SyncBookValues.rowFields {
            guard let entry = entries[.book(id, field)] else { continue }
            if field == .voice, let voice = entry.value.stringValue, let voices, !voices.contains(voice) { continue }
            if let local = SyncBookValues.value(of: field, in: book), !SyncValueCoding.isSame(local, entry.value, for: entry.key) {
                guard SyncBookValues.set(field, to: entry.value, in: &book) else { continue }
            }
            if entry.byHand, let edited = SyncBookValues.metadataField(of: field), book.handEdits?.contains(edited) != true {
                book.markEditedByHand([edited])
            }
            appliedKeys.insert(entry.key)
        }
        applyFolder(to: &book, folderID: folderID)
        applyBookmarks(to: &book)
        if let mark = entries[.book(id, .presence)], mark.key.marksRemoval(mark.value) {
            // A later change brought the book back: say so, so that the removal does not stand.
            entriesToRecord[.book(id, .presence)] = .bool(true)
        } else {
            appliedKeys.insert(.book(id, .presence))
        }
        return book
    }

    /// Moves `book` to the folder the winners and the folder plan say.
    private mutating func applyFolder(to book: inout Book, folderID: UUID?) {
        var target = folderID
        let entry = entries[.book(book.id, .folder)]
        if let entry {
            switch entry.value {
            case .null: target = nil
            case .string:
                // A folder nothing knows leaves the book where it is.
                guard let named = SyncValueCoding.uuid(from: entry.value), plan.knows(named) else { return }
                target = named
            default: return
            }
        } else if target == nil {
            return
        }
        let path = plan.path(landingOf: target)
        if book.folderPath != path {
            book.folderPath = path
            movesPackages = true
        }
        if let entry { appliedKeys.insert(entry.key) }
    }

    /// Adds, changes, and removes the bookmarks of `book` as the winners say.
    private mutating func applyBookmarks(to book: inout Book) {
        var changed = false
        var removedIDs = Set<UUID>()
        // Where each bookmark of the row is, found once for all the entries.
        var positions: [UUID: Int] = [:]
        for (place, bookmark) in book.bookmarks.enumerated() { positions[bookmark.id] = place }
        for (key, entry) in entriesOfBook[book.id] ?? [:] {
            guard case .bookmark(_, let bookmarkID) = key else { continue }
            appliedKeys.insert(key)
            let position = positions[bookmarkID]
            if entry.value == .null {
                if position != nil { removedIDs.insert(bookmarkID); changed = true }
                continue
            }
            guard let value = SyncValueCoding.decode(SyncBookmarkValue.self, from: entry.value) else {
                appliedKeys.remove(key)
                continue
            }
            if let position {
                // Only a bookmark that differs is replaced, keeping the keys it holds that this version does not know.
                if !SyncValueCoding.isSame(SyncValueCoding.json(SyncBookmarkValue(book.bookmarks[position])), entry.value, for: key) {
                    var bookmark = book.bookmarks[position]
                    bookmark.chapterIndex = value.chapterIndex
                    bookmark.characterOffset = value.characterOffset
                    bookmark.label = value.label
                    bookmark.dateCreated = value.dateCreated
                    bookmark.anchor = value.anchor
                    book.bookmarks[position] = bookmark
                    changed = true
                }
            } else {
                book.bookmarks.append(value.bookmark(id: bookmarkID, number: 0))
                changed = true
            }
        }
        guard changed else { return }
        book.bookmarks.removeAll { removedIDs.contains($0.id) }
        // Numbered by date, then ID, so every device numbers them alike.
        book.bookmarks.sort { ($0.dateCreated, $0.id.uuidString) < ($1.dateCreated, $1.id.uuidString) }
        for number in book.bookmarks.indices { book.bookmarks[number].number = number + 1 }
    }

    // MARK: - New books

    /// Makes a row for each live book that another device added and this library lacks.
    private mutating func addNewBooks() {
        let known = Set(source.books.map(\.id))
        let ownHashes = Set(source.books.filter { !$0.isFeedItem }.map(\.md5Hash))
        // A candidate with the keys and records applying it made, which count only if it is offered.
        var candidates: [(new: SyncNewBook, keys: Set<SyncKey>, records: [SyncKey: JSONValue])] = []
        for (id, group) in entriesOfBook where !known.contains(id) {
            guard let presence = group[.book(id, .presence)], presence.value != .null || !isRemoved(id),
                  let contentEntry = group[.book(id, .content)],
                  let content = SyncValueCoding.decode(SyncContent.self, from: contentEntry.value) else { continue }
            // A book this library has under another ID (imported on both devices) stays one book here.
            if !content.md5Hash.isEmpty, ownHashes.contains(content.md5Hash) { continue }
            var book = Book(
                id: id, title: "", format: content.format, filePath: "", md5Hash: content.md5Hash,
                dateAdded: content.dateAdded, totalWordCount: content.totalWordCount, audioDuration: content.audioDuration
            )
            // Applying the entries notes keys and records; set what was noted before aside, so that
            // what this candidate notes can be kept or dropped with it.
            let notedKeys = appliedKeys, notedRecords = entriesToRecord
            appliedKeys = []
            entriesToRecord = [:]
            book = apply(to: book, folderID: nil)
            let keys = appliedKeys.union([.book(id, .content)]), records = entriesToRecord
            appliedKeys = notedKeys
            entriesToRecord = notedRecords
            candidates.append((SyncNewBook(book: book, content: content), keys, records))
        }
        // Oldest first, so every device adds them in one order; of two that are one book (the same
        // file, imported on two devices) the older is offered and the other is left out.
        var seenHashes = Set<String>()
        let offered = candidates
            .sorted { ($0.new.content.dateAdded, $0.new.book.id.uuidString) < ($1.new.content.dateAdded, $1.new.book.id.uuidString) }
            .filter { $0.new.content.md5Hash.isEmpty || seenHashes.insert($0.new.content.md5Hash).inserted }
        // A copy that was left out is no book of this library: none of its keys is applied.
        for candidate in offered {
            appliedKeys.formUnion(candidate.keys)
            entriesToRecord.merge(candidate.records, uniquingKeysWith: { _, new in new })
        }
        booksToAdd = offered.map { $0.new }
        if !booksToAdd.isEmpty { movesPackages = true }
    }

    // MARK: - The reading list

    /// Orders the reading list by the winners' keys, and sets its options.
    private mutating func applyReadingList() {
        let present = Set(library.books.filter { !$0.isFeedItem }.map(\.id)).union(booksToAdd.map(\.book.id))
        var keyed: [SyncOrderKey.SortKey: UUID] = [:]
        var withEntry = Set<UUID>()
        for (key, entry) in entries {
            guard case .readingList(let book) = key, present.contains(book) else { continue }
            appliedKeys.insert(key)
            withEntry.insert(book)
            if let order = entry.value.stringValue {
                keyed[SyncOrderKey.SortKey(key: order, id: book.uuidString)] = book
            }
        }
        // Books the winners place, in key order; then this library's own, which they say nothing of.
        var order = keyed.keys.sorted().compactMap { keyed[$0] }
        order += source.readingList.bookIDs.filter { present.contains($0) && !withEntry.contains($0) }

        var list = ReadingList(
            bookIDs: order,
            continuation: option(.continuation).flatMap { $0.stringValue.flatMap(ReadingList.Continuation.init(rawValue:)) } ?? source.readingList.continuation,
            skipsFinished: option(.skipsFinished).flatMap(flag(in:)) ?? source.readingList.skipsFinished,
            removesFinished: option(.removesFinished).flatMap(flag(in:)) ?? source.readingList.removesFinished
        )
        list.unknownKeys = source.readingList.unknownKeys
        library.readingList = list
    }

    /// The winning value of a reading list option, noting that it was applied.
    private mutating func option(_ option: SyncListOption) -> JSONValue? {
        guard let entry = entries[.readingListOption(option)] else { return nil }
        appliedKeys.insert(entry.key)
        return entry.value
    }

    /// The flag a value holds, or nil for any other value.
    private func flag(in value: JSONValue) -> Bool? {
        if case .bool(let flag) = value { return flag }
        return nil
    }

    // MARK: - Feeds (FR56)

    /// Changes this device's feeds as the winners say, removes the ones another
    /// device deleted, and adds the ones another device subscribed to. With no
    /// feeds from the host nothing is applied, and the application says whether
    /// any feed key waits.
    private mutating func applyFeeds() {
        guard let sourceFeeds else {
            feeds.waitsForFeeds = !entriesOfFeed.isEmpty
            return
        }
        var removed: [UUID] = []
        // This device's feeds as the merge leaves them, which the new ones are measured against.
        var staying: [Feed] = []
        for feed in sourceFeeds {
            let group = entriesOfFeed[feed.id] ?? [:]
            if isFeedRemoved(group) {
                removed.append(feed.id)
                appliedKeys.insert(.feed(feed.id, .presence))
                continue
            }
            let updated = apply(group, to: feed)
            if updated != feed { feeds.feedsToChange.append(updated) }
            staying.append(updated)
        }
        feeds.feedsToRemove = removed.sorted { $0.uuidString < $1.uuidString }
        feeds.feedsToChange.sort { $0.id.uuidString < $1.id.uuidString }
        addNewFeeds(besides: staying, known: Set(sourceFeeds.map(\.id)))
    }

    /// Whether a feed's removal mark stands: it is later than every other entry of the feed.
    private func isFeedRemoved(_ group: [SyncFeedField: SyncEntry]) -> Bool {
        guard let mark = group[.presence], mark.value == .null else { return false }
        return !group.values.contains { $0.key != mark.key && $0.stamp > mark.stamp }
    }

    /// `feed`, a subscription of this device, with the winners' values of its
    /// synced fields, each only where it differs, and its folder where the
    /// folder plan lands it.
    private mutating func apply(_ group: [SyncFeedField: SyncEntry], to feed: Feed) -> Feed {
        var feed = feed
        for field in SyncFeedValues.feedFields {
            guard let entry = group[field] else { continue }
            let local = SyncFeedValues.value(of: field, in: feed)
            if !SyncValueCoding.isSame(local, entry.value, for: entry.key) {
                // A value this TextMouth can't hold leaves the feed's own, and is offered again.
                guard SyncFeedValues.set(field, to: entry.value, in: &feed) else { continue }
            }
            appliedKeys.insert(entry.key)
        }
        applyFolder(group[.folder], to: &feed)
        if let mark = group[.presence], mark.key.marksRemoval(mark.value) {
            // A later change brought the feed back: say so, so that the removal does not stand.
            entriesToRecord[.feed(feed.id, .presence)] = .bool(true)
        } else if group[.presence] != nil {
            appliedKeys.insert(.feed(feed.id, .presence))
        }
        if let subscribed = group[.subscribed] { appliedKeys.insert(subscribed.key) }
        return feed
    }

    /// Moves `feed` to the folder its winning entry names, or, with none, after
    /// its own folder where that was folded into another or removed: a feed lists
    /// its episodes in the live folder the plan lands it in. A folder that lands
    /// nowhere (the top level) leaves the feed where it is, since a feed needs a
    /// folder of its own.
    private mutating func applyFolder(_ entry: SyncEntry?, to feed: inout Feed) {
        let named = entry.flatMap { SyncValueCoding.uuid(from: $0.value) }
        guard let target = plan.landing(named ?? feed.folderID) else { return }
        feed.folderID = target
        if let entry, named != nil { appliedKeys.insert(entry.key) }
    }

    /// Adds a record for each live feed another device subscribed to and this
    /// device lacks, once its address, date, and folder have arrived and the
    /// folder lands in a live one. A feed whose address this device subscribes
    /// already is not added (the same feed subscribed on both devices stays one
    /// here), and of two new feeds of one address the older, then the lower ID,
    /// is added, so every device adds the same one. Nor is a feed added to a
    /// folder another feed lists in (two feeds of one title, subscribed apart,
    /// whose same-named folders the plan folded into one): a folder lists one
    /// feed's episodes (`FeedStore.feed(inFolder:)`), so it waits, its keys unapplied.
    /// - Parameters:
    ///   - local: this device's feeds as the merge leaves them.
    ///   - known: the IDs of every feed this device has, the removed ones among them.
    private mutating func addNewFeeds(besides local: [Feed], known: Set<UUID>) {
        // A candidate with the keys it applies, and whether a later change brought it back from a removal.
        var candidates: [(feed: Feed, keys: Set<SyncKey>, revives: Bool)] = []
        for (id, group) in entriesOfFeed where !known.contains(id) {
            guard let presence = group[.presence], !isFeedRemoved(group),
                  let folderValue = group[.folder], let named = SyncValueCoding.uuid(from: folderValue.value),
                  let folderID = plan.landing(named) else { continue }
            guard let feed = SyncFeedValues.makeFeed(id: id, values: group.mapValues(\.value), folderID: folderID) else { continue }
            var keys = Set(group.values.map(\.key))
            // A value this TextMouth can't hold (a later TextMouth's choice) is not applied.
            for field in SyncFeedValues.feedFields where field != .address {
                guard let entry = group[field] else { continue }
                var probe = feed
                if !SyncFeedValues.set(field, to: entry.value, in: &probe) { keys.remove(entry.key) }
            }
            let revives = presence.value == .null
            if revives { keys.remove(presence.key) }
            candidates.append((feed, keys, revives))
        }
        var seen = Set(local.map { FeedAddress.comparisonKey($0.feedURL) })
        var usedFolders = Set(local.map(\.folderID))
        let offered = candidates
            .sorted { ($0.feed.subscribedDate, $0.feed.id.uuidString) < ($1.feed.subscribedDate, $1.feed.id.uuidString) }
            .filter { candidate in
                guard !usedFolders.contains(candidate.feed.folderID),
                      seen.insert(FeedAddress.comparisonKey(candidate.feed.feedURL)).inserted else { return false }
                usedFolders.insert(candidate.feed.folderID)
                return true
            }
        // A copy that was left out is no feed of this device: none of its keys is applied.
        for candidate in offered {
            appliedKeys.formUnion(candidate.keys)
            // A later change brought the feed back: say so, so that the removal does not stand.
            if candidate.revives { entriesToRecord[.feed(candidate.feed.id, .presence)] = .bool(true) }
        }
        feeds.feedsToAdd = offered.map(\.feed)
    }
}
