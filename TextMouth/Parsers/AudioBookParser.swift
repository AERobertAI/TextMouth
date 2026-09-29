import Foundation
import AVFoundation

/// Parses audio files into DocumentContent for the reader.
/// For single audio files: extracts chapter markers if available (M4B), otherwise single chapter.
/// For multi-file audio books (from ZIP): each file becomes a chapter.
enum AudioBookParser {

    static func placeholderLength(for duration: TimeInterval) -> Int {
        max(1, Int(duration * ReaderViewModel.audioCharsPerSecond))
    }

    static func time(forCharacterOffset offset: Int) -> TimeInterval {
        Double(offset) / ReaderViewModel.audioCharsPerSecond
    }

    static func characterOffset(forTime time: TimeInterval) -> Int {
        Int(time * ReaderViewModel.audioCharsPerSecond)
    }

    /// Respect an explicit order without repeating a file when a manifest lists
    /// it twice; append unlisted files in Finder-style numeric order.
    static func orderedFileNames(_ names: [String], manifestOrder: [String]? = nil) -> [String] {
        let alphabetical = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard let manifestOrder, !manifestOrder.isEmpty else { return alphabetical }
        let available = Set(names)
        var seen = Set<String>()
        let requested = manifestOrder.filter { available.contains($0) && seen.insert($0).inserted }
        let requestedSet = Set(requested)
        return requested + alphabetical.filter { !requestedSet.contains($0) }
    }

    /// Find the same playable candidates during import and reader loading.
    /// ZIPs commonly contain a wrapper folder; AppleDouble sidecars and symbolic
    /// links are not chapters, even when their names have an audio extension.
    static func audioFiles(in directory: URL) throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else { throw AudioParseError.noAudioFiles }

        let extensions = Set(BookFormat.audio.fileExtensions)
        var files: [URL] = []
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: keys)
            if file.lastPathComponent == "__MACOSX" || values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if values.isRegularFile == true, extensions.contains(file.pathExtension.lowercased()) {
                files.append(file)
            }
        }
        if let enumerationError { throw enumerationError }
        return files.sorted {
            relativeName(of: $0, in: directory).localizedStandardCompare(
                relativeName(of: $1, in: directory)
            ) == .orderedAscending
        }
    }

    /// Manifest filenames are relative to the audio directory, so tracks with
    /// the same basename on different discs remain distinct.
    private static func relativeName(of file: URL, in directory: URL) -> String {
        // Foundation may return /private/var for a directory supplied as /var.
        // Compare canonical paths before removing the base-directory prefix.
        let basePath = directory.resolvingSymlinksInPath().path
        return String(file.resolvingSymlinksInPath().path.dropFirst(basePath.count + 1))
    }

    /// Parse a single audio file. Extracts chapters from M4B metadata if available.
    static func parse(url: URL) async throws -> DocumentContent {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let totalSeconds = CMTimeGetSeconds(duration)
        guard totalSeconds.isFinite && totalSeconds > 0 else {
            throw AudioParseError.invalidDuration
        }

        // Try to extract metadata
        let metadata = await AudioPlaybackService.extractMetadata(from: url)
        let title = metadata.title ?? url.deletingPathExtension().lastPathComponent
        let author = metadata.artist ?? "Unknown"

        // Try to extract chapter markers
        let chapters = await AudioPlaybackService.extractChapters(from: url)

        if chapters.isEmpty {
            // Single chapter for the whole file
            // Use a placeholder text with duration info for character-based position tracking
            let placeholderLength = placeholderLength(for: totalSeconds)
            let placeholderText = String(repeating: " ", count: max(1, placeholderLength))

            let chapter = Chapter(
                title: title,
                text: placeholderText,
                headings: [Heading(level: 1, text: title, chapterIndex: 0, characterOffset: 0)]
            )
            return DocumentContent(title: title, author: author, chapters: [chapter])
        } else {
            // Multiple chapters from metadata
            var parsedChapters: [Chapter] = []
            for (index, ch) in chapters.enumerated() {
                let chDuration = ch.duration > 0 ? ch.duration : 1
                let placeholderLength = placeholderLength(for: chDuration)
                let placeholderText = String(repeating: " ", count: max(1, placeholderLength))

                let heading = Heading(level: 1, text: ch.title, chapterIndex: index, characterOffset: 0)
                parsedChapters.append(Chapter(
                    title: ch.title,
                    text: placeholderText,
                    headings: [heading]
                ))
            }
            return DocumentContent(title: title, author: author, chapters: parsedChapters)
        }
    }

    /// Parse a directory of audio files as a multi-chapter audio book.
    /// Files are ordered alphabetically unless a manifest.json is found.
    static func parseDirectory(url: URL) async throws -> (content: DocumentContent, filePaths: [String], segments: [AudioSegment]?) {
        let fm = FileManager.default
        var audioFiles = try Self.audioFiles(in: url)

        guard !audioFiles.isEmpty else {
            throw AudioParseError.noAudioFiles
        }

        // Check for manifest.json
        let manifestURL = url.appendingPathComponent("manifest.json")
        var chapterTitles: [String: String] = [:] // filename -> title

        var manifest: AudioManifest?
        if fm.fileExists(atPath: manifestURL.path),
           let data = try? Data(contentsOf: manifestURL) {
            manifest = try? JSONDecoder().decode(AudioManifest.self, from: data)
            chapterTitles = manifest?.chapters ?? [:]
            if let order = manifest?.order, !order.isEmpty {
                // Reorder files according to manifest
                let filesByName = Dictionary(uniqueKeysWithValues: audioFiles.map {
                    (relativeName(of: $0, in: url), $0)
                })
                audioFiles = orderedFileNames(Array(filesByName.keys), manifestOrder: order)
                    .compactMap { filesByName[$0] }
            }
        }

        let overallTitle = manifest?.title ?? url.lastPathComponent
        let overallAuthor = manifest?.author ?? "Unknown"

        // If manifest has segments (DAISY-style sub-file chapters), use those
        // instead of the one-file-per-chapter model
        if let segments = manifest?.segments, !segments.isEmpty {
            let result = try await parseSegmentedAudio(
                segments: segments,
                audioDir: url,
                availableFiles: Set(audioFiles.map { relativeName(of: $0, in: url) }),
                title: overallTitle,
                author: overallAuthor
            )
            return (content: result.content, filePaths: result.filePaths, segments: segments)
        }

        var chapters: [Chapter] = []
        var filePaths: [String] = []

        for (index, fileURL) in audioFiles.enumerated() {
            let fileName = fileURL.deletingPathExtension().lastPathComponent
            let title = chapterTitles[relativeName(of: fileURL, in: url)] ?? fileName

            guard let dur = await AudioPlaybackService.getDuration(of: fileURL),
                  dur.isFinite, dur > 0 else { throw AudioParseError.invalidDuration }
            let placeholderLength = placeholderLength(for: dur)
            let placeholderText = String(repeating: " ", count: max(1, placeholderLength))

            let heading = Heading(level: 1, text: title, chapterIndex: index, characterOffset: 0)
            chapters.append(Chapter(
                title: title,
                text: placeholderText,
                headings: [heading]
            ))
            filePaths.append(fileURL.path)
        }

        let content = DocumentContent(title: overallTitle, author: overallAuthor, chapters: chapters)
        return (content: content, filePaths: filePaths, segments: nil)
    }

    /// Parse segmented audio where chapters are time ranges within audio files.
    /// Each segment specifies a file + start/end time. Segments referencing the
    /// same file become chapters that share the underlying audio, with playback
    /// controlled by clip start/end times.
    private static func parseSegmentedAudio(
        segments: [AudioSegment],
        audioDir: URL,
        availableFiles: Set<String>,
        title: String,
        author: String
    ) async throws -> (content: DocumentContent, filePaths: [String]) {
        var chapters: [Chapter] = []
        var filePaths: [String] = []

        for (index, segment) in segments.enumerated() {
            // Only reference discovered in-package media. A manifest cannot
            // escape the package or introduce negative/non-finite clip ranges.
            guard availableFiles.contains(segment.file),
                  segment.startTime.isFinite, segment.startTime >= 0,
                  segment.endTime.isFinite, segment.endTime >= 0,
                  segment.endTime == 0 || segment.endTime > segment.startTime else {
                throw AudioParseError.invalidSegment
            }
            let filePath = audioDir.appendingPathComponent(segment.file).path

            // Calculate duration from start/end times
            var duration = segment.endTime - segment.startTime
            if duration <= 0 {
                // endTime of 0 means "play to end of file" — get actual duration
                let fileURL = URL(fileURLWithPath: filePath)
                guard let fileDuration = await AudioPlaybackService.getDuration(of: fileURL) else {
                    throw AudioParseError.invalidDuration
                }
                duration = fileDuration - segment.startTime
            }

            guard duration.isFinite, duration > 0 else { throw AudioParseError.invalidDuration }

            let placeholderLength = placeholderLength(for: max(1, duration))
            let placeholderText = String(repeating: " ", count: max(1, placeholderLength))

            let heading = Heading(level: 1, text: segment.title,
                                  chapterIndex: index, characterOffset: 0)
            chapters.append(Chapter(
                title: segment.title,
                text: placeholderText,
                headings: [heading]
            ))
            filePaths.append(filePath)
        }

        let content = DocumentContent(title: title, author: author, chapters: chapters)
        return (content: content, filePaths: filePaths)
    }
}

// MARK: - Errors

enum AudioParseError: LocalizedError {
    case invalidDuration
    case noAudioFiles
    case unsupportedFormat
    case invalidSegment

    var errorDescription: String? {
        switch self {
        case .invalidDuration: return "Could not determine audio duration."
        case .noAudioFiles: return "No supported audio files found."
        case .unsupportedFormat: return "Unsupported audio format."
        case .invalidSegment: return "An audio section refers to a missing file or an invalid time range."
        }
    }
}

// MARK: - Manifest

/// Optional JSON manifest for ZIP-based audio books.
/// Placed as manifest.json in the ZIP alongside audio files.
struct AudioManifest: Codable {
    /// Custom title for the audio book
    var title: String?
    /// Author/artist
    var author: String?
    /// Map of filename -> chapter title
    var chapters: [String: String]?
    /// Ordered list of filenames (overrides alphabetical)
    var order: [String]?
    /// Sub-file chapter segments for DAISY and other formats where
    /// chapters are defined as time ranges within audio files rather
    /// than whole-file boundaries. When present, this overrides the
    /// simple one-file-per-chapter model.
    var segments: [AudioSegment]?
}

/// A chapter segment within an audio file, defined by start/end times.
/// Used for DAISY audio books where SMIL files define clip ranges
/// within shared MP3 files.
struct AudioSegment: Codable {
    /// Chapter/section title
    var title: String
    /// Audio filename (relative to the audio directory)
    var file: String
    /// Start time in seconds within the audio file
    var startTime: Double
    /// End time in seconds within the audio file (0 = play to end)
    var endTime: Double
}
