import Foundation

// MARK: - Where a Feed's Items Live (FR11)

/// Where a feed's downloaded items are kept (FR11, branch A1): each feed has
/// a folder of its own in the data directory's Feeds folder, beside its
/// record, named by the feed's ID alone.
///
/// ```
/// Feeds/
///   <feed ID>.json      the feed's record (`FeedRecord`), as before
///   <feed ID>/          the feed's own folder
///     library.json      its index: one row per package (`FeedIndex`)
///     <item>.tmb/       a package per item downloaded at least once
/// ```
///
/// The folder is outside the Library folder, so none of the library's own
/// passes (orphan adoption, folder edits, Delete Folder) ever reaches it,
/// and `FeedStore` reads only names of the form `<feed ID>.json`, so it
/// never mistakes the folder for a record.
extension FeedPaths {
    /// The name of a feed's index inside its folder.
    static let indexFileName = "library.json"

    /// The folder of the feed `feedID`'s own packages and index, in the data
    /// directory at `root`.
    static func itemsFolder(of feedID: UUID, in root: URL) -> URL {
        recordsFolder(in: root).appendingPathComponent(feedID.uuidString, isDirectory: true)
    }

    /// The index of the feed `feedID`'s packages, in its folder in the data
    /// directory at `root`.
    static func indexFile(of feedID: UUID, in root: URL) -> URL {
        itemsFolder(of: feedID, in: root).appendingPathComponent(indexFileName, isDirectory: false)
    }

    /// The package named `name` of the feed `feedID`, in its folder in the
    /// data directory at `root`.
    static func packageDirectory(named name: String, of feedID: UUID, in root: URL) -> URL {
        itemsFolder(of: feedID, in: root).appendingPathComponent(name, isDirectory: true)
    }

    /// The feed whose folder is named `name`: a name that is exactly a feed's
    /// ID, as TextMouth makes it. A record's name ("<ID>.json"), a sync
    /// service's conflict copy ("<ID> 2"), and any other name name none.
    static func feedID(ofItemsFolderNamed name: String) -> UUID? {
        guard let id = UUID(uuidString: name), id.uuidString == name else { return nil }
        return id
    }
}
