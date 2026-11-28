import Foundation

/// The package of a book another device has and this one has not fetched yet
/// (FR43, section 6 of the build plan): its bookInfo.json, made from the
/// row the merge gave it, and its `.storeCopy.json` pointer, which names the
/// store, the book's manifest, and which files are here. It holds no book
/// file, so every file-level check reads it as a book not downloaded: the
/// library lists it as In Cloud, and Download Now fetches it (`StoreBookStorage`).
///
/// This file makes and reads the placeholder; the fetch that fills it in
/// belongs to sync-store. Both platforms use it.
enum SyncPlaceholder {
    /// Why a placeholder could not be made.
    enum Failure: Error, Equatable {
        /// The row names a library folder path the library refuses.
        case invalidFolderPath
        /// The row's package name is not one the library manages.
        case invalidPackageName
    }

    /// Makes the package of `newBook` in the library directory and returns
    /// its row, ready to join the library: the package's name, the content
    /// file's place in it, and what the content describes (hash, format,
    /// date added, counts) filled in. Making it again, as after a crash,
    /// writes the same files over each other and changes nothing else.
    /// - Parameters:
    ///   - storeID: The sync folder's store, which the pointer names.
    ///   - libraryDirectory: Where the library's folders are; the data
    ///     directory's by default, a scratch folder in tests.
    /// - Throws: `Failure` for a name or folder the library refuses, or the
    ///   file system's error.
    static func makePackage(
        for newBook: SyncNewBook,
        storeID: UUID,
        libraryDirectory: URL = TextMouthPaths.libraryDir
    ) throws -> Book {
        var book = newBook.book
        let content = newBook.content
        guard BookFolder.isValidLibraryPath(book.folderPath) else { throw Failure.invalidFolderPath }
        if book.tmbDirectoryName.isEmpty {
            book.tmbDirectoryName = TextMouthPaths.tmbName(
                title: book.title, author: book.author, dateAdded: content.dateAdded, bookID: book.id
            )
        }
        guard FileImportService.isManagedPackageName(book.tmbDirectoryName) else { throw Failure.invalidPackageName }

        // The content file's name is the row's if it has one; the fetch puts
        // the manifest's file there.
        let contentName = book.filePath.isEmpty ? "" : URL(fileURLWithPath: book.filePath).lastPathComponent
        let package = packageDirectory(of: book, in: libraryDirectory)
        book.filePath = package.appendingPathComponent(contentName.isEmpty ? defaultContentName : contentName).path
        book.format = content.format
        book.dateAdded = content.dateAdded
        book.md5Hash = content.md5Hash
        book.totalWordCount = content.totalWordCount ?? book.totalWordCount
        book.audioDuration = content.audioDuration ?? book.audioDuration

        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try book.saveBookInfoThrowing(inPackageAt: package)
        let pointer = StorePointer(
            formatVersion: SyncFormats.currentVersion, storeID: storeID, bookID: book.id, manifest: content.manifest, uploaded: nil, files: []
        )
        try StoreFetch.write(pointer, in: package)
        return book
    }

    /// The name given to a content file when the row names none.
    static let defaultContentName = "book"

    /// Where `book`'s package is in the library at `libraryDirectory`.
    static func packageDirectory(of book: Book, in libraryDirectory: URL) -> URL {
        let folder = book.folderPath.isEmpty
            ? libraryDirectory
            : libraryDirectory.appendingPathComponent(book.folderPath, isDirectory: true)
        return folder.appendingPathComponent(book.tmbDirectoryName, isDirectory: true)
    }

    /// When the files of the book at `package` last arrived on this device: the date the pointer was last
    /// written, which a fetch does after each file it brings in and a backup does when a book's copy has
    /// uploaded (FR45). Nil when the package has no pointer, or it cannot be read.
    static func arrivedAt(_ package: URL) -> Date? {
        let pointer = package.appendingPathComponent(StorePointer.fileName)
        return DatalessFiles.withoutDownloading {
            try? pointer.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
    }

    /// Whether the package at `package` is a placeholder: it holds a pointer
    /// and the book's file is not on this device. A package with a pointer
    /// and its file is a fetched book, which keeps the pointer.
    static func isPlaceholder(package: URL, contentFile: URL) -> Bool {
        StoreFetch.pointer(in: package) != nil && !FileManager.default.fileExists(atPath: contentFile.path)
    }
}
