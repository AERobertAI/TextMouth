import AVFoundation

// MARK: - A Pause

/// A pause in the edited audio (FR04): a stretch quieter than the speech
/// around it, long enough to be one, found by its level. The editor moves
/// from pause to pause, selects up to one, and lists them with their
/// lengths, so a place can be found without a waveform.
struct AudioEditorPause: Equatable, Hashable, Sendable, Identifiable {
    /// Where the pause begins, in seconds on the edited audio.
    let start: TimeInterval
    /// Where it ends: where the sound after it begins.
    let end: TimeInterval

    /// Pauses are told apart by where they begin.
    var id: TimeInterval { start }

    /// How long the pause lasts, in seconds.
    var duration: TimeInterval { end - start }
}

// MARK: - The Audio's Levels

/// How loud the edited audio is, a level for every hundredth of a second
/// (FR04): what the editor finds pauses in, as the research's level search
/// did (10-millisecond windows quiet for long enough), and what its
/// waveform draws for sighted helpers.
///
/// The levels are measured from the edited audio itself, the same
/// composition the preview plays, read once off the main thread after each
/// edit, mixed to one channel; a pass streams the audio a buffer at a time,
/// so memory stays small whatever the audio's length.
struct AudioEditorLevels: Equatable, Sendable {
    /// The seconds each level stands for.
    static let window: TimeInterval = 0.01
    /// The level that stands for digital silence, in dBFS: lower than any
    /// sound, so a window of zeros is never mistaken for a quiet sound.
    static let silence: Float = -120
    /// The shortest stretch the editor calls a pause, in seconds: the gap
    /// between a narrator's sentences, longer than a breath between words.
    static let shortestPause: TimeInterval = 0.4

    /// The level of each window, in decibels relative to full scale, of its
    /// root mean square: 0 at most, `silence` at least.
    let decibels: [Float]
    /// How long the audio measured lasts, in seconds.
    let duration: TimeInterval
    /// The loudest level of each of `overviewCount` equal stretches, made
    /// once as the levels are measured, so the waveform draws from a few
    /// thousand values however long the audio, and redraws cheaply as the
    /// cursor moves.
    let overview: [Float]

    /// How many stretches the overview has: more than any window is wide.
    static let overviewCount = 4_096

    /// The levels `decibels` of audio lasting `duration` seconds.
    init(decibels: [Float], duration: TimeInterval) {
        self.decibels = decibels
        self.duration = duration
        overview = Self.loudest(of: decibels, in: min(Self.overviewCount, decibels.count))
    }

    // MARK: Pauses

    /// The level below which a window counts as quiet: 15 dB above the
    /// background (the quietest tenth of the windows, silence counted as
    /// -90 dBFS), kept between -60 and -30 dBFS, so a recording's own room
    /// tone sets it, as the research recommended.
    var pauseThreshold: Float {
        guard !decibels.isEmpty else { return -45 }
        let sorted = decibels.map { max($0, -90) }.sorted()
        let background = sorted[min(sorted.count - 1, sorted.count / 10)]
        return min(-30, max(-60, background + 15))
    }

    /// The pauses: every run of quiet windows lasting at least `shortest`
    /// seconds, in order, each ending where the sound after it begins (the
    /// end of the audio for a pause that reaches it).
    func pauses(shortest: TimeInterval = AudioEditorLevels.shortestPause) -> [AudioEditorPause] {
        let threshold = pauseThreshold
        let minimumWindows = max(1, Int((shortest / Self.window).rounded()))
        var found: [AudioEditorPause] = []
        var runStart: Int?
        /// Ends the quiet run under way at window `index`, keeping it when
        /// long enough.
        func closeRun(at index: Int) {
            guard let start = runStart else { return }
            runStart = nil
            guard index - start >= minimumWindows else { return }
            let end = min(duration, Double(index) * Self.window)
            let begin = Double(start) * Self.window
            if end > begin {
                found.append(AudioEditorPause(start: begin, end: end))
            }
        }
        for (index, level) in decibels.enumerated() {
            if level < threshold {
                if runStart == nil { runStart = index }
            } else {
                closeRun(at: index)
            }
        }
        closeRun(at: decibels.count)
        return found
    }

    // MARK: The Waveform

    /// The loudest level of each of `count` equal stretches of the audio,
    /// for a waveform `count` points wide, from the overview; empty when
    /// there is nothing to draw.
    func envelope(_ count: Int) -> [Float] {
        Self.loudest(of: overview, in: count)
    }

    /// The loudest of `values` in each of `count` equal stretches of them;
    /// empty for none. A stretch narrower than one value takes the value it
    /// falls in.
    static func loudest(of values: [Float], in count: Int) -> [Float] {
        guard count > 0, !values.isEmpty else { return [] }
        return (0..<count).map { bucket in
            let start = min(values.count - 1, values.count * bucket / count)
            let end = max(start + 1, values.count * (bucket + 1) / count)
            return values[start..<min(end, values.count)].max() ?? silence
        }
    }

    // MARK: Measuring

    /// The levels of `preview`, the edited audio's composition, read off the
    /// main thread.
    /// - Throws: `AudioEditError.renderFailed` when AVFoundation can't read
    ///   it, or `CancellationError` when the task is cancelled, as a newer
    ///   edit cancels the measurement of an older one.
    static func measure(_ preview: sending AudioEditComposition) async throws -> AudioEditorLevels {
        let rate = preview.sampleRate
        let tracks = try await preview.composition.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty, rate > 0 else { return AudioEditorLevels(decibels: [], duration: 0) }
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: preview.composition)
        } catch {
            throw AudioEditError.renderFailed("\((error as NSError).domain) \((error as NSError).code)")
        }
        // One channel of 32-bit floats at the audio's own rate: the mix
        // output sums the channels, which is what a level needs.
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: rate,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioEditError.renderFailed("the reader refused the audio") }
        reader.add(output)
        guard reader.startReading() else {
            throw AudioEditError.renderFailed(reader.error.map { "\(($0 as NSError).domain) \(($0 as NSError).code)" } ?? "no error was given")
        }

        var meter = WindowMeter(framesPerWindow: max(1, Int((rate * window).rounded())))
        // Each buffer's samples are copied out, since a block buffer need
        // not hold them in one piece; the copy is reused buffer to buffer.
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            do {
                try Task.checkCancellation()
            } catch {
                reader.cancelReading()
                throw error
            }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            if samples.count < count {
                samples = [Float](repeating: 0, count: count)
            }
            let copied = samples.withUnsafeMutableBytes { bytes -> OSStatus in
                guard let base = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size, destination: base)
            }
            guard copied == noErr else { continue }
            samples.withUnsafeBufferPointer { all in
                meter.add(UnsafeBufferPointer(rebasing: all[0..<count]))
            }
        }
        guard reader.status == .completed else {
            throw AudioEditError.renderFailed(reader.error.map { "\(($0 as NSError).domain) \(($0 as NSError).code)" } ?? "the reader stopped")
        }
        return AudioEditorLevels(decibels: meter.finish(), duration: Double(preview.frames) / rate)
    }

    /// Sums the squares of samples a window at a time and turns each
    /// window's mean into decibels.
    struct WindowMeter {
        /// How many samples a window holds.
        let framesPerWindow: Int
        /// The levels of the windows finished.
        private(set) var levels: [Float] = []
        /// The sum of squares of the window under way.
        private var sum: Double = 0
        /// How many samples it holds so far.
        private var count = 0

        init(framesPerWindow: Int) {
            self.framesPerWindow = framesPerWindow
        }

        /// Adds `samples` to the windows.
        mutating func add(_ samples: UnsafeBufferPointer<Float>) {
            for sample in samples {
                let value = Double(sample)
                sum += value * value
                count += 1
                if count == framesPerWindow {
                    closeWindow()
                }
            }
        }

        /// The levels, the last window's from the samples it has.
        mutating func finish() -> [Float] {
            if count > 0 {
                closeWindow()
            }
            return levels
        }

        /// Turns the window under way into its level and starts another.
        private mutating func closeWindow() {
            let mean = count > 0 ? sum / Double(count) : 0
            let level = mean > 0 ? Float(10 * log10(mean)) : AudioEditorLevels.silence
            levels.append(max(AudioEditorLevels.silence, min(0, level)))
            sum = 0
            count = 0
        }
    }
}
