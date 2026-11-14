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
    /// The name of the microphone it was recorded from; empty when it is
    /// not known, as for a take left behind (`RecoveredTake`).
    let deviceName: String
}

// MARK: - A Take Left Behind

/// A take a recording left in this Mac's Recordings folder that no window
/// owns (FR04), neither the Record window nor an audio editor recording a
/// punch-in (`RecordingService.takesInUse`): one a crash or a forced quit
/// cut off, which its format keeps readable up to where it stopped, or one
/// whose save failed after its window closed. The Record window lists each
/// under "Recovered recordings", to save as an audiobook or to discard;
/// nothing deletes one on its own.
struct RecoveredTake: Identifiable, Equatable, Sendable {
    /// The take's file.
    let url: URL
    /// When recording started, read from the file's name, or, for a name of
    /// another form, the file's creation date.
    let startedAt: Date
    /// How long its audio lasts, in seconds; nil when no audio can be read
    /// from it, as from a take cut off before any sound reached its file.
    let duration: TimeInterval?

    var id: URL { url }

    /// The take, to save as an audiobook; nil when it holds no audio. Which
    /// microphone recorded it is not known.
    var take: RecordedTake? {
        guard let duration, duration > 0 else { return nil }
        return RecordedTake(url: url, startedAt: startedAt, duration: duration, deviceName: "")
    }
}

// MARK: - Take Files

/// Naming, measuring, finding, and removing the files takes are recorded
/// into.
enum RecordingTakeFiles {
    /// The extension of every take's file.
    static let fileExtension = "caf"

    /// What every take's name starts with, before when it started.
    private static let namePrefix = "Take "

    /// How a take's name gives when it started: to the second, in this Mac's
    /// time zone, with dots between the hours, minutes, and seconds, as a
    /// name may not hold a colon.
    private static let nameDateFormat = "yyyy-MM-dd HH.mm.ss"

    /// The formatter of the start in a take's name, in the format above.
    private static func nameDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = nameDateFormat
        return formatter
    }

    /// A new take's file in `folder`, which is created when missing, named
    /// for when the take started, as "Take 2026-10-04 06.30.12 1A2B3C4D.caf",
    /// so a person looking in the folder can tell takes apart. The last
    /// part keeps two takes started in the same second apart: capture
    /// refuses to record into a file that exists.
    static func newTakeURL(startedAt: Date, in folder: URL = MachineLocalPaths.recordings) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suffix = UUID().uuidString.prefix(8)
        let name = "\(namePrefix)\(nameDateFormatter().string(from: startedAt)) \(suffix).\(fileExtension)"
        return folder.appendingPathComponent(name)
    }

    /// When the take named `name` started, read from its name in this Mac's
    /// time zone, as the name was written (`newTakeURL`); nil for a name of
    /// another form.
    static func startDate(fromName name: String) -> Date? {
        guard name.hasPrefix(namePrefix) else { return nil }
        let date = name.dropFirst(namePrefix.count).prefix(nameDateFormat.count)
        return nameDateFormatter().date(from: String(date))
    }

    /// The file a take's save encodes it into, beside the take, before the
    /// book's import copies it into the package.
    static func encodingURL(for take: URL) -> URL {
        take.deletingPathExtension().appendingPathExtension("m4a")
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

    // MARK: Takes Left Behind

    /// The takes in `folder`, every take file there but those named in
    /// `owned`, oldest first, each with when it started and how long it
    /// lasts, read from its file. Hidden files and files of other kinds are
    /// left out, among them the encoding a save cut off left beside its take.
    /// Deletes nothing. Reads files: call it off the main thread.
    static func leftovers(in folder: URL = MachineLocalPaths.recordings, excluding owned: Set<URL> = []) -> [RecoveredTake] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let ownedPaths = Set(owned.map(path(of:)))
        return names
            .filter { !$0.hasPrefix(".") && ($0 as NSString).pathExtension.lowercased() == fileExtension }
            .sortedStably()
            .map { folder.appendingPathComponent($0) }
            .filter { !ownedPaths.contains(path(of: $0)) }
            .map { RecoveredTake(url: $0, startedAt: startDate(of: $0), duration: duration(of: $0)) }
            .sortedStably { $0.startedAt < $1.startedAt }
    }

    /// `leftovers(in:excluding:)`, read on a thread of its own, so the main
    /// thread never waits on the files.
    static func readLeftovers(in folder: URL = MachineLocalPaths.recordings) async -> [RecoveredTake] {
        await Task.detached(priority: .utility) { leftovers(in: folder) }.value
    }

    /// When the take at `url` started: from its name, or else when its file
    /// was created, or else last changed.
    private static func startDate(of url: URL) -> Date {
        if let date = startDate(fromName: url.lastPathComponent) {
            return date
        }
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate ?? Date(timeIntervalSince1970: 0)
    }

    /// `url`'s path with links resolved, as two spellings of one file, such
    /// as /var and /private/var, compare.
    private static func path(of url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
