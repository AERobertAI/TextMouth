import AVFoundation
import Darwin
import XCTest
@testable import TextMouth

/// Ogg audio converted in a child process that a watchdog can kill (B09): the
/// header read that decodes nothing, afconvert's arguments, each rule of the
/// watchdog (time, memory, no progress) with stand-in children, and the
/// converter's handling of a child that is killed or fails. No test hands Ogg
/// audio to a player or decodes it in the test host: the real conversions
/// run through `/usr/bin/afconvert`.
final class OggAfconvertTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try AudioTestFixtures.makeTemporaryDirectory()
    }

    override func tearDown() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
    }

    // MARK: - Reading the Header

    /// The header of each fixture gives its rate, channels, and length with
    /// nothing decoded.
    func testTheHeaderGivesTheRateChannelsAndLength() throws {
        let vorbis = try OggTestFixtures.copy(OggTestFixtures.vorbis, to: folder, as: "v.ogg")
        let opus = try OggTestFixtures.copy(OggTestFixtures.opus, to: folder, as: "o.opus")

        let vorbisInfo = try XCTUnwrap(OggAudioConverter.inspect(vorbis))
        XCTAssertEqual(vorbisInfo.sampleRate, 22_050)
        XCTAssertEqual(vorbisInfo.channels, 1)
        XCTAssertEqual(vorbisInfo.duration, 2, accuracy: 0.1)
        let opusInfo = try XCTUnwrap(OggAudioConverter.inspect(opus))
        XCTAssertEqual(opusInfo.channels, 1)
        XCTAssertEqual(opusInfo.duration, 2, accuracy: 0.1)
    }

    /// A missing file and a file that is not audio have no header to read.
    func testNothingIsReadFromAMissingFileOrOneThatIsNotAudio() throws {
        let text = folder.appendingPathComponent("text.ogg")
        try Data("not audio".utf8).write(to: text)
        XCTAssertNil(OggAudioConverter.inspect(text))
        XCTAssertNil(OggAudioConverter.inspect(folder.appendingPathComponent("missing.ogg")))
    }

    // MARK: - Nothing Else Decodes Ogg

    /// The playability probe, the audio editor's loader, and the
    /// transcriber's length reader refuse Ogg audio without opening it, so
    /// Apple's Vorbis decoder never runs in TextMouth.
    func testNoOtherReaderDecodesOgg() async throws {
        let ogg = try OggTestFixtures.copy(OggTestFixtures.vorbis, to: folder, as: "v.ogg")

        let probed = await AudioMediaProbe.duration(of: ogg)
        XCTAssertEqual(probed, .failure(.cannotOpen))
        do {
            _ = try await AudioEditBase.load(ogg, name: "v.ogg")
            XCTFail("The editor must not load Ogg audio")
        } catch {
            XCTAssertEqual(error as? AudioEditError, .unreadableAudio)
        }
        XCTAssertThrowsError(try TranscriptionPlan.duration(ofAudioFileAt: ogg))
    }

    // MARK: - afconvert's Arguments

    /// The arguments name the .m4a container, AAC, and the bit rate; the
    /// sample rate and channel count only when they change.
    func testTheArgumentsChangeOnlyWhatMustChange() {
        let input = URL(fileURLWithPath: "/in/a.ogg")
        let output = URL(fileURLWithPath: "/out/.a.m4a")
        let same = OggAudioConverter.SourceInfo(sampleRate: 44_100, channels: 2, duration: 10)
        XCTAssertEqual(
            OggAudioConverter.afconvertArguments(
                from: input, to: output, info: same,
                target: .init(channels: 2, sampleRate: 44_100, bitRate: 128_000)
            ),
            ["-f", "m4af", "-d", "aac", "-b", "128000", "/in/a.ogg", "/out/.a.m4a"]
        )
        let surround = OggAudioConverter.SourceInfo(sampleRate: 88_200, channels: 6, duration: 10)
        XCTAssertEqual(
            OggAudioConverter.afconvertArguments(
                from: input, to: output, info: surround,
                target: .init(channels: 2, sampleRate: 44_100, bitRate: nil)
            ),
            ["-f", "m4af", "-d", "aac@44100", "-c", "2", "/in/a.ogg", "/out/.a.m4a"]
        )
    }

    /// A real conversion through afconvert gives AAC in an .m4a file of the
    /// source's length, from Vorbis and from Opus, and leaves no hidden file.
    func testRealConversionsRunThroughAfconvert() async throws {
        try OggTestFixtures.skipUnlessOggDecodes()
        let sources = [
            try OggTestFixtures.copy(OggTestFixtures.vorbis, to: folder, as: "a.ogg"),
            try OggTestFixtures.copy(OggTestFixtures.opus, to: folder, as: "b.opus"),
        ]
        for source in sources {
            let conversion = try await OggAudioConverter.convert(source)
            let formatID = await OggTestFixtures.formatID(of: conversion.converted)
            XCTAssertEqual(formatID, kAudioFormatMPEG4AAC)
            XCTAssertEqual(conversion.duration, 2, accuracy: 0.1)
        }
        XCTAssertEqual(OggTestFixtures.names(in: folder), ["a.m4a", "a.ogg", "b.m4a", "b.opus"])
    }

    // MARK: - The Watchdog

    /// Limits that keep a test short: the watchdog looks every 0.1 second.
    private func limits(seconds: TimeInterval = 60, bytes: Int64 = 1 << 30, stalled: TimeInterval = 60) -> WatchedProcess.Limits {
        WatchedProcess.Limits(maximumSeconds: seconds, maximumResidentBytes: bytes, maximumStalledSeconds: stalled, pollInterval: 0.1)
    }

    /// A shell child that appends to `output` ten times a second for ever.
    private func writer(to output: URL) -> (URL, [String]) {
        (URL(fileURLWithPath: "/bin/sh"), ["-c", "while :; do echo x >> \"$0\"; sleep 0.1; done", output.path])
    }

    /// A child that ends by itself is reported with its exit status.
    func testAChildThatEndsReportsItsStatus() async throws {
        let output = folder.appendingPathComponent("out")
        let fine = try await WatchedProcess.run(URL(fileURLWithPath: "/usr/bin/true"), arguments: [], watching: output, limits: limits())
        XCTAssertEqual(fine, .exited(status: 0))
        let failed = try await WatchedProcess.run(URL(fileURLWithPath: "/usr/bin/false"), arguments: [], watching: output, limits: limits())
        XCTAssertEqual(failed, .exited(status: 1))
        let missing = try await WatchedProcess.run(URL(fileURLWithPath: "/nonexistent/tool"), arguments: [], watching: output, limits: limits())
        XCTAssertEqual(missing, .couldNotStart)
    }

    /// A child that never writes is killed for making no progress, long
    /// before it would have ended.
    func testAChildThatNeverWritesIsKilledForNoProgress() async throws {
        let started = Date()
        let outcome = try await WatchedProcess.run(
            URL(fileURLWithPath: "/bin/sleep"), arguments: ["60"],
            watching: folder.appendingPathComponent("out"), limits: limits(stalled: 0.5)
        )
        XCTAssertEqual(outcome, .killed(.madeNoProgress(seconds: 0.5)))
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
    }

    /// A child that keeps writing but never ends is killed for taking too
    /// long.
    func testAChildThatRunsTooLongIsKilled() async throws {
        let output = folder.appendingPathComponent("out")
        let (executable, arguments) = writer(to: output)
        let started = Date()
        let outcome = try await WatchedProcess.run(executable, arguments: arguments, watching: output, limits: limits(seconds: 1))
        XCTAssertEqual(outcome, .killed(.tookTooLong(seconds: 1)))
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
    }

    /// A child whose memory, as the injected reader reports it, passes the
    /// limit is killed, though it writes steadily.
    func testAChildThatHoldsTooMuchMemoryIsKilled() async throws {
        let output = folder.appendingPathComponent("out")
        let (executable, arguments) = writer(to: output)
        let outcome = try await WatchedProcess.run(
            executable, arguments: arguments, watching: output, limits: limits(bytes: 1 << 30),
            residentMemory: { _ in (1 << 30) + 1 }
        )
        XCTAssertEqual(outcome, .killed(.usedTooMuchMemory(bytes: 1 << 30)))
    }

    /// A steady writer that stays inside every limit is left alone until its
    /// task is cancelled, which kills it and throws.
    func testCancellingTheTaskKillsTheChild() async throws {
        let output = folder.appendingPathComponent("out")
        let (executable, arguments) = writer(to: output)
        let limits = limits()
        let task = Task {
            try await WatchedProcess.run(executable, arguments: arguments, watching: output, limits: limits)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled run must throw")
        } catch is CancellationError {
            // Expected.
        }
    }

    /// The real memory reader reports this test host's own memory, and
    /// nothing for a process that does not exist.
    func testTheMemoryReaderReadsAProcessAndRefusesAGhost() {
        XCTAssertGreaterThan(WatchedProcess.residentMemory(of: getpid()) ?? 0, 1_000_000)
        XCTAssertNil(WatchedProcess.residentMemory(of: 999_999))
    }

    /// The kill reasons are spoken in whole words for the debug log.
    func testKillReasonsReadAsWords() {
        XCTAssertEqual(WatchedProcess.KillReason.tookTooLong(seconds: 62.2).words, "it ran longer than 63 seconds")
        XCTAssertEqual(WatchedProcess.KillReason.usedTooMuchMemory(bytes: 1 << 30).words, "it held more than 1024 MB of memory")
        XCTAssertEqual(WatchedProcess.KillReason.madeNoProgress(seconds: 20).words, "its output did not grow for 20 seconds")
    }

    /// A one-second limit reads "1 second", not "1 seconds", and two or
    /// more keep the plural; the rounding up is unchanged.
    func testKillReasonsCountOneSecondInTheSingular() {
        XCTAssertEqual(WatchedProcess.KillReason.tookTooLong(seconds: 1).words, "it ran longer than 1 second")
        XCTAssertEqual(WatchedProcess.KillReason.madeNoProgress(seconds: 1).words, "its output did not grow for 1 second")
        // A fraction rounds up to the next whole second before it is counted.
        XCTAssertEqual(WatchedProcess.KillReason.tookTooLong(seconds: 0.4).words, "it ran longer than 1 second")
        XCTAssertEqual(WatchedProcess.KillReason.tookTooLong(seconds: 2).words, "it ran longer than 2 seconds")
        XCTAssertEqual(WatchedProcess.KillReason.tookTooLong(seconds: 62.2).words, "it ran longer than 63 seconds")
        XCTAssertEqual(WatchedProcess.KillReason.madeNoProgress(seconds: 20).words, "its output did not grow for 20 seconds")
    }

    // MARK: - The Converter Kills a Hung Child

    /// A stand-in converter whose child is `executable` with `arguments`, and
    /// tight limits.
    private func tool(_ executable: String, _ arguments: [String], stalled: TimeInterval = 0.5) -> OggAudioConverter.Tool {
        let limits = limits(stalled: stalled)
        return OggAudioConverter.Tool(
            command: { _, _, _, _ in (URL(fileURLWithPath: executable), arguments) },
            limits: { _ in limits },
            residentMemory: { _ in nil }
        )
    }

    /// A conversion whose child hangs fails as killed, naming the file and
    /// the reason, and leaves the folder as it was.
    func testAHungConversionFailsAndLeavesNothing() async throws {
        let source = try OggTestFixtures.copy(OggTestFixtures.vorbis, to: folder, as: "hung.ogg")
        do {
            _ = try await OggAudioConverter.convert(source, using: tool("/bin/sleep", ["60"]))
            XCTFail("A hung conversion must fail")
        } catch let failure as OggAudioConverter.Failure {
            XCTAssertEqual(failure, .killed(fileName: "hung.ogg", reason: "its output did not grow for 1 second"))
        }
        XCTAssertEqual(OggTestFixtures.names(in: folder), ["hung.ogg"])
    }

    /// A conversion whose child fails reports the exit status and leaves
    /// nothing; the book waits for a later launch.
    func testAFailingConversionLeavesNothing() async throws {
        let source = try OggTestFixtures.copy(OggTestFixtures.vorbis, to: folder, as: "bad.ogg")
        do {
            _ = try await OggAudioConverter.convert(source, using: tool("/usr/bin/false", []))
            XCTFail("A failing conversion must fail")
        } catch let failure as OggAudioConverter.Failure {
            XCTAssertEqual(failure, .processFailed(fileName: "bad.ogg", status: 1))
        }
        XCTAssertEqual(OggTestFixtures.names(in: folder), ["bad.ogg"])
    }

    /// One hung track fails a batch, stopping the others and removing
    /// everything already converted.
    func testOneHungTrackFailsTheBatchAndRemovesTheRest() async throws {
        let sources = [
            try OggTestFixtures.copy(OggTestFixtures.vorbis, to: folder, as: "01.ogg"),
            try OggTestFixtures.copy(OggTestFixtures.vorbis, to: folder, as: "02.ogg"),
        ]
        do {
            _ = try await OggAudioConverter.convertEach(sources, using: tool("/bin/sleep", ["60"]))
            XCTFail("A batch with a hung track must fail")
        } catch is OggAudioConverter.Failure {
            // Expected.
        }
        XCTAssertEqual(OggTestFixtures.names(in: folder), ["01.ogg", "02.ogg"])
    }

    // MARK: - Stale Files

    /// Every file a killed or quit run left under its hidden name, in the
    /// folder and in a folder inside it, is removed, and nothing else.
    func testStaleTemporaryFilesAreRemovedFromTheWholeFolder() throws {
        let inner = folder.appendingPathComponent("inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let stale = [
            ".01.\(UUID().uuidString)\(OggAudioConverter.temporarySuffix)",
            ".01.\(UUID().uuidString)\(OggAudioConverter.temporarySuffix)",
            ".02.\(UUID().uuidString)\(OggAudioConverter.temporarySuffix)",
        ]
        for (index, name) in stale.enumerated() {
            try Data("x".utf8).write(to: (index == 2 ? inner : folder).appendingPathComponent(name))
        }
        try Data("keep".utf8).write(to: folder.appendingPathComponent("01.m4a"))
        try Data("keep".utf8).write(to: folder.appendingPathComponent(".hidden-but-not-ours.m4a"))

        OggAudioConverter.removeLeftovers(in: folder)

        XCTAssertEqual(OggTestFixtures.names(in: folder), [".hidden-but-not-ours.m4a", "01.m4a", "inner"])
        XCTAssertEqual(OggTestFixtures.names(in: inner), [])
    }
}
