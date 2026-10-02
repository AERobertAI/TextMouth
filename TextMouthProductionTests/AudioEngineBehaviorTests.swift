import AVFoundation
import XCTest
@testable import TextMouth

final class AudioEngineBehaviorTests: XCTestCase {
    func testAudioResumeRejectsPausedStateWithoutLoadedPlayer() {
        let playback = AudioPlaybackService()
        playback.isPaused = true
        playback.isPlaying = true

        XCTAssertFalse(playback.resume())
        XCTAssertTrue(playback.isPaused)
    }

    private let map: [(charOffset: Int, frame: AVAudioFramePosition)] = [
        (0, 0), (100, 1_000), (200, 2_000),
    ]

    private func mappedEngine() -> AudioEngineService {
        let engine = AudioEngineService()
        engine._configureFrameMapForTesting(map, totalFrames: 2_000)
        return engine
    }

    func testCharacterToFrameMappingIsMonotonic() {
        let engine = mappedEngine()
        var previous: AVAudioFramePosition = -1

        for offset in stride(from: 0, through: 200, by: 10) {
            let frame = engine._frameForCharOffsetForTesting(offset)
            XCTAssertGreaterThanOrEqual(frame, previous)
            previous = frame
        }
    }

    func testSpeedMultiplierUsesRenderRate() {
        XCTAssertEqual(AudioEngineService.speedMultiplier(wpm: 200, renderWPM: 216), 0.9259, accuracy: 0.001)
        XCTAssertEqual(AudioEngineService.speedMultiplier(wpm: 300, renderWPM: 216), 1.3889, accuracy: 0.001)
        XCTAssertEqual(AudioEngineService.speedMultiplier(wpm: 500, renderWPM: 216), 2.3148, accuracy: 0.001)
        XCTAssertEqual(AudioEngineService.speedMultiplier(wpm: 650, renderWPM: 216), 3.0093, accuracy: 0.001)
    }

    func testSpeedMultiplierClampsAndHandlesInvalidRenderRate() {
        XCTAssertEqual(AudioEngineService.speedMultiplier(wpm: 1, renderWPM: 216), 0.25)
        XCTAssertEqual(AudioEngineService.speedMultiplier(wpm: 2_000, renderWPM: 216), 4)
        XCTAssertEqual(AudioEngineService.speedMultiplier(wpm: 200, renderWPM: 0), 1)
    }

    func testPlayerTimelineIsNotRateCorrectedTwice() {
        XCTAssertEqual(
            AudioEngineService.currentFrame(segmentStartFrame: 1_000, playerSampleTime: 22_050),
            23_050
        )
    }

    func testFrameCharacterRoundTripIsConsistent() {
        let engine = mappedEngine()

        for offset in [0, 25, 100, 150, 200] {
            let frame = engine._frameForCharOffsetForTesting(offset)
            XCTAssertEqual(engine._charOffsetForFrameForTesting(frame), offset, accuracy: 1)
        }
    }

    func testEmptyFrameMapReturnsZero() {
        let engine = AudioEngineService()
        engine._configureFrameMapForTesting([], totalFrames: 0)

        XCTAssertEqual(engine._frameForCharOffsetForTesting(100), 0)
        XCTAssertEqual(engine._charOffsetForFrameForTesting(100), 0)
    }

    func testCharacterToFrameMappingInterpolates() {
        let engine = mappedEngine()

        XCTAssertEqual(engine._frameForCharOffsetForTesting(0), 0)
        XCTAssertEqual(engine._frameForCharOffsetForTesting(50), 500)
        XCTAssertEqual(engine._frameForCharOffsetForTesting(100), 1_000)
        XCTAssertEqual(engine._frameForCharOffsetForTesting(150), 1_500)
        XCTAssertEqual(engine._frameForCharOffsetForTesting(200), 2_000)
    }

    func testFrameToCharacterMappingInterpolatesAndClamps() {
        let engine = mappedEngine()

        XCTAssertEqual(engine._charOffsetForFrameForTesting(-100), 0)
        XCTAssertEqual(engine._charOffsetForFrameForTesting(500), 50)
        XCTAssertEqual(engine._charOffsetForFrameForTesting(1_000), 100)
        XCTAssertEqual(engine._charOffsetForFrameForTesting(2_000), 200)
        XCTAssertEqual(engine._charOffsetForFrameForTesting(5_000), 200)
    }

    func testSilencePaddingFrameCountUsesSampleRate() {
        XCTAssertEqual(AudioEngineService.silencePaddingFrameCount(sampleRate: 22_050), 4_410)
        XCTAssertEqual(AudioEngineService.silencePaddingFrameCount(sampleRate: 44_100), 8_820)
    }

    func testSilencePaddingIsPositiveAtNormalSampleRate() {
        XCTAssertGreaterThan(AudioEngineService.silencePaddingFrameCount(sampleRate: 22_050), 0)
    }

    func testSilencePaddingDurationRemainsTwoHundredMilliseconds() {
        XCTAssertEqual(AudioEngineService.silencePaddingDuration, 0.2)
    }

    func testSpeechMappingEndsBeforePaddedBufferEnd() {
        let engine = mappedEngine()
        let speechFrames = engine._frameForCharOffsetForTesting(200)
        let bufferFrames = speechFrames + AVAudioFramePosition(
            AudioEngineService.silencePaddingFrameCount(sampleRate: 22_050)
        )

        XCTAssertEqual(speechFrames, 2_000)
        XCTAssertLessThan(speechFrames, bufferFrames)
    }

    func testFramesInPaddingClampToFinalCharacter() {
        let engine = mappedEngine()

        XCTAssertEqual(engine._charOffsetForFrameForTesting(6_410), 200)
        XCTAssertEqual(engine._charOffsetForFrameForTesting(2_000), 200)
    }

    func testSubBufferSeekIncludesPaddingAfterSpeechRemainder() {
        let engine = mappedEngine()
        let seekFrame = engine._frameForCharOffsetForTesting(100)
        let padding = AudioEngineService.silencePaddingFrameCount(sampleRate: 22_050)

        XCTAssertEqual(2_000 - seekFrame, 1_000)
        XCTAssertEqual(2_000 + AVAudioFramePosition(padding) - seekFrame, 5_410)
    }

    func testAudioEngineSetVolumeTracksAndAppliesValue() {
        let engine = AudioEngineService()

        engine.setVolume(0.5)

        XCTAssertEqual(engine.intendedVolume, 0.5)
        XCTAssertEqual(engine.outputVolume, 0.5)
    }

    func testAudioEngineRestoreVolumeResetsToFull() {
        let engine = AudioEngineService()
        engine.setVolume(0.3)

        engine.restoreVolume()

        XCTAssertEqual(engine.intendedVolume, 1)
        XCTAssertEqual(engine.outputVolume, 1)
    }

    func testAudioEngineVolumeClampsToValidRange() {
        let engine = AudioEngineService()

        engine.setVolume(-0.5)
        XCTAssertEqual(engine.intendedVolume, 0)
        engine.setVolume(2)
        XCTAssertEqual(engine.intendedVolume, 1)
        engine.setVolume(0.75)
        XCTAssertEqual(engine.intendedVolume, 0.75)
    }

    func testAudioEngineStopPreservesIntendedFadeVolume() {
        let engine = AudioEngineService()
        engine.setVolume(0.4)

        engine.stop()

        XCTAssertEqual(engine.intendedVolume, 0.4)
    }

    func testDiscardRenderedAudioRemovesPreviousChapterBuffer() {
        let engine = AudioEngineService()
        engine._installRenderedAudioForTesting()

        XCTAssertTrue(engine.hasRenderedAudio)
        XCTAssertTrue(engine.discardRenderedAudio())

        XCTAssertFalse(engine.hasRenderedAudio)
        XCTAssertEqual(engine.renderedAudioByteCount, 0)
        XCTAssertEqual(engine._frameForCharOffsetForTesting(1), 0)
    }

    func testDiscardRenderedAudioReportsWhenNoBufferWasRetained() {
        let engine = AudioEngineService()

        XCTAssertFalse(engine.discardRenderedAudio())
        XCTAssertFalse(engine.hasRenderedAudio)
    }

    /// Discarded audio takes its signature with it, so an engine with no
    /// audio never claims to hold audio rendered from anything.
    func testDiscardRenderedAudioForgetsItsSignature() {
        let engine = AudioEngineService()
        engine._installRenderedAudioForTesting(
            signature: SpeechRenderSignature(text: "Chapter one.", voiceIdentifier: "voice.a")
        )

        engine.discardRenderedAudio()

        XCTAssertNil(engine.renderedSignature)
    }

    /// Adopting pre-rendered audio adopts what it was rendered from, so the
    /// speech engine can still tell which text and voice its audio belongs to.
    func testAudioEngineAdoptionCarriesTheRenderedSignature() {
        let signature = SpeechRenderSignature(text: "Chapter two.", voiceIdentifier: "voice.b")
        let source = AudioEngineService()
        source._installRenderedAudioForTesting(signature: signature)
        let receiver = AudioEngineService()
        receiver._installRenderedAudioForTesting(
            signature: SpeechRenderSignature(text: "Chapter one.", voiceIdentifier: "voice.b")
        )

        receiver.adoptRenderedAudio(from: source)

        XCTAssertEqual(receiver.renderedSignature, signature)
        XCTAssertTrue(receiver.hasRenderedAudio)
    }

    func testAudioEngineAdoptionPreservesReceiverVolume() {
        let receiver = AudioEngineService()
        let source = AudioEngineService()
        receiver.setVolume(0.5)

        receiver.adoptRenderedAudio(from: source)

        XCTAssertEqual(receiver.intendedVolume, 0.5)
        XCTAssertEqual(receiver.outputVolume, 0.5)
    }

    func testAudioPlaybackSetVolumeTracksValue() {
        let playback = AudioPlaybackService()

        playback.setVolume(0.5)

        XCTAssertEqual(playback.intendedVolume, 0.5)
        XCTAssertEqual(playback.outputVolume, 0.5)
    }

    func testPausedEngineIgnoresRouteTeardownCompletion() {
        let engine = AudioEngineService()
        engine.isPlaying = true
        engine.isPaused = true
        var finishCount = 0
        engine.onPlaybackFinished = {
            finishCount += 1
        }

        let accepted = engine._handlePlaybackCompleteForTesting()

        XCTAssertFalse(accepted)
        XCTAssertTrue(engine.isPlaying)
        XCTAssertTrue(engine.isPaused)
        XCTAssertEqual(finishCount, 0)
    }

    func testActivelyPlayingEngineAcceptsNaturalCompletion() {
        let engine = AudioEngineService()
        engine.isPlaying = true
        engine.isPaused = false
        var finishCount = 0
        engine.onPlaybackFinished = {
            finishCount += 1
        }

        let accepted = engine._handlePlaybackCompleteForTesting()

        XCTAssertTrue(accepted)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertFalse(engine.isPaused)
        XCTAssertEqual(finishCount, 1)
    }

    func testAudioPlaybackRestoreVolumeResetsToFull() {
        let playback = AudioPlaybackService()
        playback.setVolume(0.3)

        playback.restoreVolume()

        XCTAssertEqual(playback.intendedVolume, 1)
        XCTAssertEqual(playback.outputVolume, 1)
    }

    func testAudioPlaybackNewPlayerInheritsTrackedVolume() throws {
        let tracks = try makeSilentTracks(count: 1)
        defer { tracks.remove() }
        let playback = AudioPlaybackService()
        playback.setVolume(0.4)

        XCTAssertTrue(playback.load(url: tracks.urls[0]))

        XCTAssertEqual(playback.outputVolume, 0.4)
        playback.stop()
    }

    func testAudioPlaybackChapterLoadPreservesFadeVolume() throws {
        let tracks = try makeSilentTracks(count: 2)
        defer { tracks.remove() }
        let playback = AudioPlaybackService()
        playback.setVolume(0.6)
        XCTAssertTrue(playback.load(url: tracks.urls[0]))

        XCTAssertTrue(playback.load(url: tracks.urls[1]))

        XCTAssertEqual(playback.intendedVolume, 0.6)
        XCTAssertEqual(playback.outputVolume, 0.6)
        playback.stop()
    }

    func testAudioPlaybackMultipleLoadsPreserveProgressiveFade() throws {
        let tracks = try makeSilentTracks(count: 3)
        defer { tracks.remove() }
        let playback = AudioPlaybackService()

        for (url, volume) in zip(tracks.urls, [Float(0.8), 0.5, 0.1]) {
            playback.setVolume(volume)
            XCTAssertTrue(playback.load(url: url))
            XCTAssertEqual(playback.outputVolume, volume)
        }
        playback.stop()
    }

    func testAudioPlaybackStopResetsTrackedVolume() {
        let playback = AudioPlaybackService()
        playback.setVolume(0.3)

        playback.stop()

        XCTAssertEqual(playback.intendedVolume, 1)
    }

    func testAudioPlaybackVolumeClampsToValidRange() {
        let playback = AudioPlaybackService()

        playback.setVolume(-0.5)
        XCTAssertEqual(playback.intendedVolume, 0)
        playback.setVolume(2)
        XCTAssertEqual(playback.intendedVolume, 1)
        playback.setVolume(0.75)
        XCTAssertEqual(playback.intendedVolume, 0.75)
    }

    func testAudioPlaybackSameURLLoadRetainsVolume() throws {
        let tracks = try makeSilentTracks(count: 1)
        defer { tracks.remove() }
        let playback = AudioPlaybackService()
        let url = tracks.urls[0]
        playback.setVolume(0.2)
        XCTAssertTrue(playback.load(url: url))

        XCTAssertTrue(playback.load(url: url))

        XCTAssertEqual(playback.outputVolume, 0.2)
        playback.stop()
    }

    /// Silent tracks in a folder of their own, and a way to remove them.
    private struct SilentTracks {
        let directory: URL
        let urls: [URL]

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Write `count` one-second silent tracks. Loading a real file builds a
    /// real player, whose volume is what these tests check; a missing path
    /// is refused before any player exists.
    private func makeSilentTracks(count: Int) throws -> SilentTracks {
        let directory = try AudioTestFixtures.makeTemporaryDirectory()
        let urls = (1...count).map { directory.appendingPathComponent("\($0).wav") }
        for url in urls {
            try AudioTestFixtures.writeSilence(to: url)
        }
        return SilentTracks(directory: directory, urls: urls)
    }
}
