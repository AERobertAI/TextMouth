import Foundation

// MARK: - Bringing the Library's Own Files to This Mac

/// Reads one item of the library that is only in the cloud, with downloads
/// allowed, so the sync service brings it to this Mac. It blocks until the
/// item arrives or fails, so call it off the main thread. A test passes a
/// fake in its place and never touches a real cloud.
typealias LibraryFileFetch = @Sendable (URL) throws -> Void

/// The real fetch of the files the data directory check names (the identity
/// marker, library.json, the Feeds folder, and each feed's folder and
/// index), never a book or an episode.
///
/// Apple's TN3150 says any read of a dataless item downloads it, and listing
/// a folder brings the folder's entries. A provider that fetches partial
/// content (Google Drive and Dropbox adopt `NSFileProviderPartialContentFetching`)
/// brings only the range a read asks for, so a file is read to its end, and
/// the chunks are discarded: no large file is ever held in memory. Nothing
/// here asks the sync service by name, so it works on every File Provider
/// drive, Google Drive's Stream mode included.
enum LibraryFileFetcher {
    /// How many bytes one read of a file asks for.
    private static let chunkSize = 65_536

    /// The fetch the app uses.
    static let app: LibraryFileFetch = { item in try fetch(item) }

    /// Brings `item` to this Mac: a folder is listed, and a file is read to
    /// its end in chunks that are thrown away. Throws what the read threw,
    /// such as a network error while the Mac is offline.
    ///
    /// Must run with the thread's default download policy, never inside
    /// `DatalessFiles.withoutDownloading`.
    static func fetch(_ item: URL) throws {
        var isFolder: ObjCBool = false
        // A stat reads metadata only, so it does not download the item. An
        // item it can't find is read as a file, which throws the reason.
        if FileManager.default.fileExists(atPath: item.path, isDirectory: &isFolder), isFolder.boolValue {
            _ = try FileManager.default.contentsOfDirectory(atPath: item.path)
            return
        }
        let handle = try FileHandle(forReadingFrom: item)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {}
    }
}
