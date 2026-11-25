import Foundation
@testable import TextMouth

/// Small makers shared by the sync tests (FR43): books, folders, entries, and
/// registers, so each test says only what it is about. Nothing here touches a
/// folder on disk.
enum SyncTestFixtures {
    /// A text book with a made-up file and hash.
    static func book(
        id: UUID = UUID(), title: String = "A Book", author: String = "An Author", md5: String? = nil, folderPath: String = ""
    ) -> Book {
        Book(
            id: id, title: title, author: author, format: .epub, filePath: "/Users/reader/\(id.uuidString).epub",
            md5Hash: md5 ?? id.uuidString, folderPath: folderPath,
            dateAdded: Date(timeIntervalSince1970: 1_000), tmbDirectoryName: id.uuidString
        )
    }

    /// The ID `number` makes: the same ID every run, so a printed seed or a failure replays.
    static func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llX", UInt64(abs(number % 1_000_000_000))))
            ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
    }

    /// An entry for `key` stamped at `wall` milliseconds by `device`.
    static func entry(
        _ key: SyncKey, _ value: JSONValue, wall: Int64, counter: UInt32 = 0, device: String = "a", byHand: Bool = false
    ) -> SyncEntry {
        SyncEntry(key: key, value: value, stamp: SyncStamp(wall: wall, counter: counter, device: device), byHand: byHand)
    }

    /// Registers that hold `entries`.
    static func registers(_ entries: [SyncEntry]) -> SyncRegisters {
        var registers = SyncRegisters()
        registers.merge(entries)
        return registers
    }

    /// The content a device that lacks `book` makes its row from.
    static func content(of book: Book, manifest: String = "m1") -> SyncContent {
        SyncContent(
            manifest: manifest, format: book.format, dateAdded: book.dateAdded, md5Hash: book.md5Hash,
            totalWordCount: 1_000, audioDuration: nil
        )
    }

    /// The entries that say a book is there, with its content, as another device records one.
    static func presence(of book: Book, wall: Int64, device: String = "b") -> [SyncEntry] {
        [
            entry(.book(book.id, .presence), .bool(true), wall: wall, device: device),
            entry(.book(book.id, .content), SyncValueCoding.json(content(of: book)), wall: wall, device: device),
            entry(.book(book.id, .title), .string(book.title), wall: wall, device: device),
        ]
    }

    /// A library of `books` and `folders`.
    static func library(books: [Book] = [], folders: [BookFolder] = []) -> Library {
        var library = Library()
        library.books = books
        library.folders = folders
        return library
    }
}
