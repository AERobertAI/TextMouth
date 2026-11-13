#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Combine
import Foundation

/// The analysis fields a batch committed to one book's package record,
/// and the places a rebuild moved (T06's branch D) that the record took,
/// the encoding the record keeps for a text file, and the braille file code
/// it keeps for a braille book, on their way to the book's library row.
///
/// The row takes only the moves its record took, so a move never wins over a
/// newer write another Mac left in the record: a moved place is dated at the
/// move, so a row holding one the record refused would look newer than the
/// other Mac's save, and the next launch would keep the stale place.
///
/// Small, so it can wait: the full chapter and heading index is already on
/// disk, released after each book instead of pinning the parser's memory
/// for the whole batch.
struct ContentAnalysisSummary: Sendable {
    let bookID: UUID
    /// The package whose record took the analysis, by name. A row whose
    /// package is another took no part in it, even under the same ID, as
    /// the new copy Replace Existing puts in a book's place has (ST04): the
    /// old copy's counts, fingerprints, and record of an edit describe
    /// files the new copy does not hold. Moves keep a package's name.
    let packageName: String
    let fields: Book.ContentAnalysisFields
    /// The places the rebuild behind this analysis moved, narrowed to the
    /// moves the record took (`MovedPlaces.taken(by:)`); nil when it moved
    /// none. For a book recovered from its record, the moves that bring the
    /// row to the record's places (`init(recovered:record:)`).
    let movedPlaces: MovedPlaces?
    /// The encoding the book's package record keeps for its text file
    /// (`Book.textEncoding`, FMT16), which a row that lost its own takes
    /// back: a damaged value in library.json reads as none, and so does a row
    /// an older build wrote, while the record keeps it. Nil when the record
    /// names none, or names another book.
    let textEncoding: String?
    /// Who decided `textEncoding`, as the record keeps it
    /// (`Book.textEncodingSource`, encodingchoice), taken back with it.
    let textEncodingSource: TextEncodingSource?
    /// The braille file characters the book's package record keeps for its
    /// BRF or BRL file (`Book.brailleFileCode`, braillecodes), by the
    /// code's id, which a row that lags behind a re-read in other braille
    /// file characters, or lost its own, takes back
    /// (`BrailleFileCodeRecord.standing(row:recorded:)`). Nil when the
    /// record names none, or names another book.
    let brailleFileCode: String?
    /// The braille table the book's package record keeps for its braille
    /// text (`Book.brailleTable`, FMT21), by its stored value, with the
    /// liblouis version of this Mac's tables it was read under
    /// (`brailleTableVersion`), which a row that lags behind a re-read of
    /// the book with another braille code takes back: the record's whenever
    /// it names one, as the braille file code is. Nil when the record names
    /// none, or names another book.
    let brailleTable: String?
    /// The version that goes with `brailleTable` (`Book.brailleTableVersion`).
    let brailleTableVersion: String?

    /// The record's encoding and who decided it, as one.
    var textEncodingRecord: TextEncodingRecord {
        TextEncodingRecord(identifier: textEncoding, source: textEncodingSource)
    }

    /// The analysis fields of `committed`, the book as its package records
    /// it once the analysis is saved (`LibraryPersistenceService.saveContentAnalysis`),
    /// and the places the rebuild moved, narrowed to the moves `committed`
    /// holds: a move the record refused (a place saved meanwhile, perhaps by
    /// another Mac) is put back, so the row does not take it either.
    init(committed: Book, movedPlaces: MovedPlaces? = nil) {
        bookID = committed.id
        packageName = committed.tmbDirectoryName
        fields = committed.contentAnalysisFields
        self.movedPlaces = movedPlaces.map { $0.taken(by: committed) }
        textEncoding = committed.textEncoding
        textEncodingSource = committed.textEncodingSource
        brailleFileCode = committed.brailleFileCode
        brailleTable = committed.brailleTable
        brailleTableVersion = committed.brailleTableVersion
    }

    /// The analysis fields of `recovered`, the library row with the analysis
    /// an earlier run committed applied, and the places that run moved, which
    /// `record`, the book as its package record holds it, describes. The
    /// record describes content.md as it is now, so its places are the
    /// moved ones, and the row (whose library.json was not written before
    /// the earlier run stopped) takes them as moves from its own places
    /// (`placesMoved(to:from:)`). The record is the source of these moves, so
    /// they are not narrowed to what it took, as a fresh commit's are.
    ///
    /// The record's encoding, and who decided it, are taken only from this
    /// book's own record, and only for a format that reads text files, as
    /// `Book.recordedTextEncodingRecord()` takes them: a package record that
    /// names another book, as an old shared
    /// package's may, must never give this row that book's encoding, which
    /// every later reading of this book would then use. The record's braille
    /// file code is taken the same way, from this book's own record only,
    /// and only for a braille book, as `Book.recordedBrailleFileCode()`
    /// takes it.
    init(recovered: Book, record: Book) {
        bookID = recovered.id
        packageName = recovered.tmbDirectoryName
        fields = recovered.contentAnalysisFields
        movedPlaces = Self.placesMoved(to: record, from: recovered)
        // Each counts only from this book's own record, and only for a
        // format whose files are read in it.
        let isOwnRecord = record.id == recovered.id
        let takesEncoding = isOwnRecord && recovered.format.usesTextFileDecoder
        textEncoding = takesEncoding ? record.textEncoding : nil
        textEncodingSource = takesEncoding ? record.textEncodingSource : nil
        brailleFileCode = isOwnRecord && recovered.format == .braille ? record.brailleFileCode : nil
        let takesTable = isOwnRecord && recovered.format == .braille
        brailleTable = takesTable ? record.brailleTable : nil
        brailleTableVersion = takesTable ? record.brailleTableVersion : nil
    }

    /// The moves that bring the places of `row`, the library row, to those
    /// of `record`, the book's package record; nil when they would change
    /// nothing. Each place is taken only where the row still holds it as it
    /// is now (`Book.takeMovedPlaces(original:moved:)`), so a place saved
    /// meanwhile wins. Places are compared as the files store them (dates to
    /// the second, `Book.isAsStored`).
    ///
    /// - The reading position moves when the record's is at least as new as
    ///   the row's: a move is dated at the move, so an older position in the
    ///   record never replaces a newer one of the row's.
    /// - A bookmark moves when the record's bookmark of its ID differs from
    ///   the row's only in where it is and its saved words; one that differs
    ///   otherwise (a label edited on one side) keeps the row's.
    /// - The skipped headings move as one, as `takeMovedPlaces` takes them.
    private static func placesMoved(to record: Book, from row: Book) -> MovedPlaces? {
        let original = row.relocatablePlaces
        let recorded = record.relocatablePlaces
        var moved = original

        // The position: the record's, unless the row's is newer or the
        // record has none.
        if let recordedPosition = recorded.position {
            let rowDate = original.position.map { storedSecond(of: $0.lastUpdated) }
            if rowDate.map({ storedSecond(of: recordedPosition.lastUpdated) >= $0 }) ?? true {
                moved.position = recordedPosition
            }
        }

        // Each bookmark the record also holds, where only its place and
        // words differ.
        let recordedBookmarks = Dictionary(recorded.bookmarks.map { ($0.id, $0) }) { first, _ in first }
        moved.bookmarks = original.bookmarks.map { held in
            guard let there = recordedBookmarks[held.id] else { return held }
            var relocated = held
            relocated.chapterIndex = there.chapterIndex
            relocated.characterOffset = there.characterOffset
            relocated.anchor = there.anchor
            return Book.isAsStored(relocated, there) ? there : held
        }

        // The skips, as one.
        moved.skippedHeadings = recorded.skippedHeadings
        moved.waitingSkippedHeadings = recorded.waitingSkippedHeadings

        guard !Book.isAsStored(moved, original) else { return nil }
        return MovedPlaces(bookID: row.id, original: original, moved: moved, snapshot: nil)
    }

    /// `date` as the library's files store it: to the second (ISO 8601),
    /// so two dates compare as the files would show them.
    private static func storedSecond(of date: Date) -> TimeInterval {
        date.timeIntervalSince1970.rounded(.down)
    }

    /// Gives `book`, the library row, the committed analysis fields and
    /// the moves its record took, and nothing else. The row keeps its own
    /// reading state, settings, and metadata, which are at least as new as
    /// its package's, except that it takes each of those moves as the record
    /// did: only where it still holds the place as it was, so a place saved
    /// meanwhile wins. A move the record refused is not taken, so a moved
    /// place never wins over a newer write another Mac left in the record.
    /// The row takes the record's encoding, with who decided it
    /// (`textEncodingRecord`), as the one that stands between the two
    /// (`TextEncodingRecord.standing(row:recorded:)`): the listener's own
    /// decision, which a re-read in another encoding writes into the record
    /// with its new text before the row takes it (encodingchoice), so a row
    /// a stop left behind catches up when its analysis is recovered; or the
    /// record's guess, for a row that lost its own. A row that holds a guess
    /// of its own otherwise keeps it. The row takes the record's braille
    /// file code (`brailleFileCode`) by the same rule
    /// (`BrailleFileCodeRecord.standing(row:recorded:)`): the record's
    /// whenever it names one, which a re-read in other braille file
    /// characters writes with its new text before the row takes it
    /// (braillecodes), and the row's own otherwise.
    func apply(to book: inout Book) {
        book.contentAnalysisFields = fields
        if let movedPlaces {
            book.takeMovedPlaces(original: movedPlaces.original, moved: movedPlaces.moved)
        }
        book.textEncodingRecord = .standing(row: book.textEncodingRecord, recorded: textEncodingRecord)
        book.brailleFileCode = BrailleFileCodeRecord.standing(row: book.brailleFileCode, recorded: brailleFileCode)
        // The braille table, with its version, is the record's whenever the
        // record names one: only a re-read of the book with another braille
        // code (or an import) decides it, and it writes the record first.
        if let brailleTable {
            book.brailleTable = brailleTable
            book.brailleTableVersion = brailleTableVersion
        }
    }
}

/// Finished books' analysis summaries, waiting to reach the library
/// together (TODO PERF12).
///
/// The text cache batch and the statistics pass finish books one at a time
/// on their workers: hundreds of them at the first launch after the cache
/// format changes. Each finished book used to change its row at once, a
/// library update that re-rendered every Library window's list, plus an
/// index save, several times a second for minutes. Summaries now wait here
/// and reach the library together, in one change and one save: at most
/// `flushInterval` after the first of them arrived, when the pass ends, and
/// when TextMouth quits. A summary a crash loses is not lost work: the
/// book's package record already holds the analysis and the places the
/// rebuild moved, which the next launch's batch recovers without parsing
/// the book again (`BookContentAnalysisService.recoveredTextCache`): the
/// analysis, and the record's places as moves to the row
/// (`ContentAnalysisSummary.init(recovered:record:)`).
@MainActor
final class ContentAnalysisSummaryBuffer {
    /// The longest a finished book's summary waits to reach the library.
    static let flushInterval: TimeInterval = 0.5

    /// Applies summaries to the library, in one change and one save.
    private let apply: @MainActor ([ContentAnalysisSummary]) -> Void
    /// The summaries waiting, in the order they arrived.
    private var pending: [ContentAnalysisSummary] = []
    /// The flush scheduled when the first of `pending` arrived.
    private var scheduledFlush: DispatchWorkItem?
    /// Flushes as TextMouth quits; cancelled with the buffer.
    private var terminationSubscription: AnyCancellable?

    /// A buffer that hands summaries to `apply`.
    /// - Parameters:
    ///   - notificationCenter: Where TextMouth's quitting is announced: the
    ///     app's center, unless a test passes its own.
    ///   - apply: Gives the library rows the summaries, in one change of the
    ///     library and one save.
    init(
        notificationCenter: NotificationCenter = .default,
        apply: @escaping @MainActor ([ContentAnalysisSummary]) -> Void
    ) {
        self.apply = apply
        // Delivered on the posting thread, the main thread, while AppKit
        // quits, so the flush is done before TextMouth exits.
        // iOS ends an app without a guaranteed willTerminate notice, so
        // phase 0 listens for none there (phase 1 flushes as the app goes
        // to the background).
        #if os(macOS)
        terminationSubscription = notificationCenter
            .publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.flushForTermination() }
            }
        #endif
    }

    /// How many summaries are waiting.
    var pendingCount: Int {
        pending.count
    }

    /// Adds a finished book's summary. The first summary waiting schedules
    /// a flush `flushInterval` later; the rest wait for that one.
    func add(_ summary: ContentAnalysisSummary) {
        pending.append(summary)
        guard scheduledFlush == nil else { return }
        let flush = DispatchWorkItem { [weak self] in
            self?.flush()
        }
        scheduledFlush = flush
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flushInterval, execute: flush)
    }

    /// Hands every waiting summary to the library now, as a pass does when
    /// it ends; with none waiting, does nothing.
    func flush() {
        scheduledFlush?.cancel()
        scheduledFlush = nil
        guard !pending.isEmpty else { return }
        let summaries = pending
        pending = []
        apply(summaries)
    }

    /// Flushes as TextMouth quits, and writes the library index at once
    /// rather than after the usual short delay, which quitting would cut
    /// off.
    private func flushForTermination() {
        flush()
        LibraryPersistenceService.flushPendingSave()
    }
}

extension LibraryViewModel {
    /// Gives the rows of `summaries`' books their committed analysis fields
    /// in one change of the library and one save (TODO PERF12). A book no
    /// longer in the library is skipped, and so is a row whose package is
    /// not the one the analysis was committed to, as the new copy Replace
    /// Existing put in the book's place under its ID while the old copy's
    /// analysis was on its way (ST04); for a book summarized twice, the
    /// later summary wins.
    func applyAnalysisSummaries(_ summaries: [ContentAnalysisSummary]) {
        let latest = Dictionary(summaries.map { ($0.bookID, $0) }, uniquingKeysWith: { _, later in later })
        var books = library.books
        var changed = false
        for index in books.indices {
            guard let summary = latest[books[index].id],
                  summary.packageName == books[index].tmbDirectoryName else { continue }
            summary.apply(to: &books[index])
            changed = true
        }
        guard changed else { return }
        library.books = books
        save()
    }
}
