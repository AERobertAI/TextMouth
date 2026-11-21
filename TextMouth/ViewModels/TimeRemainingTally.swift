import Foundation

/// The time left in a list of books, added up for the Library's summary bar
/// (the audit's C7, November 13, 2026).
///
/// The bar redraws each time a reader reports a new position, about once a
/// second while anything plays, and used to add the list up anew each time:
/// for each of 1,500 books a copy of the book with its live position in
/// place of its own, and an estimate. Only the few books a reader has open
/// have a live position, so a `TimeRemainingTally` adds the list up once, at
/// the checkpointed positions the list shows, and keeps what each book
/// contributed; a redraw takes the kept figures and estimates again only the
/// books that have a live position.
///
/// Every figure is the one a full addition gives, added in the list's order,
/// so the cached bar says what an uncached one says, to the last bit.
///
/// What is kept is good for the same array of books and the same speed. The
/// array is told by its storage, which the tally holds on to so that it is
/// never another array's: a library change makes a list anew, with new
/// storage, and the next addition is made afresh.
@MainActor
final class TimeRemainingTally {

    /// What a list of books comes to.
    struct Sum: Equatable {
        /// The time left in the books whose time is known, in seconds.
        var time: TimeInterval = 0
        /// How many books have a known time left.
        var known = 0
        /// How many books have none: not yet opened, or of a length not known.
        var unknown = 0
    }

    /// The books the kept figures were made from, held so that their storage
    /// stays theirs.
    private var books: [Book] = []
    /// The speed (words a minute) the kept figures were made at; nil before
    /// the first addition.
    private var wpm: Double?
    /// What each of `books` contributes at its listed position, in order:
    /// its time left, or nil when that is not known.
    private var listedRemaining: [TimeInterval?] = []
    /// Where each book is in `books`, by ID, for the books a reader has
    /// open: more than one place for a book listed twice, which the full
    /// addition gives the live position at each.
    private var indexesByID: [UUID: [Int]] = [:]

    /// How many times a book's time was estimated, which an addition made
    /// afresh adds the list's length to and a redraw adds one for each book
    /// a reader has open. Tests read it.
    private(set) var estimateCount = 0

    /// The sum of `books` at `wpm`, each book at its reader's live position
    /// while that is newer than the one it is listed with.
    func sum(of books: [Book], wpm: Double, livePositions: LiveReadingPositions) -> Sum {
        keepFigures(of: books, at: wpm)
        // The few books a reader has open are estimated anew, each from its
        // live position; every other book contributes what it did.
        var liveRemaining: [Int: TimeInterval?] = [:]
        for bookID in livePositions.liveBookIDs {
            guard let indexes = indexesByID[bookID], let first = indexes.first else { continue }
            estimateCount += 1
            let remaining = livePositions.applied(to: books[first]).estimatedTimeRemaining(wpm: wpm)
            for index in indexes {
                liveRemaining[index] = remaining
            }
        }
        var total = Sum()
        for index in listedRemaining.indices {
            let remaining = liveRemaining.isEmpty ? listedRemaining[index] : liveRemaining[index] ?? listedRemaining[index]
            total.add(remaining)
        }
        return total
    }

    /// Makes the figures of `books` at `wpm` when the ones kept are not of
    /// this array of books at this speed.
    private func keepFigures(of books: [Book], at wpm: Double) {
        guard !isKept(books, at: wpm) else { return }
        self.books = books
        self.wpm = wpm
        listedRemaining = books.map { $0.estimatedTimeRemaining(wpm: wpm) }
        estimateCount += books.count
        indexesByID = [:]
        for (index, book) in books.enumerated() {
            indexesByID[book.id, default: []].append(index)
        }
    }

    /// Whether the kept figures are of `books`, the very array and no other
    /// with equal books, at `wpm`.
    private func isKept(_ books: [Book], at wpm: Double) -> Bool {
        guard self.wpm == wpm, self.books.count == books.count else { return false }
        // Two arrays with one storage hold the same books: one of them is
        // kept here, so a change by whoever owns the other has copied it.
        return self.books.withUnsafeBufferPointer { kept in
            books.withUnsafeBufferPointer { given in kept.baseAddress == given.baseAddress }
        }
    }

    /// The sum of `books` at `wpm` added up from nothing, with no figures
    /// kept: for a list that is added up once, as a folder's facts or the
    /// spoken summary of the phone's list are.
    static func sum(of books: [Book], wpm: Double, livePositions: LiveReadingPositions) -> Sum {
        var total = Sum()
        for book in books {
            total.add(livePositions.estimatedTimeRemaining(of: book, wpm: wpm))
        }
        return total
    }
}

private extension TimeRemainingTally.Sum {
    /// Adds a book's time left, `remaining`, or its being unknown (nil).
    mutating func add(_ remaining: TimeInterval?) {
        if let remaining {
            time += remaining
            known += 1
        } else {
            unknown += 1
        }
    }
}
