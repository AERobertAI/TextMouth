import AVFoundation
import XCTest
@testable import TextMouth

/// A file's markers as Core Audio keeps them (FMT17, FMT11,
/// `AudioMarkerList`): the Broadcast Wave sample's two cue points read as
/// chapters, markers written into WAVE, AIFF, and CAF files made here and
/// read back, and afinfo's list of the same markers (`AudioFileInfo.markers`),
/// which the import keeps for a format it converts. Nothing is played, and no
/// file of a format the import converts is opened in the app.
final class AudioMarkerListTests: XCTestCase {
    // MARK: - The Sample

    /// The sample's cue and adtl chunks give its two markers, named, at
    /// their frames, with its sample rate.
    func testTheBroadcastWaveSamplesMarkersAreRead() throws {
        let read = try XCTUnwrap(AudioMarkerList.read(at: Self.sample))
        XCTAssertEqual(read.sampleRate, 11_025)
        XCTAssertEqual(read.markers, [
            AudioMarkerList.Marker(name: "First chapter", frame: 0),
            AudioMarkerList.Marker(name: "Second chapter", frame: 16_537),
        ])
    }

    /// The sample's markers are its chapters, which AVFoundation does not
    /// read: each lasting until the next, the last to the file's end.
    func testTheSamplesMarkersAreItsChapters() async throws {
        let copy = try makeSandboxDirectory("markers-bwf").appendingPathComponent("tones-bwf.wav")
        try FileManager.default.copyItem(at: Self.sample, to: copy)

        let chapters = await AudioPlaybackService.extractChapters(from: copy)

        XCTAssertEqual(chapters.map(\.title), ["First chapter", "Second chapter"])
        XCTAssertEqual(chapters.map(\.startTime), [0, 16_537.0 / 11_025])
        XCTAssertEqual(chapters.map(\.duration).reduce(0, +), 2.9999, accuracy: 0.01)
    }

    /// afinfo, in its child process, lists the same two markers, as the
    /// import reads them for a format it converts, and as chapters at their
    /// times.
    func testAfinfoListsTheSamplesMarkers() async throws {
        let copy = try makeSandboxDirectory("markers-afinfo").appendingPathComponent("tones-bwf.wav")
        try FileManager.default.copyItem(at: Self.sample, to: copy)

        let read = try await AudioFileInfo.read(copy)
        let info = try XCTUnwrap(read)

        XCTAssertEqual(info.markers, [
            AudioFileInfo.Marker(name: "First chapter", frame: 0),
            AudioFileInfo.Marker(name: "Second chapter", frame: 16_537),
        ])
        XCTAssertEqual(info.markerChapters, [
            NeroChapterReader.Chapter(title: "First chapter", start: 0),
            NeroChapterReader.Chapter(title: "Second chapter", start: 16_537.0 / 11_025),
        ])
    }

    /// afinfo's XML gives the first track's markers alone, a marker without a
    /// name keeping an empty one and one without a frame left out.
    func testAfinfosXMLGivesTheFirstTracksMarkers() throws {
        func marker(_ name: String?, _ frame: String?) -> String {
            "<audio_marker>" + (name.map { "<marker_name>\($0)</marker_name>" } ?? "")
                + (frame.map { "<marker_frame_pos>\($0)</marker_frame_pos>" } ?? "") + "<marker_type>....</marker_type></audio_marker>"
        }
        func track(_ number: Int, markers: [String]) -> String {
            "<track track_id=\"\(number)\"><num_channels>1</num_channels><sample_rate units=\"Hz\">8000</sample_rate>"
                + "<format_type>lpcm</format_type><bit_depth units=\"bits\">16</bit_depth><duration units=\"sec\">3.0</duration>"
                + "<audio_markers>\(markers.joined())</audio_markers></track>"
        }
        let xml = "<?xml version=\"1.0\" encoding=\"UTF8\"?><audio_info><audio_file><file_name>m.caf</file_name>"
            + "<file_type>'caff'</file_type><tracks>"
            + track(1, markers: [marker("Opening &amp; Overture", "0"), marker(nil, "4000"), marker("Lost", nil), marker("Late", "12000")])
            + track(2, markers: [marker("Other track", "100")])
            + "</tracks></audio_file></audio_info>"

        let info = try XCTUnwrap(AudioFileInfo.parse(xml: Data(xml.utf8)))

        XCTAssertEqual(info.markers, [
            AudioFileInfo.Marker(name: "Opening & Overture", frame: 0),
            AudioFileInfo.Marker(name: "", frame: 4_000),
            AudioFileInfo.Marker(name: "Late", frame: 12_000),
        ])
        XCTAssertEqual(info.markerChapters.map(\.start), [0, 0.5, 1.5])
    }

    // MARK: - Writing and Reading Back

    /// Markers written into a WAVE, an AIFF, and a CAF file made here read
    /// back with their names, at their times to the nearest frame; a WAVE's
    /// and an AIFF's are their chapters. An AIFF's last marker is read too,
    /// though Core Audio hands back a size 8 bytes short of the list it
    /// fills (train 1115-1258 lost it). A CAF, which the import converts,
    /// is never opened by the chapter reader, so it lists none there.
    func testMarkersWrittenReadBackInEveryFormat() async throws {
        let folder = try makeSandboxDirectory("markers-round-trip")
        let chapters: [(title: String, start: TimeInterval)] = [("Opening", 0), ("Middle, part 2", 0.5), ("End", 1.25)]
        for name in ["tones.wav", "tones.aiff", "tones.caf"] {
            let file = folder.appendingPathComponent(name)
            try writeSilence(to: file)

            try AudioMarkerList.write(chapters, to: file)

            let read = try XCTUnwrap(AudioMarkerList.read(at: file), name)
            XCTAssertEqual(read.markers.map(\.name), chapters.map(\.title), name)
            XCTAssertEqual(read.markers.map(\.frame), chapters.map { ($0.start * read.sampleRate).rounded() }, name)
            let listed = await AudioPlaybackService.extractChapters(from: file)
            XCTAssertEqual(listed.map(\.title), name.hasSuffix(".caf") ? [] : chapters.map(\.title), name)
        }
    }

    /// A file's markers are places in it (`FileChapterReaders.placedChapters`):
    /// one unnamed marker at the start makes no chapter, so the book keeps
    /// its title, as it did before markers were read, not "Chapter 1"; one a
    /// second in begins a chapter there, after one titled as the book is (by
    /// the file's name, as it has no title tag). A FLAC cue sheet's one track
    /// makes none either, and a place past the end leaves nothing.
    func testAFilesPlacesFollowTheBooksTitleAndOneAloneMakesNone() async throws {
        let folder = try makeSandboxDirectory("markers-places")
        let alone = folder.appendingPathComponent("Ferry Log.wav")
        try writeSilence(to: alone)
        try AudioMarkerList.write([("", 0)], to: alone)
        let later = folder.appendingPathComponent("Pier Notes.wav")
        try writeSilence(to: later)
        try AudioMarkerList.write([("", 1)], to: later)

        let aloneChapters = await AudioPlaybackService.extractChapters(from: alone)
        let parsed = try await AudioBookParser.parseFile(url: alone)
        let laterChapters = await AudioPlaybackService.extractChapters(from: later)

        XCTAssertEqual(aloneChapters.map(\.title), [])
        XCTAssertEqual(parsed.content.chapters.map(\.title), ["Ferry Log"])
        XCTAssertEqual(laterChapters.map(\.title), ["Pier Notes", "Chapter 2"])
        XCTAssertEqual(laterChapters.map(\.startTime), [0, 1])
        let place = { (title: String, start: TimeInterval) in NeroChapterReader.Chapter(title: title, start: start) }
        XCTAssertEqual(FileChapterReaders.placedChapters([place("Track 1", 0)], lasting: 60, leadingTitle: "Album").map(\.title), [])
        XCTAssertEqual(FileChapterReaders.placedChapters([place("Late", 90)], lasting: 60, leadingTitle: "Album").map(\.title), [])
        XCTAssertEqual(
            FileChapterReaders.placedChapters([place("B", 30), place("A", 0)], lasting: 60, leadingTitle: "Album").map(\.title),
            ["A", "B"]
        )
    }

    /// Names with letters outside ASCII, and typographic punctuation, read
    /// back as written in each format, as chapter titles in other languages
    /// need.
    func testNamesOutsideASCIIReadBackInEveryFormat() throws {
        let folder = try makeSandboxDirectory("markers-unicode")
        let chapters: [(title: String, start: TimeInterval)] = [("Café crème", 0), ("Naïve — “quoted”", 1)]
        for name in ["tones.wav", "tones.aiff", "tones.caf"] {
            let file = folder.appendingPathComponent(name)
            try writeSilence(to: file)
            try AudioMarkerList.write(chapters, to: file)
            XCTAssertEqual(AudioMarkerList.read(at: file)?.markers.map(\.name), chapters.map(\.title), name)
        }
    }

    /// Writing replaces the markers a file had, and an empty list leaves it
    /// with none.
    func testWritingReplacesTheMarkers() throws {
        let file = try makeSandboxDirectory("markers-replace").appendingPathComponent("tone.wav")
        try writeSilence(to: file)
        try AudioMarkerList.write([("One", 0), ("Two", 0.5)], to: file)
        try AudioMarkerList.write([("Only", 0.25)], to: file)
        XCTAssertEqual(AudioMarkerList.read(at: file)?.markers.map(\.name), ["Only"])
        try AudioMarkerList.write([], to: file)
        XCTAssertEqual(AudioMarkerList.read(at: file)?.markers, [])
    }

    /// A file of any other kind is never opened, for reading or writing, and
    /// a WAVE without markers has none.
    func testOtherKindsAreNeverOpenedAndAFileWithoutMarkersHasNone() throws {
        let folder = try makeSandboxDirectory("markers-refused")
        let ogg = folder.appendingPathComponent("tone.ogg")
        try Data("OggS".utf8).write(to: ogg)
        XCTAssertNil(AudioMarkerList.read(at: ogg))
        XCTAssertThrowsError(try AudioMarkerList.write([("A", 0)], to: ogg)) {
            XCTAssertEqual($0 as? AudioMarkerList.WriteError, .notMarkable)
        }
        XCTAssertEqual(try Data(contentsOf: ogg), Data("OggS".utf8), "a refused file is left as it was")
        // A WAVE file whose bytes are Ogg is refused by its content.
        let disguised = folder.appendingPathComponent("disguised.wav")
        try FileManager.default.copyItem(at: ogg, to: disguised)
        XCTAssertNil(AudioMarkerList.read(at: disguised))
        XCTAssertFalse(AudioMarkerList.mayHoldMarkers(URL(fileURLWithPath: "/a/b.mp3")))
        XCTAssertTrue(AudioMarkerList.mayHoldMarkers(URL(fileURLWithPath: "/a/B.AIF")))

        XCTAssertEqual(AudioMarkerList.read(at: CueSheetTests.sample("cue/part1.wav"))?.markers, [])
        XCTAssertEqual(AudioMarkerList.chapters(at: CueSheetTests.sample("cue/part1.wav")), [])
    }

    // MARK: - Helpers

    /// The Broadcast Wave sample with two cue markers.
    static let sample = CueSheetTests.sample("bwf/tones-bwf.wav")

    /// Writes two seconds of 16-bit mono silence at 8,000 Hz to `file`, in
    /// the format its extension names: big-endian for AIFF, which keeps no
    /// other, little-endian for WAVE and CAF.
    private func writeSilence(to file: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 8_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: file.pathExtension == "aiff",
        ]
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 8_000, channels: 1, interleaved: true))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        // Silence: the one channel's samples, all zero.
        try XCTUnwrap(buffer.int16ChannelData).pointee.update(repeating: 0, count: 16_000)
        let audio = try AVAudioFile(forWriting: file, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
        try audio.write(from: buffer)
    }
}
