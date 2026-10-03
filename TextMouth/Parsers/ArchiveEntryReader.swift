import Foundation
import ZIPFoundation

// MARK: - Limits

/// The most a reader takes into memory from one entry of a book's archive
/// (TODO I05). The EPUB, DOCX, and DAISY readers read every file they need
/// wholly into memory, so without a limit one deliberately huge entry,
/// whether it declares its size honestly or not, would be read in full.
///
/// - `audio`, 256 MB: the DAISY audio converter reads each audio file whole
///   before writing it into the book's package. DAISY audio is usually
///   32–64 kbps MP3 split by section, a few megabytes a file; 256 MB holds
///   about nine hours at 64 kbps in one file, and is still safe to hold in
///   memory on a Mac with 8 GB.
/// - `text`, 64 MB: every other entry (XHTML, XML, SMIL, OPF, NCX). The
///   largest real ones, a whole Bible in one XHTML file (about 5 MB), a long
///   DTBook (about 20 MB), or a 1,000-page Word document's text part (about
///   15 MB), fit three times over.
struct ArchiveEntryLimits: Equatable, Sendable {
    /// The most bytes one audio entry may hold.
    var audio: Int64
    /// The most bytes any other entry may hold.
    var text: Int64

    /// The documented limits every reader uses.
    static let standard = ArchiveEntryLimits(audio: 256_000_000, text: 64_000_000)

    /// The limits readers use: `standard`, unless a test binds smaller ones
    /// with `ArchiveEntryLimits.$current.withValue(_:operation:)`, which
    /// changes only the reading that operation does on its own thread.
    @TaskLocal static var current = ArchiveEntryLimits.standard

    /// The extensions of the audio files a book's archive can hold: those
    /// TextMouth plays as audio books, and Ogg, which DAISY books also use.
    static let audioExtensions: Set<String> = Set(BookFormat.audio.fileExtensions).union(["ogg"])

    /// Whether the entry at `path` inside an archive is an audio file,
    /// judged by its extension, without regard to case.
    static func isAudio(_ path: String) -> Bool {
        audioExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// The limit for the entry at `path`: `audio` for an audio file, and
    /// `text` for anything else.
    func limit(forEntryAt path: String) -> Int64 {
        Self.isAudio(path) ? audio : text
    }
}

// MARK: - Overflow

/// An archive entry that holds more bytes than it may: more than a reader
/// takes from one entry, or more than the archive records for it, which only
/// a damaged or deliberately crafted archive does. Each reader names the
/// entry in its own damage sentence with `reason`; on its own, the error
/// describes the entry as a file in "this archive".
enum ArchiveEntryOverflow: LocalizedError, Equatable {
    /// The entry at `path` holds more than `limit`, the most a reader takes
    /// from one entry.
    case pastLimit(path: String, limit: Int64)
    /// The entry at `path` holds more than `declared`, the size the archive
    /// records for it.
    case pastDeclaredSize(path: String, declared: Int64)

    /// The entry's path inside the archive.
    var path: String {
        switch self {
        case .pastLimit(let path, _), .pastDeclaredSize(let path, _):
            return path
        }
    }

    /// The words that complete "The file “…” in this book is damaged or
    /// incomplete: …", as every format's damage sentence ends.
    var reason: String {
        switch self {
        case .pastLimit(_, let limit):
            return "it holds more than \(ArchiveFigures.size(limit)), the most TextMouth reads from one file"
        case .pastDeclaredSize(_, let declared):
            return "it holds more than the \(ArchiveFigures.size(declared)) the archive records for it"
        }
    }

    var errorDescription: String? {
        PackageDamage.message(file: path, reason: reason, container: "this archive", original: "the archive")
    }
}

// MARK: - Figures

/// How archive messages write their figures: sizes as Finder writes them,
/// in decimal units ("64 MB"), and counts with digit grouping ("12,345").
/// VoiceOver reads both as numbers with their units.
enum ArchiveFigures {
    /// `bytes` as a size, such as "2 GB".
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// `value` as a count, such as "12,345".
    static func count(_ value: Int) -> String {
        value.formatted()
    }
}

// MARK: - Reading

/// The one way TextMouth takes an entry's bytes out of a ZIP archive,
/// whether into memory for a reader or onto disk for an import (TODO I05).
///
/// ZIPFoundation inflates a compressed entry until its compressed bytes run
/// out, however small a size the archive records for it, so every read here
/// counts the bytes as they come out and stops at the first chunk past the
/// most the entry may hold, before anything is done with that chunk.
enum ArchiveEntryReader {

    /// Reads `entry` of `archive` wholly into memory and returns its bytes
    /// with the checksum of the bytes read, which the caller may compare
    /// with the one the archive stores (`Entry.checksum`).
    /// - Parameters:
    ///   - limit: The most bytes the entry may hold; by default the limit
    ///     `ArchiveEntryLimits.current` sets for its path. An entry that
    ///     declares more is refused before any of it is read.
    ///   - holdingToDeclaredSize: Whether an entry that holds more than the
    ///     archive records for it is refused as well, as an import that
    ///     budgets by the sizes an archive declares needs.
    /// - Throws: `ArchiveEntryOverflow` when the entry holds too much, or
    ///   ZIPFoundation's own error when its data cannot be read.
    static func read(
        _ entry: Entry,
        in archive: Archive,
        limit: Int64? = nil,
        holdingToDeclaredSize: Bool = false
    ) throws -> (data: Data, checksum: CRC32) {
        let limit = limit ?? ArchiveEntryLimits.current.limit(forEntryAt: entry.path)
        let declared = Int64(clamping: entry.uncompressedSize)
        guard declared <= limit else {
            throw ArchiveEntryOverflow.pastLimit(path: entry.path, limit: limit)
        }
        // Within the limit, an import holds the entry to the smaller bound,
        // the size the archive declares; a reader holds it to the limit.
        let maximumBytes = holdingToDeclaredSize ? declared : limit
        let overflow: ArchiveEntryOverflow = holdingToDeclaredSize
            ? .pastDeclaredSize(path: entry.path, declared: declared)
            : .pastLimit(path: entry.path, limit: limit)
        var data = Data()
        let checksum = try stream(entry, in: archive, maximumBytes: maximumBytes, overflow: overflow) { chunk in
            // ZIPFoundation reuses each chunk's buffer, so its bytes are
            // copied here rather than the chunk kept.
            data.append(chunk)
        }
        return (data, checksum)
    }

    /// Streams `entry`'s bytes to `consume` as they come out of `archive`,
    /// holding the entry to the size the archive records for it, and
    /// returns the checksum of the bytes read. `consume` must copy or write
    /// each chunk before it returns: ZIPFoundation reuses its buffer.
    /// - Throws: `ArchiveEntryOverflow.pastDeclaredSize` at the first chunk
    ///   past the recorded size, any error `consume` throws, or
    ///   ZIPFoundation's own error when the entry's data cannot be read.
    static func stream(_ entry: Entry, in archive: Archive, consume: (Data) throws -> Void) throws -> CRC32 {
        let declared = Int64(clamping: entry.uncompressedSize)
        return try stream(
            entry,
            in: archive,
            maximumBytes: declared,
            overflow: .pastDeclaredSize(path: entry.path, declared: declared),
            consume: consume
        )
    }

    /// Streams `entry`'s bytes to `consume`, throwing `overflow` instead of
    /// passing on the chunk that takes the entry past `maximumBytes`.
    private static func stream(
        _ entry: Entry,
        in archive: Archive,
        maximumBytes: Int64,
        overflow: ArchiveEntryOverflow,
        consume: (Data) throws -> Void
    ) throws -> CRC32 {
        var produced: Int64 = 0
        return try archive.extract(entry, skipCRC32: false) { chunk in
            produced += Int64(chunk.count)
            guard produced <= maximumBytes else { throw overflow }
            try consume(chunk)
        }
    }
}
