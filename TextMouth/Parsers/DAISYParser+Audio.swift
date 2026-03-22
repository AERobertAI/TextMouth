import Foundation

// MARK: - Audio SMIL Parser

/// An audio clip extracted from a DAISY SMIL file
struct DAISYAudioClip {
    var file: String        // audio filename (relative path)
    var startTime: Double   // seconds
    var endTime: Double     // seconds
}

/// SAX parser for DAISY SMIL files that extracts audio clip references.
/// Handles both DAISY 2.02 (clip-begin="npt=SS.SSSs") and DAISY 3
/// (clipBegin="H:MM:SS.mmm") timing formats.
class DAISYAudioSMILParser: NSObject, XMLParserDelegate {
    private let data: Data
    private(set) var audioClips: [DAISYAudioClip] = []

    init(data: Data) {
        self.data = data
    }

    func parse() -> [DAISYAudioClip] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.parse()
        return audioClips
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let localName = ParserUtilities.stripNamespacePrefix(elementName).lowercased()

        if localName == "audio" {
            guard let src = attributes["src"], !src.isEmpty else { return }

            // Try DAISY 3 format first (clipBegin/clipEnd)
            var startTime: Double = 0
            var endTime: Double = 0

            if let begin = attributes["clipBegin"] {
                startTime = parseDAISYTime(begin)
            } else if let begin = attributes["clip-begin"] {
                // DAISY 2.02 format
                startTime = parseDAISYTime(begin)
            }

            if let end = attributes["clipEnd"] {
                endTime = parseDAISYTime(end)
            } else if let end = attributes["clip-end"] {
                endTime = parseDAISYTime(end)
            }

            audioClips.append(DAISYAudioClip(
                file: src,
                startTime: startTime,
                endTime: endTime
            ))
        }
    }

    /// Parse a DAISY time string to seconds.
    /// Supports both formats:
    ///   DAISY 2.02: "npt=SS.SSSs" (e.g. "npt=38.228s")
    ///   DAISY 3:    "H:MM:SS.mmm" (e.g. "0:02:43.650")
    private func parseDAISYTime(_ timeStr: String) -> Double {
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
        let opfData = try provider.readFile(at: opfPath)
        let opfParser = DAISYOPFParser(data: opfData)
        let opfResult = opfParser.parse()
        let opfDir = (opfPath as NSString).deletingLastPathComponent

        // Parse NCX for heading structure
        guard let ncxPath = allFiles.first(where: { $0.lowercased().hasSuffix(".ncx") }) else {
            throw DAISYParserError.missingContent("No NCX file found")
        }
        let ncxData = try provider.readFile(at: ncxPath)
        let ncxParser = DAISYNCXParser(data: ncxData)
        let navPoints = ncxParser.parse()

        // For each navPoint, find its SMIL file and extract the first audio clip
        // to determine the chapter's audio start time
        var segments: [AudioSegment] = []
        let fm = FileManager.default

        for (i, navPoint) in navPoints.enumerated() {
            let smilRef = navPoint.contentSrc
            let smilFile = smilRef.components(separatedBy: "#").first ?? smilRef
            let smilPath = opfDir.isEmpty ? smilFile : "\(opfDir)/\(smilFile)"

            guard let smilData = try? provider.readFile(at: smilPath) else { continue }
            let smilParser = DAISYAudioSMILParser(data: smilData)
            let clips = smilParser.parse()
            guard let firstClip = clips.first else { continue }

            // Use the last clip's end time as the segment end
            let lastClip = clips.last ?? firstClip
            let endTime = lastClip.endTime

            // Copy the audio file to the output directory
            let audioFileName = (firstClip.file as NSString).lastPathComponent
            let audioSrcPath = opfDir.isEmpty ? firstClip.file : "\(opfDir)/\(firstClip.file)"
            let destPath = audioDir.appendingPathComponent(audioFileName)

            if !fm.fileExists(atPath: destPath.path) {
                do {
                    let audioData = try provider.readFile(at: audioSrcPath)
                    try audioData.write(to: destPath)
                } catch {
                    print("Warning: Failed to copy audio file \(audioSrcPath): \(error.localizedDescription)")
                }
            }

            segments.append(AudioSegment(
                title: navPoint.label,
                file: audioFileName,
                startTime: firstClip.startTime,
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
        let nccData = try provider.readFile(at: nccPath)
        guard let nccHTML = String(data: nccData, encoding: .utf8)
                ?? String(data: nccData, encoding: .isoLatin1) else {
            throw DAISYParserError.parseError("Cannot decode ncc.html")
        }

        let nccParser = DAISY202NCCParser(html: nccHTML)
        let nccResult = nccParser.parse()
        let nccDir = (nccPath as NSString).deletingLastPathComponent

        // For each NCC heading, follow the SMIL reference to find audio clips
        var segments: [AudioSegment] = []
        let fm = FileManager.default

        for heading in nccResult.headings {
            let smilRef = heading.href
            let smilFile = smilRef.components(separatedBy: "#").first ?? smilRef
            let smilPath = nccDir.isEmpty ? smilFile : "\(nccDir)/\(smilFile)"

            guard let smilData = try? provider.readFile(at: smilPath) else { continue }
            let smilParser = DAISYAudioSMILParser(data: smilData)
            let clips = smilParser.parse()
            guard let firstClip = clips.first else { continue }

            let lastClip = clips.last ?? firstClip

            // Copy the audio file
            let audioFileName = (firstClip.file as NSString).lastPathComponent
            let audioSrcPath: String
            let smilDir = (smilPath as NSString).deletingLastPathComponent
            if smilDir.isEmpty {
                audioSrcPath = firstClip.file
            } else {
                audioSrcPath = "\(smilDir)/\(firstClip.file)"
            }
            let destPath = audioDir.appendingPathComponent(audioFileName)

            if !fm.fileExists(atPath: destPath.path) {
                do {
                    let audioData = try provider.readFile(at: audioSrcPath)
                    try audioData.write(to: destPath)
                } catch {
                    print("Warning: Failed to copy audio file \(audioSrcPath): \(error.localizedDescription)")
                }
            }

            segments.append(AudioSegment(
                title: heading.text,
                file: audioFileName,
                startTime: firstClip.startTime,
                endTime: lastClip.endTime
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
