import Foundation
import os

// MARK: - A Snapshot of a Book's Old Text and Places

/// A book's old text, copied aside with the book's saved places as they were
/// (T06's branch D). A rebuild of the book's text takes one just before it
/// replaces content.md, writes the new text, and moves the places from the
/// snapshot's text to the new one (`movePlaces(to:at:)`). The moved places
/// are committed to the book's record with its analysis, and the snapshot is
/// then discarded. A snapshot a crash or a quit left between the write and
/// the commit is found at the next launch (`leftovers(in:)`) and finished;
/// a copy a rebuild in this run is still using is never a leftover.
///
/// It lives in a folder of this Mac's own (`MachineLocalPaths.placeSnapshots`),
/// never in the data directory, which a cloud library would upload. With the
/// library on the startup disk the copy of the text is a clone, taking no
/// space until one of the two files changes; elsewhere it is an ordinary
/// copy (0.67 MB for a typical book).
struct PlaceSnapshot: Equatable, Sendable {
    /// The name of the old text inside a snapshot's folder.
    static let textFileName = "content.md"
    /// The name of the record inside a snapshot's folder. It is written last,
    /// so a folder without it was never finished.
    static let recordFileName = "places.json"

    /// The folder names of the copies this run of TextMouth made and has
    /// not discarded: copies a rebuild is still using, between taking the
    /// copy and committing the moved places. `leftovers(in:)` neither lists
    /// nor removes them, so a recovery that runs while a reader rebuilds its
    /// book (as when the library is rebuilt from Storage settings) never
    /// takes or sweeps a copy in use. A copy whose commit failed stays this
    /// run's, and the next launch finishes it.
    private static let inUse = OSAllocatedUnfairLock(initialState: Set<String>())

    /// What a snapshot keeps of a book besides its old text.
    struct Record: Codable, Equatable, Sendable {
        /// The book.
        var bookID: UUID
        /// The book's title: the old text is read with it, as the reader
        /// reads a content.md, and the debug log's line names the book by it.
        var title: String
        /// The book's author, which the old text is read with.
        var author: String
        /// The book's places as they were when the old text was copied aside.
        var places: PlaceRelocator.Places
        /// When the old text was copied aside.
        var takenAt: Date
    }

    /// The snapshot's own folder in the snapshots folder, named
    /// "<book ID> <UUID>" so that two rebuilds of one book never share one.
    let folder: URL
    /// What the snapshot keeps of the book besides its text.
    let record: Record

    /// Where the old text is kept.
    private var textURL: URL { Self.textURL(in: folder) }

    /// Where the old text is kept in a snapshot folder `folder`.
    private static func textURL(in folder: URL) -> URL {
        folder.appendingPathComponent(textFileName, isDirectory: false)
    }

    /// Where the record is kept in a snapshot folder `folder`.
    private static func recordURL(in folder: URL) -> URL {
        folder.appendingPathComponent(recordFileName, isDirectory: false)
    }

    // MARK: Keeping and Finding

    /// Copies the old text, the file at `cacheURL`, aside with `record`:
    /// into a new folder of its own in `folder` (made, with `folder`, as
    /// needed), as `content.md`, and then writes the record as `places.json`.
    /// The record comes last, so a folder without it was never finished. A
    /// failure removes the new folder before it throws.
    /// - Parameters:
    ///   - cacheURL: The book's content.md, about to be replaced.
    ///   - record: The book and its places as they are now.
    ///   - folder: The snapshots folder.
    static func keep(
        textAt cacheURL: URL,
        record: Record,
        in folder: URL = MachineLocalPaths.placeSnapshots
    ) throws -> PlaceSnapshot {
        try keep(record: record, in: folder) { textURL in
            // Clones on APFS when source and destination share a volume.
            try FileManager.default.copyItem(at: cacheURL, to: textURL)
        }
    }

    /// Keeps `text`, the bytes of a content.md, aside with `record`, as
    /// `keep(textAt:record:in:)` keeps a file: the bytes are written
    /// atomically as `content.md`. An Edit Text session keeps the text its
    /// edits replace this way, as TextMouth last took it.
    /// - Parameters:
    ///   - text: The text's bytes, exactly as they are to be read back.
    ///   - record: The book and its places as they are now.
    ///   - folder: The snapshots folder.
    static func keep(
        text: Data,
        record: Record,
        in folder: URL = MachineLocalPaths.placeSnapshots
    ) throws -> PlaceSnapshot {
        try keep(record: record, in: folder) { textURL in
            try text.write(to: textURL, options: .atomic)
        }
    }

    /// The sequence both forms of `keep` share: makes the snapshot's folder
    /// (and `folder`) as needed, marks it in use first, has `putText` put
    /// the text at the URL it is given, and writes the record last. A
    /// failure removes the folder and unmarks it before it throws.
    /// - Parameters:
    ///   - record: The book and its places as they are now.
    ///   - folder: The snapshots folder.
    ///   - putText: Puts the old text at the given URL, in the new folder.
    private static func keep(
        record: Record,
        in folder: URL,
        putText: (URL) throws -> Void
    ) throws -> PlaceSnapshot {
        let name = "\(record.bookID.uuidString) \(UUID().uuidString)"
        let snapshotFolder = folder.appendingPathComponent(name, isDirectory: true)
        let fileManager = FileManager.default
        // In use before its folder exists, so a listing meanwhile leaves the
        // half-made copy alone.
        inUse.withLock { _ = $0.insert(name) }
        do {
            try fileManager.createDirectory(at: snapshotFolder, withIntermediateDirectories: true)
            try putText(textURL(in: snapshotFolder))
            let data = try JSONEncoder().encode(record)
            try data.write(to: recordURL(in: snapshotFolder), options: .atomic)
        } catch {
            try? fileManager.removeItem(at: snapshotFolder)
            inUse.withLock { _ = $0.remove(name) }
            throw error
        }
        return PlaceSnapshot(folder: snapshotFolder, record: record)
    }

    /// Every finished snapshot in `folder` that no rebuild of this run is
    /// still using (`inUse`), oldest first by `record.takenAt`
    /// (ties by folder name). A folder whose record is missing or cannot be
    /// read, or whose `content.md` is missing, is a copy a stop left
    /// unfinished, and is removed. A missing `folder` holds no snapshots, and
    /// files in it that are not folders are left alone.
    static func leftovers(in folder: URL = MachineLocalPaths.placeSnapshots) -> [PlaceSnapshot] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return [] }

        let busy = inUse.withLock { $0 }
        var finished: [PlaceSnapshot] = []
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            // A copy this run is still using is no leftover, finished or not.
            guard !busy.contains(entry.lastPathComponent) else { continue }
            // Named from `folder` rather than taken as listed, which may
            // spell the path differently (/private/var for /var).
            let snapshotFolder = folder.appendingPathComponent(entry.lastPathComponent, isDirectory: true)
            if let snapshot = finishedSnapshot(in: snapshotFolder) {
                finished.append(snapshot)
            } else {
                try? fileManager.removeItem(at: snapshotFolder)
            }
        }
        return finished.sortedStably {
            $0.record.takenAt != $1.record.takenAt
                ? $0.record.takenAt < $1.record.takenAt
                : $0.folder.lastPathComponent < $1.folder.lastPathComponent
        }
    }

    /// The snapshot in `folder`, or nil when its record cannot be read or its
    /// old text is missing: a copy that was never finished.
    private static func finishedSnapshot(in folder: URL) -> PlaceSnapshot? {
        guard FileManager.default.fileExists(atPath: textURL(in: folder).path),
              let data = try? Data(contentsOf: recordURL(in: folder)),
              let record = try? JSONDecoder().decode(Record.self, from: data)
        else { return nil }
        return PlaceSnapshot(folder: folder, record: record)
    }

    // MARK: Using

    /// The bytes of the snapshot's kept text, exactly as they were kept.
    func textBytes() throws -> Data {
        try Data(contentsOf: textURL)
    }

    /// The snapshot's old text as this build reads a content.md: the file's
    /// bytes decoded (`MarkdownCacheService.cacheText(from:at:)`) and parsed
    /// with the book's title and author.
    func oldText() throws -> DocumentContent {
        try oldText(from: try textBytes())
    }

    /// The old text parsed from `bytes`, the snapshot's kept text already
    /// read (`textBytes()`), exactly as `oldText()` parses it: a caller that
    /// has checked the bytes reads them once.
    func oldText(from bytes: Data) throws -> DocumentContent {
        let markdown = try MarkdownCacheService.cacheText(from: bytes, at: textURL)
        return MarkdownCacheService.parseMultiChapterMarkdown(markdown, bookTitle: record.title, bookAuthor: record.author)
    }

    /// Removes the snapshot's folder, which this run then no longer uses. A
    /// folder already gone is no error.
    func discard() {
        try? FileManager.default.removeItem(at: folder)
        Self.inUse.withLock { _ = $0.remove(folder.lastPathComponent) }
    }

    // MARK: Test Seam

    /// Forgets which copies this run is still using, as a quit does: each
    /// becomes a leftover that `leftovers(in:)` lists and the launch's
    /// recovery finishes. Tests call it to stand for a stop between a
    /// rebuild and its commit.
    static func forgetCopiesInUse() {
        inUse.withLock { $0.removeAll() }
    }

    /// Moves the book's places from the snapshot's old text to `new`, the
    /// text that replaced it, as of `date`.
    ///
    /// - When the old text cannot be read the copy is no use: it is
    ///   discarded, the debug log gets one `PLACES_NOT_MOVED` line, and the
    ///   result is nil.
    /// - When anything moved, the debug log gets the counts' line
    ///   (`PlaceRelocator.Counts.logLine(title:)`).
    /// - When the moved places equal the saved ones nothing needs writing:
    ///   the snapshot is discarded and the result is nil. That is decided by
    ///   comparing the places, never by the counts: nothing counts as moved
    ///   when only a position's offset in the whole book or a place's words
    ///   changed, and those must still be written.
    /// - Otherwise the result holds both sets of places and the snapshot,
    ///   which stays until the book's record holds the moved places.
    func movePlaces(to new: DocumentContent, at date: Date) -> MovedPlaces? {
        let outcome: PlaceRelocator.Outcome
        do {
            outcome = try PlaceRelocator.relocate(record.places, from: { try oldText() }, to: new, movedAt: date)
        } catch {
            discard()
            DiagnosticLog.event(.storage, "PLACES_NOT_MOVED: \(record.title): \(error.localizedDescription)")
            return nil
        }
        if outcome.counts.anythingMoved {
            DiagnosticLog.event(.storage, outcome.counts.logLine(title: record.title))
        }
        guard outcome.places != record.places else {
            discard()
            return nil
        }
        return MovedPlaces(bookID: record.bookID, original: record.places, moved: outcome.places, snapshot: self)
    }
}

// MARK: - Places Moved by a Rebuild

/// A book's places moved by a rebuild of its text. A writer takes each moved
/// place only where the book still holds it as it was
/// (`Book.takeMovedPlaces(original:moved:)`), so a place saved meanwhile wins.
struct MovedPlaces: Equatable, Sendable {
    /// The book.
    let bookID: UUID
    /// The places as they were when the old text was copied aside.
    let original: PlaceRelocator.Places
    /// Where the places are in the new text.
    let moved: PlaceRelocator.Places
    /// The copy of the old text and places, deleted once the book's record
    /// holds the moved places; nil when there is none.
    let snapshot: PlaceSnapshot?

    /// Discards the snapshot, once the book's record holds the moved places.
    func discardSnapshot() {
        snapshot?.discard()
    }

    /// These moves narrowed to the ones `committed`, the book as its record
    /// holds it after the save, took: each move the record did not take is
    /// put back to its original, so a writer taking the result changes only
    /// what the record changed. A record refuses a move where another Mac
    /// (or the listener) saved the place meanwhile; a row that took that
    /// move anyway would hold a stale place dated at the move, which later
    /// looks newer than the other Mac's save. Places are compared as the
    /// record's file stores them (`Book.isAsStored`).
    ///
    /// - The position moves when the record holds the moved one.
    /// - Each bookmark moves when the record holds the moved bookmark of
    ///   its `id`. A moved bookmark with no original of its `id` stays as it
    ///   is: nothing was there to put back.
    /// - The skips move as one, as `Book.takeMovedPlaces` moves them: both
    ///   lists, or neither.
    func taken(by committed: Book) -> MovedPlaces {
        var narrowed = moved

        // The position, back to what it was unless the record took the move.
        if !Book.isAsStored(committed.readingPosition, moved.position) {
            narrowed.position = original.position
        }

        // Each bookmark, back to its original unless the record took it. The
        // first of any bookmarks sharing an ID answers for it.
        let originalBookmarks = Dictionary(original.bookmarks.map { ($0.id, $0) }) { first, _ in first }
        let committedBookmarks = Dictionary(committed.bookmarks.map { ($0.id, $0) }) { first, _ in first }
        narrowed.bookmarks = moved.bookmarks.map { now in
            guard !Book.isAsStored(committedBookmarks[now.id], now), let before = originalBookmarks[now.id] else { return now }
            return before
        }

        // The skips, as one: both lists moved, or both as they were.
        let skipsMoved = (committed.skippedHeadings ?? []) == moved.skippedHeadings
            && (committed.waitingSkippedHeadings ?? []) == moved.waitingSkippedHeadings
        if !skipsMoved {
            narrowed.skippedHeadings = original.skippedHeadings
            narrowed.waitingSkippedHeadings = original.waitingSkippedHeadings
        }

        return MovedPlaces(bookID: bookID, original: original, moved: narrowed, snapshot: snapshot)
    }
}
