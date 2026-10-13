import AVFoundation
import CryptoKit

/// Renders a stretch of an edit timeline through a filter chain (FR04): what
/// filter and gain edits apply through. The stretch is rendered to 32-bit
/// float PCM, run through the chain by `engine`, TextMouth's own filters or
/// the installed ffmpeg, and kept in the edit's scratch folder under a name
/// made from everything that decides it: the audio the edits start from,
/// the stretch, the chain, and the engine. Applying the same edit again, as
/// undo and redo and a later render do, reads it back instead of rendering
/// it again.
struct AudioFilterProcessor: AudioEditProcessing {
    /// Where the stretches' sound comes from.
    let sources: AudioEditComposition.Sources
    /// What runs the chain.
    let engine: AudioFilterEngine

    func process(_ stretch: AudioEditTimeline, chain: String) async throws -> AudioEditTimeline.Segment {
        // TextMouth's own engine checks the chain before anything is
        // rendered; ffmpeg takes it as written and says what it refuses.
        let filters: [AudioBuiltInFilter]?
        switch engine {
        case .builtIn:
            filters = try AudioFilterChain.parse(chain).builtInFilters()
        case .ffmpeg:
            guard !chain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AudioFilterError.empty }
            filters = nil
        }
        let name = "processed-\(cacheKey(of: stretch, chain: chain)).caf"
        let result = sources.scratch.appendingPathComponent(name)
        if let frames = try? Self.frames(of: result, at: stretch.sampleRate) {
            return AudioEditTimeline.Segment(source: .processed(name), sourceStart: 0, length: frames)
        }

        try AudioEditScratch.make(sources.scratch)
        let input = sources.scratch.appendingPathComponent(".\(UUID().uuidString).input.caf")
        let partial = sources.scratch.appendingPathComponent(".\(UUID().uuidString).processed.caf")
        defer {
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: partial)
        }
        _ = try await AudioEditRenderer.render(
            stretch,
            sources: sources,
            to: input,
            format: .pcmCAF,
            settings: AudioRenderSettings.floatCAF(for: sources.base),
            metadata: AudioRenderMetadata(title: "", author: nil)
        )
        if let filters {
            try AudioFilterRunner.run(filters, input: input, output: partial, scratch: sources.scratch)
        } else if let ffmpeg = engine.ffmpeg {
            try await ffmpeg.filter(
                input,
                chain: chain,
                to: partial,
                sampleRate: stretch.sampleRate,
                channels: sources.base.channelCount
            )
        }
        // The result's name is made from everything that decides its sound,
        // so another render of this very stretch (a preview and a level
        // measurement can ask at once) makes the same file. Each puts its
        // own in place in one step, so neither ever finds the result
        // missing (#1988).
        try SavedFile.renameReplacing(partial, result)
        return AudioEditTimeline.Segment(
            source: .processed(name),
            sourceStart: 0,
            length: try Self.frames(of: result, at: stretch.sampleRate)
        )
    }

    /// How many frames the audio file at `url` lasts at `rate`.
    private static func frames(of url: URL, at rate: Double) throws -> Int64 {
        let file = try AVAudioFile(forReading: url)
        let fileRate = file.fileFormat.sampleRate
        return fileRate == rate ? file.length : Int64((Double(file.length) * rate / fileRate).rounded())
    }

    /// The name, in hexadecimal, of the result of running `chain` on
    /// `stretch`: a digest of everything that decides it. Take and processed
    /// files are never changed once written, so their names stand for their
    /// sound; the audio the edits start from and an installed ffmpeg are
    /// named with their sizes and dates, so a different file or ffmpeg is a
    /// different result.
    private func cacheKey(of stretch: AudioEditTimeline, chain: String) -> String {
        func stamp(_ url: URL) -> String {
            FileStamp(of: url).map { "\($0.byteCount)/\($0.modificationTimeNanoseconds)" } ?? "unstamped"
        }
        let engineName: String
        switch engine {
        case .builtIn: engineName = "textmouth-1"
        case .ffmpeg(let ffmpeg): engineName = "ffmpeg \(ffmpeg.executable.path) \(stamp(ffmpeg.executable))"
        }
        let stretches = stretch.segments.map { segment -> String in
            let source: String
            switch segment.source {
            case .base: source = "base"
            case .take(let path): source = "take \(path)"
            case .silence: source = "silence"
            case .processed(let name): source = "processed \(name)"
            }
            return "\(source) \(segment.sourceStart) \(segment.length)"
        }
        let description = [
            engineName,
            chain,
            "\(stretch.sampleRate) \(sources.base.channelCount)",
            "base \(sources.base.url.path) \(stamp(sources.base.url))",
        ] + stretches
        let digest = SHA256.hash(data: Data(description.joined(separator: "\n").utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

extension AudioRenderSettings {
    /// 32-bit float PCM in a CAF file at `base`'s rate and channels: what a
    /// filter chain reads and writes, which loses nothing between filters.
    static func floatCAF(for base: AudioEditBase) -> AudioRenderSettings {
        AudioRenderSettings(
            format: .pcmCAF,
            sampleRate: base.sampleRate,
            channels: base.channelCount,
            bitRate: nil,
            bitsPerSample: 32,
            isFloat: true
        )
    }
}
