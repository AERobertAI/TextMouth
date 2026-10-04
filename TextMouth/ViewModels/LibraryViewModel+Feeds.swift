import Combine
import Foundation

/// The library's side of the podcast and article reader (FR03): the feed
/// engine starts with the library, finds a feed's folder by its ID, and adds
/// the books its downloads publish.
extension LibraryViewModel: FeedLibraryHost {
    /// The feed engine this library works with: the app's.
    var feeds: FeedCenter {
        FeedCenter.shared
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
    func addFeedBook(_ book: Book) {
        guard bookByID(book.id) == nil else { return }
        library.books.append(book)
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
}
