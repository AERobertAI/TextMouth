import Foundation

// MARK: - Shared Types (mirrored from app)

// MARK: - LibrarySortField (mirrored from app)

enum LibrarySortField: String, CaseIterable, Codable {
    case title = "Title"
    case author = "Author"
    case dateAdded = "Date Added"
    case lastOpened = "Last Opened"
    case fileSize = "File Size"
    case manual = "Manual Order"
}

/// Per-folder sort configuration, mirrored from app
struct FolderSortSetting: Codable, Equatable {
    var sortField: LibrarySortField
    var sortAscending: Bool

    static let defaultSort = FolderSortSetting(sortField: .title, sortAscending: true)
}

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

    /// Estimated time to read from a given global character offset to the end
    func estimatedTimeRemaining(fromGlobalOffset offset: Int, wpm: Double) -> TimeInterval {
        guard wpm > 0, totalCharacterCount > 0 else { return 0 }
        let remainingFraction = Double(max(totalCharacterCount - offset, 0)) / Double(totalCharacterCount)
        return estimatedReadingTime(wpm: wpm) * remainingFraction
    }

    /// Percentage through the book for a given global offset
    func percentComplete(globalOffset: Int) -> Double {
        guard totalCharacterCount > 0 else { return 0 }
        return min(Double(globalOffset) / Double(totalCharacterCount) * 100.0, 100.0)
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

struct BookFolder: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var parentPath: String
    var fullPath: String { parentPath.isEmpty ? name : "\(parentPath)/\(name)" }
    var depth: Int { fullPath.isEmpty ? 0 : fullPath.components(separatedBy: "/").count }
    static let maxDepth = 4

    init(id: UUID = UUID(), name: String, parentPath: String = "") {
        self.id = id
        self.name = name
        self.parentPath = parentPath
    }
}

extension Array where Element == BookFolder {
    /// Sort folders in tree order: parent immediately followed by children.
    func sortedTreeOrder() -> [BookFolder] {
        sorted {
            let a = $0.fullPath.lowercased().replacingOccurrences(of: "/", with: "\0")
            let b = $1.fullPath.lowercased().replacingOccurrences(of: "/", with: "\0")
            return a < b
        }
    }
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

// MARK: - ReadingPosition (mirrored from app)

struct ReadingPosition: Codable, Hashable {
    var chapterIndex: Int
    var headingIndex: Int?
    var characterOffset: Int
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

// MARK: - Book (mirrored from app with key business logic)

struct Book: Identifiable, Codable {
    let id: UUID
    var title: String
    var author: String
    var format: BookFormat
    var filePath: String
    var md5Hash: String
    var folderPath: String
    var dateAdded: Date
    var lastOpened: Date?
    var readingPosition: ReadingPosition?
    var bookmarks: [Bookmark]
    var totalWordCount: Int?
    var totalCharacterCount: Int?
    var tmbDirectoryName: String
    var sourceFilePath: String?
    var localVoiceID: String?
    var localWPM: Double?
    var localPitch: Double?
    var skippedHeadingIDs: [String]?
    var localEndOfBookBehavior: String?
    var manualSortOrder: Int?
    var audioDuration: TimeInterval?
    var audioAlbum: String?
    var audioGenre: String?
    var audioYear: String?

    init(
        id: UUID = UUID(),
        title: String,
        author: String = "Unknown",
        format: BookFormat = .txt,
        filePath: String = "",
        md5Hash: String = "",
        folderPath: String = "",
        dateAdded: Date = Date(),
        lastOpened: Date? = nil,
        readingPosition: ReadingPosition? = nil,
        bookmarks: [Bookmark] = [],
        totalWordCount: Int? = nil,
        totalCharacterCount: Int? = nil,
        tmbDirectoryName: String = "",
        sourceFilePath: String? = nil,
        localVoiceID: String? = nil,
        localWPM: Double? = nil,
        localPitch: Double? = nil,
        skippedHeadingIDs: [String]? = nil,
        localEndOfBookBehavior: String? = nil,
        manualSortOrder: Int? = nil,
        audioDuration: TimeInterval? = nil,
        audioAlbum: String? = nil,
        audioGenre: String? = nil,
        audioYear: String? = nil
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
    }

    /// The effective WPM for this book: local override if set, otherwise the provided fallback
    func effectiveWPM(fallback: Double) -> Double {
        localWPM ?? fallback
    }

    /// Estimated time remaining in seconds, or nil if unknown.
    func estimatedTimeRemaining(wpm: Double) -> TimeInterval? {
        if format.isAudio {
            guard let duration = audioDuration, duration > 0 else { return nil }
            let speed = localWPM ?? 1.0
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
}

// MARK: - Library (mirrored from app with all operations)

struct Library: Codable {
    var books: [Book]
    var folders: [BookFolder]
    var folderSortSettings: [String: FolderSortSetting]

    init(books: [Book] = [], folders: [BookFolder] = [], folderSortSettings: [String: FolderSortSetting] = [:]) {
        self.books = books
        self.folders = folders
        self.folderSortSettings = folderSortSettings
    }

    /// Backward-compatible decoding: folderSortSettings may be absent
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        books = try container.decode([Book].self, forKey: .books)
        folders = try container.decode([BookFolder].self, forKey: .folders)
        folderSortSettings = try container.decodeIfPresent([String: FolderSortSetting].self, forKey: .folderSortSettings) ?? [:]
    }

    func sortSetting(for folderPath: String) -> FolderSortSetting {
        folderSortSettings[folderPath] ?? .defaultSort
    }

    mutating func setSortSetting(_ setting: FolderSortSetting, for folderPath: String) {
        folderSortSettings[folderPath] = setting
    }

    mutating func applySortToSubfolders(_ setting: FolderSortSetting, from folderPath: String) {
        folderSortSettings[folderPath] = setting
        for folder in folders {
            let path = folder.fullPath
            if path == folderPath || path.hasPrefix(folderPath.isEmpty ? "" : folderPath + "/") {
                if folderPath.isEmpty || path != folderPath {
                    folderSortSettings[path] = setting
                }
            }
        }
    }

    mutating func addBook(_ book: Book) {
        guard !books.contains(where: { $0.md5Hash == book.md5Hash }) else { return }
        books.append(book)
    }

    mutating func removeBook(id: UUID) {
        books.removeAll { $0.id == id }
    }

    mutating func moveBook(id: UUID, toFolder folderPath: String) {
        guard let index = books.firstIndex(where: { $0.id == id }) else { return }
        books[index].folderPath = folderPath
    }

    mutating func updateReadingPosition(bookID: UUID, position: ReadingPosition) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[index].readingPosition = position
        books[index].lastOpened = Date()
    }

    mutating func addBookmark(bookID: UUID, chapterIndex: Int, characterOffset: Int, label: String = "") {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        let nextNumber = (books[index].bookmarks.map { $0.number }.max() ?? 0) + 1
        let bookmark = Bookmark(number: nextNumber, chapterIndex: chapterIndex, characterOffset: characterOffset, label: label)
        books[index].bookmarks.append(bookmark)
    }

    mutating func removeBookmark(bookID: UUID, bookmarkID: UUID) {
        guard let bookIndex = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[bookIndex].bookmarks.removeAll { $0.id == bookmarkID }
        for i in books[bookIndex].bookmarks.indices {
            books[bookIndex].bookmarks[i].number = i + 1
        }
    }

    mutating func createFolder(name: String, parentPath: String = "") -> BookFolder? {
        let folder = BookFolder(name: name, parentPath: parentPath)
        guard folder.depth <= BookFolder.maxDepth else { return nil }
        guard !folders.contains(where: { $0.fullPath == folder.fullPath }) else { return nil }
        folders.append(folder)
        return folder
    }

    mutating func removeFolder(id: UUID, movingContentsTo destination: String = "") {
        guard let folder = folders.first(where: { $0.id == id }) else { return }
        let folderPath = folder.fullPath
        let childFolders = folders.filter {
            $0.parentPath == folderPath || $0.parentPath.hasPrefix(folderPath + "/")
        }
        for child in childFolders {
            if let idx = folders.firstIndex(where: { $0.id == child.id }) {
                if child.parentPath == folderPath {
                    folders[idx].parentPath = destination
                } else {
                    let suffix = String(child.parentPath.dropFirst(folderPath.count))
                    folders[idx].parentPath = destination.isEmpty ? String(suffix.dropFirst()) : destination + suffix
                }
            }
        }
        for i in books.indices {
            if books[i].folderPath == folderPath {
                books[i].folderPath = destination
            } else if books[i].folderPath.hasPrefix(folderPath + "/") {
                let suffix = String(books[i].folderPath.dropFirst(folderPath.count))
                books[i].folderPath = destination.isEmpty ? String(suffix.dropFirst()) : destination + suffix
            }
        }
        folders.removeAll { $0.id == id }
    }

    mutating func removeFolderAndContents(id: UUID) -> [Book] {
        guard let folder = folders.first(where: { $0.id == id }) else { return [] }
        let folderPath = folder.fullPath
        let removedBooks = books.filter {
            $0.folderPath == folderPath || $0.folderPath.hasPrefix(folderPath + "/")
        }
        books.removeAll {
            $0.folderPath == folderPath || $0.folderPath.hasPrefix(folderPath + "/")
        }
        folders.removeAll {
            $0.fullPath == folderPath || $0.fullPath.hasPrefix(folderPath + "/")
        }
        return removedBooks
    }

    @discardableResult
    mutating func moveFolder(id: UUID, toParentPath newParent: String) -> Bool {
        guard let folderIdx = folders.firstIndex(where: { $0.id == id }) else { return false }
        let folder = folders[folderIdx]
        let oldPath = folder.fullPath
        let newPath = newParent.isEmpty ? folder.name : "\(newParent)/\(folder.name)"
        guard newPath != oldPath else { return false }
        if newParent == oldPath || newParent.hasPrefix(oldPath + "/") { return false }
        let newDepth = newPath.components(separatedBy: "/").count
        guard newDepth <= BookFolder.maxDepth else { return false }
        if folders.contains(where: { $0.fullPath == newPath }) { return false }
        let depthIncrease = newDepth - oldPath.components(separatedBy: "/").count
        let maxSubfolderDepth = folders
            .filter { $0.fullPath.hasPrefix(oldPath + "/") }
            .map { $0.depth }
            .max() ?? 0
        if maxSubfolderDepth + depthIncrease > BookFolder.maxDepth { return false }
        folders[folderIdx].parentPath = newParent
        for i in folders.indices {
            if folders[i].parentPath == oldPath {
                folders[i].parentPath = newPath
            } else if folders[i].parentPath.hasPrefix(oldPath + "/") {
                folders[i].parentPath = newPath + String(folders[i].parentPath.dropFirst(oldPath.count))
            }
        }
        for i in books.indices {
            if books[i].folderPath == oldPath {
                books[i].folderPath = newPath
            } else if books[i].folderPath.hasPrefix(oldPath + "/") {
                books[i].folderPath = newPath + String(books[i].folderPath.dropFirst(oldPath.count))
            }
        }
        return true
    }

    @discardableResult
    mutating func renameFolder(id: UUID, to newName: String) -> Bool {
        let sanitized = newName.replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return false }
        guard let folderIdx = folders.firstIndex(where: { $0.id == id }) else { return false }
        let folder = folders[folderIdx]
        guard sanitized != folder.name else { return false }
        let oldPath = folder.fullPath
        let newPath = folder.parentPath.isEmpty ? sanitized : "\(folder.parentPath)/\(sanitized)"
        if folders.contains(where: { $0.fullPath == newPath }) { return false }
        folders[folderIdx].name = sanitized
        for i in folders.indices {
            if folders[i].parentPath == oldPath {
                folders[i].parentPath = newPath
            } else if folders[i].parentPath.hasPrefix(oldPath + "/") {
                folders[i].parentPath = newPath + String(folders[i].parentPath.dropFirst(oldPath.count))
            }
        }
        for i in books.indices {
            if books[i].folderPath == oldPath {
                books[i].folderPath = newPath
            } else if books[i].folderPath.hasPrefix(oldPath + "/") {
                books[i].folderPath = newPath + String(books[i].folderPath.dropFirst(oldPath.count))
            }
        }
        return true
    }

    func folderHasContents(_ folder: BookFolder) -> Bool {
        let path = folder.fullPath
        let hasBooks = books.contains {
            $0.folderPath == path || $0.folderPath.hasPrefix(path + "/")
        }
        let hasSubfolders = folders.contains { $0.parentPath == path }
        return hasBooks || hasSubfolders
    }

    func totalBooksInFolderTree(_ path: String) -> Int {
        books.filter {
            $0.folderPath == path || $0.folderPath.hasPrefix(path + "/")
        }.count
    }

    func booksInFolder(_ path: String) -> [Book] {
        books.filter { $0.folderPath == path }
    }

    func subfolders(of parentPath: String) -> [BookFolder] {
        folders.filter { $0.parentPath == parentPath }.sorted { $0.name < $1.name }
    }

    func bookByHash(_ hash: String) -> Book? {
        books.first { $0.md5Hash == hash }
    }
}

// MARK: - SleepTimerDuration (mirrored from app)

enum SleepTimerDuration: Hashable {
    case minutes(Int)
    case endOfHeading
    case endOfDocument
}

// MARK: - BookInfo (mirrored from app for persistence tests)

struct BookInfo: Codable {
    var metadata: BookMetadata
    var state: BookState
    var bookmarks: [Bookmark]

    init(metadata: BookMetadata = BookMetadata(), state: BookState = BookState(), bookmarks: [Bookmark] = []) {
        self.metadata = metadata
        self.state = state
        self.bookmarks = bookmarks
    }
}

// MARK: - ReadingStats (mirrored from app)

struct ReadingStats: Codable {
    var dailyListeningSeconds: [String: TimeInterval] = [:]
    var totalListeningSeconds: TimeInterval = 0
    var bookListeningSeconds: [String: TimeInterval] = [:]
    var finishedBooks: [FinishedBookEntry] = []
}

struct FinishedBookEntry: Codable {
    var bookID: String
    var title: String
    var dateFinished: Date
}

