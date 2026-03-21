import Foundation

// MARK: - Shared Types (mirrored from app)

struct Heading: Equatable {
    var id: String
    var level: Int
    var text: String
    var chapterIndex: Int
    var characterOffset: Int

    init(level: Int, text: String, chapterIndex: Int = 0, characterOffset: Int = 0) {
        self.level = level
        self.text = text
        self.chapterIndex = chapterIndex
        self.characterOffset = characterOffset
        self.id = "\(chapterIndex)-\(characterOffset)-\(level)-\(text)"
    }
}

struct Chapter {
    var title: String
    var text: String
    var headings: [Heading]

    init(title: String = "", text: String = "", headings: [Heading] = []) {
        self.title = title
        self.text = text
        self.headings = headings
    }
}

struct DocumentContent {
    var title: String
    var author: String
    var chapters: [Chapter]

    var allHeadings: [Heading] {
        var result: [Heading] = []
        for (chapterIndex, chapter) in chapters.enumerated() {
            for heading in chapter.headings {
                var h = heading
                h.chapterIndex = chapterIndex
                h.id = "\(chapterIndex)-\(h.characterOffset)-\(h.level)-\(h.text)"
                result.append(h)
            }
        }
        return result
    }

    var totalCharacterCount: Int {
        chapters.reduce(0) { $0 + $1.text.count }
    }

    var totalWordCount: Int {
        chapters.reduce(0) { $0 + $1.text.split(whereSeparator: { $0.isWhitespace }).count }
    }

    func chapterStartOffset(_ chapterIndex: Int) -> Int {
        guard chapterIndex > 0 else { return 0 }
        let clamped = min(chapterIndex, chapters.count)
        return chapters[0..<clamped].reduce(0) { $0 + $1.text.count }
    }

    func globalOffset(chapterIndex: Int, localOffset: Int) -> Int {
        chapterStartOffset(chapterIndex) + localOffset
    }

    func estimatedReadingTime(wpm: Double) -> TimeInterval {
        guard wpm > 0 else { return 0 }
        return Double(totalWordCount) / wpm * 60.0
    }
}

struct Bookmark: Identifiable, Codable {
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

struct BookFolder {
    var name: String
    var parentPath: String
    var fullPath: String { parentPath.isEmpty ? name : "\(parentPath)/\(name)" }
    var depth: Int { fullPath.isEmpty ? 0 : fullPath.components(separatedBy: "/").count }
    static let maxDepth = 4
}

/// Mirrored from the app for metadata editing and persistence tests
struct AudioMetadata: Codable {
    var title: String
    var artist: String
    var album: String
    var genre: String
    var year: String
    var duration: String
    var fileFormat: String

    init(
        title: String = "",
        artist: String = "",
        album: String = "",
        genre: String = "",
        year: String = "",
        duration: String = "",
        fileFormat: String = ""
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.year = year
        self.duration = duration
        self.fileFormat = fileFormat
    }
}

/// Book format enum mirrored from the app
enum BookFormat: String, Codable, CaseIterable {
    case epub, txt, markdown, html, audio
    var isAudio: Bool { self == .audio }
}

/// Minimal BookMetadata mirrored from the app for JSON round-trip tests
struct BookMetadata: Codable {
    var title: String
    var author: String
    var format: BookFormat
    var md5Hash: String
    var dateAdded: Date
    var lastOpened: Date?
    var originalFileName: String
    var folderPath: String
    var bookID: UUID
    var sourceFilePath: String?
    var publisher: String?
    var publicationDate: String?
    var isbn: String?
    var language: String?
    var epubIdentifier: String?
    var epubVersion: String?
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

