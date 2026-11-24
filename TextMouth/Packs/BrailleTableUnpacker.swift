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
/// - **Whole files only.** Each file is written under a temporary name in `folder` and renamed into place, so a reader (the
///   helper, or liblouis in this process) never sees half a file, and a rename replaces a file a damaged earlier run left.
/// - **One unpacking at a time.** A lock holds a second caller until the first has finished, so two unpackings of the same
///   table never write the same file at once; the second finds the files there and writes nothing.
/// - **Kept files.** A file already in `folder` with the length the index gives is kept, as it is. A missing one, or one of
///   another length, is unpacked again, since iOS may clear Caches and a run may end half way.
/// - **Damage.** A damaged blob or index makes the table unavailable: `unpackedFolder(for:)` throws and the translation fails
///   as it does for a table the app does not have. The reason is logged once for each file (`BRAILLE_TABLES_UNAVAILABLE`),
///   never again however often the table is asked for, and nothing traps.
///
/// The app's own unpacker, `BrailleTableUnpacker.app`, reads the pack in the app and writes into the Caches folder of
/// `MachineLocalPaths` (under the liblouis version, so a newer release unpacks beside the older). A test makes an unpacker
/// of its own, over a pack of its own and a folder it makes, and never writes into the app's Caches.
final class BrailleTableUnpacker: Sendable {
    /// The pack the tables come from.
    let pack: BrailleTablePack
    /// The folder the files are unpacked into: every table and include in one folder, as liblouis reads them.
    let folder: URL
    /// One unpacking at a time.
    private let unpacking = OSAllocatedUnfairLock()
    /// The reasons already logged, so that a table asked for again and again is logged once.
    private let logged = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    /// An unpacker of `pack` into `folder`.
    init(pack: BrailleTablePack, folder: URL) {
        self.pack = pack
        self.folder = folder
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
            return BrailleTableUnpacker(pack: pack, folder: appFolder(for: pack))
        } catch {
            DiagnosticLog.event(.import, "BRAILLE_TABLES_UNAVAILABLE: the pack cannot be used: \(error)")  // l10n: no (a debug log reason, which stays English)
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

    /// Unpacks `file` and every file its includes reach into `folder` (the files already there with the right length are
    /// kept), and returns `folder`.
    /// - Throws: `Failure.unknownFile` for a name the pack lacks, and `Failure.unavailable` for a damaged blob or a folder that
    ///   cannot be written, after logging why, once.
    @discardableResult
    func unpackedFolder(for file: String) throws -> URL {
        guard let names = pack.closure(of: file) else { throw Failure.unknownFile(file) }
        return try unpacking.withLock { () throws -> URL in
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                // A group is decoded once for the files of this unpacking that need it.
                var groups: [Int: [UInt8]] = [:]
                for name in names {
                    guard let entry = pack.files[name] else { throw Failure.unknownFile(name) }
                    let destination = folder.appendingPathComponent(name, isDirectory: false)
                    if Self.length(of: destination) == entry.length { continue }
                    if groups[entry.group] == nil { groups[entry.group] = try pack.decodedGroup(entry.group) }
                    guard let group = groups[entry.group], let bytes = BrailleTablePack.bytes(of: entry, in: group) else {
                        throw BrailleTablePackFailure("\(name) lies outside its group")  // l10n: no (English text for the debug log, never shown)
                    }
                    try Self.write(bytes, to: destination)
                }
                return folder
            } catch let failure as Failure {
                throw failure
            } catch {
                let reason = "\(error)"
                logOnce(file: file, reason: reason)
                throw Failure.unavailable(reason)
            }
        }
    }

    /// Logs `reason` for `file` unless it has been logged before.
    private func logOnce(file: String, reason: String) {
        let key = "\(file): \(reason)"
        let first = logged.withLock { $0.insert(key).inserted }
        if first { DiagnosticLog.event(.import, "BRAILLE_TABLES_UNAVAILABLE: \(file): \(reason)") }  // l10n: no (a debug log reason, which stays English)
    }

    /// The length of the regular file at `url`, or nil when there is none (or it is not a regular file).
    private static func length(of url: URL) -> Int? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { return nil }
        return values.fileSize
    }

    /// Writes `bytes` to `destination` whole: into a hidden file of its own beside it, then renamed over it, which replaces a
    /// file already there in one step. A write that fails leaves the temporary file, which no reader opens, and throws.
    private static func write(_ bytes: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp", isDirectory: false)
        try bytes.write(to: temporary, options: [])
        guard rename(temporary.path, destination.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))])
        }
    }
}
