import Foundation

/// The listening options of the folders and feeds the library holds (FR19):
/// found for a folder or a book, and set for a folder. A feed's are set
/// through `FeedCenter.setListeningOptions(_:of:)`, since its record keeps
/// them.
extension LibraryViewModel {

    /// The listening options of the plain folder `folderID`: nil when the
    /// folder has none of its own, or is not in the library.
    func listeningOptions(ofFolder folderID: UUID) -> ListeningOptions? {
        library.folders.first { $0.id == folderID }?.listeningOptions
    }

    /// Gives the folder `folderID` its own listening options, or none when
    /// `options` is nil or standard (standard options are never stored).
    /// Saves the library once; changes and saves nothing for a folder that
    /// is not in the library, or for options the folder already has.
    func setListeningOptions(_ options: ListeningOptions?, ofFolder folderID: UUID) {
        guard let index = library.folders.firstIndex(where: { $0.id == folderID }) else { return }
        let stored = options.flatMap { $0.isStandard ? nil : $0 }
        guard library.folders[index].listeningOptions != stored else { return }
        library.folders[index].listeningOptions = stored
        save()
    }

    /// The listening options that govern `book`: for an item of a feed, the
    /// feed's; for any other book, those of the folder that holds it
    /// directly, never those of a folder above it. Nil for a book at the
    /// top level, in a folder with none, or whose feed's record is gone.
    func listeningOptions(of book: Book) -> ListeningOptions? {
        if let link = book.feedLink {
            return feeds.store.record(of: link.feedID)?.feed.listeningOptions
        }
        // The top level has no folder row; never match a damaged row with no path.
        guard !book.folderPath.isEmpty else { return nil }
        return library.existingFolder(equivalentTo: book.folderPath)?.listeningOptions
    }
}
