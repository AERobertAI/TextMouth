import Foundation

/// The record of a book kept inside its .tmb package: its metadata, reading
/// state, bookmarks, and content index.
///
/// Two files hold it (PERF15). bookInfo.json holds everything but the
/// content index, about a kilobyte, so the save the reader makes every 30
/// seconds of playback writes only that. The content index, which can run
/// to hundreds of kilobytes and changes only when the book is analyzed or
/// imported, has a file of its own beside it, contentIndex.json
/// (`TextMouthPaths.contentIndexPath(in:)`).
///
/// Older versions of TextMouth kept the index inside bookInfo.json. Such a
/// record still loads with its index, and the next save of the book moves
/// the index into contentIndex.json. An index found inside bookInfo.json
/// wins over contentIndex.json: TextMouth no longer writes one there, so
/// either an older version wrote it after the file was written, or a save
/// that would have replaced it was interrupted, and either way it is the
/// index the record's analysis fields describe. An older version reading a
/// record written since finds no index in it and builds the book's index
/// once, as for any book without one, keeping it inside bookInfo.json, from
/// where the next save here moves it out again.
struct BookInfo: Codable {
    var metadata: BookMetadata
    var state: BookState
    var bookmarks: [Bookmark]
    /// Versioned chapter/heading/statistics index. Kept per package rather than
    /// in library.json so startup does not decode every heading in the library.
    /// On disk it lives in contentIndex.json; bookInfo.json holds it only as
    /// an older version of TextMouth wrote it (see the type's notes).
    var contentIndex: BookContentIndex?

    /// The keys of bookInfo.json. The content index is only ever read under
    /// its key, from a record an older version wrote; it is never written.
    private enum CodingKeys: String, CodingKey {
        case metadata
        case state
        case bookmarks
        case contentIndex
    }

    init(
        metadata: BookMetadata = BookMetadata(),
        state: BookState = BookState(),
        bookmarks: [Bookmark] = [],
        contentIndex: BookContentIndex? = nil
    ) {
        self.metadata = metadata
        self.state = state
        self.bookmarks = bookmarks
        self.contentIndex = contentIndex
    }

    /// Decodes a package's bookInfo.json. `BookState` repairs what it can
    /// check on its own; the per-book speed also depends on the format, so
    /// its range is applied here, once the metadata is known.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try container.decode(BookMetadata.self, forKey: .metadata)
        state = try container.decode(BookState.self, forKey: .state)
        bookmarks = try container.decode([Bookmark].self, forKey: .bookmarks)
        contentIndex = try container.decodeIfPresent(BookContentIndex.self, forKey: .contentIndex)
        state.applyLocalSpeedRange(
            isAudio: metadata.format.isAudio,
            codingPath: container.codingPath + [CodingKeys.state]
        )
    }

    /// Encodes the record as bookInfo.json holds it: its metadata, state,
    /// and bookmarks. The content index is never encoded here; it is written
    /// to contentIndex.json (`save(to:)` and `saveRecord(to:)`).
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(metadata, forKey: .metadata)
        try container.encode(state, forKey: .state)
        try container.encode(bookmarks, forKey: .bookmarks)
    }
}

/// Built-in and user-editable metadata for a book
struct BookMetadata: Codable {
    var title: String
    var author: String
    var format: BookFormat
    var md5Hash: String
    var dateAdded: Date
    var lastOpened: Date?
    /// Original filename of the imported book
    var originalFileName: String
    /// The folder path within the library (virtual folder assignment)
    var folderPath: String
    /// UUID of the book (stable across sessions)
    var bookID: UUID
    /// Path to the original source file this book was imported from (if known)
    var sourceFilePath: String?

    // EPUB-specific metadata (populated when available)
    var publisher: String?
    var publicationDate: String?
    var isbn: String?
    var language: String?
    var epubIdentifier: String?
    var epubVersion: String?

    // Audio-specific metadata (populated from file tags when available)
    var audioAlbum: String?
    var audioGenre: String?
    var audioYear: String?

    /// The version of the metadata reader that last read the book's file
    /// for its title and author (`Book.metadataReaderVersion`); nil in a
    /// record written before readers were versioned.
    var metadataReaderVersion: String?

    /// Which of the book's metadata fields the user edited by hand, and
    /// since when (`Book.handEdits`); nil in a record written before edits
    /// were recorded, and for a book made by an import that begins no
    /// record (a feed's download, a recording, New from Text, an audio or
    /// DAISY archive) until an edit is recorded. A file imported since then
    /// begins an empty record (`Book.HandEdits.noneSinceImport`).
    var handEdits: Book.HandEdits?

    /// The feed item the book was downloaded from (FR03), for a podcast
    /// episode or an article; nil for every other book. Never in
    /// library.json: a row carries it only while its book belongs to its
    /// feed, in the feed's own index (`Book.feedLink`, FR11). Each save of
    /// the book's state writes the row's link, or carries this one forward
    /// when the row has none (`Book.bookInfo(replacing:contentIndex:revisionFloor:)`).
    var feedLink: FeedBookLink? = nil

    /// The braille table a braille book's text was read with (FMT21): the
    /// row's field (`Book.brailleTable`), by its stored value ("mac:" before
    /// the file name of one of this Mac's tables), nil for every other book
    /// and for a record written before braille books.
    var brailleTable: String? = nil
    /// The liblouis version of this Mac's tables the book was read with
    /// (`Book.brailleTableVersion`, review R2); nil for a bundled table and
    /// for a record written before it was kept.
    var brailleTableVersion: String? = nil
    /// Who chose the braille table (`Book.brailleTableOrigin`, brfguess):
    /// `.guessed` when the import found the book clearly English Braille,
    /// American Edition and read it so; nil for every other book and for a
    /// record written before guesses were kept. A value that cannot be read
    /// is nil, as the row's is, and does not fail the record.
    @LenientOptional var brailleTableOrigin: BrailleTableOrigin? = nil
    /// The braille file characters a BRF or BRL book's file writes its cells
    /// in (braillecodes): the row's field (`Book.brailleFileCode`), by the
    /// code's id, kept here too, where it stands over a row that lags behind
    /// it (`BrailleFileCodeRecord.standing(row:recorded:)`). Nil for every
    /// book that records none and for a record written before it was kept;
    /// an id this TextMouth does not know is kept exactly as it is stored. A
    /// value that cannot be read is nil, as the row's is, and does not fail
    /// the record.
    @LenientOptional var brailleFileCode: String? = nil

    /// The encoding a text book's file was guessed to be in (FMT16): the
    /// row's field (`Book.textEncoding`), by its identifier in
    /// `TextEncodingCatalog`; nil for every book whose bytes named their
    /// encoding or that Windows-1252 reads correctly, and for a record
    /// written before guesses were kept. A value that cannot be read is nil,
    /// as the row's is, and does not fail the record. It holds the
    /// listener's choice too (encodingchoice).
    @LenientOptional var textEncoding: String? = nil
    /// Who decided `textEncoding` (encodingchoice): the row's field
    /// (`Book.textEncodingSource`); nil for the import, and for a record
    /// written before the listener could choose. A value that cannot be read
    /// is nil, as the row's is, and does not fail the record.
    @LenientOptional var textEncodingSource: TextEncodingSource? = nil

    init(
        title: String = "Untitled",
        author: String = Book.unknownAuthor,
        format: BookFormat = .txt,
        md5Hash: String = "",
        dateAdded: Date = Date(),
        lastOpened: Date? = nil,
        originalFileName: String = "",
        folderPath: String = "",
        bookID: UUID = UUID(),
        sourceFilePath: String? = nil,
        publisher: String? = nil,
        publicationDate: String? = nil,
        isbn: String? = nil,
        language: String? = nil,
        epubIdentifier: String? = nil,
        epubVersion: String? = nil,
        audioAlbum: String? = nil,
        audioGenre: String? = nil,
        audioYear: String? = nil,
        metadataReaderVersion: String? = nil,
        handEdits: Book.HandEdits? = nil
    ) {
        self.title = title
        self.author = author
        self.format = format
        self.md5Hash = md5Hash
        self.dateAdded = dateAdded
        self.lastOpened = lastOpened
        self.originalFileName = originalFileName
        self.folderPath = folderPath
        self.bookID = bookID
        self.sourceFilePath = sourceFilePath
        self.publisher = publisher
        self.publicationDate = publicationDate
        self.isbn = isbn
        self.language = language
        self.epubIdentifier = epubIdentifier
        self.epubVersion = epubVersion
        self.audioAlbum = audioAlbum
        self.audioGenre = audioGenre
        self.audioYear = audioYear
        self.metadataReaderVersion = metadataReaderVersion
        self.handEdits = handEdits
    }
}

/// Reading state and computed book data
struct BookState: Codable {
    var readingPosition: ReadingPosition?
    var totalWordCount: Int?
    var totalCharacterCount: Int?
    /// Whether the book has been opened (read) at least once
    var isNew: Bool
    /// The name of the .tmb directory (e.g. "Title-Author-123456.tmb")
    var tmbDirectoryName: String
    /// When playback was last started (for rewind-on-resume elapsed time)
    var lastPlaybackStarted: Date?
    /// When playback was last stopped/paused (for rewind-on-resume elapsed time)
    var lastPlaybackStopped: Date?
    /// Per-book voice ID override (nil = use global setting)
    var localVoiceID: String?
    /// Per-book WPM override (nil = use global setting)
    var localWPM: Double?
    /// Per-book pitch multiplier override (nil = use global setting, range 0.5–2.0)
    var localPitch: Double?
    /// Heading IDs that should be skipped during playback (`Heading.id`),
    /// which all older builds keep; `skippedHeadings` follows every change
    /// to them (T06), as `Book`'s do.
    var skippedHeadingIDs: [String]? {
        didSet { skippedHeadings = SkippedHeading.inStep(with: skippedHeadingIDs, keeping: skippedHeadings) }
    }
    /// The headings skipped during playback, in step with
    /// `skippedHeadingIDs` (`Book.skippedHeadings`, T06).
    var skippedHeadings: [SkippedHeading]?
    /// The skipped headings that wait, naming no heading, kept apart from
    /// `skippedHeadingIDs` (`Book.waitingSkippedHeadings`, T06's branch D).
    var waitingSkippedHeadings: [SkippedHeading]?
    /// Per-book end-of-book behavior override (nil = use global setting)
    var localEndOfBookBehavior: String?
    /// Per-book forward navigation unit override (nil = use global setting)
    var localSkipForwardUnit: String?
    /// Per-book backward navigation unit override (nil = use global setting)
    var localSkipBackwardUnit: String?
    /// Manual sort order within folder (lower = earlier)
    var manualSortOrder: Int?
    /// Total audio duration in seconds (audio books only)
    var audioDuration: TimeInterval?
    /// Version of the content.md cache format used when the cache was generated
    var cacheFormatVersion: String?
    /// Version of the persisted BookContentIndex in this package.
    var contentIndexVersion: String?
    /// The fingerprints of the source and content.md the text cache was
    /// written from, kept with the cache's format version (see
    /// `Book.textCacheFingerprint`). A load checks the package's files
    /// against these before it trusts the cache or the index.
    var textCacheFingerprint: TextCacheFingerprint?
    /// The edit of the book's text that content.md holds, if the user made
    /// one with Edit Text (`Book.editedText`, B12). Kept in the record so a
    /// library rebuilt from its records still refuses to read the book's
    /// file over the user's text.
    var editedText: EditedText?
    /// The page reader that wrote content.md (`Book.pageReaderVersion`,
    /// PG09). Kept in the record so a library rebuilt from its records
    /// re-reads only the books whose content.md predates their format's
    /// pages.
    var pageReaderVersion: String?
    /// What the package's transcript is, for a transcribed audiobook
    /// (FR05): its layout version, language, and date, so knowing whether a
    /// book has a transcript never means reading transcript.json or the
    /// content index. Only the package record holds it; library.json does
    /// not, and a library row never carries it. It follows the content
    /// index's transcript text: a write carrying an index notes that index's
    /// transcript, and every other save of the book's state keeps the note
    /// the record holds (`Book.bookInfo(replacing:contentIndex:revisionFloor:)`).
    /// Nil for any other book.
    var transcript: TranscriptNote?
    /// How many times this record has been written. Every write of
    /// bookInfo.json stores at least one more than the record it replaces
    /// (`Book.bookInfo(replacing:contentIndex:revisionFloor:)`), so of two
    /// writes the later carries the higher revision, across restarts too.
    /// Nil in a record written before revisions were kept, which counts as 0.
    var revision: Int?

    init(
        readingPosition: ReadingPosition? = nil,
        totalWordCount: Int? = nil,
        totalCharacterCount: Int? = nil,
        isNew: Bool = true,
        tmbDirectoryName: String = "",
        lastPlaybackStarted: Date? = nil,
        lastPlaybackStopped: Date? = nil,
        localVoiceID: String? = nil,
        localWPM: Double? = nil,
        localPitch: Double? = nil,
        skippedHeadingIDs: [String]? = nil,
        skippedHeadings: [SkippedHeading]? = nil,
        waitingSkippedHeadings: [SkippedHeading]? = nil,
        localEndOfBookBehavior: String? = nil,
        localSkipForwardUnit: String? = nil,
        localSkipBackwardUnit: String? = nil,
        manualSortOrder: Int? = nil,
        audioDuration: TimeInterval? = nil,
        cacheFormatVersion: String? = nil,
        contentIndexVersion: String? = nil,
        textCacheFingerprint: TextCacheFingerprint? = nil,
        editedText: EditedText? = nil,
        pageReaderVersion: String? = nil,
        transcript: TranscriptNote? = nil,
        revision: Int? = nil
    ) {
        self.readingPosition = readingPosition
        self.totalWordCount = totalWordCount
        self.totalCharacterCount = totalCharacterCount
        self.isNew = isNew
        self.tmbDirectoryName = tmbDirectoryName
        self.lastPlaybackStarted = lastPlaybackStarted
        self.lastPlaybackStopped = lastPlaybackStopped
        self.localVoiceID = localVoiceID
        self.localWPM = localWPM
        self.localPitch = localPitch
        self.skippedHeadingIDs = skippedHeadingIDs
        self.skippedHeadings = SkippedHeading.inStep(with: skippedHeadingIDs, keeping: skippedHeadings)
        self.waitingSkippedHeadings = SkippedHeading.stored(waitingSkippedHeadings)
        self.localEndOfBookBehavior = localEndOfBookBehavior
        self.localSkipForwardUnit = localSkipForwardUnit
        self.localSkipBackwardUnit = localSkipBackwardUnit
        self.manualSortOrder = manualSortOrder
        self.audioDuration = audioDuration
        self.cacheFormatVersion = cacheFormatVersion
        self.contentIndexVersion = contentIndexVersion
        self.textCacheFingerprint = textCacheFingerprint
        self.editedText = editedText
        self.pageReaderVersion = pageReaderVersion
        self.transcript = transcript
        self.revision = revision
    }

    /// Decodes saved state, repairing the values `SettingsPolicy` checks
    /// (counts, speed, and pitch; positions and bookmarks repair themselves)
    /// instead of failing the package. Every other field decodes exactly as
    /// the synthesized decoder did. The state cannot know its book's format,
    /// so this only drops speeds no book can have; `BookInfo` then applies
    /// the format's range.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fields = LenientFields(container, source: SettingsPolicy.bookStateSource)
        readingPosition = try container.decodeIfPresent(ReadingPosition.self, forKey: .readingPosition)
        totalWordCount = fields.count(.totalWordCount)
        totalCharacterCount = fields.count(.totalCharacterCount)
        isNew = try container.decode(Bool.self, forKey: .isNew)
        tmbDirectoryName = try container.decode(String.self, forKey: .tmbDirectoryName)
        lastPlaybackStarted = try container.decodeIfPresent(Date.self, forKey: .lastPlaybackStarted)
        lastPlaybackStopped = try container.decodeIfPresent(Date.self, forKey: .lastPlaybackStopped)
        localVoiceID = try container.decodeIfPresent(String.self, forKey: .localVoiceID)
        localWPM = fields.optionalValue(.localWPM, validate: SettingsPolicy.usableLocalSpeed)
        localPitch = fields.optionalValue(.localPitch, validate: SettingsPolicy.validatedLocalPitch)
        skippedHeadingIDs = try container.decodeIfPresent([String].self, forKey: .skippedHeadingIDs)
        // As `Book` decodes them: unreadable ones count as none, and they
        // are put in step with the IDs.
        skippedHeadings = SkippedHeading.inStep(with: skippedHeadingIDs, keeping: fields.optionalValue(.skippedHeadings) { $0 })
        // As `Book` decodes them: unreadable or empty ones count as none.
        waitingSkippedHeadings = SkippedHeading.stored(fields.optionalValue(.waitingSkippedHeadings) { $0 })
        localEndOfBookBehavior = try container.decodeIfPresent(String.self, forKey: .localEndOfBookBehavior)
        localSkipForwardUnit = try container.decodeIfPresent(String.self, forKey: .localSkipForwardUnit)
        localSkipBackwardUnit = try container.decodeIfPresent(String.self, forKey: .localSkipBackwardUnit)
        manualSortOrder = try container.decodeIfPresent(Int.self, forKey: .manualSortOrder)
        audioDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .audioDuration)
        cacheFormatVersion = try container.decodeIfPresent(String.self, forKey: .cacheFormatVersion)
        contentIndexVersion = try container.decodeIfPresent(String.self, forKey: .contentIndexVersion)
        // A fingerprint that cannot be read counts as none, so the cache is
        // checked as one written before fingerprints and fingerprinted
        // again, instead of the whole record failing.
        textCacheFingerprint = fields.optionalValue(.textCacheFingerprint) { $0 }
        // A record of an edit that cannot be read counts as none, as a
        // fingerprint does; a record written before B12 has none.
        editedText = fields.optionalValue(.editedText) { $0 }
        // A version that cannot be read counts as none, as an edit does.
        pageReaderVersion = fields.optionalValue(.pageReaderVersion) { $0 }
        // A note that cannot be read counts as none, as a fingerprint does:
        // the book's transcript is still read from transcript.json itself.
        transcript = fields.optionalValue(.transcript) { $0 }
        // Like a count, a revision is never negative. One that cannot be
        // read counts as none, so the next write numbers from there instead
        // of the whole record failing over a bookkeeping field.
        revision = fields.count(.revision)
    }
}

extension BookState {
    /// The analysis-owned fields this state records (see
    /// `Book.ContentAnalysisFields`).
    var contentAnalysisFields: Book.ContentAnalysisFields {
        Book.ContentAnalysisFields(
            totalWordCount: totalWordCount,
            totalCharacterCount: totalCharacterCount,
            audioDuration: audioDuration,
            contentIndexVersion: contentIndexVersion,
            cacheFormatVersion: cacheFormatVersion,
            textCacheFingerprint: textCacheFingerprint,
            editedText: editedText,
            pageReaderVersion: pageReaderVersion
        )
    }

    /// The revision that follows `latest`. At `Int.max`, which only a
    /// hand-edited file could hold, it stays put rather than overflow.
    static func revision(after latest: Int) -> Int {
        latest == .max ? latest : latest + 1
    }

    /// Applies the book format's range to `localWPM`: the words-per-minute
    /// range for text, `AudioSpeed` normalization for an audio multiplier.
    /// `BookInfo` calls this once it has decoded the format; `codingPath`
    /// locates this state in the file for the repair log.
    fileprivate mutating func applyLocalSpeedRange(isAudio: Bool, codingPath: [CodingKey]) {
        guard let saved = localWPM else { return }
        localWPM = StoredValueRepair.validated(
            saved,
            source: SettingsPolicy.bookStateSource,
            codingPath: codingPath + [CodingKeys.localWPM]
        ) { SettingsPolicy.validatedLocalSpeed($0, isAudio: isAudio) }
    }
}

// MARK: - BookInfo I/O

extension BookInfo {

    /// How bookInfo.json is written: readable, with sorted keys, so two
    /// records of one book compare line by line.
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    /// How contentIndex.json is written: compact, since only TextMouth reads
    /// it and it is a package's largest record, with sorted keys, so one
    /// index is always written as the same bytes.
    private static let contentIndexEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: Writing

    /// Replaces the package's whole record with this one: afterwards
    /// contentIndex.json holds `contentIndex`, or is gone when it is nil,
    /// and bookInfo.json holds the rest. For a package written whole, as an
    /// import, a data-directory move, or a repair that separates a shared
    /// package writes one. A save of a book's state uses `saveRecord(to:)`,
    /// which leaves the package's index alone.
    func save(to tmbDir: URL) throws {
        if let contentIndex {
            try Self.writeContentIndex(contentIndex, in: tmbDir)
        } else {
            try Self.removeContentIndex(from: tmbDir)
        }
        try writeRecordFile(in: tmbDir)
    }

    /// Writes this record over the package's, as every save of a book's
    /// state does (PERF15). A record that carries a content index writes it
    /// into contentIndex.json first: a new analysis's index, or one an older
    /// version of TextMouth kept inside bookInfo.json, moving into its own
    /// file. A record without one leaves the package's contentIndex.json as
    /// it is, so a reading checkpoint writes about a kilobyte.
    ///
    /// The index goes first, so bookInfo.json, whose analysis fields describe
    /// the index (`Book.ContentAnalysisFields`), never names one that is not
    /// on disk yet. A failure between the two leaves the new index beside the
    /// older record: every load checks a saved index against the book's text
    /// before it trusts it, and the next save writes both again.
    func saveRecord(to tmbDir: URL) throws {
        if let contentIndex {
            try Self.writeContentIndex(contentIndex, in: tmbDir)
        }
        try writeRecordFile(in: tmbDir)
    }

    /// Writes bookInfo.json alone, which never holds the content index
    /// (`encode(to:)`), replacing it atomically.
    private func writeRecordFile(in tmbDir: URL) throws {
        let data = try Self.encoder.encode(self)
        try data.write(to: TextMouthPaths.bookInfoPath(in: tmbDir), options: .atomic)
    }

    /// Writes `index` as the package's contentIndex.json, replacing it
    /// atomically.
    private static func writeContentIndex(_ index: BookContentIndex, in tmbDir: URL) throws {
        let data = try contentIndexEncoder.encode(index)
        try data.write(to: TextMouthPaths.contentIndexPath(in: tmbDir), options: .atomic)
    }

    /// Removes the package's contentIndex.json. A package without one is
    /// left as it is.
    private static func removeContentIndex(from tmbDir: URL) throws {
        do {
            try FileManager.default.removeItem(at: TextMouthPaths.contentIndexPath(in: tmbDir))
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Nothing to remove.
        }
    }

    // MARK: Reading

    /// The package's whole record: bookInfo.json, with the content index
    /// from contentIndex.json, unless bookInfo.json still holds one an older
    /// version of TextMouth kept there, which wins (see the type's notes).
    ///
    /// Throws when bookInfo.json is missing or cannot be read. A missing,
    /// unreadable, or damaged contentIndex.json leaves the record without an
    /// index, which the book's next load builds afresh, as for a book never
    /// indexed; but a read refused because either file is only in the cloud
    /// throws that refusal (`DatalessFiles.isDownloadRefusal`), so a pass
    /// that must not download leaves the book as it is.
    static func load(from tmbDir: URL) throws -> BookInfo {
        var info = try loadRecordFile(from: tmbDir)
        if info.contentIndex == nil {
            info.contentIndex = try loadContentIndex(from: tmbDir)
        }
        return info
    }

    /// bookInfo.json alone, with the index an older version kept inside it,
    /// if any. Throws when it is missing or cannot be read.
    fileprivate static func loadRecordFile(from tmbDir: URL) throws -> BookInfo {
        let data = try Data(contentsOf: TextMouthPaths.bookInfoPath(in: tmbDir))
        return try decoder.decode(BookInfo.self, from: data)
    }

    /// The package's contentIndex.json: nil when there is none, or when it
    /// cannot be read or decoded, which counts as none. Throws only a read
    /// refused because the file is only in the cloud.
    private static func loadContentIndex(from tmbDir: URL) throws -> BookContentIndex? {
        let data: Data
        do {
            data = try Data(contentsOf: TextMouthPaths.contentIndexPath(in: tmbDir))
        } catch where DatalessFiles.isDownloadRefusal(error) {
            throw error
        } catch {
            return nil
        }
        return try? decoder.decode(BookContentIndex.self, from: data)
    }

    /// Whether the package holds a contentIndex.json, downloaded or not,
    /// asked of the file's metadata alone, reading no content.
    fileprivate static func hasContentIndexFile(in tmbDir: URL) -> Bool {
        MaintenanceFileAccess.hasItem(at: TextMouthPaths.contentIndexPath(in: tmbDir))
    }
}

// MARK: - The Record a Save Replaces

/// A package's record as a save of the book's state finds it before
/// replacing it (PERF15): bookInfo.json, and whether the package keeps a
/// content index. Such a save needs nothing more of the index than whether
/// there is one (`Book.bookInfo(replacing:contentIndex:revisionFloor:)`),
/// so reading this never reads contentIndex.json, which can hold hundreds
/// of kilobytes.
struct StoredBookRecord {
    /// bookInfo.json. Its `contentIndex` is set only when an older version
    /// of TextMouth kept the index inside it; the next save moves that index
    /// into its own file.
    var info: BookInfo
    /// Whether the package keeps a content index: in contentIndex.json, or
    /// inside `info`.
    var keepsContentIndex: Bool

    /// The record in the package at `tmbDir`. Throws when bookInfo.json is
    /// missing or cannot be read, as `BookInfo.load(from:)` does.
    static func read(from tmbDir: URL) throws -> StoredBookRecord {
        let info = try BookInfo.loadRecordFile(from: tmbDir)
        return StoredBookRecord(
            info: info,
            keepsContentIndex: info.contentIndex != nil || BookInfo.hasContentIndexFile(in: tmbDir)
        )
    }
}
