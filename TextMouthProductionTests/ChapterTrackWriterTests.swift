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
    /// An AAC .m4a and an Apple Lossless one, copied with the chapters given,
    /// gain them in order, each lasting until the next, read back by
    /// AVFoundation; the audio keeps its format and its length, and the file
    /// copied from is as it was.
    func testAnM4AGainsTheChaptersAndKeepsItsAudio() async throws {
        let folder = try makeSandboxDirectory("chapter-track")
        for (name, codec) in [("aac.m4a", kAudioFormatMPEG4AAC), ("alac.m4a", kAudioFormatAppleLossless)] {
            let file = folder.appendingPathComponent(name)
            let copy = folder.appendingPathComponent("chaptered-\(name)")
            try writeSilence(to: file, codec: codec, duration: 3)
            let bytes = try Data(contentsOf: file)
            let before = try await facts(of: file)

            let wrote = try await ChapterTrackWriter.write(
                [.init(title: "Second", start: 1.5), .init(title: "First", start: 0)], from: file, to: copy, lasting: before.duration, titled: "Harbour"
            )

            XCTAssertTrue(wrote, name)
            let chapters = await AudioPlaybackService.extractChapters(from: copy)
            XCTAssertEqual(chapters.map(\.title), ["First", "Second"], name)
            XCTAssertEqual(chapters.map(\.startTime), [0, 1.5], name)
            let after = try await facts(of: copy)
            XCTAssertEqual(after.codec, codec, "\(name): the samples are copied as stored")
            XCTAssertEqual(after.duration, before.duration, accuracy: 0.05, name)
            XCTAssertEqual(try Data(contentsOf: file), bytes, "\(name): the file copied from is unchanged")
        }
    }

    /// A list that makes no chapter writes nothing, and a file of a kind the
    /// writer never opens is refused, with nothing written.
    func testNothingIsWrittenForNoChaptersOrAFileNeverOpened() async throws {
        let folder = try makeSandboxDirectory("chapter-track-refused")
        let file = folder.appendingPathComponent("plain.m4a")
        try writeSilence(to: file, codec: kAudioFormatMPEG4AAC, duration: 1)
        let unused = folder.appendingPathComponent("unused.m4a")
        let wrote = try await ChapterTrackWriter.write([], from: file, to: unused, lasting: 1, titled: "Plain")
        XCTAssertFalse(wrote)
        let pastTheEnd = try await ChapterTrackWriter.write(
            [.init(title: "Late", start: 5)], from: file, to: unused, lasting: 1, titled: "Plain"
        )
        XCTAssertFalse(pastTheEnd, "a chapter past the file's end makes no chapter")

        let ogg = folder.appendingPathComponent("radio.ogg")
        try Data("OggS not really".utf8).write(to: ogg)
        do {
            try await ChapterTrackWriter.write([.init(title: "A", start: 0)], from: ogg, to: unused, lasting: 1, titled: "Radio")
            XCTFail("an Ogg file was opened")
        } catch {
            XCTAssertEqual(error as? AudioEditError, .unreadableAudio)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), ["plain.m4a", "radio.ogg"])
    }

    /// The places given make a book's chapters as a file's markers do
    /// (`FileChapterReaders.placedChapters`): one chapter alone writes
    /// nothing, so the book keeps its title, as it did before; a place a
    /// second and a half in begins a chapter there, after one titled as the
    /// book will be, here by the name given, as the file has no title tag.
    func testOnePlaceWritesNothingAndALaterOneFollowsTheBooksTitle() async throws {
        let folder = try makeSandboxDirectory("chapter-track-places")
        let file = folder.appendingPathComponent("plain.m4a")
        try writeSilence(to: file, codec: kAudioFormatMPEG4AAC, duration: 3)
        let alone = folder.appendingPathComponent("alone.m4a")
        let later = folder.appendingPathComponent("later.m4a")

        let wroteAlone = try await ChapterTrackWriter.write(
            [.init(title: "Only", start: 0)], from: file, to: alone, lasting: 3, titled: "Harbour Talk"
        )
        let wroteLater = try await ChapterTrackWriter.write(
            [.init(title: "Departure", start: 1.5)], from: file, to: later, lasting: 3, titled: "Harbour Talk"
        )

        XCTAssertFalse(wroteAlone)
        XCTAssertFalse(FileManager.default.fileExists(atPath: alone.path))
        XCTAssertTrue(wroteLater)
        let chapters = await AudioPlaybackService.extractChapters(from: later)
        XCTAssertEqual(chapters.map(\.title), ["Harbour Talk", "Departure"])
        XCTAssertEqual(chapters.map(\.startTime), [0, 1.5])
    }

    /// An import cancelled while its converted file gains its chapters
    /// stops there, as its conversion would: `keepChapters` throws
    /// `CancellationError` rather than carrying on without the chapters, the
    /// file is as it was, and no hidden copy is left beside it.
    func testACancelledImportStopsWhileKeepingChapters() async throws {
        let folder = try makeSandboxDirectory("chapter-track-cancelled")
        let file = folder.appendingPathComponent("plain.m4a")
        try writeSilence(to: file, codec: kAudioFormatMPEG4AAC, duration: 1)
        let bytes = try Data(contentsOf: file)

        // The task runs on the main actor, so it starts only once this test
        // awaits it: it is already cancelled when it begins.
        let task = Task {
            try await ImportAudioConverter.keepChapters(
                [.init(title: "A", start: 0), .init(title: "B", start: 0.5)], in: file, lasting: 1, from: "plain.m4a"
            )
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("the cancelled task carried on")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }

        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["plain.m4a"])
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
