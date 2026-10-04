import Foundation
import os

/// An ffmpeg executable installed on this Mac (FR04), which TextMouth runs,
/// when the user's setting allows, for every filter ffmpeg has and to write
/// MP3, which Core Audio can't. TextMouth bundles nothing of it: it only
/// looks for one, in Homebrew's and MacPorts' folders and along PATH.
///
/// It runs as a separate process, never on the main thread, with its
/// standard input closed and its errors read back: a refusal becomes
/// `AudioFilterError.ffmpegFailed` with ffmpeg's own first words, which name
/// the filter or option at fault. Cancelling the task that runs it stops
/// the process.
struct FFmpeg: Equatable, Sendable {
    /// The executable.
    let executable: URL

    /// Where Homebrew (on Apple silicon, then on Intel) and MacPorts install
    /// ffmpeg, looked in before PATH: an app opened from the Finder runs
    /// with a PATH that holds none of them.
    static let standardLocations = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"]

    /// The ffmpeg found first in `locations`, then in each folder of the
    /// PATH in `environment`: an executable file named ffmpeg. Nil when there
    /// is none. Reads only file metadata.
    static func locate(
        in locations: [String] = standardLocations,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> FFmpeg? {
        let path = (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/ffmpeg" }
        for candidate in locations + path where FileManager.default.isExecutableFile(atPath: candidate) {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isFolder), !isFolder.boolValue else { continue }
            return FFmpeg(executable: URL(fileURLWithPath: candidate))
        }
        return nil
    }

    // MARK: Commands

    /// The options every run starts with: no banner, no questions, only
    /// errors on standard error, and any output file replaced.
    static let quietOptions = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y"]

    /// Runs `chain`, in ffmpeg's own syntax and with every filter it has, on
    /// `input`, writing 32-bit float PCM in a CAF file at `output` at
    /// `sampleRate` in `channels` channels, whatever the filters did to them.
    func filter(_ input: URL, chain: String, to output: URL, sampleRate: Double, channels: Int) async throws {
        try await run(Self.quietOptions + [
            "-i", input.path,
            "-af", chain,
            "-ar", String(Int(sampleRate.rounded())),
            "-ac", String(channels),
            "-c:a", "pcm_f32le",
            "-f", "caf",
            output.path,
        ])
    }

    // MARK: Running

    /// Runs ffmpeg with `arguments` and waits for it to end, off the main
    /// thread.
    /// - Throws: `AudioFilterError.ffmpegMissing` when it can't be started,
    ///   `.ffmpegFailed` with its own words when it ends in failure, or
    ///   `CancellationError` when the task is cancelled, which stops it.
    func run(_ arguments: [String]) async throws {
        let executable = self.executable
        let running = OSAllocatedUnfairLock<Int32?>(initialState: nil)
        let outcome: (status: Int32, errors: Data) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = executable
                    process.arguments = arguments
                    let errors = Pipe()
                    process.standardError = errors
                    process.standardOutput = FileHandle.nullDevice
                    process.standardInput = FileHandle.nullDevice
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: AudioFilterError.ffmpegMissing)
                        return
                    }
                    running.withLock { $0 = process.processIdentifier }
                    // Read until ffmpeg closes standard error as it exits, so
                    // a full pipe never stalls it.
                    let data = errors.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    running.withLock { $0 = nil }
                    continuation.resume(returning: (process.terminationStatus, data))
                }
            }
        } onCancel: {
            if let pid = running.withLock({ $0 }) {
                kill(pid, SIGTERM)
            }
        }
        try Task.checkCancellation()
        guard outcome.status == 0 else {
            throw AudioFilterError.ffmpegFailed(Self.describe(String(decoding: outcome.errors, as: UTF8.self), status: outcome.status))
        }
    }

    /// What went wrong, in ffmpeg's own words from its standard error: its
    /// first lines that say anything, without the "[Parsed_volume_0 @
    /// 0x6000…]" prefixes naming its internals, ending in a full stop; or
    /// the exit code when it said nothing.
    static func describe(_ errors: String, status: Int32) -> String {
        let lines = errors
            .split(whereSeparator: \.isNewline)
            .map { line -> String in
                var text = String(line).trimmingCharacters(in: .whitespaces)
                while text.hasPrefix("["), let close = text.firstIndex(of: "]") {
                    text = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
                }
                return text
            }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return "it ended with code \(status)." }
        let words = lines.prefix(2).joined(separator: " ")
        return words.hasSuffix(".") ? words : words + "."
    }
}

// MARK: - Which Engine Runs Filters

/// What runs a filter chain (FR04): TextMouth's own filters, or the
/// installed ffmpeg, with every filter it has. One chain, in ffmpeg's
/// syntax, serves both.
enum AudioFilterEngine: Equatable, Sendable {
    /// TextMouth's own filters (`AudioBuiltInFilter`).
    case builtIn
    /// The installed ffmpeg.
    case ffmpeg(FFmpeg)

    /// Whether TextMouth uses an installed ffmpeg, when it finds one:
    /// the setting `useInstalledFFmpeg`, on until the user turns it off, so
    /// a Mac with ffmpeg uses it from the start. Mirrored in config.json.
    static let usePreference = StoredPreference.flag("useInstalledFFmpeg", default: true)

    /// The engine filters run on now: the installed ffmpeg when the setting
    /// in `store` allows it and `locate` finds one; TextMouth's own otherwise.
    /// Looks at file metadata only.
    static func current(
        in store: UserDefaults = TextMouthRuntime.current.preferences,
        locate: () -> FFmpeg? = { FFmpeg.locate() }
    ) -> AudioFilterEngine {
        guard usePreference.read(from: store), let ffmpeg = locate() else { return .builtIn }
        return .ffmpeg(ffmpeg)
    }

    /// The installed ffmpeg this engine runs, or nil for TextMouth's own.
    var ffmpeg: FFmpeg? {
        if case .ffmpeg(let ffmpeg) = self { return ffmpeg }
        return nil
    }
}
