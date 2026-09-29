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

    static func detect(from url: URL) -> BookFormat? {
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
        contentIndexVersion: String? = nil
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
    }

    // Custom decoding to handle missing fields from old library.json
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
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
        totalWordCount = try container.decodeIfPresent(Int.self, forKey: .totalWordCount)
        totalCharacterCount = try container.decodeIfPresent(Int.self, forKey: .totalCharacterCount)
        tmbDirectoryName = try container.decodeIfPresent(String.self, forKey: .tmbDirectoryName) ?? ""
        sourceFilePath = try container.decodeIfPresent(String.self, forKey: .sourceFilePath)
        lastPlaybackStarted = try container.decodeIfPresent(Date.self, forKey: .lastPlaybackStarted)
        lastPlaybackStopped = try container.decodeIfPresent(Date.self, forKey: .lastPlaybackStopped)
        localVoiceID = try container.decodeIfPresent(String.self, forKey: .localVoiceID)
        localWPM = try container.decodeIfPresent(Double.self, forKey: .localWPM)
        localPitch = try container.decodeIfPresent(Double.self, forKey: .localPitch)
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
    }

    /// The .tmb package directory URL
    var tmbDirectory: URL {
        TextMouthPaths.tmbPath(folderPath: folderPath, tmbName: tmbDirectoryName)
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

    mutating func applyContentIndexSummary(_ index: BookContentIndex) {
        totalWordCount = index.totalWordCount
        totalCharacterCount = index.totalCharacterCount
        audioDuration = index.totalAudioDuration
        contentIndexVersion = index.version
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

    /// Apply the metadata fields that can be edited by the library and reader
    /// metadata sheets. Keeping this mutation on Book makes the complete field
    /// set independently testable and prevents individual callers from silently
    /// dropping format-specific values.
    mutating func applyEditableMetadata(from updatedBook: Book) {
        title = updatedBook.title
        author = updatedBook.author
        md5Hash = updatedBook.md5Hash
        audioAlbum = updatedBook.audioAlbum
        audioGenre = updatedBook.audioGenre
        audioYear = updatedBook.audioYear
        epubPublisher = updatedBook.epubPublisher
        epubPublicationDate = updatedBook.epubPublicationDate
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

    /// Estimated time remaining in seconds, or nil if unknown.
    /// For audio books: uses actual duration adjusted by playback speed.
    /// For text books: uses WPM-based estimate with per-book override.
    func estimatedTimeRemaining(wpm: Double) -> TimeInterval? {
        if format.isAudio {
            guard let duration = audioDuration, duration.isFinite, duration > 0 else { return nil }
            // For audio, localWPM stores the multiplier. Match the runtime
            // clamp before division, including legacy zero-speed values.
            let speed = AudioPlaybackService.clampedSpeed(localWPM ?? 1.0)
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
    /// metadata cannot be committed alongside a package move.
    func saveBookInfoThrowing(contentIndex: BookContentIndex? = nil) throws {
        var info = makeBookInfo()
        if let contentIndex {
            info.contentIndex = contentIndex
        } else if let existing = try? BookInfo.load(from: tmbDirectory) {
            // Metadata/position saves must not erase an analysis produced by a
            // background migration or import.
            info.contentIndex = existing.contentIndex
        }
        try info.save(to: tmbDirectory)
    }

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
                contentIndexVersion: contentIndexVersion
            ),
            bookmarks: bookmarks
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

    /// Concise label shared by bookmark rows and the bookmarks rotor, such as
    /// "Bookmark 3, The Battle, Note: Check this". `headingText` names the
    /// heading containing the bookmark. When it is unknown (content not
    /// loaded, or no heading at that point) the location is simply omitted:
    /// internal content-unit numbers are never shown in its place.
    func accessibilityLabel(headingText: String?) -> String {
        var parts = ["Bookmark \(number)"]
        if let headingText, !headingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(headingText)
        }
        if !label.isEmpty { parts.append("Note: \(label)") }
        return parts.joined(separator: ", ")
    }
}
