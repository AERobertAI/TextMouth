import Foundation

// MARK: - Which Books (FR17)

/// Edit Manifest in Default Editor and Edit Manifest With… (FR17): a
/// multi-track audiobook's manifest.json opens in the user's own editor, and
/// TextMouth takes what the user saves as the book's arrangement, as Edit
/// Text takes a book's edited text (FR05, `BookTextEditor`).
///
/// A ZIP's tracks sit unzipped in the book's package, with the ZIP's
/// manifest beside them, so a manifest edited there rearranges the book
/// without importing it again (the user's answer to question 8 of October
/// 13, 2026: "yes A").
enum BookManifestEditing {
    /// Whether `book`'s manifest can be edited, given whether its audio is
    /// a folder of tracks played one per heading (`isTrackFolder`, as
    /// `TrackFolderBooks` has found it): an audiobook of the library's own,
    /// in a package of its own (`LibraryAudioCommand.isAudioEditable`),
    /// never a feed's item, which the user decided is not editable (FR11,
    /// question 4). A single-file audiobook and a converted DAISY book,
    /// whose manifest's sections TextMouth writes itself, are no track
    /// folders, so neither is offered.
    static func canEditManifest(of book: Book, isTrackFolder: Bool) -> Bool {
        LibraryAudioCommand.isAudioEditable(book) && isTrackFolder
    }

    /// Whether `book`'s manifest can be edited, as the app knows which
    /// audiobooks play a folder of tracks (`TrackFolderBooks.shared`).
    @MainActor
    static func canEditManifest(of book: Book) -> Bool {
        canEditManifest(of: book, isTrackFolder: TrackFolderBooks.shared.contains(book.id))
    }

    /// Whether `book`'s audio is a folder of tracks in its own package that
    /// plays one track per heading (`isTrackFolder(_:isDataless:)`). False
    /// for any book `canEditManifest(of:isTrackFolder:)` refuses whatever
    /// its audio, and for a book whose audio folder is not inside its
    /// package. Looks at the disk: call it off the main thread.
    static func hasTrackFolder(_ book: Book, isDataless: (URL) -> Bool = DatalessFiles.isDataless) -> Bool {
        guard canEditManifest(of: book, isTrackFolder: true),
              book.filePath.hasPrefix(book.tmbDirectory.path + "/") else { return false }
        return isTrackFolder(book.bookFileURL, isDataless: isDataless) == true
    }

    /// Whether `folder` is a folder of tracks that plays one track per
    /// heading, as the reader's parse plays it (`AudioBookParser.parseDirectory`):
    /// a folder without a manifest, or whose manifest gives no sections
    /// (`AudioManifest.segments`), the layout the content index calls
    /// `multiFile`. A manifest that cannot be read is read as none, as the
    /// parse reads it, so its tracks play one per heading too.
    ///
    /// False for a file, which is a single-file audiobook, for a folder
    /// whose manifest gives sections, as a converted DAISY book's does, and
    /// for nothing at all. Nil when it cannot be told without downloading
    /// (FR02): the folder or its manifest is only in the cloud. Reads only
    /// the manifest, never a track.
    static func isTrackFolder(_ folder: URL, isDataless: (URL) -> Bool = DatalessFiles.isDataless) -> Bool? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        // The folder is listed to find a manifest inside its one folder,
        // which would download the listing of a folder only in the cloud.
        guard !isDataless(folder) else { return nil }
        guard let location = AudioManifestLocation.find(in: folder) else { return true }
        guard !isDataless(location.url) else { return nil }
        guard let data = try? Data(contentsOf: location.url),
              let manifest = try? AudioManifest.decoded(from: data) else { return true }
        return (manifest.segments ?? []).isEmpty
    }
}
