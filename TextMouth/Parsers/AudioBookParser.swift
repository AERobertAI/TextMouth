import Foundation

/// Parses audio files into DocumentContent for the reader.
/// For single audio files: extracts chapter markers if available (M4B), otherwise single chapter.
/// For multi-file audio books (from ZIP): each file becomes a chapter.
enum AudioBookParser {

    static func placeholderLength(for duration: TimeInterval) -> Int {
        max(1, Int(duration * ReaderViewModel.audioCharsPerSecond))
    }

    static func time(forCharacterOffset offset: Int) -> TimeInterval {
        Double(offset) / ReaderViewModel.audioCharsPerSecond
    }

    static func characterOffset(forTime time: TimeInterval) -> Int {
        Int(time * ReaderViewModel.audioCharsPerSecond)
    }

    /// Respect an explicit order without repeating a file when a manifest lists
    /// it twice; append unlisted files in Finder-style numeric order.
    static func orderedFileNames(_ names: [String], manifestOrder: [String]? = nil) -> [String] {
        let alphabetical = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard let manifestOrder, !manifestOrder.isEmpty else { return alphabetical }
        let available = Set(names)
        var seen = Set<String>()
        let requested = manifestOrder.filter { available.contains($0) && seen.insert($0).inserted }
        let requestedSet = Set(requested)
        return requested + alphabetical.filter { !requestedSet.contains($0) }
    }

    /// Find the same playable candidates during import and reader loading.
    /// ZIPs commonly contain a wrapper folder; AppleDouble sidecars and symbolic
    /// links are not chapters, even when their names have an audio extension.
    static func audioFiles(in directory: URL) throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else { throw AudioParseError.noAudioFiles }

        let extensions = Set(BookFormat.audio.fileExtensions)
        var files: [URL] = []
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: keys)
            if file.lastPathComponent == "__MACOSX" || values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if values.isRegularFile == true, extensions.contains(file.pathExtension.lowercased()) {
                files.append(file)
            }
        }
        if let enumerationError { throw enumerationError }
        return files.sorted {
            relativeName(of: $0, in: directory).localizedStandardCompare(
                relativeName(of: $1, in: directory)
            ) == .orderedAscending
        }
    }

    /// Manifest filenames are relative to the audio directory, so tracks with
    /// the same basename on different discs remain distinct.
    private static func relativeName(of file: URL, in directory: URL) -> String {
        // Foundation may return /private/var for a directory supplied as /var.
        // Compare canonical paths before removing the base-directory prefix.
        let basePath = directory.resolvingSymlinksInPath().path
        return String(file.resolvingSymlinksInPath().path.dropFirst(basePath.count + 1))
    }

    /// Parse a single audio file. Extracts chapters from M4B metadata if available.
    /// - Parameter prober: checks that the file plays and measures it; the
    ///   app's AVFoundation probe unless a test stands in for it.
    /// - Throws: `AudioParseError.unplayableFile` naming the file when it
    ///   cannot be played (see `AudioMediaProbe`).
    static func parse(url: URL, prober: AudioMediaProber = .avFoundation) async throws -> DocumentContent {
        // One file in, one duration out.
        let totalSeconds = try await playableDurations(
            of: [(name: url.lastPathComponent, url: url)],
            prober: prober
        )[0]

        // Try to extract metadata
        let metadata = await AudioPlaybackService.extractMetadata(from: url)
        let title = metadata.title ?? url.deletingPathExtension().lastPathComponent
        let author = metadata.artist ?? "Unknown"

        // Try to extract chapter markers
        let chapters = await AudioPlaybackService.extractChapters(from: url)

        if chapters.isEmpty {
            // Single chapter for the whole file
            // Use a placeholder text with duration info for character-based position tracking
            let placeholderLength = placeholderLength(for: totalSeconds)
            let placeholderText = String(repeating: " ", count: max(1, placeholderLength))

            let chapter = Chapter(
                title: title,
                text: placeholderText,
                headings: [Heading(level: 1, text: title, chapterIndex: 0, characterOffset: 0)]
            )
            return DocumentContent(title: title, author: author, chapters: [chapter])
        } else {
            // Multiple chapters from metadata
            var parsedChapters: [Chapter] = []
            for (index, ch) in chapters.enumerated() {
                let chDuration = ch.duration > 0 ? ch.duration : 1
                let placeholderLength = placeholderLength(for: chDuration)
                let placeholderText = String(repeating: " ", count: max(1, placeholderLength))

                let heading = Heading(level: 1, text: ch.title, chapterIndex: index, characterOffset: 0)
                parsedChapters.append(Chapter(
                    title: ch.title,
                    text: placeholderText,
                    headings: [heading]
                ))
            }
            return DocumentContent(title: title, author: author, chapters: parsedChapters)
        }
    }

    /// Parse a directory of audio files as a multi-chapter audio book.
    /// Files are ordered alphabetically unless a manifest.json is found.
    /// - Parameter prober: checks that each file plays and measures it,
    ///   probing each file once; the app's AVFoundation probe unless a test
    ///   stands in for it.
    /// - Returns: the book's content, one file path per heading (for a
    ///   section of several clips, its first clip's file), and, for a
    ///   manifest with sections, the sections as the book plays them: a
    ///   clip's end slightly past its file's end is moved back to that end
    ///   (see `endTolerance(forFileLasting:)`).
    /// - Throws: `AudioParseError.unplayableFile` naming the first file, in
    ///   playing order, that cannot be played; `.invalidSegment` for a
    ///   manifest clip with a missing file or impossible times; and, for a
    ///   clip whose times do not fit its file, the section errors
    ///   `boundedSegments(_:fileDurations:)` describes.
    static func parseDirectory(
        url: URL,
        prober: AudioMediaProber = .avFoundation
    ) async throws -> (content: DocumentContent, filePaths: [String], segments: [AudioSegment]?) {
        let fm = FileManager.default
        var audioFiles = try Self.audioFiles(in: url)

        guard !audioFiles.isEmpty else {
            throw AudioParseError.noAudioFiles
        }

        // Check for manifest.json
        let manifestURL = url.appendingPathComponent("manifest.json")
        var chapterTitles: [String: String] = [:] // filename -> title

        var manifest: AudioManifest?
        if fm.fileExists(atPath: manifestURL.path),
           let data = try? Data(contentsOf: manifestURL) {
            manifest = try? JSONDecoder().decode(AudioManifest.self, from: data)
            chapterTitles = manifest?.chapters ?? [:]
            if let order = manifest?.order, !order.isEmpty {
                // Reorder files according to manifest
                let filesByName = Dictionary(uniqueKeysWithValues: audioFiles.map {
                    (relativeName(of: $0, in: url), $0)
                })
                audioFiles = orderedFileNames(Array(filesByName.keys), manifestOrder: order)
                    .compactMap { filesByName[$0] }
            }
        }

        let overallTitle = manifest?.title ?? url.lastPathComponent
        let overallAuthor = manifest?.author ?? "Unknown"

        // If manifest has segments (DAISY-style sub-file chapters), use those
        // instead of the one-file-per-chapter model
        if let segments = manifest?.segments, !segments.isEmpty {
            let result = try await parseSegmentedAudio(
                segments: segments,
                audioDir: url,
                availableFiles: Set(audioFiles.map { relativeName(of: $0, in: url) }),
                title: overallTitle,
                author: overallAuthor,
                prober: prober
            )
            return (content: result.content, filePaths: result.filePaths, segments: result.segments)
        }

        var chapters: [Chapter] = []
        var filePaths: [String] = []

        // Every track is checked and measured before any becomes a heading,
        // so a damaged track fails the whole book, by its name in the book.
        let tracks = audioFiles.map { (name: relativeName(of: $0, in: url), url: $0) }
        let durations = try await playableDurations(of: tracks, prober: prober)

        for (index, (track, duration)) in zip(tracks, durations).enumerated() {
            let title = chapterTitles[track.name] ?? track.url.deletingPathExtension().lastPathComponent
            let placeholderText = String(repeating: " ", count: max(1, placeholderLength(for: duration)))

            let heading = Heading(level: 1, text: title, chapterIndex: index, characterOffset: 0)
            chapters.append(Chapter(
                title: title,
                text: placeholderText,
                headings: [heading]
            ))
            filePaths.append(track.url.path)
        }

        let content = DocumentContent(title: overallTitle, author: overallAuthor, chapters: chapters)
        return (content: content, filePaths: filePaths, segments: nil)
    }

    /// Parse segmented audio where chapters are time ranges within audio files.
    /// Each segment plays one or more clips, each a file + start/end time, in
    /// order. Segments referencing the same file become chapters that share
    /// the underlying audio, with playback controlled by clip start/end
    /// times. Returns the segments as the book plays them (see
    /// `boundedSegments(_:fileDurations:)`).
    private static func parseSegmentedAudio(
        segments: [AudioSegment],
        audioDir: URL,
        availableFiles: Set<String>,
        title: String,
        author: String,
        prober: AudioMediaProber
    ) async throws -> (content: DocumentContent, filePaths: [String], segments: [AudioSegment]) {
        // Every clip of every section, in the order the book plays them.
        let clips = segments.flatMap(\.clips)

        // Only reference discovered in-package media. A manifest cannot
        // escape the package or introduce negative/non-finite clip ranges.
        // Every clip is checked before any file is opened, so a path the
        // manifest made up never reaches AVFoundation.
        for clip in clips {
            guard availableFiles.contains(clip.file),
                  clip.startTime.isFinite, clip.startTime >= 0,
                  clip.endTime.isFinite, clip.endTime >= 0,
                  clip.endTime == 0 || clip.endTime > clip.startTime else {
                throw AudioParseError.invalidSegment
            }
        }

        // Check and measure each file the clips play from. A file that
        // several clips share is probed once, and they share its length.
        let measured = try await playableDurations(
            of: clips.map { (name: $0.file, url: audioDir.appendingPathComponent($0.file)) },
            prober: prober
        )
        let fileDurations = Dictionary(zip(clips.map(\.file), measured)) { first, _ in first }

        // Fit every clip to its file before any section becomes a heading.
        let bounded = try boundedSegments(segments, fileDurations: fileDurations)

        var chapters: [Chapter] = []
        var filePaths: [String] = []

        for (index, segment) in bounded.segments.enumerated() {
            // A section starts in its first clip's file.
            let filePath = audioDir.appendingPathComponent(segment.file).path

            // A section lasts as long as its clips together, and each clip
            // a positive time: it starts before its file ends, and any end
            // other than 0 ("play to the end of the file") lies after its
            // start and within the file.
            let duration = segment.clips.reduce(0) { total, clip in
                let end = clip.endTime == 0 ? fileDurations[clip.file, default: 0] : clip.endTime
                return total + (end - clip.startTime)
            }

            let placeholderLength = placeholderLength(for: max(1, duration))
            let placeholderText = String(repeating: " ", count: max(1, placeholderLength))

            let heading = Heading(level: 1, text: segment.title,
                                  chapterIndex: index, characterOffset: 0)
            chapters.append(Chapter(
                title: segment.title,
                text: placeholderText,
                headings: [heading]
            ))
            filePaths.append(filePath)
        }

        // Moved ends are recorded only once the whole book has parsed, so
        // a book refused for another reason leaves no misleading record.
        for clamped in bounded.clampedFiles {
            clamped.log(bookTitle: title)
        }

        let content = DocumentContent(title: title, author: author, chapters: chapters)
        return (content: content, filePaths: filePaths, segments: bounded.segments)
    }

    // MARK: - Section Bounds

    /// The tag that starts the debug-log line recording sections whose ends
    /// ran past their file's end and were moved back to it.
    static let clampLogTag = "AUDIO_SEGMENT_CLAMPED"

    /// Seconds any section may end past the measured end of its file.
    static let endToleranceSeconds: TimeInterval = 1

    /// The share of its file's length a section may end past the file's
    /// end, on top of `endToleranceSeconds`.
    static let endToleranceFraction = 0.01

    /// How far past the measured end of a file lasting `fileDuration`
    /// seconds a section may claim to end and still be accepted, with its
    /// end moved back to the file's end: one second plus one percent of the
    /// file.
    ///
    /// DAISY producers time each clip against the recording before it is
    /// encoded, and DAISY audio is mostly MP3. Encoding adds a delay before
    /// the audio and padding after it (LAME, the usual MP3 encoder, delays
    /// by 576 samples and pads to a whole frame; AAC encoders commonly
    /// prime with 2,112 samples, per Apple's TN2258), and decoders may trim
    /// them again. A clip's end can therefore lie past the encoded file's
    /// measured end by up to about a tenth of a second at the low sample
    /// rates audiobooks use, and by more where a producer rounds clip times
    /// up. The DAISY Consortium's own validator accepts audio whose
    /// duration differs from the book's declared timing by up to half a
    /// second (DAISY Pipeline 2, daisy202-validator, option
    /// timeToleranceMs, default 500: "The duration of the audio files can
    /// deviate from the duration declared in the DAISY 2.02 fileset by
    /// this many milliseconds"). One second is twice that. The one percent
    /// covers timing that drifts along a long file, as clip times computed
    /// from a nominal bit rate or sample rate do: 36 seconds over an hour.
    /// An end beyond that is not padding but navigation made for other
    /// audio, such as an end an hour past the end of a ten-minute file.
    static func endTolerance(forFileLasting fileDuration: TimeInterval) -> TimeInterval {
        endToleranceSeconds + endToleranceFraction * fileDuration
    }

    /// `segments` as the book will play them, each clip checked against the
    /// measured length of its file (`fileDurations`, by the file's path in
    /// the audio folder; it holds every file a clip names). The first
    /// problem in book order is thrown, naming the section and the clip's
    /// file:
    ///
    /// - Every clip must start before its file ends; otherwise
    ///   `AudioParseError.sectionStartsPastEnd`.
    /// - A clip may end past its file's end by up to
    ///   `endTolerance(forFileLasting:)`, which covers encoder padding. Its
    ///   end is then moved back to exactly the file's end, and the move is
    ///   reported once per file in `clampedFiles`. An end further out is
    ///   `AudioParseError.sectionEndsPastEnd`. An end of 0 keeps its
    ///   meaning, "play to the end of the file", in a section of one clip.
    ///   In a section of several it becomes the file's measured end, so
    ///   every clip has a known length and playback can tell where in the
    ///   section each clip begins.
    /// - Within one file, each section must start at or after the start of
    ///   the section before it in that file; otherwise
    ///   `AudioParseError.sectionStartsBeforeEarlierSection`. A section
    ///   starts where its first clip does. Navigation in
    ///   reading order never goes back within a file, so a section that
    ///   does was timed against other audio or names the wrong file, and
    ///   the listener would hear the book out of order. Sections may
    ///   overlap, though: the DAISY converter ends a heading at the last
    ///   clip of its file in its SMIL file when the next heading plays from
    ///   another file, so a later heading in the first file can start
    ///   inside it. Overlap repeats audio but never loses any, and refusing
    ///   it would refuse such books. The later clips of a section are not
    ///   compared: a section may return to an earlier part of a file, as a
    ///   note recorded at the end of a file interrupts the text before it.
    private static func boundedSegments(
        _ segments: [AudioSegment],
        fileDurations: [String: TimeInterval]
    ) throws -> (segments: [AudioSegment], clampedFiles: [ClampedFile]) {
        var bounded: [AudioSegment] = []
        // In the order the files' first clips were moved back.
        var clampedFiles: [ClampedFile] = []
        // The latest section so far in each file, which, as starts never go
        // back within a file, starts last of that file's sections so far.
        var latestSectionInFile: [String: (name: AudioSectionName, start: TimeInterval)] = [:]

        for (index, segment) in segments.enumerated() {
            let name = AudioSectionName(title: segment.title, number: index + 1)
            let playsSeveralClips = segment.clips.count > 1

            let playable = try segment.mappingClips { clip in
                // Every file a clip names was measured before any section
                // is bounded, so the default never applies.
                let fileDuration = fileDurations[clip.file, default: 0]
                guard clip.startTime < fileDuration else {
                    throw AudioParseError.sectionStartsPastEnd(
                        section: name, file: clip.file, start: clip.startTime, fileDuration: fileDuration
                    )
                }

                var fitted = clip
                if clip.endTime > fileDuration {
                    guard clip.endTime <= fileDuration + endTolerance(forFileLasting: fileDuration) else {
                        throw AudioParseError.sectionEndsPastEnd(
                            section: name, file: clip.file, end: clip.endTime, fileDuration: fileDuration
                        )
                    }
                    fitted.endTime = fileDuration
                    let overshoot = clip.endTime - fileDuration
                    if let place = clampedFiles.firstIndex(where: { $0.file == clip.file }) {
                        clampedFiles[place].sectionCount += 1
                        clampedFiles[place].largestOvershoot = max(clampedFiles[place].largestOvershoot, overshoot)
                    } else {
                        clampedFiles.append(ClampedFile(
                            file: clip.file, fileDuration: fileDuration, sectionCount: 1, largestOvershoot: overshoot
                        ))
                    }
                } else if clip.endTime == 0, playsSeveralClips {
                    fitted.endTime = fileDuration
                }
                return fitted
            }

            if let earlier = latestSectionInFile[segment.file], segment.startTime < earlier.start {
                throw AudioParseError.sectionStartsBeforeEarlierSection(
                    section: name, file: segment.file, start: segment.startTime,
                    earlierSection: earlier.name, earlierStart: earlier.start
                )
            }
            latestSectionInFile[segment.file] = (name: name, start: segment.startTime)
            bounded.append(playable)
        }
        return (segments: bounded, clampedFiles: clampedFiles)
    }

    /// The sections of one file whose ends ran past the file's measured
    /// end, within the tolerance, and were moved back to it.
    private struct ClampedFile {
        /// The file's path inside the book's audio folder.
        let file: String
        /// How long the file plays, in seconds.
        let fileDuration: TimeInterval
        /// How many of its sections were moved back.
        var sectionCount: Int
        /// The furthest any of them ran past the file's end, in seconds.
        var largestOvershoot: TimeInterval

        /// Record the move in the console and the debug log, as the single
        /// line `AUDIO_SEGMENT_CLAMPED: <book>: <file>: moved 2 sections'
        /// ends back to the file's measured end of 600.000 s, from up to
        /// 0.400 s past it`. A line break in the book's title or the file's
        /// name becomes a space, so the entry stays on one line.
        func log(bookTitle: String) {
            let ends = sectionCount == 1 ? "1 section's end" : "\(sectionCount) sections' ends"
            let distance = sectionCount == 1 ? "from" : "from up to"
            let line = "\(AudioBookParser.clampLogTag): \(bookTitle): \(file): moved \(ends) back to "
                + "the file's measured end of " + String(format: "%.3f", fileDuration) + " s, "
                + "\(distance) " + String(format: "%.3f", largestOvershoot) + " s past it"
            let singleLine = line.components(separatedBy: .newlines).joined(separator: " ")
            print(singleLine)
            TextMouthPaths.appendLog(to: TextMouthPaths.debugLogFile, message: singleLine)
        }
    }

    /// How long each of `files` plays, in the same order, as `prober`
    /// measures it. Each distinct file is probed once, however many times
    /// it is listed. `name` is how an error names the file: its path inside
    /// the book's audio folder, or a single book's file name.
    /// - Throws: `AudioParseError.unplayableFile` naming the first listed
    ///   file that cannot be played.
    private static func playableDurations(
        of files: [(name: String, url: URL)],
        prober: AudioMediaProber
    ) async throws -> [TimeInterval] {
        let outcomes = await prober.probeEach(files.map(\.url))
        return try zip(files, outcomes).map { file, outcome in
            try outcome.mapError { AudioParseError.unplayableFile(file: file.name, problem: $0) }.get()
        }
    }
}

// MARK: - Errors

enum AudioParseError: LocalizedError, Equatable {
    case invalidDuration
    case noAudioFiles
    case unsupportedFormat
    case invalidSegment
    /// The audio file `file` cannot be played, because of `problem`. `file`
    /// is the file's path inside the book's audio folder ("Disc 2/03.mp3"),
    /// or a single-file book's file name.
    case unplayableFile(file: String, problem: AudioMediaProblem)
    /// The section `section` starts `start` seconds into its file `file`
    /// (its path inside the book's audio folder), at or after the end of
    /// that file, which plays for `fileDuration` seconds.
    case sectionStartsPastEnd(section: AudioSectionName, file: String, start: TimeInterval, fileDuration: TimeInterval)
    /// The section `section` ends `end` seconds into its file `file`,
    /// further past the end of that file (`fileDuration` seconds) than
    /// encoder padding explains (`AudioBookParser.endTolerance`).
    case sectionEndsPastEnd(section: AudioSectionName, file: String, end: TimeInterval, fileDuration: TimeInterval)
    /// The section `section` starts `start` seconds into its file `file`,
    /// before `earlierSection`, which comes earlier in the book and starts
    /// `earlierStart` seconds into the same file.
    case sectionStartsBeforeEarlierSection(
        section: AudioSectionName,
        file: String,
        start: TimeInterval,
        earlierSection: AudioSectionName,
        earlierStart: TimeInterval
    )

    /// What a listener can do about a section that does not fit its file:
    /// the sentence that ends every such message.
    static let mismatchAdvice = "The book's navigation does not match its audio; get a fresh copy and import it again."

    var errorDescription: String? {
        switch self {
        case .invalidDuration: return "Could not determine audio duration."
        case .noAudioFiles: return "No supported audio files found."
        case .unsupportedFormat: return "Unsupported audio format."
        case .invalidSegment: return "An audio section refers to a missing file or an invalid time range."
        case .unplayableFile(let file, let problem):
            // Damage is described as it is for every other kind of book.
            return PackageDamage.message(
                file: file,
                reason: problem.reason,
                container: "this audiobook",
                original: "the book"
            )
        // Times are written as they are spoken ("1 hour, 3 minutes"), which
        // reads the same on screen, aloud, and in braille; "1:03:00" can be
        // heard as a time of day.
        case .sectionStartsPastEnd(let section, let file, let start, let fileDuration):
            return "The \(section.phrase) starts \(TimeFormatting.spoken(start)) into its file “\(file)”, "
                + "which is only \(TimeFormatting.spoken(fileDuration)) long. \(Self.mismatchAdvice)"
        case .sectionEndsPastEnd(let section, let file, let end, let fileDuration):
            return "The \(section.phrase) ends \(TimeFormatting.spoken(end)) into its file “\(file)”, "
                + "which is only \(TimeFormatting.spoken(fileDuration)) long. \(Self.mismatchAdvice)"
        case .sectionStartsBeforeEarlierSection(let section, let file, let start, let earlierSection, let earlierStart):
            return "The \(section.phrase) starts \(TimeFormatting.spoken(start)) into its file “\(file)”, "
                + "before the \(earlierSection.phrase), which comes earlier in the book and starts "
                + "\(TimeFormatting.spoken(earlierStart)) in. \(Self.mismatchAdvice)"
        }
    }
}

/// How an error names one section of a segmented audiobook: by the title
/// its heading shows, or, for a heading without a title, by its place
/// among the book's headings. User-facing text calls sections headings,
/// never chapters.
struct AudioSectionName: Equatable, Sendable {
    /// The section's title, as the manifest gives it.
    let title: String
    /// The section's place among the book's headings, counting from 1.
    let number: Int

    /// The name as it reads after "the": `heading “Tide Tables”`, or
    /// `untitled heading 3` for a blank title. A title's line breaks become
    /// spaces, so the message stays one line.
    var phrase: String {
        let oneLine = title.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return oneLine.isEmpty ? "untitled heading \(number)" : "heading “\(oneLine)”"
    }
}

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
