import XCTest
@testable import TextMouth

/// The metadata readers never hand an Ogg file to AVFoundation (the rule of
/// October 14, 2026): `AudioPlaybackService.metadataAsset(for:)` is their one
/// funnel, and it refuses Ogg by extension. No test here opens a real Ogg
/// file with an Apple API.
final class OggMetadataGuardTests: XCTestCase {
    /// A folder of the test's own, removed when the test ends.
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try AudioTestFixtures.makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when set-up failed.
        if let folder {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// The funnel refuses every Ogg extension, in any case.
    func testTheFunnelRefusesOggExtensions() {
        for name in ["a.ogg", "a.OGA", "a.opus", "A.Ogg"] {
            XCTAssertNil(AudioPlaybackService.metadataAsset(for: URL(fileURLWithPath: "/tmp/\(name)")),
                         "\(name) must not be opened")
        }
    }

    /// The funnel opens every other audio extension.
    func testTheFunnelOpensOtherFormats() {
        for name in ["a.m4a", "a.mp3", "a.wav"] {
            XCTAssertNotNil(AudioPlaybackService.metadataAsset(for: URL(fileURLWithPath: "/tmp/\(name)")),
                            "\(name) must be opened")
        }
    }

    /// Real, playable audio copied under an Ogg name gives no chapters, no
    /// tags, and no duration, while the same bytes named `.wav` give a
    /// duration: the guard refuses, not a failing decode.
    func testPlayableAudioNamedOggIsNeverProbed() async throws {
        let ogg = folder.appendingPathComponent("x.ogg")
        let wav = folder.appendingPathComponent("x.wav")
        // AVAudioFile infers its format from the extension, so the audio is
        // written as a WAVE file and the same bytes copied under the Ogg name.
        try AudioTestFixtures.writeSilence(to: wav, duration: 2)
        try FileManager.default.copyItem(at: wav, to: ogg)

        let chapters = await AudioPlaybackService.extractChapters(from: ogg)
        XCTAssertTrue(chapters.isEmpty)
        let metadata = await AudioPlaybackService.extractFullMetadata(from: ogg)
        XCTAssertEqual(metadata.fileFormat, "OGG")
        XCTAssertEqual(metadata.title, "")
        XCTAssertEqual(metadata.artist, "")
        XCTAssertEqual(metadata.duration, "")
        let oggDuration = await AudioPlaybackService.getDuration(of: ogg)
        XCTAssertNil(oggDuration)

        let wavDuration = await AudioPlaybackService.getDuration(of: wav)
        XCTAssertEqual(try XCTUnwrap(wavDuration), 2, accuracy: 0.1)
    }
}
