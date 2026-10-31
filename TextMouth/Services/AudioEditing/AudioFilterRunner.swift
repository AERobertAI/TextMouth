import AVFoundation

/// Runs TextMouth's own filters on audio files (FR04): every filter a pass
/// from one file of 32-bit float samples to another, a chunk at a time, so
/// memory stays small whatever the length. Plain DSP does what it does well
/// (volume, ffmpeg's biquads and fades, loudness normalization, silence
/// removal, the compressor, reversing), and Apple's time-pitch unit, rendered
/// offline by AVAudioEngine in manual rendering mode, changes the tempo.
/// Every pass is synchronous and CPU-bound: call it off the main thread.
enum AudioFilterRunner {
    /// Frames a pass reads at a time.
    private static let chunk: AVAudioFrameCount = 65_536

    /// Runs `filters` in order on `input`, writing the result to `output`,
    /// both CAF files of 32-bit float samples, the passes between them in
    /// `scratch`.
    /// - Throws: `AudioFilterError.badValue` for a value that doesn't fit the
    ///   audio (a frequency above half its sample rate, or a biquad's width
    ///   too wide to make a filter at its frequency), `CancellationError`
    ///   when the task running it is cancelled, or AVFoundation's errors.
    static func run(_ filters: [AudioBuiltInFilter], input: URL, output: URL, scratch: URL) throws {
        var current = input
        var made: [URL] = []
        defer { made.forEach { try? FileManager.default.removeItem(at: $0) } }
        for (index, filter) in filters.enumerated() {
            let next = index == filters.count - 1 ? output : scratch.appendingPathComponent(".pass-\(UUID().uuidString).caf")
            if next != output { made.append(next) }
            try apply(filter, from: current, to: next)
            current = next
        }
        if filters.isEmpty {
            try FileManager.default.copyItem(at: input, to: output)
        }
    }

    /// Runs one filter from `input` to `output`.
    private static func apply(_ filter: AudioBuiltInFilter, from input: URL, to output: URL) throws {
        switch filter {
        case .volume(let gain):
            try stream(from: input, to: output) { buffer, _ in scale(buffer, by: Float(gain)) }
        case .biquad(let parameters):
            try applyBiquad(parameters, from: input, to: output)
        case .fade(let fade):
            try applyFade(fade, from: input, to: output)
        case .tempo(let factor):
            try applyTempo(factor, from: input, to: output)
        case .loudness(let target, let truePeak):
            try normalize(toLoudness: target, truePeak: truePeak, from: input, to: output)
        case .silenceRemoval(let removal):
            try removeSilence(removal, from: input, to: output)
        case .compressor(let compressor):
            try compress(compressor, from: input, to: output)
        case .reverse:
            try reverse(from: input, to: output)
        }
    }

    // MARK: Files

    /// `url` opened for reading as 32-bit float samples, one buffer a channel.
    static func openInput(_ url: URL) throws -> AVAudioFile {
        try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// A new CAF file at `url` taking buffers of `format`, stored as they are.
    static func makeOutput(_ url: URL, format: AVAudioFormat) throws -> AVAudioFile {
        try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// A buffer of `format` holding up to `frames` frames.
    private static func buffer(_ format: AVAudioFormat, frames: AVAudioFrameCount = chunk) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw AudioEditError.unreadableAudio
        }
        return buffer
    }

    /// Reads `input` a chunk at a time, lets `change` change each chunk in
    /// place, given the frame it starts at, and writes it to `output`.
    private static func stream(from input: URL, to output: URL, _ change: (AVAudioPCMBuffer, Int64) throws -> Void) throws {
        let source = try openInput(input)
        let destination = try makeOutput(output, format: source.processingFormat)
        let piece = try buffer(source.processingFormat)
        while source.framePosition < source.length {
            try Task.checkCancellation()
            let start = source.framePosition
            try source.read(into: piece, frameCount: chunk)
            guard piece.frameLength > 0 else { break }
            try change(piece, start)
            try destination.write(from: piece)
        }
    }

    /// Calls `body` with each channel's samples of `buffer`.
    private static func eachChannel(_ buffer: AVAudioPCMBuffer, _ body: (UnsafeMutableBufferPointer<Float>, Int) -> Void) {
        guard let channels = buffer.floatChannelData else { return }
        for channel in 0..<Int(buffer.format.channelCount) {
            body(UnsafeMutableBufferPointer(start: channels[channel], count: Int(buffer.frameLength)), channel)
        }
    }

    /// Multiplies every sample of `buffer` by `gain`.
    private static func scale(_ buffer: AVAudioPCMBuffer, by gain: Float) {
        eachChannel(buffer) { samples, _ in
            for index in samples.indices { samples[index] *= gain }
        }
    }

    // MARK: Biquads

    /// A biquad's coefficients, divided by a0, as ffmpeg's af_biquads
    /// computes them (after the Audio EQ Cookbook).
    struct BiquadCoefficients: Equatable, Sendable {
        let b0, b1, b2, a1, a2: Double

        /// Whether every coefficient is a number, neither NaN nor infinite.
        var isFinite: Bool {
            [b0, b1, b2, a1, a2].allSatisfy(\.isFinite)
        }
    }

    /// The coefficients of `parameters` at `sampleRate`.
    /// - Throws: `AudioFilterError.badValue` for a frequency at or above half
    ///   the sample rate, which no biquad can reach, or for a width that
    ///   makes no usable filter at the frequency: one whose coefficients
    ///   aren't all finite, which would render NaN into every sample.
    static func coefficients(_ parameters: AudioBuiltInFilter.Biquad, sampleRate: Double) throws -> BiquadCoefficients {
        let frequency = parameters.frequency
        guard frequency < sampleRate / 2 else {
            throw AudioFilterError.badValue(
                filter: filterName(parameters.kind), option: "frequency", value: String(frequency),
                expected: "give a frequency below half the audio's sample rate, \(Int(sampleRate / 2)) Hz"
            )
        }
        let w0 = 2 * Double.pi * frequency / sampleRate
        let sine = sin(w0), cosine = cos(w0)
        let alpha: Double
        switch parameters.widthType {
        case .q: alpha = sine / (2 * parameters.width)
        case .hertz: alpha = sine / (2 * frequency / parameters.width)
        case .kilohertz: alpha = sine / (2 * frequency / (parameters.width * 1_000))
        case .octave: alpha = sine * sinh(log(2.0) / 2 * parameters.width * w0 / sine)
        }
        let b0, b1, b2, a0, a1, a2: Double
        switch (parameters.kind, parameters.poles) {
        case (.highpass, 1):
            a0 = 1; a1 = -exp(-w0); a2 = 0
            b0 = (1 - a1) / 2; b1 = -b0; b2 = 0
        case (.lowpass, 1):
            a0 = 1; a1 = -exp(-w0); a2 = 0
            b0 = 1 + a1; b1 = 0; b2 = 0
        case (.highpass, _):
            a0 = 1 + alpha; a1 = -2 * cosine; a2 = 1 - alpha
            b0 = (1 + cosine) / 2; b1 = -(1 + cosine); b2 = (1 + cosine) / 2
        case (.lowpass, _):
            a0 = 1 + alpha; a1 = -2 * cosine; a2 = 1 - alpha
            b0 = (1 - cosine) / 2; b1 = 1 - cosine; b2 = (1 - cosine) / 2
        case (.peaking, _):
            let amplitude = pow(10, parameters.gain / 40)
            a0 = 1 + alpha / amplitude; a1 = -2 * cosine; a2 = 1 - alpha / amplitude
            b0 = 1 + alpha * amplitude; b1 = -2 * cosine; b2 = 1 - alpha * amplitude
        }
        let normalized = BiquadCoefficients(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
        // A width can be too wide for its frequency. In octaves, the sinh of
        // ffmpeg's formula overflows to infinity past about 2,000 octaves, and
        // near half the sample rate, where sin(w0) is tiny, past one, so
        // alpha is infinite and the coefficients NaN: refused here, before a
        // render fills every sample with NaN and is saved over the book.
        guard normalized.isFinite else {
            throw AudioFilterError.badValue(
                filter: filterName(parameters.kind), option: "width", value: AudioBuiltInFilter.written(parameters.width),
                expected: "give a narrower width, since this one makes no usable filter at \(AudioBuiltInFilter.written(frequency)) Hz"
            )
        }
        return normalized
    }

    /// The name of the filter that makes a biquad of `kind`, as a chain
    /// writes it, for a refusal to name.
    private static func filterName(_ kind: AudioBuiltInFilter.Biquad.Kind) -> String {
        switch kind {
        case .highpass: return "highpass"
        case .lowpass: return "lowpass"
        case .peaking: return "equalizer"
        }
    }

    /// One channel's biquad state.
    private struct BiquadState {
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        /// Filters `samples` in place through `c`.
        mutating func filter(_ samples: UnsafeMutableBufferPointer<Float>, _ c: BiquadCoefficients) {
            for index in samples.indices {
                let x = Double(samples[index])
                let y = c.b0 * x + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2
                x2 = x1; x1 = x
                y2 = y1; y1 = y
                samples[index] = Float(y)
            }
        }
    }

    /// Runs a biquad, each channel through its own state.
    private static func applyBiquad(_ parameters: AudioBuiltInFilter.Biquad, from input: URL, to output: URL) throws {
        let rate = try openInput(input).processingFormat.sampleRate
        let c = try coefficients(parameters, sampleRate: rate)
        var states: [BiquadState] = []
        try stream(from: input, to: output) { buffer, _ in
            if states.isEmpty { states = Array(repeating: BiquadState(), count: Int(buffer.format.channelCount)) }
            eachChannel(buffer) { samples, channel in states[channel].filter(samples, c) }
        }
    }

    // MARK: Fades

    /// The gain of `curve` at `x`, from 0 to 1, as ffmpeg's afade computes it.
    static func fadeGain(_ curve: AudioBuiltInFilter.Fade.Curve, _ x: Double) -> Double {
        let g = min(max(x, 0), 1)
        func cube(_ v: Double) -> Double { v * v * v }
        switch curve {
        case .tri: return g
        case .qsin: return sin(g * .pi / 2)
        case .iqsin: return 0.636_943 * asin(g)
        case .esin: return 1 - cos(.pi / 4 * (cube(2 * g - 1) + 1))
        case .hsin: return (1 - cos(g * .pi)) / 2
        case .ihsin: return 0.318_471 * acos(1 - 2 * g)
        case .exp: return exp(-11.512_925_464_970_227 * (1 - g))
        case .log: return min(max(1 + 0.2 * log10(g), 0), 1)
        case .par: return 1 - sqrt(1 - g)
        case .ipar: return 1 - (1 - g) * (1 - g)
        case .qua: return g * g
        case .cub: return cube(g)
        case .squ: return sqrt(g)
        case .cbr: return cbrt(g)
        case .dese: return g <= 0.5 ? cbrt(2 * g) / 2 : 1 - cbrt(2 * (1 - g)) / 2
        case .desi: return g <= 0.5 ? cube(2 * g) / 2 : 1 - cube(2 * (1 - g)) / 2
        case .nofade: return 1
        }
    }

    /// Fades in or out, as ffmpeg's afade does: silent before a fade in, and
    /// after a fade out.
    private static func applyFade(_ fade: AudioBuiltInFilter.Fade, from input: URL, to output: URL) throws {
        let rate = try openInput(input).processingFormat.sampleRate
        let start = fade.startTime.map { Int64(($0 * rate).rounded()) } ?? fade.startSample
        let length = max(1, fade.duration.map { Int64(($0 * rate).rounded()) } ?? fade.sampleCount)
        /// The gain at frame `position` of the stretch.
        func gain(_ position: Int64) -> Float {
            let into = position - start
            let progress: Double
            if fade.fadesIn {
                progress = into < 0 ? 0 : Double(min(into, length)) / Double(length)
            } else {
                progress = into < 0 ? 1 : Double(max(length - into, 0)) / Double(length)
            }
            return Float(fade.silence + (fade.unity - fade.silence) * fadeGain(fade.curve, progress))
        }
        try stream(from: input, to: output) { buffer, first in
            eachChannel(buffer) { samples, _ in
                for index in samples.indices { samples[index] *= gain(first + Int64(index)) }
            }
        }
    }

    // MARK: Tempo

    /// Changes the tempo by `factor` without changing the pitch: Apple's
    /// time-pitch unit, rendered offline. The result lasts the input's length
    /// divided by `factor`.
    private static func applyTempo(_ factor: Double, from input: URL, to output: URL) throws {
        let source = try openInput(input)
        let format = source.processingFormat
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        timePitch.rate = Float(factor)
        engine.attach(player)
        engine.attach(timePitch)
        // A unit refusing a format says so here, as a Swift error; at
        // connect it would raise an Objective-C exception, which nothing can
        // catch (the research prototype's reverb).
        try timePitch.auAudioUnit.inputBusses[0].setFormat(format)
        try timePitch.auAudioUnit.outputBusses[0].setFormat(format)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        try engine.start()
        defer {
            player.stop()
            engine.stop()
        }
        player.scheduleFile(source, at: nil)
        player.play()

        let destination = try makeOutput(output, format: engine.manualRenderingFormat)
        let piece = try buffer(engine.manualRenderingFormat, frames: engine.manualRenderingMaximumFrameCount)
        let target = AVAudioFramePosition((Double(source.length) / factor).rounded())
        while engine.manualRenderingSampleTime < target {
            try Task.checkCancellation()
            let frames = AVAudioFrameCount(min(Int64(piece.frameCapacity), target - engine.manualRenderingSampleTime))
            switch try engine.renderOffline(frames, to: piece) {
            case .success:
                try destination.write(from: piece)
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                continue
            case .error:
                throw AudioEditError.renderFailed("the tempo change stopped")
            @unknown default:
                throw AudioEditError.renderFailed("the tempo change stopped")
            }
        }
    }

    // MARK: Loudness

    /// The integrated loudness of `url`, in LUFS, and its sample peak, as a
    /// linear amplitude: ITU-R BS.1770-4's K-weighted, gated loudness over
    /// 400 ms blocks every 100 ms. Nil loudness for audio with no block above
    /// the absolute gate (silence, or less than 400 ms of sound).
    static func loudness(of url: URL) throws -> (integrated: Double?, peak: Double) {
        let source = try openInput(url)
        let rate = source.processingFormat.sampleRate
        let channels = Int(source.processingFormat.channelCount)
        let weighting = kWeighting(sampleRate: rate)
        var shelves = Array(repeating: BiquadState(), count: channels)
        var highpasses = Array(repeating: BiquadState(), count: channels)
        let subBlock = Int64((rate * 0.1).rounded())
        var subBlocks: [Double] = []
        var energy = 0.0
        var filled: Int64 = 0
        var peak = 0.0
        let piece = try buffer(source.processingFormat)
        var scratch = [Float](repeating: 0, count: Int(chunk))
        while source.framePosition < source.length {
            try Task.checkCancellation()
            try source.read(into: piece, frameCount: chunk)
            let frames = Int(piece.frameLength)
            guard frames > 0, let data = piece.floatChannelData else { break }
            var frameEnergy = [Double](repeating: 0, count: frames)
            for channel in 0..<channels {
                scratch.withUnsafeMutableBufferPointer { weighted in
                    for index in 0..<frames {
                        weighted[index] = data[channel][index]
                        peak = max(peak, Double(abs(data[channel][index])))
                    }
                    let samples = UnsafeMutableBufferPointer(rebasing: weighted[0..<frames])
                    shelves[channel].filter(samples, weighting.shelf)
                    highpasses[channel].filter(samples, weighting.highpass)
                    for index in 0..<frames {
                        frameEnergy[index] += Double(samples[index]) * Double(samples[index])
                    }
                }
            }
            for value in frameEnergy {
                energy += value
                filled += 1
                if filled == subBlock {
                    subBlocks.append(energy)
                    energy = 0
                    filled = 0
                }
            }
        }
        // 400 ms blocks of four 100 ms sub-blocks, every 100 ms.
        guard subBlocks.count >= 4 else { return (nil, peak) }
        let blockFrames = Double(4 * subBlock)
        let blocks = (0...(subBlocks.count - 4)).map { start in
            subBlocks[start..<(start + 4)].reduce(0, +) / blockFrames
        }
        func loudness(_ meanSquare: Double) -> Double { -0.691 + 10 * log10(meanSquare) }
        let absolute = blocks.filter { $0 > 0 && loudness($0) > -70 }
        guard !absolute.isEmpty else { return (nil, peak) }
        let relativeGate = loudness(absolute.reduce(0, +) / Double(absolute.count)) - 10
        let gated = absolute.filter { loudness($0) > relativeGate }
        guard !gated.isEmpty else { return (nil, peak) }
        return (loudness(gated.reduce(0, +) / Double(gated.count)), peak)
    }

    /// BS.1770's K-weighting at `sampleRate`: a high shelf, then a high pass
    /// (libebur128's formulas, which give the standard's 48 kHz coefficients).
    private static func kWeighting(sampleRate rate: Double) -> (shelf: BiquadCoefficients, highpass: BiquadCoefficients) {
        var f0 = 1_681.974_450_955_533
        let gain = 3.999_843_853_973_347
        var q = 0.707_175_236_955_419_6
        var k = tan(Double.pi * f0 / rate)
        let vh = pow(10, gain / 20)
        let vb = pow(vh, 0.499_666_774_154_541_6)
        var a0 = 1 + k / q + k * k
        let shelf = BiquadCoefficients(
            b0: (vh + vb * k / q + k * k) / a0,
            b1: 2 * (k * k - vh) / a0,
            b2: (vh - vb * k / q + k * k) / a0,
            a1: 2 * (k * k - 1) / a0,
            a2: (1 - k / q + k * k) / a0
        )
        f0 = 38.135_470_876_024_44
        q = 0.500_327_037_323_877_3
        k = tan(Double.pi * f0 / rate)
        a0 = 1 + k / q + k * k
        let highpass = BiquadCoefficients(
            b0: 1, b1: -2, b2: 1,
            a1: 2 * (k * k - 1) / a0,
            a2: (1 - k / q + k * k) / a0
        )
        return (shelf, highpass)
    }

    /// Brings the integrated loudness to `target` LUFS with one gain, kept
    /// low enough that no sample rises above `truePeak` dBFS. Without a
    /// measurable loudness the audio is copied as it is.
    private static func normalize(toLoudness target: Double, truePeak: Double, from input: URL, to output: URL) throws {
        let measured = try loudness(of: input)
        guard let integrated = measured.integrated else {
            try FileManager.default.copyItem(at: input, to: output)
            return
        }
        var decibels = target - integrated
        if measured.peak > 0 {
            decibels = min(decibels, truePeak - 20 * log10(measured.peak))
        }
        let gain = Float(pow(10, decibels / 20))
        try stream(from: input, to: output) { buffer, _ in scale(buffer, by: gain) }
    }

    // MARK: Silence

    /// Removes silence as `removal` says: a pass measures the level of every
    /// window, then a pass copies all but the silences removed.
    private static func removeSilence(_ removal: AudioBuiltInFilter.SilenceRemoval, from input: URL, to output: URL) throws {
        let source = try openInput(input)
        let rate = source.processingFormat.sampleRate
        let window = max(1, Int64((removal.window * rate).rounded()))
        let levels = try windowLevels(source, window: window, detection: removal.detection)
        let total = source.length
        let removed = silencesToRemove(levels: levels, window: window, total: total, removal: removal, rate: rate)

        source.framePosition = 0
        let destination = try makeOutput(output, format: source.processingFormat)
        let piece = try buffer(source.processingFormat)
        var position: Int64 = 0
        for range in removed + [total..<total] {
            // Copies the sound up to the next removed silence, then skips it.
            while position < range.lowerBound {
                try Task.checkCancellation()
                source.framePosition = position
                let frames = AVAudioFrameCount(min(Int64(chunk), range.lowerBound - position))
                try source.read(into: piece, frameCount: frames)
                guard piece.frameLength > 0 else { break }
                try destination.write(from: piece)
                position += Int64(piece.frameLength)
            }
            position = max(position, range.upperBound)
        }
    }

    /// The level of each `window`-frame window of `source`: its loudest
    /// channel's peak or RMS.
    private static func windowLevels(_ source: AVAudioFile, window: Int64, detection: AudioBuiltInFilter.SilenceRemoval.Detection) throws -> [Double] {
        var levels: [Double] = []
        var accumulated = [Double](repeating: 0, count: Int(source.processingFormat.channelCount))
        var filled: Int64 = 0
        let piece = try buffer(source.processingFormat)
        func finishWindow() {
            let level = accumulated.map { detection == .rms ? sqrt($0 / Double(filled)) : $0 }.max() ?? 0
            levels.append(level)
            accumulated = accumulated.map { _ in 0 }
            filled = 0
        }
        while source.framePosition < source.length {
            try Task.checkCancellation()
            try source.read(into: piece, frameCount: chunk)
            let frames = Int(piece.frameLength)
            guard frames > 0, let data = piece.floatChannelData else { break }
            for index in 0..<frames {
                for channel in accumulated.indices {
                    let sample = Double(data[channel][index])
                    accumulated[channel] = detection == .rms
                        ? accumulated[channel] + sample * sample
                        : max(accumulated[channel], abs(sample))
                }
                filled += 1
                if filled == window { finishWindow() }
            }
        }
        if filled > 0 { finishWindow() }
        return levels
    }

    /// The frame ranges to remove, in order, given each window's level, as
    /// ffmpeg 7's silenceremove removes them (its af_silenceremove.c), a
    /// window at a time where it goes a sample at a time. ffmpeg measures
    /// the window that ends at each sample, so a silence is heard only once
    /// a whole window of it has passed: here, a window is silent when it and
    /// the one before it are, which puts each silence where ffmpeg puts it,
    /// to within a window.
    ///
    /// - The start (start_periods above 0): everything is trimmed until sound,
    ///   counted over the start, has lasted longer than `startDuration`,
    ///   `startPeriods` times over; the sound counted is trimmed too.
    ///   `startSilence` of what was trimmed, just before, is kept.
    /// - After it, once there has been sound, a silence longer than
    ///   `stopDuration` is a period: that much of it is kept. Once
    ///   `stopPeriods` periods are found, copying stops, `stopSilence` more
    ///   aside. A positive count stops it for good, removing everything
    ///   after; a negative one starts it again with the next sound, counting
    ///   afresh, so every long silence is shortened to `stopDuration` plus
    ///   `stopSilence`. Silence before the first sound never counts.
    static func silencesToRemove(
        levels: [Double],
        window: Int64,
        total: Int64,
        removal: AudioBuiltInFilter.SilenceRemoval,
        rate: Double
    ) -> [Range<Int64>] {
        func frames(_ seconds: TimeInterval) -> Int64 { Int64((seconds * rate).rounded()) }
        /// The frames of window `index`.
        func span(_ index: Int) -> Range<Int64> { (Int64(index) * window)..<min(total, Int64(index + 1) * window) }
        /// Whether window `index` is quiet as `threshold` hears it: at or
        /// below it, as is the window before it, if any.
        func isQuiet(_ index: Int, threshold: Double) -> Bool {
            levels[index] <= threshold && (index == 0 || levels[index - 1] <= threshold)
        }
        var ranges: [Range<Int64>] = []
        /// Adds `range` to those removed, joined to the last when they meet.
        func remove(_ range: Range<Int64>) {
            guard !range.isEmpty else { return }
            if let last = ranges.last, last.upperBound == range.lowerBound {
                ranges[ranges.count - 1] = last.lowerBound..<range.upperBound
            } else {
                ranges.append(range)
            }
        }

        // The start: the frame where the sound counted passes the duration
        // for the last time, found window by window.
        var copyFrom: Int64 = 0
        if removal.startPeriods > 0 {
            let needed = frames(removal.startDuration)
            var counted: Int64 = 0
            var found = 0
            var begin: Int64?
            search: for index in levels.indices where !isQuiet(index, threshold: removal.startThreshold) {
                let windowFrames = span(index)
                var position = windowFrames.lowerBound
                while position < windowFrames.upperBound {
                    // The frame that makes the count pass `needed`.
                    let passing = position + (needed - counted)
                    guard passing < windowFrames.upperBound else {
                        counted += windowFrames.upperBound - position
                        break
                    }
                    found += 1
                    counted = 0
                    if found >= removal.startPeriods {
                        begin = passing
                        break search
                    }
                    position = passing + 1
                }
            }
            // Without enough sound, nothing is left.
            guard let begin else {
                remove(0..<total)
                return ranges
            }
            copyFrom = max(0, begin - frames(removal.startSilence))
            remove(0..<copyFrom)
        }

        // After the start: silences counted in periods.
        guard removal.stopPeriods != 0, copyFrom < total else { return ranges }
        let restarts = removal.stopPeriods < 0
        let periodsNeeded = abs(removal.stopPeriods)
        let duration = frames(removal.stopDuration)
        let keptAfterStopping = frames(removal.stopSilence)
        var heardSound = false
        var silentRun: Int64 = 0
        var periods = 0
        var isCopying = true
        var keepLeft: Int64 = 0
        /// Keeps what `keepLeft` still allows of `position..<end` and
        /// removes the rest: copying has stopped.
        func keepWhatIsLeft(from position: Int64, to end: Int64) {
            let kept = min(keepLeft, end - position)
            keepLeft -= kept
            remove((position + kept)..<end)
        }
        for index in Int(copyFrom / window)..<levels.count {
            let windowFrames = span(index)
            var position = max(windowFrames.lowerBound, copyFrom)
            guard isQuiet(index, threshold: removal.stopThreshold) else {
                // Sound: a negative count copies again from here.
                heardSound = true
                silentRun = 0
                if restarts {
                    isCopying = true
                    periods = 0
                }
                if !isCopying { keepWhatIsLeft(from: position, to: windowFrames.upperBound) }
                continue
            }
            while position < windowFrames.upperBound {
                guard isCopying else {
                    keepWhatIsLeft(from: position, to: windowFrames.upperBound)
                    break
                }
                guard heardSound else { break }
                // The frame that makes the silence longer than `duration`.
                let passing = position + (duration - silentRun)
                guard passing < windowFrames.upperBound else {
                    silentRun += windowFrames.upperBound - position
                    break
                }
                periods += 1
                silentRun = 0
                if periods >= periodsNeeded {
                    // That frame goes; `keptAfterStopping` more are kept.
                    isCopying = false
                    keepLeft = keptAfterStopping
                    remove(passing..<(passing + 1))
                }
                position = passing + 1
            }
        }
        return ranges
    }

    // MARK: Compressor

    /// Compresses as ffmpeg's acompressor does, with its defaults: the
    /// channels' average level followed with attack and release, a soft
    /// knee, and the gain applied to every channel.
    private static func compress(_ parameters: AudioBuiltInFilter.Compressor, from input: URL, to output: URL) throws {
        let rate = try openInput(input).processingFormat.sampleRate
        let attack = min(1, 1 / (parameters.attack * rate / 4_000))
        let release = min(1, 1 / (parameters.release * rate / 4_000))
        let isRMS = parameters.detection == .rms
        let threshold = log(parameters.threshold)
        let kneeStart = log(parameters.threshold / sqrt(parameters.knee))
        let kneeStop = log(parameters.threshold * sqrt(parameters.knee))
        let compressedKneeStop = (kneeStop - threshold) / parameters.ratio + threshold
        let ratio = parameters.ratio
        let linearKneeStart = parameters.threshold / sqrt(parameters.knee)

        /// ffmpeg's gain for a level `slide`, linear.
        func gain(_ slide: Double) -> Double {
            var slope = log(slide)
            if isRMS { slope *= 0.5 }
            var gain = (slope - threshold) / ratio + threshold
            if parameters.knee > 1, slope < kneeStop {
                gain = hermite(slope, kneeStart, kneeStop, kneeStart, compressedKneeStop, 1, 1 / ratio)
            }
            return exp(gain - slope)
        }

        var slide = 0.0
        try stream(from: input, to: output) { buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            let channels = Int(buffer.format.channelCount)
            for index in 0..<Int(buffer.frameLength) {
                var level = 0.0
                for channel in 0..<channels {
                    let sample = Double(data[channel][index]) * parameters.levelIn
                    level += isRMS ? sample * sample : abs(sample)
                }
                level /= Double(channels)
                slide += (level - slide) * (level > slide ? attack : release)
                let compressed = slide > 0 && slide > (isRMS ? linearKneeStart * linearKneeStart : linearKneeStart)
                    ? gain(slide)
                    : 1
                let factor = parameters.levelIn * (compressed * parameters.makeup * parameters.mix + (1 - parameters.mix))
                for channel in 0..<channels {
                    data[channel][index] = Float(Double(data[channel][index]) * factor)
                }
            }
        }
    }

    /// ffmpeg's Hermite interpolation across the compressor's knee.
    private static func hermite(_ x: Double, _ x0: Double, _ x1: Double, _ p0: Double, _ p1: Double, _ m0: Double, _ m1: Double) -> Double {
        let width = x1 - x0
        let t = (x - x0) / width
        let tangent0 = m0 * width, tangent1 = m1 * width
        let t2 = t * t, t3 = t2 * t
        let c2 = -3 * p0 - 2 * tangent0 + 3 * p1 - tangent1
        let c3 = 2 * p0 + tangent0 - 2 * p1 + tangent1
        return c3 * t3 + c2 * t2 + tangent0 * t + p0
    }

    // MARK: Reverse

    /// Writes `input` backwards, reading it a chunk at a time from its end.
    private static func reverse(from input: URL, to output: URL) throws {
        let source = try openInput(input)
        let destination = try makeOutput(output, format: source.processingFormat)
        let piece = try buffer(source.processingFormat)
        let part = try buffer(source.processingFormat)
        var end = source.length
        while end > 0 {
            try Task.checkCancellation()
            let frames = AVAudioFrameCount(min(Int64(chunk), end))
            source.framePosition = end - Int64(frames)
            try readFully(source, frames: frames, into: piece, using: part)
            eachChannel(piece) { samples, _ in
                var reversed = samples
                reversed.reverse()
            }
            try destination.write(from: piece)
            end -= Int64(frames)
        }
    }

    /// Reads exactly `frames` frames from `file`, from where it stands, into
    /// `buffer`, by as many reads as it takes: one read of AVAudioFile can
    /// return fewer frames than asked (15,360 of 16,000 from a float WAVE
    /// file). `part` holds each read on the way.
    /// - Throws: `AudioEditError.unreadableAudio` when the file ends first.
    private static func readFully(_ file: AVAudioFile, frames: AVAudioFrameCount, into buffer: AVAudioPCMBuffer, using part: AVAudioPCMBuffer) throws {
        guard let target = buffer.floatChannelData, let source = part.floatChannelData else {
            throw AudioEditError.unreadableAudio
        }
        buffer.frameLength = 0
        while buffer.frameLength < frames {
            try file.read(into: part, frameCount: frames - buffer.frameLength)
            guard part.frameLength > 0 else { throw AudioEditError.unreadableAudio }
            for channel in 0..<Int(buffer.format.channelCount) {
                (target[channel] + Int(buffer.frameLength)).update(from: source[channel], count: Int(part.frameLength))
            }
            buffer.frameLength += part.frameLength
        }
    }
}
