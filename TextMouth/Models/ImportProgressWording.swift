import Foundation

/// The words of the imports under way (FR10), kept in one place so the
/// Library window's import overlay, VoiceOver, and the tests say the same
/// thing.
enum ImportProgressWording {
    /// The import overlay's title, which VoiceOver reads first.
    static let title = "Importing Books"
    /// What the overlay's count counts, after the books done of the total:
    /// "3 of 10 books processed". A book skipped as a duplicate, or one
    /// that failed, is processed too.
    static let itemNoun = "books processed"
    /// What the overlay says as a ZIP import starts, before its archive is
    /// opened.
    static let startingArchive = "Extracting archive..."

    // MARK: - The Overlay's Lines

    /// The books done of the total, as the overlay's count says it:
    /// "3 of 10 books processed".
    static func count(done: Int, of total: Int) -> String {
        CountWording.progress(done, of: total, itemNoun)
    }

    /// How far the extraction of the archive named `archive`, the archive
    /// imported or one found inside it, has got, by its items and by the
    /// bytes they declare: "Extracting “Library Export.zip”: 120 of 300
    /// items, 1.2 GB of 3.4 GB...". An archive declaring no bytes, folders
    /// and empty files alone, is counted by its items alone.
    static func extracting(archive: String, progress: ArchiveExtractionProgress) -> String {
        let items = "\(progress.entriesDone) of \(progress.entries) items"
        guard progress.bytes > 0 else { return "Extracting “\(archive)”: \(items)..." }
        return "Extracting “\(archive)”: \(items), \(size(progress.bytesDone)) of \(size(progress.bytes))..."
    }

    /// `bytes` as a size, as the archive messages write sizes, in decimal
    /// units as Finder does (`ArchiveFigures.size`), but in figures from the
    /// start: "0 bytes" rather than "Zero KB", since the size counts up
    /// from nothing. VoiceOver reads "1.2 GB" as gigabytes.
    static func size(_ bytes: Int64) -> String {
        // A formatter of its own each time: formatting is rare enough, at
        // most a few hundred times an archive, and nothing is shared.
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }

    /// The book a ZIP batch is importing and the step it is at: "Book 3 of
    /// 100: “Moby Dick.epub”, reading its text". `name` is the book's file,
    /// or a DAISY book's folder, as the archive names it.
    static func book(_ name: String, number: Int, of total: Int, step: ImportStep) -> String {
        "Book \(number) of \(total): “\(name)”, \(self.step(step))"
    }

    /// The one book an import is bringing in, a file or an archive holding
    /// one book, and the step it is at: "“Moby Dick.epub”, reading its text".
    static func book(_ name: String, step: ImportStep) -> String {
        "“\(name)”, \(self.step(step))"
    }

    /// How long a book must have been under way before the overlay says how
    /// long: most books take a second or two, and the time on them would
    /// only flash by (FR10).
    static let timeOnBookShownAfter: TimeInterval = 10
    /// The step the time on a book moves in, so what VoiceOver reads and a
    /// braille display shows changes every few seconds rather than every
    /// second, as the reader's cloud download counts its wait.
    static let timeOnBookStep: TimeInterval = 5

    /// How long the book under way has taken, once that is long enough to
    /// say: "1 minute, 5 seconds on this book", counted down to whole
    /// `timeOnBookStep`s; nil before `timeOnBookShownAfter`. A book that
    /// never leaves its step shows here as a time that keeps growing.
    static func timeOnBook(_ seconds: TimeInterval) -> String? {
        guard seconds.isFinite, seconds >= timeOnBookShownAfter else { return nil }
        let stepped = (seconds / timeOnBookStep).rounded(.down) * timeOnBookStep
        return "\(TimeFormatting.spoken(stepped)) on this book"
    }

    /// `step` as the phrase that follows a book's name: the words a failure
    /// names the step by (`ImportStep.activity`), begun in lowercase, as in
    /// "reading its text" or "copying it into the library".
    static func step(_ step: ImportStep) -> String {
        lowercasedFirst(step.activity)
    }

    /// `words` with their first letter in lowercase, to follow other words
    /// in a sentence, as the feed downloads' announcements use it too.
    static func lowercasedFirst(_ words: String) -> String {
        words.prefix(1).lowercased() + words.dropFirst()
    }

    /// The time a batch has left, as the overlay says it once a book is
    /// done: "About 4 minutes left", or "Less than a minute left". The
    /// estimate is rounded first (`ImportTimeEstimate.rounded(_:)`).
    static func timeLeft(_ seconds: TimeInterval) -> String {
        let rounded = ImportTimeEstimate.rounded(seconds)
        guard rounded > 0 else { return "Less than a minute left" }
        return "About \(TimeFormatting.spoken(rounded)) left"
    }

    /// What the overlay says once Cancel is pressed, in place of the time
    /// left: the import stops after the book under way, or, before any book,
    /// at its next step.
    static func cancelling(afterBook: Bool) -> String {
        afterBook ? "Cancelling after this book..." : "Cancelling..."
    }

    /// How many imports wait their turn behind the one the overlay shows:
    /// "1 more import waiting", "2 more imports waiting". Each file chosen
    /// or opened, each archive, each text made with New from Text, and each
    /// recording saved is an import of its own on the import queue.
    static func waiting(_ count: Int) -> String {
        CountWording.phrase(count, singular: "more import waiting", plural: "more imports waiting")
    }

    // MARK: - What VoiceOver Reads

    /// What VoiceOver reads for the overlay: the title, then each line it
    /// shows, as sentences: "Importing Books: 2 of 100 books processed. Book
    /// 3 of 100: “Moby Dick.epub”, reading its text. 15 seconds on this
    /// book. About 4 minutes left." Empty lines are left out, and with none
    /// the title is read alone.
    static func spokenStatus(_ lines: [String]) -> String {
        spokenStatus(title: title, lines: lines)
    }

    /// What VoiceOver reads for a progress display titled `title` that
    /// shows `lines`: the title, then each line as a sentence, empty lines
    /// left out, or the title alone with none. The import overlay and the
    /// feed downloads section (`FeedDownloadProgressWording`) both read
    /// their lines this way.
    static func spokenStatus(title: String, lines: [String]) -> String {
        let shown = lines.filter { !$0.isEmpty }
        guard !shown.isEmpty else { return title }
        return "\(title): " + shown.map(sentence).joined(separator: " ")
    }

    /// `line` ending as a sentence: with a period, unless it already ends
    /// in one, or in the ellipsis of a line still under way.
    private static func sentence(_ line: String) -> String {
        line.hasSuffix(".") ? line : line + "."
    }

    // MARK: - What VoiceOver Hears Unasked

    /// Announced as a ZIP batch that has run long passes a quarter of its
    /// books: "Importing “Library Export.zip”: 25 of 100 books processed,
    /// about 4 minutes left." `subject` is the archive's name; the time
    /// left is said when there is an estimate.
    static func quarter(of subject: String, done: Int, total: Int, secondsLeft: TimeInterval?) -> String {
        let timeLeft = secondsLeft.map { ", " + lowercasedFirst(self.timeLeft($0)) } ?? ""
        return "Importing “\(subject)”: \(count(done: done, of: total))\(timeLeft)."
    }

    /// Announced as a ZIP batch that ran long ends: "Finished importing
    /// “Library Export.zip”: 97 books imported, 2 skipped as duplicates,
    /// 1 failed." Only the counts that are not 0 follow the books imported.
    /// A batch that imported no book and in which nothing failed says what
    /// it found instead (`noNewBooks(in:alreadyInLibrary:)`). The library's
    /// alert names each file that failed.
    static func finished(batch subject: String, imported: Int, skippedDuplicates: Int, failed: Int) -> String {
        guard imported + failed > 0 else {
            return noNewBooks(in: subject, alreadyInLibrary: skippedDuplicates)
        }
        var counts = ["\(CountWording.books(imported)) imported"]
        if skippedDuplicates > 0 {
            counts.append(CountWording.phrase(skippedDuplicates, singular: "skipped as a duplicate", plural: "skipped as duplicates"))
        }
        if failed > 0 {
            counts.append("\(failed) failed")
        }
        return "Finished importing “\(subject)”: \(counts.joined(separator: ", "))."
    }

    /// Announced as a ZIP batch that brought no new book into the library,
    /// and in which nothing failed, ends, however short it was, since no
    /// alert and no question follow it to say so: "No new books in “Library
    /// Export.zip”: all 24 were already in your library.", "…: both were
    /// already in your library.", "…: its one book was already in your
    /// library.", or, for an archive holding no book TextMouth reads, "No
    /// books were found in “Empty.zip”." `duplicates` counts the books it
    /// found, each skipped as already in the library.
    static func noNewBooks(in subject: String, alreadyInLibrary duplicates: Int) -> String {
        switch duplicates {
        case ...0:
            return "No books were found in “\(subject)”."
        case 1:
            return "No new books in “\(subject)”: its one book was already in your library."
        case 2:
            return "No new books in “\(subject)”: both were already in your library."
        default:
            return "No new books in “\(subject)”: all \(duplicates) were already in your library."
        }
    }

    /// Announced as the import of one book that ran long ends: "Finished
    /// importing “Moby Dick.epub”."
    static func finished(book subject: String) -> String {
        "Finished importing “\(subject)”."
    }

    /// Announced as an import that ran long fails; the library's alert says
    /// why, in the same opening words (`ImportFailure.errorDescription`).
    static func failed(_ subject: String) -> String {
        "Could not import “\(subject)”."
    }

    // MARK: - What VoiceOver Hears on Request

    /// What Speak Import Progress says with no import under way; with one,
    /// it says what VoiceOver reads for the overlay.
    static let noImportUnderWay = "No import is under way."
}

// MARK: - The Time Left

/// How long the books of a ZIP batch not yet done should take, estimated
/// from the books done so far, and how the overlay rounds it (FR10).
enum ImportTimeEstimate {
    /// The seconds the `remaining` books should take at the average of the
    /// `timedBooks` books imported or failed so far, which took
    /// `timedSeconds` in all; nil before any book was timed, and with no
    /// book left.
    ///
    /// A book skipped as a duplicate is not timed: it takes next to no time,
    /// and counting it would shorten the average of the books that do take
    /// time, so an archive whose first books are already in the library
    /// would promise far too little. The books left are all counted at the
    /// average, duplicates among them or not, so the estimate errs long
    /// rather than short.
    static func secondsLeft(timedSeconds: TimeInterval, timedBooks: Int, remaining: Int) -> TimeInterval? {
        guard timedBooks > 0, remaining > 0, timedSeconds.isFinite else { return nil }
        return max(0, timedSeconds) / Double(timedBooks) * Double(remaining)
    }

    /// `seconds` as the overlay says it: 0 under a minute, which it says as
    /// "less than a minute"; otherwise rounded to the nearest whole minute
    /// under 10 minutes, the nearest 5 minutes under an hour, and the
    /// nearest 15 minutes from an hour on. An estimate recomputed as each
    /// book finishes so changes its words only when it moves by a step that
    /// matters at its size, and does not flicker between neighbors.
    static func rounded(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite, seconds >= 60 else { return 0 }
        let minutes = seconds / 60
        let step: Double = minutes < 10 ? 1 : (minutes < 60 ? 5 : 15)
        return (minutes / step).rounded() * step * 60
    }
}
