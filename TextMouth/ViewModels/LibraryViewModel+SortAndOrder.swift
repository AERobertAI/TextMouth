import SwiftUI

/// Extension for sorting, ordering, and reordering books within folders —
/// manual sort order, folder sort settings, and next-book navigation.
extension LibraryViewModel {

    /// Get the next book in the same folder, sorted by manual order then title.
    func nextBookInFolder(after book: Book) -> Book? {
        let folderBooks = sortedBooksInFolder(book.folderPath)
        guard let currentIndex = folderBooks.firstIndex(where: { $0.id == book.id }) else { return nil }
        let nextIndex = currentIndex + 1
        guard nextIndex < folderBooks.count else { return nil }
        return folderBooks[nextIndex]
    }

    /// Update the sort setting for a specific folder path and persist.
    func setFolderSortSetting(_ setting: FolderSortSetting, for folderPath: String) {
        library.setSortSetting(setting, for: folderPath)
        save()
    }

    /// Apply a sort setting to a folder and all its subfolders, then persist.
    func applySortToSubfolders(_ setting: FolderSortSetting, from folderPath: String) {
        library.applySortToSubfolders(setting, from: folderPath)
        save()
    }

    /// Update manual sort order for a book within its folder.
    func updateManualSortOrder(bookID: UUID, order: Int) {
        updateBook(id: bookID) { $0.manualSortOrder = order }
    }

    /// Reorder books in a folder by moving from source indices to destination.
    func reorderBooksInFolder(folderPath: String, from source: IndexSet, to destination: Int) {
        var folderBooks = sortedBooksInFolder(folderPath)
        folderBooks.move(fromOffsets: source, toOffset: destination)
        // Assign new sort orders
        for (i, book) in folderBooks.enumerated() {
            updateManualSortOrder(bookID: book.id, order: i)
        }
    }

    /// Result of a manual order move, containing info for VoiceOver announcements.
    struct MoveResult {
        let movedTitle: String
        let adjacentTitle: String
        let direction: Int  // -1 = up, +1 = down
    }

    /// Move a book up or down by one position within its folder's manual sort order.
    /// direction: -1 for up, +1 for down.
    /// Returns a MoveResult for VoiceOver announcement, or nil if the move was not possible.
    @discardableResult
    func moveBookInManualOrder(bookID: UUID, direction: Int, folderPath: String) -> MoveResult? {
        var folderBooks = sortedBooksInFolder(folderPath)
        guard let currentIndex = folderBooks.firstIndex(where: { $0.id == bookID }) else { return nil }
        let newIndex = currentIndex + direction
        guard newIndex >= 0, newIndex < folderBooks.count else { return nil }

        let movedTitle = folderBooks[currentIndex].title
        let adjacentTitle = folderBooks[newIndex].title

        // Swap the two books and reassign sequential sort orders
        folderBooks.swapAt(currentIndex, newIndex)
        for (i, book) in folderBooks.enumerated() {
            updateManualSortOrder(bookID: book.id, order: i)
        }
        return MoveResult(movedTitle: movedTitle, adjacentTitle: adjacentTitle, direction: direction)
    }

    /// Check if a book can be moved up or down in manual sort order.
    func canMoveBookInManualOrder(bookID: UUID, direction: Int, folderPath: String) -> Bool {
        let folderBooks = sortedBooksInFolder(folderPath)
        guard let currentIndex = folderBooks.firstIndex(where: { $0.id == bookID }) else { return false }
        let newIndex = currentIndex + direction
        return newIndex >= 0 && newIndex < folderBooks.count
    }
}
