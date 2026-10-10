import Combine
import Foundation

/// The library's side of the podcast and article reader (FR03): the feed
/// engine starts with the library, finds a feed's folder by its ID, and adds
/// the books its downloads publish.
extension LibraryViewModel: FeedLibraryHost {
    /// The feed engine this library works with: the app's, unless a test
    /// gave its own (`feedEngine`).
    var feeds: FeedCenter {
        feedEngine ?? FeedCenter.shared
    }

    // MARK: - A Feed's Items in Its Folder (FR11)

    /// The feed whose folder is the library folder at `path`, if any.
    func feedID(listedIn path: String) -> UUID? {
        guard !path.isEmpty, let folder = library.folders.first(where: { $0.fullPath == path }) else { return nil }
        return feeds.store.feed(inFolder: folder.id)?.id
    }

    /// The feed items the library folder at `path` lists beside its own
    /// books (FR11): the rows of its feed's items whose files are here,
    /// found by feed ID, since a feed item's row names no folder; none for a
    /// folder that holds no feed. So a folder's rename or move, and Feed
    /// Info's change of folder, take a feed's items along without changing
    /// any row.
    func feedItems(listedIn path: String) -> [Book] {
        guard let feedID = feedID(listedIn: path) else { return [] }
        return library.books.filter { $0.feedLink?.feedID == feedID }
    }

    /// Starts the feed engine with this library, once the library has
    /// loaded: it reads the feeds' records off the main thread and, outside
    /// a process hosting tests, refreshes every feed when the settings say
    /// to. Returns at once, so nothing the engine does holds the library
    /// back.
    func startFeeds() {
        feeds.start(library: self)
    }

    // MARK: - FeedLibraryHost

    /// The path of the library folder `folderID`, wherever it has been
    /// renamed or moved to; nil when the folder is gone.
    func feedFolderPath(forFolderID folderID: UUID) -> String? {
        library.folders.first { $0.id == folderID }?.fullPath
    }

    /// The book `bookID`, when the library lists it.
    func feedBook(withID bookID: UUID) -> Book? {
        bookByID(bookID)
    }

    /// Lists a book a feed download published, and saves the library. An
    /// episode skips the duplicate question, and the library's rule against
    /// two books of one file, since two shows can carry one file.
    ///
    /// The book is a feed item's (FR11): its row carries the feed link the
    /// import gave it and no library folder, its package is in its feed's
    /// folder, and the save writes it to its feed's index, which the library
    /// keeps from now on, never to library.json.
    func addFeedBook(_ book: Book) {
        guard bookByID(book.id) == nil else { return }
        var row = book
        var updated = library
        if let feedID = row.feedLink?.feedID {
            row.folderPath = ""
            updated.feedShelf.keepIndex(of: feedID)
        }
        updated.books.append(row)
        library = updated
        save()
    }

    /// Takes a feed book whose package was deleted out of the library,
    /// through the same bookkeeping as every removal that deletes a package
    /// (`removeDeletedBook(_:)`), and saves the library.
    func removeFeedBook(_ book: Book) {
        removeDeletedBook(book)
        save()
    }

    /// The books open in readers now.
    var feedBooksOpenInReaders: Set<UUID> {
        openBookIDs
    }

    /// Publishes the books open in readers whenever they change.
    var feedBooksOpenInReadersChanges: AnyPublisher<Set<UUID>, Never> {
        $openBookIDs.eraseToAnyPublisher()
    }

    /// Whether the library lists every book it holds: not while its index
    /// is recovered (`indexRecovery`), when the library is provisional.
    var feedLibraryIsComplete: Bool {
        indexRecovery == nil
    }

    /// Opens the book `bookID` in its reader, as an import that opens its
    /// book does.
    func openFeedBook(_ bookID: UUID) {
        readerOpener(bookID)
    }

    /// Makes a folder for a new subscription to the feed titled `title`
    /// inside the folder at `parentPath` ("" for the library's top level),
    /// as New Folder makes one: the feed's title, made a folder name
    /// (`FeedFolderNaming.baseName(for:)`), followed by " 2", " 3", and so on
    /// while a folder of that name is there already.
    /// - Throws: `FeedFolderError` when the parent folder is gone, or no
    ///   folder could be made there.
    func makeFeedFolder(named title: String, inParentPath parentPath: String) throws(FeedFolderError) -> UUID {
        // A parent path naming no folder would leave the new folder outside
        // the library's tree.
        guard parentPath.isEmpty || library.existingFolder(equivalentTo: parentPath) != nil else {
            throw FeedFolderError(message: FeedFolderNaming.parentMissingMessage)
        }
        let base = FeedFolderNaming.baseName(for: title)
        for name in FeedFolderNaming.candidates(for: base) {
            do {
                return try createFolderReturningFolder(name: name, parentPath: parentPath).id
            } catch {
                switch error {
                case .refused(.nameInUse):
                    // Taken: try the next name.
                    continue
                default:
                    throw FeedFolderError(message: error.outcome.failureMessage ?? FeedFolderNaming.notMadeMessage)
                }
            }
        }
        throw FeedFolderError(message: FeedFolderNaming.notMadeMessage)
    }
}

// MARK: - Naming a Feed's Folder (FR03)

/// How a new subscription's folder is named: after the feed, as a folder
/// name may be written, told apart from folders already there by a number.
enum FeedFolderNaming {
    /// The longest name given, in characters: a feed's title can run long,
    /// and a folder's name is also a directory's name on disk.
    static let maximumLength = 80
    /// How many numbered names are tried before giving up: " 2" to " 99".
    static let maximumNumber = 99

    /// What a new subscription's folder is called, before any number: the
    /// feed's title as a folder name may hold it (`BookFolder.normalizedName`,
    /// which turns "/" into "-"), cut to `maximumLength` characters at a
    /// word where it can be, or "Feed" for a title no folder name can hold.
    static func baseName(for title: String) -> String {
        guard let normalized = BookFolder.normalizedName(title) else { return "Feed" }
        guard normalized.count > maximumLength else { return normalized }
        let cut = String(normalized.prefix(maximumLength))
        // Cut at the last space, unless that leaves too little of the title.
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) >= maximumLength / 2 {
            return BookFolder.normalizedName(String(cut[..<space])) ?? cut
        }
        return BookFolder.normalizedName(cut) ?? "Feed"
    }

    /// The names tried in turn for a folder called `base`: `base` itself,
    /// then "`base` 2", "`base` 3", up to `maximumNumber`.
    static func candidates(for base: String) -> [String] {
        [base] + (2...maximumNumber).map { "\(base) \($0)" }
    }

    /// Why no folder was made when the folder chosen to hold it is gone.
    static let parentMissingMessage = "The folder chosen to hold the feed's folder is no longer in the library. Choose another one."
    /// Why no folder was made when no name could be used.
    static let notMadeMessage = "TextMouth couldn't make a folder for this feed."
}
