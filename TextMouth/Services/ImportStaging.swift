import Foundation

/// A package an import builds under a hidden name, `.import-<UUID>.tmb`, in
/// the folder it will be published in (TODO S02).
///
/// Nothing in TextMouth treats a hidden directory as a book or a folder:
/// orphan adoption, folder adoption, and empty-folder cleanup all skip
/// hidden names. So every step of an import that can fail (copying, reading
/// the book's text or audio, writing bookInfo.json and reading it back)
/// works on a package no one else can see, and `publish()` renames it to
/// its final name, the single step that makes the book exist. `discard()`
/// removes it after a failure. A staged package that an interrupted import
/// (a crash or a forced quit) left behind is removed by the next import
/// into the same folder.
final class ImportStaging {
    /// What every staged package's name starts with.
    static let namePrefix = ".import-"
    /// What every staged package's name ends with.
    private static let nameSuffix = ".tmb"

    /// The staged package.
    let directory: URL
    /// Where `publish()` puts it: the package's final location.
    let destination: URL
    /// Whether `publish()` has renamed the package; `discard()` then does
    /// nothing.
    private(set) var isPublished = false

    /// The names of the packages imports in this process are staging, which
    /// the cleanup of abandoned ones leaves alone. Imports normally run one
    /// at a time on the import queue, but tests and other callers can run
    /// them on other threads, so the set is locked.
    private static let inUse = StagedNames()

    /// A staging location beside `destination`, with a name no other import
    /// can choose.
    private init(destination: URL) {
        self.destination = destination
        directory = destination.deletingLastPathComponent().appendingPathComponent(
            "\(Self.namePrefix)\(UUID().uuidString)\(Self.nameSuffix)",
            isDirectory: true
        )
    }

    /// The staged package's directory name, which a staged `Book` uses as
    /// its package name so that its `tmbDirectory` is this directory.
    var name: String { directory.lastPathComponent }

    // MARK: - Staging

    /// Stages an empty package for a book to be published at `destination`.
    /// The folder `destination` is in must already exist.
    static func makeEmpty(publishingTo destination: URL) throws -> ImportStaging {
        try reserve(publishingTo: destination) { staged in
            try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: false)
        }
    }

    /// Stages a copy of the package at `source`, to be published at
    /// `destination`. The folder `destination` is in must already exist.
    static func copy(of source: URL, publishingTo destination: URL) throws -> ImportStaging {
        try reserve(publishingTo: destination) { staged in
            try FileManager.default.copyItem(at: source, to: staged)
        }
    }

    /// Creates a staged package with `create`, after removing any that
    /// interrupted imports left in the same folder. The new name is marked
    /// in use before anything exists under it, so no other import's cleanup
    /// can take it. When `create` fails, whatever it made is removed.
    private static func reserve(
        publishingTo destination: URL,
        create: (URL) throws -> Void
    ) throws -> ImportStaging {
        let staging = ImportStaging(destination: destination)
        removeAbandoned(in: destination.deletingLastPathComponent())
        inUse.insert(staging.name)
        do {
            try create(staging.directory)
        } catch {
            staging.discard()
            throw error
        }
        return staging
    }

    // MARK: - Finishing

    /// `book`, described as it is inside this staged package, as it will be
    /// once published: named after the destination, with a file path inside
    /// the staged package moved to the same place inside the destination.
    func published(_ book: Book) -> Book {
        var published = book
        published.tmbDirectoryName = destination.lastPathComponent
        let stagedPrefix = directory.path + "/"
        if book.filePath.hasPrefix(stagedPrefix) {
            published.filePath = destination.path + "/" + book.filePath.dropFirst(stagedPrefix.count)
        }
        return published
    }

    /// Renames the staged package to its destination, which publishes the
    /// book. It never replaces anything: an item already at the destination
    /// makes it throw, and the staged package then stays for `discard()`.
    func publish() throws {
        guard !isPublished else { return }
        try FileManager.default.moveItem(at: directory, to: destination)
        isPublished = true
        Self.inUse.remove(name)
    }

    /// Removes the staged package after a failure. Does nothing once the
    /// package is published, so callers can defer it unconditionally.
    func discard() {
        guard !isPublished else { return }
        Self.removeStagedPackage(at: directory)
        Self.inUse.remove(name)
    }

    // MARK: - Abandoned Packages

    /// Whether `name` is one an import gives its staged package:
    /// `.import-`, a UUID, then `.tmb`.
    static func isStagedPackageName(_ name: String) -> Bool {
        guard name.hasPrefix(namePrefix), name.hasSuffix(nameSuffix) else { return false }
        let identifier = name.dropFirst(namePrefix.count).dropLast(nameSuffix.count)
        return UUID(uuidString: String(identifier)) != nil
    }

    /// Removes the staged packages interrupted imports left directly in
    /// `folder`: directories named as staged packages that no import in
    /// this process is building. Only an import names a directory that way,
    /// and an interrupted import can never be resumed, so each is removed
    /// with everything inside it and the removal is logged. Returns how many
    /// were removed.
    @discardableResult
    static func removeAbandoned(in folder: URL) -> Int {
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        var removed = 0
        for name in names where isStagedPackageName(name) && !inUse.contains(name) {
            let leftover = folder.appendingPathComponent(name, isDirectory: true)
            let values = try? leftover.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            if removeStagedPackage(at: leftover) {
                removed += 1
                let line = "IMPORT_STAGING_REMOVED: \(leftover.path): left by an interrupted import"
                print(line)
                TextMouthPaths.appendLog(to: TextMouthPaths.debugLogFile, message: line)
            }
        }
        return removed
    }

    /// Removes the staged package at `directory` with everything inside it,
    /// and reports whether it is gone. A package that lost its write
    /// permission partway (its folder or volume made read-only, or a test
    /// simulating one) would keep its files, so write permission is then
    /// given back to every directory in it, all of which an import created,
    /// locked files are unlocked, and the removal is tried once more.
    @discardableResult
    static func removeStagedPackage(at directory: URL) -> Bool {
        let fileManager = FileManager.default
        // A removal that succeeds, or finds nothing to remove, is done.
        if (try? fileManager.removeItem(at: directory)) != nil { return true }
        guard fileManager.fileExists(atPath: directory.path) else { return true }
        // Something inside refused to go: make everything removable and
        // try once more.
        makeRemovable(directory)
        do {
            try fileManager.removeItem(at: directory)
            return true
        } catch {
            let line = "IMPORT_STAGING_LEFT: \(directory.path): could not be removed: \(error.localizedDescription)"
            print(line)
            TextMouthPaths.appendLog(to: TextMouthPaths.debugLogFile, message: line)
            return false
        }
    }

    /// Gives write permission back to `directory` and to every directory
    /// inside it, and unlocks every item, so the whole package can be
    /// deleted. Symbolic links are neither followed nor changed: their
    /// targets may lie outside the package.
    private static func makeRemovable(_ directory: URL) {
        let fileManager = FileManager.default
        // The package itself first, so its contents can be listed and changed.
        chmod(directory.path, 0o755)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let items = fileManager.enumerator(at: directory, includingPropertiesForKeys: keys) else { return }
        for case let item as URL in items {
            let values = try? item.resourceValues(forKeys: Set(keys))
            guard values?.isSymbolicLink != true else { continue }
            try? fileManager.setAttributes([.immutable: false], ofItemAtPath: item.path)
            if values?.isDirectory == true {
                chmod(item.path, 0o755)
            }
        }
    }
}

/// A set of staged package names shared by every thread that imports.
private final class StagedNames: @unchecked Sendable {
    private let lock = NSLock()
    private var names: Set<String> = []

    /// Marks `name` in use.
    func insert(_ name: String) {
        lock.lock()
        names.insert(name)
        lock.unlock()
    }

    /// Marks `name` no longer in use.
    func remove(_ name: String) {
        lock.lock()
        names.remove(name)
        lock.unlock()
    }

    /// Whether `name` is in use.
    func contains(_ name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return names.contains(name)
    }
}
