import Combine
import Foundation

/// Which audiobooks play a folder of tracks, one per heading, for the
/// commands that edit a book's manifest (FR17, `BookManifestEditing`).
///
/// A book's row cannot tell a folder of tracks from a converted DAISY
/// book's folder of sections: both are audiobooks whose file is a folder in
/// their package, and only the manifest says which. This store looks at
/// each audiobook's folder instead, off the main thread, reading only a
/// manifest that is on this Mac and downloading nothing: as a Library
/// window appears, as the number of books changes, and as TextMouth
/// becomes active, as `TranscribedBooks` looks for transcripts. A look
/// superseded by a later one records nothing.
@MainActor
final class TrackFolderBooks: ObservableObject {
    /// The app's store.
    static let shared = TrackFolderBooks()

    /// The books whose audio is a folder of tracks, by ID.
    @Published private(set) var bookIDs: Set<UUID> = []

    /// How many looks have begun: only the latest one records what it found.
    private var lookCount = 0

    /// A store with nothing recorded. The app uses `shared`; tests make
    /// their own.
    init() {}

    /// Whether the book `bookID`'s audio is a folder of tracks.
    func contains(_ bookID: UUID) -> Bool {
        bookIDs.contains(bookID)
    }

    /// Looks at each of `books`' audio folders off the main thread and
    /// records which are folders of tracks (`BookManifestEditing.hasTrackFolder`),
    /// in one change, published only when something changed. Only the
    /// audiobooks whose manifest could be edited are looked at. `isDataless`
    /// tells a file only in the cloud; tests stand in for it.
    func refresh(_ books: [Book], isDataless: @escaping @Sendable (URL) -> Bool = DatalessFiles.isDataless) async {
        lookCount += 1
        let look = lookCount
        let candidates = books.filter { BookManifestEditing.canEditManifest(of: $0, isTrackFolder: true) }
        let found = await OffMainWork.run(on: .global(qos: .utility)) {
            Set(candidates.filter { BookManifestEditing.hasTrackFolder($0, isDataless: isDataless) }.map(\.id))
        }
        guard look == lookCount, found != bookIDs else { return }
        bookIDs = found
    }
}
