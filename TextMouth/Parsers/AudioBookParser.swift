import Foundation

/// Parses audio files into DocumentContent for the reader.
/// For single audio files: extracts chapter markers if available (M4B), otherwise single chapter.
/// For multi-file audio books (from ZIP): each file becomes a chapter.
enum AudioBookParser {

    /// How many placeholder characters stand for `duration` seconds of
    /// audio: `ReaderViewModel.audioCharsPerSecond` a second, at least 1,
    /// and at most `BookContentIndex.maximumCharacterCount`, the most the
    /// index accepts on every reopen. A file's header can claim any length,
    /// so the count is worked out and bounded as a `Double` before it
    /// becomes an `Int`: no length traps (`Int(_:)` does on infinity, NaN,
    /// and from about 9.2e17 seconds on), and none builds a placeholder
    /// gigabytes long. A length that is not a finite number above zero
    /// gets 1.
    static func placeholderLength(for duration: TimeInterval) -> Int {
        guard duration.isFinite, duration > 0 else { return 1 }
        let characters = duration * ReaderViewModel.audioCharsPerSecond
        return max(1, Int(min(characters, Double(BookContentIndex.maximumCharacterCount))))
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

    /// Which tracks a scan of a folder takes. The import's scans run before
    /// the conversion and must find every file the import converts; a
    /// package's scans run after it, so a file of a converted format there is
    /// not one the book plays.
    enum TrackScan: Equatable {
        /// A folder being imported, or the staged copy about to be
        /// converted: every format the import accepts
        /// (`BookFormat.audio.fileExtensions`), those it converts included.
        case importing
        /// A book's own folder of tracks (loading the reader, re-analysis, a
        /// manifest edit, the library's checks): the formats TextMouth plays
        /// as they are, and Ogg, which the library still converts
        /// (`BookFormat.packageTrackExtensions`), and of the other converted
        /// formats only TextMouth's own CAF (`isOwnCAF(atPath:)`).
        /// A stray .aifc, .au, .ac3, or CAF of another origin, left by an
        /// older ZIP import, is not a track: taking it would fail the whole
        /// book, or decode it in TextMouth's process and shift the chapters
        /// after it under the listener's places and bookmarks.
        case package
    }

    /// Whether the CAF at `relativePath`, its path from the folder being
    /// scanned, is one TextMouth wrote itself, by its name and its place.
    /// TextMouth writes CAF files in several places, and two of them can
    /// lie inside a folder a scan reads:
    ///
    /// - A recording's original take, `BookOrigin.originalTakeFileName`, at
    ///   the package's root (the scan's top level when it reads the
    ///   package).
    /// - A punch-in's take, `<ID>.caf` in `AudioEditPackage.takesFolder`
    ///   (`audioEdits/takes`), also at the package's root.
    ///
    /// The rest are written outside every package, so no scan meets them:
    /// the audio editor's processed stretches and silence
    /// (`AudioFilterProcessor`, `AudioEditComposition`) and its clips
    /// (`AudioEditorModel`) go to this Mac's scratch folder (their
    /// temporary files are hidden besides), and a recording's take in
    /// progress (`RecordingTakeFiles`) to the recordings folder until it is
    /// kept as the original take above.
    ///
    /// A CAF of the same name elsewhere (inside a subfolder, say) is a stray.
    static func isOwnCAF(atPath relativePath: String) -> Bool {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts == [BookOrigin.originalTakeFileName] { return true }
        guard parts.count == 3,
              parts[0] == AudioEditPackage.folderName,
              parts[1] == AudioEditPackage.takesFolderName else { return false }
        return (parts[2] as NSString).pathExtension.lowercased() == RecordingTakeFiles.fileExtension
    }

    /// Find the same playable candidates during import and reader loading.
    /// ZIPs commonly contain a wrapper folder; AppleDouble sidecars and symbolic
    /// links inside the folder are not chapters, even when their names have an
    /// audio extension. The folder itself may be a symbolic link: whoever named
    /// it chose to read what it leads to, so it is read as that folder
    /// (`resolvingALinkedFolder(_:)`), while the links inside it stay unfollowed.
    /// - Parameter scan: which formats are tracks (`TrackScan`). Every app
    ///   caller passes it, so each says whether it runs before the import's
    ///   conversion or on a package; the default, the import's list, is what
    ///   this function always did, and is only what older callers (and
    ///   tests) that name no scan rely on.
    static func audioFiles(in directory: URL, scan: TrackScan = .importing) throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: resolvingALinkedFolder(directory),
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else { throw AudioParseError.noAudioFiles }

        let extensions = Set(BookFormat.audio.fileExtensions)
        let packageExtensions = BookFormat.packageTrackExtensions
        var files: [URL] = []
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: keys)
            // A link is neither a regular file nor entered as a folder, so
            // the guard below passes it over. The skip is for Finder's
            // metadata folder alone (`skipFinderMetadataFolder`).
            if enumerator.skipFinderMetadataFolder(file, isDirectory: values.isDirectory) { continue }
            guard values.isRegularFile == true else { continue }
            let fileExtension = file.pathExtension.lowercased()
            switch scan {
            case .importing:
                if extensions.contains(fileExtension) { files.append(file) }
            case .package:
                // A format played as it is; or a CAF of TextMouth's own,
                // known by its place, so its path is worked out for a CAF only.
                if packageExtensions.contains(fileExtension)
                    || (fileExtension == RecordingTakeFiles.fileExtension
                        && isOwnCAF(atPath: relativeName(of: file, in: directory))) {
                    files.append(file)
                }
            }
        }
        if let enumerationError { throw enumerationError }
        return files.sorted {
            relativeName(of: $0, in: directory).localizedStandardCompare(
                relativeName(of: $1, in: directory)
            ) == .orderedAscending
        }
    }

    /// `directory` as the folder to walk: the folder a symbolic link leads to
    /// when `directory` is itself a link, since the file manager's enumerator
    /// refuses a link ("couldn't be opened", as if the folder were damaged),
    /// and `directory` as it is otherwise, its spelling kept (a path through
    /// /var stays one). A link that leads nowhere is returned as it is, and
    /// the enumerator reports it.
    private static func resolvingALinkedFolder(_ directory: URL) -> URL {
        let isLink = (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
        return isLink ? directory.resolvingSymlinksInPath() : directory
    }

    /// The path from `directory` of each track `audioFiles(in:scan:)` finds
    /// there, in Finder's order: "Disc 2/03.mp3".
    static func trackPaths(in directory: URL, scan: TrackScan = .importing) throws -> [String] {
        try audioFiles(in: directory, scan: scan).map { relativeName(of: $0, in: directory) }
    }

    /// Manifest filenames are relative to the audio directory, so tracks with
    /// the same basename on different discs remain distinct.
    static func relativeName(of file: URL, in directory: URL) -> String {
        // Foundation may return /private/var for a directory supplied as /var.
        // Compare canonical paths before removing the base-directory prefix.
        let basePath = directory.resolvingSymlinksInPath().path
        return String(file.resolvingSymlinksInPath().path.dropFirst(basePath.count + 1))
    }

    /// Where the chapters of a book of one audio file came from
    /// (`parseFile(url:prober:fallbackChapters:)`).
    enum ChapterSource: Equatable, Sendable {
        /// The file's own chapter markers, which always win.
        case file
        /// A podcast episode's chapters kept beside the file (FMT25), taken
        /// because the file has none of its own.
        case podcastChapters
        /// None: the book is one chapter, the whole file. Any podcast's
        /// chapters given for it begin past its end.
        case wholeFile
    }

    /// Parse a single audio file. Extracts chapters from M4B metadata if
    /// available, or takes a podcast's chapters kept beside it
    /// (`parseFile(url:prober:fallbackChapters:)`).
    /// - Parameters:
    ///   - prober: checks that the file plays and measures it; the app's
    ///     AVFoundation probe unless a test stands in for it.
    ///   - fallbackChapters: a podcast episode's chapters, kept beside its
    ///     audio (FMT25), for a file without chapters of its own.
    /// - Throws: `AudioParseError.unplayableFile` naming the file when it
    ///   cannot be played (see `AudioMediaProbe`).
    static func parse(
        url: URL,
        prober: AudioMediaProber = .avFoundation,
        fallbackChapters: PodcastChapters? = nil
    ) async throws -> DocumentContent {
        try await parseFile(url: url, prober: prober, fallbackChapters: fallbackChapters).content
    }

    /// Parse a single audio file, saying where its chapters came from.
    /// Extracts chapters from M4B metadata if available. A file without
    /// any takes `fallbackChapters`, a podcast episode's chapters kept
    /// beside it (FMT25), when they fit it
    /// (`PodcastChapters.bookChapters(fileDuration:)`): each is a chapter
    /// with one heading, as each of the file's own is. The file's own
    /// chapters always win.
    /// - Parameters:
    ///   - prober: checks that the file plays and measures it; the app's
    ///     AVFoundation probe unless a test stands in for it.
    ///   - fallbackChapters: a podcast episode's chapters, kept beside its
    ///     audio, for a file without chapters of its own; nil for none.
    /// - Throws: `AudioParseError.unplayableFile` naming the file when it
    ///   cannot be played (see `AudioMediaProbe`).
    static func parseFile(
        url: URL,
        prober: AudioMediaProber = .avFoundation,
        fallbackChapters: PodcastChapters? = nil
    ) async throws -> (content: DocumentContent, chapterSource: ChapterSource) {
        // One file in, one duration out.
        let totalSeconds = try await playableDurations(
            of: [(name: url.lastPathComponent, url: url)],
            prober: prober
        )[0]

        // Try to extract metadata
        let metadata = await AudioPlaybackService.extractMetadata(from: url)
        let title = metadata.title ?? url.deletingPathExtension().lastPathComponent
        let author = metadata.artist ?? Book.unknownAuthor

        // Try to extract chapter markers, or take a podcast's chapters
        let (chapters, source) = await markers(of: url, lasting: totalSeconds, fallback: fallbackChapters)

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
            return (DocumentContent(title: title, author: author, chapters: [chapter]), source)
        } else {
            // Multiple chapters, from metadata or from a podcast's chapters
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
            return (DocumentContent(title: title, author: author, chapters: parsedChapters), source)
        }
    }

    /// The chapters of the one audio file at `url`, lasting `fileDuration`
    /// seconds, and where they came from: the file's own chapter markers,
    /// which always win; without any, those of `fallback`, a podcast's
    /// chapters, that fit the file (`PodcastChapters.bookChapters(fileDuration:)`);
    /// and none when neither gives any.
    private static func markers(
        of url: URL,
        lasting fileDuration: TimeInterval,
        fallback: PodcastChapters?
    ) async -> (chapters: [(title: String, startTime: TimeInterval, duration: TimeInterval)], source: ChapterSource) {
        let own = await AudioPlaybackService.extractChapters(from: url)
        if !own.isEmpty {
            return (own, .file)
        }
        let podcast = fallback?.bookChapters(fileDuration: fileDuration) ?? []
        return (podcast, podcast.isEmpty ? .wholeFile : .podcastChapters)
    }

    /// Parse a directory of audio files as a multi-chapter audio book.
    /// Files are ordered alphabetically unless a manifest.json is found, at
    /// the directory's top level or inside its one folder
    /// (`AudioManifest.read(inAudioFolder:)`); the manifest names tracks by
    /// their paths from the folder holding it, and arranges them
    /// (`AudioTrackPlan`). Each track is a chapter, which opens with the
    /// group heading the manifest begins there, if any, then the track's
    /// own heading, both at the chapter's start.
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
        let audioFiles = try Self.audioFiles(in: url, scan: .package)

        guard !audioFiles.isEmpty else {
            throw AudioParseError.noAudioFiles
        }
        // Each track's path from `url`, in Finder's order, as the files are.
        let paths = audioFiles.map { relativeName(of: $0, in: url) }

        // The manifest, wherever it lies, names each track by its path from
        // the folder holding it; each name it gives is turned into the
        // track's path from `url`, as the tracks are named here.
        let found = AudioManifest.read(inAudioFolder: url)
        let manifest = found?.manifest
        let pathOfTrack = { (name: String) in found?.location.path(ofTrackNamed: name) ?? name }
        let nameOfTrack = { (path: String) in found?.location.name(ofTrackAt: path) ?? path }

        let overallTitle = manifest?.bookTitle ?? url.lastPathComponent
        let overallAuthor = manifest?.bookAuthor ?? Book.unknownAuthor

        // If manifest has segments (DAISY-style sub-file chapters), use those
        // instead of the one-file-per-chapter model. Their clips name files
        // from the manifest's folder too.
        if let segments = manifest?.segments, !segments.isEmpty {
            let result = try await parseSegmentedAudio(
                segments: segments.map { segment in
                    segment.mappingClips { clip in
                        var located = clip
                        located.file = pathOfTrack(clip.file)
                        return located
                    }
                },
                audioDir: url,
                availableFiles: Set(paths),
                title: overallTitle,
                author: overallAuthor,
                prober: prober
            )
            return (content: result.content, filePaths: result.filePaths, segments: result.segments)
        }

        // The tracks in the order the book plays them, each with its title
        // and headings, as the manifest arranges them; each is found again
        // by its path from `url`, as every track the plan places is one of
        // the folder's.
        let filesByPath = Dictionary(uniqueKeysWithValues: zip(paths, audioFiles))
        let plan = AudioTrackPlan(arranging: paths.map(nameOfTrack), by: manifest)
        let tracks = plan.tracks.compactMap { planned -> (planned: AudioTrackPlan.Track, name: String, url: URL)? in
            let path = pathOfTrack(planned.name)
            return filesByPath[path].map { (planned: planned, name: path, url: $0) }
        }

        // Every track is checked and measured before any becomes a heading,
        // so a damaged track fails the whole book, by its name in the book.
        let durations = try await playableDurations(of: tracks.map { (name: $0.name, url: $0.url) }, prober: prober)

        var chapters: [Chapter] = []
        var filePaths: [String] = []
        for (index, (track, duration)) in zip(tracks, durations).enumerated() {
            let placeholderText = String(repeating: " ", count: max(1, placeholderLength(for: duration)))
            chapters.append(Chapter(
                title: track.planned.title,
                text: placeholderText,
                headings: Self.headings(of: track.planned, chapterIndex: index)
            ))
            filePaths.append(track.url.path)
        }

        let content = DocumentContent(title: overallTitle, author: overallAuthor, chapters: chapters)
        return (content: content, filePaths: filePaths, segments: nil)
    }

    /// The headings at the start of the chapter, number `chapterIndex`,
    /// that plays `track`: the group heading the manifest begins there, at
    /// level 1, then the track's own heading at its level. Both are at the
    /// chapter's start, the group heading first, which every list of the
    /// book's headings keeps.
    static func headings(of track: AudioTrackPlan.Track, chapterIndex: Int) -> [Heading] {
        var headings: [Heading] = []
        if let group = track.groupHeading {
            headings.append(Heading(level: 1, text: group, chapterIndex: chapterIndex, characterOffset: 0))
        }
        headings.append(Heading(level: track.level, text: track.title, chapterIndex: chapterIndex, characterOffset: 0))
        return headings
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
    ///   overlap, though: books converted from DAISY before a heading could
    ///   play several clips end a heading at the last clip of its file in
    ///   its SMIL file when the next heading plays from another file, so a
    ///   later heading in the first file can start inside it. Overlap
    ///   repeats audio but never loses any, and refusing it would refuse
    ///   such books. The later clips of a section are not
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

        /// Record the move as an import event, in the console and the debug
        /// log, as the single line `AUDIO_SEGMENT_CLAMPED: <book>: <file>:
        /// moved 2 sections' ends back to the file's measured end of
        /// 600.000 s, from up to 0.400 s past it`. A line break in the book's
        /// title or the file's name becomes a space, so the entry stays on
        /// one line.
        func log(bookTitle: String) {
            let ends = sectionCount == 1 ? "1 section's end" : "\(sectionCount) sections' ends"
            let distance = sectionCount == 1 ? "from" : "from up to"
            DiagnosticLog.event(
                .import,
                "\(AudioBookParser.clampLogTag): \(bookTitle): \(file): moved \(ends) back to "
                    + "the file's measured end of " + String(format: "%.3f", fileDuration) + " s, "
                    + "\(distance) " + String(format: "%.3f", largestOvershoot) + " s past it"
            )
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
