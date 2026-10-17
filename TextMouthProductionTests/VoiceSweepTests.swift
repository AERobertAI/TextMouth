import AVFoundation
import os
import XCTest
@testable import TextMouth

/// The voice sweep (TODO P09): renders one fixed sample (`VoiceSweepSample`)
/// with every voice installed on this Mac, offline, the way the app renders
/// speech (`AVSpeechSynthesizer.write`, which plays nothing), and writes a
/// Markdown report of what each voice did: whether it produced audio, how
/// long that audio is, and whether it hung or refused. Run it through
/// `Scripts/test/voice-sweep.sh` after installing voices or updating macOS.
///
/// Off unless `TEXTMOUTH_VOICE_SWEEP=1`, since it takes minutes and loads every
/// voice. The other settings:
/// - `TEXTMOUTH_VOICE_SWEEP_SECONDS`: the watchdog per voice (default 20).
/// - `TEXTMOUTH_VOICE_SWEEP_LANGUAGE`: only voices whose language starts with
///   this, such as `en`.
/// - `TEXTMOUTH_VOICE_SWEEP_VOICES`: only these voice identifiers, comma
///   separated.
/// - `TEXTMOUTH_VOICE_SWEEP_REPORT`: where to write the report (default: a
///   file in the test host's temporary folder).
///
/// A bad voice never fails the test: the report is the product. The test fails
/// only when the sweep itself could not run, because no voice is installed (or
/// none matches the filters) or the report cannot be written.
@MainActor
final class VoiceSweepTests: XCTestCase {

    // MARK: - Settings

    /// The names of the environment variables that steer the sweep.
    private enum Setting {
        static let enable = "TEXTMOUTH_VOICE_SWEEP"
        static let seconds = "TEXTMOUTH_VOICE_SWEEP_SECONDS"
        static let language = "TEXTMOUTH_VOICE_SWEEP_LANGUAGE"
        static let voices = "TEXTMOUTH_VOICE_SWEEP_VOICES"
        static let report = "TEXTMOUTH_VOICE_SWEEP_REPORT"
    }

    /// The seconds a voice may take when `TEXTMOUTH_VOICE_SWEEP_SECONDS` does
    /// not say.
    private static let defaultWatchdogSeconds: TimeInterval = 20

    /// The non-empty value of environment variable `name`, or nil.
    private static func setting(_ name: String) -> String? {
        let value = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespaces)
        return value?.isEmpty == false ? value : nil
    }

    /// The watchdog interval per voice: the setting when it is a positive
    /// number, else the default.
    private static func watchdogSeconds() -> TimeInterval {
        guard let text = setting(Setting.seconds), let seconds = Double(text), seconds > 0 else {
            return defaultWatchdogSeconds
        }
        return seconds
    }

    /// Where the report goes: the setting, or a file in the test host's
    /// temporary folder.
    private static func reportURL() -> URL {
        if let path = setting(Setting.report) { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("textmouth-voice-sweep.md")
    }

    // MARK: - Choosing the voices

    /// The installed voices that match the language and identifier filters,
    /// in a stable order (language, name, identifier). Novelty voices are
    /// included, unlike the app's list, since a novelty voice that hangs is
    /// worth knowing.
    private static func selectedVoices() -> [AVSpeechSynthesisVoice] {
        var voices = AVSpeechSynthesisVoice.speechVoices()
        if let prefix = setting(Setting.language)?.lowercased() {
            voices = voices.filter { $0.language.lowercased().hasPrefix(prefix) }
        }
        if let list = setting(Setting.voices) {
            let wanted = Set(list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            voices = voices.filter { wanted.contains($0.identifier) }
            // Name each identifier that matched no installed voice, as a typo
            // would otherwise look like a voice that was left out.
            let found = Set(voices.map(\.identifier))
            for missing in wanted.subtracting(found).sorted() {
                print("VOICE SWEEP: \(missing) is not installed")
            }
        }
        return voices.sorted {
            ($0.language, $0.name, $0.identifier) < ($1.language, $1.name, $1.identifier)
        }
    }

    /// What the report records about `voice` before it is rendered.
    private static func describe(_ voice: AVSpeechSynthesisVoice) -> VoiceSweepVoice {
        VoiceSweepVoice(
            identifier: voice.identifier,
            name: voice.name,
            language: voice.language,
            quality: qualityWord(voice.quality),
            note: voice.voiceTraits.contains(.isNoveltyVoice) ? "A novelty voice, which the app does not list." : ""
        )
    }

    /// A voice quality in words.
    private static func qualityWord(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .default: return "default"
        case .enhanced: return "enhanced"
        case .premium: return "premium"
        @unknown default: return "unknown"
        }
    }

    // MARK: - The sweep

    /// Render the sample with every installed voice, one at a time, and write
    /// the report after each voice, so that a crash or a hang leaves a usable
    /// partial report.
    func testSweepEveryInstalledVoice() throws {
        guard Self.setting(Setting.enable) == "1" else {
            throw XCTSkip("Set TEXTMOUTH_VOICE_SWEEP=1 to render every installed voice offline.")
        }

        // The sweep cannot run without a voice: fail, rather than report that
        // all is well because nothing was tried.
        guard !AVSpeechSynthesisVoice.speechVoices().isEmpty else {
            XCTFail("No voice is installed, so there is nothing to sweep.")
            return
        }
        let voices = Self.selectedVoices()
        guard !voices.isEmpty else {
            XCTFail("No installed voice matches the language and identifier filters.")
            return
        }

        let url = Self.reportURL()
        print("VOICE SWEEP REPORT: \(url.path)")
        let watchdog = Self.watchdogSeconds()
        let macOS = "macOS " + ProcessInfo.processInfo.operatingSystemVersionString
            .replacingOccurrences(of: "Version ", with: "")
        let started = Date()

        // A placeholder first proves the report is writable, and tells a reader
        // of a crashed run that the sweep began.
        let placeholder = "# Voice sweep\n\nThe sweep started and has not finished its first voice.\n"
        guard write(placeholder, to: url) else { return }

        var results: [VoiceSweepResult] = []
        var breaker = VoiceSweepBreaker()
        // The probes stay alive for the whole sweep, so that a synthesizer
        // that hangs is never torn down under its own callbacks.
        var probes: [OfflineRenderProbe] = []

        for (index, voice) in voices.enumerated() {
            let info = Self.describe(voice)
            if breaker.shouldStop {
                results.append(contentsOf: voices[index...].map { .notTried(Self.describe($0)) })
                print("VOICE SWEEP: stopped after \(VoiceSweepBreaker.limit) timeouts in a row")
                break
            }
            let result = render(voice, as: info, watchdog: watchdog, keeping: &probes)
            print(
                "VOICE SWEEP: \(index + 1)/\(voices.count) \(info.name) (\(info.language)) "
                    + "\(result.outcome.rawValue) in \(String(format: "%.1f", result.wallSeconds)) s"
            )
            breaker.record(result.outcome)
            results.append(result)
            guard write(report(results, macOS: macOS), to: url) else { return }
        }

        // The final report includes any voices the breaker skipped.
        guard write(report(results, macOS: macOS), to: url) else { return }
        print("VOICE SWEEP: \(VoiceSweepReport.countsLine(results))")
        print("VOICE SWEEP: took \(String(format: "%.0f", Date().timeIntervalSince(started))) s")
        print("VOICE SWEEP REPORT: \(url.path)")
    }

    /// Render the sample with `voice` offline, in its turn on the app's render
    /// queue so that it overlaps no other render, and measure what happened. A
    /// render that has not ended after `watchdog` seconds is reported as timed
    /// out and stopped, so a hung voice costs one interval and holds nothing.
    private func render(
        _ voice: AVSpeechSynthesisVoice,
        as info: VoiceSweepVoice,
        watchdog: TimeInterval,
        keeping probes: inout [OfflineRenderProbe]
    ) -> VoiceSweepResult {
        let probe = OfflineRenderProbe(VoiceSweepSample.text, voice: voice, synthesizer: AVSpeechSynthesizer())
        probes.append(probe)
        // When the render began and ended, on the clock.
        let times = OSAllocatedUnfairLock<(start: Date?, end: Date?)>(initialState: (nil, nil))
        let handedBack = OSAllocatedUnfairLock(initialState: false)

        SpeechRenderCoordinator.shared.enqueue(
            textLength: probe.textLength,
            shouldStart: { true },
            start: { finish in
                // The end of the render and the watchdog race to report once.
                let report = VoiceWarmUp.reportingOnce { succeeded in
                    times.withLock { $0.end = Date() }
                    finish(succeeded)
                }
                times.withLock { $0.start = Date() }
                probe.begin(reportingEnd: report)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + watchdog) {
                    report(false)
                }
            },
            completion: { _ in handedBack.withLock { $0 = true } }
        )
        // The watchdog ends the render at `watchdog` seconds; the slack lets
        // the queue hand the turn back.
        _ = eventually(within: watchdog + 10) { handedBack.withLock { $0 } }
        probe.stop()

        let measured = times.withLock { $0 }
        let wall = measured.start.flatMap { start in measured.end.map { $0.timeIntervalSince(start) } } ?? watchdog
        return .measured(
            info, end: probe.end, buffers: probe.buffers, frames: probe.frames,
            sampleRate: probe.sampleRate, wallSeconds: wall, watchdogSeconds: watchdog
        )
    }

    // MARK: - The report

    /// The Markdown report for `results` so far.
    private func report(_ results: [VoiceSweepResult], macOS: String) -> String {
        VoiceSweepReport.markdown(results: results, macOS: macOS, date: Date())
    }

    /// Write `text` to `url`, making its folder if need be; fails the test and
    /// returns false when it cannot.
    private func write(_ text: String, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            XCTFail("The report cannot be written to \(url.path): \(error.localizedDescription)")
            return false
        }
    }
}
