import Combine
import Foundation

// MARK: - Keep on This Mac (FR02 Polish)

/// The books this Mac keeps downloaded (Keep on This Mac), by ID.
///
/// A kept book stays on this Mac: TextMouth downloads it at once when it is
/// only in the cloud, downloads it again when a cloud refresh finds that the
/// sync service removed its download, and refuses Remove Download for it
/// (`LibraryCloudCommands`). Keeping a book is this Mac's choice alone, as
/// Finder's Keep Downloaded is: another Mac that opens the same library keeps
/// only the books chosen there. So the set is saved in this Mac's own folder
/// (`MachineLocalPaths.keptBooks`), which never syncs, and never in
/// library.json or a book's package record, which every Mac reads.
///
/// A second reason keeps a book (the user, November 13, 2026: "if the main
/// library is in the cloud keep all the reading list books downloaded"):
/// the book is on the reading list, while this Mac's own choice, "Keep these
/// books on this Mac", is on. That reason is derived, never stored: the
/// library model hands over the list's books each time they change
/// (`setReadingListBooks(_:)`), and the set never reaches the file, which
/// holds only the books the listener chose. A book that leaves the list
/// stops being kept for it, and nothing is removed from this Mac by that, as
/// stopping a keep removes nothing. `contains(_:)` answers for the
/// listener's own choice alone; `isKept(_:)` for either reason.
///
/// Like every kept book, a list book is kept only in a cloud library: the
/// rows, the commands, and the refresh that downloads kept books all act on
/// kept books only there (`BookCloudStates.showsCloudNotes`).
///
/// The set names books by ID alone. A book that leaves the library leaves
/// its ID behind, which nothing reads: IDs are unique, so another library
/// chosen on this Mac never meets them, and a package taken back into the
/// library keeps its ID, and with it the choice made for it.
@MainActor
final class KeptBooks: ObservableObject {
    /// The set the app uses, saved in this Mac's own folder.
    static let shared = KeptBooks(
        file: MachineLocalPaths.keptBooks,
        settingFile: MachineLocalPaths.keepReadingListBooks
    )

    /// The IDs of the books the listener keeps on this Mac. Library windows
    /// observe it, so each row's note and commands follow every change.
    @Published private(set) var bookIDs: Set<UUID>

    /// The reading list's books as the library model last handed them over
    /// (`setReadingListBooks(_:)`): derived, in memory only, and counted as
    /// kept only while `keepsReadingListBooks` is on.
    @Published private(set) var readingListBookIDs: Set<UUID> = []

    /// Whether this Mac keeps the reading list's books downloaded in a cloud
    /// library: this Mac's own choice, on until cleared, saved in its own
    /// folder (`settingFile`) and never in the library, which every Mac
    /// reads.
    @Published private(set) var keepsReadingListBooks: Bool

    /// Where the set is saved, or nil for a set that lives only in memory.
    let file: URL?

    /// Where `keepsReadingListBooks` is saved, or nil for a choice that
    /// lives only in memory.
    let settingFile: URL?

    /// The set saved at `file`, or an empty one when nothing is saved there
    /// yet, and the choice saved at `settingFile`, or on when nothing is
    /// saved there yet. A file that can't be read or decoded keeps no book
    /// (and leaves the choice on): it is preserved beside itself first
    /// (`LibraryIndexQuarantine`), so the save that later replaces it loses
    /// nothing, and one KEEP_ON_MAC line says so.
    /// - Parameters:
    ///   - file: Where the set is read and saved; nil keeps it in memory
    ///     only, as tests that need no file do.
    ///   - settingFile: Where the choice to keep the reading list's books is
    ///     read and saved; nil keeps it in memory only, on.
    init(file: URL?, settingFile: URL? = nil) {
        self.file = file
        self.settingFile = settingFile
        bookIDs = file.flatMap { Self.loadContents(KeptBooksFile.self, from: $0) }.map { Set($0.books) } ?? []
        keepsReadingListBooks = settingFile
            .flatMap { Self.loadContents(ReadingListKeepFile.self, from: $0) }?.keepsReadingListBooks ?? true
    }

    /// Whether the listener keeps the book `bookID` on this Mac, by their
    /// own choice. A book kept only for the reading list is not in this
    /// sense (`isKept(_:)`).
    func contains(_ bookID: UUID) -> Bool {
        bookIDs.contains(bookID)
    }

    /// Whether the book `bookID` is kept because it is on the reading list
    /// and this Mac keeps the list's books (`keepsReadingListBooks`),
    /// whether or not the listener also kept it themselves.
    func isKeptForReadingList(_ bookID: UUID) -> Bool {
        keepsReadingListBooks && readingListBookIDs.contains(bookID)
    }

    /// Whether the book `bookID` is kept on this Mac for either reason: the
    /// listener kept it, or it is on the reading list being kept.
    func isKept(_ bookID: UUID) -> Bool {
        bookIDs.contains(bookID) || isKeptForReadingList(bookID)
    }

    /// Whether the book `bookID` is kept only because of the reading list:
    /// the listener's own choice does not keep it, so Stop Keeping on This
    /// Mac has nothing to stop.
    func isKeptOnlyForReadingList(_ bookID: UUID) -> Bool {
        !bookIDs.contains(bookID) && isKeptForReadingList(bookID)
    }

    /// Whether any book is kept, for either reason.
    var keepsAnyBook: Bool {
        !bookIDs.isEmpty || (keepsReadingListBooks && !readingListBookIDs.isEmpty)
    }

    /// How many of `books` are kept on this Mac, for either reason.
    func count(of books: [Book]) -> Int {
        guard keepsAnyBook else { return 0 }
        return books.reduce(0) { $0 + (isKept($1.id) ? 1 : 0) }
    }

    /// Takes `ids`, the reading list's books in any order, as the books kept
    /// for the list while `keepsReadingListBooks` is on. Nothing is saved:
    /// the list is the library's, and this set derives from it.
    func setReadingListBooks(_ ids: Set<UUID>) {
        guard ids != readingListBookIDs else { return }
        readingListBookIDs = ids
    }

    /// Makes this Mac keep the reading list's books downloaded (in a cloud
    /// library), or not, saving the choice when it changed. Turning it off
    /// removes nothing from this Mac.
    func setKeepsReadingListBooks(_ keeps: Bool) {
        guard keeps != keepsReadingListBooks else { return }
        keepsReadingListBooks = keeps
        guard let settingFile else { return }
        Self.write(ReadingListKeepFile(keepsReadingListBooks: keeps), to: settingFile)
    }

    /// Keeps the books `ids` on this Mac, saving the set when it changed.
    /// - Returns: The books kept now that were not kept before.
    @discardableResult
    func keep(_ ids: [UUID]) -> Set<UUID> {
        let added = Set(ids).subtracting(bookIDs)
        guard !added.isEmpty else { return [] }
        bookIDs.formUnion(added)
        save()
        return added
    }

    /// Stops keeping the books `ids` on this Mac, saving the set when it
    /// changed. Their downloads stay until the sync service or Remove
    /// Download removes them. A book on the reading list stays kept for it.
    /// - Returns: The books that were kept and no longer are.
    @discardableResult
    func stopKeeping(_ ids: [UUID]) -> Set<UUID> {
        let removed = Set(ids).intersection(bookIDs)
        guard !removed.isEmpty else { return [] }
        bookIDs.subtract(removed)
        save()
        return removed
    }

    // MARK: - The Files

    /// What the file of kept books holds: `{"books": [<book ID>, ...]}`, the
    /// IDs in order, so the same set always writes the same bytes.
    private struct KeptBooksFile: Codable {
        /// The kept books' IDs.
        var books: [UUID]
    }

    /// What the file of the reading list choice holds:
    /// `{"keepsReadingListBooks": true}`.
    private struct ReadingListKeepFile: Codable {
        /// Whether this Mac keeps the reading list's books downloaded.
        var keepsReadingListBooks: Bool
    }

    /// Replaces the file of kept books with the set in one step.
    private func save() {
        guard let file else { return }
        Self.write(KeptBooksFile(books: bookIDs.sorted { $0.uuidString < $1.uuidString }), to: file)
    }

    /// Replaces `file` with `contents` in one step, making this Mac's folder
    /// first when it is missing. The folder is on this Mac's own disk, so
    /// the write never waits on the network. A failure is logged; what was
    /// chosen still holds for the rest of the session.
    private static func write<Contents: Encodable>(_ contents: Contents, to file: URL) {
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(contents).write(to: file, options: .atomic)
        } catch {
            DiagnosticLog.event(
                .storage,
                "KEEP_ON_MAC: could not save \(DiagnosticLog.loggablePath(file)): \(error.localizedDescription); "
                    + "what was chosen stays so until TextMouth quits"
            )
        }
    }

    /// What `file` holds, decoded as `Contents`: nil when there is no file.
    /// A file that can't be read or decoded gives nil too: it is preserved
    /// beside itself first (`SavedFile`), and one KEEP_ON_MAC line says so.
    /// The file is on this Mac's own disk, so it is never only in the cloud.
    private static func loadContents<Contents: Decodable>(_ type: Contents.Type, from file: URL) -> Contents? {
        let unusable: (bytes: Data?, reason: String)
        switch SavedFile.read(file, using: SavedFile.readWithoutDownloading) {
        case .missing, .inCloud:
            return nil
        case .contents(let data):
            do {
                return try JSONDecoder().decode(Contents.self, from: data)
            } catch {
                unusable = (data, error.localizedDescription)
            }
        case .unreadable(let reason):
            unusable = (nil, reason)
        }
        SavedFile.preserveUnusable(
            file,
            bytes: unusable.bytes,
            because: unusable.reason,
            logging: "KEEP_ON_MAC",
            in: .storage,
            standIn: "no book is kept on this Mac until one is kept again"
        )
        return nil
    }
}
