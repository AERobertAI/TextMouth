import Foundation

/// The words of the imports under way (FR10), kept in one place so the
/// Library window's import overlay, VoiceOver, and the tests say the same
/// thing.
///
/// Every text is localized (FR34): a whole sentence for each case, a count
/// inside a sentence with its own plural forms, and a total that names what
/// it counts is a phrase of its own ("10 books processed") that the
/// "3 of ..." line carries whole.
enum ImportProgressWording {
    /// The import overlay's title, which VoiceOver reads first.
    static var title: String {
        // Translators: Title of the overlay that shows the imports under way. VoiceOver reads it first.
        InterfaceText.line("importProgress.title", "Importing Books")
    }

    /// What the overlay's count counts, after the books done of the total,
    /// agreeing with the total: "3 of 10 books processed", "0 of 1 book
    /// processed". A book skipped as a duplicate, or one that failed, is
    /// processed too. English only: `ProgressOverlay` (ContentView.swift)
    /// glues it into its own count with `CountWording.part` until the
    /// library's views convert; this type's own line is `count(done:of:)`.
    static let itemNoun = CountWording.Noun(singular: "book processed", plural: "books processed") // l10n: no (inside ProgressOverlay's English count until the library's views convert)

    /// What the overlay says as a ZIP import starts, before its archive is
    /// opened.
    static var startingArchive: String {
        // Translators: Line of the import overlay as a ZIP import starts, before its archive is opened. Ends with an ellipsis written as three full stops, which says the work goes on.
        InterfaceText.line("importProgress.startingArchive", "Extracting archive...")
    }

    // MARK: - The Overlay's Lines

    /// `done` of a total that names what it counts, `total`: "3 of 10 books
    /// processed". The total is a whole phrase with its own plural forms,
    /// so each language agrees the noun with it.
    static func part(_ done: Int, of total: String) -> String {
        // Translators: A count done, then "of", then a phrase that names the total and what is counted, such as "3 of 10 books processed" or "12 of 176 tracks". %lld is the number done and %@ the total's phrase, which has its own plural forms.
        InterfaceText.line("importProgress.part", "\(number: done) of \(total)")
    }

    /// The books done of the total, as the overlay's count says it:
    /// "3 of 10 books processed", and for one book "0 of 1 book processed"
    /// (REV13; it said "0 of 1 books processed").
    static func count(done: Int, of total: Int) -> String {
        // Translators: The total of the import overlay's count: how many books are being imported, whether each is done, skipped as a duplicate, or failed. %lld is the number of books. Follows "3 of".
        part(done, of: InterfaceText.line("importProgress.count", "\(number: total) books processed"))
    }

    /// How far the extraction of the archive named `archive`, the archive
    /// imported or one found inside it, has got, by its items and by the
    /// bytes they declare: "Extracting “Library Export.zip”: 120 of 300
    /// items, 1.2 GB of 3.4 GB...".
    static func extracting(archive: String, progress: ArchiveExtractionProgress) -> String {
        // Translators: Line of the import overlay while an archive is extracted. %1$@ is the archive's name and %2$@ how far the extraction has got, such as "120 of 300 items, 1.2 GB of 3.4 GB". Ends with an ellipsis written as three full stops.
        InterfaceText.line("importProgress.extracting", "Extracting “\(archive)”: \(extracted(progress))...")
    }

    /// How far an extraction has got, by its items and by the bytes they
    /// declare: "120 of 300 items, 1.2 GB of 3.4 GB". An archive declaring
    /// no bytes, folders and empty files alone, is counted by its items
    /// alone.
    static func extracted(_ progress: ArchiveExtractionProgress) -> String {
        // Translators: The total of an archive extraction's count: how many items (files and folders) the archive holds. %lld is the number of items. Follows "120 of".
        let items = part(progress.entriesDone, of: InterfaceText.line("common.countItems", "\(number: progress.entries) items"))
        guard progress.bytes > 0 else { return items }
        // Translators: How many bytes of an archive's declared total have been extracted. %1$@ is the size done and %2$@ the total size, each with its unit, such as "1.2 GB of 3.4 GB".
        let bytes = InterfaceText.line("common.valueOfValue", "\(size(progress.bytesDone)) of \(size(progress.bytes))")
        return SentenceWording.commaJoined([items, bytes])
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
        // Translators: Line of the import overlay for one book of a ZIP batch. %1$lld is the book's place in the batch, %2$lld the number of books, %3$@ the book's file name, and %4$@ what is being done to it, such as "reading its text".
        InterfaceText.line("importProgress.book.numberOfTotal", "Book \(number: number) of \(number: total): “\(name)”, \(self.step(step))")
    }

    /// The one book an import is bringing in, a file or an archive holding
    /// one book, and the step it is at: "“Moby Dick.epub”, reading its text";
    /// with how far the extraction of an archive holding one audiobook has
    /// got, while it is extracted: "“Harbor Talks.zip”, extracting the
    /// archive: 12 of 30 items, 120 MB of 340 MB" (FR10).
    static func book(_ name: String, step: ImportStep, extraction: ArchiveExtractionProgress? = nil) -> String {
        guard let extraction else {
            // Translators: Line of the import overlay for the one book being imported. %1$@ is the book's file name and %2$@ what is being done to it, such as "reading its text".
            return InterfaceText.line("importProgress.book.quote", "“\(name)”, \(self.step(step))")
        }
        // Translators: Line of the import overlay for an archive holding one audiobook, while it is extracted. %1$@ is the archive's file name, %2$@ the step, such as "extracting the archive", and %3$@ how far the extraction has got, such as "12 of 30 items, 120 MB of 340 MB".
        return InterfaceText.line("importProgress.book.colon", "“\(name)”, \(self.step(step)): \(extracted(extraction))")
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
        // Translators: Line of the import overlay: how long the book under way has taken. %@ is the time in words, such as "1 minute, 5 seconds".
        return InterfaceText.line("importProgress.timeOnBook", "\(TimeFormatting.spoken(stepped)) on this book")
    }

    /// `step` as the phrase that follows a book's name: the words a failure
    /// names the step by (`ImportStep.activity`), begun in lowercase, as in
    /// "reading its text" or "copying it into the library".
    static func step(_ step: ImportStep) -> String {
        let phrase = step.phrase
        switch step {
        // Converting a book of several tracks counts them, as in
        // "converting its audio: 12 of 176 tracks"; one file needs no count.
        case let .convertingImportedAudio(done, total) where total > 1:
            return SentenceWording.labelled(phrase, tracks(done: done, of: total))
        // Reading a book of several pictured pages counts them the same way,
        // as in "reading its text: 3 of 12 pages" (FMT34); one picture needs
        // no count.
        case let .readingPages(done, total) where total > 1:
            return SentenceWording.labelled(phrase, pages(done: done, of: total))
        default:
            return phrase
        }
    }

    /// The tracks converted of a book's total: "12 of 176 tracks", or "0 of
    /// 1 track", as an import's line and the library's conversion say it.
    static func tracks(done: Int, of total: Int) -> String {
        // Translators: The total of a count of audio tracks, such as the tracks of a book converted at import. %lld is the number of tracks. Follows "12 of".
        part(done, of: InterfaceText.line("importProgress.tracks", "\(number: total) tracks"))
    }

    /// The pages read of a book's total: "3 of 12 pages", as an import's line
    /// says it.
    static func pages(done: Int, of total: Int) -> String {
        // Translators: The total of a count of pages of a book of pictures read by text recognition at import. %lld is the number of pages. Follows "3 of".
        part(done, of: InterfaceText.line("importProgress.pages", "\(number: total) pages"))
    }

    /// `words` with their first letter in lowercase, to follow other words
    /// in a sentence, as the feed downloads' announcements use it too.
    static func lowercasedFirst(_ words: String) -> String {
        words.lowercasingFirstLetter
    }

    /// The time a batch has left, as the overlay says it once a book is
    /// done, and the feed downloads section once a download is: "About 4
    /// minutes left", or "Less than a minute left". The estimate is rounded
    /// first (`TimeLeftEstimate.rounded(_:)`).
    static func timeLeft(_ seconds: TimeInterval) -> String {
        let rounded = TimeLeftEstimate.rounded(seconds)
        guard rounded > 0 else {
            // Translators: Line of the import overlay and the feed downloads: the time left is under a minute.
            return InterfaceText.line("importProgress.timeLeft.minute", "Less than a minute left")
        }
        // Translators: Line of the import overlay and the feed downloads: the estimated time left. %@ is the time in words, such as "4 minutes".
        return InterfaceText.line("importProgress.timeLeft.about", "About \(TimeFormatting.spoken(rounded)) left")
    }

    /// What the overlay says once Cancel is pressed, in place of the time
    /// left: the import stops after the book under way, or, before any book,
    /// at its next step (`cancellingLine`).
    static func cancelling(afterBook: Bool) -> String {
        afterBook
            // Translators: Line of the import overlay once Cancel is pressed while a book is under way: the import stops after that book. Ends with an ellipsis written as three full stops.
            ? InterfaceText.line("importProgress.cancelling", "Cancelling after this book...")
            : cancellingLine
    }

    /// What VoiceOver calls the import overlay's Cancel button, on the Mac
    /// and the iPhone: the name says what it cancels.
    static var cancelButtonLabel: String {
        // Translators: VoiceOver label of the import overlay's Cancel button. Title case.
        InterfaceText.line("importProgress.cancelButtonLabel", "Cancel Import")
    }

    /// What VoiceOver says the import overlay's Cancel button does
    /// (`LibraryViewModel.cancelImports()`): the import under way stops at
    /// its next step (a ZIP batch before its next book, a conversion by a
    /// helper at once, a book of pictures before its next page, FMT34), the
    /// imports waiting behind it never start, and every book already
    /// imported stays.
    static var cancelButtonHint: String {
        // Translators: VoiceOver hint of the import overlay's Cancel button.
        InterfaceText.line("importProgress.cancelButtonHint", "Stops the import under way and those waiting. Books already imported stay.")
    }

    /// What a progress display says once Cancel is pressed while what it
    /// shows stops at its next step: the import overlay before any book,
    /// and the feed downloads section while a download already being added
    /// to the library finishes (`FeedDownloadProgressWording.cancelling`).
    static var cancellingLine: String {
        // Translators: Line of a progress display once Cancel is pressed: the work stops at its next step. Ends with an ellipsis written as three full stops.
        InterfaceText.line("importProgress.cancellingLine", "Cancelling...")
    }

    /// How many imports wait their turn behind the one the overlay shows:
    /// "1 more import waiting", "2 more imports waiting". Each file chosen
    /// or opened, each archive, each text made with New from Text, and each
    /// recording saved is an import of its own on the import queue.
    static func waiting(_ count: Int) -> String {
        // Translators: Line of the import overlay: how many imports wait their turn behind the one shown. %lld is the number of imports waiting.
        InterfaceText.line("importProgress.waiting", "\(number: count) more imports waiting")
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
        return SentenceWording.labelled(title, SentenceWording.joined(shown.map(sentence)))
    }

    /// `line` ending as a sentence: with a period, unless it already ends
    /// in one, or in the ellipsis of a line still under way.
    private static func sentence(_ line: String) -> String {
        guard !line.hasSuffix(".") else { return line }
        // Translators: Ends a line of a progress display with its full stop, so VoiceOver reads the lines as sentences. %@ is the line.
        return InterfaceText.line("common.valuePeriod", "\(line).")
    }

    // MARK: - What VoiceOver Hears Unasked

    /// Announced as a ZIP batch that has run long passes a quarter of its
    /// books: "Importing “Library Export.zip”: 25 of 100 books processed,
    /// about 4 minutes left." `subject` is the archive's name; the time
    /// left is said when there is an estimate.
    static func quarter(of subject: String, done: Int, total: Int, secondsLeft: TimeInterval?) -> String {
        let progress = count(done: done, of: total)
        guard let secondsLeft else {
            // Translators: VoiceOver announcement as a ZIP batch that has run long passes a quarter of its books, with no estimate of the time left. %1$@ is the archive's name and %2$@ how far it has got, such as "25 of 100 books processed".
            return InterfaceText.line("importProgress.quarter.withoutTimeLeft", "Importing “\(subject)”: \(progress).")
        }
        // Translators: VoiceOver announcement as a ZIP batch that has run long passes a quarter of its books. %1$@ is the archive's name, %2$@ how far it has got, such as "25 of 100 books processed", and %3$@ the time left, such as "about 4 minutes left", starting with a lowercase letter.
        return InterfaceText.line("importProgress.quarter.withTimeLeft", "Importing “\(subject)”: \(progress), \(lowercasedFirst(timeLeft(secondsLeft))).")
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
        // Translators: Part of the announcement that a ZIP batch ended: how many books were imported. %lld is the number of books.
        var counts = [InterfaceText.line("importProgress.finished.imported", "\(number: imported) books imported")]
        if skippedDuplicates > 0 {
            // Translators: Part of the announcement that a ZIP batch ended: how many books were skipped because the library already held them. %lld is the number of books.
            counts.append(InterfaceText.line("importProgress.finished.duplicates", "\(number: skippedDuplicates) skipped as duplicates"))
        }
        if failed > 0 {
            // Translators: Part of the announcement that a ZIP batch ended: how many books failed to import. %lld is the number of books.
            counts.append(InterfaceText.line("common.countFailed", "\(number: failed) failed"))
        }
        // Translators: VoiceOver announcement as a ZIP batch that ran long ends. %1$@ is the archive's name and %2$@ the counts, such as "97 books imported, 2 skipped as duplicates, 1 failed".
        return InterfaceText.line("importProgress.finished.zipBatch", "Finished importing “\(subject)”: \(counts.formatted(.list(type: .and, width: .narrow).locale(InterfaceLanguage.current.locale))).")
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
            // Translators: What the library says as an archive holds no book TextMouth reads. %@ is the archive's name. A sentence about what it holds may follow.
            return InterfaceText.line("importProgress.noNewBooks.found", "No books were found in “\(subject)”.")
        case 1:
            // Translators: What the library says as an archive holds one book, which the library already has. %@ is the archive's name.
            return InterfaceText.line("importProgress.noNewBooks.book", "No new books in “\(subject)”: its one book was already in your library.")
        case 2:
            // Translators: What the library says as an archive holds two books, both of which the library already has. %@ is the archive's name.
            return InterfaceText.line("importProgress.noNewBooks.both", "No new books in “\(subject)”: both were already in your library.")
        default:
            // Translators: What the library says as an archive holds three or more books, all of which the library already has. %1$@ is the archive's name and %2$lld the number of books.
            return InterfaceText.line("importProgress.noNewBooks.other", "No new books in “\(subject)”: all \(number: duplicates) were already in your library.")
        }
    }

    // MARK: - A Book Imported With Something To Tell

    /// The title of the library's alert as an import that added its book
    /// ends with something to tell: chapters left out, an RTFD's original
    /// kept, or the entries a playlist skipped. The book is in the library,
    /// so it is no error.
    static var bookImportedTitle: String {
        // Translators: Title of the library's alert as an import that added its book ends with something to tell, such as chapters left out. The book is in the library, so it is no error. Title case.
        InterfaceText.line("importProgress.bookImportedTitle", "Book Imported")
    }

    // MARK: - A Batch That Imported Nothing

    /// The title of the library's alert as a ZIP batch that brought no new
    /// book ends: nothing failed, so it is no error.
    static var nothingImportedTitle: String {
        // Translators: Title of the library's alert as a ZIP batch that brought no new book ends. Nothing failed, so it is no error. Title case.
        InterfaceText.line("importProgress.nothingImportedTitle", "Nothing Imported")
    }

    /// The title of the library's alert as a ZIP batch that added at least
    /// one book ends having left something out: a file failed or the reader
    /// cancelled it. The books that came in are in the library, so it is no
    /// error, and the title says some files are not.
    static var someFilesNotImportedTitle: String {
        // Translators: Title of the library's alert as a ZIP batch that added at least one book ends having left some files out: a file failed or the batch was cancelled. Title case.
        InterfaceText.line("importProgress.someFilesNotImportedTitle", "Some Files Not Imported")
    }

    /// The title of the library's alert as a ZIP batch that added several
    /// books ends with something to tell about some of them (chapters or
    /// pages left out): the plural of `bookImportedTitle`, since its message
    /// opens "Imported 3 books, but ...".
    static var booksImportedTitle: String {
        // Translators: Title of the library's alert as a ZIP batch that added several books ends with something to tell about some of them, such as chapters left out. Title case.
        InterfaceText.line("importProgress.booksImportedTitle", "Books Imported")
    }

    /// The title of the library's alert as a ZIP batch that found books but
    /// added none ends with something to tell: the library already held
    /// every one of them, so "Nothing Imported" would be no truer than
    /// "Book Imported".
    static var alreadyInLibraryTitle: String {
        // Translators: Title of the library's alert as a ZIP batch that found books but added none, because the library already held every one. Title case.
        InterfaceText.line("importProgress.alreadyInLibraryTitle", "Already in Library")
    }

    /// The title of the library's alert as a ZIP batch ends with something
    /// to tell (`ZipImportResult.failureSummary`), so it is never the
    /// fallback "Error" of an alert with no title, and agrees with the
    /// message under it:
    /// - the batch found no book (`result.books` is empty): "Nothing
    ///   Imported", whether files failed or the batch was cancelled early;
    /// - it found books but the library took none, having them already:
    ///   "Already in Library";
    /// - books came in, but a file failed or the batch was cancelled:
    ///   "Some Files Not Imported";
    /// - books came in, all of them, and only some lack chapters or pages:
    ///   "Book Imported" for one, "Books Imported" for several, as for a
    ///   single book imported with something to tell (`bookImportedTitle`).
    /// `addedBooks` counts the books the library took from the batch.
    static func zipAlertTitle(for result: ZipImportResult, addedBooks: Int) -> String {
        guard addedBooks > 0 else { return result.books.isEmpty ? nothingImportedTitle : alreadyInLibraryTitle }
        if !result.failures.isEmpty || result.cancellation != nil { return someFilesNotImportedTitle }
        return addedBooks > 1 ? booksImportedTitle : bookImportedTitle
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
        guard files.total > 0 else {
            return SentenceWording.joined([opening, holdsNoFiles])
        }
        // Translators: Sentence of the alert about an archive that holds no book: what it holds instead. %@ is the kinds of files it holds with their counts, such as "176 .ogg files" or "10 .jpg files, 3 .png files, and 4 other files".
        let holds = InterfaceText.line("importProgress.noBooksFound", "It holds \(kindsHeld(files)), which TextMouth does not import.")
        return SentenceWording.joined([opening, holds] + adviceSentences(for: files))
    }

    /// The sentence that a place of files holds none.
    private static var holdsNoFiles: String {
        // Translators: Sentence of the alert about an archive or folder that holds no book: it holds no files at all.
        InterfaceText.line("importProgress.holdsNoFiles", "It holds no files.")
    }

    /// The advice for the kinds of `files` that have some
    /// (`RefusedFormatAdvice`, FMT02), as the sentences to follow, or none
    /// when no kind has advice.
    private static func adviceSentences(for files: NonBookFiles) -> [String] {
        RefusedFormatAdvice.advice(for: files).map { [$0] } ?? []
    }

    /// That the folder `name`, chosen to import, holds no DAISY book and no
    /// audio tracks to import as one book, and what it holds instead, as
    /// `noBooksFound(in:holding:)` lists an archive's files (FR17): "“Harbor
    /// Notes” holds no DAISY book and no audio tracks to import as one book.
    /// It holds 1 .txt file."
    static func noBookInFolder(named name: String, holding files: NonBookFiles) -> String {
        // Translators: What the library says as a folder chosen to import holds no DAISY book and no audio tracks. %@ is the folder's name. A sentence about what it holds follows.
        let opening = InterfaceText.line("importProgress.noBookInFolder", "“\(name)” holds no DAISY book and no audio tracks to import as one book.")
        guard files.total > 0 else {
            return SentenceWording.joined([opening, holdsNoFiles])
        }
        // Translators: Sentence of the alert about a folder that holds no book: what it holds instead. %@ is the kinds of files it holds with their counts, such as "1 .txt file" or "10 .jpg files, 3 .png files, and 4 other files".
        let holds = InterfaceText.line("common.itHoldsValue", "It holds \(kindsHeld(files)).")
        return SentenceWording.joined([opening, holds] + adviceSentences(for: files))
    }

    /// The kinds of `files`, most first, as a sentence lists them: up to
    /// `namedFileKinds` named, and the rest counted together.
    private static func kindsHeld(_ files: NonBookFiles) -> String {
        let kinds = files.kinds
        var phrases = kinds.prefix(namedFileKinds).map { kind in
            kind.fileExtension.isEmpty
                // Translators: Part of a list of the kinds of file a place holds: how many files have no extension. %lld is the number of files.
                ? InterfaceText.line("importProgress.kindsHeld.extension", "\(number: kind.count) files without an extension")
                // Translators: Part of a list of the kinds of file a place holds: how many files have one extension. %1$lld is the number of files and %2$@ the extension without its dot, such as "ogg". The dot before the extension is part of the text.
                : InterfaceText.line("importProgress.kindsHeld.files", "\(number: kind.count) .\(kind.fileExtension) files")
        }
        let others = kinds.dropFirst(namedFileKinds).reduce(0) { $0 + $1.count }
        if others > 0 {
            // Translators: Last part of a list of the kinds of file a place holds: how many files of the kinds not named. %lld is the number of files.
            phrases.append(InterfaceText.line("importProgress.kindsHeld.other", "\(number: others) other files"))
        }
        return CountWording.list(phrases)
    }

    /// Announced as the import of one book that ran long ends: "Finished
    /// importing “Moby Dick.epub”."
    static func finished(book subject: String) -> String {
        // Translators: VoiceOver announcement as the import of one book that ran long ends. %@ is the book's file name.
        InterfaceText.line("importProgress.finished.oneBook", "Finished importing “\(subject)”.")
    }

    /// Announced as an import that ran long fails; the library's alert says
    /// why, in the same opening words (`ImportFailure.errorDescription`).
    static func failed(_ subject: String) -> String {
        // Translators: VoiceOver announcement as an import that ran long fails. %@ is the file's name. The library's alert says why.
        InterfaceText.line("importProgress.failed", "Could not import “\(subject)”.")
    }

    // MARK: - What VoiceOver Hears on Request

    /// What Speak Import Progress says with no import under way; with one,
    /// it says what VoiceOver reads for the overlay.
    static var noImportUnderWay: String {
        // Translators: What the Speak Import Progress command says when no import is under way.
        InterfaceText.line("importProgress.noImportUnderWay", "No import is under way.")
    }
}
