import AVFoundation
import Darwin
import XCTest
@testable import TextMouth

/// Every channel count converts (review item 1): TextMouth writes at most
/// two channels, so a source of more is mixed down to stereo in two steps
/// (`ImportAudioConverter.downmixArguments`, then the AAC or Apple Lossless
/// arguments, which never pass `-c`). The tests pin the arguments, convert
/// 3.0 and 5.1 AC-3 and a 7.1 AAC file, check that a centre-channel-only
/// tone reaches both ears, convert PCM of one to eight channels (and ten)
/// to Apple Lossless, and check that no hidden stereo file is left behind
/// by a success, a failure, or a kill.
///
/// The two AC-3 fixtures in `TestData/audio` are one second of a 440 Hz
/// tone in the centre channel only, made on October 18, 2026 with ffmpeg
/// (Homebrew), from the repository's root:
///
///     ffmpeg -f lavfi -i "sine=frequency=440:duration=1:sample_rate=48000" \
///       -filter_complex "[0:a]aformat=channel_layouts=mono,pan=5.1|FL=0*c0|FR=0*c0|FC=c0|LFE=0*c0|BL=0*c0|BR=0*c0[a]" \
///       -map "[a]" -c:a ac3 -b:a 384k TestData/audio/tone-centre-5.1.ac3
///     ffmpeg -f lavfi -i "sine=frequency=440:duration=1:sample_rate=48000" \
///       -filter_complex "[0:a]aformat=channel_layouts=mono,pan=3.0|FL=0*c0|FR=0*c0|FC=c0[a]" \
///       -map "[a]" -c:a ac3 -b:a 192k TestData/audio/tone-centre-3.0.ac3
///
/// The sources are read only by `afinfo` and `afconvert` in child
/// processes (the rule of October 14, 2026), and no test plays sound. The
/// PCM sources are written by `AVAudioFile(forWriting:)`, which decodes
/// nothing.
final class AudioChannelDownmixTests: XCTestCase {
    private var folder: URL! // lint-ok: set in setUpWithError before any test body reads it

    override func setUpWithError() throws {
        folder = try AudioTestFixtures.makeTemporaryDirectory()
    }

    override func tearDown() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
    }

    // MARK: - Fixtures

    private static let centre51 = "audio/tone-centre-5.1.ac3"
    private static let centre30 = "audio/tone-centre-3.0.ac3"

    /// A source described by its channels, rate, depth, and kind, as the
    /// converter reads one.
    private func info(
        rate: Double = 44_100, channels: Int, bits: Int? = nil, lossless: Bool = false
    ) -> ImportAudioConverter.SourceInfo {
        ImportAudioConverter.SourceInfo(
            sampleRate: rate, channels: channels, duration: 10,
            formatID: lossless ? "lpcm" : "ac-3", bitsPerSample: bits, isLossless: lossless
        )
    }

    /// Writes `seconds` of a 440 Hz sine, the same in every channel (or in
    /// channel `signalIn` alone, the others silent), to `url` as 16-bit PCM in a CAF with the channel layout `tag`, and
    /// returns the channels the layout holds. `AVAudioFile` writes the
    /// file and decodes nothing.
    @discardableResult
    private func writePCM(
        layout tag: AudioChannelLayoutTag, to url: URL, seconds: Double = 1, rate: Double = 44_100,
        signalIn: Int? = nil
    ) throws -> Int {
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: tag))
        let channels = Int(layout.channelCount)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVChannelLayoutKey: Data(bytes: layout.layout, count: MemoryLayout<AudioChannelLayout>.size),
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        let channelData = try XCTUnwrap(buffer.floatChannelData)
        let pointers = UnsafeBufferPointer(start: channelData, count: Int(file.processingFormat.channelCount))
        for (channel, pointer) in pointers.enumerated() {
            let samples = UnsafeMutableBufferPointer(start: pointer, count: Int(frames))
            let sounding = signalIn == nil || signalIn == channel
            for index in samples.indices {
                samples[index] = sounding ? 0.25 * Float(sin(2 * Double.pi * 440 * Double(index) / rate)) : 0
            }
        }
        try file.write(from: buffer)
        return channels
    }

    /// A copy of the fixture `fixture` in the test's own folder, as `name`.
    private func copy(_ fixture: String, as name: String) throws -> URL {
        try OggTestFixtures.copy(fixture, to: folder, as: name)
    }

    /// Runs `/usr/bin/afconvert` with `arguments` in a watched child and
    /// returns its exit status (nil when it was killed or could not start).
    private func afconvert(_ arguments: [String], watching output: URL) async throws -> Int32? {
        let outcome = try await WatchedProcess.run(
            URL(fileURLWithPath: "/usr/bin/afconvert"), arguments: arguments, watching: output,
            limits: WatchedProcess.Limits(maximumSeconds: 60, maximumResidentBytes: 1 << 30, maximumStalledSeconds: 30)
        )
        if case let .exited(status) = outcome { return status }
        return nil
    }

    /// What `AudioFileInfo` (afinfo in a child) says of the converted file.
    private func facts(of url: URL) async throws -> AudioFileInfo {
        let read = try await AudioFileInfo.read(url)
        return try XCTUnwrap(read)
    }

    /// The names in the test's folder, hidden ones included, sorted.
    private var names: [String] { OggTestFixtures.names(in: folder) }

    // MARK: - The Arguments

    /// A source of more than two channels needs the second step; mono and
    /// stereo do not.
    func testOnlyMoreThanTwoChannelsNeedADownmix() {
        XCTAssertFalse(ImportAudioConverter.needsDownmix(info(channels: 1)))
        XCTAssertFalse(ImportAudioConverter.needsDownmix(info(channels: 2)))
        XCTAssertTrue(ImportAudioConverter.needsDownmix(info(channels: 3)))
        XCTAssertTrue(ImportAudioConverter.needsDownmix(info(channels: 6)))
        XCTAssertTrue(ImportAudioConverter.needsDownmix(info(channels: 12)))
    }

    /// TextMouth writes two channels at most, AAC and Apple Lossless alike,
    /// and an AAC bit rate for a source of more is chosen among stereo's.
    func testNoTargetHasMoreThanTwoChannels() {
        for channels in [1, 2, 3, 6, 8, 12] {
            let expected = min(channels, 2)
            let lossy = ImportAudioConverter.target(for: info(channels: channels), bytes: 1_000_000)
            XCTAssertEqual(lossy.channels, expected, "lossy, \(channels) channels")
            let lossless = ImportAudioConverter.target(for: info(channels: channels, bits: 16, lossless: true), bytes: 1)
            XCTAssertEqual(lossless.channels, expected, "lossless, \(channels) channels")
        }
        // 450,000 bytes in 10 seconds is 360 kbit/s: above every stereo rate, so the highest.
        let surround = ImportAudioConverter.target(for: info(channels: 6), bytes: 450_000)
        XCTAssertEqual(surround.bitRate, 192_000)
        // 40,000 bytes in 10 seconds is 32 kbit/s: stereo's lowest rate, not mono's 32 kbit/s.
        let quiet = ImportAudioConverter.target(for: info(channels: 6), bytes: 40_000)
        XCTAssertEqual(quiet.bitRate, 64_000)
    }

    /// Step 1 writes stereo PCM in a CAF at the rate and depth step 2 keeps:
    /// 16 bits for AAC, the depth of Apple Lossless samples (24 for 20,
    /// which PCM has no form of).
    func testStepOneWritesStereoPCMAtTheTargetsRateAndDepth() {
        let input = URL(fileURLWithPath: "/in/a.ac3")
        let output = URL(fileURLWithPath: "/in/.x.audio-downmix.caf")
        let aac = ImportAudioConverter.target(for: info(rate: 88_200, channels: 6), bytes: 100_000)
        XCTAssertEqual(
            ImportAudioConverter.downmixArguments(from: input, to: output, target: aac),
            ["-f", "caff", "-d", "LEI16@44100", "-c", "2", "--mix", "/in/a.ac3", "/in/.x.audio-downmix.caf"]
        )
        for (bits, depth) in [(16, 16), (20, 24), (24, 24), (32, 32)] {
            let target = ImportAudioConverter.target(for: info(rate: 96_000, channels: 6, bits: bits, lossless: true), bytes: 1)
            XCTAssertEqual(
                ImportAudioConverter.downmixArguments(from: input, to: output, target: target),
                ["-f", "caff", "-d", "LEI\(depth)@96000", "-c", "2", "--mix", "/in/a.ac3", "/in/.x.audio-downmix.caf"],
                "\(bits) bits"
            )
        }
    }

    /// Step 2 never passes a channel count: afconvert refuses `-c` for AAC
    /// above stereo and for Apple Lossless above eight channels.
    func testStepTwoNeverPassesAChannelCount() {
        let input = URL(fileURLWithPath: "/in/.x.audio-downmix.caf")
        let output = URL(fileURLWithPath: "/in/.y.audio-conversion.m4a")
        for channels in [1, 2, 6, 12] {
            for lossless in [false, true] {
                let source = info(channels: channels, bits: lossless ? 24 : nil, lossless: lossless)
                let target = ImportAudioConverter.target(for: source, bytes: 100_000)
                let arguments = ImportAudioConverter.afconvertArguments(from: input, to: output, info: source, target: target)
                XCTAssertFalse(arguments.contains("-c"), "\(channels) channels, lossless \(lossless)")
            }
        }
    }

    /// The downmix file's hidden name is a temporary name, so the leftover
    /// removal and the orphaned-converter sweep both find it; a bare suffix
    /// or a visible name is not one.
    func testTheDownmixFileHasATemporaryName() throws {
        let hidden = ".\(UUID().uuidString)\(ImportAudioConverter.downmixSuffix)"
        XCTAssertTrue(ImportAudioConverter.isTemporaryName(hidden))
        XCTAssertTrue(OrphanedConversionSweep.isTemporaryOutputName("/Users/x/Book/\(hidden)"))
        XCTAssertFalse(ImportAudioConverter.isTemporaryName(ImportAudioConverter.downmixSuffix))
        XCTAssertFalse(ImportAudioConverter.isTemporaryName("x\(ImportAudioConverter.downmixSuffix)"))
        let source = folder.appendingPathComponent("a.ac3")
        XCTAssertTrue(ImportAudioConverter.isTemporaryName(ImportAudioConverter.downmixURL(beside: source).lastPathComponent))

        try Data("x".utf8).write(to: folder.appendingPathComponent(hidden))
        try Data("keep".utf8).write(to: folder.appendingPathComponent("a.caf"))
        ImportAudioConverter.removeLeftovers(in: folder)
        XCTAssertEqual(names, ["a.caf"])
    }

    // MARK: - Lossy Sources of More Than Two Channels

    /// A 3.0 and a 5.1 AC-3 file convert to stereo AAC that passes the
    /// probe and keeps its length, and nothing else is left in the folder.
    func testLossySurroundSourcesConvertToStereoAAC() async throws {
        for (fixture, name, channels) in [(Self.centre30, "three.ac3", 3), (Self.centre51, "six.ac3", 6)] {
            let source = try copy(fixture, as: name)
            let before = try XCTUnwrap(try await ImportAudioConverter.inspect(source))
            XCTAssertEqual(before.channels, channels, name)

            let conversion = try await ImportAudioConverter.convert(source)

            let converted = try await facts(of: conversion.converted)
            XCTAssertEqual(converted.formatID, "aac ", name)
            XCTAssertEqual(converted.channels, 2, name)
            XCTAssertEqual(converted.duration, 1.024, accuracy: 0.1, name)
            XCTAssertNotNil(conversion.bitRate, name)
        }
        XCTAssertEqual(names, ["six.ac3", "six.m4a", "three.ac3", "three.m4a"])
    }

    /// A 7.1 AAC file, made from 7.1 PCM with afconvert, converts to stereo
    /// AAC. The AAC encoder takes one of two 7.1 layout names, tried in turn.
    func testASevenPointOneAACSourceConvertsToStereoAAC() async throws {
        let pcm = folder.appendingPathComponent("eight.caf")
        let channels = try writePCM(layout: kAudioChannelLayoutTag_MPEG_7_1_C, to: pcm)
        XCTAssertEqual(channels, 8)
        let aac = folder.appendingPathComponent("eight-aac.caf")
        var made = false
        for layoutName in ["AAC_7_1", "MPEG_7_1_C"] where !made {
            let status = try await afconvert(["-f", "caff", "-d", "aac", "-l", layoutName, pcm.path, aac.path], watching: aac)
            made = status == 0
        }
        try XCTSkipUnless(made, "This macOS's AAC encoder takes neither 7.1 layout name.")
        let before = try XCTUnwrap(try await ImportAudioConverter.inspect(aac))
        XCTAssertEqual(before.channels, 8)
        XCTAssertFalse(before.isLossless)

        let conversion = try await ImportAudioConverter.convert(aac)

        let converted = try await facts(of: conversion.converted)
        XCTAssertEqual(converted.formatID, "aac ")
        XCTAssertEqual(converted.channels, 2)
        XCTAssertEqual(converted.duration, 1, accuracy: 0.2)
    }

    /// The dialogue lives in a film's centre channel: the 5.1 fixture has
    /// its tone there alone, and both channels of the stereo file carry it.
    /// The converted file is decoded to WAV by afconvert in a child, and
    /// each channel's level is read from the WAV's bytes.
    func testTheCentreChannelReachesBothEars() async throws {
        let source = try copy(Self.centre51, as: "film.ac3")
        let conversion = try await ImportAudioConverter.convert(source)
        let wav = folder.appendingPathComponent("decoded.wav")
        let status = try await afconvert(["-f", "WAVE", "-d", "LEI16", conversion.converted.path, wav.path], watching: wav)
        XCTAssertEqual(status, 0)

        let levels = try XCTUnwrap(Self.channelLevels(ofWAVAt: wav))

        XCTAssertEqual(levels.count, 2)
        for level in levels {
            // A 0 dBFS full-scale sine has an RMS of 23,170; silence is 0.
            XCTAssertGreaterThan(level, 300, "a channel is silent")
        }
    }

    /// The RMS level of each channel of the 16-bit WAVE file at `url`, read
    /// from its bytes (the chunk walk finds "fmt " and "data" wherever they
    /// are, and WAVE_FORMAT_EXTENSIBLE files read the same); nil when the
    /// file is not a 16-bit WAVE file.
    private static func channelLevels(ofWAVAt url: URL) -> [Double]? {
        guard let data = try? Data(contentsOf: url), data.count > 12 else { return nil }
        /// The unsigned little-endian integer of `size` bytes at `offset`, or nil past the end.
        func integer(at offset: Int, size: Int) -> Int? {
            guard offset >= 0, offset + size <= data.count else { return nil }
            return (0..<size).reduce(0) { $0 | Int(data[data.startIndex + offset + $1]) << (8 * $1) }
        }
        var channels = 0
        var offset = 12
        while let size = integer(at: offset + 4, size: 4) {
            let body = offset + 8
            let id = String(decoding: data.dropFirst(offset).prefix(4), as: UTF8.self)
            if id == "fmt " {
                guard let count = integer(at: body + 2, size: 2), integer(at: body + 14, size: 2) == 16 else { return nil }
                channels = count
            } else if id == "data" {
                guard channels > 0 else { return nil }
                let frames = min(size, data.count - body) / (2 * channels)
                guard frames > 0 else { return nil }
                return (0..<channels).map { channel in
                    let squares = (0..<frames).reduce(0.0) { sum, frame in
                        let raw = integer(at: body + (frame * channels + channel) * 2, size: 2) ?? 0
                        let sample = Double(Int16(truncatingIfNeeded: raw))
                        return sum + sample * sample
                    }
                    return (squares / Double(frames)).squareRoot()
                }
            }
            offset = body + size + (size % 2)
        }
        return nil
    }

    /// How many decibels `level` is below `reference`, both RMS levels.
    private static func decibels(below reference: Double, _ level: Double) -> Double {
        20 * log10(reference / max(level, 1e-9))
    }

    /// Decodes the file at `url` to WAV with afconvert in a child process and
    /// returns each channel's RMS level.
    private func levels(of url: URL, as name: String) async throws -> [Double] {
        let wav = folder.appendingPathComponent(name)
        let status = try await afconvert(["-f", "WAVE", "-d", "LEI16", url.path, wav.path], watching: wav)
        XCTAssertEqual(status, 0, name)
        return try XCTUnwrap(Self.channelLevels(ofWAVAt: wav))
    }

    /// Checks that the stereo file at `converted`, mixed from a source whose
    /// tone is in its centre channel alone (RMS `sourceCentre`), carries the
    /// tone in both channels: each channel is within 20 dB of the source's
    /// centre, and the two within 1 dB of each other. The exact level is not
    /// pinned (Apple may change its normalization); it is printed, so a
    /// change shows in the log without failing.
    private func assertCentreInBothEars(of converted: URL, sourceCentre: Double, _ label: String) async throws {
        let levels = try await levels(of: converted, as: "\(label)-converted.wav")
        XCTAssertEqual(levels.count, 2, label)
        let drops = levels.map { Self.decibels(below: sourceCentre, $0) }
        print("\(label): the centre arrives \(drops.map { String(format: "%.1f", $0) }) dB below the source's centre")
        for drop in drops {
            XCTAssertLessThan(drop, 20, "\(label): a channel lost the centre")
        }
        if let first = drops.first, let last = drops.last {
            XCTAssertEqual(first, last, accuracy: 1, "\(label): the ears differ")
        }
    }

    /// A 5.1 PCM file with signal in the centre channel alone (layout
    /// MPEG_5_1_A) converts to a stereo file with the tone in both channels.
    /// Without `--mix` the centre is lost (-93 dBFS against -21).
    func testAPCMCentreReachesBothEars() async throws {
        let source = folder.appendingPathComponent("pcm51.caf")
        try writePCM(layout: kAudioChannelLayoutTag_MPEG_5_1_A, to: source, signalIn: 2)
        let sourceCentre = try XCTUnwrap(try await levels(of: source, as: "source.wav").max())
        XCTAssertGreaterThan(sourceCentre, 1_000)

        let conversion = try await ImportAudioConverter.convert(source)

        try await assertCentreInBothEars(of: conversion.converted, sourceCentre: sourceCentre, "pcm 5.1")
    }

    /// The same for the committed AC-3 fixture, which AC-3's own decoder mixes.
    func testAnAC3CentreReachesBothEars() async throws {
        let source = try copy(Self.centre51, as: "film.ac3")
        let sourceCentre = try XCTUnwrap(try await levels(of: source, as: "source.wav").max())
        XCTAssertGreaterThan(sourceCentre, 1_000)

        let conversion = try await ImportAudioConverter.convert(source)

        try await assertCentreInBothEars(of: conversion.converted, sourceCentre: sourceCentre, "ac-3 5.1")
    }

    // MARK: - Sources That Do Not Say Which Channel Is Which

    /// Writes a CAF of `channels` channels of 16-bit PCM by hand, one second
    /// of a tone in every channel. With `labelled`, a layout chunk names each
    /// channel (the standard labels 1, 2, 3, ...: L R C LFE Ls Rs Lc Rc Cs
    /// Lsd for ten); without, there is no layout chunk at all, which
    /// `AVAudioFile` cannot write (it may add a layout of its own).
    private func writeCAF(channels: Int, labelled: Bool = false, to url: URL, rate: Double = 44_100) throws {
        func bigEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
            withUnsafeBytes(of: value.bigEndian) { Array($0) }
        }
        let frames = Int(rate)
        var pcm = Data()
        for index in 0..<frames {
            let sample = Int16(8_000 * sin(2 * Double.pi * 440 * Double(index) / rate))
            for _ in 0..<channels { pcm.append(contentsOf: withUnsafeBytes(of: sample.littleEndian) { Array($0) }) }
        }
        var description = bigEndian(rate.bitPattern)
        description += Array("lpcm".utf8) + bigEndian(UInt32(2)) + bigEndian(UInt32(2 * channels))
        description += bigEndian(UInt32(1)) + bigEndian(UInt32(channels)) + bigEndian(UInt32(16))
        var file = Data("caff".utf8) + Data(bigEndian(UInt16(1)) + bigEndian(UInt16(0)))
        file += Data("desc".utf8) + Data(bigEndian(Int64(description.count)) + description)
        if labelled {
            // Layout tag 0 means "use the channel descriptions": a label, flags, and three coordinates each.
            var layout = bigEndian(UInt32(0)) + bigEndian(UInt32(0)) + bigEndian(UInt32(channels))
            for label in 1...channels { layout += bigEndian(UInt32(label)) + Array(repeating: 0, count: 16) }
            file += Data("chan".utf8) + Data(bigEndian(Int64(layout.count)) + layout)
        }
        file += Data("data".utf8) + Data(bigEndian(Int64(pcm.count + 4)) + bigEndian(UInt32(0)))
        file += pcm
        try file.write(to: url)
    }

    /// A six-channel file with no layout, and one whose channels are only
    /// "Discrete", is refused by name before any child runs: afconvert would
    /// keep the first two channels, and the speech is often the third. A
    /// labelled one, and stereo without a layout, are not refused.
    func testASurroundSourceWithoutALayoutIsRefusedByName() async throws {
        let bare = folder.appendingPathComponent("bare.caf")
        try writeCAF(channels: 6, to: bare)
        let discrete = folder.appendingPathComponent("discrete.caf")
        try writePCM(layout: kAudioChannelLayoutTag_DiscreteInOrder | 6, to: discrete)
        let marker = folder.appendingPathComponent("a-child-ran")
        let spy = tool(downmix: ("/usr/bin/touch", [marker.path]), convert: ("/usr/bin/touch", [marker.path]))

        for (source, name) in [(bare, "bare.caf"), (discrete, "discrete.caf")] {
            let inspected = try XCTUnwrap(try await ImportAudioConverter.inspect(source))
            XCTAssertFalse(inspected.hasChannelLayout, name)
            do {
                _ = try await ImportAudioConverter.convert(source, using: spy)
                XCTFail("\(name) must be refused")
            } catch let failure as ImportAudioConverter.Failure {
                XCTAssertEqual(failure, .unlabelledChannels(fileName: name, channels: 6), name)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "no child ran")
        XCTAssertEqual(names, ["bare.caf", "discrete.caf"])

        let stereo = folder.appendingPathComponent("stereo.caf")
        try writeCAF(channels: 2, to: stereo)
        let conversion = try await ImportAudioConverter.convert(stereo)
        XCTAssertEqual(conversion.converted.lastPathComponent, "stereo.m4a")
    }

    /// The refusal's words, with the file's own count.
    func testTheWordsOfTheUnlabelledChannelsFailure() {
        XCTAssertEqual(
            ImportAudioConverter.Failure.unlabelledChannels(fileName: "film.caf", channels: 6).errorDescription,
            "The audio file film.caf has 6 channels but does not say which is which, so TextMouth cannot mix it to stereo."
        )
    }

    /// afinfo's layouts are read for the track and for the AAC format: AC-3
    /// and a labelled PCM file have one, as has the converted stereo AAC.
    func testALabelledFileHasAChannelLayout() async throws {
        let ac3 = try copy(Self.centre51, as: "film.ac3")
        let ac3Info = try XCTUnwrap(try await ImportAudioConverter.inspect(ac3))
        XCTAssertTrue(ac3Info.hasChannelLayout)
        let pcm = folder.appendingPathComponent("pcm51.caf")
        try writePCM(layout: kAudioChannelLayoutTag_MPEG_5_1_A, to: pcm)
        let pcmInfo = try XCTUnwrap(try await ImportAudioConverter.inspect(pcm))
        XCTAssertTrue(pcmInfo.hasChannelLayout)
        let conversion = try await ImportAudioConverter.convert(ac3)
        XCTAssertTrue(try await facts(of: conversion.converted).hasChannelLayout)
    }

    // MARK: - Lossless Sources of Every Channel Count

    /// PCM of one to eight channels, each in a standard layout, converts to
    /// Apple Lossless with one channel for mono and two for the rest.
    func testEveryChannelCountFromOneToEightConvertsToAppleLossless() async throws {
        let layouts: [(String, AudioChannelLayoutTag, Int)] = [
            ("mono", kAudioChannelLayoutTag_Mono, 1),
            ("stereo", kAudioChannelLayoutTag_Stereo, 2),
            ("three", kAudioChannelLayoutTag_MPEG_3_0_A, 3),
            ("quad", kAudioChannelLayoutTag_Quadraphonic, 4),
            ("five", kAudioChannelLayoutTag_MPEG_5_0_A, 5),
            ("six", kAudioChannelLayoutTag_MPEG_5_1_A, 6),
            ("seven", kAudioChannelLayoutTag_MPEG_6_1_A, 7),
            ("eight", kAudioChannelLayoutTag_MPEG_7_1_C, 8),
        ]
        for (name, tag, channels) in layouts {
            let source = folder.appendingPathComponent("\(name).caf")
            XCTAssertEqual(try writePCM(layout: tag, to: source), channels, name)

            let conversion = try await ImportAudioConverter.convert(source)

            let converted = try await facts(of: conversion.converted)
            XCTAssertEqual(converted.formatID, "alac", name)
            XCTAssertEqual(converted.channels, channels == 1 ? 1 : 2, name)
            XCTAssertEqual(converted.bitsPerSample, 16, name)
            XCTAssertEqual(converted.sampleRate, 44_100, name)
            XCTAssertEqual(converted.duration, 1, accuracy: 0.1, name)
        }
        XCTAssertEqual(names.filter { $0.hasPrefix(".") }, [], "no hidden file is left")
        XCTAssertEqual(names.count, 16)
    }

    /// A source of ten channels, labelled one by one (more than Apple
    /// Lossless holds), converts too, to stereo.
    func testATenChannelSourceConvertsToAppleLossless() async throws {
        let source = folder.appendingPathComponent("ten.caf")
        try writeCAF(channels: 10, labelled: true, to: source)
        let before = try XCTUnwrap(try await ImportAudioConverter.inspect(source))
        XCTAssertEqual(before.channels, 10)
        XCTAssertTrue(before.hasChannelLayout)

        let conversion = try await ImportAudioConverter.convert(source)

        let converted = try await facts(of: conversion.converted)
        XCTAssertEqual(converted.formatID, "alac")
        XCTAssertEqual(converted.channels, 2)
        XCTAssertEqual(names, ["ten.caf", "ten.m4a"])
    }

    /// A 5.1 source at 88,200 Hz keeps its rate through Apple Lossless: step
    /// 1 writes the stereo file at the rate step 2 keeps.
    func testALosslessSurroundSourceKeepsItsSampleRate() async throws {
        let source = folder.appendingPathComponent("wide.caf")
        try writePCM(layout: kAudioChannelLayoutTag_MPEG_5_1_A, to: source, rate: 88_200)

        let conversion = try await ImportAudioConverter.convert(source)

        let converted = try await facts(of: conversion.converted)
        XCTAssertEqual(converted.sampleRate, 88_200)
        XCTAssertEqual(converted.channels, 2)
        XCTAssertEqual(converted.duration, 1, accuracy: 0.1)
    }

    // MARK: - Nothing Is Left Behind

    /// A stand-in tool: each step runs the executable and arguments given,
    /// or afconvert itself where nil, under limits that stop a hung child
    /// after `stalled` seconds without output.
    private func tool(
        downmix: (String, [String])? = nil, convert: (String, [String])? = nil, stalled: TimeInterval = 2
    ) -> ImportAudioConverter.Tool {
        let limits = WatchedProcess.Limits(
            maximumSeconds: 60, maximumResidentBytes: 1 << 30, maximumStalledSeconds: stalled, pollInterval: 0.1
        )
        var tool = ImportAudioConverter.Tool.afconvert
        tool.limits = { _ in limits }
        if let downmix {
            tool.downmixCommand = { _, _, _ in (URL(fileURLWithPath: downmix.0), downmix.1) }
        }
        if let convert {
            tool.command = { _, _, _, _ in (URL(fileURLWithPath: convert.0), convert.1) }
        }
        return tool
    }

    /// Converts the 5.1 fixture with `tool` and returns what it threw.
    private func failure(of tool: ImportAudioConverter.Tool) async throws -> ImportAudioConverter.Failure? {
        let source = try copy(Self.centre51, as: "film.ac3")
        do {
            _ = try await ImportAudioConverter.convert(source, using: tool)
            return nil
        } catch let failure as ImportAudioConverter.Failure {
            return failure
        }
    }

    /// A success leaves the source and the .m4a, and no hidden stereo file.
    func testASuccessLeavesNoIntermediate() async throws {
        let source = try copy(Self.centre51, as: "film.ac3")
        _ = try await ImportAudioConverter.convert(source)
        XCTAssertEqual(names, ["film.ac3", "film.m4a"])
    }

    /// A failing step 1 fails the conversion with its exit status, runs no
    /// second step, and leaves nothing.
    func testAFailureOfStepOneLeavesNothing() async throws {
        let failed = try await failure(of: tool(downmix: ("/usr/bin/false", []), convert: ("/usr/bin/true", [])))
        XCTAssertEqual(failed, .processFailed(fileName: "film.ac3", status: 1))
        XCTAssertEqual(names, ["film.ac3"])
    }

    /// A failing step 2 (after a real step 1 wrote the stereo file) fails
    /// the conversion and removes that file.
    func testAFailureOfStepTwoRemovesTheIntermediate() async throws {
        let failed = try await failure(of: tool(convert: ("/bin/sh", ["-c", "exit 3"])))
        XCTAssertEqual(failed, .processFailed(fileName: "film.ac3", status: 3))
        XCTAssertEqual(names, ["film.ac3"])
    }

    /// A hung step 1 is killed and fails the conversion, leaving nothing.
    func testAKillInStepOneLeavesNothing() async throws {
        let failed = try await failure(of: tool(downmix: ("/bin/sleep", ["60"]), stalled: 0.5))
        XCTAssertEqual(failed, .killed(fileName: "film.ac3", reason: "its output did not grow for 1 second"))
        XCTAssertEqual(names, ["film.ac3"])
    }

    /// A hung step 2 is killed and fails the conversion, and the stereo file
    /// step 1 wrote is removed.
    func testAKillInStepTwoRemovesTheIntermediate() async throws {
        let failed = try await failure(of: tool(convert: ("/bin/sleep", ["60"]), stalled: 2))
        XCTAssertEqual(failed, .killed(fileName: "film.ac3", reason: "its output did not grow for 2 seconds"))
        XCTAssertEqual(names, ["film.ac3"])
    }

    /// A mono or stereo source is written in one step: the downmix step's
    /// command is never run.
    func testAStereoSourceNeverRunsTheDownmixStep() async throws {
        let source = folder.appendingPathComponent("plain.caf")
        try writePCM(layout: kAudioChannelLayoutTag_Stereo, to: source)
        let conversion = try await ImportAudioConverter.convert(source, using: tool(downmix: ("/usr/bin/false", [])))
        XCTAssertEqual(conversion.converted.lastPathComponent, "plain.m4a")
        XCTAssertEqual(names, ["plain.caf", "plain.m4a"])
    }

    // MARK: - Disk Space

    /// What the 5.1 fixture's downmix needs free: its 49,152 frames at
    /// 48 kHz in two channels of 16-bit samples, and 512 MB.
    private static let fixtureBytesNeeded: Int64 = 49_152 * 2 * 2 + 512 * 1_048_576

    /// A tool whose volume holds `available` bytes (nil: unknown), whose
    /// downmix step, if it ever runs, touches `marker`.
    private func tool(available: Int64?, marker: URL) -> ImportAudioConverter.Tool {
        var tool = tool(downmix: ("/usr/bin/touch", [marker.path]))
        tool.availableBytes = { _ in available }
        return tool
    }

    /// The stereo PCM file's size is its length at the rate written, in two
    /// channels of 16-bit samples for AAC and of the Apple Lossless depth
    /// (24 bits for 20), and 512 MB on top.
    func testTheFreeSpaceADownmixNeeds() {
        let reserve = Int64(512 * 1_048_576)
        let aac = ImportAudioConverter.target(for: info(rate: 44_100, channels: 6), bytes: 1_000_000)
        XCTAssertEqual(
            ImportAudioConverter.downmixBytesNeeded(duration: 3_600, target: aac),
            3_600 * 44_100 * 2 * 2 + reserve
        )
        for (bits, bytes) in [(16, 2), (20, 3), (24, 3), (32, 4)] as [(Int, Int64)] {
            let lossless = ImportAudioConverter.target(for: info(rate: 96_000, channels: 6, bits: bits, lossless: true), bytes: 1)
            XCTAssertEqual(
                ImportAudioConverter.downmixBytesNeeded(duration: 600, target: lossless),
                600 * 96_000 * 2 * bytes + reserve,
                "\(bits) bits"
            )
        }
    }

    /// The refusal reads as a whole sentence with the size in figures.
    func testTheWordsOfTheNotEnoughSpaceFailure() {
        XCTAssertEqual(
            ImportAudioConverter.Failure.notEnoughSpace(fileName: "a.ac3", bytesNeeded: 1_400_000_000).errorDescription,
            "There is not enough free disk space to convert a.ac3: it needs 1.4 GB free."
        )
    }

    /// The real reading of the free space gives a figure for the temporary
    /// folder's volume.
    func testTheRealFreeSpaceReadingGivesAFigure() throws {
        let free = try XCTUnwrap(ImportAudioConverter.availableBytes(on: folder))
        XCTAssertGreaterThan(free, 0)
    }

    /// With less free space than the downmix needs, the conversion is
    /// refused with the new failure before any child runs, leaving nothing.
    func testNotEnoughSpaceIsRefusedBeforeAnyChildRuns() async throws {
        let marker = folder.appendingPathComponent("step-one-ran")
        let refused = try await failure(of: tool(available: Self.fixtureBytesNeeded - 1, marker: marker))
        XCTAssertEqual(refused, .notEnoughSpace(fileName: "film.ac3", bytesNeeded: Self.fixtureBytesNeeded))
        XCTAssertEqual(names, ["film.ac3"])
    }

    /// Exactly the free space needed is enough: the downmix runs (the
    /// stand-in's marker appears), so the refusal is for less only.
    func testExactlyEnoughSpaceRunsTheDownmix() async throws {
        let marker = folder.appendingPathComponent("step-one-ran")
        _ = try await failure(of: tool(available: Self.fixtureBytesNeeded, marker: marker))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    /// A volume that can't say how much it has is not a reason to refuse.
    func testUnknownFreeSpaceDoesNotRefuse() async throws {
        let marker = folder.appendingPathComponent("step-one-ran")
        _ = try await failure(of: tool(available: nil, marker: marker))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    /// A mono or stereo source writes no stereo file, so it asks for no
    /// space and converts however little the volume reports.
    func testAStereoSourceNeedsNoFreeSpaceForADownmix() async throws {
        let source = folder.appendingPathComponent("plain.caf")
        try writePCM(layout: kAudioChannelLayoutTag_Stereo, to: source)
        var noSpace = tool()
        noSpace.availableBytes = { _ in 0 }

        let conversion = try await ImportAudioConverter.convert(source, using: noSpace)

        XCTAssertEqual(conversion.converted.lastPathComponent, "plain.m4a")
    }
}
