import AVFoundation
import XCTest
@testable import TextMouth

/// TextMouth's own filters (FR04), each run on a generated signal and its
/// effect measured: a volume change, high and low passes, an equalizer
/// band, fades, a tempo change, loudness normalization, silence removal,
/// compression, and reversing. Then the processor that applies a filter edit
/// to a stretch of a timeline, kept for later and read back; and the ffmpeg
/// route, through a stub ffmpeg found along PATH, its refusals reported in
/// its own words, and, with ffmpeg installed, every premade preset doing the
/// same through it as through TextMouth's own filters. No sound is played:
/// every result is read back as samples.
final class AudioFilterTests: XCTestCase {

    /// Frames a second of the signals.
    private static let rate = 8_000.0

    // MARK: - TextMouth's Own Filters

    /// volume multiplies every sample, by a factor or by decibels.
    func testVolumeScalesTheLevel() throws {
        let output = try run("volume=0.5", on: [.init(seconds: 1, frequency: 440, amplitude: 0.8)])
        XCTAssertEqual(AudioTestFixtures.peak(output), 0.4, accuracy: 0.001)
        let decibels = try run("volume=-6dB", on: [.init(seconds: 1, frequency: 440, amplitude: 0.8)])
        XCTAssertEqual(AudioTestFixtures.peak(decibels), 0.8 * 0.501, accuracy: 0.002)
    }

    /// A high pass keeps sound well above its frequency and removes sound
    /// well below it; a low pass the other way round.
    func testHighAndLowPassesSeparateFrequencies() throws {
        let low = AudioTestFixtures.Tone(seconds: 1, frequency: 100, amplitude: 0.5)
        let high = AudioTestFixtures.Tone(seconds: 1, frequency: 2_000, amplitude: 0.5)
        XCTAssertLessThan(try steadyRMS(run("highpass=f=1000", on: [low])), 0.5 * 0.707 * 0.05)
        XCTAssertGreaterThan(try steadyRMS(run("highpass=f=1000", on: [high])), 0.5 * 0.707 * 0.9)
        XCTAssertLessThan(try steadyRMS(run("lowpass=f=300", on: [high])), 0.5 * 0.707 * 0.05)
        XCTAssertGreaterThan(try steadyRMS(run("lowpass=f=300", on: [low])), 0.5 * 0.707 * 0.9)
        XCTAssertThrowsError(try run("highpass=f=5000", on: [low])) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "The highpass filter's frequency can't be “5000.0”: give a frequency below half the audio's sample rate, 4000 Hz."
            )
        }
    }

    /// An equalizer band raises its frequency by its gain and leaves a far
    /// one alone.
    func testAnEqualizerBandRaisesItsFrequency() throws {
        let centre = try steadyRMS(run("equalizer=f=1000:t=q:w=1:g=6", on: [.init(seconds: 1, frequency: 1_000, amplitude: 0.2)]))
        XCTAssertEqual(20 * log10(centre / (0.2 * 0.707_1)), 6, accuracy: 0.3)
        let far = try steadyRMS(run("equalizer=f=1000:t=q:w=1:g=6", on: [.init(seconds: 1, frequency: 100, amplitude: 0.2)]))
        XCTAssertEqual(20 * log10(far / (0.2 * 0.707_1)), 0, accuracy: 0.5)
    }

    /// A fade in rises from silence over its length; a fade out falls to
    /// silence and stays there, as ffmpeg's afade does.
    func testFadesRiseAndFall() throws {
        let steady = [AudioTestFixtures.Tone(seconds: 3, frequency: 0, amplitude: 0.5)]
        let fadeIn = try run("afade=t=in:d=1", on: steady)
        XCTAssertEqual(fadeIn.count, 24_000)
        XCTAssertEqual(fadeIn[checked: 0], 0)
        XCTAssertEqual(try XCTUnwrap(fadeIn[checked: 4_000]), 0.25, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(fadeIn[checked: 8_000]), 0.5, accuracy: 0.000_1)
        XCTAssertEqual(fadeIn.last ?? 0, 0.5, accuracy: 0.000_1)

        let fadeOut = try run("afade=t=out:st=1:d=1:curve=hsin", on: steady)
        XCTAssertEqual(try XCTUnwrap(fadeOut[checked: 7_999]), 0.5, accuracy: 0.000_1)
        XCTAssertEqual(try XCTUnwrap(fadeOut[checked: 12_000]), 0.25, accuracy: 0.001)
        XCTAssertEqual(fadeOut[checked: 16_000], 0)
        XCTAssertEqual(fadeOut.last ?? 1, 0)
    }

    /// A tempo change shortens or lengthens the sound by its factor, and a
    /// click moves with it.
    func testATempoChangeScalesTheLength() throws {
        let tones: [AudioTestFixtures.Tone] = [
            .silence(2), .init(seconds: 0.05, frequency: 0, amplitude: 0.9), .silence(1.95),
        ]
        let faster = try run("atempo=2", on: tones)
        XCTAssertEqual(Double(faster.count) / Self.rate, 2, accuracy: 0.001)
        let click = try XCTUnwrap(faster.indices.first { abs(faster[$0]) > 0.3 })
        XCTAssertEqual(Double(click) / Self.rate, 1, accuracy: 0.06)
        let slower = try run("atempo=0.5", on: [.init(seconds: 1, frequency: 300, amplitude: 0.5)])
        XCTAssertEqual(Double(slower.count) / Self.rate, 2, accuracy: 0.001)
    }

    /// Loudness normalization brings the integrated loudness to its target,
    /// and keeps the peak below the true-peak limit when that comes first.
    func testLoudnessIsNormalizedToItsTarget() throws {
        let quiet = [AudioTestFixtures.Tone(seconds: 3, frequency: 1_000, amplitude: 0.05)]
        let folder = try AudioTestFixtures.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let normalized = folder.appendingPathComponent("normalized.caf")
        try runFile("loudnorm=I=-16:TP=-1", on: quiet, to: normalized)
        let measured = try AudioFilterRunner.loudness(of: normalized)
        XCTAssertEqual(try XCTUnwrap(measured.integrated), -16, accuracy: 0.3)

        let capped = try run("loudnorm=I=-5:TP=-6", on: quiet)
        XCTAssertEqual(AudioTestFixtures.peak(capped), 0.501, accuracy: 0.005)

        let silent = try run("loudnorm=I=-16", on: [.silence(1)])
        XCTAssertEqual(AudioTestFixtures.peak(silent), 0, "silence has no loudness to bring anywhere")
    }

    /// Silence removal does what ffmpeg 7's does with the same options. The
    /// lengths are ffmpeg 7.1.1's own results on this signal (0.5 s
    /// silence, tone, a 2 s pause, tone, a 0.2 s pause, tone, 1 s silence),
    /// which TextMouth's must match to a hundredth of a second. A silence is
    /// heard once a whole window of it (0.02 s) has passed, so that much more
    /// of each is kept.
    func testSilenceIsRemovedAsFFmpegRemovesIt() throws {
        let speech: [AudioTestFixtures.Tone] = [
            .silence(0.5), .init(seconds: 1, frequency: 300, amplitude: 0.5), .silence(2),
            .init(seconds: 1, frequency: 300, amplitude: 0.5), .silence(0.2),
            .init(seconds: 1, frequency: 300, amplitude: 0.5), .silence(1),
        ]
        let bothEnds = "silenceremove=start_periods=1:start_threshold=-40dB,areverse,"
            + "silenceremove=start_periods=1:start_threshold=-40dB,areverse"
        let cases: [(chain: String, seconds: Double, why: String)] = [
            ("silenceremove=stop_periods=-1:stop_duration=0.5:stop_threshold=-40dB:stop_silence=0.25", 5.239,
             "the 2 s pause and the last 1 s keep 0.5 s and 0.25 s more; the first comes before any sound"),
            ("silenceremove=stop_periods=-2:stop_duration=0.3:stop_threshold=-40dB:stop_silence=0.1", 5.140,
             "two periods of 0.3 s and 0.1 s more are kept of each long silence"),
            ("silenceremove=start_periods=1:start_threshold=-40dB:stop_periods=1:stop_threshold=-40dB", 1.020,
             "a positive count stops copying at the first silence, for good"),
            ("silenceremove=stop_periods=2:stop_duration=0.5:stop_threshold=-40dB", 2.520,
             "the 2 s pause holds the two periods, and nothing after it is kept"),
            ("silenceremove=start_periods=1:start_duration=0.25:start_threshold=-40dB:start_silence=0.1", 6.050,
             "the first 0.25 s of sound goes with the silence before it, 0.1 s of what went kept"),
            ("silenceremove=start_periods=2:start_threshold=-40dB", 6.200,
             "sound found twice: its second frame starts the copy"),
            (bothEnds, 5.200, "both ends trimmed, by trimming the start of the sound reversed"),
        ]
        for (chain, seconds, why) in cases {
            let result = try run(chain, on: speech)
            XCTAssertEqual(Double(result.count) / Self.rate, seconds, accuracy: 0.01, "\(chain): \(why)")
        }

        // Trimmed at both ends, the result starts with the first tone.
        let trimmed = try run(bothEnds, on: speech)
        XCTAssertGreaterThan(abs(try XCTUnwrap(trimmed[checked: 10])), 0.3, "the start's silence stayed")
    }

    /// The compressor lowers a level above its threshold by its ratio, and
    /// leaves one below it alone.
    func testTheCompressorEvensOutTheLevel() throws {
        let loud = try run(
            "acompressor=threshold=-20dB:ratio=4:attack=50:release=50:knee=1",
            on: [.init(seconds: 2, frequency: 200, amplitude: 0.5)]
        )
        // With attack and release alike the level followed is the mean square:
        // the sine's RMS, -9 dBFS, 11 dB over the threshold. At 4:1 it comes
        // out 2.75 dB over, 8.25 dB quieter.
        let reduction = 20 * log10(steadyRMS(loud) / (0.5 * 0.707_1))
        XCTAssertEqual(reduction, -8.25, accuracy: 0.75)
        let quiet = try run("acompressor=threshold=-20dB:ratio=4", on: [.init(seconds: 2, frequency: 200, amplitude: 0.02)])
        XCTAssertEqual(steadyRMS(quiet), 0.02 * 0.707_1, accuracy: 0.000_5)
    }

    /// Reversing writes every sample in the opposite order.
    func testReversingPlaysTheSoundBackwards() throws {
        let folder = try AudioTestFixtures.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("ramp.caf")
        let output = folder.appendingPathComponent("reversed.caf")
        try AudioTestFixtures.writeIdentityRamp(to: input, frames: 150_000)
        try AudioFilterRunner.run(try AudioFilterChain.parse("areverse").builtInFilters(), input: input, output: output, scratch: folder)
        let reversed = try AudioTestFixtures.floatSamples(of: output)
        XCTAssertEqual(reversed.count, 150_000)
        XCTAssertEqual(reversed.indices.filter { AudioTestFixtures.rampSample(reversed[$0]) != .frame(.book, 149_999 - $0) }, [])
    }

    /// Filters run one after another in the order written.
    func testAChainRunsItsFiltersInOrder() throws {
        let output = try run("volume=0.5,volume=0.5,areverse", on: [.init(seconds: 1, frequency: 0, amplitude: 0.8)])
        XCTAssertEqual(AudioTestFixtures.peak(output), 0.2, accuracy: 0.000_1)
    }

    // MARK: - The Processor

    /// A filter edit renders its stretch through the chain once: applying
    /// it again reads the kept result back, and the gain edit of the timeline
    /// is the volume filter.
    func testTheProcessorKeepsWhatItRendered() async throws {
        let (sources, folder) = try await makeSources(frames: 16_000)
        let processor = AudioFilterProcessor(sources: sources, engine: .builtIn)
        var timeline = sources.base.timeline
        try await timeline.apply(.gain(decibels: -6, range: AudioTimeRange(start: 0.5, end: 1.5)), processor: processor)

        XCTAssertEqual(timeline.length, 16_000)
        guard case .processed(let name) = timeline.segments[checked: 1]?.source else { return XCTFail("\(timeline.segments)") }
        let kept = folder.appendingPathComponent(name)
        let samples = try AudioTestFixtures.floatSamples(of: kept)
        XCTAssertEqual(samples.count, 8_000)
        XCTAssertEqual(try XCTUnwrap(samples.first), Float((4_000 + 1) * AudioTestFixtures.rampStep) * 0.501, accuracy: 0.000_001)

        let date = try XCTUnwrap(kept.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        var again = sources.base.timeline
        try await again.apply(.gain(decibels: -6, range: AudioTimeRange(start: 0.5, end: 1.5)), processor: processor)
        XCTAssertEqual(again, timeline)
        XCTAssertEqual(try kept.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date)
    }

    /// TextMouth's own engine refuses a chain it can't run before rendering
    /// anything.
    func testTheProcessorRefusesWhatTheEngineCantRun() async throws {
        let (sources, _) = try await makeSources(frames: 8_000)
        var timeline = sources.base.timeline
        do {
            try await timeline.apply(.filter(chain: "aecho=0.8:0.9:1000:0.3", range: nil), processor: AudioFilterProcessor(sources: sources, engine: .builtIn))
            XCTFail("an unknown filter ran")
        } catch {
            XCTAssertEqual(error as? AudioFilterError, .unknownFilter("aecho"))
        }
    }

    // MARK: - ffmpeg

    /// ffmpeg is found in the usual places first, then along PATH; a file
    /// that isn't an executable is passed over.
    func testFFmpegIsFoundInTheUsualPlacesThenAlongPATH() throws {
        let folder = try AudioTestFixtures.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let onPath = try writeStub(in: folder.appendingPathComponent("bin"), body: "exit 0")
        let notExecutable = folder.appendingPathComponent("plain/ffmpeg")
        try FileManager.default.createDirectory(at: notExecutable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a program".utf8).write(to: notExecutable)

        XCTAssertEqual(
            FFmpeg.locate(in: [notExecutable.path], environment: ["PATH": "/nowhere:\(onPath.deletingLastPathComponent().path)"]),
            FFmpeg(executable: onPath)
        )
        XCTAssertEqual(FFmpeg.locate(in: [onPath.path], environment: [:]), FFmpeg(executable: onPath))
        XCTAssertNil(FFmpeg.locate(in: [notExecutable.path], environment: ["PATH": "/nowhere"]))
        XCTAssertEqual(FFmpeg.standardLocations, ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"])
    }

    /// With ffmpeg, a chain runs through it as written, every filter it has
    /// included, keeping the stretch's rate and channels.
    func testAChainRunsThroughFFmpegAsWritten() async throws {
        let (sources, folder) = try await makeSources(frames: 8_000)
        let arguments = folder.appendingPathComponent("arguments.txt")
        // The stub records its arguments and copies its input to its output,
        // as a filter that changes nothing would.
        let stub = try writeStub(in: folder.appendingPathComponent("bin"), body: """
            printf '%s\\n' "$@" > '\(arguments.path)'
            previous=""
            for argument in "$@"; do
              if [ "$previous" = "-i" ]; then input="$argument"; fi
              previous="$argument"
            done
            cp "$input" "$previous"
            """)
        let ffmpeg = try XCTUnwrap(FFmpeg.locate(in: [], environment: ["PATH": stub.deletingLastPathComponent().path]))
        var timeline = sources.base.timeline

        try await timeline.apply(
            .filter(chain: "aecho=0.8:0.9:1000:0.3", range: nil),
            processor: AudioFilterProcessor(sources: sources, engine: .ffmpeg(ffmpeg))
        )

        XCTAssertEqual(timeline.length, 8_000)
        let passed = try String(contentsOf: arguments, encoding: .utf8).split(separator: "\n").map(String.init)
        let chain = try XCTUnwrap(passed.firstIndex(of: "-af"))
        XCTAssertEqual(passed[checked: chain + 1], "aecho=0.8:0.9:1000:0.3")
        XCTAssertEqual(Array(passed.prefix(5)), FFmpeg.quietOptions)
        XCTAssertTrue(passed.contains("8000") && passed.contains("pcm_f32le"), "\(passed)")
    }

    /// ffmpeg's refusal is reported in its own words, without the names of
    /// its internals, and a failure to start says so.
    func testFFmpegsRefusalIsReportedInItsOwnWords() async throws {
        let folder = try AudioTestFixtures.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let stub = try writeStub(in: folder, body: """
            echo "[AVFilterGraph @ 0x600003b0c000] No such filter: 'warble'" >&2
            echo "Error initializing complex filters." >&2
            exit 1
            """)
        do {
            try await FFmpeg(executable: stub).run(["-i", "x"])
            XCTFail("a failing ffmpeg succeeded")
        } catch {
            XCTAssertEqual(error as? AudioFilterError, .ffmpegFailed("No such filter: 'warble' Error initializing complex filters."))
            XCTAssertEqual(
                error.localizedDescription,
                "ffmpeg couldn't run the filters: No such filter: 'warble' Error initializing complex filters."
            )
        }
        do {
            try await FFmpeg(executable: folder.appendingPathComponent("missing")).run([])
            XCTFail("a missing ffmpeg ran")
        } catch {
            XCTAssertEqual(error as? AudioFilterError, .ffmpegMissing)
        }
        XCTAssertEqual(FFmpeg.describe("", status: 3), "it ended with code 3.")
    }

    /// The setting chooses the engine: an installed ffmpeg while it is on,
    /// TextMouth's own when it is off or none is found. It is on until the
    /// user turns it off, and config.json carries it.
    @MainActor
    func testTheSettingChoosesTheEngine() throws {
        let store = makeSandboxedPreferences("ffmpeg-setting")
        let found = FFmpeg(executable: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"))
        XCTAssertEqual(AudioFilterEngine.current(in: store, locate: { found }), .ffmpeg(found))
        XCTAssertEqual(AudioFilterEngine.current(in: store, locate: { nil }), .builtIn)
        AudioFilterEngine.usePreference.write(false, to: store)
        XCTAssertEqual(AudioFilterEngine.current(in: store, locate: { found }), .builtIn)
        XCTAssertTrue(AudioEditingPreferences.keys.contains("useInstalledFFmpeg"))

        let settings = SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false, userDefaults: store)
        var written = ConfigService.AppConfig()
        settings.writePreferences(into: &written)
        XCTAssertEqual(written.useInstalledFFmpeg, false)
        settings.applyConfigChanges(try JSONDecoder().decode(ConfigService.AppConfig.self, from: Data(#"{"useInstalledFFmpeg": true}"#.utf8)))
        XCTAssertTrue(AudioFilterEngine.usePreference.read(from: store))
    }

    /// Every premade preset does the same through an installed ffmpeg as
    /// through TextMouth's own filters, on a signal of tones, hum, and
    /// pauses: the same length, to within 0.03 s, and the same level, to
    /// within half a decibel. loudnorm is compared on steady sound, by
    /// integrated loudness, to within one LU: ffmpeg's runs in one pass and
    /// changes its gain as it goes, so on speech with pauses it approaches
    /// its target only over a minute or more (-14.5 LUFS after this signal's
    /// 8 seconds, -16.9 after a minute, for -18), while TextMouth's is the
    /// one gain ffmpeg's two-pass, linear normalization would apply.
    /// Skipped on a Mac without ffmpeg.
    func testThePremadePresetsDoTheSameThroughFFmpeg() async throws {
        guard let ffmpeg = FFmpeg.locate() else { throw XCTSkip("ffmpeg isn't installed on this Mac") }
        let folder = try AudioTestFixtures.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("speech.caf")
        try AudioTestFixtures.writeTones([
            .silence(0.6), .init(seconds: 1.2, frequency: 300, amplitude: 0.3), .silence(1.8),
            .init(seconds: 1, frequency: 50, amplitude: 0.3), .init(seconds: 1, frequency: 3_000, amplitude: 0.2),
            .silence(0.3), .init(seconds: 1.4, frequency: 300, amplitude: 0.6), .silence(0.9),
        ], to: input, sampleRate: Self.rate)
        let steady = folder.appendingPathComponent("steady.caf")
        try AudioTestFixtures.writeTones([.init(seconds: 10, frequency: 300, amplitude: 0.1)], to: steady, sampleRate: Self.rate)
        let presets = await MainActor.run { AudioFilterPresetLibrary.standard }

        for preset in presets {
            let source = preset.chain.hasPrefix("loudnorm") ? steady : input
            let ours = folder.appendingPathComponent("ours.caf")
            let theirs = folder.appendingPathComponent("theirs.caf")
            try AudioFilterRunner.run(try AudioFilterChain.parse(preset.chain).builtInFilters(), input: source, output: ours, scratch: folder)
            try await ffmpeg.filter(source, chain: preset.chain, to: theirs, sampleRate: Self.rate, channels: 1)

            let ourSamples = try AudioTestFixtures.floatSamples(of: ours)
            let theirSamples = try AudioTestFixtures.floatSamples(of: theirs)
            XCTAssertEqual(
                Double(ourSamples.count) / Self.rate, Double(theirSamples.count) / Self.rate,
                accuracy: 0.03, "\(preset.name): length"
            )
            if preset.chain.hasPrefix("loudnorm") {
                let ourLoudness = try XCTUnwrap(AudioFilterRunner.loudness(of: ours).integrated, preset.name)
                let theirLoudness = try XCTUnwrap(AudioFilterRunner.loudness(of: theirs).integrated, preset.name)
                XCTAssertEqual(ourLoudness, theirLoudness, accuracy: 1, "\(preset.name): loudness")
            } else {
                XCTAssertEqual(decibels(ourSamples), decibels(theirSamples), accuracy: 0.5, "\(preset.name): level")
            }
            try? FileManager.default.removeItem(at: ours)
            try? FileManager.default.removeItem(at: theirs)
        }
    }

    // MARK: - Helpers

    /// The level of `samples`, their RMS in decibels below full scale.
    private func decibels(_ samples: [Float]) -> Double {
        20 * log10(max(Double(AudioTestFixtures.rms(samples)), 1e-9))
    }

    /// The samples `chain`, on TextMouth's own engine, makes of `tones`.
    private func run(_ chain: String, on tones: [AudioTestFixtures.Tone]) throws -> [Float] {
        let folder = try AudioTestFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("output.caf")
        try runFile(chain, on: tones, to: output)
        return try AudioTestFixtures.floatSamples(of: output)
    }

    /// Runs `chain` on `tones`, writing the result to `output`.
    private func runFile(_ chain: String, on tones: [AudioTestFixtures.Tone], to output: URL) throws {
        let folder = output.deletingLastPathComponent()
        let input = folder.appendingPathComponent("input-\(UUID().uuidString).caf")
        try AudioTestFixtures.writeTones(tones, to: input, sampleRate: Self.rate)
        try AudioFilterRunner.run(try AudioFilterChain.parse(chain).builtInFilters(), input: input, output: output, scratch: folder)
    }

    /// The RMS of the middle half of `samples`, away from a filter's settling.
    private func steadyRMS(_ samples: [Float]) -> Float {
        AudioTestFixtures.rms(samples[(samples.count / 4)..<(samples.count * 3 / 4)])
    }

    /// The sources of an edit whose base is an identity ramp of `frames`
    /// frames, in a folder of this test's own that serves as package and
    /// scratch folder.
    private func makeSources(frames: Int) async throws -> (AudioEditComposition.Sources, URL) {
        let folder = try AudioTestFixtures.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let base = folder.appendingPathComponent("Canal Survey.caf")
        try AudioTestFixtures.writeIdentityRamp(to: base, frames: frames, sampleRate: Self.rate)
        let loaded = try await AudioEditBase.load(base, name: "Canal Survey.caf")
        return (AudioEditComposition.Sources(base: loaded, package: folder, scratch: folder), folder)
    }

    /// An executable shell script named ffmpeg in `folder`, running `body`.
    private func writeStub(in folder: URL, body: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stub = folder.appendingPathComponent("ffmpeg")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: stub)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return stub
    }
}
