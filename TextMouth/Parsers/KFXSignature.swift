import Foundation

/// What the first bytes of a Kindle KFX file say it is. The bytes decide,
/// never the file's name (KFX-FORMAT-NOTES-2026-11-05.md, part 3): Kindle's
/// apps name KFX books `.azw`, and a protected book looks like any other
/// until its first eight bytes are read. Nothing here, or anywhere in the
/// reader, tries to decrypt: a protected container is refused.
enum KFXSignature {

    /// What a file's first bytes show.
    enum Kind: Equatable {
        /// `CONT`: a KFX container, which may be read.
        case container
        /// The eight bytes of an encrypted Ion envelope, the mark of a
        /// copy-protected container (Amazon's own books).
        case protected
        /// `PK\3\4`: a ZIP archive, which may be a `.kfx-zip` set or a
        /// Kindle Create package (`.kpf`); its members decide
        /// (`KFXPackage`).
        case zip
        /// Anything else.
        case other
    }

    /// The first four bytes of a container: "CONT".
    static let containerMagic: [UInt8] = Array("CONT".utf8)

    /// The first eight bytes of a copy-protected container: "DRMION" with a
    /// 0xEA byte before it and a 0xEE byte after.
    static let protectedMagic: [UInt8] = [0xEA, 0x44, 0x52, 0x4D, 0x49, 0x4F, 0x4E, 0xEE]

    /// The container versions there are.
    static let supportedVersions = 1...2

    /// Where a Palm database (MOBI) names its type and creator, and the two
    /// pairs that mean a MOBI or PalmDOC book, not a KFX one.
    private static let palmTypeOffset = 0x3C
    private static let palmTypes: [[UInt8]] = [Array("BOOKMOBI".utf8), Array("TEXtREAd".utf8)]

    /// Whether a file named `name` is a voucher, the key envelope of a
    /// protected book: `voucher`, or a name that ends `.voucher`.
    static func isVoucherName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered == "voucher" || lowered.hasSuffix(".voucher")
    }

    /// The first four bytes of a ZIP archive's first entry.
    static let zipMagic: [UInt8] = [0x50, 0x4B, 0x03, 0x04]

    /// How many bytes decide the kind: the longest signature.
    static let prefixLength = 8

    /// The kind of the data that begins with `prefix` (any length: a short
    /// prefix is `other`).
    static func kind(ofPrefix prefix: [UInt8]) -> Kind {
        if prefix.starts(with: protectedMagic) { return .protected }
        // A container says its version, 1 or 2, in the two bytes after the
        // signature: a Palm database named "CONTACT..." is not one.
        if prefix.starts(with: containerMagic), prefix.count > containerMagic.count + 1,
           supportedVersions.contains(Int(prefix[4])), prefix[5] == 0 { return .container }
        if prefix.starts(with: zipMagic) { return .zip }
        return .other
    }

    /// Whether `bytes` is a KFX container or a protected one: what an
    /// `.azw` file holds when Kindle's apps named a KFX book that way, and so
    /// what the MOBI reader hands on to this one.
    static func isKFXOrProtected(_ bytes: [UInt8]) -> Bool {
        let kind = kind(ofPrefix: Array(bytes.prefix(prefixLength)))
        guard kind == .container || kind == .protected else { return false }
        // A Palm database that names itself a MOBI book is one, whatever its name begins.
        let typeEnd = palmTypeOffset + 8
        if bytes.count >= typeEnd, palmTypes.contains(where: { Array(bytes[palmTypeOffset..<typeEnd]) == $0 }) { return false }
        return true
    }

    /// The kind of the file at `url`, from its first bytes alone, so a large
    /// file is not read to be told apart.
    /// - Throws: The file system's error for a file that cannot be read.
    static func kind(ofFileAt url: URL) throws -> Kind {
        // Only a regular file is opened: reading a named pipe would wait for
        // a writer that never comes. A link is followed to what it names.
        let isRegular = try url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile
        guard isRegular == true else { return .other }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: prefixLength) ?? Data()
        return kind(ofPrefix: [UInt8](prefix))
    }
}
