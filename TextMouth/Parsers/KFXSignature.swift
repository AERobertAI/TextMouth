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

    /// The first four bytes of a ZIP archive's first entry.
    static let zipMagic: [UInt8] = [0x50, 0x4B, 0x03, 0x04]

    /// How many bytes decide the kind: the longest signature.
    static let prefixLength = 8

    /// The kind of the data that begins with `prefix` (any length: a short
    /// prefix is `other`).
    static func kind(ofPrefix prefix: [UInt8]) -> Kind {
        if prefix.starts(with: protectedMagic) { return .protected }
        if prefix.starts(with: containerMagic) { return .container }
        if prefix.starts(with: zipMagic) { return .zip }
        return .other
    }

    /// Whether `bytes` is a KFX container or a protected one: what an
    /// `.azw` file holds when Kindle's apps named a KFX book that way, and so
    /// what the MOBI reader hands on to this one.
    static func isKFXOrProtected(_ bytes: [UInt8]) -> Bool {
        let kind = kind(ofPrefix: Array(bytes.prefix(prefixLength)))
        return kind == .container || kind == .protected
    }

    /// The kind of the file at `url`, from its first bytes alone, so a large
    /// file is not read to be told apart.
    /// - Throws: The file system's error for a file that cannot be read.
    static func kind(ofFileAt url: URL) throws -> Kind {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: prefixLength) ?? Data()
        return kind(ofPrefix: [UInt8](prefix))
    }
}
