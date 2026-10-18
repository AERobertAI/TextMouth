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
    /// Whether the file says which channel is which (a layout such as
    /// "5.1 (L C R Ls Rs LFE)"), as afinfo prints it for the track or its
    /// format. False when the layout is "NA" or only "Discrete" channels:
    /// a mix to stereo then cannot tell the centre from a rear channel.
    /// True when afinfo prints no layout at all (nothing is known against
    /// the file).
    var hasChannelLayout = true

    /// Whether the codec keeps every bit of the source: linear PCM, ALAC,
    /// and FLAC.
    var isLossless: Bool {
        ["lpcm", "alac", "flac"].contains(formatID)
    }

    // MARK: - Plausibility

    /// The longest length believed at all, in seconds: one year, as
    /// `OggHeaderReader.maximumDuration`.
    static let maximumPlausibleDuration: TimeInterval = OggHeaderReader.maximumDuration

    /// The slack a linear PCM file's bound allows over its exact size:
    /// one percent of the length, and one second.
    private static let pcmRelativeSlack = 1.01
    private static let pcmAbsoluteSlackSeconds: TimeInterval = 1

    /// The lowest bit rate, in bits a second, that a file of this codec can
    /// have: no real file is smaller for its length. Linear PCM has exactly
    /// one rate (the sample rate times the channels times the bits a sample,
    /// 32 for floating point; 8 when afinfo gave no depth); the packed
    /// codecs have a rate that depends on the sample rate; the rest a table
    /// of the lowest rate the codec has.
    var lowestPlausibleBitRate: Double {
        let samplesPerSecond = sampleRate * Double(channels)
        switch formatID {
        case "lpcm":
            return samplesPerSecond * Double(isFloat ? 32 : (bitsPerSample ?? 8))
        case "ima4":
            return samplesPerSecond * 4
        case "ulaw", "alaw":
            return samplesPerSecond * 8
        case "samr": return 4_750
        case "sawb": return 6_600
        case "opus": return 6_000
        case ".mp3", ".mp2": return 8_000
        case ".mp1", "ac-3", "ec-3": return 32_000
        case _ where formatID.hasPrefix("aac"): return 8_000
        default: return 1_000
        }
    }

    /// Whether the file's own size can hold the length it claims. A header
    /// can say anything: a 136 KB CAF once claimed 25 billion seconds, and
    /// the converter's time limit and output reservation grew with it. The
    /// length is believed only when it is at most a year and at most the
    /// file's bits divided by the codec's lowest bit rate (linear PCM, which
    /// has exactly one rate, gets one percent and one second of slack).
    /// - Parameter bytes: The file's size in bytes.
    func isPlausible(inFileOfBytes bytes: Int64) -> Bool {
        guard duration <= Self.maximumPlausibleDuration else { return false }
        let longest = Double(max(bytes, 0)) * 8 / lowestPlausibleBitRate
        if formatID == "lpcm" {
            return duration <= longest * Self.pcmRelativeSlack + Self.pcmAbsoluteSlackSeconds
        }
        return duration <= longest
    }

    /// The log line for a file whose claimed length its size cannot hold,
    /// with the length in whole seconds.
    static func implausibleLogLine(file: String, duration: TimeInterval, bytes: Int64) -> String {
        "AUDIO_INFO_IMPLAUSIBLE: \(file): claims \(String(format: "%.0f", duration)) seconds in \(bytes) bytes"
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
            "channel_layout", "format_list/format/channel_layout",
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
                isFloat: isFloat,
                hasChannelLayout: Self.hasChannelLayout(values["channel_layout"], values["format_list/format/channel_layout"])
            )
        }

        /// Whether the layouts afinfo printed (the track's, and its format's,
        /// where AAC in an .m4a keeps it) say which channel is which: any
        /// one that is named and not "NA" or "Discrete" does; all absent
        /// counts as saying so.
        private static func hasChannelLayout(_ layouts: String?...) -> Bool {
            let printed = layouts.compactMap { trimmed($0) }
            guard !printed.isEmpty else { return true }
            return printed.contains { $0 != "NA" && !$0.isEmpty && !$0.localizedCaseInsensitiveContains("discrete") }
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
    ///   kills it (logged as `AUDIO_INFO_KILLED`), its output does not
    ///   parse, or the length it claims is more than the file's size can
    ///   hold (logged as `AUDIO_INFO_IMPLAUSIBLE`).
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
            guard let info = parse(xml: result.output) else { return nil }
            guard info.isPlausible(inFileOfBytes: bytes) else {
                DiagnosticLog.event(
                    .storage, implausibleLogLine(file: url.lastPathComponent, duration: info.duration, bytes: bytes)
                )
                return nil
            }
            return info
        case .exited, .couldNotStart:
            return nil
        case let .killed(reason):
            DiagnosticLog.event(.storage, "AUDIO_INFO_KILLED: \(url.lastPathComponent): \(reason.words)")
            return nil
        }
    }
}
