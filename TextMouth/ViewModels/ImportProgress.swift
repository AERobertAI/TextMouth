import SwiftUI

/// What the import overlay shows at one moment (FR10): the bar's books done
/// of the total, which is 0 of 0 while the bar only spins, the line beneath
/// it, which says what the import is doing, and the lines under that: how
/// long the book under way has taken, once that is long enough to say, and
/// the time a ZIP batch has left, or that the imports are cancelling.
struct ImportProgressState: Equatable {
    /// A book being imported, the step it is at, and when it began.
    struct BookUnderWay: Equatable {
        /// Its name: its file, or a DAISY book's folder, as the archive or
        /// the Finder names it.
        let name: String
        /// Its number in a ZIP batch, from 1; nil for an import of one book.
        let number: Int?
        /// The step it is at.
        var step: ImportStep
        /// When it began, which the time on it counts from.
        let startedAt: Date
        /// Whether it is done: its line stays until the next book begins,
        /// but the time on it is no longer said.
        var isDone = false
    }

    /// The books done, which the bar and its count show.
    var current = 0
    /// The books the bar counts toward; 0 while the bar only spins.
    var total = 0
    /// What the import is doing while no book is under way: a sentence
    /// alone, as an import starts or waits, or how far an archive's
    /// extraction has got.
    private(set) var notice = ""
    /// The book under way, while one is.
    private(set) var book: BookUnderWay?
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
        notice = message
    }

    /// The state of an import of one book, named `name`, begun at `date`: a
    /// file, or an archive holding one book. It begins by reading the file.
    init(book name: String, at date: Date) {
        book = BookUnderWay(name: name, number: nil, step: .readingSource, startedAt: date)
    }

    /// The line under the bar: the book under way and the step it is at,
    /// or, with none, the notice.
    var message: String {
        guard let book else { return notice }
        guard let number = book.number else {
            return ImportProgressWording.book(book.name, step: book.step)
        }
        return ImportProgressWording.book(book.name, number: number, of: total, step: book.step)
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
            book = nil
            notice = ImportProgressWording.extracting(archive: archive, done: done, total: total)
        case let .importingBook(number, total, name, step):
            // A book's first report begins it; the later ones move its step.
            if book?.number == number {
                book?.step = step
            } else {
                book = BookUnderWay(name: name, number: number, step: step, startedAt: date)
            }
            // The books before this one are done.
            current = number - 1
            self.total = total
        case let .importing(done, total, skippedDuplicate):
            current = done
            self.total = total
            // The book done is the one under way, timed from its start.
            if let finished = book, finished.number == done, !finished.isDone {
                book?.isDone = true
                if !skippedDuplicate {
                    timedBooks += 1
                    timedSeconds += max(0, date.timeIntervalSince(finished.startedAt))
                }
            }
            secondsLeft = ImportTimeEstimate.secondsLeft(
                timedSeconds: timedSeconds,
                timedBooks: timedBooks,
                remaining: total - done
            )
        }
    }

    /// The import of one book began `step`.
    mutating func reach(_ step: ImportStep) {
        book?.step = step
    }

    /// Notes that Cancel was pressed: the overlay says the import is
    /// cancelling, and no longer estimates the time left, since a batch
    /// stops after the book under way.
    mutating func cancel() {
        isCancelling = true
    }

    /// The lines the overlay shows at `now` under the line that says what
    /// the import is doing: how long the book under way has taken, once
    /// that is long enough to say and until it is done
    /// (`ImportProgressWording.timeOnBook(_:)`);
    /// then that the import is cancelling, once Cancel is pressed, or else
    /// the time left, once a book of a batch of several is done and while
    /// books are left.
    func details(at now: Date) -> [String] {
        var details: [String] = []
        if let book, !book.isDone,
           let timeOnBook = ImportProgressWording.timeOnBook(now.timeIntervalSince(book.startedAt)) {
            details.append(timeOnBook)
        }
        if isCancelling {
            details.append(ImportProgressWording.cancelling(afterBook: book != nil))
        } else if let secondsLeft {
            details.append(ImportProgressWording.timeLeft(secondsLeft))
        }
        return details
    }

    /// The lines the overlay shows at `now` under its title, in order: the
    /// books done of the total, while the bar counts them, the line that
    /// says what the import is doing, and the details under it.
    func lines(at now: Date) -> [String] {
        let count = total > 0 ? [ImportProgressWording.count(done: current, of: total)] : []
        return count + [message] + details(at: now)
    }

    /// What VoiceOver reads for the overlay at `now`: its title and every
    /// line it shows, as "Importing Books: 2 of 100 books processed. Book 3
    /// of 100: “Moby Dick.epub”, reading its text. 15 seconds on this book.
    /// About 4 minutes left."
    func spokenStatus(at now: Date) -> String {
        ImportProgressWording.spokenStatus(lines(at: now))
    }
}

/// The progress of the imports under way, as the Library window's import
/// overlay shows it (`LibraryWindowView.importProgressOverlay(for:at:)`).
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

    /// Shows the import of one book, named `name`, beginning now: a file,
    /// or an archive holding one book (FR10).
    func showBook(_ name: String) {
        state = ImportProgressState(book: name, at: now())
    }

    /// Shows that the import of one book began `step`.
    func reach(_ step: ImportStep) {
        state.reach(step)
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

    /// For an import of one book that runs on the import queue: shows, on
    /// the main queue, that the book named `name` begins, and returns the
    /// observer that shows each step its import then begins on the book's
    /// package, before it tells `next`, the queue's test hook, when there is
    /// one (FR10).
    nonisolated func observeBook(_ name: String, then next: ImportStepObserver? = nil) -> ImportStepObserver {
        DispatchQueue.main.async { self.showBook(name) }
        return { step, package in
            DispatchQueue.main.async { self.reach(step) }
            try next?(step, package)
        }
    }
}
