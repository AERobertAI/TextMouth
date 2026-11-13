import Foundation

/// The words of the imports under way (FR10), kept in one place so the
/// Library window's import overlay, VoiceOver, and the tests say the same
/// thing.
enum ImportProgressWording {
    /// The import overlay's title, which VoiceOver reads first.
    static let title = "Importing Books"
    /// What the overlay's count counts, after the books done of the total,
    /// agreeing with the total: "3 of 10 books processed", "0 of 1 book
    /// processed". A book skipped as a duplicate, or one that failed, is
    /// processed too.
    static let itemNoun = CountWording.Noun(singular: "book processed", plural: "books processed")
    /// What the overlay says as a ZIP import starts, before its archive is
    /// opened.
    static let startingArchive = "Extracting archive..."

    // MARK: - The Overlay's Lines

    /// The books done of the total, as the overlay's count says it:
    /// "3 of 10 books processed", and for one book "0 of 1 book processed"
    /// (REV13; it said "0 of 1 books processed").
    static func count(done: Int, of total: Int) -> String {
        CountWording.part(done, of: total, itemNoun)
    }

    /// How far the extraction of the archive named `archive`, the archive
    /// imported or one found inside it, has got, by its items and by the
    /// bytes they declare: "Extracting “Library Export.zip”: 120 of 300
    /// items, 1.2 GB of 3.4 GB...".
    static func extracting(archive: String, progress: ArchiveExtractionProgress) -> String {
        "Extracting “\(archive)”: \(extracted(progress))..."
    }

    /// How far an extraction has got, by its items and by the bytes they
    /// declare: "120 of 300 items, 1.2 GB of 3.4 GB". An archive declaring
    /// no bytes, folders and empty files alone, is counted by its items
    /// alone.
    static func extracted(_ progress: ArchiveExtractionProgress) -> String {
        let items = "\(progress.entriesDone) of \(progress.entries) items"
        guard progress.bytes > 0 else { return items }
        return "\(items), \(size(progress.bytesDone)) of \(size(progress.bytes))"
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
    /// one book, and the step it is at: "“Moby Dick.epub”, reading its text";
    /// with how far the extraction of an archive holding one audiobook has
    /// got, while it is extracted: "“Harbor Talks.zip”, extracting the
    /// archive: 12 of 30 items, 120 MB of 340 MB" (FR10).
    static func book(_ name: String, step: ImportStep, extraction: ArchiveExtractionProgress? = nil) -> String {
        let line = "“\(name)”, \(self.step(step))"
        guard let extraction else { return line }
        return "\(line): \(extracted(extraction))"
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
        let phrase = lowercasedFirst(step.activity)
        // Converting a book of several tracks counts them, as in
        // "converting its audio: 12 of 176 tracks"; one file needs no count.
        guard case let .convertingImportedAudio(done, total) = step, total > 1 else { return phrase }
        return "\(phrase): \(tracks(done: done, of: total))"
    }

    /// What the tracks of a book being converted at import are counted by
    /// (B06, FMT09).
    static let trackNoun = CountWording.Noun(singular: "track", plural: "tracks")

    /// The tracks converted of a book's total: "12 of 176 tracks", or "0 of
    /// 1 track", as an import's line and the library's conversion say it.
    static func tracks(done: Int, of total: Int) -> String {
        CountWording.part(done, of: total, trackNoun)
    }

    /// `words` with their first letter in lowercase, to follow other words
    /// in a sentence, as the feed downloads' announcements use it too.
    static func lowercasedFirst(_ words: String) -> String {
        words.prefix(1).lowercased() + words.dropFirst()
    }

    /// The time a batch has left, as the overlay says it once a book is
    /// done, and the feed downloads section once a download is: "About 4
    /// minutes left", or "Less than a minute left". The estimate is rounded
    /// first (`TimeLeftEstimate.rounded(_:)`).
    static func timeLeft(_ seconds: TimeInterval) -> String {
        let rounded = TimeLeftEstimate.rounded(seconds)
        guard rounded > 0 else { return "Less than a minute left" }
        return "About \(TimeFormatting.spoken(rounded)) left"
    }

    /// What the overlay says once Cancel is pressed, in place of the time
    /// left: the import stops after the book under way, or, before any book,
    /// at its next step (`cancellingLine`).
    static func cancelling(afterBook: Bool) -> String {
        afterBook ? "Cancelling after this book..." : cancellingLine
    }

    /// What a progress display says once Cancel is pressed while what it
    /// shows stops at its next step: the import overlay before any book,
    /// and the feed downloads section while a download already being added
    /// to the library finishes (`FeedDownloadProgressWording.cancelling`).
    static let cancellingLine = "Cancelling..."

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

    /// What a ZIP batch that brought no new book into the library, and in
    /// which nothing failed, found: "No new books in “Library
    /// Export.zip”: all 24 were already in your library.", "…: both were
    /// already in your library.", "…: its one book was already in your
    /// library.", or, for an archive holding no book TextMouth reads, "No
    /// books were found in “Empty.zip”." `duplicates` counts the books it
    /// found, each skipped as already in the library. The library's alert
    /// says it as the batch ends (`nothingImported(from:result:)`).
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

    // MARK: - A Book Imported With Something To Tell

    /// The title of the library's alert as an import that added its book
    /// ends with something to tell: chapters left out, an RTFD's original
    /// kept, or the entries a playlist skipped. The book is in the library,
    /// so it is no error.
    static let bookImportedTitle = "Book Imported"

    // MARK: - A Batch That Imported Nothing

    /// The title of the library's alert as a ZIP batch that brought no new
    /// book ends: nothing failed, so it is no error.
    static let nothingImportedTitle = "Nothing Imported"

    /// The title of the library's alert as a ZIP batch that added at least
    /// one book ends having left something out: a file failed or the reader
    /// cancelled it. The books that came in are in the library, so it is no
    /// error, and the title says some files are not.
    static let someFilesNotImportedTitle = "Some Files Not Imported"

    /// The title of the library's alert as a ZIP batch ends with something
    /// to tell (`ZipImportResult.failureSummary`), so it is never the
    /// fallback "Error" of an alert with no title:
    /// - no book came into the library (`addedBooks` is 0): "Nothing
    ///   Imported", whether files failed or the batch was cancelled early;
    /// - books came in, but a file failed or the batch was cancelled:
    ///   "Some Files Not Imported";
    /// - books came in, all of them, and only some lack chapters or pages:
    ///   "Book Imported", as for a single book imported with something to
    ///   tell (`bookImportedTitle`).
    /// `addedBooks` counts the books the library took from the batch.
    static func zipAlertTitle(for result: ZipImportResult, addedBooks: Int) -> String {
        guard addedBooks > 0 else { return nothingImportedTitle }
        if !result.failures.isEmpty || result.cancellation != nil { return someFilesNotImportedTitle }
        return bookImportedTitle
    }

    /// How many kinds of file the alert of a batch that found no book names
    /// before counting the rest together as other files.
    static let namedFileKinds = 3

    /// What the library's alert says as a ZIP batch that brought no new
    /// book, and in which nothing failed, ends (`ZipImportResult
    /// .foundNoNewBook`): that its books were already in the library, or,
    /// when it found none, what the archive held instead
    /// (`noBooksFound(in:holding:)`). `subject` is the archive's name.
    ///
    /// Until October 13, 2026 VoiceOver alone was told, and an
    /// announcement made while TextMouth had no window in front is never
    /// spoken, so an archive that took minutes to search could end with
    /// nothing said or shown at all.
    static func nothingImported(from subject: String, result: ZipImportResult) -> String {
        result.skippedDuplicates > 0
            ? noNewBooks(in: subject, alreadyInLibrary: result.skippedDuplicates)
            : noBooksFound(in: subject, holding: result.nonBookFiles)
    }

    /// That the archive `subject` holds no book TextMouth reads, and what
    /// it holds instead, by kind, most files first: "No books were found in
    /// “Radio.zip”. It holds 176 .ogg files, which TextMouth does not
    /// import." Up to `namedFileKinds` kinds are named and the rest are
    /// counted together: "It holds 10 .jpg files, 3 .png files, 2 .gif
    /// files, and 4 other files, which TextMouth does not import." A file
    /// without an extension is "a file without an extension", and an
    /// archive of folders alone "holds no files".
    static func noBooksFound(in subject: String, holding files: NonBookFiles) -> String {
        let opening = noNewBooks(in: subject, alreadyInLibrary: 0)
        guard files.total > 0 else { return "\(opening) It holds no files." }
        return "\(opening) It holds \(kindsHeld(files)), which TextMouth does not import."
    }

    /// That the folder `name`, chosen to import, holds no DAISY book and no
    /// audio tracks to import as one book, and what it holds instead, as
    /// `noBooksFound(in:holding:)` lists an archive's files (FR17): "“Harbor
    /// Notes” holds no DAISY book and no audio tracks to import as one book.
    /// It holds 1 .txt file."
    static func noBookInFolder(named name: String, holding files: NonBookFiles) -> String {
        let opening = "“\(name)” holds no DAISY book and no audio tracks to import as one book."
        guard files.total > 0 else { return "\(opening) It holds no files." }
        return "\(opening) It holds \(kindsHeld(files))."
    }

    /// The kinds of `files`, most first, as a sentence lists them: up to
    /// `namedFileKinds` named, and the rest counted together.
    private static func kindsHeld(_ files: NonBookFiles) -> String {
        let kinds = files.kinds
        var phrases = kinds.prefix(namedFileKinds).map { kind in
            kind.fileExtension.isEmpty
                ? CountWording.phrase(kind.count, singular: "file without an extension", plural: "files without an extension")
                : CountWording.phrase(kind.count, singular: ".\(kind.fileExtension) file", plural: ".\(kind.fileExtension) files")
        }
        let others = kinds.dropFirst(namedFileKinds).reduce(0) { $0 + $1.count }
        if others > 0 {
            phrases.append(CountWording.phrase(others, singular: "other file", plural: "other files"))
        }
        return ListFormatter.localizedString(byJoining: phrases)
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
