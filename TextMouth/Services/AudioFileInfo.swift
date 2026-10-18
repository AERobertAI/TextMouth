import Foundation

/// What `afinfo`, run in a watched child process, says about an audio file
/// (FMT09): its container, codec, channels, sample rate, bit depth, and
/// length. The import needs these before it converts a file `afconvert` can
/// read (AC-3, AMR, MP2, AIFC, CAF, Wave64, and others).
///
/// The facts come from a child process and never from AudioFile or
/// AVFoundation inside the app: since October 14, 2026, when Apple's Vorbis
/// decoder locked up inside TextMouth, no source file of a format the import
/// converts is opened by Apple's audio frameworks in this process.
struct AudioFileInfo: Equatable, Sendable {
    /// The container, as afinfo prints it with its quotes removed:
    /// "caff", "ac-3", "NeXT", "WAVE".
    let fileType: String
    /// The codec, as afinfo prints it with its spaces kept: "lpcm", "alac",
    /// "flac", "aac ", "ac-3", "samr", ".mp2", "ima4", "ulaw", "opus".
    let formatID: String
    /// How many channels the first track has.
    let channels: Int
    /// The first track's sample rate, in hertz.
    let sampleRate: Double
    /// The first track's length, in seconds.
    let duration: TimeInterval
    /// The bits in one sample of linear PCM (its own depth), or of the source
    /// a lossless codec (ALAC, FLAC) kept; nil for floating-point PCM and for
    /// lossy codecs, which have none.
    let bitsPerSample: Int?
    /// Whether the samples are floating-point numbers (linear PCM only).
    let isFloat: Bool

    /// Whether the codec keeps every bit of the source: linear PCM, ALAC,
    /// and FLAC.
    var isLossless: Bool {
        ["lpcm", "alac", "flac"].contains(formatID)
    }

    // MARK: - Parsing

    /// Reads the first track of the first audio file in afinfo's XML output
    /// (`afinfo -x -r`). A codec such as AC-3 nests `format` elements with
    /// their own channels and sample rate; only the track's own count.
    /// - Returns: Nil for malformed XML, no track, fewer than one channel, a
    ///   sample rate or duration that is not a finite number above zero, or
    ///   an empty format.
    static func parse(xml: Data) -> AudioFileInfo? {
        let collector = FactCollector()
        let parser = XMLParser(data: xml)
        parser.delegate = collector
        guard parser.parse() else { return nil }
        return collector.info()
    }

    /// Collects the few elements `parse` wants from afinfo's XML, by their
    /// path from the root, ignoring everything else.
    private final class FactCollector: NSObject, XMLParserDelegate {
        /// The path of the first audio file's file type.
        private static let fileTypePath = "audio_info/audio_file/file_type"
        /// Where a track starts; its own elements follow, `trackPrefix` deep.
        private static let trackPath = "audio_info/audio_file/tracks/track"
        private static let filePath = "audio_info/audio_file"
        private static let trackPrefix = trackPath + "/"
        /// The track elements read, relative to the track.
        private static let wantedInTrack: Set<String> = [
            "num_channels", "sample_rate", "format_type", "bit_depth", "duration",
            "pcm_info/data_type", "source_info/bit_depth",
        ]

        /// The names of the elements open now, outermost first.
        private var stack: [String] = []
        /// How many audio files and tracks have started: only the first of
        /// each counts.
        private var fileCount = 0
        private var trackCount = 0
        /// The characters of the wanted element open now, if one is.
        private var text: String?
        /// The text of each wanted element, first one wins: the file type
        /// under "file_type", the track's under its path from the track.
        private(set) var values: [String: String] = [:]

        /// The open elements' path, "audio_info/audio_file/...".
        private var path: String { stack.joined(separator: "/") }

        /// The key under which the element open now is kept, or nil when it
        /// is not one of the first track's wanted elements (or the first
        /// file's type).
        private func keyOfCurrentElement() -> String? {
            let current = path
            if current == Self.fileTypePath, fileCount == 1 { return "file_type" }
            guard fileCount == 1, trackCount == 1, current.hasPrefix(Self.trackPrefix) else { return nil }
            let relative = String(current.dropFirst(Self.trackPrefix.count))
            return Self.wantedInTrack.contains(relative) ? relative : nil
        }

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
        ) {
            stack.append(elementName)
            switch path {
            case Self.filePath: fileCount += 1
            case Self.trackPath: trackCount += 1
            default: break
            }
            text = keyOfCurrentElement() == nil ? nil : ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text?.append(string)
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            if let text, let key = keyOfCurrentElement(), values[key] == nil {
                values[key] = text
            }
            text = nil
            stack.removeLast()
        }

        /// The facts as an `AudioFileInfo`, or nil when any is missing or
        /// out of range.
        func info() -> AudioFileInfo? {
            guard let formatID = values["format_type"], !formatID.isEmpty,
                  let channels = values["num_channels"].flatMap(Self.integer), channels >= 1,
                  let sampleRate = values["sample_rate"].flatMap(Self.number), sampleRate > 0,
                  let duration = values["duration"].flatMap(Self.number), duration > 0
            else { return nil }
            let isLinear = formatID == "lpcm"
            let isFloat = isLinear && Self.trimmed(values["pcm_info/data_type"]) == "float"
            let bits: Int?
            if isLinear {
                bits = isFloat ? nil : values["bit_depth"].flatMap(Self.integer)
            } else if formatID == "alac" || formatID == "flac" {
                bits = values["source_info/bit_depth"].flatMap(Self.integer)
            } else {
                bits = nil
            }
            return AudioFileInfo(
                fileType: Self.trimmed(values["file_type"])?.replacingOccurrences(of: "'", with: "") ?? "",
                formatID: formatID,
                channels: channels,
                sampleRate: sampleRate,
                duration: duration,
                bitsPerSample: bits.flatMap { $0 > 0 ? $0 : nil },
                isFloat: isFloat
            )
        }

        /// `text` without the white space around it; nil stays nil.
        private static func trimmed(_ text: String?) -> String? {
            text?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// A whole number from `text`, or nil.
        private static func integer(_ text: String) -> Int? {
            Int(trimmed(text) ?? "")
        }

        /// A finite number from `text`, or nil.
        private static func number(_ text: String) -> Double? {
            Double(trimmed(text) ?? "").flatMap { $0.isFinite ? $0 : nil }
        }
    }

    // MARK: - Asking afinfo

    /// What runs afinfo and what watches it: Apple's tool under the
    /// watchdog's rules in the app, replaced in tests by a stand-in child
    /// (a `sleep`, a failing shell) and tight limits.
    struct Tool: Sendable {
        /// The executable and arguments that print the facts of the file.
        var command: @Sendable (_ file: URL) -> (executable: URL, arguments: [String])
        /// What the watchdog allows a file of the given size in bytes.
        var limits: @Sendable (_ bytes: Int64) -> WatchedProcess.Limits
        /// How the watchdog reads the child's resident memory.
        var residentMemory: @Sendable (pid_t) -> Int64?

        /// `/usr/bin/afinfo -x -r <file>`: the facts as XML. It prints only
        /// when it ends, so the stall allowance is the whole run's.
        static let afinfo = Tool(
            command: { file in
                (URL(fileURLWithPath: "/usr/bin/afinfo"), ["-x", "-r", file.path])
            },
            limits: { bytes in
                let seconds = 30 + Double(bytes) / 20_000_000
                return WatchedProcess.Limits(
                    maximumSeconds: seconds,
                    maximumResidentBytes: 536_870_912,
                    maximumStalledSeconds: seconds
                )
            },
            residentMemory: { WatchedProcess.residentMemory(of: $0) }
        )
    }

    // MARK: - Reading

    /// Asks `tool` what the file at `url` holds. The app never opens the
    /// file itself.
    /// - Returns: The facts, or nil when the file is missing or only in the
    ///   cloud, the tool cannot start or exits with a failure, the watchdog
    ///   kills it (logged as `AUDIO_INFO_KILLED`), or its output does not
    ///   parse.
    /// - Throws: `CancellationError` only.
    static func read(_ url: URL, using tool: Tool = .afinfo) async throws -> AudioFileInfo? {
        let fileManager = FileManager.default
        // A file in the cloud only is never downloaded for a look at it.
        guard fileManager.fileExists(atPath: url.path), !DatalessFiles.isDataless(url) else { return nil }
        let bytes = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        let command = tool.command(url)
        let result = try await WatchedProcess.runCapturingOutput(
            command.executable,
            arguments: command.arguments,
            limits: tool.limits(bytes),
            residentMemory: tool.residentMemory
        )
        switch result.outcome {
        case .exited(status: 0):
            return parse(xml: result.output)
        case .exited, .couldNotStart:
            return nil
        case let .killed(reason):
            DiagnosticLog.event(.storage, "AUDIO_INFO_KILLED: \(url.lastPathComponent): \(reason.words)")
            return nil
        }
    }
}
