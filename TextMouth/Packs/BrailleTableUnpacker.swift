import CryptoKit
import Darwin
import Foundation
import os

/// The unpacking of liblouis's tables from `BrailleTables.pack` into a folder at first use (FR40).
///
/// liblouis, and the Mac's braille helper, read tables as files of one folder, each table beside the files it includes. The
/// pack holds no such folder, so when a translation, a check, or a reading needs a table, `unpackedFolder(for:)` writes that
/// table and every file its includes reach (the index's closure) into `folder`, and hands that folder back, as the app used
/// to hand the bundle's.
///
/// - **Whole files only.** Each file is written under a temporary name in `folder`, synced to disk, and renamed into place, so
///   a reader (the helper, or liblouis in this process) never sees half a file, a crash cannot leave a renamed file whose
///   bytes never reached the disk, and a rename replaces a file a damaged earlier run left.
/// - **One unpacking at a time.** A lock holds a second caller until the first has finished, so two unpackings of the same
///   table never write the same file at once; the second finds the files there and writes nothing.
/// - **Kept files are checked, not trusted.** A file already in `folder` with the length the index gives is kept only when its
///   SHA-256 is the one the index records. The hash is checked the first time in a launch that a table needs the file (the
///   unpacker's life is a launch); later the length alone is looked at. A missing file, one of another length, and one
///   whose hash differs is unpacked again, since iOS may clear Caches and a run may end half way.
/// - **Damage.** A damaged blob or index makes the table unavailable: `unpackedFolder(for:)` throws and the translation fails
///   as it does for a table the app does not have. The first file to fail and the error's domain and code are logged
///   (`BRAILLE_TABLES_UNAVAILABLE`), never a path, and the same error is not logged again however many tables it fails.
///   Nothing traps.
/// - **Tidiness.** The first unpacking of a launch, under the lock, removes the temporary files an earlier run left (those
///   more than ten minutes old, which no unpacking is still writing) and, for the app's own unpacker, the folders of other
///   liblouis versions beside `folder`.
///
/// The app's own unpacker, `BrailleTableUnpacker.app`, reads the pack in the app and writes into the Caches folder of
/// `MachineLocalPaths` (under the liblouis version, so a newer release unpacks beside the older, which is then removed). A
/// test makes an unpacker of its own, over a pack of its own and a folder it makes, and never writes into the app's Caches.
final class BrailleTableUnpacker: Sendable {
    /// The pack the tables come from.
    let pack: BrailleTablePack
    /// The folder the files are unpacked into: every table and include in one folder, as liblouis reads them.
    let folder: URL
    /// What the unpacker remembers of this launch, behind the lock that also makes one unpacking run at a time.
    private struct State: Sendable {
        /// The files whose bytes have been checked, or written, in this launch.
        var verified: Set<String> = []
        /// Whether the first unpacking's tidying has been done.
        var tidied = false
    }
    private let unpacking = OSAllocatedUnfairLock<State>(initialState: State())
    /// The reasons already logged, so that a table asked for again and again is logged once.
    private let logged = OSAllocatedUnfairLock<Set<String>>(initialState: [])
    /// Whether the first unpacking removes the folders of other liblouis versions beside `folder`.
    private let sweepsOtherVersions: Bool
    /// What a test watches: each group decoded (its number), and each kept file hashed (its name).
    private let groupDecoded: @Sendable (Int) -> Void
    private let fileHashed: @Sendable (String) -> Void

    /// An unpacker of `pack` into `folder`. `sweepsOtherVersions` is for the app's own, whose folder is one of the versions in a
    /// folder of its own; `groupDecoded` and `fileHashed` are for tests, which count the work.
    init(
        pack: BrailleTablePack, folder: URL, sweepsOtherVersions: Bool = false,
        groupDecoded: @escaping @Sendable (Int) -> Void = { _ in },
        fileHashed: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.pack = pack
        self.folder = folder
        self.sweepsOtherVersions = sweepsOtherVersions
        self.groupDecoded = groupDecoded
        self.fileHashed = fileHashed
    }

    // MARK: - The app's unpacker

    /// The folder the app unpacks into: `MachineLocalPaths.brailleTables` under the liblouis version of `pack`.
    static func appFolder(for pack: BrailleTablePack) -> URL {
        MachineLocalPaths.brailleTables.appendingPathComponent(pack.liblouisVersion, isDirectory: true)
    }

    /// The app's unpacker, made once: the pack in the app (nil when the app has none, or its pack is damaged, which is
    /// logged once) and its folder in the Caches.
    static let app: BrailleTableUnpacker? = {
        do {
            guard let pack = try BrailleTablePack.inMainBundle() else {
                DiagnosticLog.event(.import, "BRAILLE_TABLES_UNAVAILABLE: the app has no BrailleTables.pack")  // l10n: no (a debug log reason, which stays English)
                return nil
            }
            return BrailleTableUnpacker(pack: pack, folder: appFolder(for: pack), sweepsOtherVersions: true)
        } catch let failure as BrailleTablePackFailure {
            DiagnosticLog.event(.import, "BRAILLE_TABLES_UNAVAILABLE: the pack cannot be used: \(failure.description)")  // l10n: no (a debug log reason, which stays English)
            return nil
        } catch {
            DiagnosticLog.event(.import, "BRAILLE_TABLES_UNAVAILABLE: the pack cannot be used: \(BrailleTableUnpacker.describe(error))")  // l10n: no (a debug log reason, which stays English)
            return nil
        }
    }()

    // MARK: - Unpacking

    /// Why a table cannot be unpacked.
    enum Failure: Error, Equatable {
        /// The pack has no such file.
        case unknownFile(String)
        /// The pack, or a file's blob, is damaged, or the folder cannot be written: the sentence says what.
        case unavailable(String)
    }

    /// Unpacks `file` and every file its includes reach into `folder` (the files already there are kept when their bytes are
    /// the ones the index records), and returns `folder`.
    /// - Throws: `Failure.unknownFile` for a name the pack lacks, and `Failure.unavailable` for a damaged blob or a folder that
    ///   cannot be written, after logging why, once.
    @discardableResult
    func unpackedFolder(for file: String) throws -> URL {
        guard let names = pack.closure(of: file) else { throw Failure.unknownFile(file) }
        return try unpacking.withLock { state -> URL in
            // The file being worked on, which a failure names.
            var current = file
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                if !state.tidied {
                    state.tidied = true
                    tidy()
                }
                // A group is decoded once for the files of this unpacking that need it.
                var groups: [Int: [UInt8]] = [:]
                for name in names {
                    current = name
                    guard let entry = pack.files[name] else { throw Failure.unknownFile(name) }
                    let destination = folder.appendingPathComponent(name, isDirectory: false)
                    if try keeps(destination, of: entry, verified: &state.verified) { continue }
                    if groups[entry.group] == nil {
                        groups[entry.group] = try pack.decodedGroup(entry.group)
                        groupDecoded(entry.group)
                    }
                    guard let group = groups[entry.group], let bytes = BrailleTablePack.bytes(of: entry, in: group) else {
                        throw BrailleTablePackFailure("\(name) lies outside its group")  // l10n: no (English text for the debug log, never shown)
                    }
                    try Self.write(bytes, to: destination)
                    state.verified.insert(name)
                }
                return folder
            } catch let failure as Failure {
                throw failure
            } catch {
                let reason = Self.describe(error)
                logOnce(file: current, reason: reason)
                throw Failure.unavailable(reason)
            }
        }
    }

    /// Whether the file at `destination` stays as it is: it has the length `entry` gives and, unless this launch has checked
    /// it already, the SHA-256 `entry` records. A file that passes is noted in `verified`.
    private func keeps(_ destination: URL, of entry: BrailleTablePack.File, verified: inout Set<String>) throws -> Bool {
        guard Self.length(of: destination) == entry.length else { return false }
        if verified.contains(entry.name) { return true }
        fileHashed(entry.name)
        guard let data = try? Data(contentsOf: destination, options: .alwaysMapped),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == entry.sha256
        else { return false }
        verified.insert(entry.name)
        return true
    }

    /// How a failure is told in the log: a pack's own sentence (it names only blobs and files), and for anything else the
    /// error's domain and code, never its description, which may hold a path.
    private static func describe(_ error: Error) -> String {
        if let failure = error as? BrailleTablePackFailure { return failure.description }
        let underlying = error as NSError
        return "\(underlying.domain) \(underlying.code)"
    }

    /// Logs `reason` for `file` unless the same reason has been logged before: the set is keyed by the error's domain and code
    /// alone, so a full disk, which fails every table the same way, logs one line, not one for each table asked for.
    private func logOnce(file: String, reason: String) {
        let first = logged.withLock { $0.insert(reason).inserted }
        if first { DiagnosticLog.event(.import, "BRAILLE_TABLES_UNAVAILABLE: \(file): \(reason)") }  // l10n: no (a debug log reason, which stays English)
    }

    // MARK: - Tidying

    /// The age past which a temporary file is a stray: no unpacking is still writing a file that old.
    private static let strayAge: TimeInterval = 600

    /// Removes the temporary files a run that ended half way left in `folder`, and, for the app's own unpacker, the folders of
    /// other liblouis versions beside it. Called under the lock, the first time in a launch; a failure to remove is not one
    /// to report, since the next launch tries again.
    private func tidy() {
        let manager = FileManager.default
        let now = Date()
        for url in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let name = url.lastPathComponent
            guard name.hasPrefix("."), name.hasSuffix(".tmp") else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if now.timeIntervalSince(modified) > Self.strayAge { try? manager.removeItem(at: url) }
        }
        guard sweepsOtherVersions else { return }
        let parent = folder.deletingLastPathComponent()
        for url in (try? manager.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
            guard url.lastPathComponent != folder.lastPathComponent, BrailleTablePack.isPlainName(url.lastPathComponent),
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            try? manager.removeItem(at: url)
        }
    }

    // MARK: - Files

    /// The length of the regular file at `url`, or nil when there is none (or it is not a regular file).
    private static func length(of url: URL) -> Int? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { return nil }
        return values.fileSize
    }

    /// Writes `bytes` to `destination` whole: into a hidden file of its own beside it, synced to disk, then renamed over it,
    /// which replaces a file already there in one step. A write, sync, or rename that fails removes the temporary file and
    /// throws.
    private static func write(_ bytes: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp", isDirectory: false)
        do {
            try bytes.write(to: temporary, options: [])
            // The bytes are on the disk before the name is: a crash after the rename cannot leave a table that is empty.
            let handle = try FileHandle(forWritingTo: temporary)
            do {
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            guard rename(temporary.path, destination.path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
