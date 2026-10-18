import Foundation
import ZIPFoundation

/// What a document's own first bytes say, checked before `textutil` reads
/// it (FMT13). `textutil` is always told the format by name, so it never
/// guesses, and it cannot tell a listener two things that a few bytes of the
/// file can: that a file named .doc is really RTF, and that a document is
/// protected by a password rather than damaged.
///
/// Every check is a pure function of one file. None of them reads a whole
/// file at once, so a large or hostile document costs a few kilobytes at
/// most (a Word file's scan stops at 8 MB). Each answers false for anything
/// it cannot make sense of: a missing file, a folder, a damaged file. The
/// reader that follows then fails with its own sentence.
enum TextutilSourceCheck {

    // MARK: - RTF under another name

    /// Whether the file at `url` begins as RTF: after an optional UTF-8
    /// byte-order mark and any ASCII white space, its next bytes are
    /// `{\rtf`. Many files named .doc are RTF (Word's "Save as RTF" keeps
    /// the name), and `textutil` told `-format doc` refuses them while
    /// `-format rtf` reads them well, so such a file is read as RTF
    /// whatever its extension. Reads at most the first 64 bytes.
    static func beginsAsRTF(_ url: URL) -> Bool {
        guard let head = leadingBytes(of: url, count: 64) else { return false }
        var index = 0
        // A UTF-8 byte-order mark some editors write before the text.
        if head.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3 }
        // ASCII white space: tab, line feed, vertical tab, form feed,
        // carriage return, and space.
        while index < head.count, head[index] == 0x20 || (0x09...0x0D).contains(head[index]) {
            index += 1
        }
        return head.dropFirst(index).starts(with: Array(#"{\rtf"#.utf8))
    }

    // MARK: - A Word 97-2003 document with a password

    /// The signature every compound file (the container of Word 97-2003
    /// files) begins with.
    private static let compoundFileSignature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
    /// The size of a compound file's sectors. The first one is its header.
    private static let sectorSize = 512
    /// The alignment a stream starts on in the file. A large stream starts
    /// on a sector boundary (512 bytes), but a stream under 4096 bytes, as
    /// the `WordDocument` stream of a very short document is, lives in the
    /// file's mini stream, whose 64-byte mini sectors lie inside sectors:
    /// the sample `libreoffice-tdf104239_chapterNumbering.doc` has its block
    /// at offset 5312, which is 64-aligned but not 512-aligned.
    private static let streamAlignment = 64
    /// How far into a file the File Information Block is looked for.
    private static let fibSearchLimit = 8 * 1024 * 1024
    /// The `nFib` values Word 6 to Word 2007 and later write (Word 97 and
    /// after write 0x00C1).
    private static let knownFibVersions: ClosedRange<UInt16> = 0x0065...0x0200
    /// Where the 16-bit flags word lies in a File Information Block, and
    /// the bit of it that says the document is encrypted (`fEncrypted`;
    /// bit 0x0001 is `fDot`, a template).
    private static let fibFlagsOffset = 0x0A
    private static let fibEncryptedBit: UInt16 = 0x0100

    /// Whether the file at `url` is a Word 97-2003 document ([MS-DOC]) whose
    /// File Information Block says it is encrypted. False when the file is
    /// no compound file or holds no such block: `textutil` then tries, and
    /// fails with its own sentence if it must.
    ///
    /// The `WordDocument` stream starts on a 64-byte boundary at least, so
    /// the block is found without parsing the compound file, by
    /// `fibOffset(in:from:)` over the file read in chunks.
    static func isEncryptedWordDocument(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        // A multiple of the stream alignment, so a block never straddles
        // two chunks.
        let chunkSize = 64 * 1024
        var chunkStart = 0
        while chunkStart < fibSearchLimit {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { return false }
            if chunkStart == 0, !chunk.starts(with: compoundFileSignature) { return false }
            // The first sector is the compound file's header, never a stream.
            if let offset = fibOffset(in: chunk, from: chunkStart == 0 ? sectorSize : 0) {
                return fibFlags(in: chunk, at: offset) & fibEncryptedBit != 0
            }
            chunkStart += chunk.count
        }
        return false
    }

    /// The offset in `data` of the first File Information Block, or nil. A
    /// block starts on a 64-byte boundary (`streamAlignment`) with `wIdent`
    /// 0xA5EC (the bytes EC A5), then an `nFib` from 0x0065 to 0x0200, and
    /// has room for its flags word. `data` is taken to start on such a
    /// boundary, and `start` is the first offset looked at (512 by default,
    /// to pass over the compound file's header sector).
    static func fibOffset(in data: Data, from start: Int = 512) -> Int? {
        let blockEnd = fibFlagsOffset + 2
        for offset in stride(from: start, to: data.count, by: streamAlignment) {
            guard offset + blockEnd <= data.count else { return nil }
            let base = data.startIndex + offset
            guard data[base] == 0xEC, data[base + 1] == 0xA5 else { continue }
            let version = UInt16(data[base + 2]) | UInt16(data[base + 3]) << 8
            if knownFibVersions.contains(version) { return offset }
        }
        return nil
    }

    /// The flags word (little-endian) of the block at `offset` in `data`.
    private static func fibFlags(in data: Data, at offset: Int) -> UInt16 {
        let base = data.startIndex + offset + fibFlagsOffset
        return UInt16(data[base]) | UInt16(data[base + 1]) << 8
    }

    // MARK: - An OpenDocument package with a password

    /// The package's manifest, and the most bytes of it that are read.
    private static let manifestPath = "META-INF/manifest.xml"
    private static let manifestByteLimit: Int64 = 1_000_000

    /// Whether the OpenDocument package at `url` (.odt or .ott) has an
    /// encrypted part: its `META-INF/manifest.xml` holds a
    /// `manifest:encryption-data` element for each one. False when the file
    /// is no ZIP, the manifest is missing, too large, or unreadable.
    static func isEncryptedOpenDocument(_ url: URL) -> Bool {
        guard let archive = Archive.openedForReading(at: url),
              let entry = archive[manifestPath], entry.type == .file,
              let manifest = try? ArchiveEntryReader.read(entry, in: archive, limit: manifestByteLimit).data
        else { return false }

        let finder = EncryptionDataFinder()
        let parser = XMLParser(data: manifest)
        parser.delegate = finder
        parser.shouldProcessNamespaces = true
        // A manifest names no outside entity, and none is ever loaded.
        parser.shouldResolveExternalEntities = false
        parser.parse()
        return finder.found
    }

    // MARK: - Shared

    /// The first `count` bytes of the file at `url` (fewer when it is
    /// shorter), or nil when it cannot be read: missing, a folder, no
    /// permission.
    private static func leadingBytes(of url: URL, count: Int) -> [UInt8]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: count) else { return nil }
        return [UInt8](data)
    }
}

/// Watches a manifest for an element whose local name is `encryption-data`
/// and stops the parse at the first one.
private final class EncryptionDataFinder: NSObject, XMLParserDelegate {
    /// Whether an `encryption-data` element was met.
    private(set) var found = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        // With namespaces processed the name is the local one, but a prefix
        // is dropped here as well in case the parser keeps it.
        if elementName.split(separator: ":").last == "encryption-data" {
            found = true
            parser.abortParsing()
        }
    }
}

// MARK: - The Refusal

/// A document protected by a password, which `textutil` would fail on as on
/// a damaged one. Its sentence tells the listener what to do; it never
/// names the file, which the import's failure does (`ImportFailure`).
struct PasswordProtectedDocument: LocalizedError, Equatable {
    var errorDescription: String? {
        "This document is protected by a password. Save a copy without the password, then import that copy."
    }
}
