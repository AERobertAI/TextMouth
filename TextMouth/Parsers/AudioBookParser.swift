import Foundation
import AVFoundation

/// Parses audio files into DocumentContent for the reader.
/// For single audio files: extracts chapter markers if available (M4B), otherwise single chapter.
/// For multi-file audio books (from ZIP): each file becomes a chapter.
enum AudioBookParser {

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
            let placeholderLength = Int(totalSeconds * 10) // 10 chars per second for position granularity
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
                let placeholderLength = Int(chDuration * 10)
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
    static func parseDirectory(url: URL) async throws -> (content: DocumentContent, filePaths: [String]) {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)

        let audioExtensions = Set(BookFormat.audio.fileExtensions)
        var audioFiles = contents.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard !audioFiles.isEmpty else {
            throw AudioParseError.noAudioFiles
        }

        // Check for manifest.json
        let manifestURL = url.appendingPathComponent("manifest.json")
        var chapterTitles: [String: String] = [:] // filename -> title
        var customOrder: [String]?

        if fm.fileExists(atPath: manifestURL.path),
           let data = try? Data(contentsOf: manifestURL),
           let manifest = try? JSONDecoder().decode(AudioManifest.self, from: data) {
            chapterTitles = manifest.chapters ?? [:]
            if let order = manifest.order, !order.isEmpty {
                // Reorder files according to manifest
                let orderSet = Set(order)
                let ordered = order.compactMap { name in audioFiles.first { $0.lastPathComponent == name } }
                let remaining = audioFiles.filter { !orderSet.contains($0.lastPathComponent) }
                audioFiles = ordered + remaining
                customOrder = order
            }
        }

        var chapters: [Chapter] = []
        var filePaths: [String] = []
        var overallTitle = url.lastPathComponent

        for (index, fileURL) in audioFiles.enumerated() {
            let fileName = fileURL.deletingPathExtension().lastPathComponent
            let title = chapterTitles[fileURL.lastPathComponent] ?? fileName

            let dur = await AudioPlaybackService.getDuration(of: fileURL) ?? 1
            let placeholderLength = Int(dur * 10)
            let placeholderText = String(repeating: " ", count: max(1, placeholderLength))

            let heading = Heading(level: 1, text: title, chapterIndex: index, characterOffset: 0)
            chapters.append(Chapter(
                title: title,
                text: placeholderText,
                headings: [heading]
            ))
            filePaths.append(fileURL.path)
        }

        let content = DocumentContent(title: overallTitle, author: "Unknown", chapters: chapters)
        return (content: content, filePaths: filePaths)
    }
}

// MARK: - Errors

enum AudioParseError: LocalizedError {
    case invalidDuration
    case noAudioFiles
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .invalidDuration: return "Could not determine audio duration."
        case .noAudioFiles: return "No supported audio files found."
        case .unsupportedFormat: return "Unsupported audio format."
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
}
