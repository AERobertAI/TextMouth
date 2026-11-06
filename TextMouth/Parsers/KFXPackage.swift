import Foundation
import ZIPFoundation

/// A ZIP archive that may hold a Kindle book: a `.kfx-zip` (calibre's bundle
/// of a book's containers) or a Kindle Create package (`.kpf`). This looks
/// at the archive's member names and their first bytes only, to say which it
/// is and whether it is copy-protected; it never extracts a member whole.
enum KFXPackage {

    /// The most members looked at: a book's set holds a handful of files, so
    /// an archive with more is no Kindle book's, and walking its central
    /// directory further is the work a hostile file would ask for.
    static let maximumMembers = 4_096

    /// What an archive's members show.
    enum Kind: Equatable {
        /// A member starts with the protected mark, or is a voucher.
        case protected
        /// A member is a `.kdf` database: a Kindle Create package.
        case kindleCreate
        /// At least one member is a KFX container: a set of containers.
        case containers
        /// None of the above.
        case other
    }

    /// Stops an extraction once the first bytes of a member are in hand.
    private struct EnoughBytes: Error {}

    /// The kind of the archive at `url`, from its members' names and the
    /// first bytes of each.
    /// - Throws: `MOBIError.damaged` for an archive that cannot be opened
    ///   or that lists more than `maximumMembers`.
    static func kind(ofArchiveAt url: URL) throws -> Kind {
        guard let archive = Archive.openedForReading(at: url) else {
            throw MOBIError.damaged("the set's archive does not open")
        }
        var holdsContainer = false
        var members = 0
        var isKindleCreate = false
        for entry in archive where entry.type == .file {
            members += 1
            guard members <= maximumMembers else {
                throw MOBIError.damaged("the set's archive lists more than \(maximumMembers) files")
            }
            let name = (entry.path as NSString).lastPathComponent.lowercased()
            // A voucher is the key envelope of a protected book.
            if name == "voucher" || name.hasSuffix(".voucher") { return .protected }
            if name.hasSuffix(".kdf") { isKindleCreate = true }
            // Every member is checked for the protected mark, not only the
            // main file: a set holds several containers.
            switch KFXSignature.kind(ofPrefix: firstBytes(of: entry, in: archive)) {
            case .protected: return .protected
            case .container: holdsContainer = true
            case .zip, .other: break
            }
        }
        if isKindleCreate { return .kindleCreate }
        return holdsContainer ? .containers : .other
    }

    /// Up to `KFXSignature.prefixLength` bytes from the start of `entry`.
    /// ZIPFoundation hands the data over in chunks; the first one is enough,
    /// so the extraction is stopped there and nothing more is inflated.
    private static func firstBytes(of entry: Entry, in archive: Archive) -> [UInt8] {
        var head: [UInt8] = []
        _ = try? archive.extract(entry, bufferSize: 1_024, skipCRC32: true) { chunk in
            head.append(contentsOf: chunk.prefix(KFXSignature.prefixLength - head.count))
            if head.count >= KFXSignature.prefixLength { throw EnoughBytes() }
        }
        return head
    }
}
