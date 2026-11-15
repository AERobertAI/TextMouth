import AVFoundation
import XCTest
@testable import TextMouth

/// Chapters written into a converted .m4a's chapter track (FMT17,
/// `ChapterTrackWriter`): AAC and Apple Lossless files made here gain the
/// chapters AVFoundation reads back, their samples copied as stored; a file
/// of a kind the writer never opens is left alone. And a CAF with markers,
/// imported, keeps them as its book's chapters through afinfo, the
/// conversion, and the writer. Nothing is played; no Ogg is decoded.
@MainActor
final class ChapterTrackWriterTests: XCTestCase {
    /// An AAC .m4a and an Apple Lossless one gain the chapters given, in
    /// order, each lasting until the next, read back by AVFoundation; the
    /// audio keeps its format and its length.
    func testAnM4AGainsTheChaptersAndKeepsItsAudio() async throws {
        let folder = try makeSandboxDirectory("chapter-track")
        for (name, codec) in [("aac.m4a", kAudioFormatMPEG4AAC), ("alac.m4a", kAudioFormatAppleLossless)] {
            let file = folder.appendingPathComponent(name)
            try writeSilence(to: file, codec: codec, duration: 3)
            let before = try await facts(of: file)

            try await ChapterTrackWriter.write(
                [.init(title: "Second", start: 1.5), .init(title: "First", start: 0)], into: file, lasting: before.duration
            )

            let chapters = await AudioPlaybackService.extractChapters(from: file)
            XCTAssertEqual(chapters.map(\.title), ["First", "Second"], name)
            XCTAssertEqual(chapters.map(\.startTime), [0, 1.5], name)
            let after = try await facts(of: file)
            XCTAssertEqual(after.codec, codec, "\(name): the samples are copied as stored")
            XCTAssertEqual(after.duration, before.duration, accuracy: 0.05, name)
        }
    }

    /// A list that makes no chapter changes nothing, and a file of a kind the
    /// writer never opens is refused and left as it was, with nothing left
    /// beside it.
    func testNothingIsWrittenForNoChaptersOrAFileNeverOpened() async throws {
        let folder = try makeSandboxDirectory("chapter-track-refused")
        let file = folder.appendingPathComponent("plain.m4a")
        try writeSilence(to: file, codec: kAudioFormatMPEG4AAC, duration: 1)
        let bytes = try Data(contentsOf: file)
        try await ChapterTrackWriter.write([], into: file, lasting: 1)
        XCTAssertEqual(try Data(contentsOf: file), bytes)

        let ogg = folder.appendingPathComponent("radio.ogg")
        try Data("OggS not really".utf8).write(to: ogg)
        do {
            try await ChapterTrackWriter.write([.init(title: "A", start: 0)], into: ogg, lasting: 1)
            XCTFail("an Ogg file was opened")
        } catch {
            XCTAssertEqual(error as? AudioEditError, .unreadableAudio)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), ["plain.m4a", "radio.ogg"])
    }

    /// A CAF file with two markers, imported on its own, is converted to an
    /// .m4a that keeps them as its chapters: afinfo lists them, the
    /// conversion carries them, and the book has a heading for each.
    func testAnImportedCAFKeepsItsMarkersAsChapters() async throws {
        let world = try makeIntegrationWorld("Chapters From Markers")
        let source = try makeSandboxDirectory("chapter-track-caf").appendingPathComponent("Harbour Talk.caf")
        try AudioTestFixtures.writeSilence(to: source, duration: 3)
        try AudioMarkerList.write([("Arrival", 0), ("Departure", 1.5)], to: source)

        let book = try world.importBook(from: source)

        XCTAssertEqual(book.bookFileURL.pathExtension, "m4a", "the CAF was converted")
        let chapters = await AudioPlaybackService.extractChapters(from: book.bookFileURL)
        XCTAssertEqual(chapters.map(\.title), ["Arrival", "Departure"])
        XCTAssertEqual(try BookContentAnalysisService.load(book: book).content.chapters.map(\.title), ["Arrival", "Departure"])
    }

    // MARK: - Helpers

    /// Writes `duration` seconds of mono silence at 22,050 Hz to `file` as an
    /// .m4a of `codec`: AAC, or Apple Lossless of 16-bit samples.
    private func writeSilence(to file: URL, codec: AudioFormatID, duration: TimeInterval) throws {
        var settings: [String: Any] = [AVFormatIDKey: codec, AVSampleRateKey: 22_050.0, AVNumberOfChannelsKey: 1]
        if codec == kAudioFormatAppleLossless {
            settings[AVEncoderBitDepthHintKey] = 16
        }
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 22_050, channels: 1, interleaved: false))
        let frames = AVAudioFrameCount(duration * 22_050)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        // Silence: the one channel's samples, all zero.
        try XCTUnwrap(buffer.floatChannelData).pointee.update(repeating: 0, count: Int(frames))
        let audio = try AVAudioFile(forWriting: file, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try audio.write(from: buffer)
    }

    /// The codec of the audio track of the .m4a at `file`, and how long it
    /// lasts.
    private func facts(of file: URL) async throws -> (codec: AudioFormatID, duration: TimeInterval) {
        let asset = AVURLAsset(url: file)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let descriptions = try await XCTUnwrap(tracks.first).load(.formatDescriptions)
        let codec = try XCTUnwrap(descriptions.first?.audioStreamBasicDescription).mFormatID
        return (codec, CMTimeGetSeconds(try await asset.load(.duration)))
    }
}
