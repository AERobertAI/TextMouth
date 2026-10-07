import AVFoundation
import Darwin
import os
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

    // MARK: - Ends of rendered segments

    /// The policy finishes a segment that played to its end while playing,
    /// holds one that played to its end as the listener paused, and ignores
    /// a report from a replaced play, from stopped playback, and from paused
    /// playback short of its end, as a vanished output route gives.
    func testSegmentEndPolicyFinishesHoldsOrIgnoresEachReport() {
        func outcome(scheduled: Int = 2, playing: Bool = true, paused: Bool, atEnd: Bool) -> SpeechSegmentEndOutcome {
            SpeechSegmentEndPolicy.outcome(
                scheduledGeneration: scheduled,
                currentGeneration: 2,
                isPlaying: playing,
                isPaused: paused,
                reachedSegmentEnd: atEnd
            )
        }

        XCTAssertEqual(outcome(paused: false, atEnd: true), .finishedPlayback)
        XCTAssertEqual(outcome(paused: false, atEnd: false), .finishedPlayback)
        XCTAssertEqual(outcome(paused: true, atEnd: true), .heldUntilResume)
        XCTAssertEqual(outcome(paused: true, atEnd: false), .ignoredShortOfTheEnd)
        XCTAssertEqual(outcome(scheduled: 1, paused: true, atEnd: true), .scheduledDuringEarlierPlay)
        XCTAssertEqual(outcome(scheduled: 1, paused: false, atEnd: true), .scheduledDuringEarlierPlay)
        XCTAssertEqual(outcome(playing: false, paused: false, atEnd: true), .nothingPlaying)
    }

    /// A pause landing just as the rendered audio plays to its end does not
    /// swallow that end (board #166): the player node's report, which
    /// reaches the main queue after the pause, is held, and playback stays
    /// paused. Resuming finishes the play once, after `resume()` has
    /// returned, as an audiobook's held end does. The report used to be
    /// dropped, so resuming played an empty node and speech stayed Playing.
    func testPauseAsRenderedAudioEndsIsFinishedOnResume() {
        var finishCount = 0
        let finished = expectation(description: "Playback finished")
        let engine = engineHeldAtItsEnd {
            finishCount += 1
            finished.fulfill()
        }
        defer { engine.stop() }

        XCTAssertTrue(engine.isPlaying)
        XCTAssertTrue(engine.isPaused)
        XCTAssertEqual(finishCount, 0, "finished while paused")

        XCTAssertTrue(engine.resume())
        XCTAssertEqual(finishCount, 0, "finished before resume() returned")
        wait(for: [finished], timeout: 5)

        XCTAssertFalse(engine.isPlaying)
        XCTAssertFalse(engine.isPaused)
        XCTAssertEqual(finishCount, 1)
    }

    /// A listener who pauses again before a resumed play's held end is
    /// finished holds it once more: playback stays paused, and the next
    /// resume finishes the play.
    func testPausingAgainBeforeTheHeldEndIsFinishedHoldsItAgain() {
        var finishCount = 0
        let finished = expectation(description: "Playback finished")
        let engine = engineHeldAtItsEnd {
            finishCount += 1
            finished.fulfill()
        }
        defer { engine.stop() }
        let heldAgain = expectation(description: "End held again")
        engine._segmentEndHandledForTesting = { outcome in
            if outcome == .heldUntilResume {
                heldAgain.fulfill()
            }
        }

        XCTAssertTrue(engine.resume())
        // Paused again before the main queue turns to finish the play.
        engine.pause()
        wait(for: [heldAgain], timeout: 5)

        XCTAssertTrue(engine.isPlaying)
        XCTAssertTrue(engine.isPaused)
        XCTAssertEqual(finishCount, 0)

        engine._segmentEndHandledForTesting = nil
        XCTAssertTrue(engine.resume())
        wait(for: [finished], timeout: 5)

        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(finishCount, 1)
    }

    /// An engine whose rendered audio, `seconds` of silence, played to its
    /// end just as the listener paused, with the node's report of that end
    /// held. The node's own report puts the pause on the main queue ahead of
    /// itself, so the pause lands at the audio's end every time.
    ///
    /// - Parameter onFinish: The engine's finish handler, installed before
    ///   it plays, so that a finish at any moment is seen.
    private func engineHeldAtItsEnd(
        lasting seconds: TimeInterval = 0.3,
        onFinish: @escaping () -> Void
    ) -> AudioEngineService {
        let engine = AudioEngineService()
        engine._installRenderedAudioForTesting(lasting: seconds)
        engine.onPlaybackFinished = onFinish
        let held = expectation(description: "End held while paused")
        engine._segmentEndHandledForTesting = { outcome in
            if outcome == .heldUntilResume {
                held.fulfill()
            }
        }
        engine._segmentPlayedBackForTesting = { reportingEngine in
            DispatchQueue.main.async { reportingEngine.pause() }
        }

        engine.play()
        XCTAssertTrue(engine.isPlaying, "the engine could not start")
        wait(for: [held], timeout: 5)
        engine._segmentPlayedBackForTesting = nil
        engine._segmentEndHandledForTesting = nil
        return engine
    }

    /// A report that comes while paused short of the segment's end, as the
    /// player node gives when its output route disappears, ends nothing,
    /// neither then nor on resume. The resumed audio still finishes the
    /// play when it really ends.
    func testReportWhilePausedShortOfTheEndIsNotFinishedOnResume() {
        let engine = AudioEngineService()
        defer { engine.stop() }
        engine._installRenderedAudioForTesting(lasting: 0.4)
        var finishCount = 0
        let finished = expectation(description: "Playback finished")
        engine.onPlaybackFinished = {
            finishCount += 1
            finished.fulfill()
        }

        engine.play()
        engine.pause()
        XCTAssertFalse(engine._handlePlaybackCompleteForTesting(), "a report short of the end finished playback")
        XCTAssertTrue(engine.resume())
        // Anything resuming put on the main queue runs before this does.
        let turn = expectation(description: "Main queue turned")
        DispatchQueue.main.async { turn.fulfill() }
        wait(for: [turn], timeout: 5)

        XCTAssertTrue(engine.isPlaying, "resuming finished the play at once")
        XCTAssertEqual(finishCount, 0)
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(finishCount, 1)
    }

    /// A report from a segment that a newer play replaced ends nothing, and
    /// says so in one playback trace line naming both plays.
    func testReportFromAReplacedPlayIsTracedAndEndsNothing() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        setAppTracing(true)
        let engine = AudioEngineService()
        defer { engine.stop() }
        engine._installRenderedAudioForTesting(lasting: 1)
        var finishCount = 0
        engine.onPlaybackFinished = { finishCount += 1 }
        let dropped = expectation(description: "Report from the replaced play dropped")
        dropped.assertForOverFulfill = false
        engine._segmentEndHandledForTesting = { outcome in
            if outcome == .scheduledDuringEarlierPlay {
                dropped.fulfill()
            }
        }

        let lines = logLines(in: .debug) {
            engine.play()
            // Playing again replaces the first play's segment, which the
            // node reports played back as it stops it.
            engine.play()
            wait(for: [dropped], timeout: 5)
        }
        // Stopping at the end reports the second play's segment too, after
        // this test has finished with its expectation.
        engine._segmentEndHandledForTesting = nil

        let drops = lines.filter { $0.contains("speech audio end ignored: scheduled during an earlier play") }
        XCTAssertEqual(drops.count, 1, "\(lines)")
        XCTAssertTrue(
            drops.allSatisfy {
                $0.contains("TRACE playback: speech audio end ignored: scheduled during an earlier play (generation 1, now 2)")
            },
            "\(drops)"
        )
        XCTAssertEqual(finishCount, 0)
        XCTAssertTrue(engine.isPlaying)
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

    // MARK: - Rendered Speech in Blocks

    /// The synthesizer's pieces land in the render's blocks in order,
    /// however their sizes fall against the blocks' edges, followed by the
    /// silence padding; the audio is kept at two bytes a sample, and the
    /// last block keeps no room past it.
    func testRenderedAudioKeepsEveryPieceInOrderAcrossBlocks() throws {
        let builder = RenderedSpeechAudio.Builder(blockFrameCount: 4)
        var next = 0
        for size in [3, 6, 1, 5] {
            builder.append(try Self.makePiece((next..<next + size).map(Self.sample)))
            next += size
        }

        let audio = try XCTUnwrap(builder.finish(paddingFrameCount: 2))

        XCTAssertEqual(audio.speechFrameCount, 15)
        XCTAssertEqual(audio.frameCount, 17)
        Self.assertSamples(try Self.samples(of: audio, in: 0..<17), match: (0..<15).map(Self.sample) + [0, 0])
        // A stretch beginning and ending inside blocks comes out whole.
        Self.assertSamples(try Self.samples(of: audio, in: 3..<10), match: (3..<10).map(Self.sample))
        XCTAssertEqual(audio.byteCount, 17 * MemoryLayout<Int16>.stride)
    }

    /// Samples beyond full scale are clipped to it as they are kept in 16
    /// bits, rather than wrap around into loud noise, and every other
    /// sample comes back within half a 16-bit step.
    func testSamplesBeyondFullScaleAreClippedToIt() throws {
        let builder = RenderedSpeechAudio.Builder()

        builder.append(try Self.makePiece([1.5, -2, 0.3, -0.25, 1, -1]))
        let audio = try XCTUnwrap(builder.finish(paddingFrameCount: 0))

        let played = try Self.samples(of: audio, in: 0..<6)
        let halfStep = 0.5 / SpeechSampleCodec.fullScale
        for (sample, expected) in zip(played, [Float(1), -1, 0.3, -0.25, 1, -1]) {
            XCTAssertEqual(sample, expected, accuracy: halfStep)
        }
    }

    /// A piece of 16-bit samples, which some voices may write, is kept as it
    /// is.
    func testSixteenBitPiecesAreKeptAsTheyAre() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 22_050, channels: 1, interleaved: false)
        )
        let piece = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
        let channel = try XCTUnwrap(piece.int16ChannelData?[0])
        for (index, value) in [Int16(100), -100, 32_767].enumerated() {
            channel[index] = value
        }
        piece.frameLength = 3
        let builder = RenderedSpeechAudio.Builder()

        builder.append(piece)
        let audio = try XCTUnwrap(builder.finish(paddingFrameCount: 0))

        XCTAssertNil(builder.failure)
        Self.assertSamples(try Self.samples(of: audio, in: 0..<3), match: [100, -100, 32_767].map(Self.sample))
    }

    /// A piece whose channels are interleaved is kept channel by channel,
    /// and plays in the standard format, with a buffer for each channel.
    func testInterleavedPiecesAreKeptChannelByChannel() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 22_050, channels: 2, interleaved: true)
        )
        let piece = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
        let frames = [1, -1, 2, -2, 3, -3].map(Self.sample)
        let channels = try XCTUnwrap(piece.floatChannelData)
        for (index, value) in frames.enumerated() {
            channels[0][index] = value
        }
        piece.frameLength = 3
        let builder = RenderedSpeechAudio.Builder(blockFrameCount: 2)

        builder.append(piece)
        let audio = try XCTUnwrap(builder.finish(paddingFrameCount: 1))

        XCTAssertFalse(audio.format.isInterleaved)
        XCTAssertEqual(audio.format.channelCount, 2)
        let out = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.format, frameCapacity: 4))
        audio.copyFrames(0..<4, into: out)
        let outChannels = try XCTUnwrap(out.floatChannelData)
        Self.assertSamples(Array(UnsafeBufferPointer(start: outChannels[0], count: 4)), match: [1, 2, 3, 0].map(Self.sample))
        Self.assertSamples(Array(UnsafeBufferPointer(start: outChannels[1], count: 4)), match: [-1, -2, -3, 0].map(Self.sample))
    }

    /// A piece in another sample rate than the rest cannot join them, so
    /// the render fails rather than play at the wrong speed.
    func testAPieceInAnotherSampleRateFailsTheRender() throws {
        let builder = RenderedSpeechAudio.Builder()

        builder.append(try Self.makePiece([1, 2].map(Self.sample)))
        builder.append(try Self.makePiece([3].map(Self.sample), sampleRate: 44_100))

        XCTAssertNotNil(builder.failure)
        XCTAssertNil(builder.finish(paddingFrameCount: 4))
    }

    /// A render of nothing installs nothing.
    func testARenderOfNothingBuildsNoAudio() {
        XCTAssertNil(RenderedSpeechAudio.Builder().finish(paddingFrameCount: 4))
    }

    // MARK: - Feeding the Player Node

    /// A play is fed to the player node in order, a few slices at a time,
    /// from the render's first frame through its padding, never holding
    /// more than its slices ahead, and ends once.
    @MainActor
    func testAPlayFeedsItsSegmentInOrderedSlicesEndingWithThePadding() throws {
        let engine = AudioEngineService(sliceFrameCount: 2_205, slicesAhead: 2)
        engine.setVolume(0)
        defer { engine.stop() }
        let speech = Self.quietRamp(frameCount: 13_230)
        engine._installRenderedAudioForTesting(samples: speech)
        let slices = SliceLog()
        engine._observeScheduledSlicesForTesting { slices.append($0) }
        defer { engine._observeScheduledSlicesForTesting(nil) }
        var finishCount = 0
        engine.onPlaybackFinished = { finishCount += 1 }

        engine.play()
        XCTAssertTrue(engine.isPlaying, "the engine could not start")
        XCTAssertTrue(eventually(within: 5) { finishCount > 0 }, "the play never finished")
        spinMainRunLoop(for: 0.1)

        let padding = AudioEngineService.silencePaddingFrameCount(sampleRate: 22_050)
        let frameCount = speech.count + padding
        let scheduled = slices.all
        XCTAssertEqual(scheduled.map(\.frames.lowerBound), Array(stride(from: 0, to: frameCount, by: 2_205)))
        XCTAssertEqual(scheduled.last?.frames.upperBound, frameCount)
        Self.assertSamples(scheduled.flatMap(\.samples), match: speech + [Float](repeating: 0, count: padding))
        XCTAssertLessThanOrEqual(scheduled.map(\.bytesScheduled).max() ?? 0, 2 * 2_205 * MemoryLayout<Float>.stride)
        XCTAssertEqual(finishCount, 1)
    }

    /// A play that starts part-way through fades in its first slice from
    /// silence over 10 milliseconds, and leaves the rest of it, and every
    /// slice after it, as rendered.
    @MainActor
    func testAPlayFromPartWayFadesInOnlyItsFirstSlice() throws {
        let engine = AudioEngineService(sliceFrameCount: 2_205, slicesAhead: 2)
        engine.setVolume(0)
        defer { engine.stop() }
        let speech = Self.quietRamp(frameCount: 8_820)
        engine._installRenderedAudioForTesting(samples: speech)
        // A hundred characters over the speech: the fiftieth starts halfway.
        engine._configureFrameMapForTesting([(0, 0), (100, 8_820)], totalFrames: 8_820)
        let slices = SliceLog()
        engine._observeScheduledSlicesForTesting { slices.append($0) }
        defer { engine._observeScheduledSlicesForTesting(nil) }

        engine.play(fromCharOffset: 50)
        // A play schedules its first slices before it returns.
        let scheduled = slices.all
        engine.stop()

        XCTAssertEqual(scheduled.map(\.frames), [4_410..<6_615, 6_615..<8_820])
        let first = try XCTUnwrap(scheduled.first)
        let fadeFrames = 220
        Self.assertSamples(
            Array(first.samples[..<fadeFrames]),
            match: (0..<fadeFrames).map { speech[4_410 + $0] * (Float($0) / Float(fadeFrames)) }
        )
        Self.assertSamples(Array(first.samples[fadeFrames...]), match: Array(speech[(4_410 + fadeFrames)..<6_615]))
        Self.assertSamples(scheduled.last?.samples, match: Array(speech[6_615..<8_820]))
    }

    /// A seek while playing schedules a few slices from where it lands, not
    /// a copy of the rest of the chapter, as starting part-way through once
    /// did (TODO PERF04). Stopping leaves nothing scheduled.
    @MainActor
    func testASeekWhilePlayingSchedulesOnlyAFewSlices() throws {
        let sliceFrames = 4_096
        let engine = AudioEngineService(sliceFrameCount: sliceFrames, slicesAhead: 3)
        engine.setVolume(0)
        defer { engine.stop() }
        engine._installRenderedAudioForTesting(lasting: 20)
        engine._configureFrameMapForTesting([(0, 0), (100, 441_000)], totalFrames: 441_000)
        let slices = SliceLog()
        engine._observeScheduledSlicesForTesting { slices.append($0) }
        defer { engine._observeScheduledSlicesForTesting(nil) }
        engine.play()
        XCTAssertTrue(engine.isPlaying, "the engine could not start")

        slices.removeAll()
        engine.seek(toCharOffset: 50)
        let scheduledBytes = engine.scheduledSegmentAudioByteCount
        let firstAfterSeek = slices.all.first
        XCTAssertTrue(engine.isPlaying)
        engine.stop()

        XCTAssertEqual(firstAfterSeek?.frames.lowerBound, 220_500)
        XCTAssertGreaterThan(scheduledBytes, 0)
        XCTAssertLessThanOrEqual(scheduledBytes, 3 * sliceFrames * MemoryLayout<Float>.stride)
        // The rest of the chapter from the seek, padding included, which a
        // seek used to copy whole, is more than ten times as much.
        let restOfChapterBytes = (441_000 + 4_410 - 220_500) * MemoryLayout<Float>.stride
        XCTAssertLessThan(scheduledBytes * 10, restOfChapterBytes)
        XCTAssertEqual(engine.scheduledSegmentAudioByteCount, 0)
    }

    /// The position runs on unbroken across a play's slices: it never steps
    /// back, and it reaches the end of the speech.
    @MainActor
    func testThePositionRunsOnAcrossSlices() {
        let engine = AudioEngineService(sliceFrameCount: 2_205, slicesAhead: 2)
        engine.setVolume(0)
        defer { engine.stop() }
        engine._installRenderedAudioForTesting(lasting: 0.8)
        engine._configureFrameMapForTesting([(0, 0), (100, 17_640)], totalFrames: 17_640)
        var finished = false
        engine.onPlaybackFinished = { finished = true }
        var offsets: [Int] = []

        engine.play()
        let ended = eventually(within: 5) {
            if engine.isPlaying {
                offsets.append(engine.currentCharOffset())
            }
            return finished
        }

        XCTAssertTrue(ended, "the play never finished")
        XCTAssertEqual(offsets, offsets.sorted(), "the position stepped back")
        XCTAssertGreaterThanOrEqual(offsets.max() ?? 0, 90, "the position stopped short")
    }

    /// Once a play is stopped, the reports its slices bring schedule
    /// nothing more.
    @MainActor
    func testAStoppedPlaySchedulesNothingMore() {
        let engine = AudioEngineService(sliceFrameCount: 1_024, slicesAhead: 2)
        engine.setVolume(0)
        defer { engine.stop() }
        engine._installRenderedAudioForTesting(lasting: 1)
        let slices = SliceLog()
        engine._observeScheduledSlicesForTesting { slices.append($0) }
        defer { engine._observeScheduledSlicesForTesting(nil) }
        engine.play()
        spinMainRunLoop(for: 0.1)

        engine.stop()
        let scheduledAtStop = slices.all.count
        spinMainRunLoop(for: 0.3)

        XCTAssertEqual(slices.all.count, scheduledAtStop)
        XCTAssertEqual(engine.scheduledSegmentAudioByteCount, 0)
    }

    /// A sample `index` 16-bit steps from silence, so it keeps its value,
    /// near enough, through being kept in 16 bits.
    private static func sample(_ index: Int) -> Float {
        Float(index) / SpeechSampleCodec.fullScale
    }

    /// `frameCount` samples of a quiet sawtooth that is never silent, so
    /// slices of it are told apart from the padding. At about -54 dBFS, and
    /// played at volume 0, nothing is heard.
    private static func quietRamp(frameCount: Int) -> [Float] {
        (0..<frameCount).map { sample($0 % 64 + 1) }
    }

    /// A piece of `values`, one channel of 32-bit floats, as the synthesizer
    /// writes one.
    private static func makePiece(_ values: [Float], sampleRate: Double = 22_050) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let piece = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(values.count)))
        let channel = try XCTUnwrap(piece.floatChannelData?[0])
        for (index, value) in values.enumerated() {
            channel[index] = value
        }
        piece.frameLength = AVAudioFrameCount(values.count)
        return piece
    }

    /// Check that `actual` holds `expected`'s samples, each within a
    /// three-hundredth of a 16-bit step: the audio as rendered, as it comes
    /// back from being kept in 16 bits.
    private static func assertSamples(
        _ actual: [Float]?,
        match expected: [Float],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual else {
            XCTFail("no samples", file: file, line: line)
            return
        }
        XCTAssertEqual(actual.count, expected.count, "the number of samples", file: file, line: line)
        let mismatch = zip(actual, expected).enumerated().first { abs($0.element.0 - $0.element.1) > 1e-7 }
        XCTAssertNil(
            mismatch.map { "sample \($0.offset) is \($0.element.0), not \($0.element.1)" },
            file: file,
            line: line
        )
    }

    /// The first channel's samples of frames `frames` of `audio`.
    private static func samples(of audio: RenderedSpeechAudio, in frames: Range<Int>) throws -> [Float] {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.format, frameCapacity: AVAudioFrameCount(frames.count)))
        audio.copyFrames(frames, into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    // MARK: - Markup

    /// The chunk of *Rainbows End* the engine refused raw, cancelled with 0
    /// frames (see `SpeechMarkupGuard`), renders through the engine's render
    /// path, which hands the synthesizer the text guarded, and the audio
    /// carries the request's own signature. Rendered offline, in its turn
    /// on the app's render queue: nothing is heard. Skips when the voice the
    /// refusal was measured in is not installed.
    @MainActor
    func testARenderHandsTheSynthesizerTheTextGuarded() throws {
        let voice = try SpeechMarkupGuardTests.probeVoice()
        let engine = AudioEngineService()
        defer { engine.discardRenderedAudio() }
        let request = SpeechRenderRequest(text: SpeechMarkupGuardTests.chunkAfterOpeningTag, voice: voice)

        let installed = renderThroughTheQueue(request, into: engine)

        XCTAssertEqual(installed, true, "the guarded render did not install audio")
        XCTAssertTrue(engine.hasRenderedAudio)
        XCTAssertEqual(engine.renderedSignature, request.signature)
        XCTAssertFalse(engine.isRendering)
    }

    /// A render the engine refuses, handed the raw chunk through the test
    /// hook in place of the guard, is reported at once as failed and logged
    /// `RENDER_REFUSED`, with nothing installed and the engine no longer
    /// rendering, instead of holding the render queue for two minutes.
    /// Rendered offline: nothing is heard. Skips when the voice is not
    /// installed, or when the engine on this Mac does not refuse the chunk.
    @MainActor
    func testARefusedRenderIsReportedAtOnce() throws {
        let voice = try SpeechMarkupGuardTests.probeVoice()
        try TextMouthPaths.ensureDirectoryStructure()
        let engine = AudioEngineService()
        defer { engine.discardRenderedAudio() }
        // The raw text, as the synthesizer saw it before the guard.
        engine._spokenTextForTesting = { $0 }
        let request = SpeechRenderRequest(text: SpeechMarkupGuardTests.chunkAfterOpeningTag, voice: voice)

        let began = Date()
        var installed: Bool?
        let lines = logLines(in: .speechTransitions) {
            installed = renderThroughTheQueue(request, into: engine, timeout: 20)
        }
        let seconds = Date().timeIntervalSince(began)

        if installed == true {
            throw XCTSkip("The engine on this Mac rendered the raw chunk; there is no refusal to report")
        }
        XCTAssertEqual(installed, false, "the refused render never reported")
        XCTAssertLessThan(seconds, 15, "the refusal took \(seconds) s to report")
        XCTAssertFalse(engine.hasRenderedAudio)
        XCTAssertFalse(engine.isRendering)
        XCTAssertTrue(lines.contains { $0.contains("RENDER_REFUSED:") && $0.contains("after 0 frames") }, "\(lines)")
    }

    /// A render cancelled by the engine wakes the render queue's wait
    /// without a sound: the observer signals the semaphore it was given and
    /// remembers the cancel.
    func testTheCancellationObserverWakesTheWait() {
        let semaphore = DispatchSemaphore(value: 0)
        let observer = RenderCancellationObserver(waking: semaphore)
        XCTAssertFalse(observer.wasCancelled)

        observer.speechSynthesizer(AVSpeechSynthesizer(), didCancel: AVSpeechUtterance(string: "x"))

        XCTAssertEqual(semaphore.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(observer.wasCancelled)
    }

    /// Render `request` into `engine` in its turn on the app's render
    /// queue, as speech does, and return whether the render installed audio
    /// within `timeout` seconds, or nil when it did not report by then.
    @MainActor
    private func renderThroughTheQueue(
        _ request: SpeechRenderRequest,
        into engine: AudioEngineService,
        timeout: TimeInterval = 15
    ) -> Bool? {
        let outcome = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        SpeechRenderCoordinator.shared.render(
            request,
            engine: engine,
            shouldStart: { true },
            completion: { success in outcome.withLock { $0 = success } }
        )
        _ = eventually(within: timeout) { outcome.withLock { $0 } != nil }
        return outcome.withLock { $0 }
    }

    // MARK: - Memory Benchmark

    /// The environment variable that asks for the rendered speech benchmark.
    private static let renderBenchmarkVariable = "TEXTMOUTH_RENDER_BENCHMARK"

    /// What rendered speech costs in memory and main-thread time (TODO
    /// PERF04): rendering a 40,000-unit chapter, the 90th percentile of the
    /// developer's library, then starting it halfway through, as a resume
    /// or a seek from direct speech does, and seeking within it while it
    /// plays. One line beginning `PERF04_BENCHMARK` carries the numbers as
    /// JSON, so runs before and after a change can be compared.
    ///
    /// Opt-in, since the system's synthesizer takes about half a minute to
    /// render the chapter: set TEXTMOUTH_RENDER_BENCHMARK=1, or for
    /// xcodebuild TEST_RUNNER_TEXTMOUTH_RENDER_BENCHMARK=1, which it hands
    /// to the test host without its prefix. Nothing is heard: the render
    /// goes through `write()`, which plays nothing, and the engine plays at
    /// volume 0. The render's completion only sets a flag the test polls,
    /// so one arriving after a timeout can do no harm.
    @MainActor
    func testRenderedSpeechMemoryBenchmark() throws {
        guard ProcessInfo.processInfo.environment[Self.renderBenchmarkVariable] == "1" else {
            throw XCTSkip(
                "Set \(Self.renderBenchmarkVariable)=1 (for xcodebuild, TEST_RUNNER_\(Self.renderBenchmarkVariable)=1) "
                    + "to measure a 40,000-unit render"
            )
        }
        let text = Self.benchmarkProse(utf16Length: 40_000)
        let voice = AVSpeechSynthesisVoice(identifier: "com.apple.voice.compact.en-US.Samantha")
            ?? AVSpeechSynthesisVoice(language: "en-US")
        let engine = AudioEngineService()
        engine.setVolume(0)
        defer { engine.discardRenderedAudio() }

        // The render: its highest memory, sampled while the render queue
        // works, and what it keeps once installed.
        let beforeRender = ProcessMemory.now()
        let peak = OSAllocatedUnfairLock(initialState: beforeRender)
        let sampler = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { _ in
            let now = ProcessMemory.now()
            peak.withLock { $0 = $0.highest(with: now) }
        }
        // Whether the render succeeded, once its completion has run.
        let outcome = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        let (finished, renderMilliseconds) = Self.timed {
            engine.render(SpeechRenderRequest(text: text, voice: voice)) { success in
                outcome.withLock { $0 = success }
            }
            return eventually(within: 300) { outcome.withLock { $0 } != nil }
        }
        sampler.invalidate()
        spinMainRunLoop(for: 0.5)
        let afterRender = ProcessMemory.now()
        let renderPeak = peak.withLock { $0 }.highest(with: afterRender)
        XCTAssertTrue(finished, "The render did not finish in time")
        XCTAssertEqual(outcome.withLock { $0 }, true, "The system synthesizer did not render the benchmark text")
        XCTAssertTrue(engine.hasRenderedAudio)

        // Starting halfway through the chapter, then seeking while it plays.
        let (_, playMilliseconds) = Self.timed { engine.play(fromCharOffset: 20_000) }
        let afterPlay = ProcessMemory.now()
        XCTAssertTrue(engine.isPlaying, "The rendered chapter did not start")
        spinMainRunLoop(for: 0.3)
        let beforeSeek = ProcessMemory.now()
        let (_, seekMilliseconds) = Self.timed { engine.seek(toCharOffset: 30_000) }
        let afterSeek = ProcessMemory.now()
        spinMainRunLoop(for: 0.3)
        let settledAfterSeek = ProcessMemory.now()
        let scheduledBytesAfterSeek = engine.scheduledSegmentAudioByteCount
        engine.stop()

        let renderedBytes = engine.renderedAudioByteCount
        let renderedSeconds = engine.renderedDuration
        engine.discardRenderedAudio()
        spinMainRunLoop(for: 0.5)
        let afterDiscard = ProcessMemory.now()

        let report: [String: Any] = [
            "textUTF16": text.utf16.count,
            "renderMilliseconds": Self.rounded(renderMilliseconds),
            "renderedSeconds": Self.rounded(renderedSeconds),
            "renderedAudioMB": Self.megabytes(Int64(renderedBytes)),
            "renderedBytesPerUTF16Unit": Self.rounded(Double(renderedBytes) / Double(text.utf16.count)),
            "renderPeakMallocMB": Self.megabytes(renderPeak.mallocInUse - beforeRender.mallocInUse),
            "renderPeakFootprintMB": Self.megabytes(renderPeak.footprint - beforeRender.footprint),
            "renderKeptMallocMB": Self.megabytes(afterRender.mallocInUse - beforeRender.mallocInUse),
            "renderKeptFootprintMB": Self.megabytes(afterRender.footprint - beforeRender.footprint),
            "renderKeptResidentMB": Self.megabytes(afterRender.resident - beforeRender.resident),
            "playFromMiddleMilliseconds": Self.rounded(playMilliseconds),
            "playFromMiddleMallocMB": Self.megabytes(afterPlay.mallocInUse - afterRender.mallocInUse),
            "seekMilliseconds": Self.rounded(seekMilliseconds),
            "seekMallocMB": Self.megabytes(afterSeek.mallocInUse - beforeSeek.mallocInUse),
            "playingAfterSeekMallocMB": Self.megabytes(settledAfterSeek.mallocInUse - beforeRender.mallocInUse),
            "playingAfterSeekFootprintMB": Self.megabytes(settledAfterSeek.footprint - beforeRender.footprint),
            "scheduledAudioMBAfterSeek": Self.megabytes(Int64(scheduledBytesAfterSeek)),
            "afterDiscardMallocMB": Self.megabytes(afterDiscard.mallocInUse - beforeRender.mallocInUse),
        ]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("PERF04_BENCHMARK \(String(decoding: json, as: UTF8.self))")
    }

    /// `length` UTF-16 units of plain prose, the same in every run:
    /// sentences of everyday words, which the synthesizer speaks at an
    /// ordinary pace. Every character is ASCII, one unit each.
    private static func benchmarkProse(utf16Length length: Int) -> String {
        let words = [
            "the", "parcel", "came", "on", "a", "wet", "tuesday", "and", "nobody", "in", "flat",
            "could", "read", "its", "smudged", "address", "so", "it", "waited", "by", "kettle",
            "until", "evening", "when", "someone", "finally", "cut", "string", "with", "bread",
            "knife", "found", "inside", "three", "postcards", "from", "harbour", "town", "nobody",
            "remembered", "visiting", "each", "signed", "different", "name",
        ]
        // A fixed linear congruential sequence: the same prose every run.
        var state: UInt64 = 2_026
        func nextIndex(below bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        var text = ""
        while text.utf8.count < length {
            let sentence = (0..<(6 + nextIndex(below: 12))).map { _ in words[nextIndex(below: words.count)] }
            text += sentence.joined(separator: " ").capitalizedFirstLetter + ". "
        }
        return String(text.prefix(length))
    }

    /// Runs `body`, returning its result and how many milliseconds it took.
    private static func timed<T>(_ body: () throws -> T) rethrows -> (T, Double) {
        let start = ContinuousClock.now
        let value = try body()
        let elapsed = start.duration(to: .now)
        let milliseconds = Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1e15
        return (value, milliseconds)
    }

    /// `bytes` in megabytes, to one decimal place.
    private static func megabytes(_ bytes: Int64) -> Double {
        rounded(Double(bytes) / 1_048_576, places: 1)
    }

    /// `value` to `places` decimal places, for a report a person reads.
    private static func rounded(_ value: Double, places: Int = 2) -> Double {
        let scale = pow(10, Double(places))
        return (value * scale).rounded() / scale
    }
}

/// The slices an engine reports scheduling, kept under a lock, since the
/// player node's own thread reports most of them.
private final class SliceLog: Sendable {
    private let slices = OSAllocatedUnfairLock<[ScheduledSpeechSlice]>(initialState: [])

    /// Every slice reported so far, in order.
    var all: [ScheduledSpeechSlice] {
        slices.withLock { $0 }
    }

    /// Keep `slice`.
    func append(_ slice: ScheduledSpeechSlice) {
        slices.withLock { $0.append(slice) }
    }

    /// Forget every slice reported so far.
    func removeAll() {
        slices.withLock { $0.removeAll() }
    }
}

/// The process's memory, three ways: what the program has allocated with
/// malloc and not freed, across every zone; the physical footprint, which
/// Activity Monitor shows as Memory and by which memory pressure is
/// judged; and the resident size.
private struct ProcessMemory: Sendable {
    /// Bytes allocated with malloc and not yet freed.
    let mallocInUse: Int64
    /// The physical footprint, in bytes.
    let footprint: Int64
    /// The resident size, in bytes.
    let resident: Int64

    /// The memory now. A figure the kernel does not give is 0.
    static func now() -> ProcessMemory {
        var statistics = malloc_statistics_t()
        // A nil zone sums every zone's statistics.
        malloc_zone_statistics(nil, &statistics)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        let succeeded = result == KERN_SUCCESS
        return ProcessMemory(
            mallocInUse: Int64(statistics.size_in_use),
            footprint: succeeded ? Int64(info.phys_footprint) : 0,
            resident: succeeded ? Int64(info.resident_size) : 0
        )
    }

    /// The higher of each figure here and in `other`: a running peak.
    func highest(with other: ProcessMemory) -> ProcessMemory {
        ProcessMemory(
            mallocInUse: max(mallocInUse, other.mallocInUse),
            footprint: max(footprint, other.footprint),
            resident: max(resident, other.resident)
        )
    }
}

private extension String {
    /// The string with its first letter in upper case, the rest unchanged.
    var capitalizedFirstLetter: String {
        prefix(1).uppercased() + dropFirst()
    }
}
