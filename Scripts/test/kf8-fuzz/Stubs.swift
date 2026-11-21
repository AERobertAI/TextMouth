import Foundation

// Stand-ins for the app types the Kindle reader and the shared converter touch but `build-reader.py` does not
// compile: the app's models, its import errors, its cancellation, and its logging. Nothing here reads a file.

enum FileImportError: LocalizedError {
    case noTextToRead
    var errorDescription: String? { "This file has no text to read." }
}

struct DocumentContent {
    var title: String
    var author: String
    var chapters: [Chapter]
}

enum Book {
    static let unknownAuthor = "Unknown"
    static func isUnknownAuthor(_ author: String) -> Bool { author.isEmpty || author == unknownAuthor }
}

enum FileImportService {
    static func md5Hash(of url: URL) throws -> String { "" }
}

enum KFXParser {
    static func prepareBook(bytes: [UInt8], fallbackTitle: String, includesPages: Bool, near url: URL) throws -> MOBIParser.PreparedBook {
        throw FileImportError.noTextToRead
    }
    static func readMetadata(bytes: [UInt8], near url: URL) throws -> MOBIBook.Metadata {
        throw FileImportError.noTextToRead
    }
}

enum TextFileDecoder {
    static func windows1252Text(_ data: Data) -> String {
        String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }
}

enum BookFormat {
    case audio
    var fileExtensions: [String] { [] }
}

enum DiagnosticLog {
    enum Category { case `import` }
    static func event(_ category: Category, _ message: String) {}
}

enum ReaderViewModel {
    static func snappedWordStart(in text: String, at offset: Int) -> Int { offset }
}

enum CountWording {
    static func phrase(_ count: Int, singular: String, plural: String) -> String { "\(count) \(count == 1 ? singular : plural)" }
    static func list(_ items: [String]) -> String { items.joined(separator: ", ") }
}

struct ImportCancelled: Error, Equatable {}
final class ImportCancellation {
    @TaskLocal static var current: ImportCancellation? = nil
    var isCancelled = false
    func cancel() { isCancelled = true }
    static func throwIfCancelled() throws { if current?.isCancelled == true { throw ImportCancelled() } }
}

