import Foundation
import SwiftSoup

/// Manages cached Markdown content files (content.md) inside .tmb packages.
/// All non-audio book formats are converted to Markdown at import time and stored
/// in the .tmb bundle. The reader loads from this cache instead of re-parsing
/// the original file on every open.
enum MarkdownCacheService {

    /// Current semantic version of the extracted Markdown. Bump this when source
    /// extraction or the stored representation changes. Changes confined to
    /// reading-text/index derivation should bump BookContentIndex.currentVersion
    /// instead, so existing Markdown can be reindexed without source conversion.
    /// Older versions (or nil) regenerate through startup maintenance.
    /// Uses semantic versioning: major.minor.patch
    /// 3.0.5: EPUB page lists, landmarks, and hidden content no longer become
    /// headings or speech; a navigation annotation never enters a heading or
    /// begins a line (which hid that line's words); named anchors add no "[]";
    /// and a heading with a line break stays one heading.
    /// 3.0.6: plain-text books are stored as literal Markdown, so text that
    /// looks like Markdown or HTML is read as written and matches the direct
    /// parser; and DAISY 2.02 inline fragments are read in full, where caches
    /// written earlier kept only a fragment's first child element's text.
    /// 3.0.7: HTML text (HTML, EPUB, DAISY 2.02) is literal Markdown keeping block, row, and cell boundaries and code lines.
    static let currentCacheVersion: String = "3.0.7"

    /// Whether a cache stamped `stored` is older than `current`
    /// (`SemanticVersion.isOutdated(stored:current:)`), and so is extracted
    /// again.
    static func isCacheOutdated(stored: String?, current: String = currentCacheVersion) -> Bool {
        SemanticVersion.isOutdated(stored: stored, current: current)
    }

    /// The comment prefix used to separate chapters in the cached Markdown file.
    /// Each chapter begins with <!-- chapter: Title --> on its own line.
    private static let chapterMarkerPrefix = "<!-- chapter: "
    private static let chapterMarkerSuffix = " -->"

    /// The line that begins a chapter titled `title` in content.md, as
    /// `splitChapters(_:)` finds it. `title` must be one line.
    static func chapterMarker(title: String) -> String {
        "\(chapterMarkerPrefix)\(title)\(chapterMarkerSuffix)"
    }

    /// EPUB extraction already produces reading chapters to resolve heading
    /// coordinates. Keep those results until indexing instead of parsing the
    /// newly written Markdown a second time. Other formats supply Markdown only.
    /// `report` names the chapters the source could not supply; formats that
    /// do not report omissions leave it empty. A document that names its own
    /// title and author, as a textutil format does in the head of its HTML,
    /// gives them in `title` and `author`, read from the one conversion that
    /// made the Markdown; every other format leaves them nil. A textutil
    /// format whose run for the pages failed says so in `pageRunFailed`
    /// (PG16); every other format, and a run that succeeded, leaves it false.
    /// A text file read in a guessed encoding (FMT16) names it in
    /// `guessedEncoding`, by its identifier, for the book to record.
    private struct ExtractedCache {
        var markdown: String
        var chapters: [Chapter]? = nil
        var report = ExtractionReport()
        var title: String? = nil
        var author: String? = nil
        var pageRunFailed = false
        var guessedEncoding: String? = nil
    }

    /// What one successful cache generation produced: the book's reading
    /// content, indexed, and the report of chapters its source could not
    /// supply, kept beside the content so a reader can later say what is
    /// missing from it.
    struct GeneratedCache {
        var content: DocumentContent
        var report: ExtractionReport
        /// The book's saved places, moved from its old text to the one just
        /// written (T06's branch D); nil when nothing needed moving. The copy
        /// of the old text stays until the book's record holds them, so the
        /// caller commits them (`MovedPlaces.discardSnapshot()` after).
        var movedPlaces: MovedPlaces? = nil
        /// The title and author the source document names, nil for a format
        /// that names none (everything but textutil's formats) and for a
        /// document that names none.
        var title: String? = nil
        var author: String? = nil
        /// The version of the page reader that wrote this content.md
        /// (`PageReaderVersions`, PG09): the format's current one, since a
        /// generation always writes pages, noting a failure when the run for
        /// them failed (`PageReaderVersions.stamp(for:pageRunFailed:previous:)`,
        /// PG16); nil for a format without pages.
        var pageReaderVersion: String? = nil
        /// The encoding a text file's bytes were guessed to be in (FMT16),
        /// by its identifier in `TextEncodingCatalog`, for the book to
        /// record (`Book.textEncoding`); nil for a generation that guessed
        /// nothing: any rebuild of an existing book, any other format, and
        /// bytes that named their encoding or that Windows-1252 reads well.
        var guessedEncoding: String? = nil
    }

    // MARK: - Cache Generation

    /// Generate and write the content.md cache file for a book.
    /// Returns true if the cache was successfully created.
    @discardableResult
    static func generateCache(for book: Book) -> Bool {
        generateCacheContent(for: book) != nil
    }

    /// Generate the cache and its reading content together, with the book's
    /// places moved to the new text, treating any failure as no cache.
    /// Chapters the source could not supply are still recorded in the debug
    /// log (see `generateReportedCacheContent`).
    static func generateCacheContent(for book: Book) -> GeneratedCache? {
        do {
            return try generateReportedCacheContent(for: book)
        } catch {
            logGenerationFailure(error, for: book)
            return nil
        }
    }

    /// Generate the cache and its reading content together, with the report
    /// of chapters the source could not supply. Index construction reuses
    /// EPUB's prepared chapters and performs only one Markdown pass for other
    /// formats. No result escapes until the atomic cache write succeeds.
    ///
    /// Every generation path (import, startup maintenance, Redo Text
    /// Extraction, legacy migration, and the reader's regeneration) passes
    /// through here, so each one writes a report with omissions to the debug
    /// log as a single `<FORMAT>_INCOMPLETE_CONTENT: <title>: <message>` line.
    /// Only an import presents it to the reader (see `FileImportService`).
    ///
    /// Each one also fingerprints the source and the content.md it writes
    /// (TODO T07), so the index returned carries what a later load checks
    /// the cache against. The source is fingerprinted before extraction
    /// reads it: one replaced meanwhile then differs from its fingerprint
    /// next time, instead of being recorded as the one this cache came from.
    /// Each one also removes the reading text this Mac kept for the book
    /// (`ReadingTextCache`), which the old content.md gave.
    /// While the book's text is being edited in the user's editor (FR05),
    /// what the user saved in content.md is kept beside it before anything
    /// replaces it, and an edit not taken is never replaced at all
    /// (`BookTextEditSessions.permitTextRebuild(of:writing:)`).
    /// A finished edit is protected too (B12): when the book records an edit
    /// taken (`Book.editedText`) and content.md still holds exactly that
    /// text, no generation replaces it unless `replacingEditedText` is set,
    /// which only Redo Text Extraction does. Otherwise it throws
    /// `EditedTextKept` before reading the source, and logs one
    /// `TEXT_EDIT_KEPT` line.
    /// Each one also copies the old content.md aside with the book's places
    /// and moves them to the new text (T06's branch D, `PlaceSnapshot`),
    /// returned in `movedPlaces` for the caller to commit with the book's
    /// analysis; the copy stays until the record holds them.
    /// Every generation is storage work (TODO S04): a data-directory move
    /// waits for it, so its cache lands where it chose to write it, and one
    /// started during a move waits until the move has published. A book
    /// captured before a move is read and cached in the new data directory.
    /// - Returns: nil for a book with no text cache: an audio book, or one
    ///   without a package.
    /// - Throws: why no cache could be written. A cache written earlier is
    ///   left as it was, so a failed rebuild never empties a readable book.
    ///
    /// With `adoptingDocumentNames`, as an import of a file the user chose
    /// sets it, the title and author the document names (`GeneratedCache`)
    /// are the book's while its content is read, in place of the book's own
    /// (a file name at that point). A regeneration never sets it: the
    /// book's title and author may have been edited by hand.
    ///
    /// With `decidingEncoding`, the read decides the book's encoding, as an
    /// import of a file the user chose and a re-read in another encoding
    /// from Book Information do (encodingchoice): the book is read as its
    /// own row says, whatever its package record holds, and a plain-text,
    /// Markdown, or HTML file of a row that records nothing (an import, or
    /// Automatic), whose bytes name no encoding, is read in the encoding
    /// `TextEncodingGuesser` finds, which the result names for the book to
    /// record (`GeneratedCache.guessedEncoding`, FMT16). Nothing else
    /// guesses or decides: any other read goes by the encoding that stands
    /// between the row and the record (`Book.recordedTextEncodingRecord()`),
    /// and a book that records none is read as it always was, so no rebuild
    /// or migration changes the text of a book already in the library.
    /// Such a read also reads a braille book's file in the braille file
    /// characters its row records (`Book.brailleFileCode`, braillecodes),
    /// which an import sets on the row before the read, and so will a
    /// re-read in other braille file characters; any other read goes by the
    /// code that stands between the row and the record
    /// (`Book.recordedBrailleFileCode()`).
    static func generateReportedCacheContent(
        for book: Book, adoptingDocumentNames: Bool = false, replacingEditedText: Bool = false,
        decidingEncoding: Bool = false
    ) throws -> GeneratedCache? {
        guard !book.format.isAudio, !book.tmbDirectoryName.isEmpty else { return nil }
        let boundary = StorageBoundary.shared
        return try boundary.perform(.textExtraction) { _ in
            try writeCache(
                for: boundary.rebasedToCurrent(book),
                adoptingDocumentNames: adoptingDocumentNames,
                replacingEditedText: replacingEditedText,
                decidingEncoding: decidingEncoding
            )
        }
    }

    /// How a text file in `book` is read: for a read `decidingEncoding`, as
    /// the book's row says, by a guess when it records nothing; otherwise by
    /// the encoding that stands between the row and the package record
    /// (`Book.recordedTextEncodingRecord()`): in the encoding the listener
    /// chose, whatever the bytes say (encodingchoice); in the encoding
    /// guessed, when the bytes name none; or as it always was read, when
    /// nothing is recorded.
    private static func encodingPolicy(of book: Book, decidingEncoding: Bool = false) -> TextFileDecoder.EncodingPolicy {
        guard decidingEncoding else { return book.recordedTextEncodingRecord().policy }
        return book.textEncodingRecord.isEmpty ? .guess : book.textEncodingRecord.policy
    }

    /// The braille file characters a braille book's file is read in, by the
    /// code's id (braillecodes). A read `decidingEncoding` reads the code the
    /// book's row names, as the row says it: an import of a file the user
    /// chose sets it before the read, and so will a re-read in other braille
    /// file characters from Book Information. Any other read takes the code
    /// that stands between the row and the package record, the record's for
    /// a row that lags behind a re-read or lost its own, and, for a BRF or
    /// BRL that records none, Unicode braille patterns when its bytes say so
    /// for certain (`Book.brailleFileCodeForReading()`, review finding 1).
    /// Nil reads North American Braille ASCII; every format but braille
    /// ignores it.
    private static func brailleFileCode(of book: Book, decidingEncoding: Bool) -> String? {
        decidingEncoding ? book.brailleFileCode : book.brailleFileCodeForReading()
    }

    /// The work of `generateReportedCacheContent(for:)` for a book with a
    /// package, whose paths are in the current data directory: extracts the
    /// source, writes content.md, and indexes and fingerprints the result.
    /// - Throws: `EditedTextKept` when `replacingEditedText` is false and
    ///   content.md holds the text of an edit the user made (B12); nothing
    ///   is read or written then.
    private static func writeCache(
        for book: Book, adoptingDocumentNames: Bool, replacingEditedText: Bool, decidingEncoding: Bool
    ) throws -> GeneratedCache {
        // An automatic re-read never replaces the user's finished edit.
        if !replacingEditedText, BookTextEditSessions.holdsTakenEdit(book, access: BookTextEditSessions.shared.access) {
            BookTextEditSessions.logEditedTextKept(of: book)
            throw EditedTextKept(bookTitle: book.title)
        }
        let cachePath = cacheURL(for: book)
        extractionObserver?(book)
        let fileURL = URL(fileURLWithPath: book.filePath)
        let sourceFingerprint = FileFingerprint(of: fileURL, hasher: .md5)

        let extracted: ExtractedCache
        do {
            extracted = try extractCache(
                from: fileURL, format: book.format, brailleTable: book.brailleTable,
                brailleTableVersion: book.brailleTableVersion,
                brailleFileCode: brailleFileCode(of: book, decidingEncoding: decidingEncoding),
                encodingPolicy: encodingPolicy(of: book, decidingEncoding: decidingEncoding), includesPages: true
            )
        } catch EPUBParserError.noReadableChapters(let report) {
            // Nothing can be cached, but which chapters could not be read is
            // still worth recording before the failure is passed on.
            logIncompleteContent(report, of: book)
            throw EPUBParserError.noReadableChapters(report)
        }

        // The names the content is read under: the document's own when this
        // import adopts them and it names them, otherwise the book's.
        let bookTitle = adoptingDocumentNames ? extracted.title ?? book.title : book.title
        let bookAuthor = adoptingDocumentNames ? extracted.author ?? book.author : book.author

        let parsed: DocumentContent
        if let chapters = extracted.chapters, !chapters.isEmpty {
            parsed = DocumentContent(
                title: documentTitle(of: chapters, bookTitle: bookTitle),
                author: bookAuthor,
                chapters: chapters,
                contentIndex: BookContentIndex.build(fromChapters: chapters, format: book.format)
            )
        } else {
            // Preserve the cache reader's empty-document and chapter-marker
            // behavior as well as its title fallback for non-EPUB formats.
            // A text that nests too deeply to read is refused here, with its
            // sentence, before anything is written: no content.md is left behind.
            let markdownContent = try parseMultiChapterMarkdownRefusing(
                extracted.markdown, bookTitle: bookTitle, bookAuthor: bookAuthor
            )
            parsed = DocumentContent(
                title: markdownContent.title, author: markdownContent.author, chapters: markdownContent.chapters,
                contentIndex: markdownContent.contentIndex.replacingFormat(book.format)
            )
        }
        // Write exactly the bytes that are digested, as UTF-8 without a
        // byte-order mark, which is how a String's UTF-8 write stores them.
        let bytes = Data(extracted.markdown.utf8)
        // A book being edited in the user's editor keeps what the user saved
        // there: copied aside before it is replaced, and an edit not taken
        // never replaced (FR05). Asked only now, after extraction, so a save
        // made while the source was read is not missed.
        let edits = BookTextEditSessions.shared
        try edits.permitTextRebuild(of: book, writing: bytes)
        // The book's places are copied aside with the old text, so they can
        // be moved to the new one; a failed write leaves no copy behind.
        let snapshot = keptPlaceSnapshot(of: book, replacing: cachePath, with: bytes)
        do {
            try bytes.write(to: cachePath, options: .atomic)
        } catch {
            snapshot?.discard()
            throw error
        }
        // The reading text this Mac kept for the book was read from the
        // content.md just replaced, so it goes now rather than at the next
        // open, which would find it no longer matches (PERF22).
        ReadingTextCache.shared.remove(bookID: book.id)
        var index = parsed.contentIndex
        index.textCacheFingerprint = fingerprint(source: sourceFingerprint, written: bytes, to: cachePath)
        // The user's next save is checked against the text just written.
        edits.textRebuilt(book, writing: bytes, fingerprint: index.textCacheFingerprint)
        let content = DocumentContent(
            title: parsed.title, author: parsed.author, chapters: parsed.chapters, contentIndex: index
        )
        logIncompleteContent(extracted.report, of: book)
        // The places move from the copied old text to the text just written.
        let movedPlaces = snapshot.flatMap { $0.movePlaces(to: content, at: Date()) }
        // A run for the pages that failed records no pages as read (PG16).
        let pageReaderVersion = PageReaderVersions.stamp(
            for: book.format, pageRunFailed: extracted.pageRunFailed, previous: book.pageReaderVersion
        )
        if extracted.pageRunFailed {
            DiagnosticLog.event(.storage, PageReaderVersions.failedRunLogLine(title: book.title, stamp: pageReaderVersion))
        }
        return GeneratedCache(
            content: content, report: extracted.report, movedPlaces: movedPlaces,
            title: extracted.title, author: extracted.author,
            pageReaderVersion: pageReaderVersion, guessedEncoding: extracted.guessedEncoding
        )
    }

    /// What reading a book's file again gives (`extractedText(for:includesPages:)`):
    /// the Markdown a generation would write, and whether the run that reads
    /// its pages failed.
    struct ExtractedText: Equatable {
        /// The Markdown.
        var markdown: String
        /// Whether pages were asked for and textutil's run for them failed or
        /// was stopped, so the Markdown has none (PG16); false for every
        /// other format, and without pages.
        var pageRunFailed: Bool

        /// The bytes a generation writes for `markdown`: its UTF-8.
        var bytes: Data { Data(markdown.utf8) }
    }

    /// What reading `book`'s file again would write to content.md, exactly:
    /// with page markers, as every generation writes it, or without them
    /// (`includesPages: false`), as it was written before pages (PG09). The
    /// launch's re-read for pages compares each, byte for byte, with the
    /// content.md the book has, to tell a text TextMouth wrote from one
    /// changed by hand, and needs to know when the run for the pages failed
    /// (PG16). It extracts exactly as a generation does, and writes nothing:
    /// no content.md, no snapshot, no record.
    /// - Parameter kindleHalf: For a Kindle book that is a hybrid file, the half read:
    ///   nil for the one a generation reads now (the KF8 half), `.mobi6` for the text an
    ///   older TextMouth stored, which the upgrade of an unstamped book compares with.
    /// - Returns: The text; nil for a book with no text cache (an audio
    ///   book, or one without a package).
    /// - Throws: why the file could not be read, as a generation does.
    static func extractedText(
        for book: Book, includesPages: Bool, kindleHalf: MOBIBook.HybridChoice? = nil
    ) throws -> ExtractedText? {
        guard !book.format.isAudio, !book.tmbDirectoryName.isEmpty else { return nil }
        let boundary = StorageBoundary.shared
        return try boundary.perform(.textExtraction) { _ in
            let current = boundary.rebasedToCurrent(book)
            let extracted = try extractCache(
                from: URL(fileURLWithPath: current.filePath), format: current.format,
                brailleTable: current.brailleTable, brailleTableVersion: current.brailleTableVersion,
                brailleFileCode: current.brailleFileCodeForReading(),
                encodingPolicy: encodingPolicy(of: current), includesPages: includesPages, kindleHalf: kindleHalf
            )
            return ExtractedText(markdown: extracted.markdown, pageRunFailed: extracted.pageRunFailed)
        }
    }

    /// The Markdown of `extractedText(for:includesPages:)`.
    static func extractedMarkdown(for book: Book, includesPages: Bool) throws -> String? {
        try extractedText(for: book, includesPages: includesPages)?.markdown
    }

    /// Copies the book's old content.md aside with its saved places, before
    /// a rebuild replaces it (T06's branch D), so the places can be moved to
    /// the new text. Nil, with nothing copied, unless all of these hold,
    /// checked cheapest first:
    /// - the book holds a place to move;
    /// - the book is not held by an Edit Text session, whose places that
    ///   session moves;
    /// - the old content.md exists and is on this Mac: one only in the cloud
    ///   is never downloaded for this;
    /// - the old content.md differs from `newBytes`: an unchanged text moves
    ///   nothing.
    /// A failure to read or copy the old text is logged once as
    /// `PLACES_NOT_KEPT` and gives nil; the rebuild goes on, and the places
    /// stay at their numbers, as before branch D.
    private static func keptPlaceSnapshot(of book: Book, replacing cacheURL: URL, with newBytes: Data) -> PlaceSnapshot? {
        guard book.holdsPlacesToMove,
              !BookTextEditSessions.shared.isEditing(book.id),
              FileManager.default.fileExists(atPath: cacheURL.path),
              !DatalessFiles.isDataless(cacheURL)
        else { return nil }
        do {
            // Read without asking the cloud to download anything.
            let oldBytes = try DatalessFiles.withoutDownloading { try Data(contentsOf: cacheURL) }
            guard oldBytes != newBytes else { return nil }
            let record = PlaceSnapshot.Record(
                bookID: book.id, title: book.title, author: book.author,
                places: book.relocatablePlaces, takenAt: Date()
            )
            return try PlaceSnapshot.keep(textAt: cacheURL, record: record)
        } catch {
            DiagnosticLog.event(.storage, "PLACES_NOT_KEPT: \(book.title): \(error.localizedDescription)")
            return nil
        }
    }

    /// The fingerprint of a cache just written as `bytes` to `cacheURL` from
    /// a source fingerprinted as `source` before extraction read it. Nil
    /// when either file could not be fingerprinted (the source could not be
    /// read twice, say), so the cache counts as one written before
    /// fingerprints and the next verified load fingerprints it.
    private static func fingerprint(source: FileFingerprint?, written bytes: Data, to cacheURL: URL) -> TextCacheFingerprint? {
        guard let source, let stamp = FileStamp(of: cacheURL) else { return nil }
        return TextCacheFingerprint(
            source: source,
            cache: FileFingerprint(stamp: stamp, digest: FingerprintHasher.md5.digestOfData(bytes))
        )
    }

    /// Generate a cache and advance the stored format version, with the
    /// statistics and fingerprints recorded alongside it, only after the
    /// cache file has been written successfully.
    @discardableResult
    static func generateCacheAndStampVersion(for book: inout Book) -> Bool {
        generateCacheAnalyzeAndStamp(for: &book) != nil
    }

    /// Variant that also computes the persisted navigation index while
    /// already executing on a background queue, treating any failure as no
    /// cache. Cache rebuilds use it: they log omissions but never alert.
    static func generateCacheAnalyzeAndStamp(for book: inout Book) -> BookContentIndex? {
        do {
            return try generateReportedCacheAnalyzeAndStamp(for: &book)?.content.contentIndex
        } catch {
            logGenerationFailure(error, for: book)
            return nil
        }
    }

    /// Import-time variant: write the cache, stamp `book` with the cache
    /// version and its index summary, and return the content with the report
    /// of chapters the source could not supply.
    /// With `adoptingDocumentNames`, `book` also takes the title and author
    /// the document names (`generateReportedCacheContent(for:adoptingDocumentNames:)`),
    /// keeping its own for any the document leaves out.
    /// With `replacingEditedText`, as Redo Text Extraction sets it, the book's
    /// file is read over the text of an edit the user made (B12), and `book`
    /// loses its record of that edit, since content.md is no longer it.
    /// With `decidingEncoding`, as an import of a file the user chose and a
    /// re-read in another encoding set it, the file is read as `book`'s row
    /// says (`generateReportedCacheContent`), and a text file whose bytes
    /// name no encoding, of a row that records nothing, is read in a guessed
    /// one, which `book` records (`Book.textEncoding`, FMT16) so that every
    /// later reading of it uses the same. Without it, the book is read in
    /// the encoding that stands between its row and its package record,
    /// which `book` takes, with who decided it
    /// (`Book.recordedTextEncodingRecord()`): a row that lost its encoding
    /// takes the record's back, and one that lags behind a re-read takes its
    /// decision; the library row takes it with the analysis the caller
    /// commits (`ContentAnalysisSummary`).
    /// A read `decidingEncoding` also reads a braille book's file in the
    /// braille file characters its row records (`Book.brailleFileCode`,
    /// braillecodes), which an import sets on the row before the read, and
    /// so will a re-read in other braille file characters, and `book` keeps
    /// that code. Without it, the file is read in the code that stands
    /// between the row and the record (`Book.recordedBrailleFileCode()`),
    /// which `book` takes, as it takes the encoding.
    /// - Returns: nil for a book with no text cache.
    /// - Throws: why no cache could be written; `book` is then unchanged.
    ///   `EditedTextKept` when content.md holds the user's edit and
    ///   `replacingEditedText` is false.
    static func generateReportedCacheAnalyzeAndStamp(
        for book: inout Book, adoptingDocumentNames: Bool = false, replacingEditedText: Bool = false,
        decidingEncoding: Bool = false
    ) throws -> GeneratedCache? {
        guard let generated = try generateReportedCacheContent(
            for: book, adoptingDocumentNames: adoptingDocumentNames, replacingEditedText: replacingEditedText,
            decidingEncoding: decidingEncoding
        ) else { return nil }
        book.cacheFormatVersion = currentCacheVersion
        // The content.md just written has its format's pages (PG09).
        book.pageReaderVersion = generated.pageReaderVersion
        book.applyContentIndexSummary(generated.content.contentIndex)
        if adoptingDocumentNames {
            if let title = generated.title { book.title = title }
            if let author = generated.author { book.author = author }
        }
        if let guessed = generated.guessedEncoding {
            // The encoding the file was guessed to be in is the book's from now on.
            book.textEncoding = guessed
        } else if !decidingEncoding {
            // The book takes the encoding the file was just read in, with
            // who decided it: its own, the record's for a row that lost its
            // own, or the record's decision for a row that lags behind it.
            book.textEncodingRecord = book.recordedTextEncodingRecord()
        }
        if !decidingEncoding {
            // The book takes the braille file characters its file was just
            // read in (braillecodes): the record's for a row that lags behind
            // a re-read or lost its own, or Unicode braille patterns for a
            // BRF or BRL that records none and whose bytes say so (review
            // finding 1), which its next save records. Another format's row
            // keeps its own.
            book.brailleFileCode = book.brailleFileCodeForReading()
        }
        return generated
    }

    // MARK: - Test Seam

    /// Told, with the book, once a cache generation has chosen where its
    /// content.md goes and before it reads the source, on the thread doing
    /// the work; nil in the app. Tests set it to hold a rebuild there.
    static var extractionObserver: (@Sendable (Book) -> Void)? {
        get {
            extractionObserverLock.lock()
            defer { extractionObserverLock.unlock() }
            return storedExtractionObserver
        }
        set {
            extractionObserverLock.lock()
            storedExtractionObserver = newValue
            extractionObserverLock.unlock()
        }
    }

    /// Guards `storedExtractionObserver`, which any cache generation reads.
    private static let extractionObserverLock = NSLock()
    // Access is confined by extractionObserverLock. `nonisolated(unsafe)`
    // documents that contract to Swift's global-state checker.
    nonisolated(unsafe) private static var storedExtractionObserver: (@Sendable (Book) -> Void)?

    // MARK: - Generation Diagnostics

    /// Print why no cache could be generated for `book`, for the callers that
    /// treat a failure as no cache.
    static func logGenerationFailure(_ error: Error, for book: Book) {
        print("Failed to generate content cache for \(book.title): \(error)")
    }

    /// Record a report that left chapters out as one line in the console and
    /// the debug log, tagged by format ("EPUB_INCOMPLETE_CONTENT"), in the
    /// form every format's damage reports take (see `PackageDamage.log`).
    /// A complete report records nothing.
    private static func logIncompleteContent(_ report: ExtractionReport, of book: Book) {
        guard !report.isComplete else { return }
        PackageDamage.log(
            IncompleteContent(title: book.title, report: report),
            tag: "\(book.format.rawValue.uppercased())_INCOMPLETE_CONTENT"
        )
    }

    /// A book whose extraction left chapters out, described for the log line
    /// that `PackageDamage.log` writes: the book's title, then the report.
    private struct IncompleteContent: LocalizedError {
        var title: String
        var report: ExtractionReport

        /// A line break in the title (or in a file name) becomes a space,
        /// so the entry stays on the one line that readers of the log expect.
        var errorDescription: String? {
            "\(title): \(report.message)".components(separatedBy: .newlines).joined(separator: " ")
        }
    }

    /// Where `book`'s content.md is: in its package, whether or not one has
    /// been written there yet.
    static func cacheURL(for book: Book) -> URL {
        TextMouthPaths.contentMarkdownPath(in: book.tmbDirectory)
    }

    /// Check whether a cached content.md exists for a book.
    static func cacheExists(for book: Book) -> Bool {
        guard !book.tmbDirectoryName.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: cacheURL(for: book).path)
    }

    /// Delete the cached content.md for a book (used before re-extraction).
    static func deleteCache(for book: Book) {
        guard !book.tmbDirectoryName.isEmpty else { return }
        try? FileManager.default.removeItem(at: cacheURL(for: book))
    }

    // MARK: - Cache Loading

    /// Load DocumentContent from the cached content.md file.
    /// Parses chapter markers and runs each chapter through the Markdown parser
    /// to produce plain text + headings for TTS consumption.
    static func loadFromCache(
        for book: Book,
        contentIndex: BookContentIndex? = nil
    ) throws -> DocumentContent {
        let url = cacheURL(for: book)
        let markdown = try cacheText(from: Data(contentsOf: url), at: url)

        return parseMultiChapterMarkdown(
            markdown,
            bookTitle: book.title,
            bookAuthor: book.author,
            contentIndex: contentIndex
        )
    }

    /// The text of a content.md whose bytes, read from `url`, are `bytes`.
    /// They are decoded as UTF-8 exactly as reading the file as a string
    /// decodes it, a leading byte-order mark dropped, so a load that needs
    /// the bytes for their digest reads the file once. Bytes that are not
    /// UTF-8 throw the error that reading the file as a string throws.
    static func cacheText(from bytes: Data, at url: URL) throws -> String {
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url])
        }
        return text
    }

    // MARK: - Format-Specific Extraction

    /// Extract Markdown content from a book file based on its format.
    /// EPUB: converts each chapter's HTML to Markdown with chapter separators.
    /// HTML: converts the HTML to Markdown, stripping duplicate navigation
    /// exactly as the direct parser (HTMLParser) does.
    /// Markdown: uses the file's text as-is.
    /// Plain text: literal Markdown with the plain-text headings as ATX headings.
    /// HTML, Markdown, and plain-text files are decoded by `TextFileDecoder`,
    /// as the direct parsers decode them (see `BookParser.parse(url:format:)`).
    /// RTF, RTFD, Word 97-2003, OpenDocument text, and Word 2003 XML are
    /// read by textutil in a child process (`TextutilDocumentReader`), which
    /// blocks while it runs: like DOCX's regeneration, this runs off the main
    /// thread, in the import queue, startup maintenance, Redo Text
    /// Extraction, and the reader's background load.
    /// A braille book (FMT20) is read through liblouis in the braille helper,
    /// which blocks the same way, with the table the book was imported with
    /// (`brailleTable`, `Book.brailleTable`; the default table for a book
    /// that has none), and a BRF or BRL file in the braille file characters
    /// the book records (`brailleFileCode`, braillecodes; North American
    /// Braille ASCII for a book that records none), so a rebuild of the
    /// cache never changes its text; one of this Mac's tables must still
    /// have the liblouis version the book was read with
    /// (`brailleTableVersion`, review R2), and the code must be one this
    /// TextMouth knows, or the rebuild fails by name and the old content.md
    /// stays.
    /// - Parameter encodingPolicy: What a plain-text, Markdown, or HTML file
    ///   is read as when its bytes name no encoding (FMT16): the book's
    ///   recorded encoding, a guess for the import of a new file, or the
    ///   Windows-1252 fallback. The result names a guessed encoding.
    /// - Parameter includesPages: Whether page markers are written: true for
    ///   every cache the app writes; false reads as cache format 3.0.7 did,
    ///   which PG09 compares against to find text changed by hand.
    private static func extractCache(
        from url: URL, format: BookFormat, brailleTable: String?, brailleTableVersion: String?,
        brailleFileCode: String?, encodingPolicy: TextFileDecoder.EncodingPolicy, includesPages: Bool,
        kindleHalf: MOBIBook.HybridChoice? = nil
    ) throws -> ExtractedCache {
        let markdown: String
        var guessedEncoding: String?
        switch format {
        case .epub:
            return try extractFromEPUB(url: url, includesPages: includesPages)
        case .html:
            let decoded = try TextFileDecoder.readDecodedText(at: url, format: format, policy: encodingPolicy)
            guessedEncoding = decoded.guessedEncodingIdentifier
            markdown = try HTMLToMarkdownConverter.convert(
                decoded.text, stripDuplicateNavigation: true, includesPages: includesPages)
        case .webarchive:
            markdown = try WebArchiveReader.mainPage(of: url).markdown(includesPages: includesPages)
        case .ssml:
            // Read as text, never as SSML for the speech engine (see BookParser).
            markdown = try HTMLToMarkdownConverter.convert(SSMLReader.html(from: url), includesPages: includesPages)
        case .markdown:
            // Already Markdown — use the decoded text as-is
            let decoded = try TextFileDecoder.readDecodedText(at: url, format: format, policy: encodingPolicy)
            guessedEncoding = decoded.guessedEncodingIdentifier
            markdown = decoded.text
        case .txt:
            // The same line analysis as the direct parser, written as literal
            // Markdown, so a cached book reads exactly as
            // PlainTextParser.parse(text:) reads it.
            let decoded = try TextFileDecoder.readDecodedText(at: url, format: format, policy: encodingPolicy)
            guessedEncoding = decoded.guessedEncodingIdentifier
            markdown = PlainTextParser.markdown(text: decoded.text, includesPages: includesPages)
        case .docx:
            markdown = try DOCXParser.extractMarkdown(from: url, includesPages: includesPages)
        case .rtf, .rtfd, .doc, .odt, .wordml:
            // One conversion gives the Markdown and the names the head of
            // textutil's HTML holds.
            let extraction = try TextutilDocumentReader.extract(from: url, bookFormat: format, includesPages: includesPages)
            return ExtractedCache(
                markdown: extraction.markdown, title: extraction.title, author: extraction.author,
                pageRunFailed: extraction.pageRunFailed
            )
        case .braille:
            markdown = try BrailleBookReader.markdown(
                of: url, table: brailleTable ?? BrailleTableCatalog.defaultTableID, recordedVersion: brailleTableVersion,
                fileCode: brailleFileCode, includesPages: includesPages
            )
        case .daisy:
            markdown = try DAISYParser.extractMarkdown(from: url, includesPages: includesPages)
        case .mobi:
            return extractFromKindle(try MOBIParser.prepareBook(
                url: url, includesPages: includesPages, hybrid: kindleHalf ?? MOBIBook.hybridChoice))
        case .kfx:
            return extractFromKindle(try KFXParser.prepareBook(url: url, includesPages: includesPages))
        case .pdf:
            // The report says how each page was read and names any page
            // whose pictures OCR could not read, so an import warns and
            // keeps the original, and every generation logs those pages.
            let pdf = try PDFTextParser.extract(from: url, includesPages: includesPages)
            return ExtractedCache(markdown: pdf.markdown, report: pdf.report)
        case .audio:
            // Audio books don't get text caching
            markdown = ""
        }
        return ExtractedCache(markdown: markdown, guessedEncoding: guessedEncoding)
    }

    /// Use the direct EPUB parser's navigation recovery as the cache source.
    /// Chapter markers preserve boundaries; heading annotations preserve TOC
    /// labels and offsets without inserting any extra text into the book.
    private static func extractFromEPUB(url: URL, includesPages: Bool) throws -> ExtractedCache {
        let book = try EPUBParser.prepareBook(url: url, includesPages: includesPages)
        let markdown = book.chapters.map { prepared in
            "\(chapterMarker(title: prepared.chapter.title))\n\(prepared.markdown)"
        }.joined(separator: "\n\n")
        return ExtractedCache(markdown: markdown, chapters: book.chapters.map(\.chapter), report: book.report)
    }

    /// A Kindle book (FMT42, FMT52) read by `MOBIParser` or `KFXParser`:
    /// chapter markers preserve its chapters, and heading annotations its
    /// deeper entries, without inserting any extra text into the book, as an
    /// EPUB's do. A MOBI 6 book has no print pages, so none are written
    /// whatever `includesPages` says; a KF8 book's page-break elements and a
    /// KFX book's own print page list are written as pages with it.
    private static func extractFromKindle(_ book: MOBIParser.PreparedBook) -> ExtractedCache {
        let markdown = book.chapters.map { prepared in
            "\(chapterMarker(title: prepared.chapter.title))\n\(prepared.markdown)"
        }.joined(separator: "\n\n")
        return ExtractedCache(markdown: markdown, chapters: book.chapters.map(\.chapter))
    }

    // MARK: - Multi-Chapter Markdown Parsing

    /// Parse a cached Markdown file that may contain chapter markers into DocumentContent.
    /// Each chapter section is parsed through the Markdown parser for heading detection
    /// and plain text extraction.
    ///
    /// A chapter whose Markdown nests past the limit (`MarkupRefusal`) is never
    /// dropped and never read for a shorter text: it keeps its raw Markdown as its
    /// text, as the reader shows a file it cannot parse, and the refusal is
    /// logged once (`logKeptRaw`). So Edit Text, a rebuild, the pages' re-read,
    /// and the exports, which all commit for the text this returns, never commit
    /// for fewer words than the book holds. An import does not come here for its
    /// verdict: it refuses the file with the sentence
    /// (`parseMultiChapterMarkdownRefusing`).
    static func parseMultiChapterMarkdown(
        _ markdown: String,
        bookTitle: String,
        bookAuthor: String,
        contentIndex: BookContentIndex? = nil
    ) -> DocumentContent {
        let parsed = parseChapters(
            markdown, bookTitle: bookTitle, bookAuthor: bookAuthor, contentIndex: contentIndex
        )
        logKeptRaw(parsed)
        return parsed.content
    }

    /// `parseMultiChapterMarkdown` for a text that is about to be written to
    /// content.md: a chapter that nests too deeply to be read is not kept raw
    /// but refused, with the sentence the reader is shown, so the write that
    /// follows never happens and no content.md is left behind.
    /// - Throws: `MarkupRefusal.nestedTooDeeply` for the first such chapter.
    static func parseMultiChapterMarkdownRefusing(
        _ markdown: String,
        bookTitle: String,
        bookAuthor: String,
        contentIndex: BookContentIndex? = nil
    ) throws -> DocumentContent {
        let parsed = parseChapters(
            markdown, bookTitle: bookTitle, bookAuthor: bookAuthor, contentIndex: contentIndex
        )
        if let refusal = parsed.firstRefusal { throw refusal }
        return parsed.content
    }

    /// What parsing a cached Markdown file gave: the content (a refused
    /// chapter kept as written) and what was refused.
    private struct ParsedChapters {
        /// The document, with every chapter in it.
        var content: DocumentContent
        /// How many of the chapters were refused and kept as written.
        var refusedCount = 0
        /// The first refusal, which an import throws.
        var firstRefusal: Error?
    }

    /// The shared work of both parsers above: split `markdown` at its chapter
    /// markers (or take it whole), parse each chapter, and keep a refused
    /// chapter's raw text in its place, counting the refusal.
    private static func parseChapters(
        _ markdown: String,
        bookTitle: String,
        bookAuthor: String,
        contentIndex: BookContentIndex?
    ) -> ParsedChapters {
        let sections = splitChapters(markdown)
        var refusedCount = 0
        var firstRefusal: Error?

        /// The chapter `text` parses to, or its raw text when it is refused.
        func chapter(of text: String, titled title: String) -> Chapter {
            do {
                return try MarkdownDocParser.parseChapter(markdown: text, title: title, includeNavigationHeadings: true)
            } catch {
                // The parser refuses only what nests too deeply, but whatever it
                // threw, a chapter is never dropped: it stays as written.
                refusedCount += 1
                firstRefusal = firstRefusal ?? error
                return Chapter(title: title, text: text, headings: [])
            }
        }

        if sections.isEmpty {
            // No chapter markers — treat entire file as single chapter
            let single = chapter(of: markdown, titled: bookTitle)
            let content = DocumentContent(
                title: documentTitle(of: [single], bookTitle: bookTitle),
                author: bookAuthor,
                chapters: [single],
                contentIndex: contentIndex
            )
            return ParsedChapters(content: content, refusedCount: refusedCount, firstRefusal: firstRefusal)
        }

        var chapters: [Chapter] = []
        for section in sections {
            var ch = chapter(of: section.content, titled: section.title)
            // Use the chapter marker title, falling back to what the parser found
            if !section.title.isEmpty {
                ch.title = section.title
            }

            // If this chapter has a title but the Markdown parser found no
            // headings, inject a synthetic level-1 heading at offset 0.
            // This ensures every titled chapter appears in the heading list.
            if ch.headings.isEmpty && !ch.title.isEmpty {
                ch.headings = [Heading(level: 1, text: ch.title, characterOffset: 0)]
            }

            chapters.append(ch)
        }

        let content = DocumentContent(
            title: documentTitle(of: chapters, bookTitle: bookTitle),
            author: bookAuthor,
            chapters: chapters,
            contentIndex: contentIndex
        )
        return ParsedChapters(content: content, refusedCount: refusedCount, firstRefusal: firstRefusal)
    }

    /// The tag of the line that says a parse kept chapters as written.
    static let keptRawLogTag = "MARKDOWN_NESTING_KEPT_RAW"

    /// Record, once for the whole parse, that chapters nested too deeply to be
    /// read were kept as written. The line holds counts only, never the book's
    /// title or words (the log's policy).
    private static func logKeptRaw(_ parsed: ParsedChapters) {
        guard parsed.refusedCount > 0 else { return }
        DiagnosticLog.event(
            .storage,
            "\(keptRawLogTag): \(parsed.refusedCount) of \(parsed.content.chapters.count) chapters nest too deeply to read and are kept as written"
        )
    }

    /// The title of a book whose reading text is `chapters`: its first
    /// chapter's title, or `bookTitle` when that is empty or there is no
    /// chapter. Extraction, parsing content.md, and reading a book's cached
    /// reading text (`ReadingTextCache`) all name a book's content this way.
    static func documentTitle(of chapters: [Chapter], bookTitle: String) -> String {
        guard let first = chapters.first, !first.title.isEmpty else { return bookTitle }
        return first.title
    }

    /// Split cached Markdown into chapter sections based on chapter markers.
    /// Returns empty array if no chapter markers are found.
    ///
    /// A line ends at each line feed alone, as `components(separatedBy: "\n")`
    /// ends it, and a marker is a whole line that begins with the marker's
    /// prefix and ends with its suffix, compared Character by Character. A
    /// section's content is everything between its marker line and the next
    /// one (or the end), trimmed of whitespace and newlines; one with nothing
    /// left is dropped.
    ///
    /// The lines and sections are Substrings of `markdown`, found by looking
    /// for line feeds among its UTF-8 bytes, so each section is copied once,
    /// when it is trimmed, rather than every line being copied into an array
    /// and every section joined again (PERF22: four times as long, and 46 MB
    /// at its peak for a 20 MB book in one chapter, where this split needs
    /// no more than the sections it keeps).
    static func splitChapters(_ markdown: String) -> [(title: String, content: String)] {
        var sections: [(title: String, content: String)] = []
        // The title of the section being read, and where its content starts:
        // nil until the first marker.
        var current: (title: String, contentStart: String.Index)?

        /// Close the section being read at `end`, keeping it if it holds anything.
        func closeSection(at end: String.Index) {
            guard let current else { return }
            let content = markdown[current.contentStart..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                sections.append((title: current.title, content: content))
            }
        }

        let bytes = markdown.utf8
        var lineStart = markdown.startIndex
        while true {
            let lineEnd = bytes[lineStart...].firstIndex(of: UInt8(ascii: "\n")) ?? markdown.endIndex
            // Sliced as scalars, so a line ending in the CR of a CR LF keeps
            // it, as the lines `components(separatedBy: "\n")` made kept it.
            let line = Substring(markdown.unicodeScalars[lineStart..<lineEnd])
            let nextLineStart = lineEnd < markdown.endIndex ? bytes.index(after: lineEnd) : lineEnd
            if line.hasPrefix(chapterMarkerPrefix) && line.hasSuffix(chapterMarkerSuffix) {
                closeSection(at: lineStart)
                current = (title: visibleChapterTitle(markerTitle(of: line)), contentStart: nextLineStart)
            } else if let marker = chapterMarkerFollowedByWords(in: line) {
                // A chapter line with words after it (ST05b): the marker
                // begins the chapter as a chapter line alone does, and the
                // words after it are the chapter's first line.
                closeSection(at: lineStart)
                current = (title: visibleChapterTitle(marker.title), contentStart: marker.restStart)
            }
            guard lineEnd < markdown.endIndex else { break }
            lineStart = nextLineStart
        }
        closeSection(at: markdown.endIndex)
        return sections
    }

    /// The chapter marker a line begins with when more than whitespace follows
    /// it (ST05b), as the title it names and where the words after it start;
    /// nil for any other line (a line that is a marker alone is handled by
    /// `splitChapters` itself, and so is one that ends with the marker's
    /// suffix). The marker ends at the first ` -->` outside a comment inside
    /// its title (caches written before format 3.0.5 could hold a navigation
    /// annotation there). The writers put a chapter marker on a line of its
    /// own (`chapterMarker(title:)`), so nothing TextMouth wrote splits
    /// differently; an Edit Text change can leave words after one. The marker
    /// is found by Characters, as the line is tested for its suffix, so a
    /// combining mark after the `>` keeps the line as it was.
    private static func chapterMarkerFollowedByWords(in line: Substring) -> (title: String, restStart: Substring.Index)? {
        guard line.hasPrefix(chapterMarkerPrefix) else { return nil }
        let titleStart = line.index(line.startIndex, offsetBy: chapterMarkerPrefix.count)
        // The suffix's space may be the prefix's last one (`<!-- chapter: -->`).
        var index = line.index(before: titleStart)
        var depth = 0
        while index < line.endIndex {
            let remainder = line[index...]
            if depth == 0, remainder.hasPrefix(chapterMarkerSuffix) {
                let restStart = line.index(index, offsetBy: chapterMarkerSuffix.count)
                guard line[restStart...].contains(where: { !$0.isWhitespace }) else { return nil }
                return (title: index > titleStart ? String(line[titleStart..<index]) : "", restStart: restStart)
            } else if remainder.hasPrefix("<!--") {
                depth += 1
                index = line.index(index, offsetBy: 4)
            } else if depth > 0, remainder.hasPrefix("-->") {
                depth -= 1
                index = line.index(index, offsetBy: 3)
            } else {
                index = line.index(after: index)
            }
        }
        return nil
    }

    /// The title a chapter marker line names: what stands between the
    /// marker's prefix and suffix, counted in Characters. A line too short
    /// to hold both apart (`<!-- chapter: -->`, whose single space both
    /// share) names no title; reading one there once stopped the app.
    private static func markerTitle(of line: Substring) -> String {
        let titleLength = line.count - chapterMarkerPrefix.count - chapterMarkerSuffix.count
        guard titleLength > 0 else { return "" }
        return String(line.dropFirst(chapterMarkerPrefix.count).prefix(titleLength))
    }

    /// A chapter marker title is the chapter's first heading label. Caches
    /// written before format 3.0.5 could carry a navigation annotation inside
    /// that label; the title is shown to the reader (and becomes the chapter's
    /// heading when it has none), so complete HTML comments are dropped.
    private static func visibleChapterTitle(_ title: String) -> String {
        guard title.contains("<!--") else { return title }
        return title.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
