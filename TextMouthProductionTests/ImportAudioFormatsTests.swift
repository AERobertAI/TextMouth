import XCTest
@testable import TextMouth

/// The audio formats macOS decodes, converted at import (FMT09, step 3):
/// what the converter knows of a source, the plan it makes (AAC for a lossy
/// source, Apple Lossless for a lossless one), the target and afconvert's
/// arguments for each, and the words of its failures. Nothing is played, and
/// no source is opened by Apple's audio frameworks inside the test host:
/// sources are read by `afinfo` and converted by `afconvert`, both in child
/// processes.
final class ImportAudioFormatsTests: XCTestCase {
    private var folder: URL! // lint-ok: made in setUpWithError before every test
    /// Imported book packages, removed when a test ends.
    private var importedPackages: [URL] = []

    override func setUpWithError() throws {
        folder = try AudioTestFixtures.makeTemporaryDirectory()
    }

    override func tearDown() {
        for package in importedPackages { try? FileManager.default.removeItem(at: package) }
        importedPackages = []
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
    }

    // MARK: - Helpers

    /// A description of a source, with the codec facts given.
    private func info(
        rate: Double = 44_100, channels: Int = 2, duration: TimeInterval = 10,
        formatID: String = "ac-3", bits: Int? = nil, lossless: Bool = false
    ) -> ImportAudioConverter.SourceInfo {
        ImportAudioConverter.SourceInfo(
            sampleRate: rate, channels: channels, duration: duration,
            formatID: formatID, bitsPerSample: bits, isLossless: lossless
        )
    }

    // MARK: - What the Converter Knows of a Source

    /// An Ogg file's codec comes from its own header: "vorbis" or "opus",
    /// never lossless, with no bit depth.
    func testAnOggSourceNamesItsCodecAndIsNeverLossless() async throws {
        let vorbis = folder.appendingPathComponent("synthetic.ogg")
        try Data(OggStreamBuilder.vorbisStream(channels: 2, rate: 44_100, granule: 88_200)).write(to: vorbis)
        let opus = folder.appendingPathComponent("synthetic.opus")
        try Data(OggStreamBuilder.opusStream(channels: 2, preSkip: 312, granule: 48_312)).write(to: opus)

        let vorbisRead = try await ImportAudioConverter.inspect(vorbis)
        let vorbisInfo = try XCTUnwrap(vorbisRead)
        XCTAssertEqual(vorbisInfo.formatID, "vorbis")
        XCTAssertNil(vorbisInfo.bitsPerSample)
        XCTAssertFalse(vorbisInfo.isLossless)
        let opusRead = try await ImportAudioConverter.inspect(opus)
        let opusInfo = try XCTUnwrap(opusRead)
        XCTAssertEqual(opusInfo.formatID, "opus")
        XCTAssertFalse(opusInfo.isLossless)
    }

    /// Any other source is read by afinfo: PCM gives its codec, its depth,
    /// and its lossless mark. A file that is not audio, and a missing file,
    /// give nothing.
    func testAnotherSourceIsReadByAfinfo() async throws {
        let wave = folder.appendingPathComponent("silence.wav")
        try AudioTestFixtures.writeSilence(to: wave, duration: 2)
        let text = folder.appendingPathComponent("text.amr")
        try Data("not audio".utf8).write(to: text)

        let waveRead = try await ImportAudioConverter.inspect(wave)
        let waveInfo = try XCTUnwrap(waveRead)
        XCTAssertEqual(waveInfo.formatID, "lpcm")
        XCTAssertEqual(waveInfo.bitsPerSample, 16)
        XCTAssertEqual(waveInfo.channels, 1)
        XCTAssertTrue(waveInfo.isLossless)
        let textRead = try await ImportAudioConverter.inspect(text)
        XCTAssertNil(textRead)
        let missingRead = try await ImportAudioConverter.inspect(folder.appendingPathComponent("missing.ac3"))
        XCTAssertNil(missingRead)
    }

    // MARK: - The Plan

    /// An extension the import does not convert is left as it is, whatever
    /// the file holds; a converted one is Apple Lossless when lossless and
    /// AAC otherwise.
    func testThePlanFollowsTheExtensionAndTheCodec() {
        let lossy = info(formatID: "vorbis")
        let lossless = info(formatID: "flac", bits: 16, lossless: true)
        XCTAssertEqual(ImportAudioConverter.plan(for: URL(fileURLWithPath: "/a/b.mp3"), info: lossy), .leaveAsItIs)
        XCTAssertEqual(ImportAudioConverter.plan(for: URL(fileURLWithPath: "/a/b.flac"), info: lossless), .leaveAsItIs)
        XCTAssertEqual(ImportAudioConverter.plan(for: URL(fileURLWithPath: "/a/b.ogg"), info: lossy), .convertToAAC)
        XCTAssertEqual(ImportAudioConverter.plan(for: URL(fileURLWithPath: "/a/B.OGG"), info: lossy), .convertToAAC)
        XCTAssertEqual(ImportAudioConverter.plan(for: URL(fileURLWithPath: "/a/b.ogg"), info: lossless), .convertToAppleLossless)
    }

    // MARK: - The Target

    /// Apple Lossless keeps the source's own sample rate, takes no bit rate,
    /// and keeps up to eight channels (more are mixed down by afconvert).
    func testALosslessTargetKeepsTheRateAndTheChannelsUpToEight() {
        let stereo = ImportAudioConverter.target(for: info(rate: 96_000, bits: 24, lossless: true), bytes: 1_000_000)
        XCTAssertEqual(stereo, .init(channels: 2, sampleRate: 96_000, bitRate: nil, appleLosslessBitDepth: 24))
        let surround = ImportAudioConverter.target(for: info(rate: 48_000, channels: 6, bits: 16, lossless: true), bytes: 1)
        XCTAssertEqual(surround.channels, 6)
        let many = ImportAudioConverter.target(for: info(channels: 12, bits: 16, lossless: true), bytes: 1)
        XCTAssertEqual(many.channels, 8)
        let none = ImportAudioConverter.target(for: info(channels: 0, bits: 16, lossless: true), bytes: 1)
        XCTAssertEqual(none.channels, 1)
    }

    /// The bit depth is the smallest of 16, 20, 24, and 32 that holds the
    /// source's; an unknown depth (nil: floating-point or unreported) is 24.
    func testTheLosslessBitDepthIsTheSmallestThatHoldsTheSource() {
        let expected: [(Int?, Int)] = [
            (8, 16), (16, 16), (17, 20), (20, 20), (21, 24), (24, 24), (25, 32), (32, 32), (64, 32), (nil, 24),
        ]
        for (bits, depth) in expected {
            let target = ImportAudioConverter.target(for: info(bits: bits, lossless: true), bytes: 1)
            XCTAssertEqual(target.appleLosslessBitDepth, depth, "bits \(String(describing: bits))")
        }
    }

    /// A lossy source's target is AAC as before: no Apple Lossless depth.
    func testALossyTargetIsAAC() {
        let target = ImportAudioConverter.target(for: info(channels: 6, formatID: "vorbis"), bytes: 100_000)
        XCTAssertNil(target.appleLosslessBitDepth)
        XCTAssertEqual(target.channels, 2)
        XCTAssertNotNil(target.bitRate)
    }

    // MARK: - afconvert's Arguments

    /// Apple Lossless names its bit depth by flag (1, 2, 3, 4 for 16, 20, 24,
    /// 32 bits), takes no sample rate or bit rate, and adds `-c 8` only for
    /// a source of more than eight channels.
    func testApplesLosslessArgumentsNameTheDepthFlag() {
        let input = URL(fileURLWithPath: "/in/a.caf")
        let output = URL(fileURLWithPath: "/out/.a.m4a")
        for (depth, flag) in [(16, "1"), (20, "2"), (24, "3"), (32, "4")] {
            let source = info(rate: 96_000, bits: depth, lossless: true)
            let target = ImportAudioConverter.target(for: source, bytes: 1)
            XCTAssertEqual(
                ImportAudioConverter.afconvertArguments(from: input, to: output, info: source, target: target),
                ["-f", "m4af", "-d", "alac/\(flag)", "/in/a.caf", "/out/.a.m4a"]
            )
        }
        let eight = info(channels: 8, bits: 16, lossless: true)
        XCTAssertEqual(
            ImportAudioConverter.afconvertArguments(
                from: input, to: output, info: eight, target: ImportAudioConverter.target(for: eight, bytes: 1)
            ),
            ["-f", "m4af", "-d", "alac/1", "/in/a.caf", "/out/.a.m4a"]
        )
        let twelve = info(channels: 12, bits: 16, lossless: true)
        XCTAssertEqual(
            ImportAudioConverter.afconvertArguments(
                from: input, to: output, info: twelve, target: ImportAudioConverter.target(for: twelve, bytes: 1)
            ),
            ["-f", "m4af", "-d", "alac/1", "-c", "8", "/in/a.caf", "/out/.a.m4a"]
        )
    }

    // MARK: - Converting

    /// A real conversion of 16-bit PCM gives Apple Lossless of the source's
    /// length and depth, and leaves the source and no hidden file. Its
    /// size stays near the source's (the depth flag keeps it from growing to
    /// 32-bit samples).
    func testPCMConvertsToAppleLosslessAtItsOwnDepth() async throws {
        let source = folder.appendingPathComponent("silence.wav")
        try AudioTestFixtures.writeSilence(to: source, duration: 2)
        let sourceBytes = try Data(contentsOf: source)

        let conversion = try await ImportAudioConverter.convert(source)

        XCTAssertEqual(conversion.converted.lastPathComponent, "silence.m4a")
        let convertedRead = try await AudioFileInfo.read(conversion.converted)
        let converted = try XCTUnwrap(convertedRead)
        XCTAssertEqual(converted.formatID, "alac")
        XCTAssertEqual(converted.bitsPerSample, 16)
        XCTAssertEqual(converted.sampleRate, 8_000)
        XCTAssertEqual(converted.duration, 2, accuracy: 0.1)
        XCTAssertNil(conversion.bitRate)
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        XCTAssertEqual(OggTestFixtures.names(in: folder), ["silence.m4a", "silence.wav"])
    }

    /// A lossless source is estimated at its own size and 64 KB; a file
    /// that can't be read, at its own size alone.
    func testALosslessSourceIsEstimatedAtItsOwnSize() async throws {
        let wave = folder.appendingPathComponent("silence.wav")
        try AudioTestFixtures.writeSilence(to: wave, duration: 2)
        let broken = folder.appendingPathComponent("broken.amr")
        try Data(repeating: 7, count: 1_000).write(to: broken)
        let waveBytes = ImportAudioConverter.fileSize(of: wave)

        let estimate = await ImportAudioConverter.estimatedSize(of: [wave, broken])

        XCTAssertEqual(estimate, waveBytes + 65_536 + 1_000)
    }

    // MARK: - The Words of a Failure

    /// The failures name no format, since the converter now takes many.
    func testTheFailuresAreInFormatNeutralWords() {
        XCTAssertEqual(
            ImportAudioConverter.Failure.unreadable(fileName: "a.ac3").errorDescription,
            "The audio file a.ac3 could not be read for converting."
        )
        XCTAssertEqual(
            ImportAudioConverter.Failure.checkFailed(fileName: "a.ac3", reason: "it lasts 1.0 seconds, not 2.0").errorDescription,
            "The audio converted from a.ac3 failed its check: it lasts 1.0 seconds, not 2.0."
        )
        XCTAssertEqual(
            ImportAudioConverter.Failure.cannotName(fileName: "a.ac3").errorDescription,
            "The audio converted from a.ac3 could not be given its name."
        )
        XCTAssertEqual(
            ImportAudioConverter.Failure.killed(fileName: "a.ac3", reason: "it ran too long").errorDescription,
            "Converting a.ac3 was stopped because it ran too long."
        )
        XCTAssertEqual(
            ImportAudioConverter.Failure.processFailed(fileName: "a.ac3", status: 3).errorDescription,
            "Converting a.ac3 failed (the converter ended with code 3)."
        )
    }

    // MARK: - The New Formats' Samples

    /// The new extensions' samples: where each is, the plan, and the codec
    /// the converted file must hold.
    private static let samples: [(path: String, plan: ImportAudioConverter.Plan, codec: String)] = [
        ("ac3/tones.ac3", .convertToAAC, "aac "),
        ("eac3/tones.ec3", .convertToAAC, "aac "),
        ("amr/tones.amr", .convertToAAC, "aac "),
        ("3gp/tones-aac.3gp", .convertToAAC, "aac "),
        ("3gp/tones-amr.3gp", .convertToAAC, "aac "),
        ("mp2/tones.mp2", .convertToAAC, "aac "),
        ("au/tones.au", .convertToAppleLossless, "alac"),
        ("aifc/tones-ima4.aifc", .convertToAAC, "aac "),
        ("aifc/tones-ulaw.aifc", .convertToAAC, "aac "),
        ("caf/tones-pcm.caf", .convertToAppleLossless, "alac"),
        ("caf/tones-alac.caf", .convertToAppleLossless, "alac"),
        ("caf/tones-opus.caf", .convertToAAC, "aac "),
        ("w64/tones.w64", .convertToAppleLossless, "alac"),
    ]

    /// Copies the sample `path` (under `TestData/format-samples`) into
    /// `destination` (the test's own folder by default), named as `name`
    /// when given, and returns the copy.
    @discardableResult
    private func copySample(_ path: String, as name: String? = nil, into destination: URL? = nil) throws -> URL {
        let target: URL = destination ?? folder
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let source = try requireFile("format-samples/\(path)")
        let copy = target.appendingPathComponent(name ?? source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

    /// Every sample, converted: the plan is the expected one, the .m4a holds
    /// AAC or Apple Lossless, lasts as long as its source, passes the
    /// playability probe, and (Apple Lossless) keeps the source's 16 bits.
    /// Each conversion's time is printed.
    func testEveryNewFormatConvertsToAnM4A() async throws {
        for sample in Self.samples {
            let source = try copySample(sample.path, into: folder.appendingPathComponent(UUID().uuidString))
            let sourceRead = try await ImportAudioConverter.inspect(source)
            let sourceInfo = try XCTUnwrap(sourceRead, sample.path)
            XCTAssertEqual(ImportAudioConverter.plan(for: source, info: sourceInfo), sample.plan, sample.path)

            let conversion = try await ImportAudioConverter.convert(source)

            XCTAssertEqual(conversion.converted.pathExtension, "m4a", sample.path)
            let convertedRead = try await AudioFileInfo.read(conversion.converted)
            let converted = try XCTUnwrap(convertedRead, sample.path)
            XCTAssertEqual(converted.formatID, sample.codec, sample.path)
            XCTAssertEqual(
                converted.duration, sourceInfo.duration,
                accuracy: ImportAudioConverter.allowedLengthError(for: sourceInfo.duration), sample.path
            )
            let probed = await AudioMediaProbe.duration(of: conversion.converted)
            if case .failure = probed { XCTFail("\(sample.path) does not play: \(probed)") }
            if sample.plan == .convertToAppleLossless {
                XCTAssertEqual(converted.bitsPerSample, sourceInfo.bitsPerSample, sample.path)
                XCTAssertEqual(converted.bitsPerSample, 16, sample.path)
            }
            print("FMT09 conversion time \(sample.path): \(String(format: "%.2f", conversion.secondsTaken)) s")
        }
    }

    // MARK: - Importing

    /// A single AC-3 file imports as an .m4a file, which is the book's
    /// file; no .ac3 is left in the package, and the original is untouched.
    func testASingleAC3FileImportsAsAnM4AFile() throws {
        let source = try copySample("ac3/tones.ac3")
        let sourceBytes = try Data(contentsOf: source)

        let imported = try FileImportService.importFileWithReport(from: source)
        importedPackages.append(imported.book.tmbDirectory)

        let audio = URL(fileURLWithPath: imported.book.filePath)
        XCTAssertEqual(audio.lastPathComponent, "tones.m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertEqual(OggTestFixtures.names(in: audio.deletingLastPathComponent()).filter { $0.hasSuffix(".ac3") }, [])
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
    }

    /// A folder of 01.ac3, 02.mp3, and 03.caf imports as 01.m4a, 02.mp3,
    /// and 03.m4a in that order; the mp3 stays as it is. A manifest naming
    /// the three names the renamed tracks, and the folder imported from
    /// keeps its files.
    func testAFolderOfMixedFormatsImportsInOrderWithItsManifestRenamed() throws {
        let source = folder.appendingPathComponent("Mixed")
        try copySample("ac3/tones.ac3", as: "01.ac3", into: source)
        let mp3 = try requireFile("format-samples/mp3-chapters/three-tones.mp3")
        try FileManager.default.copyItem(at: mp3, to: source.appendingPathComponent("02.mp3"))
        try copySample("caf/tones-pcm.caf", as: "03.caf", into: source)

        let plain = try FileImportService.importAudioFolderWithReport(from: source)
        importedPackages.append(plain.book.tmbDirectory)
        XCTAssertEqual(
            try AudioBookParser.trackPaths(in: URL(fileURLWithPath: plain.book.filePath)),
            ["01.m4a", "02.mp3", "03.m4a"]
        )

        let manifestJSON = Data(#"{"tracks": ["01.ac3", "02.mp3", "03.caf"]}"#.utf8)
        try manifestJSON.write(to: source.appendingPathComponent("manifest.json"))
        let named = try FileImportService.importAudioFolderWithReport(from: source)
        importedPackages.append(named.book.tmbDirectory)

        let audio = URL(fileURLWithPath: named.book.filePath)
        XCTAssertEqual(try AudioBookParser.trackPaths(in: audio), ["01.m4a", "02.mp3", "03.m4a"])
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: audio.appendingPathComponent("manifest.json")))
        XCTAssertEqual((written as? [String: Any])?["tracks"] as? [String], ["01.m4a", "02.mp3", "03.m4a"])
        XCTAssertEqual(OggTestFixtures.names(in: source), ["01.ac3", "02.mp3", "03.caf", "manifest.json"])
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("manifest.json")), manifestJSON)
    }

    /// An .amr of random bytes fails the import at Converting its audio, in
    /// words that name the file, and leaves nothing in the library folder.
    func testAnAMRFileOfRandomBytesFailsTheImportAtItsStep() throws {
        let source = folder.appendingPathComponent("Noise.amr")
        var generator = SystemRandomNumberGenerator()
        try Data((0..<4_096).map { _ in UInt8.random(in: 0...255, using: &generator) }).write(to: source)
        let libraryBefore = OggTestFixtures.names(in: TextMouthPaths.libraryDir)

        do {
            let imported = try FileImportService.importFileWithReport(from: source)
            importedPackages.append(imported.book.tmbDirectory)
            XCTFail("A file of random bytes must not import")
        } catch let failure as ImportFailure {
            XCTAssertEqual(failure.step.activity, "Converting its audio")
            XCTAssertEqual(failure.underlying as? ImportAudioConverter.Failure, .unreadable(fileName: "Noise.amr"))
            XCTAssertEqual(
                failure.errorDescription,
                "Could not import “Noise.amr”. Converting its audio failed: The audio file Noise.amr could not be read for converting."
            )
        }
        XCTAssertEqual(OggTestFixtures.names(in: TextMouthPaths.libraryDir), libraryBefore)
    }

    // MARK: - The Guards

    /// Each new extension is converted at import and never decoded in the
    /// app, except CAF, TextMouth's own working format, which the import
    /// converts all the same.
    func testEveryNewExtensionIsConvertedAndNeverDecodedInTheApp() {
        XCTAssertEqual(ImportAudioConverter.coreAudioExtensions.count, 16)
        for ext in ImportAudioConverter.coreAudioExtensions {
            for name in ["track.\(ext)", "TRACK.\(ext.uppercased())"] {
                let url = URL(fileURLWithPath: "/a/\(name)")
                XCTAssertTrue(ImportAudioConverter.isConvertedAtImport(url), name)
                XCTAssertEqual(ImportAudioConverter.isNeverDecodedInApp(url), ext != "caf", name)
            }
            XCTAssertTrue(ImportAudioConverter.convertedExtensions.contains(ext), ext)
        }
        // What TextMouth already plays stays as it is.
        for ext in ["mp3", "m4a", "m4b", "wav", "aiff", "aif", "flac", "alac", "aac", "mp4", "m4v", "mov"] {
            XCTAssertFalse(ImportAudioConverter.isConvertedAtImport(URL(fileURLWithPath: "/a/track.\(ext)")), ext)
        }
    }

    /// The metadata reader opens no file of a converted extension, CAF too.
    func testNoMetadataAssetIsMadeForAConvertedFormat() {
        for ext in ["ac3", "caf", "amr", "aifc"] {
            XCTAssertNil(AudioPlaybackService.metadataAsset(for: URL(fileURLWithPath: "/a/track.\(ext)")), ext)
        }
    }
}
