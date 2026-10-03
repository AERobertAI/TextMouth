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
/// The set names books by ID alone. A book that leaves the library leaves
/// its ID behind, which nothing reads: IDs are unique, so another library
/// chosen on this Mac never meets them, and a package taken back into the
/// library keeps its ID, and with it the choice made for it.
@MainActor
final class KeptBooks: ObservableObject {
    /// The set the app uses, saved in this Mac's own folder.
    static let shared = KeptBooks(file: MachineLocalPaths.keptBooks)

    /// The IDs of the books kept on this Mac. Library windows observe it, so
    /// each row's note and commands follow every change.
    @Published private(set) var bookIDs: Set<UUID>

    /// Where the set is saved, or nil for a set that lives only in memory.
    let file: URL?

    /// The set saved at `file`, or an empty one when nothing is saved there
    /// yet. A file that can't be read or decoded keeps no book: it is
    /// preserved beside itself first (`LibraryIndexQuarantine`), so the save
    /// that later replaces it loses nothing, and one KEEP_ON_MAC line says so.
    /// - Parameter file: Where the set is read and saved; nil keeps it in
    ///   memory only, as tests that need no file do.
    init(file: URL?) {
        self.file = file
        bookIDs = file.map(Self.load(from:)) ?? []
    }

    /// Whether the book `bookID` is kept on this Mac.
    func contains(_ bookID: UUID) -> Bool {
        bookIDs.contains(bookID)
    }

    /// How many of `books` are kept on this Mac.
    func count(of books: [Book]) -> Int {
        guard !bookIDs.isEmpty else { return 0 }
        return books.reduce(0) { $0 + (bookIDs.contains($1.id) ? 1 : 0) }
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
    /// Download removes them.
    /// - Returns: The books that were kept and no longer are.
    @discardableResult
    func stopKeeping(_ ids: [UUID]) -> Set<UUID> {
        let removed = Set(ids).intersection(bookIDs)
        guard !removed.isEmpty else { return [] }
        bookIDs.subtract(removed)
        save()
        return removed
    }

    // MARK: - The File

    /// What the file holds: `{"books": [<book ID>, ...]}`, the IDs in order,
    /// so the same set always writes the same bytes.
    private struct Contents: Codable {
        /// The kept books' IDs.
        var books: [UUID]
    }

    /// Replaces the file with the set in one step, making this Mac's folder
    /// first when it is missing. The folder is on this Mac's own disk, so
    /// the write never waits on the network. A failure is logged; the set
    /// still holds for the rest of the session.
    private func save() {
        guard let file else { return }
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let contents = Contents(books: bookIDs.sorted { $0.uuidString < $1.uuidString })
            try encoder.encode(contents).write(to: file, options: .atomic)
        } catch {
            DiagnosticLog.event(
                .storage,
                "KEEP_ON_MAC: could not save \(DiagnosticLog.loggablePath(file)): \(error.localizedDescription); "
                    + "the books chosen stay kept until TextMouth quits"
            )
        }
    }

    /// The set saved at `file`: empty when there is no file. A file that
    /// can't be read or decoded keeps no book: it is preserved beside itself
    /// first (`SavedFile`), and one KEEP_ON_MAC line says so. The file is on
    /// this Mac's own disk, so it is never only in the cloud.
    private static func load(from file: URL) -> Set<UUID> {
        let unusable: (bytes: Data?, reason: String)
        switch SavedFile.read(file, using: SavedFile.readWithoutDownloading) {
        case .missing, .inCloud:
            return []
        case .contents(let data):
            do {
                return Set(try JSONDecoder().decode(Contents.self, from: data).books)
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
        return []
    }
}
