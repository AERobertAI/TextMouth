import XCTest
@testable import TextMouth

/// Every sample of a format only FFmpeg reads, imported through the import's
/// own path with the FFmpeg session the app carries (FMT31, FMT32, FMT50): each
/// becomes an .m4a book of the codec its source calls for, with its chapters
/// and tags. FFmpeg comes with the app, so these run everywhere, GitHub's
/// runners included: on the Mac through its helper, and on the iPhone through
/// the same session in the app (FMT54), where every sample must make the same
/// book, of the same codec, channels, length, chapters, title, and author.
/// `FFmpegImportConversionTests` checks the refusals and the broken runs with
/// stand-ins in front of the same session. Shared with the iPhone's unit
/// bundle.
final class FFmpegImportRealTests: XCTestCase {
    /// The folders of `TestData/format-samples` that hold the formats only
    /// FFmpeg reads.
    private let sampleFolders = ["avi", "flv", "mka", "mkv", "rm", "spx", "webm", "wma", "wmv"]

    /// What one sample must import as.
    private struct Expected {
        /// The sample, in TestData/format-samples.
        let sample: String
        /// The name the copy imported has, when not the sample's own.
        var name: String?
        /// The codec of the book's file, as afinfo names it: "aac" or "alac".
        let codec: String
        /// Its channels.
        var channels = 1
        /// The chapters' titles; one chapter, named by the converted file's
        /// title tag or else by its name, when the source has none.
        let chapters: [String]
        /// The book's title and author, from the source's tags or its name.
        let title: String
        let author: String
    }

    /// The three chapters of the samples made from three-tones.flac.
    private let threeTones = ["Tone 440 Hz", "Tone 660 Hz - second", "Tone 880 Hz (café)"]

    /// The title of mka/tones-long-title.mka ("Long" and 3,000 "é", 6,004
    /// bytes) as the helper hands it over: its first 4,096 bytes, "Long" and
    /// 2,046 "é".
    private let longTitleCut = "Long" + String(repeating: "é", count: 2_046)

    /// Every sample, and what it imports as: WMA 1 and 2, with markers and
    /// without, a WMV, an AVI with MP3, a Flash video with AAC (encoded again
    /// as AAC), a Matroska video with FLAC (Apple Lossless), Matroska with 5.1
    /// AC-3 (mixed to stereo) and with AAC (encoded again as AAC), two Opus
    /// tracks (the default taken), WebM with Opus and
    /// with Vorbis, Speex in Ogg under its own name and under .ogg, and
    /// RealAudio, whose file says no length.
    private var expectations: [Expected] {
        [
            Expected(sample: "wma/tones.wma", codec: "aac", chapters: ["Tones"], title: "Tones", author: "TextMouth tests"),
            Expected(sample: "wma/tones-wma1.wma", codec: "aac", chapters: threeTones, title: "Three Tones", author: "TextMouth Test"),
            Expected(sample: "wma/three-tones-chapters.wma", codec: "aac", chapters: threeTones, title: "Three Tones", author: "TextMouth Test"),
            Expected(sample: "wmv/tones.wmv", codec: "aac", chapters: threeTones, title: "Three Tones", author: "TextMouth Test"),
            Expected(sample: "avi/tones-mp3.avi", codec: "aac", chapters: ["Three Tones"], title: "Three Tones", author: "TextMouth Test"),
            Expected(sample: "flv/tones-aac.flv", codec: "aac", chapters: ["Three Tones"], title: "Three Tones", author: "TextMouth Test"),
            Expected(sample: "mkv/three-tones-flac.mkv", codec: "alac", chapters: threeTones, title: "Three Tones", author: "TextMouth Test"),
            Expected(sample: "mka/tones-5.1-ac3.mka", codec: "aac", channels: 2, chapters: threeTones, title: "Three Tones", author: "TextMouth Test"),
            // AAC in Matroska (FMT54): decoded and written again as AAC, as every lossy source is.
            Expected(sample: "mka/tones-aac.mka", codec: "aac", chapters: threeTones, title: "Three Tones", author: "TextMouth Test"),
            Expected(sample: "mka/tones-2tracks.mka", codec: "aac", chapters: ["First chapter", "Second chapter"],
                     title: "Tones in Matroska", author: "TextMouth tests"),
            // A title of 6,004 bytes, cut at 4 KB, between two characters (the TODO's FU-FFMPEG item).
            Expected(sample: "mka/tones-long-title.mka", codec: "alac", chapters: [longTitleCut], title: longTitleCut, author: "TextMouth Test"),
            // MP3 whose rate and channels change partway (FU-FFMPEG2): converted whole, in the first form.
            Expected(sample: "mka/mp3-form-changes.mka", codec: "aac", chapters: ["mp3-form-changes"], title: "mp3-form-changes",
                     author: Book.unknownAuthor),
            Expected(sample: "webm/tones-opus.webm", codec: "aac", chapters: ["tones-opus"], title: "tones-opus", author: Book.unknownAuthor),
            Expected(sample: "webm/tones-vorbis.weba", codec: "aac", chapters: ["tones-vorbis"], title: "tones-vorbis", author: Book.unknownAuthor),
            Expected(sample: "spx/tones.spx", codec: "aac", chapters: ["tones"], title: "tones", author: Book.unknownAuthor),
            Expected(sample: "spx/tones.spx", name: "Speech.ogg", codec: "aac", chapters: ["Speech"], title: "Speech", author: Book.unknownAuthor),
            Expected(sample: "rm/tones.ra", codec: "aac", chapters: ["Three Tones"], title: "Three Tones", author: Book.unknownAuthor),
        ]
    }

    /// Every sample of these formats in TestData/format-samples has its
    /// expectation here, so a sample added later is imported too.
    func testEverySampleOfTheseFormatsIsExpected() throws {
        let root = try formatSampleURL("wma").deletingLastPathComponent()
        var samples: [String] = []
        for folder in sampleFolders {
            let names = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(folder).path)
            samples += names.filter { !$0.hasPrefix(".") }.map { "\(folder)/\($0)" }
        }
        XCTAssertEqual(Set(samples), Set(expectations.map(\.sample)))
    }

    /// Each sample imports as an .m4a book of the codec its source calls for,
    /// with the source's chapters, title, and author; every mismatch is
    /// reported, sample by sample. The codec and channels are read from the
    /// .m4a's own sample entry (`M4ASampleEntry`), on both platforms; on the
    /// Mac, afinfo must agree with that reading, so the reader the iPhone
    /// relies on is checked against Apple's own tool.
    func testEverySampleImportsWithItsChaptersAndTags() throws {
        let tool = try bundledFFmpegTool()
        var mismatches: [String] = []
        for expected in expectations {
            let copy = try copyOfFormatSample(expected.sample, named: expected.name)
            let imported = try FFmpegAudioConverter.$tool.withValue(tool) { try FileImportService.importFileWithReport(from: copy) }
            addTeardownBlock { try? FileManager.default.removeItem(at: imported.book.tmbDirectory) }
            let file = URL(fileURLWithPath: imported.book.filePath)
            let entry = try M4ASampleEntry.read(file)
            #if os(macOS)
            // afinfo, a program the iPhone has not, reads the same codec and channels.
            let info = try AsyncBridge.waitForResult { try await AudioFileInfo.read(file) }
            let afinfo = [info?.formatID.trimmingCharacters(in: .whitespaces) ?? "unreadable", String(info?.channels ?? 0)]
            if afinfo != [entry?.codec ?? "unreadable", String(entry?.channels ?? 0)] {
                mismatches.append("\(expected.name ?? expected.sample): afinfo reads \(afinfo), the sample entry \(String(describing: entry))")
            }
            #endif
            let chapters = try BookContentAnalysisService.load(book: imported.book).content.chapters.map(\.title)
            let found = [
                file.pathExtension, entry?.codec ?? "unreadable",
                String(entry?.channels ?? 0), chapters.joined(separator: " | "), imported.book.title, imported.book.author,
            ]
            let wanted = [
                "m4a", expected.codec, String(expected.channels), expected.chapters.joined(separator: " | "),
                expected.title, expected.author,
            ]
            if found != wanted {
                mismatches.append("\(expected.name ?? expected.sample): \(found), not \(wanted)")
            }
        }
        XCTAssertEqual(mismatches, [])
    }

    /// The converted file lasts as long as its sound: within the import's
    /// own tolerance of four seconds for every sample made from three-tones,
    /// the RealAudio file among them, whose file says no length.
    func testTheConvertedFilesLastAsLongAsTheirSound() async throws {
        let tool = try bundledFFmpegTool()
        var mismatches: [String] = []
        for sample in ["wma/tones-wma1.wma", "wmv/tones.wmv", "avi/tones-mp3.avi", "flv/tones-aac.flv",
                       "mkv/three-tones-flac.mkv", "mka/tones-5.1-ac3.mka", "mka/tones-aac.mka", "rm/tones.ra"] {
            let copy = try copyOfFormatSample(sample)
            let conversion = try await FFmpegAudioConverter.convert(copy, using: tool)
            switch await AudioMediaProbe.duration(of: conversion.converted) {
            case let .success(seconds) where abs(seconds - 4) <= ImportAudioConverter.allowedLengthError(for: 4):
                break
            case let outcome:
                mismatches.append("\(sample): \(outcome)")
            }
        }
        XCTAssertEqual(mismatches, [])
    }

    /// A file only FFmpeg reads is measured by the FFmpeg session the app
    /// carries, which afinfo could not do, so a cue sheet over a WMA or
    /// Matroska file is checked against its length rather than taken to fit
    /// (the TODO's FU-FFMPEG item); a RealAudio file that says no length is
    /// left unmeasured, for the parse to check after its conversion. Here,
    /// among the tests the iPhone shares (it was CueSheetImportTests'), since
    /// the iPhone measures such a file in the app itself (FMT54).
    func testAFileOnlyFFmpegReadsIsMeasuredForACueSheet() throws {
        let folder = try makeSandboxDirectory("cue-measure-ffmpeg")
        let samples = ["wma/tones-wma1.wma": "tones-wma1.wma", "mkv/three-tones-flac.mkv": "three-tones-flac.mkv", "rm/tones.ra": "tones.ra"]
        for (sample, name) in samples {
            try FileManager.default.copyItem(at: try formatSampleURL(sample), to: folder.appendingPathComponent(name))
        }

        let lengths = FFmpegAudioConverter.$tool.withValue(try bundledFFmpegTool()) {
            FileImportService.measuredLengths(of: samples.values.sorted().map {
                M3UPlaylist.Track(url: folder.appendingPathComponent($0), path: $0, title: nil)
            })
        }

        XCTAssertEqual(Set(lengths.keys), ["tones-wma1.wma", "three-tones-flac.mkv"])
        XCTAssertEqual(lengths["tones-wma1.wma"] ?? 0, 3.999, accuracy: 0.01)
        XCTAssertEqual(lengths["three-tones-flac.mkv"] ?? 0, 4, accuracy: 0.1)
    }

    /// Sound that changes its rate and channels partway is imported whole,
    /// at the first stretch's rate and channels (FU-FFMPEG2): the sample is
    /// 22,050 Hz mono, then 44,100 Hz stereo, then 22,050 Hz mono, 3.2 s in
    /// all, which the import once refused for the change. Its book is a 22,050
    /// Hz mono .m4a of the whole length.
    func testSoundThatChangesItsFormIsImportedWholeAtTheFirstForm() async throws {
        let tool = try bundledFFmpegTool()
        let copy = try copyOfFormatSample("mka/mp3-form-changes.mka")
        let conversion = try await FFmpegAudioConverter.convert(copy, using: tool)
        let entry = try XCTUnwrap(try M4ASampleEntry.read(conversion.converted))
        XCTAssertEqual(entry.channels, 1)
        XCTAssertEqual(entry.sampleRate, 22_050)
        // 70,272 frames at 22,050 Hz exactly (3.187 s); the .m4a keeps them to a few hundredths.
        guard case let .success(seconds) = await AudioMediaProbe.duration(of: conversion.converted) else {
            return XCTFail("the converted file does not play")
        }
        XCTAssertEqual(seconds, 70_272.0 / 22_050, accuracy: 0.02)
    }

    /// The helper reads the samples as the import plans them: the two-track
    /// file's default stream is its first (Narration, in English), a video
    /// file's sound is its second stream, Flash video's AAC is encoded again
    /// as AAC, Matroska's FLAC is lossless of 16 bits, Speex keeps its 8 kHz,
    /// the 5.1 AC-3 names its loudspeakers, and the RealAudio file says no
    /// length.
    func testTheHelperReadsTheSamplesAsPlanned() async throws {
        let tool = try bundledFFmpegTool()
        /// The helper's report of the sample `sample`, read as its container.
        func report(_ sample: String) async throws -> FFmpegReport {
            let url = try formatSampleURL(sample)
            let container = try XCTUnwrap(FFmpegContainer.of(fileAt: url), sample)
            return try await FFmpegAudioConverter.probe(url, as: container, kind: "the sample", using: tool)
        }
        let twoTracks = try await report("mka/tones-2tracks.mka")
        XCTAssertEqual(twoTracks.streamIndex, 0)
        XCTAssertEqual(twoTracks.streamTags["language"], "eng")
        let avi = try await report("avi/tones-mp3.avi")
        XCTAssertEqual(avi.streamIndex, 1)
        XCTAssertTrue(avi.holdsMoreThanSound)
        let flvReport = try await report("flv/tones-aac.flv")
        XCTAssertEqual(flvReport.codecName, "aac")
        XCTAssertNil(try FFmpegAudioConverter.plan(for: flvReport, fileName: "tones-aac.flv").target.appleLosslessBitDepth)
        let mkvReport = try await report("mkv/three-tones-flac.mkv")
        XCTAssertEqual(try FFmpegAudioConverter.plan(for: mkvReport, fileName: "three-tones-flac.mkv").target.appleLosslessBitDepth, 16)
        let speex = try await report("spx/tones.spx")
        XCTAssertEqual(speex.sampleRate, 8_000)
        XCTAssertEqual(speex.codecName, "speex")
        let surround = try await report("mka/tones-5.1-ac3.mka")
        XCTAssertEqual(surround.channels, 6)
        XCTAssertEqual(surround.channelMask, 0x60F)
        let realAudio = try await report("rm/tones.ra")
        XCTAssertNil(realAudio.duration)
        // Matroska holding AAC, FLAC, or AC-3 (FMT54), each as the Mac plans it, on both platforms: AAC is
        // written again as AAC, mono as it came; FLAC becomes Apple Lossless at its 16 bits; 5.1 AC-3 becomes AAC,
        // mixed to stereo.
        let matroskaAAC = try await report("mka/tones-aac.mka")
        XCTAssertEqual(matroskaAAC.codecName, "aac")
        let aacTarget = try FFmpegAudioConverter.plan(for: matroskaAAC, fileName: "tones-aac.mka").target
        XCTAssertEqual([aacTarget.appleLosslessBitDepth == nil ? "aac" : "alac", String(aacTarget.channels)], ["aac", "1"])
        let flacTarget = try FFmpegAudioConverter.plan(for: mkvReport, fileName: "three-tones-flac.mkv").target
        XCTAssertEqual([flacTarget.appleLosslessBitDepth.map(String.init) ?? "aac", String(flacTarget.channels)], ["16", "1"])
        let ac3Target = try FFmpegAudioConverter.plan(for: surround, fileName: "tones-5.1-ac3.mka").target
        XCTAssertEqual([ac3Target.appleLosslessBitDepth == nil ? "aac" : "alac", String(ac3Target.channels)], ["aac", "2"])
    }
}
