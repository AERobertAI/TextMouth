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

    /// The most containers a set may hold.
    static let maximumContainers = 64
    /// The most bytes a set's containers may hold, all together.
    static let maximumTotalBytes: Int64 = 4 * DocumentByteLimit.standard

    /// The containers of the set in the archive at `url`: every member that
    /// begins with the container's signature, in the archive's order. A member
    /// is read within the limit for one document and the containers together
    /// within `maximumTotalBytes`, by the sizes read, not the sizes declared,
    /// so an archive that lies about them is stopped at the first byte past.
    /// Members that are not containers (a voucher is checked first, in
    /// `kind(ofArchiveAt:)`) are not opened.
    /// - Throws: `MOBIError.damaged` for an archive that does not open, holds
    ///   too many containers, or holds a member larger than it records;
    ///   `DocumentTooLargeError` for a member or a set past the limits; what
    ///   `KFXContainer.init(bytes:)` throws for a member that is not a sound container.
    static func containers(inArchiveAt url: URL) throws -> [KFXContainer] {
        guard let archive = Archive.openedForReading(at: url) else {
            throw MOBIError.damaged("the set's archive does not open")
        }
        var containers: [KFXContainer] = []
        var total: Int64 = 0
        for entry in archive where entry.type == .file {
            guard KFXSignature.kind(ofPrefix: firstBytes(of: entry, in: archive)) == .container else { continue }
            guard containers.count < maximumContainers else {
                throw MOBIError.damaged("the set holds more than \(maximumContainers) containers")
            }
            let bytes: Data
            do {
                bytes = try ArchiveEntryReader.read(entry, in: archive, holdingToDeclaredSize: true).data
            } catch let overflow as ArchiveEntryOverflow {
                switch overflow {
                case .pastLimit(_, let limit): throw DocumentTooLargeError(limit: limit)
                case .pastDeclaredSize: throw MOBIError.damaged("a file in the set holds more than its archive records")
                }
            }
            total += Int64(bytes.count)
            guard total <= maximumTotalBytes else { throw DocumentTooLargeError(limit: maximumTotalBytes) }
            containers.append(try KFXContainer(bytes: [UInt8](bytes)))
        }
        return containers
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
