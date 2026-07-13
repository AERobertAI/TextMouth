import Foundation

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
    /// Manual sort order within folder (lower = earlier)
    var manualSortOrder: Int?
    /// Total audio duration in seconds (for audio books only)
    var audioDuration: TimeInterval?
    /// Audio-specific metadata fields (album, genre, year) persisted in bookInfo.json
    var audioAlbum: String?
    var audioGenre: String?
    var audioYear: String?
    /// Version of the content.md cache format. When this is lower than
    /// MarkdownCacheService.currentCacheVersion the cache will be regenerated
    /// on the next app launch to pick up parser improvements.
    var cacheFormatVersion: String?

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
        manualSortOrder: Int? = nil,
        audioDuration: TimeInterval? = nil,
        audioAlbum: String? = nil,
        audioGenre: String? = nil,
        audioYear: String? = nil,
        cacheFormatVersion: String? = nil
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
        self.manualSortOrder = manualSortOrder
        self.audioDuration = audioDuration
        self.audioAlbum = audioAlbum
        self.audioGenre = audioGenre
        self.audioYear = audioYear
        self.cacheFormatVersion = cacheFormatVersion
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
        manualSortOrder = try container.decodeIfPresent(Int.self, forKey: .manualSortOrder)
        audioDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .audioDuration)
        audioAlbum = try container.decodeIfPresent(String.self, forKey: .audioAlbum)
        audioGenre = try container.decodeIfPresent(String.self, forKey: .audioGenre)
        audioYear = try container.decodeIfPresent(String.self, forKey: .audioYear)
        // Decode as String, falling back to converting old Int values for compatibility
        if let str = try? container.decodeIfPresent(String.self, forKey: .cacheFormatVersion) {
            cacheFormatVersion = str
        } else if let intVal = try? container.decodeIfPresent(Int.self, forKey: .cacheFormatVersion) {
            cacheFormatVersion = "\(intVal).0.0"
        } else {
            cacheFormatVersion = nil
        }
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

    /// Estimated time remaining in seconds, or nil if unknown.
    /// For audio books: uses actual duration adjusted by playback speed.
    /// For text books: uses WPM-based estimate with per-book override.
    func estimatedTimeRemaining(wpm: Double) -> TimeInterval? {
        if format.isAudio {
            guard let duration = audioDuration, duration > 0 else { return nil }
            let speed = localWPM ?? 1.0 // For audio, localWPM stores the speed multiplier
            let adjustedDuration = duration / speed
            guard let pos = readingPosition else { return adjustedDuration }
            let globalOffset = pos.globalCharacterOffset ?? pos.characterOffset
            guard let totalChars = totalCharacterCount, totalChars > 0 else { return adjustedDuration }
            let fraction = min(Double(globalOffset) / Double(totalChars), 1.0)
            return adjustedDuration * (1.0 - fraction)
        }

        let effectiveSpeed = effectiveWPM(fallback: wpm)
        guard let totalWords = totalWordCount, let totalChars = totalCharacterCount,
              totalChars > 0, effectiveSpeed > 0 else { return nil }
        let totalTime = Double(totalWords) / effectiveSpeed * 60.0
        guard let pos = readingPosition else { return totalTime }
        let globalOffset = pos.globalCharacterOffset ?? pos.characterOffset
        let fraction = min(Double(globalOffset) / Double(totalChars), 1.0)
        return totalTime * (1.0 - fraction)
    }

    /// Save this book's data to its bookInfo.json
    func saveBookInfo() {
        let info = BookInfo(
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
                manualSortOrder: manualSortOrder,
                audioDuration: audioDuration,
                cacheFormatVersion: cacheFormatVersion
            ),
            bookmarks: bookmarks
        )
        try? info.save(to: tmbDirectory)
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
}
