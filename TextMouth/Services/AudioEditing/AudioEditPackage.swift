import AVFoundation

/// Where a book's package keeps its audio edit history (FR04), and the files
/// that history needs besides the book's own audio:
///
///     <Title>-<Author>-<date>-<ID>.tmb/
///         <Title>.m4b                       the book's audio, as last rendered
///         original-take.caf                 a recording's original, while the policy keeps it
///         audioEdits/
///             edits.json                    the edit lists (`AudioEditHistory`)
///             originals/<Title>.m4b         an imported file's original, while the policy keeps it
///             originals/audio/Disc 2/03.mp3 the original of one track of a book of several
///             takes/<ID>.caf                the replacement audio of punch-ins
///
/// Everything lives in one folder at the package root, so the code that
/// looks for a package's own content (`FileImportService.isPackageContentName`)
/// and a book of several tracks, whose tracks are found by looking through
/// its audio folder, both pass over it by its one name. A recording's take
/// stays where the Record window put it.
///
/// Every path a history records is relative to the package, and is used
/// only when it stays inside it (`url(of:in:)`), however edits.json was
/// edited.
enum AudioEditPackage {
    /// The folder at the package root holding the audio edit history.
    static let folderName = "audioEdits"
    /// The history's file name inside that folder.
    static let historyFileName = "edits.json"
    /// The folder, inside `folderName`, of imported files' originals.
    static let originalsFolderName = "originals"
    /// The folder, inside `folderName`, of punch-in takes.
    static let takesFolderName = "takes"

    /// The history's folder in the package at `package`.
    static func folder(in package: URL) -> URL {
        package.appendingPathComponent(folderName, isDirectory: true)
    }

    /// The history's file in the package at `package`.
    static func historyURL(in package: URL) -> URL {
        folder(in: package).appendingPathComponent(historyFileName)
    }

    /// The takes' folder, as a path inside the package.
    static var takesFolder: String {
        "\(folderName)/\(takesFolderName)"
    }

    /// Where the original of `audioFile`, a path inside the package, is kept
    /// once an imported book's file is first edited: under the originals
    /// folder at the same path, so it keeps the file's own name and
    /// extension, which AVFoundation reads it by.
    static func originalFile(forAudioFile audioFile: String) -> String {
        "\(folderName)/\(originalsFolderName)/\(audioFile)"
    }

    // MARK: Paths Inside the Package

    /// Whether `path` names a place inside a package: relative, not empty,
    /// and without an empty, ".", or ".." component that could make it reach
    /// elsewhere.
    static func isInsidePackage(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// The URL of `path` inside the package at `package`, or nil when the path
    /// could reach outside it (`isInsidePackage(_:)`).
    static func url(of path: String, in package: URL) -> URL? {
        guard isInsidePackage(path) else { return nil }
        return package.appendingPathComponent(path)
    }

    /// The path of `file` inside the package at `package`, or nil when the
    /// file is not inside it. Both are compared with links resolved, as
    /// Foundation may spell a folder under /var as /private/var.
    static func path(of file: URL, in package: URL) -> String? {
        let base = package.resolvingSymlinksInPath().standardizedFileURL.path
        let full = file.resolvingSymlinksInPath().standardizedFileURL.path
        guard full.hasPrefix(base + "/") else { return nil }
        let relative = String(full.dropFirst(base.count + 1))
        return isInsidePackage(relative) ? relative : nil
    }

    // MARK: Keeping an Original

    /// Keeps a copy of `audioFile`, a path inside the package at `package`,
    /// as it is now, as that file's original, edited at `date`. On APFS the
    /// copy is a clone, which takes no space until the book's file is
    /// replaced. An earlier original whose record was lost (its history
    /// damaged) is never overwritten: this one takes the next free name.
    /// - Throws: `AudioEditError.fileOutsidePackage` for a path that could
    ///   reach elsewhere, or the copy's error.
    static func keepOriginal(ofAudioFile audioFile: String, inPackage package: URL, at date: Date) throws -> AudioOriginal {
        guard let source = url(of: audioFile, in: package) else {
            throw AudioEditError.fileOutsidePackage
        }
        let path = freePath(startingFrom: originalFile(forAudioFile: audioFile), in: package)
        let destination = package.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: source, to: destination)
        return AudioOriginal(file: path, lastEditedAt: date)
    }

    /// Removes the podcast chapters set aside in the package at `package`
    /// (`TextMouthPaths.podcastChaptersSetAsideFileName`), because the audio
    /// they were timed to, the original of the history that set them aside, is
    /// no longer what an undo of every edit reaches: the history started
    /// over. Nothing set aside is no error and says nothing; one that cannot
    /// be removed is left, with one line in the debug log naming the error's
    /// code and domain.
    static func discardSetAsidePodcastChapters(inPackage package: URL) {
        let url = TextMouthPaths.podcastChaptersSetAsidePath(in: package)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
            DiagnosticLog.event(
                .storage,
                "PODCAST_CHAPTERS_DISCARDED: the audio's edit history started over, so the chapters set aside no longer fit"
            )
        } catch {
            let failure = error as NSError
            DiagnosticLog.event(
                .storage,
                "PODCAST_CHAPTERS_LEFT: the chapters set aside could not be discarded: error \(failure.code) in \(failure.domain)"
            )
        }
    }

    /// `path`, or, when something is already there, the first of
    /// "<name> 2.<ext>", "<name> 3.<ext>", … that is free.
    private static func freePath(startingFrom path: String, in package: URL) -> String {
        var candidate = path
        var number = 2
        while FileManager.default.fileExists(atPath: package.appendingPathComponent(candidate).path) {
            let file = path as NSString
            let stem = file.deletingPathExtension
            let ext = file.pathExtension
            candidate = ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)"
            number += 1
        }
        return candidate
    }

    // MARK: Takes

    /// Keeps the audio at `source`, a punch-in's take, in the package at
    /// `package`, and returns its path there. The version control keeps its
    /// changes compressed where that loses nothing: a take of integer samples
    /// of up to 24 bits, as the Record window writes, is stored as Apple
    /// Lossless, about half the size, decoding to the very same samples. A
    /// take of floating-point samples, which Apple Lossless cannot hold, or
    /// one already compressed, is copied as it is.
    /// - Throws: the error reading or writing the audio; nothing is left in
    ///   the package after a failure.
    static func keepTake(from source: URL, inPackage package: URL) throws -> String {
        let folder = package.appendingPathComponent(takesFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let input = try AVAudioFile(forReading: source)
        let stored = streamDescription(of: input.fileFormat)
        let isIntegerPCM = stored.mFormatID == kAudioFormatLinearPCM
            && stored.mFormatFlags & kAudioFormatFlagIsFloat == 0
        let bits = Int(stored.mBitsPerChannel)

        let name = UUID().uuidString
        guard isIntegerPCM, [16, 20, 24].contains(bits) else {
            let ext = source.pathExtension.isEmpty ? "caf" : source.pathExtension
            let path = "\(takesFolder)/\(name).\(ext)"
            try FileManager.default.copyItem(at: source, to: package.appendingPathComponent(path))
            return path
        }

        let path = "\(takesFolder)/\(name).caf"
        let destination = package.appendingPathComponent(path)
        do {
            try compress(input, bits: bits, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return path
    }

    /// Writes all of `input` to `destination` as Apple Lossless in a CAF
    /// file, at its own rate and channels, `bits` bits a sample, a second at
    /// a time. Integer samples of up to 24 bits pass through the float
    /// processing format exactly, since a float holds 24 bits of mantissa.
    private static func compress(_ input: AVAudioFile, bits: Int, to destination: URL) throws {
        let format = input.processingFormat
        let output = try AVAudioFile(
            forWriting: destination,
            settings: [
                AVFormatIDKey: kAudioFormatAppleLossless,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderBitDepthHintKey: bits,
            ],
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        let chunk = AVAudioFrameCount(max(format.sampleRate, 4_096))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw AudioEditError.unreadableAudio
        }
        while input.framePosition < input.length {
            try input.read(into: buffer, frameCount: chunk)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
        }
    }

    /// The stream description of `format`, copied while the format is kept
    /// alive: the pointer `AVAudioFormat.streamDescription` gives points into
    /// the format, which Swift may release as soon as the pointer is read.
    static func streamDescription(of format: AVAudioFormat) -> AudioStreamBasicDescription {
        withExtendedLifetime(format) { format.streamDescription.pointee }
    }

    /// Deletes every take in the package at `package` that no edit the
    /// history `history` can still apply uses (`AudioEditHistory.takesInUse`):
    /// those of edits discarded after an undo, and those the audio the edits
    /// start from already holds. Returns how many it deleted.
    @discardableResult
    static func removeUnusedTakes(of history: AudioEditHistory, inPackage package: URL) -> Int {
        let folder = package.appendingPathComponent(takesFolder, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return 0 }
        let inUse = history.takesInUse
        var removed = 0
        for name in names where !name.hasPrefix(".") && !inUse.contains("\(takesFolder)/\(name)") {
            if (try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))) != nil {
                removed += 1
            }
        }
        return removed
    }
}
