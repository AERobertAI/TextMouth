import Foundation

/// Shared proportional remaining-time calculation for library rows and reader
/// windows. Both surfaces must provide the same total duration and cursor.
enum ReadingTimeEstimator {
    static func remaining(
        totalDuration: TimeInterval,
        globalOffset: Int,
        totalCharacterCount: Int
    ) -> TimeInterval {
        guard totalDuration > 0, totalCharacterCount > 0 else { return 0 }
        let clampedOffset = min(max(globalOffset, 0), totalCharacterCount)
        let remainingFraction = 1 - Double(clampedOffset) / Double(totalCharacterCount)
        return totalDuration * remainingFraction
    }
}

enum BookFormat: String, Codable, CaseIterable {
    case epub
    case txt
    case markdown
    case html
    case docx
    case daisy
    case pdf
    case audio

    var displayName: String {
        switch self {
        case .epub: return "EPUB"
        case .txt: return "Plain Text"
        case .markdown: return "Markdown"
        case .html: return "HTML"
        case .docx: return "Word Document"
        case .daisy: return "DAISY"
        case .pdf: return "PDF"
        case .audio: return "Audio"
        }
    }

    var fileExtensions: [String] {
        switch self {
        case .epub: return ["epub"]
        case .txt: return ["txt"]
        case .markdown: return ["md", "markdown"]
        case .html: return ["html", "htm", "xhtml"]
        case .docx: return ["docx"]
        case .daisy: return ["daisy", "opf"]
        case .pdf: return ["pdf"]
        case .audio: return ["mp3", "m4a", "m4b", "wav", "aiff", "aif", "flac", "alac", "aac"]
        }
    }

    var isAudio: Bool { self == .audio }

    /// Whether this format exposes format-specific fields in the rich metadata editor.
    /// Other document formats only support the shared title and author fields.
    var usesRichMetadataEditor: Bool { self == .epub || isAudio }

    /// The format a book imported from `url` has: from its extension, or
    /// for a DAISY book kept as loose files, from its navigation file's
    /// name or its folder's contents (TODO I02).
    static func detect(from url: URL) -> BookFormat? {
        // A DAISY 2.02 book's navigation file is always named ncc.html (or
        // ncc.htm). It stands for its whole book, not for one HTML page.
        if DAISYParser.isNCCFileName(url.lastPathComponent) {
            return .daisy
        }
        let ext = url.pathExtension.lowercased()
        for format in BookFormat.allCases {
            if format.fileExtensions.contains(ext) {
                return format
            }
        }
        // Check if a ZIP file is actually a DAISY package
        if ext == "zip" && DAISYParser.isDAISYZip(url: url) {
            return .daisy
        }
        // A folder with a DAISY book's package or navigation file at its top
        // level is that book. A TextMouth package is never imported as one:
        // it holds a book TextMouth already describes.
        if ext != "tmb" && DAISYParser.isDAISYDirectory(url: url) {
            return .daisy
        }
        return nil
    }
}

struct Book: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var author: String
    var format: BookFormat
    var filePath: String
    var md5Hash: String
    var folderPath: String  // e.g. "Fiction/Sci-Fi" or "" for root
    var dateAdded: Date
    var lastOpened: Date?
    var readingPosition: ReadingPosition?
    var bookmarks: [Bookmark]
    /// Total word count — populated when the book is first opened and parsed
    var totalWordCount: Int?
    /// Total character count — populated when the book is first opened and parsed
    var totalCharacterCount: Int?
    /// Name of the .tmb directory (e.g. "Title-Author-123456.tmb")
    var tmbDirectoryName: String
    /// Path to the original source file this book was imported from
    var sourceFilePath: String?
    /// When playback was last started (for rewind-on-resume)
    var lastPlaybackStarted: Date?
    /// When playback was last stopped/paused (for rewind-on-resume)
    var lastPlaybackStopped: Date?
    /// Per-book voice ID override (nil = use global setting)
    var localVoiceID: String?
    /// Per-book WPM override (nil = use global setting)
    var localWPM: Double?
    /// Per-book pitch multiplier override (nil = use global setting, range 0.5–2.0)
    var localPitch: Double?
    /// Heading IDs that should be skipped during playback
    var skippedHeadingIDs: [String]?
    /// Per-book end-of-book behavior override (nil = use global)
    var localEndOfBookBehavior: String?
    /// Per-book forward navigation unit (nil or invalid = use global).
    var localSkipForwardUnit: String?
    /// Per-book backward navigation unit (nil or invalid = use global).
    var localSkipBackwardUnit: String?
    /// Manual sort order within folder (lower = earlier)
    var manualSortOrder: Int?
    /// Total audio duration in seconds (for audio books only)
    var audioDuration: TimeInterval?
    /// Audio-specific metadata fields (album, genre, year) persisted in bookInfo.json
    var audioAlbum: String?
    var audioGenre: String?
    var audioYear: String?
    /// EPUB metadata is stored independently from optional file write-back so
    /// library-only edits survive reopening the editor and saving reading state.
    var epubPublisher: String?
    var epubPublicationDate: String?
    var epubISBN: String?
    var epubLanguage: String?
    var epubIdentifier: String?
    var epubVersion: String?
    /// Version of the content.md cache format. When this is lower than
    /// MarkdownCacheService.currentCacheVersion the cache will be regenerated
    /// on the next app launch to pick up parser improvements.
    var cacheFormatVersion: String?
    /// Compact validity marker for the full index stored in bookInfo.json.
    var contentIndexVersion: String?
    /// The fingerprints of the source and content.md the text cache was
    /// written from (see `TextCacheFingerprint`), recorded with the analysis
    /// that measured them; nil for audio and for a cache written before
    /// fingerprints. Startup maintenance compares them with the files.
    var textCacheFingerprint: TextCacheFingerprint?

    init(
        id: UUID = UUID(),
        title: String,
        author: String = "Unknown",
        format: BookFormat,
        filePath: String,
        md5Hash: String,
        folderPath: String = "",
        dateAdded: Date = Date(),
        lastOpened: Date? = nil,
        readingPosition: ReadingPosition? = nil,
        bookmarks: [Bookmark] = [],
        totalWordCount: Int? = nil,
        totalCharacterCount: Int? = nil,
        tmbDirectoryName: String = "",
        sourceFilePath: String? = nil,
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
        audioAlbum: String? = nil,
        audioGenre: String? = nil,
        audioYear: String? = nil,
        epubPublisher: String? = nil,
        epubPublicationDate: String? = nil,
        epubISBN: String? = nil,
        epubLanguage: String? = nil,
        epubIdentifier: String? = nil,
        epubVersion: String? = nil,
        cacheFormatVersion: String? = nil,
        contentIndexVersion: String? = nil,
        textCacheFingerprint: TextCacheFingerprint? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.format = format
        self.filePath = filePath
        self.md5Hash = md5Hash
        self.folderPath = folderPath
        self.dateAdded = dateAdded
        self.lastOpened = lastOpened
        self.readingPosition = readingPosition
        self.bookmarks = bookmarks
        self.totalWordCount = totalWordCount
        self.totalCharacterCount = totalCharacterCount
        self.tmbDirectoryName = tmbDirectoryName
        self.sourceFilePath = sourceFilePath
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
        self.audioAlbum = audioAlbum
        self.audioGenre = audioGenre
        self.audioYear = audioYear
        self.epubPublisher = epubPublisher
        self.epubPublicationDate = epubPublicationDate
        self.epubISBN = epubISBN
        self.epubLanguage = epubLanguage
        self.epubIdentifier = epubIdentifier
        self.epubVersion = epubVersion
        self.cacheFormatVersion = cacheFormatVersion
        self.contentIndexVersion = contentIndexVersion
        self.textCacheFingerprint = textCacheFingerprint
    }

    // Custom decoding to handle missing fields from old library.json.
    // Counts, speed, and pitch are validated with `SettingsPolicy` (and
    // positions and bookmarks validate themselves), so a hand-edited or
    // damaged value is repaired instead of failing the whole library.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fields = LenientFields(container, source: SettingsPolicy.bookStateSource)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        author = try container.decode(String.self, forKey: .author)
        format = try container.decode(BookFormat.self, forKey: .format)
        filePath = try container.decode(String.self, forKey: .filePath)
        md5Hash = try container.decode(String.self, forKey: .md5Hash)
        folderPath = try container.decode(String.self, forKey: .folderPath)
        dateAdded = try container.decode(Date.self, forKey: .dateAdded)
        lastOpened = try container.decodeIfPresent(Date.self, forKey: .lastOpened)
        readingPosition = try container.decodeIfPresent(ReadingPosition.self, forKey: .readingPosition)
        bookmarks = try container.decode([Bookmark].self, forKey: .bookmarks)
        totalWordCount = fields.count(.totalWordCount)
        totalCharacterCount = fields.count(.totalCharacterCount)
        tmbDirectoryName = try container.decodeIfPresent(String.self, forKey: .tmbDirectoryName) ?? ""
        sourceFilePath = try container.decodeIfPresent(String.self, forKey: .sourceFilePath)
        lastPlaybackStarted = try container.decodeIfPresent(Date.self, forKey: .lastPlaybackStarted)
        lastPlaybackStopped = try container.decodeIfPresent(Date.self, forKey: .lastPlaybackStopped)
        localVoiceID = try container.decodeIfPresent(String.self, forKey: .localVoiceID)
        // `localWPM` holds words per minute for text and a multiplier for audio.
        let isAudio = format.isAudio
        localWPM = fields.optionalValue(.localWPM) { SettingsPolicy.validatedLocalSpeed($0, isAudio: isAudio) }
        localPitch = fields.optionalValue(.localPitch, validate: SettingsPolicy.validatedLocalPitch)
        skippedHeadingIDs = try container.decodeIfPresent([String].self, forKey: .skippedHeadingIDs)
        localEndOfBookBehavior = try container.decodeIfPresent(String.self, forKey: .localEndOfBookBehavior)
        localSkipForwardUnit = try container.decodeIfPresent(String.self, forKey: .localSkipForwardUnit)
        localSkipBackwardUnit = try container.decodeIfPresent(String.self, forKey: .localSkipBackwardUnit)
        manualSortOrder = try container.decodeIfPresent(Int.self, forKey: .manualSortOrder)
        audioDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .audioDuration)
        audioAlbum = try container.decodeIfPresent(String.self, forKey: .audioAlbum)
        audioGenre = try container.decodeIfPresent(String.self, forKey: .audioGenre)
        audioYear = try container.decodeIfPresent(String.self, forKey: .audioYear)
        epubPublisher = try container.decodeIfPresent(String.self, forKey: .epubPublisher)
        epubPublicationDate = try container.decodeIfPresent(String.self, forKey: .epubPublicationDate)
        epubISBN = try container.decodeIfPresent(String.self, forKey: .epubISBN)
        epubLanguage = try container.decodeIfPresent(String.self, forKey: .epubLanguage)
        epubIdentifier = try container.decodeIfPresent(String.self, forKey: .epubIdentifier)
        epubVersion = try container.decodeIfPresent(String.self, forKey: .epubVersion)
        // Decode as String, falling back to converting old Int values for compatibility
        if let str = try? container.decodeIfPresent(String.self, forKey: .cacheFormatVersion) {
            cacheFormatVersion = str
        } else if let intVal = try? container.decodeIfPresent(Int.self, forKey: .cacheFormatVersion) {
            cacheFormatVersion = "\(intVal).0.0"
        } else {
            cacheFormatVersion = nil
        }
        contentIndexVersion = try container.decodeIfPresent(String.self, forKey: .contentIndexVersion)
        // A fingerprint that cannot be read counts as none: the cache is then
        // checked as one written before fingerprints, instead of the whole
        // library failing over one damaged field.
        textCacheFingerprint = fields.optionalValue(.textCacheFingerprint) { $0 }
    }

    /// The .tmb package directory URL: in the library, or, while an import
    /// is staging this book's package, wherever the import builds it, which
    /// can be this Mac's Import Staging folder (`ImportStaging`, FR02).
    var tmbDirectory: URL {
        ImportStaging.directory(ofStagedPackage: tmbDirectoryName)
            ?? TextMouthPaths.tmbPath(folderPath: folderPath, tmbName: tmbDirectoryName)
    }

    /// The actual book file URL inside the .tmb package
    var bookFileURL: URL {
        URL(fileURLWithPath: filePath)
    }

    /// The effective WPM for this book: local override if set, otherwise the provided fallback
    func effectiveWPM(fallback: Double) -> Double {
        localWPM ?? fallback
    }

    /// Resolve the saved forward unit, safely falling back for legacy or
    /// manually edited state containing no value or an unknown value.
    func effectiveSkipForwardUnit(fallback: SkipUnit) -> SkipUnit {
        localSkipForwardUnit.flatMap(SkipUnit.init(rawValue:)) ?? fallback
    }

    /// Resolve the saved backward unit with the same compatibility behavior.
    func effectiveSkipBackwardUnit(fallback: SkipUnit) -> SkipUnit {
        localSkipBackwardUnit.flatMap(SkipUnit.init(rawValue:)) ?? fallback
    }

    /// The fields of a book that content analysis owns: the word and
    /// character counts, the audio duration, the versions of the content
    /// index and text cache they were measured from, and the fingerprints of
    /// the files that text cache was written from. An analysis result
    /// changes these and nothing else, whether it lands in the package
    /// record or on the library row. Every other field of a book is user
    /// state or metadata, which only the user's own actions change.
    struct ContentAnalysisFields: Equatable, Sendable {
        var totalWordCount: Int?
        var totalCharacterCount: Int?
        var audioDuration: TimeInterval?
        var contentIndexVersion: String?
        var cacheFormatVersion: String?
        var textCacheFingerprint: TextCacheFingerprint? = nil
    }

    /// This book's analysis-owned fields. Setting them changes exactly those
    /// fields, so a record or a row that takes an analysis keeps every
    /// reading position, bookmark, setting, and edit it had.
    var contentAnalysisFields: ContentAnalysisFields {
        get {
            ContentAnalysisFields(
                totalWordCount: totalWordCount,
                totalCharacterCount: totalCharacterCount,
                audioDuration: audioDuration,
                contentIndexVersion: contentIndexVersion,
                cacheFormatVersion: cacheFormatVersion,
                textCacheFingerprint: textCacheFingerprint
            )
        }
        set {
            totalWordCount = newValue.totalWordCount
            totalCharacterCount = newValue.totalCharacterCount
            audioDuration = newValue.audioDuration
            contentIndexVersion = newValue.contentIndexVersion
            cacheFormatVersion = newValue.cacheFormatVersion
            textCacheFingerprint = newValue.textCacheFingerprint
        }
    }

    /// Records a completed analysis of this book: the statistics and version
    /// of `index` and, when the analysis vouches for one, the version of the
    /// text cache it read or wrote. A nil `cacheFormatVersion` keeps the
    /// book's own, since such an analysis says nothing about the cache. The
    /// cache's fingerprints always come from `index`, which carries those of
    /// the files it was made from, so a book never keeps fingerprints that
    /// describe another index than the one recorded with them.
    mutating func applyContentAnalysis(_ index: BookContentIndex, cacheFormatVersion: String?) {
        contentAnalysisFields = ContentAnalysisFields(
            totalWordCount: index.totalWordCount,
            totalCharacterCount: index.totalCharacterCount,
            audioDuration: index.totalAudioDuration,
            contentIndexVersion: index.version,
            cacheFormatVersion: cacheFormatVersion ?? self.cacheFormatVersion,
            textCacheFingerprint: index.textCacheFingerprint
        )
    }

    /// Records the statistics and version of `index`, keeping the book's text
    /// cache version (see `applyContentAnalysis(_:cacheFormatVersion:)`).
    mutating func applyContentIndexSummary(_ index: BookContentIndex) {
        applyContentAnalysis(index, cacheFormatVersion: nil)
    }

    /// Whether this book overrides any global voice, speed, or pitch setting.
    var hasLocalVoiceSettings: Bool {
        localVoiceID != nil || localWPM != nil || localPitch != nil
    }

    struct LocalVoiceSettings: Equatable {
        var voiceID: String? = nil
        var wordsPerMinute: Double? = nil
        var pitch: Double? = nil
    }

    /// Snapshot used when copying this book's overrides into global settings.
    var localVoiceSettings: LocalVoiceSettings {
        LocalVoiceSettings(voiceID: localVoiceID, wordsPerMinute: localWPM, pitch: localPitch)
    }

    /// Remove all per-book voice overrides atomically from the model.
    mutating func clearLocalVoiceSettings() {
        localVoiceID = nil
        localWPM = nil
        localPitch = nil
    }

    /// The metadata the library's and the reader's metadata editors change:
    /// the title and author, an audiobook's album, genre, and year, and an
    /// EPUB's publisher and publication date, together with the content
    /// hash, which changes when an edit is written into the book's EPUB file.
    struct EditableMetadata: Equatable, Sendable {
        var title: String
        var author: String
        var md5Hash: String
        var audioAlbum: String?
        var audioGenre: String?
        var audioYear: String?
        var epubPublisher: String?
        var epubPublicationDate: String?
    }

    /// This book's editable metadata. Setting it changes exactly those
    /// fields, so the book's identity, files, and reading state stay as they
    /// were.
    var editableMetadata: EditableMetadata {
        get {
            EditableMetadata(
                title: title,
                author: author,
                md5Hash: md5Hash,
                audioAlbum: audioAlbum,
                audioGenre: audioGenre,
                audioYear: audioYear,
                epubPublisher: epubPublisher,
                epubPublicationDate: epubPublicationDate
            )
        }
        set {
            title = newValue.title
            author = newValue.author
            md5Hash = newValue.md5Hash
            audioAlbum = newValue.audioAlbum
            audioGenre = newValue.audioGenre
            audioYear = newValue.audioYear
            epubPublisher = newValue.epubPublisher
            epubPublicationDate = newValue.epubPublicationDate
        }
    }

    /// Apply the metadata fields that can be edited by the library and reader
    /// metadata sheets (`EditableMetadata`). Keeping this mutation on Book
    /// makes the complete field set independently testable and prevents
    /// individual callers from silently dropping format-specific values.
    mutating func applyEditableMetadata(from updatedBook: Book) {
        editableMetadata = updatedBook.editableMetadata
    }

    /// Where a book's files are: the library folder holding its package, the
    /// package's name, and the path the book reads from inside it (its file,
    /// or its folder of audio tracks). Moving the book, renaming or moving a
    /// folder above it, and moving the data directory change it.
    struct FileLocation: Equatable, Sendable {
        var folderPath: String
        var filePath: String
        var tmbDirectoryName: String
    }

    /// This book's file location. Setting it changes exactly those fields.
    var fileLocation: FileLocation {
        get {
            FileLocation(folderPath: folderPath, filePath: filePath, tmbDirectoryName: tmbDirectoryName)
        }
        set {
            folderPath = newValue.folderPath
            filePath = newValue.filePath
            tmbDirectoryName = newValue.tmbDirectoryName
        }
    }

    /// What a reader takes from the library's row of its book whenever the
    /// library changes that row while the reader has the book open (TODO
    /// P10): where the book's files are, its editable metadata, and what
    /// content analysis measured.
    ///
    /// Everything else is the reader's own: its position and bookmarks, its
    /// voice, speed, pitch, navigation units, skipped sections, end-of-book
    /// behavior, and playback times, each of which it writes through to the
    /// library as it changes them. The library's own bookkeeping (when the
    /// book was added and last opened, its place in manual order) is nothing
    /// a reader shows or uses.
    struct LibraryFields: Equatable, Sendable {
        var location: FileLocation
        var metadata: EditableMetadata
        var analysis: ContentAnalysisFields
    }

    /// This book's library fields. Setting them changes exactly those
    /// fields, so a reader that takes them keeps all of its own state.
    var libraryFields: LibraryFields {
        get {
            LibraryFields(location: fileLocation, metadata: editableMetadata, analysis: contentAnalysisFields)
        }
        set {
            fileLocation = newValue.location
            editableMetadata = newValue.metadata
            contentAnalysisFields = newValue.analysis
        }
    }

    /// Overlay metadata kept by TextMouth onto values extracted from the EPUB.
    /// Optional fields distinguish an unedited legacy book from an intentional
    /// empty-string edit that clears publisher or publication date.
    func mergingEditableEPUBMetadata(_ extracted: EPUBMetadata) -> EPUBMetadata {
        var merged = extracted
        merged.title = title
        merged.author = author
        if let epubPublisher { merged.publisher = epubPublisher }
        if let epubPublicationDate { merged.publicationDate = epubPublicationDate }
        return merged
    }

    /// Overlay metadata kept by TextMouth onto values read from an audio
    /// file's tags: the title and author always, since they are the names
    /// the library gives the book, and the album, genre, and year once they
    /// have been edited. Nil means never edited, so the tag's value stands;
    /// an empty string is an edit that clears it.
    func mergingEditableAudioMetadata(_ extracted: AudioMetadata) -> AudioMetadata {
        var merged = extracted
        merged.title = title
        merged.artist = author
        if let audioAlbum { merged.album = audioAlbum }
        if let audioGenre { merged.genre = audioGenre }
        if let audioYear { merged.year = audioYear }
        return merged
    }

    /// Estimated time remaining in seconds, or nil if unknown.
    /// For audio books: uses actual duration adjusted by playback speed.
    /// For text books: uses WPM-based estimate with per-book override.
    func estimatedTimeRemaining(wpm: Double) -> TimeInterval? {
        if format.isAudio {
            guard let duration = audioDuration, duration.isFinite, duration > 0 else { return nil }
            // For audio, localWPM stores the multiplier. Normalize it exactly
            // as the reader and player do (clamped and snapped) before
            // division, including legacy zero-speed values.
            let speed = AudioSpeed.normalized(localWPM ?? AudioSpeed.normal)
            let adjustedDuration = duration / speed
            guard let pos = readingPosition else { return adjustedDuration }
            let globalOffset = pos.globalCharacterOffset ?? pos.characterOffset
            guard let totalChars = totalCharacterCount, totalChars > 0 else { return adjustedDuration }
            return ReadingTimeEstimator.remaining(
                totalDuration: adjustedDuration,
                globalOffset: globalOffset,
                totalCharacterCount: totalChars
            )
        }

        let effectiveSpeed = effectiveWPM(fallback: wpm)
        guard let totalWords = totalWordCount, let totalChars = totalCharacterCount,
              totalChars > 0, effectiveSpeed > 0 else { return nil }
        let totalTime = Double(totalWords) / effectiveSpeed * 60.0
        guard let pos = readingPosition else { return totalTime }
        let globalOffset = pos.globalCharacterOffset ?? pos.characterOffset
        return ReadingTimeEstimator.remaining(
            totalDuration: totalTime,
            globalOffset: globalOffset,
            totalCharacterCount: totalChars
        )
    }

    /// Percent of the book already read (0–100), or nil when the book has no
    /// saved position or has not been measured yet. Library rows hold only
    /// this model, never parsed content, so they report overall progress
    /// instead of a heading. The cursor and total match
    /// `estimatedTimeRemaining(wpm:)`, so a row's percent and time left agree.
    var percentComplete: Double? {
        guard let position = readingPosition,
              let totalChars = totalCharacterCount, totalChars > 0 else { return nil }
        let globalOffset = position.globalCharacterOffset ?? position.characterOffset
        let clampedOffset = min(max(globalOffset, 0), totalChars)
        return Double(clampedOffset) / Double(totalChars) * 100
    }

    /// Save this book's data to its bookInfo.json
    func saveBookInfo() {
        try? saveBookInfoThrowing()
    }

    /// Throwing variant used by filesystem transactions that must roll back if
    /// metadata cannot be committed alongside a package move. Writes over the
    /// record now in the package as `bookInfo(replacing:contentIndex:revisionFloor:)`
    /// describes.
    func saveBookInfoThrowing(contentIndex: BookContentIndex? = nil) throws {
        try bookInfo(replacing: storedBookInfo(), contentIndex: contentIndex).save(to: tmbDirectory)
    }

    /// The bookInfo.json now in this book's package, or nil when there is
    /// none or it cannot be read.
    func storedBookInfo() -> BookInfo? {
        try? BookInfo.load(from: tmbDirectory)
    }

    /// The bookInfo.json this book writes over `stored`, the record now in
    /// its package (nil when there is none or it cannot be read).
    ///
    /// The content index and the analysis fields measured with it
    /// (`ContentAnalysisFields`) travel together. A write that carries
    /// `contentIndex` records it with this book's analysis fields, which
    /// describe it. A write without one, such as a position, bookmark, or
    /// metadata save, keeps the stored index together with the stored
    /// fields: a library row can lag behind an analysis committed moments
    /// earlier, and its older counts and versions must neither erase that
    /// analysis nor be recorded beside an index they do not describe. Only
    /// when no index is stored does such a write record its own fields.
    ///
    /// The revision is one more than the stored record's, or one more than
    /// `revisionFloor` when that is higher. The metadata queue passes the
    /// highest revision it has written for this book, so its revisions keep
    /// rising even when the stored record has lost its own.
    func bookInfo(replacing stored: BookInfo?, contentIndex: BookContentIndex?, revisionFloor: Int = 0) -> BookInfo {
        var recorded = self
        var index = contentIndex
        if index == nil, let stored, let storedIndex = stored.contentIndex {
            index = storedIndex
            recorded.contentAnalysisFields = stored.state.contentAnalysisFields
        }
        var info = recorded.makeBookInfo()
        info.contentIndex = index
        info.state.revision = BookState.revision(after: max(stored?.state.revision ?? 0, revisionFloor))
        return info
    }

    /// This book's metadata, state, and bookmarks as bookInfo.json records
    /// them, without a content index or revision: those depend on the record
    /// being replaced (`bookInfo(replacing:contentIndex:revisionFloor:)`).
    func makeBookInfo() -> BookInfo {
        BookInfo(
            metadata: BookMetadata(
                title: title,
                author: author,
                format: format,
                md5Hash: md5Hash,
                dateAdded: dateAdded,
                lastOpened: lastOpened,
                originalFileName: bookFileURL.lastPathComponent,
                folderPath: folderPath,
                bookID: id,
                sourceFilePath: sourceFilePath,
                publisher: epubPublisher,
                publicationDate: epubPublicationDate,
                isbn: epubISBN,
                language: epubLanguage,
                epubIdentifier: epubIdentifier,
                epubVersion: epubVersion,
                audioAlbum: audioAlbum,
                audioGenre: audioGenre,
                audioYear: audioYear
            ),
            state: BookState(
                readingPosition: readingPosition,
                totalWordCount: totalWordCount,
                totalCharacterCount: totalCharacterCount,
                isNew: lastOpened == nil,
                tmbDirectoryName: tmbDirectoryName,
                lastPlaybackStarted: lastPlaybackStarted,
                lastPlaybackStopped: lastPlaybackStopped,
                localVoiceID: localVoiceID,
                localWPM: localWPM,
                localPitch: localPitch,
                skippedHeadingIDs: skippedHeadingIDs,
                localEndOfBookBehavior: localEndOfBookBehavior,
                localSkipForwardUnit: localSkipForwardUnit,
                localSkipBackwardUnit: localSkipBackwardUnit,
                manualSortOrder: manualSortOrder,
                audioDuration: audioDuration,
                cacheFormatVersion: cacheFormatVersion,
                contentIndexVersion: contentIndexVersion,
                textCacheFingerprint: textCacheFingerprint
            ),
            bookmarks: bookmarks
        )
    }

    /// The book a package record describes, the inverse of `makeBookInfo()`.
    /// Every field bookInfo.json keeps comes from `record`. The file path,
    /// folder, and package name come from where the caller found the
    /// package, because a record cannot vouch for where its package is now.
    init(record: BookInfo, filePath: String, folderPath: String, tmbDirectoryName: String) {
        let metadata = record.metadata
        let state = record.state
        self.init(
            id: metadata.bookID,
            title: metadata.title,
            author: metadata.author,
            format: metadata.format,
            filePath: filePath,
            md5Hash: metadata.md5Hash,
            folderPath: folderPath,
            dateAdded: metadata.dateAdded,
            lastOpened: metadata.lastOpened,
            readingPosition: state.readingPosition,
            bookmarks: record.bookmarks,
            totalWordCount: state.totalWordCount,
            totalCharacterCount: state.totalCharacterCount,
            tmbDirectoryName: tmbDirectoryName,
            sourceFilePath: metadata.sourceFilePath,
            lastPlaybackStarted: state.lastPlaybackStarted,
            lastPlaybackStopped: state.lastPlaybackStopped,
            localVoiceID: state.localVoiceID,
            localWPM: state.localWPM,
            localPitch: state.localPitch,
            skippedHeadingIDs: state.skippedHeadingIDs,
            localEndOfBookBehavior: state.localEndOfBookBehavior,
            localSkipForwardUnit: state.localSkipForwardUnit,
            localSkipBackwardUnit: state.localSkipBackwardUnit,
            manualSortOrder: state.manualSortOrder,
            audioDuration: state.audioDuration,
            audioAlbum: metadata.audioAlbum,
            audioGenre: metadata.audioGenre,
            audioYear: metadata.audioYear,
            epubPublisher: metadata.publisher,
            epubPublicationDate: metadata.publicationDate,
            epubISBN: metadata.isbn,
            epubLanguage: metadata.language,
            epubIdentifier: metadata.epubIdentifier,
            epubVersion: metadata.epubVersion,
            cacheFormatVersion: state.cacheFormatVersion,
            contentIndexVersion: state.contentIndexVersion,
            textCacheFingerprint: state.textCacheFingerprint
        )
    }
}

struct ReadingPosition: Codable, Hashable {
    var chapterIndex: Int
    var headingIndex: Int?
    var characterOffset: Int
    /// Global character offset across all chapters (for library time estimation)
    var globalCharacterOffset: Int?
    var lastUpdated: Date

    init(chapterIndex: Int = 0, headingIndex: Int? = nil, characterOffset: Int = 0, globalCharacterOffset: Int? = nil) {
        self.chapterIndex = chapterIndex
        self.headingIndex = headingIndex
        self.characterOffset = characterOffset
        self.globalCharacterOffset = globalCharacterOffset
        self.lastUpdated = Date()
    }

    /// Decodes a saved position, repairing indices and offsets no position
    /// can have (negative, or too large for an `Int`) instead of failing the
    /// book and, with it, the whole library. The reader still clamps the
    /// result against the loaded content.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fields = LenientFields(container, source: SettingsPolicy.bookStateSource)
        chapterIndex = fields.position(.chapterIndex)
        headingIndex = fields.optionalPosition(.headingIndex)
        characterOffset = fields.position(.characterOffset)
        globalCharacterOffset = fields.optionalPosition(.globalCharacterOffset)
        lastUpdated = try container.decode(Date.self, forKey: .lastUpdated)
    }
}

struct Bookmark: Identifiable, Codable, Hashable {
    let id: UUID
    var number: Int
    var chapterIndex: Int
    var characterOffset: Int
    var label: String
    var dateCreated: Date

    init(
        id: UUID = UUID(),
        number: Int,
        chapterIndex: Int,
        characterOffset: Int,
        label: String = "",
        dateCreated: Date = Date()
    ) {
        self.id = id
        self.number = number
        self.chapterIndex = chapterIndex
        self.characterOffset = characterOffset
        self.label = label
        self.dateCreated = dateCreated
    }

    /// Decodes a saved bookmark, repairing a location no bookmark can have
    /// (negative, or too large for an `Int`) instead of failing the book.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fields = LenientFields(container, source: SettingsPolicy.bookStateSource)
        id = try container.decode(UUID.self, forKey: .id)
        number = try container.decode(Int.self, forKey: .number)
        chapterIndex = fields.position(.chapterIndex)
        characterOffset = fields.position(.characterOffset)
        label = try container.decode(String.self, forKey: .label)
        dateCreated = try container.decode(Date.self, forKey: .dateCreated)
    }

    /// Concise label shared by bookmark rows and the bookmarks rotor, such as
    /// "Bookmark 3, The Battle, Note: Check this". `headingText` names the
    /// heading containing the bookmark. When it is unknown (content not
    /// loaded, or no heading at that point) the location is simply omitted:
    /// internal content-unit numbers are never shown in its place.
    func accessibilityLabel(headingText: String?) -> String {
        var parts = ["Bookmark \(number)"]
        if let headingText = headingText?.nonBlank {
            parts.append(headingText)
        }
        if !label.isEmpty { parts.append("Note: \(label)") }
        return parts.joined(separator: ", ")
    }
}
