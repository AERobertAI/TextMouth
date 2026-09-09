import Foundation

/// Persisted, versioned navigation and statistics derived from a book's parsed
/// content. The full index lives in the package's bookInfo.json; library.json
/// stores only the version and compact totals already exposed by Book.
struct BookContentIndex: Codable, Hashable {
    /// Bump for changes to derived reading text, heading coordinates, metrics, or
    /// the index schema. Existing Markdown can then be reindexed without forcing
    /// another source extraction via MarkdownCacheService.currentCacheVersion.
    static let currentVersion = "1.0.0"

    enum Kind: String, Codable, Hashable {
        case text
        case audio
    }

    enum AudioLayout: String, Codable, Hashable {
        case singleFile
        case multiFile
        case segmented
    }

    var version: String
    var kind: Kind
    var format: BookFormat
    var generatedAt: Date
    var totalWordCount: Int
    var totalCharacterCount: Int
    var totalAudioDuration: TimeInterval?
    var audioLayout: AudioLayout?
    var chapters: [BookContentChapterIndex]

    var isCurrent: Bool { version == Self.currentVersion }

    func isValid(for format: BookFormat) -> Bool {
        isCurrent && self.format == format && kind == (format.isAudio ? .audio : .text)
    }

    func replacingFormat(_ format: BookFormat) -> BookContentIndex {
        var copy = self
        copy.version = Self.currentVersion
        copy.kind = format.isAudio ? .audio : .text
        copy.format = format
        copy.generatedAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        return copy
    }

    var allHeadings: [Heading] {
        chapters.flatMap { chapter in
            chapter.headings.map { stored in
                Heading(
                    level: stored.level,
                    text: stored.text,
                    chapterIndex: chapter.chapterIndex,
                    characterOffset: stored.characterOffset
                )
            }
        }
    }

    func chapterStartOffset(_ chapterIndex: Int) -> Int {
        guard chapterIndex > 0 else { return 0 }
        guard chapterIndex < chapters.count else { return totalCharacterCount }
        return chapters[chapterIndex].startCharacterOffset
    }

    func location(forGlobalOffset globalOffset: Int) -> (chapterIndex: Int, localOffset: Int) {
        guard !chapters.isEmpty else { return (0, 0) }
        let clamped = max(0, min(globalOffset, totalCharacterCount))
        if clamped >= totalCharacterCount {
            let last = chapters[chapters.count - 1]
            return (last.chapterIndex, max(0, last.characterCount - 1))
        }

        var low = 0
        var high = chapters.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if chapters[middle].startCharacterOffset <= clamped {
                low = middle
            } else {
                high = middle - 1
            }
        }

        // Zero-length chapters share a start offset. Advance to the first
        // following chapter that actually contains this coordinate.
        var resolved = low
        while resolved + 1 < chapters.count,
              clamped >= chapters[resolved].startCharacterOffset + chapters[resolved].characterCount {
            resolved += 1
        }
        let chapter = chapters[resolved]
        return (chapter.chapterIndex, max(0, clamped - chapter.startCharacterOffset))
    }

    /// Build the persisted index once, off the main actor, while parsed chapter
    /// strings are already resident. Word splitting never needs to recur in UI
    /// getters after this point.
    static func build(
        from content: DocumentContent,
        format: BookFormat,
        audioFilePaths: [String]? = nil,
        audioSegments: [AudioSegment]? = nil,
        audioBaseURL: URL? = nil
    ) -> BookContentIndex {
        build(
            fromChapters: content.chapters,
            format: format,
            audioFilePaths: audioFilePaths,
            audioSegments: audioSegments,
            audioBaseURL: audioBaseURL
        )
    }

    static func build(
        fromChapters chapters: [Chapter],
        format: BookFormat,
        audioFilePaths: [String]? = nil,
        audioSegments: [AudioSegment]? = nil,
        audioBaseURL: URL? = nil
    ) -> BookContentIndex {
        var cumulativeCharacters = 0
        var totalWords = 0
        let isAudio = format.isAudio
        let layout: AudioLayout? = {
            guard isAudio else { return nil }
            if audioSegments?.isEmpty == false { return .segmented }
            if audioFilePaths?.isEmpty == false { return .multiFile }
            return .singleFile
        }()

        let chapterIndexes = chapters.enumerated().map { chapterIndex, chapter in
            let characterCount = chapter.text.utf16Length
            let wordCount = isAudio ? 0 : chapter.text.split(whereSeparator: { $0.isWhitespace }).count
            totalWords += wordCount

            let headings = chapter.headings.map { heading in
                BookContentHeadingIndex(
                    id: "\(chapterIndex)-\(heading.characterOffset)-\(heading.level)-\(heading.text)",
                    level: heading.level,
                    text: heading.text,
                    characterOffset: heading.characterOffset,
                    globalCharacterOffset: cumulativeCharacters + heading.characterOffset
                )
            }

            let audio: BookContentAudioChapterIndex? = {
                guard isAudio else { return nil }
                let segment = audioSegments.flatMap { chapterIndex < $0.count ? $0[chapterIndex] : nil }
                let path = audioFilePaths.flatMap { chapterIndex < $0.count ? $0[chapterIndex] : nil }
                let relativePath: String?
                if let segment {
                    relativePath = segment.file
                } else if let path {
                    relativePath = relativeAudioPath(path, baseURL: audioBaseURL)
                } else {
                    relativePath = nil
                }
                let inferredDuration = Double(characterCount) / ReaderViewModel.audioCharsPerSecond
                let startTime = segment?.startTime ?? 0
                let segmentDuration = segment.map { max(0, $0.endTime - $0.startTime) }
                let resolvedDuration = segmentDuration.flatMap { $0 > 0 ? $0 : nil }
                    ?? inferredDuration
                return BookContentAudioChapterIndex(
                    relativeFilePath: relativePath,
                    startTime: startTime,
                    duration: resolvedDuration
                )
            }()

            let stored = BookContentChapterIndex(
                chapterIndex: chapterIndex,
                title: chapter.title,
                startCharacterOffset: cumulativeCharacters,
                characterCount: characterCount,
                wordCount: wordCount,
                headings: headings,
                audio: audio
            )
            cumulativeCharacters += characterCount
            return stored
        }

        return BookContentIndex(
            version: currentVersion,
            kind: isAudio ? .audio : .text,
            format: format,
            generatedAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)),
            totalWordCount: totalWords,
            totalCharacterCount: cumulativeCharacters,
            totalAudioDuration: isAudio
                ? chapterIndexes.reduce(0) { $0 + ($1.audio?.duration ?? 0) }
                : nil,
            audioLayout: layout,
            chapters: chapterIndexes
        )
    }

    /// Reconstruct the lightweight placeholder document used by audio playback
    /// without re-reading AVAsset duration and chapter metadata on every open.
    func makeAudioDocumentContent(title: String, author: String) -> DocumentContent? {
        guard isCurrent, kind == .audio else { return nil }
        let restoredChapters = chapters.map { stored in
            Chapter(
                title: stored.title,
                text: String(repeating: " ", count: max(1, stored.characterCount)),
                headings: stored.headings.map {
                    Heading(
                        level: $0.level,
                        text: $0.text,
                        chapterIndex: stored.chapterIndex,
                        characterOffset: $0.characterOffset
                    )
                }
            )
        }
        return DocumentContent(
            title: title,
            author: author,
            chapters: restoredChapters,
            contentIndex: self
        )
    }

    func resolvedAudioFilePaths(relativeTo bookURL: URL) -> [String]? {
        guard audioLayout == .multiFile || audioLayout == .segmented else { return nil }
        return chapters.compactMap { chapter in
            chapter.audio?.relativeFilePath.map {
                bookURL.appendingPathComponent($0).path
            }
        }
    }

    func restoredAudioSegments() -> [AudioSegment]? {
        guard audioLayout == .segmented else { return nil }
        let restored = chapters.compactMap { chapter -> AudioSegment? in
            guard let audio = chapter.audio, let file = audio.relativeFilePath else { return nil }
            return AudioSegment(
                title: chapter.title,
                file: file,
                startTime: audio.startTime,
                endTime: audio.startTime + audio.duration
            )
        }
        return restored.count == chapters.count ? restored : nil
    }

    private static func relativeAudioPath(_ path: String, baseURL: URL?) -> String {
        guard let baseURL else { return URL(fileURLWithPath: path).lastPathComponent }
        let basePath = baseURL.standardizedFileURL.path
        let filePath = URL(fileURLWithPath: path).standardizedFileURL.path
        let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        return filePath.hasPrefix(prefix) ? String(filePath.dropFirst(prefix.count)) : URL(fileURLWithPath: path).lastPathComponent
    }
}

struct BookContentChapterIndex: Codable, Hashable {
    var chapterIndex: Int
    var title: String
    var startCharacterOffset: Int
    var characterCount: Int
    var wordCount: Int
    var headings: [BookContentHeadingIndex]
    var audio: BookContentAudioChapterIndex?
}

struct BookContentHeadingIndex: Codable, Hashable {
    var id: String
    var level: Int
    var text: String
    var characterOffset: Int
    var globalCharacterOffset: Int
}

struct BookContentAudioChapterIndex: Codable, Hashable {
    var relativeFilePath: String?
    var startTime: TimeInterval
    var duration: TimeInterval
}
