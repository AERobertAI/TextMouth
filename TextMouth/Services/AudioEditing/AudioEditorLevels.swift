import AVFoundation
import os

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
/// composition the preview plays, read once after each edit on a thread of
/// its own, mixed to one channel; a pass streams the audio a buffer at a
/// time, so memory stays small whatever the audio's length.
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
        let sorted = decibels.map { max($0, -90) }.sortedStably()
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

    /// Told, on the reading thread, how many frames a measurement is about
    /// to read, just before its reader starts; nil in the app. Tests set it
    /// to see a measurement start, or to hold one there.
    static var readingObserver: (@Sendable (Int64) -> Void)? {
        get { readingObserverStore.withLock { $0 } }
        set { readingObserverStore.withLock { $0 = newValue } }
    }

    /// Backs `readingObserver`, which any thread may read or set.
    private static let readingObserverStore = OSAllocatedUnfairLock<(@Sendable (Int64) -> Void)?>(initialState: nil)

    /// The levels of `preview`, the edited audio's composition, read on a
    /// thread of its own: never on one of Swift's cooperative pool, which
    /// has as few threads as the Mac has cores and lends them only to work
    /// that keeps moving. A reader's `copyNextSampleBuffer` waits as long
    /// as it likes; a cancelled measurement that waited there could not see
    /// its cancellation, and a few of them at once left the pool with no
    /// thread for anything else (October 6, 2026).
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
            throw AudioEditError.renderFailed(name(error))
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

        // The reading thread hands back the levels, or the error, once; a
        // cancellation only asks it to stop, since Apple's contract forbids
        // cancelling a reader while it is being read.
        let reading = Reading(preview, reader: reader, output: output)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                reading.start { continuation.resume(with: $0) }
            }
        } onCancel: {
            reading.cancel()
        }
    }

    /// `error` as its domain and code, as the editor names AVFoundation's
    /// refusals.
    private static func name(_ error: any Error) -> String {
        "\((error as NSError).domain) \((error as NSError).code)"
    }

    /// One measurement's reading of its composition, on a thread of its
    /// own, to the end or until cancelled. A thread of its own rather than
    /// a dispatch queue (`OffMainWork`): a read may block for as long as
    /// CoreMedia takes, and a thread that does costs nothing else, where a
    /// worker of a queue that does is one fewer for every other queue.
    ///
    /// `@unchecked Sendable`: the composition, the reader, and its output
    /// belong to the reading thread alone once `start` has made it, and
    /// `cancelled` is read and changed only under its lock. The cancelling
    /// thread changes nothing else: `cancelReading` must not run while
    /// `copyNextSampleBuffer` does, so the reading thread cancels the
    /// reader itself, between buffers, once it sees the flag.
    private final class Reading: @unchecked Sendable {
        /// The composition read, kept so its sources live as long as the
        /// reader needs them.
        private let preview: AudioEditComposition
        private let reader: AVAssetReader
        private let output: AVAssetReaderAudioMixOutput
        /// Whether the measurement is to stop at its next buffer.
        private let cancelled = OSAllocatedUnfairLock(initialState: false)

        init(_ preview: AudioEditComposition, reader: AVAssetReader, output: AVAssetReaderAudioMixOutput) {
            self.preview = preview
            self.reader = reader
            self.output = output
        }

        /// Asks the reading thread to stop, which it does before its reader
        /// starts, or at the next buffer it gets.
        func cancel() {
            cancelled.withLock { $0 = true }
        }

        /// Whether the measurement was asked to stop.
        private var isCancelled: Bool {
            cancelled.withLock { $0 }
        }

        /// Starts the reading thread, which hands `finish` the levels or the
        /// error, exactly once, when it is done.
        func start(_ finish: @escaping @Sendable (Result<AudioEditorLevels, any Error>) -> Void) {
            let thread = Thread { [self] in finish(read()) }
            thread.name = "com.textmouth.audio-editor-levels"
            thread.qualityOfService = .userInitiated
            thread.start()
        }

        /// Reads the composition a buffer at a time, on the reading thread,
        /// and turns it into levels.
        private func read() -> Result<AudioEditorLevels, any Error> {
            AudioEditorLevels.readingObserver?(preview.frames)
            // A measurement cancelled before its reader starts never reads.
            guard !isCancelled else { return .failure(CancellationError()) }
            guard reader.startReading() else {
                return .failure(AudioEditorLevels.failure(of: reader, otherwise: "no error was given"))
            }

            let rate = preview.sampleRate
            var meter = WindowMeter(framesPerWindow: max(1, Int((rate * window).rounded())))
            // Each buffer's samples are copied out, since a block buffer need
            // not hold them in one piece; the copy is reused buffer to buffer.
            var samples: [Float] = []
            // The frames still to measure: a compressed take that ends the
            // audio decodes past its end, to the end of its last packet, and
            // those frames are none of the audio's (`AudioEditRenderer`).
            var remaining = Int(preview.frames)
            var ended = false
            while !ended {
                // Each buffer is read and measured in an autorelease pool of
                // its own: a thread of its own has none, and whatever
                // AVFoundation autoreleases for a buffer would otherwise
                // wait for the thread's end, hours of audio later.
                autoreleasepool {
                    guard let buffer = output.copyNextSampleBuffer() else {
                        ended = true
                        return
                    }
                    // A cancellation is seen here, between buffers: the only
                    // place the reader may be cancelled from.
                    guard !isCancelled else {
                        reader.cancelReading()
                        ended = true
                        return
                    }
                    Self.measure(buffer, into: &meter, samples: &samples, remaining: &remaining)
                }
            }
            guard !isCancelled else { return .failure(CancellationError()) }
            guard reader.status == .completed else {
                return .failure(AudioEditorLevels.failure(of: reader, otherwise: "the reader stopped"))
            }
            return .success(AudioEditorLevels(decibels: meter.finish(), duration: Double(preview.frames) / rate))
        }

        /// Adds `buffer`'s samples to `meter`, as many as `remaining` allows,
        /// through `samples`, the copy reused buffer to buffer.
        private static func measure(_ buffer: CMSampleBuffer, into meter: inout WindowMeter, samples: inout [Float], remaining: inout Int) {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { return }
            let count = min(CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size, remaining)
            remaining -= count
            guard count > 0 else { return }
            if samples.count < count {
                samples = [Float](repeating: 0, count: count)
            }
            let copied = samples.withUnsafeMutableBytes { bytes -> OSStatus in
                guard let base = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size, destination: base)
            }
            guard copied == noErr else { return }
            samples.withUnsafeBufferPointer { all in
                meter.add(UnsafeBufferPointer(rebasing: all[0..<count]))
            }
        }
    }

    /// The error `reader` stopped with, or `otherwise` when it gives none.
    private static func failure(of reader: AVAssetReader, otherwise: String) -> AudioEditError {
        .renderFailed(reader.error.map(name) ?? otherwise)
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
