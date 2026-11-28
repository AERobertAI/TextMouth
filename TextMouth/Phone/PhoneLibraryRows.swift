import Combine
import Foundation

/// What a Library screen hears of the open book, from the session's snapshot:
/// which book it is, and whether it plays. Nothing else, so the screen never
/// hears the book's place move.
struct PhoneLibraryListening: Equatable, Sendable {
    /// The open book, or nil when none is open.
    let bookID: UUID?
    /// Whether it plays.
    let isPlaying: Bool

    /// No book open.
    static let nothingOpen = PhoneLibraryListening(bookID: nil, isPlaying: false)
}

/// The Continue row as it was last built (the iPhone interface spec, "The
/// Continue row"): the Mac's Continue button, as the first row of every
/// Library screen.
struct PhoneContinueRow: Equatable, Sendable {
    /// The book in reach, which the row opens.
    let bookID: UUID
    /// What VoiceOver says: the Mac's "Continue listening to Emma, 16 minutes
    /// remaining", or "Now Playing: Emma" while it plays.
    let label: String
    /// What it shows, the Mac's "Continue: Emma".
    let visibleTitle: String
    /// The time left it shows, the Mac's "16:00 left", or nil.
    let timeText: String?
    /// Whether the book plays, which the visible Play button shows.
    let isPlaying: Bool
}

/// The rows of one iPhone Library screen, held as values and published only
/// when the list itself changes (the engineering review's F11).
///
/// The library publishes at every checkpoint of a playing book, every 30
/// seconds, and after every move. A list drawn from it would change the
/// playing book's percent and time left in its row, and focus lands on
/// exactly that row after Back: a changed label on a focused element can be
/// spoken over the book. So the screen observes this model, never the
/// library. It hears each change of the library, and republishes only when
/// the list's signature changes: the rows in order, the books' titles and
/// authors, which are in the reading list, and the folders' counts. It builds
/// every row afresh, its progress and time left with it, when the screen
/// appears, when a book stops playing, and when the view, the sort, or the
/// search changes.
///
/// A plain type that compiles on both apps, so the Mac's test host tests it.
@MainActor
final class PhoneLibraryRows: ObservableObject {
    // MARK: - What the Screen Reads

    /// The list's sections, in order.
    @Published private(set) var sections: [PhoneLibrarySection] = []
    /// The Mac's spoken summary of the books listed, "743 books. 14 hours
    /// total remaining at current speed", or nil while searching or with no
    /// books. It is built with the rows, so it never changes as a book plays.
    @Published private(set) var summary: String?
    /// The Continue row, or nil while no book is in reach. Its words change
    /// only when the book starts or stops playing, when the book in reach
    /// changes, and when the rows are built afresh.
    @Published private(set) var continueRow: PhoneContinueRow?

    /// Where the screen is: published, so its title and Library view's value
    /// follow a change even when the rows come out the same.
    @Published private(set) var location: LibraryLocation
    /// What the search field holds; empty when not searching. Published, so
    /// the rows that step aside while searching follow it.
    @Published private(set) var searchText = ""
    /// How many books and folders the search found, for what is said once
    /// typing stops.
    private(set) var searchCounts = (books: 0, folders: 0)
    /// How many times the rows were built, for tests.
    private(set) var buildCount = 0

    // MARK: - What It Works With

    /// The library the rows come from.
    private let library: LibraryViewModel
    /// Which folders hold feeds, and the feed engine the feeds' rows come from (FR53).
    private let feedFolders: LibraryFeedFolders
    /// The speed time left is counted at.
    private let wordsPerMinute: @MainActor () -> Double
    /// The removal preferences, which name a row's removal.
    private let removalPreferences: @MainActor () -> RemovalPreferences
    /// The signature of the list last published.
    private var publishedSignature: Signature?
    /// The book in reach: the open reader's, else the one last opened.
    private let bookInReach: @MainActor () -> Book?
    /// What was last heard of the open book, or nil before the first word.
    private var listening: PhoneLibraryListening?
    /// The library's changes and the book's playing, heard while the model lasts.
    private var subscriptions = Set<AnyCancellable>()

    /// The rows of the screen at `location`.
    ///
    /// - Parameters:
    ///   - library: The library the rows come from.
    ///   - location: Where the screen is.
    ///   - wordsPerMinute: The speed time left is counted at, read at each build.
    ///   - removalPreferences: The removal preferences, read at each build.
    ///   - bookInReach: The book the Continue row opens, read when it is built.
    ///   - listening: The open book and whether it plays, from the session's
    ///     snapshot: when it stops, the rows are built afresh with the place
    ///     it reached.
    init(
        library: LibraryViewModel,
        location: LibraryLocation,
        wordsPerMinute: @escaping @MainActor () -> Double,
        removalPreferences: @escaping @MainActor () -> RemovalPreferences,
        bookInReach: @escaping @MainActor () -> Book?,
        listening: AnyPublisher<PhoneLibraryListening, Never>
    ) {
        self.library = library
        // The app's own, while the library works with the app's engine; a test's engine has its own.
        feedFolders = library.feeds === FeedCenter.shared ? .shared : LibraryFeedFolders(center: library.feeds)
        self.location = location
        self.wordsPerMinute = wordsPerMinute
        self.removalPreferences = removalPreferences
        self.bookInReach = bookInReach

        // `$library` publishes before the library changes, so the change is
        // read a turn of the main queue later, once it is in place.
        library.$library
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.libraryChanged()
                }
            }
            .store(in: &subscriptions)
        // A feed subscribed, refreshed, or unsubscribed, and an item downloaded, played, or deleted (FR53): the engine
        // publishes for these, never for how far a download has got, so the rows are built again only when it matters.
        // Read a turn later, as `$library` is, once the change is in place.
        library.feeds.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.libraryChanged()
                }
            }
            .store(in: &subscriptions)
        // The keep commands and the kept state follow sync being on and the set kept (FR43); rows are built afresh when they change.
        // A book's cloud state changing (a download's progress, a book arriving) is read the same way.
        BookCloudStates.shared.$states
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.rebuild()
                }
            }
            .store(in: &subscriptions)
        KeptBooks.shared.$syncedBookIDs
            .removeDuplicates()
            .combineLatest(SyncCenter.shared.$status.map(\.isOn).removeDuplicates())
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.rebuild()
                }
            }
            .store(in: &subscriptions)
        listening
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] heard in
                MainActor.assumeIsolated {
                    self?.listeningChanged(to: heard)
                }
            }
            .store(in: &subscriptions)
        rebuild()
    }

    // MARK: - Changing What Is Listed

    /// Builds every row afresh and publishes them: when the screen appears,
    /// and when a book stops playing.
    func rebuild() {
        publish(gather())
    }

    /// Shows `location`, as when the view or the sort changes.
    func show(_ location: LibraryLocation) {
        self.location = location
        rebuild()
    }

    /// Lists what `text` finds across the whole library, or, when it is
    /// empty, the screen's own list again.
    func search(for text: String) {
        guard text != searchText else { return }
        searchText = text
        rebuild()
    }

    /// Whether the list shows search results.
    var isSearching: Bool {
        !searchText.isEmpty
    }

    // MARK: - Reading the Rows

    /// Every row's identity, in the list's order.
    var rowIDs: [PhoneRowID] {
        sections.flatMap { $0.rows.map(\.id) }
    }

    /// Whether the list has a row `id`.
    func contains(_ id: PhoneRowID) -> Bool {
        sections.contains { section in section.rows.contains { $0.id == id } }
    }

    /// The row focus goes to once the row `id` leaves the list: the row after
    /// it, or the one before it when it was the last; nil when it was alone,
    /// or isn't listed. Asked before the row leaves.
    func neighbor(of id: PhoneRowID) -> PhoneRowID? {
        let ids = rowIDs.filter(Self.isListed)
        guard let index = ids.firstIndex(of: id) else { return nil }
        if ids.indices.contains(index + 1) {
            return ids[index + 1]
        }
        return index > 0 ? ids[index - 1] : nil
    }

    /// Whether `id` is a book's or a folder's row, which focus can land on in
    /// place of a row that left, rather than a sentence.
    private nonisolated static func isListed(_ id: PhoneRowID) -> Bool {
        if case .note = id { return false }
        return true
    }

    // MARK: - Hearing the Library and the Book

    /// Builds the rows afresh once a book stops playing, so they say the
    /// place it reached; otherwise only the Continue row changes, as the
    /// book starts playing or another opens.
    private func listeningChanged(to heard: PhoneLibraryListening) {
        let stopped = listening?.isPlaying == true && !heard.isPlaying
        listening = heard
        if stopped {
            rebuild()
        } else {
            refreshContinueRow()
        }
    }

    /// Builds the Continue row for the book in reach now, and publishes it
    /// only when it differs.
    private func refreshContinueRow() {
        let built = continueRow(for: bookInReach())
        if built != continueRow {
            continueRow = built
        }
    }

    /// The Continue row of `book`: "Now Playing: Emma" while it is the open
    /// book and plays, and otherwise the Mac's Continue label with the time
    /// left now.
    private func continueRow(for book: Book?) -> PhoneContinueRow? {
        guard let listed = book else { return nil }
        let book = library.livePositions.applied(to: listed)
        let isPlaying = listening?.bookID == book.id && listening?.isPlaying == true
        return PhoneContinueRow(
            bookID: book.id,
            label: isPlaying
                ? PhoneRowWording.nowPlayingLabel(title: book.title)
                : PhoneRowWording.continueLabel(for: book, wordsPerMinute: wordsPerMinute()),
            visibleTitle: PhoneRowWording.continueVisibleTitle(for: book),
            timeText: isPlaying ? nil : PhoneRowWording.continueTimeText(for: book, wordsPerMinute: wordsPerMinute()),
            isPlaying: isPlaying
        )
    }

    /// Rebuilds the rows only when the library's change changed the list's
    /// signature, not at a checkpoint that moved a reading position alone.
    private func libraryChanged() {
        let gathered = gather()
        guard gathered.signature != publishedSignature else {
            // The book in reach may have left the library, or been renamed,
            // with the list itself unchanged.
            let reach = bookInReach()
            if reach?.id != continueRow?.bookID || reach.map({ PhoneRowWording.continueVisibleTitle(for: $0) }) != continueRow?.visibleTitle {
                refreshContinueRow()
            }
            return
        }
        publish(gathered)
    }

    // MARK: - Building

    /// What a list holds, gathered from the library before any row's words
    /// are made, so a change can be compared cheaply first.
    private struct Contents {
        /// The folders listed.
        var folders: [BookFolder] = []
        /// The books listed, in order.
        var books: [Book] = []
        /// The field the books are sorted by, which decides letter sections.
        var sortField: LibrarySortField = .title
        /// Each book's moves through the order the list shows, where the
        /// listener arranges it.
        var moves: [UUID: LibraryManualMoves]?
        /// The books in the reading list.
        var inReadingList: Set<UUID> = []
        /// Whether the list is the Reading List, whose rows don't say so.
        var atReadingList = false
        /// The sentence shown where nothing is listed.
        var note: PhoneRowNote?
        /// Whether the books' heading is shown with the sentence.
        var noteHasBooksHeader = false
        /// What the screen holds of feeds: the Feeds section, feeds' folders, and a feed folder's items (FR53).
        var feeds = PhoneFeedRows.Gathered()
        /// Whether the books are listed at all: not in a view that lists feeds alone, whose Feeds section is all it has.
        var listsBooks = true
        /// The list's signature.
        var signature: Signature {
            Signature(
                folders: folders.map { Signature.FolderEntry(path: $0.fullPath, name: $0.name) },
                feeds: feeds.signature,
                books: books.map {
                    Signature.BookEntry(id: $0.id, title: $0.title, author: $0.author, inReadingList: inReadingList.contains($0.id))
                },
                sortField: sortField,
                note: note
            )
        }
    }

    /// What decides whether a change of the library changes the list: the
    /// rows in order and the words that name them, never a reading position.
    /// Folder counts are added as the folders are read.
    private struct Signature: Equatable {
        /// A folder listed, by its place and its name.
        struct FolderEntry: Equatable {
            let path: String
            let name: String
        }
        /// A book listed, by the words that name it.
        struct BookEntry: Equatable {
            let id: UUID
            let title: String
            let author: String
            let inReadingList: Bool
        }
        let folders: [FolderEntry]
        /// What the feeds on the screen say (FR53).
        let feeds: [String]
        let books: [BookEntry]
        let sortField: LibrarySortField
        let note: PhoneRowNote?
        var folderCounts: [Int] = []
    }

    /// What the list holds now: the search's results across the library, or
    /// the location's folders and books.
    private func gather() -> (contents: Contents, signature: Signature) {
        var contents = Contents()
        contents.inReadingList = Set(library.readingList.bookIDs)
        if isSearching {
            gatherSearch(into: &contents)
        } else {
            gatherLocation(into: &contents)
        }
        var signature = contents.signature
        signature.folderCounts = contents.folders.map { library.bookCount(inFolderTree: $0.fullPath) }
        return (contents, signature)
    }

    /// The search's results: every folder whose name holds the text, by
    /// path, and every book whose title or author does, in All Items' sort,
    /// as the Mac's search compares them (ignoring case).
    private func gatherSearch(into contents: inout Contents) {
        let query = searchText.lowercased()
        contents.folders = library.library.folders
            .filter { $0.name.lowercased().contains(query) }
            .sortedStably { $0.fullPath.localizedStandardCompare($1.fullPath) == .orderedAscending }
        // A feed's folder found by name still says it is a feed's (FR53).
        for folder in contents.folders {
            if let feedID = feedFolders.feedID(inFolder: folder.id) {
                contents.feeds.heldFeedCounts[folder.id] = feedFolders.center.counts(of: feedID)
            }
        }
        let everything = LibraryLocation(category: .allItems, folderPath: "")
        contents.books = library.displayedBooks(at: everything, matching: searchText)
        contents.sortField = library.sortState(at: everything).field
        if contents.books.isEmpty && contents.folders.isEmpty {
            contents.note = .noMatches
        }
    }

    /// The location's own list: its folders in Folders, its books in the
    /// order of its sort, and the sentence where it has nothing.
    private func gatherLocation(into contents: inout Contents) {
        if library.library.books.isEmpty && library.library.folders.isEmpty {
            contents.note = .emptyLibrary
            return
        }
        let sort = library.sortState(at: location)
        contents.sortField = sort.field
        contents.atReadingList = location.keepsItsOwnOrder
        contents.books = library.displayedBooks(at: location)
        // The feeds on the screen (FR53): the Feeds section, the folders without the feeds' that it stands for, and a
        // feed's own folder's items.
        contents.feeds = PhoneFeedRows.gather(
            at: location,
            subfolders: location.view.kind == .folders ? library.subfoldersOf(location.folderPath) : [],
            books: contents.books,
            in: library,
            feedFolders: feedFolders,
            wordsPerMinute: wordsPerMinute(),
            bookCount: { [library] in library.bookCount(inFolderTree: $0.fullPath) }
        )
        contents.folders = contents.feeds.folders
        // A view that lists feeds alone has no books to list, nor a heading for them.
        contents.listsBooks = location.view.filter?.listsOnlyFeeds != true
        if location.reorderTarget(sortedBy: sort) != nil {
            contents.moves = LibraryManualMoves.moves(in: contents.books)
        }
        guard contents.books.isEmpty, contents.feeds.folder == nil else { return }
        contents.noteHasBooksHeader = contents.listsBooks
        let hasFeeds = !contents.feeds.feeds.isEmpty
        switch location.view.kind {
        case .readingList:
            contents.note = .emptyReadingList
        case .folders:
            contents.note = contents.folders.isEmpty && !hasFeeds ? .emptyFolder : nil
        case .filter:
            contents.note = hasFeeds ? nil : .emptyView
        }
    }

    /// Builds the rows of `gathered` and publishes them, with its signature,
    /// leaving alone what hasn't changed so the screen isn't redrawn for
    /// nothing.
    private func publish(_ gathered: (contents: Contents, signature: Signature)) {
        buildCount += 1
        publishedSignature = gathered.signature
        let contents = gathered.contents
        let built = sections(of: contents)
        if built != sections {
            sections = built
        }
        let newSummary = summary(of: contents)
        if newSummary != summary {
            summary = newSummary
        }
        searchCounts = isSearching ? (contents.books.count, contents.folders.count) : (0, 0)
        refreshContinueRow()
    }

    /// The sections of `contents`: the folders, the feeds, then the books, by
    /// letter where the sort and their number call for it, or the sentence;
    /// in a feed's own folder, its items and then its other books.
    private func sections(of contents: Contents) -> [PhoneLibrarySection] {
        var sections: [PhoneLibrarySection] = []
        if !contents.folders.isEmpty {
            sections.append(PhoneLibrarySection(
                id: "folders",
                header: PhoneLibraryVocabulary.foldersHeader,
                indexLabel: nil,
                rows: contents.folders.map { folderRow($0, in: contents) }
            ))
        }
        // A feed's folder: its items, newest first, a downloaded one as its book's row, under the Mac's heading
        // counting them (FR53); then the books that came from no item.
        if let feedFolder = contents.feeds.folder {
            sections += feedFolderSections(of: feedFolder, in: contents)
            return sections
        }
        // The Feeds section, after Folders and before Books, as the Mac's list has it (FR53).
        if !contents.feeds.feeds.isEmpty {
            sections.append(PhoneLibrarySection(
                id: "feeds",
                header: FeedWording.feedsSectionTitle,
                indexLabel: nil,
                rows: contents.feeds.feeds.map(PhoneFeedRows.feedRow)
            ))
        }
        // A view that lists feeds alone lists no books, so it has no Books heading.
        guard contents.listsBooks else { return sections }
        if let note = contents.note {
            let header = contents.noteHasBooksHeader ? CountWording.booksHeader(of: []) : nil
            sections.append(PhoneLibrarySection(id: "note", header: header, indexLabel: nil, rows: [.note(note)]))
            return sections
        }
        // A search that found folders alone lists no books' section. A folder
        // holding only folders keeps the Mac's "Books (0)", with no rows.
        if contents.books.isEmpty && isSearching {
            return sections
        }
        let header = CountWording.booksHeader(of: contents.books)
        guard PhoneLibrarySections.usesLetters(sortedBy: contents.sortField, count: contents.books.count) else {
            sections.append(PhoneLibrarySection(id: "books", header: header, indexLabel: nil, rows: contents.books.map { bookRow($0, in: contents) }))
            return sections
        }
        // The books' heading, then a heading for each letter. A List can't
        // nest sections, so the heading stands as a section of its own.
        sections.append(PhoneLibrarySection(id: "books", header: header, indexLabel: nil, rows: []))
        for (number, run) in PhoneLibrarySections.letterRuns(of: contents.books, sortedBy: contents.sortField).enumerated() {
            sections.append(PhoneLibrarySection(
                id: "letter-\(number)-\(run.letter)",
                header: run.letter,
                indexLabel: run.letter,
                rows: run.books.map { bookRow($0, in: contents) }
            ))
        }
        return sections
    }

    /// The sections of a feed's own folder (FR53): its items under the Mac's
    /// heading, and the folder's other books under theirs, each only when it
    /// has rows.
    private func feedFolderSections(of folder: PhoneFeedRows.FolderContents, in contents: Contents) -> [PhoneLibrarySection] {
        let listing = folder.listing
        var sections = [PhoneLibrarySection(
            id: "feed-items",
            header: FeedWording.sectionTitle(listing.noun, count: listing.entries.count, total: listing.total),
            indexLabel: nil,
            rows: listing.entries.map { entry in
                switch entry {
                case .book(let book, _):
                    return bookRow(book, in: contents, feedActions: PhoneFeedRows.bookRowActions(of: entry))
                case .item(let content):
                    return PhoneFeedRows.itemRow(content)
                }
            }
        )]
        if !listing.otherBooks.isEmpty {
            sections.append(PhoneLibrarySection(
                id: "feed-other-books",
                header: FeedWording.otherBooksTitle(count: listing.otherBooks.count),
                indexLabel: nil,
                rows: listing.otherBooks.map { bookRow($0, in: contents) }
            ))
        }
        return sections
    }

    /// A folder's row: the Mac's label, "Fiction, 12 books", and its commands.
    /// A feed's folder says "Feed" and counts the feed's items instead (FR53),
    /// and a folder holding feeds names them beside its books, "Podcasts, 3
    /// books, 2 feeds".
    private func folderRow(_ folder: BookFolder, in contents: Contents) -> PhoneRowValue {
        let count = library.bookCount(inFolderTree: folder.fullPath)
        let feedCounts = contents.feeds.heldFeedCounts[folder.id]
        let feedsBelow = contents.feeds.feedsBelow[folder.id] ?? 0
        return PhoneRowValue(
            id: .folder(folder.id),
            label: FolderRow.accessibilityLabel(name: folder.name, bookCount: count, feedCounts: feedCounts, feedsBelow: feedsBelow),
            title: folder.name,
            detail: FolderRow.countText(bookCount: count, feedCounts: feedCounts, feedsBelow: feedsBelow),
            commands: PhoneLibraryOffer.folderCommands(offersDelete: library.offersDeleteFolder(folder), bookCount: count)
        )
    }

    /// A book's row: exactly the Mac's label, with the place its reader has
    /// reached now, the visible title and the author with progress, and its
    /// commands.
    private func bookRow(_ listed: Book, in contents: Contents, feedActions: [FeedItemAction] = []) -> PhoneRowValue {
        let book = library.livePositions.applied(to: listed)
        let inReadingList = contents.inReadingList.contains(book.id)
        let cloudState = BookCloudStates.shared.listedState(of: book.id)
        let macRow = BookRow(
            book: book,
            isOpenInWindow: library.openBookIDs.contains(book.id),
            wpm: wordsPerMinute(),
            // "In Cloud", "Downloading 40%", "Download failed", and "Waiting for Sync", said while sync is on (FR43), by the
            // Mac's own row: its label speaks the note.
            cloudState: cloudState,
            // Said in every view but the Reading List, where every book is in it.
            isInReadingList: !contents.atReadingList && inReadingList
        )
        let progress = BookRow.progressText(for: book)?.visible
        // Whether the book is kept on all devices, said only with sync on (FR43).
        let isKept: Bool? = SyncCenter.shared.status.isOn ? PhoneKeepOnAllDevices.isKept(book.id) : nil
        return PhoneRowValue(
            id: .book(book.id),
            label: isKept == true
                ? SentenceWording.commaJoined([macRow.rowAccessibilityLabel, SyncWording.keptState])
                : macRow.rowAccessibilityLabel,
            title: book.title,
            detail: [book.author, progress, cloudState?.visibleNote].compactMap { $0 }.joined(separator: ", "),
            commands: PhoneLibraryOffer.bookCommands(
                for: book,
                isInReadingList: inReadingList,
                moves: contents.moves?[book.id],
                removal: removalPreferences(),
                isKeptOnAllDevices: isKept,
                canDownload: cloudState?.canDownload == true,
                canRemoveDownload: BookCloudStates.shared.canRemoveDownload(book),
                feedActions: feedActions
            )
        )
    }

    /// The Mac's spoken summary of the books `contents` lists, as its summary
    /// bar says it, with the feeds beside them where the Feeds section lists
    /// any ("743 books, 2 feeds"); in a feed's own folder, the feed's items
    /// counted and its last check (FR53). Nil while searching, and with
    /// nothing to sum up.
    private func summary(of contents: Contents) -> String? {
        guard !isSearching else { return nil }
        if let feedFolder = contents.feeds.folder {
            return PhoneFeedRows.summary(
                of: feedFolder.summary,
                books: contents.books,
                wordsPerMinute: wordsPerMinute(),
                livePositions: library.livePositions
            )
        }
        guard !contents.books.isEmpty, contents.listsBooks else { return nil }
        return TimeRemainingBar(
            books: contents.books,
            wpm: wordsPerMinute(),
            livePositions: library.livePositions,
            feedCount: contents.feeds.feeds.count
        ).summaryAccessibilityLabel
    }
}
