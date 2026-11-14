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
    /// The braille table the book was read with when it was removed (FMT21),
    /// by its stored value as `Book.brailleTable` keeps it ("mac:" before
    /// the file name of one of this Mac's tables), or nil for a book that is
    /// not braille. bookInfo.json, which also holds
    /// it, is deleted by the removal, so a book added back from this marker
    /// would otherwise be read again with the default table. A marker written
    /// before this field existed has none, and decodes without it.
    let brailleTable: String?
    /// The liblouis version of this Mac's tables the book was read with
    /// (`Book.brailleTableVersion`, review R2), so a book added back still
    /// refuses a rebuild after a macOS update changed its table. Nil for a
    /// bundled table and for a marker written before it was kept.
    let brailleTableVersion: String?
    /// Who chose the braille table (`Book.brailleTableOrigin`, brfguess), so
    /// a book added back keeps "guessed" said of its table. Nil for every
    /// other book and for a marker written before it was kept; a value that
    /// cannot be read is nil too, and never makes the marker unreadable.
    @LenientOptional var brailleTableOrigin: BrailleTableOrigin? = nil
    /// The braille file characters the book's BRF or BRL file was read in
    /// (`Book.brailleFileCode`, braillecodes), by the code's id. bookInfo.json,
    /// which also holds it, is deleted by the removal, so a book added back
    /// from this marker would otherwise be read as North American Braille
    /// ASCII, which would change its text under the places it keeps. Nil
    /// for a book that records none, and for a marker written before it was
    /// kept; a value that cannot be read is nil too, and never makes the
    /// marker unreadable.
    @LenientOptional var brailleFileCode: String? = nil
    /// The encoding the book's text file was guessed to be in
    /// (`Book.textEncoding`, FMT16), so that a book added back from this
    /// marker is read as it was, not by the Windows-1252 fallback, which
    /// would change its text under the places it keeps. Nil for a book with
    /// none, and for a marker written before it was kept.
    let textEncoding: String?
    /// Who decided `textEncoding` (`Book.textEncodingSource`,
    /// encodingchoice), so a book added back keeps the listener's choice.
    /// Nil for the import, and for a marker written before it was kept; a
    /// value that cannot be read, as a later TextMouth's might be, is nil
    /// too, and never makes the marker unreadable.
    @LenientOptional var textEncodingSource: TextEncodingSource? = nil
    /// The record of the edit the user took with Edit Text that the book's
    /// content.md held when it was removed (`Book.editedText`, B12). The
    /// removal leaves content.md in the package, so a book added back from
    /// this marker keeps that text, which would otherwise be read again
    /// from the book's file over the edit. Nil for a book whose text was not
    /// edited, and for a marker written before it was kept; a value that
    /// cannot be read is nil too, and never makes the marker unreadable.
    @LenientOptional var editedText: EditedText? = nil
    /// The fingerprints of the book's file and of its content.md when it was
    /// removed (`Book.textCacheFingerprint`), which describe the text a book
    /// added back from this marker finds: Redo Text Extraction keeps a copy
    /// of an edit, and a re-read a copy of text changed by hand, only while
    /// the book has them. Nil for a book without a text cache, and for a
    /// marker written before it was kept; read as leniently as `editedText`.
    @LenientOptional var textCacheFingerprint: TextCacheFingerprint? = nil

    /// The marker recording that `book` was removed at `removedAt`.
    init(book: Book, removedAt: Date = Date()) {
        bookID = book.id
        title = book.title
        author = book.author
        self.removedAt = removedAt
        brailleTable = book.brailleTable
        brailleTableVersion = book.brailleTableVersion
        textEncoding = book.textEncoding
        // The wrapped fields last, once every stored constant is set.
        brailleFileCode = book.brailleFileCode
        textEncodingSource = book.textEncodingSource
        brailleTableOrigin = book.brailleTableOrigin
        editedText = book.editedText
        textCacheFingerprint = book.textCacheFingerprint
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

    /// Deletes the marker from `package` for a deliberate return of its
    /// book. A package without a marker is left as it is.
    static func remove(from package: URL) throws {
        let url = TextMouthPaths.removedFromLibraryMarkerPath(in: package)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

// MARK: - Startup Repair

extension RemovedFromLibraryMarker {

    /// Takes out of `library` every book whose own package holds a marker
    /// retiring it, and returns those books. Their packages and content stay
    /// on disk, untouched. Each leaves through `Library.removeBook(id:)`, so
    /// it leaves the reading list too (FR09).
    ///
    /// An index lists such a book only when it was saved before the removal:
    /// the app stopped before the removal's debounced save reached the disk,
    /// the removal happened while the index could not be read and Try Again
    /// then loaded it, or an older copy of the index was put back. The marker
    /// is the later decision, and the metadata queue drops every write into
    /// a retired package, so the book is taken out rather than left listed
    /// with its package no longer saved.
    ///
    /// - Parameter spared: Books whose markers are not read here, which keep
    ///   their rows: those whose markers are only in the cloud (FR02), which
    ///   a read would download, and which count as retiring their books
    ///   while they cannot be read.
    @discardableResult
    static func removeRetiredBooks(from library: inout Library, sparing spared: Set<UUID> = []) -> [Book] {
        let retired = library.books.filter { !spared.contains($0.id) && retires($0) }
        for book in retired {
            library.removeBook(id: book.id)
            log("kept out of the library: its package records that it was removed", for: book)
        }
        return retired
    }
}

// MARK: - Logging

extension RemovedFromLibraryMarker {

    /// Records a Remove from Library Only event for `book` as a storage
    /// event, naming the book by the start of its ID.
    static func log(_ message: String, for book: Book) {
        DiagnosticLog.event(.storage, "LIBRARY_REMOVAL: book \(book.id.uuidString.prefix(8)): \(message)")
    }
}

// MARK: - Retiring a Package

/// What Remove from Library Only did to a book's package on disk
/// (`LibraryPersistenceService.retirePackage(of:)`).
struct PackageRetirement {
    /// Whether the package now holds a removal marker. False only for a
    /// record with no package on disk, which adoption could never find.
    let isPackageMarked: Bool
    /// Why the package's bookInfo.json could not be deleted, when it could
    /// not. The book stays out of the library regardless: the marker, not
    /// the missing record, is what keeps it out.
    let recordDeletionError: (any Error)?
}

/// Why Remove from Library Only kept a book in the library.
enum LibraryRemovalError: LocalizedError {
    /// The removal marker could not be written into the named package, so
    /// nothing would keep orphan adoption from bringing the book back.
    case couldNotMarkPackage(packageName: String, underlying: any Error)

    var errorDescription: String? {
        switch self {
        case .couldNotMarkPackage(let packageName, let underlying):
            return "TextMouth could not record the removal in its package, \(packageName). "
                + underlying.localizedDescription
        }
    }
}
