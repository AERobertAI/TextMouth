import Foundation

struct Library: Codable {
    var books: [Book]
    var folders: [BookFolder]

    init(books: [Book] = [], folders: [BookFolder] = []) {
        self.books = books
        self.folders = folders
    }

    // MARK: - Book Operations

    mutating func addBook(_ book: Book) {
        // Check for duplicate by MD5 hash
        guard !books.contains(where: { $0.md5Hash == book.md5Hash }) else { return }
        books.append(book)
    }

    mutating func removeBook(id: UUID) {
        books.removeAll { $0.id == id }
    }

    mutating func moveBook(id: UUID, toFolder folderPath: String) {
        guard let index = books.firstIndex(where: { $0.id == id }) else { return }
        books[index].folderPath = folderPath
    }

    mutating func updateReadingPosition(bookID: UUID, position: ReadingPosition) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[index].readingPosition = position
        books[index].lastOpened = Date()
    }

    // MARK: - Bookmark Operations

    mutating func addBookmark(bookID: UUID, chapterIndex: Int, characterOffset: Int, label: String = "") {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        let nextNumber = (books[index].bookmarks.map { $0.number }.max() ?? 0) + 1
        let bookmark = Bookmark(
            number: nextNumber,
            chapterIndex: chapterIndex,
            characterOffset: characterOffset,
            label: label
        )
        books[index].bookmarks.append(bookmark)
    }

    mutating func removeBookmark(bookID: UUID, bookmarkID: UUID) {
        guard let bookIndex = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[bookIndex].bookmarks.removeAll { $0.id == bookmarkID }
        // Renumber bookmarks
        for i in books[bookIndex].bookmarks.indices {
            books[bookIndex].bookmarks[i].number = i + 1
        }
    }

    // MARK: - Folder Operations

    mutating func createFolder(name: String, parentPath: String = "") -> BookFolder? {
        let folder = BookFolder(name: name, parentPath: parentPath)
        guard folder.depth <= BookFolder.maxDepth else { return nil }
        guard !folders.contains(where: { $0.fullPath == folder.fullPath }) else { return nil }
        folders.append(folder)
        return folder
    }

    /// Remove a folder, moving its contents to a destination path.
    /// Pass empty string to move contents to library root.
    mutating func removeFolder(id: UUID, movingContentsTo destination: String = "") {
        guard let folder = folders.first(where: { $0.id == id }) else { return }
        let folderPath = folder.fullPath

        // Collect subfolders of the removed folder
        let childFolders = folders.filter {
            $0.parentPath == folderPath || $0.parentPath.hasPrefix(folderPath + "/")
        }

        // Reparent direct child folders under the destination
        for child in childFolders {
            if let idx = folders.firstIndex(where: { $0.id == child.id }) {
                if child.parentPath == folderPath {
                    // Direct child of deleted folder — reparent to destination
                    folders[idx].parentPath = destination
                } else {
                    // Deeper descendant — replace the deleted folder's prefix with destination
                    let suffix = String(child.parentPath.dropFirst(folderPath.count))
                    folders[idx].parentPath = destination.isEmpty ? String(suffix.dropFirst()) : destination + suffix
                }
            }
        }

        // Move books to destination, preserving subfolder structure
        for i in books.indices {
            if books[i].folderPath == folderPath {
                books[i].folderPath = destination
            } else if books[i].folderPath.hasPrefix(folderPath + "/") {
                let suffix = String(books[i].folderPath.dropFirst(folderPath.count))
                books[i].folderPath = destination.isEmpty ? String(suffix.dropFirst()) : destination + suffix
            }
        }

        // Remove only the folder itself (children have been reparented)
        folders.removeAll { $0.id == id }
    }

    /// Remove a folder and ALL its contents (books and subfolders) from the library model.
    /// Does not touch disk — caller is responsible for deleting .tmb packages.
    mutating func removeFolderAndContents(id: UUID) -> [Book] {
        guard let folder = folders.first(where: { $0.id == id }) else { return [] }
        let folderPath = folder.fullPath

        // Collect books that will be removed
        let removedBooks = books.filter {
            $0.folderPath == folderPath || $0.folderPath.hasPrefix(folderPath + "/")
        }

        // Remove those books
        books.removeAll {
            $0.folderPath == folderPath || $0.folderPath.hasPrefix(folderPath + "/")
        }

        // Remove the folder and all subfolders
        folders.removeAll {
            $0.fullPath == folderPath || $0.fullPath.hasPrefix(folderPath + "/")
        }

        return removedBooks
    }

    /// Move a folder to a new parent, preserving its internal structure.
    /// Returns false if the move is invalid (cycle, depth exceeded, duplicate name).
    @discardableResult
    mutating func moveFolder(id: UUID, toParentPath newParent: String) -> Bool {
        guard let folderIdx = folders.firstIndex(where: { $0.id == id }) else { return false }
        let folder = folders[folderIdx]
        let oldPath = folder.fullPath
        let newPath = newParent.isEmpty ? folder.name : "\(newParent)/\(folder.name)"

        // Prevent no-op
        guard newPath != oldPath else { return false }

        // Prevent moving into own descendant (cycle)
        if newParent == oldPath || newParent.hasPrefix(oldPath + "/") { return false }

        // Check depth limit
        let newDepth = newPath.components(separatedBy: "/").count
        guard newDepth <= BookFolder.maxDepth else { return false }

        // Check for name collision at destination
        if folders.contains(where: { $0.fullPath == newPath }) { return false }

        // Also check that the deepest subfolder won't exceed max depth
        let depthIncrease = newDepth - oldPath.components(separatedBy: "/").count
        let maxSubfolderDepth = folders
            .filter { $0.fullPath.hasPrefix(oldPath + "/") }
            .map { $0.depth }
            .max() ?? 0
        if maxSubfolderDepth + depthIncrease > BookFolder.maxDepth { return false }

        // Update the folder itself
        folders[folderIdx].parentPath = newParent

        // Update all subfolders: replace oldPath prefix with newPath
        for i in folders.indices {
            if folders[i].parentPath == oldPath {
                folders[i].parentPath = newPath
            } else if folders[i].parentPath.hasPrefix(oldPath + "/") {
                folders[i].parentPath = newPath + String(folders[i].parentPath.dropFirst(oldPath.count))
            }
        }

        // Update all books in the moved tree
        for i in books.indices {
            if books[i].folderPath == oldPath {
                books[i].folderPath = newPath
            } else if books[i].folderPath.hasPrefix(oldPath + "/") {
                books[i].folderPath = newPath + String(books[i].folderPath.dropFirst(oldPath.count))
            }
        }

        return true
    }

    /// Check whether a folder contains any books or subfolders
    func folderHasContents(_ folder: BookFolder) -> Bool {
        let path = folder.fullPath
        let hasBooks = books.contains {
            $0.folderPath == path || $0.folderPath.hasPrefix(path + "/")
        }
        let hasSubfolders = folders.contains { $0.parentPath == path }
        return hasBooks || hasSubfolders
    }

    /// Count all books recursively inside a folder (including subfolders)
    func totalBooksInFolderTree(_ path: String) -> Int {
        books.filter {
            $0.folderPath == path || $0.folderPath.hasPrefix(path + "/")
        }.count
    }

    mutating func updateWordCounts(bookID: UUID, wordCount: Int, charCount: Int) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[index].totalWordCount = wordCount
        books[index].totalCharacterCount = charCount
    }

    // MARK: - Query

    func booksInFolder(_ path: String) -> [Book] {
        books.filter { $0.folderPath == path }
    }

    /// All books with no folder assignment
    func booksWithNoFolder() -> [Book] {
        books.filter { $0.folderPath.isEmpty }
    }

    func subfolders(of parentPath: String) -> [BookFolder] {
        folders.filter { $0.parentPath == parentPath }.sorted { $0.name < $1.name }
    }

    func bookByHash(_ hash: String) -> Book? {
        books.first { $0.md5Hash == hash }
    }
}
