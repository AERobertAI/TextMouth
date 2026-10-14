import os
import XCTest
@testable import TextMouth

/// Sound effects play on a serial queue of their own, so the main thread
/// never waits for the system's audio, and a play that never returns holds
/// back only later sounds, which are dropped and logged once (B07). On
/// October 14, 2026 the pause sound's play blocked the main thread for good
/// behind a decoder stuck in AudioToolbox, and froze TextMouth's window.
///
/// Nothing here plays aloud: every service plays through
/// `HeldSoundEffectPlayer`, which records each sound and can be held inside
/// its play, as the system's player was held that day.
@MainActor
final class SoundEffectPlaybackTests: XCTestCase {
    /// The tag of the line logged for the first sound dropped behind a play
    /// that has not returned.
    private static let stuckTag = "SOUND_EFFECT_STUCK"

    // MARK: - Off the Main Thread

    /// A sound is handed over and played on the sound queue: asking for it
    /// returns at once although its play has not returned.
    func testASoundPlaysOffTheMainThreadAndTheAskReturnsAtOnce() throws {
        let player = HeldSoundEffectPlayer(holding: true)
        defer { player.release() }
        let sounds = makeSounds("sound-effects-off-main", playingThrough: player)

        let asked = ProcessInfo.processInfo.systemUptime
        sounds.play(for: .pause)
        let askTook = ProcessInfo.processInfo.systemUptime - asked

        XCTAssertLessThan(askTook, 0.5, "asking for a sound waited for its play")
        XCTAssertTrue(eventually { player.begun.count == 1 }, "the sound never began")
        let begun = try XCTUnwrap(player.begun.first)
        XCTAssertFalse(begun.onMainThread, "the sound played on the main thread")
        XCTAssertEqual(begun.url, SoundEffectService.soundFile(named: "Tink"))
        XCTAssertTrue(sounds.isPlayUnderWay)
    }

    // MARK: - A Play That Does Not Return

    /// While a sound's play has not returned, later sounds are dropped, not
    /// queued behind it, and only the first one dropped is logged.
    func testSoundsAskedForWhileAPlayHasNotReturnedAreDroppedAndLoggedOnce() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let player = HeldSoundEffectPlayer(holding: true)
        defer { player.release() }
        let sounds = makeSounds("sound-effects-stuck", playingThrough: player)

        let lines = logLines(in: .debug) {
            sounds.play(for: .pause)
            XCTAssertTrue(eventually { player.begun.count == 1 }, "the first sound never began")
            sounds.play(for: .play)
            sounds.play(for: .skipForward)
            sounds.previewSound("Funk")
        }

        let stuckLines = lines.filter { $0.contains(Self.stuckTag) }
        XCTAssertEqual(stuckLines.count, 1, "\(lines)")
        XCTAssertTrue(stuckLines.first?.contains("dropped the Play sound") == true, "\(stuckLines)")

        // Released, the held play returns, and nothing queued behind it
        // follows.
        player.release()
        XCTAssertTrue(eventually { !sounds.isPlayUnderWay }, "the held play never returned")
        spinMainRunLoop(for: 0.2)
        XCTAssertEqual(player.begun.count, 1, "a dropped sound was queued and played later")
    }

    /// Once the stuck play returns, sounds play again, and a later stuck
    /// play is logged again.
    func testSoundsPlayAgainOnceTheStuckPlayReturns() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let player = HeldSoundEffectPlayer(holding: true)
        defer { player.release() }
        let sounds = makeSounds("sound-effects-play-again", playingThrough: player)
        sounds.play(for: .pause)
        XCTAssertTrue(eventually { player.begun.count == 1 })
        sounds.play(for: .play)

        player.release()
        XCTAssertTrue(eventually { !sounds.isPlayUnderWay }, "the held play never returned")
        sounds.play(for: .skipBackward)

        XCTAssertTrue(eventually { player.begun.count == 2 }, "no sound played after the stuck one returned")
        XCTAssertEqual(player.begun.last?.url, SoundEffectService.soundFile(named: "Tink"))
    }

    // MARK: - Which Sounds Play, and How Loud

    /// The queue changes nothing else: each event plays the sound the
    /// settings assign it at the volume they set, None and sounds turned off
    /// play nothing, and a preview plays whether or not sounds are on.
    func testEachSoundPlaysAsTheSettingsSay() {
        let player = HeldSoundEffectPlayer(holding: false)
        let sounds = makeSounds("sound-effects-settings", playingThrough: player)
        sounds.volume = 0.3
        sounds.assignments[.play] = "Glass"
        sounds.assignments[.pause] = "None"

        sounds.play(for: .play)
        XCTAssertTrue(eventually { player.begun.count == 1 && !sounds.isPlayUnderWay })
        sounds.play(for: .pause)
        sounds.soundsEnabled = false
        sounds.play(for: .skipForward)
        sounds.previewSound("Funk")
        XCTAssertTrue(eventually { player.begun.count == 2 && !sounds.isPlayUnderWay })
        spinMainRunLoop(for: 0.2)

        XCTAssertEqual(player.begun.map(\.url.path), ["/System/Library/Sounds/Glass.aiff", "/System/Library/Sounds/Funk.aiff"])
        XCTAssertEqual(player.begun.map(\.volume), [0.3, 0.3])
    }

    /// A sound with no file of that name plays nothing, and holds back
    /// nothing.
    func testASoundWithNoFilePlaysNothing() {
        let player = HeldSoundEffectPlayer(holding: false)
        let sounds = makeSounds("sound-effects-no-file", playingThrough: player)

        sounds.previewSound("No Such Sound \(UUID().uuidString)")

        XCTAssertFalse(sounds.isPlayUnderWay)
        spinMainRunLoop(for: 0.1)
        XCTAssertEqual(player.begun.count, 0)
    }

    // MARK: - The Gate

    /// The gate lets one play through at a time, drops every sound asked
    /// for meanwhile, reporting only the first, and opens again once the
    /// play returns.
    func testTheGateLetsOnePlayThroughAndDropsTheRestUntilItReturns() {
        var gate = SoundEffectGate()

        XCTAssertEqual(gate.ask(at: 100), .play)
        XCTAssertEqual(gate.ask(at: 101.5), .drop(seconds: 1.5, isFirstDrop: true))
        XCTAssertEqual(gate.ask(at: 107), .drop(seconds: 7, isFirstDrop: false))
        gate.playReturned()
        XCTAssertEqual(gate.ask(at: 110), .play)
        XCTAssertEqual(gate.ask(at: 110.25), .drop(seconds: 0.25, isFirstDrop: true))
    }

    // MARK: - Helpers

    /// A sound effect service with sandboxed preferences, playing through
    /// `player`.
    private func makeSounds(_ label: String, playingThrough player: HeldSoundEffectPlayer) -> SoundEffectService {
        SoundEffectService(preferences: makeSandboxedPreferences(label), player: player)
    }
}

// MARK: - A Player That Plays Nothing Aloud

/// Records each sound handed to it, and plays nothing aloud. While held, its
/// play does not return, as the system's did on October 14, 2026, until the
/// test releases it (thirty seconds at most, so a failed test never leaves
/// its queue held).
///
/// It runs on a serial queue of its own, as the system's player does, so a
/// held play blocks that queue's thread, never one of Swift's cooperative
/// threads.
actor HeldSoundEffectPlayer: SoundEffectPlaying {
    /// A sound handed over: its file, its volume, and whether it began on
    /// the main thread.
    struct Begun: Sendable {
        let url: URL
        let volume: Float
        let onMainThread: Bool
    }

    /// The queue the player's plays run on.
    private let queue = DispatchSerialQueue(label: "TextMouthTests.heldSoundEffects")

    /// Runs the actor's work on `queue`.
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// The sounds begun, oldest first, readable while a play is held.
    private let begunSounds = OSAllocatedUnfairLock<[Begun]>(initialState: [])
    /// Whether plays are held.
    private let isHolding: OSAllocatedUnfairLock<Bool>
    /// Signalled to let a held play return.
    private let releaseSignal = DispatchSemaphore(value: 0)

    /// A player whose plays are held when `holding` is true.
    init(holding: Bool) {
        isHolding = OSAllocatedUnfairLock(initialState: holding)
    }

    /// The sounds begun, oldest first.
    nonisolated var begun: [Begun] {
        begunSounds.withLock { $0 }
    }

    func play(contentsOf url: URL, volume: Float) {
        begunSounds.withLock { $0.append(Begun(url: url, volume: volume, onMainThread: Thread.isMainThread)) }
        if isHolding.withLock({ $0 }) {
            _ = releaseSignal.wait(timeout: .now() + 30)
        }
    }

    /// Stop holding plays, and let a held one return. Called more than once,
    /// it changes nothing more.
    nonisolated func release() {
        let wasHolding = isHolding.withLock { holding in
            defer { holding = false }
            return holding
        }
        if wasHolding {
            releaseSignal.signal()
        }
    }
}
