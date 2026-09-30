import Foundation

/// The record, kept inside a book's `.tmb` package, that Remove from Library
/// Only took the book out of the library while leaving the package and its
/// content file on disk for a later re-import (TODO S06).
///
/// Removing the library row alone does not last. Orphan adoption re-adds
/// every package with a readable bookInfo.json that the index does not list,
/// and a queued or background metadata write can recreate the bookInfo.json
/// that the removal deleted. So the removal writes this marker before it
/// removes the row, and whatever could bring the book back checks it. Only a
/// deliberate return, such as importing the package again, deletes it.
///
/// The file's presence is what counts. Its contents name the book, so that
/// someone browsing the package can see what happened, and so that a marker
/// in a legacy package still shared by two library records retires only the
/// book it names. A marker that exists but cannot be read retires whichever
/// book the package holds, because only a removal ever writes this file.
struct RemovedFromLibraryMarker: Codable, Equatable, Sendable {
    /// ID of the book that was removed.
    let bookID: UUID
    /// The book's title when it was removed, for people reading the file.
    let title: String
    /// The book's author when it was removed, for people reading the file.
    let author: String
    /// When the book was removed.
    let removedAt: Date

    /// The marker recording that `book` was removed at `removedAt`.
    init(book: Book, removedAt: Date = Date()) {
        bookID = book.id
        title = book.title
        author = book.author
        self.removedAt = removedAt
    }
}

// MARK: - Checking a Package

extension RemovedFromLibraryMarker {

    /// Whether `package` holds a marker retiring the book with `bookID`: one
    /// that names that book, or one that exists but cannot be read. A marker
    /// naming a different book does not retire this one.
    static func retires(_ bookID: UUID, in package: URL) -> Bool {
        let url = TextMouthPaths.removedFromLibraryMarkerPath(in: package)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let marker = try? read(in: package) else { return true }
        return marker.bookID == bookID
    }

    /// Whether `book`'s own package holds a marker retiring it. A record
    /// without a package name has no package that could hold one.
    static func retires(_ book: Book) -> Bool {
        guard !book.tmbDirectoryName.isEmpty else { return false }
        return retires(book.id, in: book.tmbDirectory)
    }
}

// MARK: - Reading and Writing

extension RemovedFromLibraryMarker {

    /// Writes this marker into `package`, replacing any earlier one. The write
    /// is atomic, so the file is either absent or complete. Throws when the
    /// marker could not be written, and then the package is not retired.
    func write(into package: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: TextMouthPaths.removedFromLibraryMarkerPath(in: package), options: .atomic)
    }

    /// Reads the marker in `package`. Throws when there is none or when it
    /// cannot be decoded.
    static func read(in package: URL) throws -> RemovedFromLibraryMarker {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: TextMouthPaths.removedFromLibraryMarkerPath(in: package))
        return try decoder.decode(RemovedFromLibraryMarker.self, from: data)
    }
}
