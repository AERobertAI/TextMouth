import Foundation

// MARK: - The Row Speak Info and Book Info Act On (October 7, 2026)

/// The row of a Library window that Speak Info (Shift-Command-I) and Book Info
/// (Command-I) act on.
enum LibraryInfoRow: Equatable {
    /// A book's row.
    case book(Book)
    /// A folder's row.
    case folder(BookFolder)
    /// A feed's row in the Feeds section.
    case feed(FeedRowContent)

    /// The row's identity, as the List tags the row: its book's, folder's,
    /// or feed's ID. Speak Info ties each summary to the row it describes by
    /// it (REV07, Library finding 2), so a press on another row speaks that
    /// row's summary rather than only stopping the one speaking.
    var id: UUID {
        switch self {
        case .book(let book): return book.id
        case .folder(let folder): return folder.id
        case .feed(let row): return row.id
        }
    }

    /// The row a Library window's commands act on: the first selected row
    /// in the list's order, by the selection the List keeps, `selected`,
    /// which holds a folder's or a feed's row by its ID as it holds a
    /// book's, since each row's ID is its tag; or, when that selects none
    /// of the rows shown, the first book of the edit-mode selection; nil
    /// when nothing is selected.
    /// - Parameters:
    ///   - selected: The List's selection.
    ///   - editSelection: The edit-mode selection.
    ///   - folders: The folder rows shown, in order.
    ///   - feeds: The feed rows shown, in order.
    ///   - books: The book rows shown, in order.
    static func selected(
        _ selected: Set<UUID>,
        editSelection: Set<UUID>,
        folders: [BookFolder],
        feeds: [FeedRowContent],
        books: [Book]
    ) -> LibraryInfoRow? {
        if let folder = folders.first(where: { selected.contains($0.id) }) {
            return .folder(folder)
        }
        if let feed = feeds.first(where: { selected.contains($0.id) }) {
            return .feed(feed)
        }
        if let book = books.first(where: { selected.contains($0.id) }) {
            return .book(book)
        }
        if let book = books.first(where: { editSelection.contains($0.id) }) {
            return .book(book)
        }
        return nil
    }

    /// What Book Info (Command-I) does for this row: the Book Info sheet
    /// for a book; Feed Info for a feed's row, or for a feed's folder,
    /// whose feed `feedInFolder` names by the folder's ID; and, for any
    /// other folder, which has no sheet, its full summary spoken, as Speak
    /// Full Info speaks it, the summary nearest to a sheet's whole.
    func infoCommand(feedInFolder: (UUID) -> UUID?) -> LibraryInfoCommand {
        switch self {
        case .book(let book):
            return .bookInfo(book)
        case .feed(let row):
            return .feedInfo(row.id)
        case .folder(let folder):
            return feedInFolder(folder.id).map(LibraryInfoCommand.feedInfo) ?? .speakFullInfo
        }
    }
}

/// What Book Info (Command-I) does for the selected row
/// (`LibraryInfoRow.infoCommand(feedInFolder:)`).
enum LibraryInfoCommand: Equatable {
    /// Opens the Book Info sheet for the book.
    case bookInfo(Book)
    /// Opens Feed Info for the feed with this ID.
    case feedInfo(UUID)
    /// Speaks the row's full summary, as Speak Full Info does.
    case speakFullInfo
}

// MARK: - The Facts of a Row

extension LibraryInfoSubject {
    /// The facts of `row` as the Library window shows them now. A feed's
    /// folder is its feed's: the row offers the feed's commands, and
    /// Command-I opens its Feed Info, so Speak Info speaks the feed. The
    /// file size, which only the full summary says, is measured only when
    /// `measuresFileSize`.
    @MainActor
    init(
        _ row: LibraryInfoRow,
        library: LibraryViewModel,
        feedFolders: LibraryFeedFolders,
        wordsPerMinute: Double,
        cloudStates: BookCloudStates,
        keptBooks: KeptBooks,
        measuresFileSize: Bool,
        now: Date = Date()
    ) {
        switch row {
        case .book(let book):
            self = .book(BookInfoFacts(
                book,
                library: library,
                wordsPerMinute: wordsPerMinute,
                cloudStates: cloudStates,
                keptBooks: keptBooks,
                measuresFileSize: measuresFileSize
            ))
        case .folder(let folder):
            if let feedID = feedFolders.feedID(inFolder: folder.id),
               let feed = FeedInfoFacts.of(feedID: feedID, center: feedFolders.center, now: now) {
                self = .feed(feed)
            } else {
                self = .folder(FolderInfoFacts(folder, library: library, feedFolders: feedFolders, wordsPerMinute: wordsPerMinute))
            }
        case .feed(let row):
            self = .feed(FeedInfoFacts.of(feedID: row.id, center: feedFolders.center, now: now) ?? FeedInfoFacts(row))
        }
    }
}

extension BookInfoFacts {
    /// The facts of `book` as its row shows them: its reader's live
    /// position in place of its own while that is newer, so the progress
    /// and time left are the row's, "Finished" and no time left for a book
    /// resting at its end (TODO P07); its cloud note and whether it is kept,
    /// as the row says them; whether a reader has it open; its place in the
    /// reading list, as the Reading List counts it (FR09); and its file
    /// size when `measuresFileSize`.
    @MainActor
    init(
        _ book: Book,
        library: LibraryViewModel,
        wordsPerMinute: Double,
        cloudStates: BookCloudStates,
        keptBooks: KeptBooks,
        measuresFileSize: Bool
    ) {
        let shown = library.livePositions.applied(to: book)
        let cloudState = cloudStates.listedState(of: book.id)
        self.init(
            title: book.title,
            author: book.author,
            format: book.format.displayName,
            folderPath: book.folderPath,
            progress: BookRow.spokenProgress(for: shown, besideDownloadPercentage: false),
            timeRemaining: BookRow.timeRemaining(for: shown, wpm: wordsPerMinute),
            isUnopened: book.isUnopened,
            dateAdded: book.dateAdded,
            lastOpened: book.lastOpened,
            bookmarkCount: book.bookmarks.count,
            fileSize: measuresFileSize ? Self.fileSize(of: book, inTheCloud: cloudState?.isInTheCloud ?? false) : nil,
            cloudNote: cloudState?.spokenNote,
            isKeptOnThisMac: cloudStates.listsAsKept(book.id, in: keptBooks),
            isOpenInWindow: library.openBookIDs.contains(book.id),
            isKeptOnlyForReadingList: cloudStates.listsAsKeptOnlyForReadingList(book.id, in: keptBooks),
            feedTitle: library.feedTitle(of: book),
            readingListPlace: ReadingListPlace(of: book.id, in: library.library),
            brailleCode: book.brailleCodeDescription,
            brailleFileCharacters: book.brailleFileCodeDescription,
            textEncoding: book.textEncodingDescription
        )
    }

    /// The size of `book`'s file on disk as the File Size sort measures it
    /// (`LibraryBookSorter.recursiveFileSize(at:)`), with dataless files
    /// left in the cloud: nil for a book any of whose files is in the
    /// cloud, which is never downloaded to be measured, and for a file
    /// that cannot be measured.
    static func fileSize(of book: Book, inTheCloud: Bool) -> Int64? {
        guard !inTheCloud else { return nil }
        let bytes = DatalessFiles.withoutDownloading {
            LibraryBookSorter.recursiveFileSize(at: book.bookFileURL)
        }
        return bytes > 0 ? Int64(bytes) : nil
    }
}

extension FolderInfoFacts {
    /// The facts of `folder`: its books in it and every folder below it,
    /// as its row counts them, with the unopened ones among them and the
    /// time left in all of them at `wordsPerMinute` from their readers'
    /// live positions, as the summary bar sums it; the feeds whose folders
    /// are inside it, as the Feeds section lists them there; and its own
    /// subfolders.
    @MainActor
    init(_ folder: BookFolder, library: LibraryViewModel, feedFolders: LibraryFeedFolders, wordsPerMinute: Double) {
        let path = folder.fullPath
        let books = library.library.booksInFolderTree(path)
        // The time left, added up as the summary bar adds it up.
        let timeLeft = TimeRemainingTally.sum(of: books, wpm: wordsPerMinute, livePositions: library.livePositions)
        self.init(
            name: folder.name,
            bookCount: books.count,
            unopenedCount: books.filter { $0.isUnopened }.count,
            feedCount: LibraryFeedsSectionRows.feeds(at: LibraryLocation(category: .folders, folderPath: path), center: feedFolders.center).count,
            subfolderCount: library.subfoldersOf(path).count,
            timeRemaining: timeLeft.known == 0 ? nil : timeLeft.time
        )
    }
}

extension FeedInfoFacts {
    /// The facts of the feed `feedID` as `center` has it now, as its row
    /// shows them (`LibraryFeedsSectionRows.rows(at:center:now:)`), with
    /// its address; nil for a feed whose record is gone (an unsubscribed
    /// feed keeps its record, FR11, branch D).
    @MainActor
    static func of(feedID: UUID, center: FeedCenter, now: Date) -> FeedInfoFacts? {
        guard let feed = center.store.record(of: feedID)?.feed else { return nil }
        return FeedInfoFacts(
            title: feed.title,
            counts: center.counts(of: feed.id),
            check: center.checkWording(of: feed.id, now: now).visible,
            folderPath: center.folderPath(of: feed),
            address: feed.feedURL.absoluteString
        )
    }

    /// The facts of the feed whose row is `row`, as the row shows them,
    /// with no address: for a feed whose record went since its row was
    /// drawn.
    init(_ row: FeedRowContent) {
        self.init(title: row.title, counts: row.counts, check: row.check.visible, folderPath: row.folderPath, address: nil)
    }
}
