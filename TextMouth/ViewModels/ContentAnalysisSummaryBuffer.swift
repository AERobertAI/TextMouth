import AppKit
import Combine
import Foundation

/// The analysis fields a batch committed to one book's package record,
/// and the places a rebuild moved (T06's branch D) that the record took,
/// on their way to the book's library row.
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
    let fields: Book.ContentAnalysisFields
    /// The places the rebuild behind this analysis moved, narrowed to the
    /// moves the record took (`MovedPlaces.taken(by:)`); nil when it moved
    /// none. For a book recovered from its record, the moves that bring the
    /// row to the record's places (`init(recovered:record:)`).
    let movedPlaces: MovedPlaces?

    /// The analysis fields of `committed`, the book as its package records
    /// it once the analysis is saved (`LibraryPersistenceService.saveContentAnalysis`),
    /// and the places the rebuild moved, narrowed to the moves `committed`
    /// holds: a move the record refused (a place saved meanwhile, perhaps by
    /// another Mac) is put back, so the row does not take it either.
    init(committed: Book, movedPlaces: MovedPlaces? = nil) {
        bookID = committed.id
        fields = committed.contentAnalysisFields
        self.movedPlaces = movedPlaces.map { $0.taken(by: committed) }
    }

    /// The analysis fields of `recovered`, the library row with the analysis
    /// an earlier run committed applied, and the places that run moved, which
    /// `record`, the book as its package record holds it, describes. The
    /// record describes content.md as it is now, so its places are the
    /// moved ones, and the row (whose library.json was not written before
    /// the earlier run stopped) takes them as moves from its own places
    /// (`placesMoved(to:from:)`). The record is the source of these moves, so
    /// they are not narrowed to what it took, as a fresh commit's are.
    init(recovered: Book, record: Book) {
        bookID = recovered.id
        fields = recovered.contentAnalysisFields
        movedPlaces = Self.placesMoved(to: record, from: recovered)
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
    func apply(to book: inout Book) {
        book.contentAnalysisFields = fields
        if let movedPlaces {
            book.takeMovedPlaces(original: movedPlaces.original, moved: movedPlaces.moved)
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
        terminationSubscription = notificationCenter
            .publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.flushForTermination() }
            }
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
    /// longer in the library is skipped; for a book summarized twice, the
    /// later summary wins.
    func applyAnalysisSummaries(_ summaries: [ContentAnalysisSummary]) {
        let latest = Dictionary(summaries.map { ($0.bookID, $0) }, uniquingKeysWith: { _, later in later })
        var books = library.books
        var changed = false
        for index in books.indices {
            guard let summary = latest[books[index].id] else { continue }
            summary.apply(to: &books[index])
            changed = true
        }
        guard changed else { return }
        library.books = books
        save()
    }
}
