import Foundation

/// Editable and read-only EPUB metadata
struct EPUBMetadata {
    // Editable fields
    var title: String
    var author: String
    var publisher: String
    var publicationDate: String

    // Read-only fields
    var isbn: String
    var language: String
    var identifier: String
    var epubVersion: String
}
