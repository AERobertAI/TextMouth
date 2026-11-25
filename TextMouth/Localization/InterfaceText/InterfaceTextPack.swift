import Foundation

/// The reader of `Strings.pack`, format version 2 (FR39): the IDs, the English, the translators' notes, and one
/// compressed blob of entries for each language, in one file.
///
/// The container (the header, the directory, the two compression methods, and every bound) is `PackContainer`, which
/// `BrailleTables.pack` is written in too. For this pack the magic is `TMSP`, the version 2, and the header's count the
/// number of IDs. The blobs are named `ids`, `notes`, `en`, `es`, ...; the builder keeps the smaller compression of each.
///
/// The pack is untrusted bytes: a damaged or hostile file must give English, never a trap. The container checks the file
/// before a byte of it is used; this reader adds each blob's entry count, and a decoded blob is checked again for its
/// size, its entry count, and UTF-8 before a byte of it is used.
///
/// Foundation and the container only; no stored state beyond the container.
struct InterfaceTextPack: InterfaceTextTables {
    /// The container: the mapped bytes and the directory.
    private let container: PackContainer
    /// How many IDs the header says there are; every blob holds that many entries.
    let idCount: Int

    // MARK: - Limits

    /// The file's name inside an app's resources.
    static let resourceName = "Strings"  // l10n: no (English text for the debug log, never shown)
    static let resourceExtension = "pack"

    /// What a `Strings.pack` is, for the container: the magic and the version, and the limits that stop a header that
    /// claims millions of records. The 25 languages, English, the IDs, and the notes come to 28 blobs, so 256 leaves room;
    /// the IDs number thousands, so a million is far above them; the biggest real blob is under 300 KB, so 16 MB keeps a
    /// hostile size from asking for gigabytes.
    private static let format = PackContainer.Format(
        magic: Array("TMSP".utf8), version: 2, largestCount: 1_000_000, largestBlobCount: 256, largestRawSize: 16 * 1024 * 1024,
        // Every blob holds one entry for each ID, checked as its record is read, in the order of the file.
        recordCheck: { name, blob, count in
            blob.count == count ? nil : "the blob \(name) has \(blob.count) entries, not \(count)"  // l10n: no (English text for the debug log, never shown)
        }
    )

    // MARK: - Opening

    /// The pack in the main bundle, or nil when the bundle has none (`Strings.pack` is added to the apps by a later
    /// phase). Throws when it is there and cannot be read.
    static func inMainBundle() throws -> InterfaceTextPack? {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: resourceExtension) else { return nil }
        return try InterfaceTextPack(contentsOf: url)
    }

    /// The pack in the file at `url`, mapped rather than read, so the 1.3 MB costs address space, not memory, until a
    /// blob is decoded.
    init(contentsOf url: URL) throws {
        try self.init(opening: { try PackContainer(contentsOf: url, format: Self.format) })
    }

    /// The pack in `data`, whose header and directory are checked here; a blob is checked when it is decoded.
    init(data: Data) throws {
        try self.init(opening: { try PackContainer(data: data, format: Self.format) })
    }

    /// The pack that `open` makes a container of, checked as a `Strings.pack`: there is an `ids` blob (every blob's entry count
    /// is checked as the container reads its record, `format`). The container's failures are given the engine's own failure type.
    private init(opening open: () throws -> PackContainer) throws {
        let opened: PackContainer
        do {
            opened = try open()
            guard opened.blobs["ids"] != nil else { throw PackContainerFailure("the pack has no ids blob") }  // l10n: no (English text for the debug log, never shown)
        } catch let failure as PackContainerFailure {
            throw InterfaceTextFailure(failure.description)
        }
        self.container = opened
        self.idCount = opened.count
    }

    // MARK: - Reading

    /// Whether the pack has a blob for `language`.
    func hasLanguage(_ language: String) -> Bool {
        language != "ids" && language != "notes" && container.blobs[language] != nil
    }

    func idList() throws -> InterfaceTextIDList {
        let bytes = try decodedBlob(named: "ids")
        guard let list = InterfaceTextIDList(blob: bytes, count: idCount) else {
            throw InterfaceTextFailure("the ids blob is not \(idCount) valid IDs in order")  // l10n: no (English text for the debug log, never shown)
        }
        return list
    }

    func entries(language: String) throws -> [InterfaceTextEntry] {
        guard hasLanguage(language) else { throw InterfaceTextFailure("the pack has no \(language) blob") }  // l10n: no (English text for the debug log, never shown)
        let bytes = try decodedBlob(named: language)
        do {
            return try InterfaceTextEntry.decodeAll(bytes, count: idCount, formCount: PluralRules.categories[language]?.count)
        } catch let failure as InterfaceTextFailure {
            throw InterfaceTextFailure("the \(language) blob: \(failure.description)")  // l10n: no (English text for the debug log, never shown)
        }
    }

    /// The translators' note of each ID, in the order of the IDs ("" for none); empty when the pack has no notes blob.
    /// A note is plain text, so each entry is read as one (a note never starts a plural).
    func notes() throws -> [String] {
        guard container.blobs["notes"] != nil else { return [] }
        let entries = try InterfaceTextEntry.decodeAll(try decodedBlob(named: "notes"), count: idCount, formCount: nil)
        return entries.map { entry in
            if case .plain(let text) = entry { return text }
            return ""
        }
    }

    /// The decoded bytes of the blob `name`, with the container's failure given the engine's own type.
    private func decodedBlob(named name: String) throws -> [UInt8] {
        do {
            return try container.decodedBlob(named: name)
        } catch let failure as PackContainerFailure {
            throw InterfaceTextFailure(failure.description)
        }
    }
}
