import Foundation

/// A package an import builds under a hidden name, `.import-<UUID>.tmb`,
/// before publishing it in a folder of the library (TODO S02).
///
/// It is built in this Mac's Import Staging folder
/// (`MachineLocalPaths.importStaging`) while the data directory is on that
/// folder's volume, and otherwise beside its destination, in the folder it
/// will be published in (FR02, `ImportScratchSpace`). A data directory in a
/// cloud folder then never uploads a package that is still being built, and
/// publishing is one rename on one volume either way.
///
/// Nothing in TextMouth treats a hidden directory as a book or a folder:
/// orphan adoption, folder adoption, and empty-folder cleanup all skip
/// hidden names. So every step of an import that can fail (copying, reading
/// the book's text or audio, writing bookInfo.json and reading it back)
/// works on a package no one else can see, and `publish()` renames it to
/// its final name, the single step that makes the book exist. `discard()`
/// removes it after a failure. A staged package that an interrupted import
/// (a crash or a forced quit) left behind is removed by the next import
/// that stages in the same folder; one that an earlier version left in a
/// library folder is removed by the next import into that folder.
///
/// While an import stages a book, the book's package name is the staged
/// package's name, and its `tmbDirectory` is the staged package, wherever
/// that is (`directory(ofStagedPackage:)`).
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

    /// The packages imports in this process are staging, by name, which the
    /// cleanup of abandoned ones leaves alone and through which a staged
    /// book finds its package. Imports normally run one at a time on the
    /// import queue, but tests and other callers can run them on other
    /// threads, so the record is locked.
    private static let inUse = NamesInUse()

    /// A staging location in `folder`, with a name no other import can
    /// choose, for a package to be published at `destination`.
    private init(destination: URL, folder: URL) {
        self.destination = destination
        directory = folder.appendingPathComponent(Self.freshName(), isDirectory: true)
    }

    /// A staged package's name no other can have: `.import-`, a new UUID,
    /// then `.tmb`. Replace Existing sets a replaced package aside under one
    /// before deleting it (ST04, `DuplicateReplacement`), so that a deletion
    /// stopped partway leaves only what every walk of the library passes
    /// over and the next import into its folder removes
    /// (`removeAbandoned(in:)`).
    static func freshName() -> String {
        "\(namePrefix)\(UUID().uuidString)\(nameSuffix)"
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

    /// Copies every item the package at `source` holds, hidden ones
    /// included, into this staged package, as made by `makeEmpty`, so the
    /// staged package holds what a copy of the whole package would. The
    /// staged package exists before anything is copied, so the import
    /// names it to the step that copies, as every other import's copy is
    /// named (REV13). A copy that fails partway leaves what it copied for
    /// `discard()`; the source is never changed.
    func copyContents(of source: URL) throws {
        let items = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: [])
        for item in items {
            try FileManager.default.copyItem(at: item, to: directory.appendingPathComponent(item.lastPathComponent))
        }
    }

    /// Creates a staged package with `create`, in the folder
    /// `ImportScratchSpace` stages in, after removing any that interrupted
    /// imports left there. When that is this Mac's folder, the packages an
    /// earlier version left in the destination's own folder go too; that
    /// folder is listed with dataless files left in the cloud. The new name
    /// is marked in use before anything exists under it, so no other
    /// import's cleanup can take it. When `create` fails, whatever it made
    /// is removed.
    private static func reserve(
        publishingTo destination: URL,
        create: (URL) throws -> Void
    ) throws -> ImportStaging {
        let destinationFolder = destination.deletingLastPathComponent()
        let folder = ImportScratchSpace.stagingFolder(publishingTo: destination)
        if folder.standardizedFileURL.path != destinationFolder.standardizedFileURL.path {
            try ImportScratchSpace.prepareFolder(folder)
            DatalessFiles.withoutDownloading {
                _ = removeAbandoned(in: destinationFolder)
            }
        }
        let staging = ImportStaging(destination: destination, folder: folder)
        removeAbandoned(in: folder)
        inUse.insert(staging.name, at: staging.directory)
        do {
            try create(staging.directory)
        } catch {
            staging.discard()
            throw error
        }
        return staging
    }

    /// The package an import in this process is staging under the name
    /// `name`, wherever it is building it; nil for any other name. A staged
    /// book's `tmbDirectory` is found this way.
    static func directory(ofStagedPackage name: String) -> URL? {
        guard name.hasPrefix(namePrefix) else { return nil }
        return inUse.directory(named: name)
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
    /// with everything inside it and the removal is logged, naming it by its
    /// path inside this Mac's TextMouth folder or the data directory
    /// (`ImportScratchSpace.loggablePath`). Returns how many were removed.
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
                DiagnosticLog.event(
                    .import,
                    "IMPORT_STAGING_REMOVED: \(ImportScratchSpace.loggablePath(leftover)): left by an interrupted import"
                )
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
            DiagnosticLog.event(
                .import,
                "IMPORT_STAGING_LEFT: \(ImportScratchSpace.loggablePath(directory)): could not be removed: "
                    + error.localizedDescription
            )
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

/// The names, with their directories, shared by every thread that imports:
/// the staged packages (`ImportStaging`) or the extraction directories
/// (`ArchiveExtractionDirectory`) this process's imports are using, which
/// the cleanup of abandoned ones leaves alone.
///
/// `@unchecked Sendable`: `directories` is read and changed only under
/// `lock`.
final class NamesInUse: @unchecked Sendable {
    private let lock = NSLock()
    /// Each name in use, with the directory it names.
    private var directories: [String: URL] = [:]

    /// Marks `name`, the name of `directory`, in use.
    func insert(_ name: String, at directory: URL) {
        lock.lock()
        directories[name] = directory
        lock.unlock()
    }

    /// Marks `name` no longer in use.
    func remove(_ name: String) {
        lock.lock()
        directories[name] = nil
        lock.unlock()
    }

    /// Whether `name` is in use.
    func contains(_ name: String) -> Bool {
        directory(named: name) != nil
    }

    /// The directory `name` names while it is in use; nil otherwise.
    func directory(named name: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return directories[name]
    }
}
