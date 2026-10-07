import SwiftUI

/// What the import overlay shows at one moment (FR10): the bar's books done
/// of the total, which is 0 of 0 while the bar only spins, the line beneath
/// it, which says what the import is doing, and the lines under that: the
/// time a ZIP batch has left, or that the imports are cancelling.
struct ImportProgressState: Equatable {
    /// The books done, which the bar and its count show.
    var current = 0
    /// The books the bar counts toward; 0 while the bar only spins.
    var total = 0
    /// The line under the bar: what the import is doing, or empty.
    var message = ""
    /// The number of the book a ZIP batch has under way, from 1, and when it
    /// began; nil before the batch's first book.
    private(set) var bookNumber: Int?
    private(set) var bookStartedAt: Date?
    /// The batch's books timed so far, those imported or failed, and the
    /// seconds they took in all, which the time left is estimated from.
    private(set) var timedBooks = 0
    private(set) var timedSeconds: TimeInterval = 0
    /// The seconds the batch has left, estimated as its last book finished;
    /// nil while no estimate applies (`ImportTimeEstimate`).
    private(set) var secondsLeft: TimeInterval?
    /// Whether Cancel was pressed while this import runs (TODO I05).
    private(set) var isCancelling = false

    /// The state that shows `message` alone, under a bar that only spins:
    /// an import starting or waiting.
    init(message: String = "") {
        self.message = message
    }

    /// Takes a ZIP batch's `progress`, reported at `date` (TODO I05, FR10).
    /// While the archive is extracted the bar only spins and the line counts
    /// the archive's items, so the overlay moves before the first book; once
    /// books import, the bar counts the books done, and the line names the
    /// book under way and the step it is at, which it keeps until the next
    /// book begins. Each book is timed from its first report to its last,
    /// and as each finishes the time left is estimated again; the
    /// extraction is never timed.
    mutating func receive(_ progress: ZipImportProgress, at date: Date) {
        switch progress {
        case let .extracting(archive, done, total):
            current = 0
            self.total = 0
            message = ImportProgressWording.extracting(archive: archive, done: done, total: total)
        case let .importingBook(number, total, book, step):
            if number != bookNumber {
                bookNumber = number
                bookStartedAt = date
            }
            // The books before this one are done.
            current = number - 1
            self.total = total
            message = ImportProgressWording.book(book, number: number, of: total, step: step)
        case let .importing(done, total, skippedDuplicate):
            current = done
            self.total = total
            // The book done is the one under way, timed from its start.
            if !skippedDuplicate, bookNumber == done, let bookStartedAt {
                timedBooks += 1
                timedSeconds += max(0, date.timeIntervalSince(bookStartedAt))
            }
            secondsLeft = ImportTimeEstimate.secondsLeft(
                timedSeconds: timedSeconds,
                timedBooks: timedBooks,
                remaining: total - done
            )
        }
    }

    /// Notes that Cancel was pressed: the overlay says the import is
    /// cancelling, and no longer estimates the time left, since a batch
    /// stops after the book under way.
    mutating func cancel() {
        isCancelling = true
    }

    /// The lines the overlay shows under the line that says what the import
    /// is doing: that it is cancelling, once Cancel is pressed; otherwise
    /// the time left, once a book of a batch of several is done and while
    /// books are left.
    var details: [String] {
        if isCancelling {
            return [ImportProgressWording.cancelling(afterBook: bookNumber != nil)]
        }
        return secondsLeft.map { [ImportProgressWording.timeLeft($0)] } ?? []
    }

    /// The lines the overlay shows under its title, in order: the books
    /// done of the total, while the bar counts them, the line that says what
    /// the import is doing, and the details under it.
    var lines: [String] {
        let count = total > 0 ? [ImportProgressWording.count(done: current, of: total)] : []
        return count + [message] + details
    }

    /// What VoiceOver reads for the overlay: its title and every line it
    /// shows, as "Importing Books: 2 of 100 books processed. Book 3 of 100:
    /// “Moby Dick.epub”, reading its text. About 4 minutes left."
    var spokenStatus: String {
        ImportProgressWording.spokenStatus(lines)
    }
}

/// The progress of the imports under way, as the Library window's import
/// overlay shows it (`LibraryWindowView.importProgressOverlay(for:)`).
///
/// It is an object of its own, which only the overlay observes, as the text
/// extraction's progress is (`TextExtractionProgress`, TODO PERF12): a ZIP
/// batch reports every step of every book, and each report published by the
/// library model itself would redraw every Library window's list. The
/// library model owns one and changes it on the main thread; whether the
/// overlay shows at all is still the model's `isImporting`.
@MainActor
final class ImportProgress: ObservableObject {
    /// What the overlay shows now.
    @Published private(set) var state = ImportProgressState()
    /// Tells the time each report arrives, which times the books: the
    /// system's clock in the app, a test's own clock in a test.
    private let now: @MainActor () -> Date

    /// Progress timed by `now`: the system's clock unless a test passes its
    /// own.
    init(now: @escaping @MainActor () -> Date = { Date() }) {
        self.now = now
    }

    /// Shows `message` alone, under a bar that only spins: an import
    /// starting, or waiting for a data-directory move (TODO S04).
    func show(_ message: String) {
        state = ImportProgressState(message: message)
    }

    /// Takes a ZIP batch's `progress`, timed as it arrives: how far its
    /// extraction has got, the book under way and its step, and the books
    /// done, with the time left (TODO I05, FR10).
    func receive(_ progress: ZipImportProgress) {
        state.receive(progress, at: now())
    }

    /// Notes that Cancel was pressed while this import runs, which the
    /// overlay then says in place of the time left (TODO I05, FR10).
    func cancel() {
        state.cancel()
    }

    /// Shows nothing more: an import ended, or none is under way.
    func clear() {
        state = ImportProgressState()
    }
}
