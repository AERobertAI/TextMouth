import Foundation

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
