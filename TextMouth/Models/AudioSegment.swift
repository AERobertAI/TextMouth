import Foundation

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
