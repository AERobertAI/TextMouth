import Foundation

/// One location of the data directory as this process uses it (TODO S04).
///
/// Every file TextMouth keeps lives under the data directory's root, and the
/// root changes only when a data-directory move publishes its copy. A
/// generation numbers those changes: the location the process started with
/// is generation 0, and each published move starts the next. Work that
/// writes into the data directory resolves its paths under the current
/// generation (`StorageBoundary`), so a write prepared under one root never
/// lands under another.
struct StorageGeneration: Sendable {
    /// How many moves this process had published when this generation
    /// began: 0 for the location the process started with.
    let number: Int
    /// The data directory, spelled as `TextMouthPaths.root` returns it: as
    /// the preferences name it, or the default location.
    let root: URL
    /// The data directory as named and as the file system resolved it when
    /// the generation began, so a path spelled through a link that leads
    /// there is recognized as inside it too.
    let location: DataDirectoryLocation
}

extension StorageGeneration: Equatable {
    /// Two generations are the same when they have the same number and the
    /// same root. Paths are compared, not URLs: URLs for one folder can
    /// differ in whether they are marked as directories.
    static func == (lhs: StorageGeneration, rhs: StorageGeneration) -> Bool {
        lhs.number == rhs.number && lhs.root.path == rhs.root.path
    }
}

/// Where the data directory is now, and the boundary between data-directory
/// moves and the work that writes into the data directory (TODO S04).
///
/// `TextMouthPaths.root` is the root of the current generation. A
/// data-directory move publishes the next generation (`publish(root:)`)
/// only once its copy is in place, and nothing else changes it, so two
/// reads of the root by one piece of work can differ only across a
/// published move. In the app the first generation is the location the
/// preferences name; a process hosting tests always starts in its sandbox,
/// and only a move a test publishes, into a folder of its own, takes it
/// elsewhere until the test puts it back.
///
/// `@unchecked Sendable`: every stored property is guarded by `condition`,
/// which is never held while calling out, so nothing reached from here,
/// such as a log line that names a path inside the data directory, can
/// wait for it.
final class StorageBoundary: @unchecked Sendable {
    /// The boundary of this process, starting at the data directory its
    /// runtime names (`TextMouthPaths.root(for:)`).
    static let shared = StorageBoundary(root: TextMouthPaths.root(for: .current))

    /// Guards every stored property below.
    private let condition = NSCondition()
    /// The generation in use.
    private var generation: StorageGeneration
    /// Every earlier generation, oldest first, so a path captured under any
    /// of them can be moved under the current root.
    private var earlierGenerations: [StorageGeneration] = []

    /// A boundary whose first generation is the data directory at `root`.
    init(root: URL) {
        generation = StorageGeneration(number: 0, root: root, location: DataDirectoryLocation(root))
    }

    // MARK: - Generations

    /// The generation in use now.
    var current: StorageGeneration {
        condition.lock()
        defer { condition.unlock() }
        return generation
    }

    /// Makes the data directory at `root` the current one, as the next
    /// generation, and returns that generation. A data-directory move calls
    /// this once its copy is published (`TextMouthPaths.moveDataDirectory`);
    /// tests call it to put the data directory back where it was.
    @discardableResult
    func publish(root: URL) -> StorageGeneration {
        // Resolved before taking the lock: resolving reads the file system.
        let location = DataDirectoryLocation(root)
        condition.lock()
        defer { condition.unlock() }
        earlierGenerations.append(generation)
        generation = StorageGeneration(number: generation.number + 1, root: root, location: location)
        return generation
    }

    /// The current generation and the earlier ones, read together.
    private func generations() -> (current: StorageGeneration, earlier: [StorageGeneration]) {
        condition.lock()
        defer { condition.unlock() }
        return (generation, earlierGenerations)
    }

    // MARK: - Paths Captured Earlier

    /// `path` at its place under the current root, when it was captured
    /// under an earlier generation: a path inside an earlier generation's
    /// data directory, and not inside the current one, moves to the same
    /// place in the current one, taken from the most recent such
    /// generation. Any other path, and every path until a move has
    /// published, is returned as it is.
    ///
    /// Work that captured paths before a move published, such as a library
    /// snapshot waiting for its save or a book a batch queued, passes them
    /// through here before it reads or writes anything, so it never writes
    /// under the old root or recreates it (TODO S04).
    func rebasedToCurrent(_ path: String) -> String {
        let (current, earlier) = generations()
        return Self.rebase(path, to: current, from: earlier) ?? path
    }

    /// `book` with its file path at its place under the current root, when
    /// it was captured under an earlier generation (see
    /// `rebasedToCurrent(_:)` for a path). Nothing else about it changes:
    /// its package is named by its folder and package name, which do not
    /// depend on the root.
    func rebasedToCurrent(_ book: Book) -> Book {
        let (current, earlier) = generations()
        guard let moved = Self.rebase(book.filePath, to: current, from: earlier) else { return book }
        var rebased = book
        rebased.filePath = moved
        return rebased
    }

    /// Moves every book path in `library` captured under an earlier
    /// generation to its place under the current root (see
    /// `rebasedToCurrent(_:)` for a path).
    /// - Returns: How many books' paths moved.
    @discardableResult
    func rebaseToCurrent(_ library: inout Library) -> Int {
        let (current, earlier) = generations()
        var moved = 0
        for index in library.books.indices {
            if let path = Self.rebase(library.books[index].filePath, to: current, from: earlier) {
                library.books[index].filePath = path
                moved += 1
            }
        }
        return moved
    }

    /// `path` moved from the most recent of `earlier` that holds it to the
    /// same place under `current`, spelled as the migrator spells the books
    /// it moves; nil when `path` is inside `current`'s data directory or
    /// inside none of `earlier`.
    private static func rebase(
        _ path: String,
        to current: StorageGeneration,
        from earlier: [StorageGeneration]
    ) -> String? {
        guard !earlier.isEmpty, !current.location.contains(path) else { return nil }
        for generation in earlier.reversed() {
            if let moved = generation.location.relocating(path, to: current.location.named) {
                return moved
            }
        }
        return nil
    }
}
