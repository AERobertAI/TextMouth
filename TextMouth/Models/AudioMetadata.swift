import Foundation

/// Editable and read-only metadata extracted from audio files (MP3, M4A, M4B, etc.).
/// Mirrors the structure of EPUBMetadata for consistency in the metadata editor.
struct AudioMetadata: Codable {
    // Editable fields
    var title: String
    var artist: String
    var album: String
    var genre: String
    var year: String

    // Read-only fields (extracted from file, not user-editable)
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
