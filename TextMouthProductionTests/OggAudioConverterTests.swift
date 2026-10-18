import AVFoundation
import os
import XCTest
@testable import TextMouth

/// The Ogg fixtures every B06 test copies into its own folder: two-second
/// 440 Hz tones made with ffmpeg (`AudioDirectoryImportTests` gives the
/// commands), a Vorbis one at 22,050 Hz and an Opus one at 48,000 Hz, both
/// mono. They are only ever decoded offline, never played: no test may
/// hand Ogg audio to a player (the rule of October 14, 2026).
enum OggTestFixtures {
    /// The Vorbis tone.
    static let vorbis = "audio/ogg-vorbis-tone.ogg"
    /// The Opus tone.
    static let opus = "audio/ogg-opus-tone.opus"

    /// Skips a test on a macOS that cannot decode Ogg audio: AVFoundation
    /// reads it from macOS 15.4 on.
    static func skipUnlessOggDecodes() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.isOperatingSystemAtLeast(
                OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 0)
            ),
            "AVFoundation decodes Ogg audio from macOS 15.4 on."
        )
    }

    /// Copies the fixture `fixture` into `folder`, made when missing, as
    /// `name`, and returns the copy.
    @discardableResult
    static func copy(_ fixture: String, to folder: URL, as name: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: try requireFile(fixture), to: copy)
        return copy
    }

    /// The names of the files in `folder`, hidden ones included, sorted.
    static func names(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    /// The format of the first audio track of the file at `url`, or nil.
    static func formatID(of url: URL) async -> AudioFormatID? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let descriptions = try? await track.load(.formatDescriptions),
              let format = descriptions.first?.audioStreamBasicDescription else { return nil }
        return format.mFormatID
    }
}

/// The Ogg-to-AAC converter (B06, item 1): the bit rate and sample rate it
/// chooses, the file it writes beside its source and how that file is
/// named, the check it makes, and how it converts several files at once.
final class OggAudioConverterTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try AudioTestFixtures.makeTemporaryDirectory()
    }

    override func tearDown() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
    }

    // MARK: - The Settings

    /// A track's average bit rate is rounded up to the next standard AAC
    /// rate for its channels, so it stays about the same size and is no
    /// worse: 75 kbit/s stereo Vorbis becomes 80 kbit/s AAC, anything above
    /// the highest standard rate gets the highest, and mono uses half of
    /// stereo's rates.
    func testTheBitRateIsTheSourcesAverageRoundedUpToTheNextStandardRate() {
        let stereo = ImportAudioConverter.stereoBitRates
        let mono = stereo.map { $0 / 2 }
        XCTAssertEqual(ImportAudioConverter.bitRate(averaging: 75_000, channels: 2, accepted: stereo), 80_000)
        XCTAssertEqual(ImportAudioConverter.bitRate(averaging: 63_070, channels: 2, accepted: stereo), 64_000)
        XCTAssertEqual(ImportAudioConverter.bitRate(averaging: 20_000, channels: 2, accepted: stereo), 64_000)
        XCTAssertEqual(ImportAudioConverter.bitRate(averaging: 128_000, channels: 2, accepted: stereo), 128_000)
        XCTAssertEqual(ImportAudioConverter.bitRate(averaging: 300_000, channels: 2, accepted: stereo), 192_000)
        XCTAssertEqual(ImportAudioConverter.bitRate(averaging: 22_252, channels: 1, accepted: mono), 32_000)
        XCTAssertEqual(ImportAudioConverter.bitRate(averaging: 75_000, channels: 1, accepted: mono), 80_000)
        XCTAssertEqual(ImportAudioConverter.standardBitRates(channels: 1), [32_000, 40_000, 48_000, 56_000, 64_000, 80_000, 96_000])
    }

    /// Where the encoder doesn't take the standard rate at the sample rate
    /// written, the nearest rate above that it takes is used, or its
    /// highest; with none named, the encoder chooses.
    func testARateTheEncoderRefusesGivesWayToTheNearestItTakes() {
        XCTAssertEqual(ImportAudioConverter.bitRate(averaging: 75_000, channels: 2, accepted: [64_000, 96_000, 128_000]), 96_000)
        XCTAssertEqual(ImportAudioConverter.bitRate(averaging: 150_000, channels: 2, accepted: [24_000, 48_000]), 48_000)
        XCTAssertNil(ImportAudioConverter.bitRate(averaging: 75_000, channels: 2, accepted: []))
    }

    /// The source's sample rate is kept where AAC takes it; any other rate
    /// becomes 44.1 kHz in that rate's family and 48 kHz otherwise.
    func testTheSampleRateIsKeptWhereAACTakesIt() {
        for rate in [8_000.0, 22_050, 24_000, 32_000, 44_100, 48_000] {
            XCTAssertEqual(ImportAudioConverter.sampleRate(for: rate), rate)
        }
        XCTAssertEqual(ImportAudioConverter.sampleRate(for: 88_200), 44_100)
        XCTAssertEqual(ImportAudioConverter.sampleRate(for: 96_000), 48_000)
        XCTAssertEqual(ImportAudioConverter.sampleRate(for: 37_800), 48_000)
    }

    /// Ogg audio is known by its extension, in any case.
    func testOggFilesAreKnownByTheirExtension() {
        for name in ["a.ogg", "b.OGA", "c.opus"] {
            XCTAssertTrue(ImportAudioConverter.isOgg(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
        for name in ["a.m4a", "b.mp3", "c.ogg.m4a"] {
            XCTAssertFalse(ImportAudioConverter.isOgg(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
    }

    /// The import converts a file by its extension in any case, and no
    /// reader decodes one of those, except a CAF, which TextMouth writes
    /// itself (a recording's take, the audio editor's passes). A CAF is not
    /// converted yet, so it is never refused as the app's own.
    func testTheGuardsAskAboutTheFormatsTheImportConverts() {
        for name in ["a.ogg", "b.OPUS", "c.oga"] {
            let url = URL(fileURLWithPath: "/tmp/\(name)")
            XCTAssertTrue(ImportAudioConverter.isConvertedAtImport(url), name)
            XCTAssertTrue(ImportAudioConverter.isNeverDecodedInApp(url), name)
        }
        for name in ["d.mp3", "e.caf", "f.CAF", "g.ogg.m4a"] {
            let url = URL(fileURLWithPath: "/tmp/\(name)")
            XCTAssertFalse(ImportAudioConverter.isConvertedAtImport(url), name)
            XCTAssertFalse(ImportAudioConverter.isNeverDecodedInApp(url), name)
        }
        XCTAssertTrue(ImportAudioConverter.ownWorkingExtensions.contains("caf"))
    }

    /// `filesToConvert(in:)` and `oggFiles(in:)` list a folder's tracks by
    /// the reader's own rules, skipping a hidden file and a file of another
    /// format; an unreadable folder has none.
    func testTheFolderListingsKeepTheConvertedTracksAndSkipTheRest() throws {
        for name in ["01.ogg", "02.OGG", "03.mp3", ".04.ogg"] {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
        let names = { (urls: [URL]) in urls.map(\.lastPathComponent).sorted() }
        XCTAssertEqual(names(ImportAudioConverter.filesToConvert(in: folder)), ["01.ogg", "02.OGG"])
        XCTAssertEqual(names(ImportAudioConverter.oggFiles(in: folder)), ["01.ogg", "02.OGG"])
        XCTAssertEqual(ImportAudioConverter.filesToConvert(in: folder.appendingPathComponent("missing")), [])
    }

    /// A temporary name is hidden, ends with the current suffix or the
    /// legacy one (an earlier version's leftover), and has something
    /// before it.
    func testATemporaryNameIsHiddenAndEndsWithEitherSuffix() {
        let uuid = UUID().uuidString
        XCTAssertTrue(ImportAudioConverter.isTemporaryName(".01.\(uuid).audio-conversion.m4a"))
        XCTAssertTrue(ImportAudioConverter.isTemporaryName(".01.\(uuid).ogg-conversion.m4a"))
        XCTAssertTrue(ImportAudioConverter.isTemporaryName(".\(uuid)\(ImportAudioConverter.temporarySuffix)"))
        XCTAssertFalse(ImportAudioConverter.isTemporaryName(ImportAudioConverter.temporarySuffix))
        XCTAssertFalse(ImportAudioConverter.isTemporaryName(ImportAudioConverter.legacyTemporarySuffix))
        XCTAssertFalse(ImportAudioConverter.isTemporaryName("01.\(uuid).audio-conversion.m4a"))
        XCTAssertFalse(ImportAudioConverter.isTemporaryName(".hidden.m4a"))
        XCTAssertFalse(ImportAudioConverter.isTemporaryName(""))
    }

    /// The leftovers of both suffixes are removed, and a visible file with
    /// the suffix is kept.
    func testLeftoversOfEitherSuffixAreRemovedAndAVisibleFileIsKept() throws {
        let hidden = [
            ".01.\(UUID().uuidString)\(ImportAudioConverter.temporarySuffix)",
            ".02.\(UUID().uuidString)\(ImportAudioConverter.legacyTemporarySuffix)",
        ]
        for name in hidden + ["03.audio-conversion.m4a"] {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
        ImportAudioConverter.removeLeftovers(in: folder)
        XCTAssertEqual(OggTestFixtures.names(in: folder), ["03.audio-conversion.m4a"])
    }

    // MARK: - Converting a File

    /// A Vorbis file becomes AAC in an .m4a file beside it, with its stem,
    /// lasting as long; the source stays as it was, and nothing hidden is
    /// left behind.
    func testAVorbisFileBecomesAnM4AFileBesideIt() async throws {
        try OggTestFixtures.skipUnlessOggDecodes()
        let source = try OggTestFixtures.copy(OggTestFixtures.vorbis, to: folder, as: "Elegy.ogg")
        let sourceBytes = try Data(contentsOf: source)

        let conversion = try await ImportAudioConverter.convert(source)

        XCTAssertEqual(conversion.converted.lastPathComponent, "Elegy.m4a")
        XCTAssertEqual(OggTestFixtures.names(in: folder), ["Elegy.m4a", "Elegy.ogg"])
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        XCTAssertEqual(conversion.duration, 2, accuracy: 0.05)
        XCTAssertEqual(conversion.bytesBefore, Int64(sourceBytes.count))
        XCTAssertEqual(conversion.bytesAfter, ImportAudioConverter.fileSize(of: conversion.converted))
        XCTAssertGreaterThan(conversion.bytesAfter, 0)
        XCTAssertEqual(conversion.bitRate, 32_000, "22 kbit/s mono Vorbis rounds up to 32 kbit/s")
        let formatID = await OggTestFixtures.formatID(of: conversion.converted)
        XCTAssertEqual(formatID, kAudioFormatMPEG4AAC)
        guard case let .success(seconds) = await AudioMediaProbe.duration(of: conversion.converted) else {
            return XCTFail("The converted file must play")
        }
        XCTAssertEqual(seconds, 2, accuracy: ImportAudioConverter.lengthTolerance)
    }

    /// An Opus file converts the same way, at its own 48 kHz.
    func testAnOpusFileConvertsToo() async throws {
        try OggTestFixtures.skipUnlessOggDecodes()
        let source = try OggTestFixtures.copy(OggTestFixtures.opus, to: folder, as: "two.opus")

        let conversion = try await ImportAudioConverter.convert(source)

        XCTAssertEqual(conversion.converted.lastPathComponent, "two.m4a")
        let formatID = await OggTestFixtures.formatID(of: conversion.converted)
        XCTAssertEqual(formatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(conversion.duration, 2, accuracy: 0.05)
    }

    /// A name already taken is never replaced: the converted file takes
    /// the first free "<stem> N.m4a".
    func testATakenNameIsMadeUnique() async throws {
        try OggTestFixtures.skipUnlessOggDecodes()
        let source = try OggTestFixtures.copy(OggTestFixtures.vorbis, to: folder, as: "elegy.ogg")
        let taken = folder.appendingPathComponent("elegy.m4a")
        try Data("not mine".utf8).write(to: taken)

        let conversion = try await ImportAudioConverter.convert(source)

        XCTAssertEqual(conversion.converted.lastPathComponent, "elegy 2.m4a")
        XCTAssertEqual(try Data(contentsOf: taken), Data("not mine".utf8))
    }

    /// Without naming, the converted file keeps its hidden temporary name,
    /// which the reader never lists; one left behind is removed.
    func testAnUnnamedConversionStaysHiddenUntilNamed() async throws {
        try OggTestFixtures.skipUnlessOggDecodes()
        let source = try OggTestFixtures.copy(OggTestFixtures.vorbis, to: folder, as: "elegy.ogg")

        let staged = try await ImportAudioConverter.convert(source, naming: false)

        XCTAssertTrue(staged.converted.lastPathComponent.hasPrefix("."))
        XCTAssertTrue(staged.converted.lastPathComponent.hasSuffix(ImportAudioConverter.temporarySuffix))
        XCTAssertEqual(try AudioBookParser.audioFiles(in: folder).map(\.lastPathComponent), ["elegy.ogg"])
        let named = try ImportAudioConverter.givingFinalName(staged)
        XCTAssertEqual(named.converted.lastPathComponent, "elegy.m4a")

        let leftover = try await ImportAudioConverter.convert(source, naming: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: leftover.converted.path))
        ImportAudioConverter.removeLeftovers(in: folder)
        XCTAssertEqual(OggTestFixtures.names(in: folder), ["elegy.m4a", "elegy.ogg"])
    }

    /// A file named like Ogg that holds no audio fails, saying which file,
    /// and leaves nothing behind.
    func testAFileThatIsNotAudioFailsAndLeavesNothing() async throws {
        let broken = folder.appendingPathComponent("broken.ogg")
        try Data("this is not Ogg audio".utf8).write(to: broken)

        do {
            _ = try await ImportAudioConverter.convert(broken)
            XCTFail("A file that isn't audio must not convert")
        } catch let failure as ImportAudioConverter.Failure {
            XCTAssertEqual(failure, .unreadable(fileName: "broken.ogg"))
            XCTAssertEqual(failure.errorDescription, "The Ogg audio file broken.ogg could not be read for converting to AAC.")
        }
        XCTAssertEqual(OggTestFixtures.names(in: folder), ["broken.ogg"])
    }

    // MARK: - Several Files

    /// Several files convert together, at most four at once, returned in
    /// the order given, with the count done told as each ends.
    func testSeveralFilesConvertInTheirOrderCountingEachDone() async throws {
        try OggTestFixtures.skipUnlessOggDecodes()
        let sources = [
            try OggTestFixtures.copy(OggTestFixtures.vorbis, to: folder, as: "01.ogg"),
            try OggTestFixtures.copy(OggTestFixtures.opus, to: folder, as: "02.opus"),
            try OggTestFixtures.copy(OggTestFixtures.vorbis, to: folder, as: "03.oga"),
        ]
        let counts = OSAllocatedUnfairLock(initialState: [Int]())

        let conversions = try await ImportAudioConverter.convertEach(sources) { done in
            counts.withLock { $0.append(done) }
        }

        XCTAssertEqual(conversions.map(\.source), sources)
        XCTAssertEqual(conversions.map(\.converted.lastPathComponent), ["01.m4a", "02.m4a", "03.m4a"])
        XCTAssertEqual(counts.withLock { $0 }, [1, 2, 3])
        XCTAssertEqual(ImportAudioConverter.maximumConcurrentConversions, 4)
    }

    /// One file that fails stops the rest, and every file already converted
    /// is removed, so the folder is as it was.
    func testOneFailureRemovesEveryConversion() async throws {
        try OggTestFixtures.skipUnlessOggDecodes()
        let good = try OggTestFixtures.copy(OggTestFixtures.vorbis, to: folder, as: "01.ogg")
        let broken = folder.appendingPathComponent("02.ogg")
        try Data("not audio".utf8).write(to: broken)

        do {
            _ = try await ImportAudioConverter.convertEach([good, broken])
            XCTFail("A batch with a broken file must fail")
        } catch {
            XCTAssertEqual(error as? ImportAudioConverter.Failure, .unreadable(fileName: "02.ogg"))
        }
        XCTAssertEqual(OggTestFixtures.names(in: folder), ["01.ogg", "02.ogg"])
    }
}
