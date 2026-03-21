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
