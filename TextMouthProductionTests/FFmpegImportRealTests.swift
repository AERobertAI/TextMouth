import XCTest
@testable import TextMouth

/// Every sample of a format only ffmpeg reads, imported through the import's
/// own path with the ffmpeg and ffprobe installed on this Mac (FMT31,
/// FMT32): each becomes an .m4a book of the codec its source calls for, with
/// its chapters and tags. GitHub's runners have no ffmpeg, so there each test
/// skips with the reason; the orchestrator's Mac suite runs them.
/// `FFmpegImportConversionTests` checks the same logic with a stand-in.
final class FFmpegImportRealTests: XCTestCase {
    /// Skips the test when this Mac has no ffmpeg with an ffprobe beside it.
    private func requireInstalledFFmpeg() throws {
        guard case .found = FFmpegAudioConverter.locateInstalled() else {
            throw XCTSkip("ffmpeg and ffprobe are not installed on this Mac, so the import of these formats cannot run")
        }
    }

    /// What one sample must import as.
    private struct Expected {
        /// The sample, in TestData/format-samples.
        let sample: String
        /// The name the copy imported has, when not the sample's own.
        var name: String?
        /// afinfo's codec of the book's file: "aac" or "alac".
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

    /// Every sample, and what it imports as: WMA 1 and 2, with markers and
    /// without, a WMV, an AVI with MP3, a Flash video with AAC (copied), a
    /// Matroska video with FLAC (Apple Lossless), 5.1 AC-3 (mixed to stereo),
    /// two Opus tracks (the default taken), WebM with Opus and with Vorbis,
    /// Speex in Ogg under its own name and under .ogg, and RealAudio, whose
    /// file says no length.
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
            Expected(sample: "mka/tones-2tracks.mka", codec: "aac", chapters: ["First chapter", "Second chapter"],
                     title: "Tones in Matroska", author: "TextMouth tests"),
            Expected(sample: "webm/tones-opus.webm", codec: "aac", chapters: ["tones-opus"], title: "tones-opus", author: Book.unknownAuthor),
            Expected(sample: "webm/tones-vorbis.weba", codec: "aac", chapters: ["tones-vorbis"], title: "tones-vorbis", author: Book.unknownAuthor),
            Expected(sample: "spx/tones.spx", codec: "aac", chapters: ["tones"], title: "tones", author: Book.unknownAuthor),
            Expected(sample: "spx/tones.spx", name: "Speech.ogg", codec: "aac", chapters: ["Speech"], title: "Speech", author: Book.unknownAuthor),
            Expected(sample: "rm/tones.ra", codec: "aac", chapters: ["Three Tones"], title: "Three Tones", author: Book.unknownAuthor),
        ]
    }

    /// Each sample imports as an .m4a book of the codec its source calls for,
    /// with the source's chapters, title, and author; every mismatch is
    /// reported, sample by sample.
    func testEverySampleImportsWithItsChaptersAndTags() throws {
        try requireInstalledFFmpeg()
        var mismatches: [String] = []
        for expected in expectations {
            let copy = try copyOfFormatSample(expected.sample, named: expected.name)
            let imported = try FileImportService.importFileWithReport(from: copy)
            addTeardownBlock { try? FileManager.default.removeItem(at: imported.book.tmbDirectory) }
            let file = URL(fileURLWithPath: imported.book.filePath)
            let info = try AsyncBridge.waitForResult { try await AudioFileInfo.read(file) }
            let chapters = try BookContentAnalysisService.load(book: imported.book).content.chapters.map(\.title)
            let found = [
                file.pathExtension, info?.formatID.trimmingCharacters(in: .whitespaces) ?? "unreadable",
                String(info?.channels ?? 0), chapters.joined(separator: " | "), imported.book.title, imported.book.author,
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
        try requireInstalledFFmpeg()
        var mismatches: [String] = []
        for sample in ["wma/tones-wma1.wma", "wmv/tones.wmv", "avi/tones-mp3.avi", "flv/tones-aac.flv",
                       "mkv/three-tones-flac.mkv", "mka/tones-5.1-ac3.mka", "rm/tones.ra"] {
            let copy = try copyOfFormatSample(sample)
            let conversion = try await FFmpegAudioConverter.convert(copy, using: .installed)
            switch await AudioMediaProbe.duration(of: conversion.converted) {
            case let .success(seconds) where abs(seconds - 4) <= ImportAudioConverter.allowedLengthError(for: 4):
                break
            case let outcome:
                mismatches.append("\(sample): \(outcome)")
            }
        }
        XCTAssertEqual(mismatches, [])
    }

    /// The ffprobe installed reads the samples as the plan expects: the
    /// two-track file's default stream is its first (Narration, in English),
    /// a video file's sound is its second stream, Flash video's AAC is
    /// copied, Matroska's FLAC is lossless, Speex keeps its 8 kHz, and the
    /// RealAudio file says no length.
    func testTheInstalledFFprobeReadsTheSamplesAsPlanned() async throws {
        try requireInstalledFFmpeg()
        guard case let .found(programs) = FFmpegAudioConverter.locateInstalled() else { return }
        /// The plan for the sample `sample`, read as its container.
        func plan(_ sample: String) async throws -> FFmpegAudioConverter.Plan {
            let url = try formatSampleURL(sample)
            let container = try XCTUnwrap(FFmpegContainer.of(fileAt: url), sample)
            let read = try await FFmpegAudioConverter.report(of: url, as: container, using: programs.ffprobe)
            let report = try XCTUnwrap(read, "ffprobe read nothing of \(sample)")
            return try FFmpegAudioConverter.plan(for: report, container: container, fileName: url.lastPathComponent, aacEncoder: "aac_at")
        }
        let twoTracks = try await plan("mka/tones-2tracks.mka")
        XCTAssertEqual(twoTracks.streamIndex, 0)
        let avi = try await plan("avi/tones-mp3.avi")
        XCTAssertEqual(avi.streamIndex, 1)
        let flv = try await plan("flv/tones-aac.flv")
        XCTAssertEqual(flv.encoding, .copy)
        let mkv = try await plan("mkv/three-tones-flac.mkv")
        XCTAssertEqual(mkv.encoding, .appleLossless)
        XCTAssertEqual(mkv.target.appleLosslessBitDepth, 16)
        let speex = try await plan("spx/tones.spx")
        XCTAssertEqual(speex.container, .oggSpeex)
        XCTAssertEqual(speex.sourceSampleRate, 8_000)
        let realAudio = try await plan("rm/tones.ra")
        XCTAssertNil(realAudio.duration)
        let listsAppleEncoder = try await FFmpegAudioConverter.hasAppleAACEncoder(programs.ffmpeg)
        XCTAssertTrue(listsAppleEncoder, "Homebrew's ffmpeg lists aac_at")
    }
}
