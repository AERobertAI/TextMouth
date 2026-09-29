import Foundation

/// The bookInfo.json model stored inside each .tmb package.
/// Contains all book-specific data: metadata, reading state, bookmarks, etc.
struct BookInfo: Codable {
    var metadata: BookMetadata
    var state: BookState
    var bookmarks: [Bookmark]
    /// Versioned chapter/heading/statistics index. Kept per package rather than
    /// in library.json so startup does not decode every heading in the library.
    var contentIndex: BookContentIndex?

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

    init(
        title: String = "Untitled",
        author: String = "Unknown",
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
        audioYear: String? = nil
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
    /// Heading IDs that should be skipped during playback
    var skippedHeadingIDs: [String]?
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
        localEndOfBookBehavior: String? = nil,
        localSkipForwardUnit: String? = nil,
        localSkipBackwardUnit: String? = nil,
        manualSortOrder: Int? = nil,
        audioDuration: TimeInterval? = nil,
        cacheFormatVersion: String? = nil,
        contentIndexVersion: String? = nil
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
        self.localEndOfBookBehavior = localEndOfBookBehavior
        self.localSkipForwardUnit = localSkipForwardUnit
        self.localSkipBackwardUnit = localSkipBackwardUnit
        self.manualSortOrder = manualSortOrder
        self.audioDuration = audioDuration
        self.cacheFormatVersion = cacheFormatVersion
        self.contentIndexVersion = contentIndexVersion
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
        localEndOfBookBehavior = try container.decodeIfPresent(String.self, forKey: .localEndOfBookBehavior)
        localSkipForwardUnit = try container.decodeIfPresent(String.self, forKey: .localSkipForwardUnit)
        localSkipBackwardUnit = try container.decodeIfPresent(String.self, forKey: .localSkipBackwardUnit)
        manualSortOrder = try container.decodeIfPresent(Int.self, forKey: .manualSortOrder)
        audioDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .audioDuration)
        cacheFormatVersion = try container.decodeIfPresent(String.self, forKey: .cacheFormatVersion)
        contentIndexVersion = try container.decodeIfPresent(String.self, forKey: .contentIndexVersion)
    }
}

extension BookState {
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

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Save this BookInfo to the bookInfo.json in the given .tmb directory
    func save(to tmbDir: URL) throws {
        let url = TextMouthPaths.bookInfoPath(in: tmbDir)
        let data = try BookInfo.encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }

    /// Load a BookInfo from a .tmb directory
    static func load(from tmbDir: URL) throws -> BookInfo {
        let url = TextMouthPaths.bookInfoPath(in: tmbDir)
        let data = try Data(contentsOf: url)
        return try decoder.decode(BookInfo.self, from: data)
    }
}
