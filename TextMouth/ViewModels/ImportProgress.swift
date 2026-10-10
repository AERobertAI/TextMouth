import SwiftUI

/// What the import overlay shows at one moment (FR10): the bar's books done
/// of the total, which is 0 of 0 while the bar only spins, the line beneath
/// it, which says what the import is doing, and the lines under that: how
/// long the book under way has taken, once that is long enough to say, the
/// time a ZIP batch has left, or that the imports are cancelling, and how
/// many imports wait behind the one shown.
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
        /// How far the extraction of an archive holding one audiobook has
        /// got, which its line says while that is its step (FR10).
        var extraction: ArchiveExtractionProgress?

        /// The extraction its line says: only while it is extracted.
        var extractionShown: ArchiveExtractionProgress? {
            step == .extractingArchive ? extraction : nil
        }
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
    /// The imports queued behind the one shown, waiting their turn on the
    /// import queue, which the overlay counts (FR10). They outlast the
    /// import shown, so a new import's state keeps them
    /// (`ImportProgress.begin(_:subject:at:)`).
    var waitingImports = 0

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
    /// with how far an archive holding one audiobook has been extracted
    /// while it is, or, with none, the notice.
    var message: String {
        guard let book else { return notice }
        guard let number = book.number else {
            return ImportProgressWording.book(book.name, step: book.step, extraction: book.extractionShown)
        }
        return ImportProgressWording.book(book.name, number: number, of: total, step: book.step)
    }

    /// Takes a ZIP batch's `progress`, reported at `date` (TODO I05, FR10).
    /// While the archive is extracted the bar only spins and the line counts
    /// the archive's items and bytes, so the overlay moves before the first
    /// book; once
    /// books import, the bar counts the books done, and the line names the
    /// book under way and the step it is at, which it keeps until the next
    /// book begins. Each book is timed from its first report to its last,
    /// and as each finishes the time left is estimated again; the
    /// extraction is never timed.
    mutating func receive(_ progress: ZipImportProgress, at date: Date) {
        switch progress {
        case let .extracting(archive, extraction):
            current = 0
            total = 0
            book = nil
            notice = ImportProgressWording.extracting(archive: archive, progress: extraction)
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
            // The book done is the one under way, timed from its start,
            // unless it was skipped as a duplicate, which takes next to no
            // time (`ImportTimeEstimate`).
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

    /// The archive holding the one book under way, an audiobook's tracks,
    /// has been extracted as far as `extraction` says (FR10).
    mutating func receive(extraction: ArchiveExtractionProgress) {
        book?.extraction = extraction
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
    /// books are left, and how many imports wait behind this one. Once
    /// Cancel is pressed the waiting imports are not counted: the ZIP
    /// archives among them never start.
    func details(at now: Date) -> [String] {
        var details: [String] = []
        if let book, !book.isDone,
           let timeOnBook = ImportProgressWording.timeOnBook(now.timeIntervalSince(book.startedAt)) {
            details.append(timeOnBook)
        }
        if isCancelling {
            details.append(ImportProgressWording.cancelling(afterBook: book != nil))
            return details
        }
        if let secondsLeft {
            details.append(ImportProgressWording.timeLeft(secondsLeft))
        }
        if waitingImports > 0 {
            details.append(ImportProgressWording.waiting(waitingImports))
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
///
/// VoiceOver hears an import that runs long without having to find the
/// overlay (FR10): each quarter of a ZIP batch's books, once, and how the
/// import ended; and, at once, that Cancel was pressed. An import that ends
/// within `announcedAfter` stays quiet, as before: its questions and alerts
/// speak for it. A ZIP batch that found no new book, and in which nothing
/// failed, has neither, so what it found is said however short it was.
@MainActor
final class ImportProgress: ObservableObject {
    /// How an import shown in the overlay ended, which its announcement says.
    enum Ending {
        /// A ZIP batch of books returned `result`.
        case batch(ZipImportResult)
        /// One book was imported: a file, or an archive holding one book.
        case book
        /// The import failed, and the library's alert says why.
        case failure
    }

    /// How long an import must have run before VoiceOver hears its quarters
    /// and its end unasked: one that ends sooner ends before the user could
    /// wonder whether it is stuck.
    static let announcedAfter: TimeInterval = 10

    /// What the overlay shows now.
    @Published private(set) var state = ImportProgressState()
    /// Tells the time each report arrives, which times the books: the
    /// system's clock in the app, a test's own clock in a test.
    private let now: @MainActor () -> Date
    /// What the import shown is called in announcements: its archive's name,
    /// or its one book's; nil for an import that names neither.
    private var subject: String?
    /// When the import shown began running; nil while none is shown.
    private var startedAt: Date?
    /// The highest quarter of the batch's books reached so far, 1 for the
    /// first: each is announced once, or passes silently while the import
    /// is still short.
    private var quarterReached = 0

    /// Progress timed by `now`: the system's clock unless a test passes its
    /// own.
    init(now: @escaping @MainActor () -> Date = { Date() }) {
        self.now = now
    }

    /// Shows `message` alone, under a bar that only spins: an import
    /// starting, or waiting for a data-directory move (TODO S04).
    func show(_ message: String) {
        begin(ImportProgressState(message: message), subject: nil, at: now())
    }

    /// Shows the ZIP archive named `name` beginning to import, before it is
    /// known to hold one book or a batch of them (FR10).
    func showArchive(_ name: String) {
        begin(ImportProgressState(message: ImportProgressWording.startingArchive), subject: name, at: now())
    }

    /// Shows the import of one book, named `name`, beginning now: a file,
    /// or an archive holding one book (FR10).
    func showBook(_ name: String) {
        let date = now()
        begin(ImportProgressState(book: name, at: date), subject: name, at: date)
    }

    /// Shows `newState`, the start of an import known as `subject`, begun
    /// at `date`, with none of its quarters reached, and the imports still
    /// waiting behind it.
    private func begin(_ newState: ImportProgressState, subject: String?, at date: Date) {
        var started = newState
        started.waitingImports = state.waitingImports
        state = started
        self.subject = subject
        startedAt = date
        quarterReached = 0
    }

    /// Takes the import queue's count of the imports queued or running
    /// (`SerialImportQueue.onActivityChanged`): those behind the one shown
    /// are waiting, and the overlay counts them (FR10). Publishes only a
    /// change, since the overlay redraws for each.
    func noteImportsQueued(_ count: Int) {
        let waiting = max(0, count - 1)
        guard state.waitingImports != waiting else { return }
        state.waitingImports = waiting
    }

    /// Shows that the import of one book began `step`.
    func reach(_ step: ImportStep) {
        state.reach(step)
    }

    /// Takes a ZIP batch's `progress`, timed as it arrives: how far its
    /// extraction has got, the book under way and its step, and the books
    /// done, with the time left (TODO I05, FR10). A book done that takes
    /// the batch past a quarter of its books is announced.
    func receive(_ progress: ZipImportProgress) {
        let date = now()
        state.receive(progress, at: date)
        if case let .importing(done, total, _) = progress {
            announceQuarter(reachedBy: done, of: total, at: date)
        }
    }

    /// Announces the quarter of its `total` books a batch reached as its
    /// `done`th book finished, when it reached a new one: the highest, once,
    /// with the books processed and the time left. A quarter reached before
    /// the import has run long passes silently, as do those after Cancel;
    /// the last quarter is the batch's end, announced on its own.
    private func announceQuarter(reachedBy done: Int, of total: Int, at date: Date) {
        guard total > 0 else { return }
        let quarter = done * 4 / total
        guard quarter > quarterReached else { return }
        quarterReached = quarter
        guard quarter < 4, !state.isCancelling, hasRunLong(at: date), let subject else { return }
        VoiceOverAnnouncer.announce(
            ImportProgressWording.quarter(of: subject, done: done, total: total, secondsLeft: state.secondsLeft),
            priority: .medium
        )
    }

    /// Notes that Cancel was pressed while this import runs, which the
    /// overlay then says in place of the time left, and VoiceOver hears at
    /// once, in the overlay's own words, so the press is heard to count
    /// (TODO I05, FR10). A second press says nothing more.
    func cancel() {
        guard !state.isCancelling else { return }
        state.cancel()
        VoiceOverAnnouncer.announce(ImportProgressWording.cancelling(afterBook: state.book != nil))
    }

    /// Ends the import shown, which ended as `ending`: VoiceOver hears how,
    /// when the import ran long and Cancel was not pressed (a cancelled
    /// batch's alert says where it stopped), and the overlay shows nothing
    /// more.
    func end(_ ending: Ending) {
        if let words = endAnnouncement(for: ending) {
            VoiceOverAnnouncer.announce(words)
        }
        clear()
    }

    /// What VoiceOver hears as the import shown ends as `ending`, or nil
    /// when it hears nothing: the import was short, cancelled, or named
    /// neither an archive nor a book. A ZIP batch that found no new book,
    /// and in which nothing failed, is said however short it was: no alert
    /// and no question follow it, so nothing else would say what it found
    /// (`ZipImportResult.foundNoNewBook`).
    private func endAnnouncement(for ending: Ending) -> String? {
        guard let subject, !state.isCancelling else { return nil }
        let ranLong = hasRunLong(at: now())
        switch ending {
        case .batch(let result):
            guard result.cancellation == nil, ranLong || result.foundNoNewBook else { return nil }
            return ImportProgressWording.finished(
                batch: subject,
                imported: result.books.count,
                skippedDuplicates: result.skippedDuplicates,
                failed: result.failures.count
            )
        case .book:
            return ranLong ? ImportProgressWording.finished(book: subject) : nil
        case .failure:
            return ranLong ? ImportProgressWording.failed(subject) : nil
        }
    }

    /// What Speak Import Progress says now: what VoiceOver reads for the
    /// overlay, its every line, while an import shows or `isImporting`
    /// says one is queued or running; otherwise that none is under way.
    func spokenStatus(whileImporting isImporting: Bool) -> String {
        guard isImporting || state != ImportProgressState() else {
            return ImportProgressWording.noImportUnderWay
        }
        return state.spokenStatus(at: now())
    }

    /// Whether the import shown has run for `announcedAfter` by `date`.
    private func hasRunLong(at date: Date) -> Bool {
        guard let startedAt else { return false }
        return date.timeIntervalSince(startedAt) >= Self.announcedAfter
    }

    /// Shows nothing more of the import shown: it ended, or none is under
    /// way. The imports waiting behind it are still counted until the queue
    /// says how many are left (`noteImportsQueued(_:)`).
    func clear() {
        var cleared = ImportProgressState()
        cleared.waitingImports = state.waitingImports
        state = cleared
        subject = nil
        startedAt = nil
        quarterReached = 0
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

    /// For an archive holding one audiobook, imported on the import queue:
    /// the extractor's progress callback, which shows on the main queue how
    /// far the archive has been extracted, its items and bytes, on the
    /// book's line (FR10). The extractor tells it at most about two hundred
    /// times an archive (`ArchiveExtractor`).
    nonisolated func observeExtraction() -> (ArchiveExtractionProgress) -> Void {
        { extraction in
            DispatchQueue.main.async { self.receive(extraction: extraction) }
        }
    }

    /// Shows how far the archive holding the one book under way has been
    /// extracted.
    func receive(extraction: ArchiveExtractionProgress) {
        state.receive(extraction: extraction)
    }
}
