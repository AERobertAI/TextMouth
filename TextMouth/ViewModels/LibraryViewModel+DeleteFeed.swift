import Foundation

// MARK: - A Deleted Feed's Rows and Folders (FR14)

/// The library's side of Delete Feed… (FR14, `FeedCenter.deleteFeed(_:)`):
/// every row the feed has here, its index forgotten once those rows are
/// gone, so its folder in the data directory can go for good, and its
/// library folder deleted when nothing else is in it.
extension LibraryViewModel {
    /// Every row of the feed `feedID` the library holds, each once, in the
    /// library's order: its downloads among the books, then the rows kept on
    /// its shelf after their downloads went (FR11, branch A2). Unlike
    /// `feedItemRows(of:)`, which finds one row for each item, it holds a
    /// row whatever its item, so nothing of a deleted feed stays behind.
    func everyRow(ofFeed feedID: UUID) -> [Book] {
        var seen = Set<UUID>()
        return (library.books + library.feedShelf.rows).filter { row in
            row.feedLink?.feedID == feedID && seen.insert(row.id).inserted
        }
    }

    /// Forgets the index of the feed `feedID` for good, once every row of the
    /// feed has left the library (FR14): no save writes the index again,
    /// which would make the feed's folder anew in the data directory
    /// (`FeedIndexFiles.write(_:in:fileManager:)` makes the folder it writes
    /// in), nor leaves it alone. The library is saved at once, in place of
    /// any snapshot waiting to be written, which may still name the index.
    func forgetFeedIndex(of feedID: UUID) {
        let shelf = library.feedShelf
        guard shelf.indexedFeedIDs.contains(feedID) || shelf.indexesLeftAlone.contains(feedID) else { return }
        library.feedShelf.forgetIndex(of: feedID)
        LibraryPersistenceService.saveAndWait(library)
    }

    /// Deletes the library folder `folderID`, the folder of a feed just
    /// deleted, when nothing else is in it: no book of the library's own, no
    /// folder, and no other feed's items (`folderHasContents(_:)`, which asks
    /// the feed engine, the deleted feed's record gone by then). It goes as
    /// Delete Folder… deletes an empty folder, its contents, none, moved to
    /// its parent (FR14).
    /// - Returns: What became of the folder.
    func removeFolderOfDeletedFeed(_ folderID: UUID) async -> FeedFolderFate {
        guard let folder = library.folders.first(where: { $0.id == folderID }) else { return .none }
        let path = folder.fullPath
        guard !folderHasContents(folder) else { return .stays(path: path) }
        let outcome = await removeFolderMovingContentsReturningOutcome(folder, toPath: folder.parentPath)
        guard outcome.succeeded else {
            DiagnosticLog.event(
                .feeds,
                "FEED_DELETE_FOLDER_KEPT: the deleted feed's empty library folder stays: \(outcome.message ?? "no reason given")"
            )
            return .notDeleted(path: path)
        }
        return .deleted(path: path)
    }
}
