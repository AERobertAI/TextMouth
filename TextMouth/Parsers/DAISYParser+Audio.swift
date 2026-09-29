import Foundation

// MARK: - Audio SMIL Parser

/// An audio clip extracted from a DAISY SMIL file
struct DAISYAudioClip {
    var file: String        // audio filename (relative path)
    var startTime: Double   // seconds
    var endTime: Double     // seconds
    var parID: String       // ID of the parent <par> element (for fragment lookup)
}

/// SAX parser for DAISY SMIL files that extracts audio clip references.
/// Handles both DAISY 2.02 (clip-begin="npt=SS.SSSs") and DAISY 3
/// (clipBegin="H:MM:SS.mmm") timing formats. Each clip records the ID
/// of its parent <par> element so callers can look up clips by SMIL fragment.
class DAISYAudioSMILParser: DAISYSAXParser {
    private(set) var audioClips: [DAISYAudioClip] = []

    /// ID of the nearest enclosing <par> (or <seq>) element, used to tag clips
    private var currentParID: String = ""

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

    /// Find the index of the first audio clip matching the given fragment ID.
    func clipIndex(forFragment fragmentID: String) -> Int? {
        guard !fragmentID.isEmpty else { return nil }
        return audioClips.firstIndex(where: { $0.parID == fragmentID })
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let localName = ParserUtilities.stripNamespacePrefix(elementName).lowercased()

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

    /// Parse a DAISY time string to seconds.
    /// Supports both formats:
    ///   DAISY 2.02: "npt=SS.SSSs" (e.g. "npt=38.228s")
    ///   DAISY 3:    "H:MM:SS.mmm" (e.g. "0:02:43.650")
    /// Kept as a pure internal operation so timing syntax can be regression
    /// tested without constructing XML that obscures which value was parsed.
    nonisolated static func parseTime(_ timeStr: String) -> Double {
        var cleaned = timeStr.trimmingCharacters(in: .whitespaces)

        // Strip DAISY 2.02 "npt=" prefix and trailing "s"
        if cleaned.lowercased().hasPrefix("npt=") {
            cleaned = String(cleaned.dropFirst(4))
        }
        if cleaned.lowercased().hasSuffix("s") {
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

// MARK: - DAISY Audio Converter

/// Converts DAISY audio books into TextMouth's multi-file audio format
/// by extracting audio files and generating a manifest.json with chapter
/// segments derived from the NCC/NCX heading structure and SMIL timing.
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

        // Parse OPF for metadata
        guard let opfPath = allFiles.first(where: { $0.lowercased().hasSuffix(".opf") }) else {
            throw DAISYParserError.missingContent("No OPF file found")
        }
        let opfResult = try DAISYOPFParser(path: opfPath, in: provider).parse()

        // Parse NCX for heading structure
        guard let ncxPath = allFiles.first(where: { $0.lowercased().hasSuffix(".ncx") }) else {
            throw DAISYParserError.missingContent("No NCX file found")
        }
        let navPoints = try DAISYNCXParser(path: ncxPath, in: provider).parse()

        // Pre-parse all referenced SMIL files so we can compute segment
        // boundaries across navPoints that share the same SMIL file.
        // Key = resolved SMIL file path (without fragment), Value = parsed clips.
        var smilCache: [String: DAISYAudioSMILParser] = [:]
        let fm = FileManager.default

        // Build the list of (navPoint, smilFilePath, fragmentID) tuples
        struct NavRef {
            let navPoint: DAISYNavPoint
            let smilPath: String
            let fragmentID: String
        }
        var navRefs: [NavRef] = []

        for navPoint in navPoints {
            let smilRef = navPoint.contentSrc
            let split = ParserUtilities.splitFragment(smilRef)
            let fragmentID = split.fragment
            let smilPath = ParserUtilities.resolvedPackagePath(
                smilRef,
                relativeTo: ncxPath,
                preserveFragment: false
            )

            // Parse the SMIL file once and cache it
            guard try cachedAudioSMIL(at: smilPath, in: provider, cache: &smilCache) != nil else { continue }

            navRefs.append(NavRef(navPoint: navPoint, smilPath: smilPath, fragmentID: fragmentID))
        }

        // Build segments. For each navPoint, find its fragment's clip start time.
        // The segment's end time is determined by the NEXT navPoint's clip start
        // (if they share the same resolved audio file), or this resolved audio
        // file's last clip end in the SMIL.
        var segments: [AudioSegment] = []
        var copiedAudioFileNamesByPath: [String: String] = [:]
        var usedAudioFileNames: Set<String> = []

        for (i, ref) in navRefs.enumerated() {
            guard let smilParser = smilCache[ref.smilPath] else { continue }
            let clips = smilParser.audioClips
            guard !clips.isEmpty else { continue }

            // Find the clip for this navPoint's fragment, or fall back to the first clip
            let clipForFragment = smilParser.clip(forFragment: ref.fragmentID)
            let segmentClip = clipForFragment ?? clips[0]
            let startTime = segmentClip.startTime

            var nextClipAndPath: (clip: DAISYAudioClip, smilPath: String)?
            if i + 1 < navRefs.count {
                let nextRef = navRefs[i + 1]
                if let nextParser = smilCache[nextRef.smilPath] {
                    let nextClips = nextParser.audioClips
                    if let nextClip = nextParser.clip(forFragment: nextRef.fragmentID) ?? nextClips.first {
                        nextClipAndPath = (clip: nextClip, smilPath: nextRef.smilPath)
                    }
                }
            }

            let endTime = segmentEndTime(
                for: segmentClip,
                clips: clips,
                smilPath: ref.smilPath,
                nextClipAndPath: nextClipAndPath
            )

            // Copy the audio file to the output directory
            let audioSrcPath = resolvedAudioPath(for: segmentClip, smilPath: ref.smilPath)
            let audioFileName = copyAudioFile(
                from: audioSrcPath,
                provider: provider,
                toDirectory: audioDir,
                fileNamesBySourcePath: &copiedAudioFileNamesByPath,
                usedFileNames: &usedAudioFileNames,
                fileManager: fm
            )

            segments.append(AudioSegment(
                title: ref.navPoint.label,
                file: audioFileName,
                startTime: startTime,
                endTime: endTime
            ))
        }

        // Also copy any remaining audio files not yet copied
        copyRemainingAudioFiles(from: provider, toDirectory: audioDir)

        return AudioManifest(
            title: opfResult.title.isEmpty ? nil : opfResult.title,
            author: opfResult.author.isEmpty ? nil : opfResult.author,
            segments: segments
        )
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

        // Pre-parse all referenced SMIL files for fragment-aware clip lookup
        var smilCache: [String: DAISYAudioSMILParser] = [:]
        let fm = FileManager.default

        struct HeadingRef {
            let heading: NCCHeading
            let smilPath: String
            let fragmentID: String
        }
        var headingRefs: [HeadingRef] = []

        for heading in nccResult.headings {
            let smilRef = heading.href
            let split = ParserUtilities.splitFragment(smilRef)
            let fragmentID = split.fragment
            let smilPath = ParserUtilities.resolvedPackagePath(
                smilRef,
                relativeTo: nccPath,
                preserveFragment: false
            )

            guard try cachedAudioSMIL(at: smilPath, in: provider, cache: &smilCache) != nil else { continue }

            headingRefs.append(HeadingRef(heading: heading, smilPath: smilPath, fragmentID: fragmentID))
        }

        // Build segments with correct per-heading boundaries
        var segments: [AudioSegment] = []
        var copiedAudioFileNamesByPath: [String: String] = [:]
        var usedAudioFileNames: Set<String> = []

        for (i, ref) in headingRefs.enumerated() {
            guard let smilParser = smilCache[ref.smilPath] else { continue }
            let clips = smilParser.audioClips
            guard !clips.isEmpty else { continue }

            let clipForFragment = smilParser.clip(forFragment: ref.fragmentID)
            let segmentClip = clipForFragment ?? clips[0]
            let startTime = segmentClip.startTime

            var nextClipAndPath: (clip: DAISYAudioClip, smilPath: String)?
            if i + 1 < headingRefs.count {
                let nextRef = headingRefs[i + 1]
                if let nextParser = smilCache[nextRef.smilPath] {
                    let nextClips = nextParser.audioClips
                    if let nextClip = nextParser.clip(forFragment: nextRef.fragmentID) ?? nextClips.first {
                        nextClipAndPath = (clip: nextClip, smilPath: nextRef.smilPath)
                    }
                }
            }

            let endTime = segmentEndTime(
                for: segmentClip,
                clips: clips,
                smilPath: ref.smilPath,
                nextClipAndPath: nextClipAndPath
            )

            // Copy the audio file
            let audioSrcPath = resolvedAudioPath(for: segmentClip, smilPath: ref.smilPath)
            let audioFileName = copyAudioFile(
                from: audioSrcPath,
                provider: provider,
                toDirectory: audioDir,
                fileNamesBySourcePath: &copiedAudioFileNamesByPath,
                usedFileNames: &usedAudioFileNames,
                fileManager: fm
            )

            segments.append(AudioSegment(
                title: ref.heading.text,
                file: audioFileName,
                startTime: startTime,
                endTime: endTime
            ))
        }

        // Copy remaining audio files
        copyRemainingAudioFiles(from: provider, toDirectory: audioDir)

        return AudioManifest(
            title: nccResult.title.isEmpty ? nil : nccResult.title,
            author: nccResult.author.isEmpty ? nil : nccResult.author,
            segments: segments
        )
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

    /// Determine the boundary for a DAISY segment, accounting for clips in
    /// different files that happen to share the same basename.
    static func segmentEndTime(
        for segmentClip: DAISYAudioClip,
        clips: [DAISYAudioClip],
        smilPath: String,
        nextClipAndPath: (clip: DAISYAudioClip, smilPath: String)?
    ) -> Double {
        let currentAudioPath = resolvedAudioPath(for: segmentClip, smilPath: smilPath)
        let sameAudioClips = clips.filter {
            resolvedAudioPath(for: $0, smilPath: smilPath) == currentAudioPath
        }

        var endTime = sameAudioClips.last?.endTime ?? segmentClip.endTime

        if let nextClipAndPath,
           resolvedAudioPath(for: nextClipAndPath.clip, smilPath: nextClipAndPath.smilPath) == currentAudioPath {
            endTime = nextClipAndPath.clip.startTime
        }

        return endTime
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
                let audioData = try provider.readFile(at: sourcePath)
                try audioData.write(to: destPath)
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
                    let fileData = try provider.readFile(at: path)
                    try fileData.write(to: destPath)
                } catch {
                    print("Warning: Failed to copy remaining audio file \(path): \(error.localizedDescription)")
                }
            }
        }
    }
}
