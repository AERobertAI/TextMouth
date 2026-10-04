import AVFoundation

// MARK: - Where Takes Are Recorded

extension MachineLocalPaths {
    /// Takes being recorded, and takes not yet saved as books: this Mac's
    /// own, on the startup volume, never synced, and inside the sandbox
    /// under hosted tests. A take saved as a book is copied into the book's
    /// package and removed from here.
    static var recordings: URL {
        root.appendingPathComponent("Recordings", isDirectory: true)
    }
}

// MARK: - A Take

/// One take: the file a recording wrote, 16-bit linear PCM in a Core Audio
/// Format (CAF) file, the one format the research found still readable
/// after a recording is cut off as a crash would cut it, and what is known
/// about it.
struct RecordedTake: Equatable, Sendable {
    /// The take's CAF file.
    let url: URL
    /// When recording started.
    let startedAt: Date
    /// How long the take lasts, in seconds, pauses left out.
    let duration: TimeInterval
    /// The name of the microphone it was recorded from.
    let deviceName: String
}

/// Naming, measuring, and removing the files takes are recorded into.
enum RecordingTakeFiles {
    /// The extension of every take's file.
    static let fileExtension = "caf"

    /// A new take's file in `folder`, which is created when missing, named
    /// for when the take started, as "Take 2026-10-04 06.30.12 1A2B3C4D.caf",
    /// so a person looking in the folder can tell takes apart. The last
    /// part keeps two takes started in the same second apart: capture
    /// refuses to record into a file that exists.
    static func newTakeURL(startedAt: Date, in folder: URL = MachineLocalPaths.recordings) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let suffix = UUID().uuidString.prefix(8)
        return folder.appendingPathComponent("Take \(formatter.string(from: startedAt)) \(suffix).\(fileExtension)")
    }

    /// How long the audio in the take file at `url` lasts, in seconds, read
    /// from the file itself; nil when it cannot be read as audio.
    static func duration(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    /// Removes the take file at `url`, if it is there.
    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
