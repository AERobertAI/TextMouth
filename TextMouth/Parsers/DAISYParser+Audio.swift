import Foundation

// MARK: - Audio SMIL Parser

/// An audio clip extracted from a DAISY SMIL file
struct DAISYAudioClip {
    var file: String        // audio filename (relative path)
    var startTime: Double   // seconds
    var endTime: Double     // seconds; 0 when the SMIL gives no end (play to the end of the file)
    var parID: String       // ID of the parent <par> element (for fragment lookup)
}

/// SAX parser for DAISY SMIL files that extracts audio clip references.
/// Handles both DAISY 2.02 (clip-begin="npt=SS.SSSs") and DAISY 3
/// (clipBegin="H:MM:SS.mmm") timing formats. Each clip records the ID
/// of its parent <par> element so callers can look up clips by SMIL fragment,
/// and every element with an ID records where playback reaches it among the
/// clips, so a navigation reference to any element, a `par`, a `seq`, or
/// the `text` inside a `par`, finds where its audio starts.
class DAISYAudioSMILParser: DAISYSAXParser {
    private(set) var audioClips: [DAISYAudioClip] = []

    /// ID of the nearest enclosing <par> (or <seq>) element, used to tag clips
    private var currentParID: String = ""

    /// For each element with an ID, the place in `audioClips` where playback
    /// reaches it: the first clip it plays, or the first after it when it
    /// plays none.
    private var clipPositionsByID: [String: Int] = [:]

    /// The elements open at this point of the parse, innermost last: whether
    /// each is a `par`, and where playback reaches it. The children of a
    /// `par` play together, so each starts where the `par` does; the
    /// children of any other element play one after another.
    private var openElements: [(isPar: Bool, clipPosition: Int)] = []

    /// Parse the file's audio clips in playback order.
    /// - Throws: `DAISYParserError.malformedXML` naming the file when it is
    ///   truncated or not well-formed; segment timing drawn from a partial
    ///   clip list would cut chapters short.
    func parse() throws -> [DAISYAudioClip] {
        try parseDocument()
        return audioClips
    }

    /// Find the first audio clip whose parID matches the given SMIL fragment ID.
    /// Returns nil if no match (caller should fall back to first clip).
    func clip(forFragment fragmentID: String) -> DAISYAudioClip? {
        guard !fragmentID.isEmpty else { return nil }
        return audioClips.first(where: { $0.parID == fragmentID })
    }

    /// Where in `audioClips` playback starts for the element whose ID is
    /// `fragmentID`: the first clip the element plays, the first its `par`
    /// plays when it lies directly in one, or the first clip after it when
    /// it plays none, which is `audioClips.count` when no clip in this file
    /// follows it. Nil for an empty ID or one no element has.
    func clipPosition(forFragment fragmentID: String) -> Int? {
        guard !fragmentID.isEmpty else { return nil }
        return clipPositionsByID[fragmentID]
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let localName = ParserUtilities.stripNamespacePrefix(elementName).lowercased()

        // Where playback reaches this element: where its `par` begins, or
        // once everything before it has played.
        let clipPosition: Int
        if let parent = openElements.last, parent.isPar {
            clipPosition = parent.clipPosition
        } else {
            clipPosition = audioClips.count
        }
        openElements.append((isPar: localName == "par", clipPosition: clipPosition))
        if let id = attributes["id"], !id.isEmpty, clipPositionsByID[id] == nil {
            clipPositionsByID[id] = clipPosition
        }

        // Track the ID of <par> and <seq> elements so audio clips know
        // which SMIL fragment they belong to
        if localName == "par" || localName == "seq" {
            if let id = attributes["id"], !id.isEmpty {
                currentParID = id
            }
        }

        if localName == "audio" {
            guard let src = attributes["src"], !src.isEmpty else { return }

            // Try DAISY 3 format first (clipBegin/clipEnd)
            var startTime: Double = 0
            var endTime: Double = 0

            if let begin = attributes["clipBegin"] {
                startTime = Self.parseTime(begin)
            } else if let begin = attributes["clip-begin"] {
                // DAISY 2.02 format
                startTime = Self.parseTime(begin)
            }

            if let end = attributes["clipEnd"] {
                endTime = Self.parseTime(end)
            } else if let end = attributes["clip-end"] {
                endTime = Self.parseTime(end)
            }

            audioClips.append(DAISYAudioClip(
                file: src,
                startTime: startTime,
                endTime: endTime,
                parID: currentParID
            ))
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        _ = openElements.popLast()
    }

    /// The metrics of a SMIL timecount (a number and the unit it counts in) and
    /// the seconds each is, longest first so that "ms" and "min" are not read
    /// as an "s" or an "m" after a number.
    private nonisolated static let timecountMetrics: [(suffix: String, seconds: Double)] = [
        ("ms", 0.001), ("min", 60), ("h", 3600), ("s", 1),
    ]

    /// Parse a DAISY time string to seconds.
    /// Supports these formats:
    ///   DAISY 2.02: "npt=SS.SSSs" (e.g. "npt=38.228s")
    ///   DAISY 3:    "H:MM:SS.mmm" (e.g. "0:02:43.650")
    ///   SMIL timecounts, a number and a metric: "500ms", "38.228s", "2min",
    ///   "1h"; a number alone is in seconds.
    /// Kept as a pure internal operation so timing syntax can be regression
    /// tested without constructing XML that obscures which value was parsed.
    nonisolated static func parseTime(_ timeStr: String) -> Double {
        var cleaned = timeStr.trimmingCharacters(in: .whitespaces)

        // Strip DAISY 2.02 "npt=" prefix
        if cleaned.lowercased().hasPrefix("npt=") {
            cleaned = String(cleaned.dropFirst(4))
        }

        // A SMIL timecount: a number counted in hours, minutes, seconds, or
        // milliseconds. Anything else that ends in one of those letters, such
        // as a clock value with a trailing "s", is read as a clock below.
        let lowered = cleaned.lowercased()
        for (suffix, seconds) in timecountMetrics where lowered.hasSuffix(suffix) {
            let count = String(cleaned.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            if let value = Double(count) { return value * seconds }
            break
        }
        if lowered.hasSuffix("s") {
            cleaned = String(cleaned.dropLast())
        }

        // Try parsing as plain seconds first (e.g. "38.228")
        if let seconds = Double(cleaned) {
            return seconds
        }

        // Parse H:MM:SS.mmm format
        let parts = cleaned.components(separatedBy: ":")
        if parts.count >= 2 {
            var hours: Double = 0
            var minutes: Double = 0
            var seconds: Double = 0

            if parts.count == 3 {
                hours = Double(parts[0]) ?? 0
                minutes = Double(parts[1]) ?? 0
                seconds = Double(parts[2]) ?? 0
            } else if parts.count == 2 {
                minutes = Double(parts[0]) ?? 0
                seconds = Double(parts[1]) ?? 0
            }

            return hours * 3600 + minutes * 60 + seconds
        }

        return 0
    }
}

// MARK: - Navigation and Playback Order

/// A heading in a DAISY book's navigation (an NCX navPoint or an NCC
/// heading), and where its audio starts: a fragment of a SMIL file.
struct DAISYNavigationReference: Equatable {
    /// The heading's title.
    let title: String
    /// The SMIL file's path inside the package.
    let smilPath: String
    /// The ID of the element in that file where the heading starts; empty
    /// for the start of the file.
    let fragment: String

    /// The reference to `target`, as the navigation file `navigationFile`
    /// writes it, made by the heading `title`.
    init(title: String, target: String, in navigationFile: String) {
        self.title = title
        fragment = ParserUtilities.splitFragment(target).fragment
        smilPath = ParserUtilities.resolvedPackagePath(target, relativeTo: navigationFile, preserveFragment: false)
    }
}

/// Every audio clip a DAISY book plays, in the order it plays them: each
/// SMIL file's clips in document order, the files in reading order. A
/// heading's section is the clips from where it starts up to where the
/// next heading starts, wherever those lie: playback runs on across `par`
/// and `seq` boundaries, audio files, and SMIL files alike.
struct DAISYPlaybackSequence {
    /// One clip of the sequence.
    struct Clip: Equatable {
        /// The audio file's path inside the package.
        var audioPath: String
        /// Where the clip starts in its file, in seconds.
        var startTime: Double
        /// Where the clip ends in its file, in seconds; 0 plays to the end
        /// of the file.
        var endTime: Double

        /// Whether the clip plays anything: it plays to its file's end, or
        /// ends after it starts. A SMIL file can hold a clip of no length,
        /// as for an element read in no time.
        var playsSomething: Bool { endTime == 0 || endTime > startTime }
    }

    /// The clips, in the order the book plays them.
    let clips: [Clip]
    /// Where each SMIL file's clips begin in `clips`, by the file's path.
    private let firstClipOfFile: [String: Int]
    /// The parsed SMIL files, by path.
    private let parsedFiles: [String: DAISYAudioSMILParser]

    /// The sequence of the SMIL files at `paths`, in that order, from their
    /// parses in `parsedFiles`. A path without a parse holds no clips and
    /// is passed over; a path listed again adds nothing more.
    init(playing paths: [String], parsedFiles: [String: DAISYAudioSMILParser]) {
        var clips: [Clip] = []
        var firstClipOfFile: [String: Int] = [:]
        for path in paths where firstClipOfFile[path] == nil {
            guard let parsed = parsedFiles[path] else { continue }
            firstClipOfFile[path] = clips.count
            clips += parsed.audioClips.map { clip in
                Clip(
                    audioPath: DAISYAudioConverter.resolvedAudioPath(for: clip, smilPath: path),
                    startTime: clip.startTime,
                    endTime: clip.endTime
                )
            }
        }
        self.clips = clips
        self.firstClipOfFile = firstClipOfFile
        self.parsedFiles = parsedFiles
    }

    /// Where in `clips` playback starts for `reference`: at its fragment,
    /// or, when the fragment names nothing in its SMIL file, at that file's
    /// first clip, as the converter has always fallen back. Nil when the
    /// reference's SMIL file is not in the sequence.
    func position(of reference: DAISYNavigationReference) -> Int? {
        guard let first = firstClipOfFile[reference.smilPath],
              let parsed = parsedFiles[reference.smilPath] else { return nil }
        return first + (parsed.clipPosition(forFragment: reference.fragment) ?? 0)
    }

    /// Each of `references`' sections, in the same order: the clips from
    /// where it starts up to (not including) where the next reference in
    /// playback order starts, or to the end of the book.
    ///
    /// Nil for a reference with no audio of its own: one whose SMIL file is
    /// not in the sequence, one after whose start no clip remains, and one
    /// that a later reference in navigation order starts at the same place
    /// as (a part's heading followed at once by its first chapter's), whose
    /// audio belongs to that later heading.
    func sections(for references: [DAISYNavigationReference]) -> [[Clip]?] {
        let positions = references.map(position(of:))
        // Every place a section starts, in playback order, with where the
        // section starting there ends: where the next one starts.
        let starts = Set(positions.compactMap { $0 }).sorted()
        var endOfSectionAt: [Int: Int] = [:]
        for (index, start) in starts.enumerated() {
            endOfSectionAt[start] = index + 1 < starts.count ? starts[index + 1] : clips.count
        }
        // The last reference, in navigation order, starting at each place.
        var lastReferenceAt: [Int: Int] = [:]
        for (index, position) in positions.enumerated() {
            if let position { lastReferenceAt[position] = index }
        }
        return positions.enumerated().map { index, position in
            guard let position, lastReferenceAt[position] == index else { return nil }
            let end = endOfSectionAt[position, default: clips.count]
            return position < end ? Array(clips[position..<end]) : nil
        }
    }
}

// MARK: - DAISY Audio Converter

/// Converts DAISY audio books into TextMouth's multi-file audio format
/// by extracting audio files and generating a manifest.json with chapter
/// segments derived from the NCC/NCX heading structure and SMIL timing.
/// Each heading's segment holds every clip the heading plays, in order, up
/// to the next heading, however many audio files they lie in.
enum DAISYAudioConverter {

    /// Convert a DAISY audio ZIP into a TextMouth audio book directory.
    /// Extracts audio files and creates a manifest.json with segments.
    /// Returns the path to the audio directory within the .tmb package.
    static func convertToAudioBook(
        from provider: DAISYFileProvider,
        version: DAISYVersion,
        toDirectory audioDir: URL
    ) throws -> AudioManifest {
        switch version {
        case .daisy3:
            return try convertDAISY3Audio(from: provider, toDirectory: audioDir)
        case .daisy202:
            return try convertDAISY202Audio(from: provider, toDirectory: audioDir)
        }
    }

    /// Detect whether a DAISY package has audio content
    static func hasAudio(in provider: DAISYFileProvider) -> Bool {
        let audioExtensions: Set<String> = ["mp3", "wav", "aac", "m4a", "ogg"]
        return provider.listFiles().contains { path in
            let ext = (path as NSString).pathExtension.lowercased()
            return audioExtensions.contains(ext)
        }
    }

    // MARK: - DAISY 3 Audio

    private static func convertDAISY3Audio(
        from provider: DAISYFileProvider,
        toDirectory audioDir: URL
    ) throws -> AudioManifest {
        let allFiles = provider.listFiles()

        // Parse OPF for metadata and the reading order
        guard let opfPath = allFiles.first(where: { $0.lowercased().hasSuffix(".opf") }) else {
            throw DAISYParserError.missingContent("No OPF file found")
        }
        let opfResult = try DAISYOPFParser(path: opfPath, in: provider).parse()

        // Parse NCX for heading structure
        guard let ncxPath = allFiles.first(where: { $0.lowercased().hasSuffix(".ncx") }) else {
            throw DAISYParserError.missingContent("No NCX file found")
        }
        let navPoints = try DAISYNCXParser(path: ncxPath, in: provider).parse()

        let segments = try sectionSegments(
            for: navPoints.map { DAISYNavigationReference(title: $0.label, target: $0.contentSrc, in: ncxPath) },
            readingOrder: spineSMILPaths(of: opfResult, opfPath: opfPath),
            provider: provider,
            toDirectory: audioDir
        )

        // Also copy any remaining audio files not yet copied
        copyRemainingAudioFiles(from: provider, toDirectory: audioDir)

        return AudioManifest(
            title: opfResult.title.isEmpty ? nil : opfResult.title,
            author: opfResult.author.isEmpty ? nil : opfResult.author,
            segments: segments
        )
    }

    /// The SMIL files a DAISY 3 package's spine lists, in reading order, as
    /// package paths. Z39.86-2005 §3.4: "A player must consult the spine
    /// when it reaches the end of a SMIL file to determine which file to
    /// render next."
    private static func spineSMILPaths(of opf: DAISYOPFResult, opfPath: String) -> [String] {
        opf.spineItemRefs
            .compactMap { opf.manifest[$0] }
            .filter { $0.mediaType.lowercased().contains("smil") || $0.href.lowercased().hasSuffix(".smil") }
            .map { ParserUtilities.resolvedPackagePath($0.href, relativeTo: opfPath, preserveFragment: false) }
    }

    // MARK: - DAISY 2.02 Audio

    private static func convertDAISY202Audio(
        from provider: DAISYFileProvider,
        toDirectory audioDir: URL
    ) throws -> AudioManifest {
        let allFiles = provider.listFiles()

        // Find and parse ncc.html
        guard let nccPath = allFiles.first(where: {
            $0.lowercased().hasSuffix("ncc.html") || $0.lowercased().hasSuffix("ncc.htm")
        }) else {
            throw DAISYParserError.missingContent("No ncc.html found")
        }
        let nccResult = try DAISY202NCCParser(path: nccPath, in: provider).parse()

        // A DAISY 2.02 player plays each SMIL file to its end, then returns
        // to the NCC for the next (DAISY 2.02 §2.3.5), and every SMIL file
        // begins with a heading the NCC lists (§2.3.4.1), so the headings'
        // own order is the reading order.
        let segments = try sectionSegments(
            for: nccResult.headings.map { DAISYNavigationReference(title: $0.text, target: $0.href, in: nccPath) },
            readingOrder: [],
            provider: provider,
            toDirectory: audioDir
        )

        // Copy remaining audio files
        copyRemainingAudioFiles(from: provider, toDirectory: audioDir)

        return AudioManifest(
            title: nccResult.title.isEmpty ? nil : nccResult.title,
            author: nccResult.author.isEmpty ? nil : nccResult.author,
            segments: segments
        )
    }

    // MARK: - Sections

    /// The segments the headings `references` start, in their order, each
    /// with every clip it plays up to the next heading in playback order
    /// (see `DAISYPlaybackSequence`). Each clip's audio file is copied into
    /// `audioDir` once, under its own name, or a numbered one when another
    /// file had that name.
    ///
    /// A heading whose SMIL file the package lacks is left out, as is one
    /// with no audio of its own, as a heading whose SMIL file holds no audio
    /// always was. Clips of no length are dropped, and clips that continue
    /// one another in a file are joined (`joiningContinuousClips(_:)`).
    ///
    /// - Parameter readingOrder: The SMIL files in the order the book is
    ///   read, such as a DAISY 3 spine. Used when it names every SMIL file
    ///   a heading starts in, so files no heading names play in their place;
    ///   otherwise, or when empty, the headings' own order is used.
    /// - Throws: `DAISYParserError.malformedXML` for a damaged SMIL file.
    static func sectionSegments(
        for references: [DAISYNavigationReference],
        readingOrder: [String],
        provider: DAISYFileProvider,
        toDirectory audioDir: URL
    ) throws -> [AudioSegment] {
        // Parse each SMIL file a heading starts in, once.
        var parsedFiles: [String: DAISYAudioSMILParser] = [:]
        var playable: [DAISYNavigationReference] = []
        for reference in references {
            if try cachedAudioSMIL(at: reference.smilPath, in: provider, cache: &parsedFiles) != nil {
                playable.append(reference)
            }
        }

        // The reading order's files, parsed in turn, replace the headings'
        // order when they include every file a heading starts in.
        let headingOrder = playable.map(\.smilPath)
        var playbackOrder = headingOrder
        if !readingOrder.isEmpty {
            var readable: [String] = []
            for path in readingOrder {
                if try cachedAudioSMIL(at: path, in: provider, cache: &parsedFiles) != nil {
                    readable.append(path)
                }
            }
            if Set(headingOrder).isSubset(of: readable) {
                playbackOrder = readable
            }
        }

        let sequence = DAISYPlaybackSequence(playing: playbackOrder, parsedFiles: parsedFiles)
        var copiedAudioFileNamesByPath: [String: String] = [:]
        var usedAudioFileNames: Set<String> = []
        var segments: [AudioSegment] = []
        for (reference, section) in zip(playable, sequence.sections(for: playable)) {
            guard let section else { continue }
            let clips = joiningContinuousClips(section.filter(\.playsSomething)).map { clip in
                AudioClip(
                    file: copyAudioFile(
                        from: clip.audioPath,
                        provider: provider,
                        toDirectory: audioDir,
                        fileNamesBySourcePath: &copiedAudioFileNamesByPath,
                        usedFileNames: &usedAudioFileNames,
                        fileManager: .default
                    ),
                    startTime: clip.startTime,
                    endTime: clip.endTime
                )
            }
            // A section whose every clip lasts no time plays nothing.
            if let segment = AudioSegment(title: reference.title, clips: clips) {
                segments.append(segment)
            }
        }
        return segments
    }

    /// How far apart, in seconds, the end of one clip and the start of the
    /// next in the same file may lie for the two to play as one. A SMIL
    /// file lists a clip per phrase, and producers write clip times to the
    /// millisecond, rounding one clip's end down and the next one's start
    /// up, or writing the same time in two forms ("0:01:04.065" and
    /// "npt=64.065s"). Fifty milliseconds is shorter than any syllable, so
    /// joining clips this close changes nothing a listener can hear, while
    /// playing them apart would add a seam between every phrase.
    static let continuityTolerance: TimeInterval = 0.05

    /// `clips` with each run of clips that continue one another in the same
    /// file, within `continuityTolerance`, joined into one clip, so a
    /// section plays each stretch of a file in one go rather than phrase by
    /// phrase. A clip that plays to the end of its file continues into
    /// nothing.
    static func joiningContinuousClips(_ clips: [DAISYPlaybackSequence.Clip]) -> [DAISYPlaybackSequence.Clip] {
        var joined: [DAISYPlaybackSequence.Clip] = []
        for clip in clips {
            if var last = joined.last,
               last.audioPath == clip.audioPath,
               last.endTime != 0,
               abs(clip.startTime - last.endTime) <= continuityTolerance {
                last.endTime = clip.endTime
                joined[joined.count - 1] = last
            } else {
                joined.append(clip)
            }
        }
        return joined
    }

    // MARK: - Helpers

    /// The parsed SMIL file at `smilPath`, parsing it on first use so several
    /// headings that share a file share one parse. Returns nil when the
    /// package lacks the file, which callers skip as they always have.
    /// - Throws: `DAISYParserError.malformedXML` when the file is damaged.
    private static func cachedAudioSMIL(
        at smilPath: String,
        in provider: DAISYFileProvider,
        cache: inout [String: DAISYAudioSMILParser]
    ) throws -> DAISYAudioSMILParser? {
        if let cached = cache[smilPath] { return cached }
        guard let parser = try? DAISYAudioSMILParser(path: smilPath, in: provider) else { return nil }
        _ = try parser.parse()
        cache[smilPath] = parser
        return parser
    }

    /// Resolve a clip reference exactly as manifest construction does. Internal
    /// visibility lets parser regression tests cover basename collisions.
    static func resolvedAudioPath(for clip: DAISYAudioClip, smilPath: String) -> String {
        ParserUtilities.resolvedPackagePath(
            clip.file,
            relativeTo: smilPath,
            preserveFragment: false
        )
    }

    private static func copyAudioFile(
        from sourcePath: String,
        provider: DAISYFileProvider,
        toDirectory audioDir: URL,
        fileNamesBySourcePath: inout [String: String],
        usedFileNames: inout Set<String>,
        fileManager fm: FileManager
    ) -> String {
        if let existing = fileNamesBySourcePath[sourcePath] {
            return existing
        }

        let fileName = uniqueAudioFileName(
            for: (sourcePath as NSString).lastPathComponent,
            usedFileNames: usedFileNames
        )
        usedFileNames.insert(fileName)
        fileNamesBySourcePath[sourcePath] = fileName

        let destPath = audioDir.appendingPathComponent(fileName)
        if !fm.fileExists(atPath: destPath.path) {
            do {
                // Copied, never read whole: one audio file can hold hundreds
                // of megabytes (PERF24).
                try provider.copyFile(at: sourcePath, to: destPath)
            } catch {
                print("Warning: Failed to copy audio file \(sourcePath): \(error.localizedDescription)")
            }
        }

        return fileName
    }

    private static func uniqueAudioFileName(
        for baseName: String,
        usedFileNames: Set<String>
    ) -> String {
        guard usedFileNames.contains(baseName) else { return baseName }

        let nsBase = baseName as NSString
        let stem = nsBase.deletingPathExtension
        let ext = nsBase.pathExtension

        var index = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem)-\(index)" : "\(stem)-\(index).\(ext)"
            if !usedFileNames.contains(candidate) {
                return candidate
            }
            index += 1
        }
    }

    /// Copy any audio files from the DAISY package that haven't been copied yet
    private static func copyRemainingAudioFiles(
        from provider: DAISYFileProvider,
        toDirectory audioDir: URL
    ) {
        let audioExtensions: Set<String> = ["mp3", "wav", "aac", "m4a", "ogg"]
        let fm = FileManager.default

        for path in provider.listFiles() {
            let ext = (path as NSString).pathExtension.lowercased()
            guard audioExtensions.contains(ext) else { continue }

            let fileName = (path as NSString).lastPathComponent
            let destPath = audioDir.appendingPathComponent(fileName)

            if !fm.fileExists(atPath: destPath.path) {
                do {
                    try provider.copyFile(at: path, to: destPath)
                } catch {
                    print("Warning: Failed to copy remaining audio file \(path): \(error.localizedDescription)")
                }
            }
        }
    }
}
