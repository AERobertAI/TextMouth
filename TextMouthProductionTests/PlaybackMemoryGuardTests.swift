import os
import XCTest
@testable import TextMouth

/// The guard on TextMouth's memory while anything plays (B07): at the first
/// ceiling playback stops and the listener is told why; at the second,
/// reached afterwards or at once, everything is saved, a marker is left,
/// and TextMouth quits, asking nothing; the next launch tells the listener.
///
/// Nothing here runs away, and nothing quits: every guard reads a footprint
/// the test sets (`FootprintDial`) and records what it would do
/// (`GuardActions`). Readers are stand-ins (`StandInReader`), except where
/// a real reader plays a short silent book to be stopped.
@MainActor
final class PlaybackMemoryGuardTests: XCTestCase {
    /// A gigabyte of 1,024 megabytes.
    private static let gigabyte: UInt64 = 1 << 30

    // MARK: - The Ceilings

    /// The ceilings are 3 GB and 6 GB, far above TextMouth's own footprint.
    func testTheCeilingsAreThreeAndSixGigabytes() {
        XCTAssertEqual(MemoryGuardPolicy.stopCeiling, 3 * Self.gigabyte)
        XCTAssertEqual(MemoryGuardPolicy.quitCeiling, 6 * Self.gigabyte)
    }

    /// Below the first ceiling nothing happens. At it, playback stops, once
    /// for each runaway; the second ceiling, reached afterwards with nothing
    /// playing, or at once while something plays, saves and quits. A
    /// footprint back below the first ceiling ends the runaway, and the
    /// second ceiling quits even then, with nothing playing.
    func testThePolicyStopsAtTheFirstCeilingAndQuitsAtTheSecond() {
        var policy = MemoryGuardPolicy()
        let gb = Self.gigabyte

        XCTAssertEqual(policy.act(onFootprint: 2 * gb, isAnythingPlaying: true), .none)
        XCTAssertEqual(policy.act(onFootprint: 3 * gb, isAnythingPlaying: true), .stopPlayback(footprint: 3 * gb))
        XCTAssertTrue(policy.isWatching(whileAnythingPlays: false), "The guard stopped watching a runaway")
        XCTAssertEqual(policy.act(onFootprint: 4 * gb, isAnythingPlaying: false), .none)
        XCTAssertEqual(policy.act(onFootprint: 6 * gb, isAnythingPlaying: false), .saveAndQuit(footprint: 6 * gb))

        var fallen = MemoryGuardPolicy()
        _ = fallen.act(onFootprint: 4 * gb, isAnythingPlaying: true)
        XCTAssertEqual(fallen.act(onFootprint: 1 * gb, isAnythingPlaying: false), .none)
        // At 1 GB the guard still reads at the short wait; once the footprint
        // is well below it, at the long one.
        XCTAssertTrue(fallen.isWatching(whileAnythingPlays: false), "A footprint at 1 GB was not watched closely")
        XCTAssertEqual(fallen.act(onFootprint: gb / 2, isAnythingPlaying: false), .none)
        XCTAssertFalse(fallen.isWatching(whileAnythingPlays: false), "A runaway that ended was still watched closely")
        XCTAssertEqual(fallen.act(onFootprint: 7 * gb, isAnythingPlaying: false), .saveAndQuit(footprint: 7 * gb), "Nothing played, and it did not quit")

        var atOnce = MemoryGuardPolicy()
        XCTAssertEqual(atOnce.act(onFootprint: 7 * gb, isAnythingPlaying: true), .saveAndQuit(footprint: 7 * gb))
    }

    /// The quit ceiling quits with nothing playing, before any stop, after
    /// one, and at once; the stop ceiling does not stop with nothing playing.
    func testTheQuitCeilingActsWhetherOrNotAnythingPlays() {
        let gb = Self.gigabyte
        var fresh = MemoryGuardPolicy()
        XCTAssertEqual(fresh.act(onFootprint: 6 * gb, isAnythingPlaying: false), .saveAndQuit(footprint: 6 * gb))

        var stopped = MemoryGuardPolicy()
        XCTAssertEqual(stopped.act(onFootprint: 4 * gb, isAnythingPlaying: true), .stopPlayback(footprint: 4 * gb))
        XCTAssertEqual(stopped.act(onFootprint: 8 * gb, isAnythingPlaying: false), .saveAndQuit(footprint: 8 * gb))

        var idle = MemoryGuardPolicy()
        XCTAssertEqual(idle.act(onFootprint: 3 * gb, isAnythingPlaying: false), .none, "Nothing played, yet it stopped")
        XCTAssertEqual(idle.act(onFootprint: 5 * gb, isAnythingPlaying: false), .none)
        XCTAssertFalse(idle.hasStoppedPlayback, "A stop was recorded with nothing to stop")
        XCTAssertEqual(idle.act(onFootprint: 6 * gb, isAnythingPlaying: false), .saveAndQuit(footprint: 6 * gb))
    }

    /// The wait is 5 seconds while anything plays, while a runaway goes on,
    /// and at 1 GB and above; 30 seconds otherwise, and again once the
    /// footprint falls back.
    func testTheWaitIsShortWhenWatchingCloselyAndLongOtherwise() {
        let gb = Self.gigabyte
        XCTAssertEqual(MemoryGuardPolicy.watchCloselyFootprint, gb)
        func wait(_ policy: MemoryGuardPolicy, playing: Bool) -> TimeInterval {
            policy.readWait(whileAnythingPlays: playing, readInterval: 5, idleReadInterval: 30)
        }

        var policy = MemoryGuardPolicy()
        XCTAssertEqual(wait(policy, playing: false), 30, "Before any reading")
        XCTAssertEqual(wait(policy, playing: true), 5, "Playing")

        _ = policy.act(onFootprint: 100 << 20, isAnythingPlaying: false)
        XCTAssertEqual(wait(policy, playing: false), 30, "Idle and small")
        XCTAssertEqual(wait(policy, playing: true), 5, "Playing and small")

        _ = policy.act(onFootprint: gb - 1, isAnythingPlaying: false)
        XCTAssertEqual(wait(policy, playing: false), 30, "Just below 1 GB")
        _ = policy.act(onFootprint: gb, isAnythingPlaying: false)
        XCTAssertEqual(wait(policy, playing: false), 5, "At 1 GB")
        _ = policy.act(onFootprint: 2 * gb, isAnythingPlaying: false)
        XCTAssertEqual(wait(policy, playing: false), 5, "Above 1 GB")

        _ = policy.act(onFootprint: 100 << 20, isAnythingPlaying: false)
        XCTAssertEqual(wait(policy, playing: false), 30, "Back down")

        // A runaway playback was stopped for goes on at the short wait; it
        // ends when the footprint falls back.
        var runaway = MemoryGuardPolicy()
        _ = runaway.act(onFootprint: 4 * gb, isAnythingPlaying: true)
        XCTAssertEqual(wait(runaway, playing: false), 5, "A runaway under way")
        _ = runaway.act(onFootprint: 100 << 20, isAnythingPlaying: false)
        XCTAssertEqual(wait(runaway, playing: false), 30, "A runaway that ended")
    }

    // MARK: - The Footprint

    /// The footprint read is TextMouth's own: some megabytes, far below the
    /// first ceiling, in the test host as in the app.
    func testTheFootprintReadIsTextMouthsOwn() throws {
        let footprint = try XCTUnwrap(MemoryFootprint.current())
        print("PLAYBACK_MEMORY_GUARD_MEASURE: test host footprint \(footprint / (1 << 20)) MB")
        XCTAssertGreaterThan(footprint, 10 << 20)
        XCTAssertLessThan(footprint, MemoryGuardPolicy.stopCeiling)
        XCTAssertEqual(MemoryFootprint.gigabytes(6 * Self.gigabyte + Self.gigabyte / 10), "6.1")
    }

    // MARK: - The Guard

    /// At the first ceiling the guard stops every open reader that plays,
    /// and logs the footprint; a reader paused or closed is left alone.
    func testTheFirstCeilingStopsEveryReaderThatPlays() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let (memoryGuard, dial, actions) = makeGuard()
        let playing = StandInReader(title: "Tide Tables")
        let paused = StandInReader(title: "Ferry Timetables")
        let closed = StandInReader(title: "Lock Keeping", hasClosed: true)
        memoryGuard.reader(playing, isPlaying: true, title: playing.title)
        memoryGuard.reader(paused, isPlaying: false, title: paused.title)
        memoryGuard.reader(closed, isPlaying: true, title: closed.title)

        let lines = logLines(in: .debug) {
            dial.set(2 * Self.gigabyte)
            memoryGuard.readNow()
            spinMainRunLoop(for: 0.1)
            dial.set(3 * Self.gigabyte + 1)
            memoryGuard.readNow()
            XCTAssertTrue(eventually { !playing.stops.isEmpty }, "The playing reader was never stopped")
        }

        XCTAssertEqual(playing.stops, [3 * Self.gigabyte + 1])
        XCTAssertEqual(paused.stops, [], "A paused reader was stopped")
        XCTAssertEqual(closed.stops, [], "A closed reader was stopped")
        XCTAssertEqual(actions.recorded, [])
        let runaway = lines.filter { $0.contains("AUDIO_MEMORY_RUNAWAY: footprint=\(3 * Self.gigabyte + 1) bytes") }
        XCTAssertEqual(runaway.count, 1, "\(lines)")
    }

    /// Reaching the second ceiling after playback stopped, nothing playing,
    /// the guard leaves a marker naming the book, saves every open reader's
    /// place and the pending writes, and quits from the main thread; should
    /// that not end TextMouth, it quits from its own queue.
    func testTheSecondCeilingAfterTheStopSavesEverythingAndQuits() throws {
        let (memoryGuard, dial, actions) = makeGuard()
        let playing = StandInReader(title: "Tide Tables")
        let paused = StandInReader(title: "Ferry Timetables")
        let closed = StandInReader(title: "Lock Keeping", hasClosed: true)
        memoryGuard.reader(playing, isPlaying: true, title: playing.title)
        memoryGuard.reader(paused, isPlaying: false, title: paused.title)
        memoryGuard.reader(closed, isPlaying: false, title: closed.title)
        dial.set(3 * Self.gigabyte)
        memoryGuard.readNow()
        XCTAssertTrue(eventually { !playing.stops.isEmpty })
        memoryGuard.reader(playing, isPlaying: false, title: playing.title)

        dial.set(6 * Self.gigabyte)
        memoryGuard.readNow()

        XCTAssertTrue(eventually { actions.recorded.contains(.quitFromAnyThread) }, "\(actions.recorded)")
        XCTAssertEqual(actions.recorded, [
            .marker(MemoryQuitMarker(date: Self.quitDate, footprint: 6 * Self.gigabyte, bookTitle: "Tide Tables")),
            .savePendingWrites,
            .quit,
            .quitFromAnyThread,
        ])
        XCTAssertEqual(playing.saves, 1)
        XCTAssertEqual(paused.saves, 1)
        XCTAssertEqual(closed.saves, 0, "A closed reader was saved")
        XCTAssertTrue(memoryGuard.isQuittingToProtectTheMac)
        XCTAssertFalse(PlaybackMemoryGuard.shared.isQuittingToProtectTheMac)

        // Quitting, it reads no more.
        dial.set(9 * Self.gigabyte)
        memoryGuard.readNow()
        spinMainRunLoop(for: 0.2)
        XCTAssertEqual(actions.recorded.count, 4)
    }

    /// The second ceiling reached at once, while a book plays, saves and
    /// quits without stopping first.
    func testTheSecondCeilingReachedAtOnceSavesAndQuits() {
        let (memoryGuard, dial, actions) = makeGuard()
        let playing = StandInReader(title: "Tide Tables")
        memoryGuard.reader(playing, isPlaying: true, title: playing.title)

        dial.set(7 * Self.gigabyte)
        memoryGuard.readNow()

        XCTAssertTrue(eventually { actions.recorded.contains(.quit) }, "\(actions.recorded)")
        XCTAssertEqual(playing.stops, [])
        XCTAssertEqual(playing.saves, 1)
        XCTAssertEqual(actions.recorded.first, .marker(MemoryQuitMarker(
            date: Self.quitDate, footprint: 7 * Self.gigabyte, bookTitle: "Tide Tables"
        )))
    }

    /// Nothing playing, below the quit ceiling the guard does nothing (no
    /// stop, with nothing to stop); at the quit ceiling it saves and quits.
    /// The app's own guard watches nothing in the test host.
    func testNothingPlayingOnlyTheQuitCeilingActs() {
        let (memoryGuard, dial, actions) = makeGuard()
        let paused = StandInReader(title: "Ferry Timetables")
        memoryGuard.reader(paused, isPlaying: false, title: paused.title)

        dial.set(3 * Self.gigabyte)
        memoryGuard.readNow()
        spinMainRunLoop(for: 0.2)
        XCTAssertEqual(paused.stops, [])
        XCTAssertEqual(actions.recorded, [])

        dial.set(7 * Self.gigabyte)
        memoryGuard.readNow()
        XCTAssertTrue(eventually { actions.recorded.contains(.quit) }, "\(actions.recorded)")

        XCTAssertEqual(paused.stops, [])
        XCTAssertEqual(paused.saves, 1)
        XCTAssertFalse(PlaybackMemoryGuard.shared.isEnabled, "The app's guard watches the test host")
    }

    /// A reader that played and then paused, or stopped, under 1 GB, then a
    /// runaway while nothing plays: the guard still reads and quits, and the
    /// marker says nothing was playing.
    func testARunawayAfterThePlayerPausedStillQuits() {
        let (memoryGuard, dial, actions) = makeGuard()
        let reader = StandInReader(title: "Tide Tables")
        memoryGuard.reader(reader, isPlaying: true, title: reader.title)
        dial.set(100 << 20)
        memoryGuard.readNow()
        memoryGuard.reader(reader, isPlaying: false, title: reader.title)

        dial.set(6 * Self.gigabyte)
        memoryGuard.readNow()

        XCTAssertTrue(eventually { actions.recorded.contains(.quit) }, "\(actions.recorded)")
        XCTAssertEqual(reader.stops, [])
        XCTAssertEqual(reader.saves, 1)
        XCTAssertEqual(actions.recorded.first, .marker(MemoryQuitMarker(
            date: Self.quitDate, footprint: 6 * Self.gigabyte, bookTitle: "Tide Tables", wasNothingPlaying: true
        )))
    }

    /// A guard that never saw a reader quits at 7 GB, its marker without a
    /// book and with the idle flag.
    func testAGuardThatNeverSawAReaderQuitsAtTheQuitCeiling() {
        let (memoryGuard, dial, actions) = makeGuard()

        dial.set(7 * Self.gigabyte)
        memoryGuard.readNow()

        XCTAssertTrue(eventually { actions.recorded.contains(.quit) }, "\(actions.recorded)")
        XCTAssertEqual(actions.recorded.first, .marker(MemoryQuitMarker(
            date: Self.quitDate, footprint: 7 * Self.gigabyte, bookTitle: nil, wasNothingPlaying: true
        )))
        XCTAssertTrue(memoryGuard.isQuittingToProtectTheMac)
    }

    /// The marker of a quit while a book plays does not carry the idle flag.
    func testAPlayingQuitsMarkerDoesNotCarryTheIdleFlag() {
        let (memoryGuard, dial, actions) = makeGuard()
        let playing = StandInReader(title: "Tide Tables")
        memoryGuard.reader(playing, isPlaying: true, title: playing.title)

        dial.set(7 * Self.gigabyte)
        memoryGuard.readNow()

        XCTAssertTrue(eventually { actions.recorded.contains(.quit) }, "\(actions.recorded)")
        guard case .marker(let marker)? = actions.recorded.first else {
            return XCTFail("No marker was written: \(actions.recorded)")
        }
        XCTAssertFalse(marker.wasNothingPlaying)
    }

    // MARK: - The Loop

    /// A begun guard reads on its own with nothing ever playing, begun twice
    /// it still runs one loop, and it quits at the quit ceiling and reads no
    /// more afterwards.
    func testABegunGuardReadsWithNothingPlayingAndStopsAfterTheQuit() {
        let (memoryGuard, dial, actions) = makeGuard(readInterval: 0.05, idleReadInterval: 0.05)
        memoryGuard.beginWatching()
        memoryGuard.beginWatching()
        XCTAssertTrue(eventually { dial.reads >= 3 }, "The guard never read on its own")
        XCTAssertEqual(actions.recorded, [], "It acted below the ceilings")

        dial.set(7 * Self.gigabyte)

        XCTAssertTrue(eventually { actions.recorded.contains(.quit) }, "\(actions.recorded)")
        let readsAtTheQuit = dial.reads
        spinMainRunLoop(for: 0.4)
        XCTAssertEqual(dial.reads, readsAtTheQuit, "The guard read after it began to quit")
        XCTAssertEqual(actions.recorded.filter { $0 == .quit }.count, 1)
    }

    /// One loop runs, however often the guard is begun: its readings come at
    /// the interval, not several times over.
    func testBeginningTwiceStartsOneLoop() {
        let (memoryGuard, dial, _) = makeGuard(readInterval: 0.2, idleReadInterval: 0.2)
        memoryGuard.beginWatching()
        memoryGuard.beginWatching()
        memoryGuard.beginWatching()

        spinMainRunLoop(for: 0.5)

        // Readings at 0.2 and 0.4 seconds: two, or three at most when the
        // run loop is slow to start; three loops would read about six.
        XCTAssertLessThanOrEqual(dial.reads, 3)
        XCTAssertGreaterThanOrEqual(dial.reads, 1)
    }

    // MARK: - The Marker

    /// The marker is read once, and says when TextMouth quit, how large its
    /// memory grew, and which book played, in these words.
    func testTheMarkerIsReadOnceAndSaysWhatHappened() throws {
        let folder = try AudioTestFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("memory-quit.json")
        let marker = MemoryQuitMarker(date: Self.quitDate, footprint: 6 * Self.gigabyte + Self.gigabyte / 10, bookTitle: "Tide Tables")

        try marker.write(to: url)
        let taken = MemoryQuitMarker.take(from: url)

        XCTAssertEqual(taken, marker)
        XCTAssertNil(MemoryQuitMarker.take(from: url), "The marker was told twice")
        // ICU writes a narrow no-break space before PM; a space here.
        let announcement = marker.announcement(locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC") ?? .gmt)
            .replacingOccurrences(of: "\u{202F}", with: " ")
        XCTAssertEqual(
            announcement,
            "TextMouth quit on October 14, 2026 at 9:03 PM to protect your Mac: its memory grew to 6.1 GB "
                + "while Tide Tables played, because of a fault in macOS's audio. Your place was saved."
        )
        let untitled = MemoryQuitMarker(date: Self.quitDate, footprint: 6 * Self.gigabyte, bookTitle: nil)
        XCTAssertTrue(untitled.announcement().contains("6.0 GB while a book played"))
    }

    /// A quit while nothing played is told in its own words, a marker
    /// written before the flag existed reads as a quit while a book played,
    /// and the flag survives a round trip through the file.
    func testTheMarkerOfAQuitWhileNothingPlayedHasItsOwnWords() throws {
        let marker = MemoryQuitMarker(
            date: Self.quitDate, footprint: 6 * Self.gigabyte + Self.gigabyte / 10, bookTitle: "Tide Tables", wasNothingPlaying: true
        )
        let announcement = marker.announcement(locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC") ?? .gmt)
            .replacingOccurrences(of: "\u{202F}", with: " ")
        XCTAssertEqual(
            announcement,
            "TextMouth quit on October 14, 2026 at 9:03 PM to protect your Mac: its memory grew to 6.1 GB "
                + "while nothing was playing. Your place was saved."
        )

        // A marker file from before the flag has no such key.
        let older = Data("""
        {"date": 782000000, "footprint": 6442450944, "bookTitle": "Tide Tables"}
        """.utf8)
        let decoded = try JSONDecoder().decode(MemoryQuitMarker.self, from: older)
        XCTAssertFalse(decoded.wasNothingPlaying)
        XCTAssertEqual(decoded.bookTitle, "Tide Tables")
        XCTAssertTrue(decoded.announcement().contains("6.0 GB while Tide Tables played, because of a fault in macOS's audio."))

        let folder = try AudioTestFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("memory-quit.json")
        try marker.write(to: url)
        let taken = MemoryQuitMarker.take(from: url)
        XCTAssertEqual(taken, marker)
        XCTAssertEqual(taken?.wasNothingPlaying, true)
    }

    // MARK: - The Reader

    /// A reader the guard stops says why, in these words, its audio stopped
    /// as for any failure and the player let go of off the main thread; and
    /// it tells the guard when it plays.
    func testAPlayingReaderStoppedByTheGuardSaysWhy() throws {
        let gb = Self.gigabyte
        XCTAssertEqual(
            ReaderViewModel.memoryRunawayMessage(footprint: 3 * gb + gb / 5),
            "Playback stopped because TextMouth's memory grew to 3.2 GB while the audio played, "
                + "a fault in macOS's audio."
        )
        let world = try makeIntegrationWorld("Memory Guard Reader")
        let book = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [10])
        let reader = world.openReader(for: book)
        reader.soundEffectService = RecordedSoundEffects()
        waitForReaderToLoad(reader)
        defer { reader.stop() }
        let (memoryGuard, dial, _) = makeGuard()
        let following = reader.followPlaybackForMemoryGuard(memoryGuard)
        defer { following.cancel() }
        let letGoOnMainThread = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        reader.audioPlaybackService._stuckPlayerLetGoForTesting = { onMainThread in
            letGoOnMainThread.withLock { $0 = onMainThread }
        }

        let recorder = try recordingAnnouncements {
            reader.play()
            waitUntilReady(try XCTUnwrap(reader.audioPlaybackService._playerItemForTesting))
            if let footprint = MemoryFootprint.current() {
                print("PLAYBACK_MEMORY_GUARD_MEASURE: test host footprint playing a book \(footprint / (1 << 20)) MB")
            }
            dial.set(3 * gb + gb / 5)
            memoryGuard.readNow()
            XCTAssertTrue(eventually { reader.errorMessage != nil }, "The reader never stopped")
        }

        let message = "Playback stopped because TextMouth's memory grew to 3.2 GB while the audio played, "
            + "a fault in macOS's audio."
        XCTAssertEqual(reader.errorMessage, message)
        XCTAssertEqual(recorder.announcements.map(\.message), [message])
        XCTAssertEqual(reader.audioPlaybackFailure?.reason, .memoryRunaway(footprint: 3 * gb + gb / 5))
        XCTAssertFalse(reader.isCurrentlyPlaying)
        XCTAssertFalse(reader.audioPlaybackService.isPlaying)
        XCTAssertTrue(eventually { letGoOnMainThread.withLock { $0 } != nil }, "The player was never let go of")
        XCTAssertEqual(letGoOnMainThread.withLock { $0 }, false, "The player was let go of on the main thread")
    }

    /// A reader that is not playing is not stopped.
    func testAReaderNotPlayingIsLeftAlone() throws {
        let world = try makeIntegrationWorld("Memory Guard Idle Reader")
        let book = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [2])
        let reader = world.openReader(for: book)
        reader.soundEffectService = RecordedSoundEffects()
        waitForReaderToLoad(reader)

        reader.stopPlaybackForMemoryRunaway(footprint: 4 * Self.gigabyte)

        XCTAssertNil(reader.errorMessage)
        XCTAssertNil(reader.audioPlaybackFailure)
    }

    // MARK: - Helpers

    /// When the guard's clock says the quit happened: October 14, 2026, at
    /// 21:03 UTC.
    private static let quitDate = Date(timeIntervalSince1970: 1_792_011_780)

    /// A guard reading `FootprintDial`'s footprint and recording what it
    /// would do, which never reads on its own (a reading every hour, unless
    /// a loop test gives shorter intervals) and
    /// quits from its queue a moment after the main thread's quit.
    private func makeGuard(
        readInterval: TimeInterval = 3_600,
        idleReadInterval: TimeInterval = 3_600
    ) -> (PlaybackMemoryGuard, FootprintDial, GuardActions) {
        let dial = FootprintDial()
        let actions = GuardActions()
        let quitDate = Self.quitDate
        var environment = PlaybackMemoryGuard.Environment()
        environment.readFootprint = { dial.read() }
        environment.now = { quitDate }
        environment.readInterval = readInterval
        environment.idleReadInterval = idleReadInterval
        environment.quitGrace = 0.2
        environment.writeMarker = { actions.record(.marker($0)) }
        environment.savePendingWrites = { actions.record(.savePendingWrites) }
        environment.quit = { actions.record(.quit) }
        environment.quitFromAnyThread = { actions.record(.quitFromAnyThread) }
        return (PlaybackMemoryGuard(environment: environment), dial, actions)
    }
}

// MARK: - Stand-Ins

/// The footprint a test's guard reads, set by the test.
private final class FootprintDial: Sendable {
    private let footprint = OSAllocatedUnfairLock<UInt64>(initialState: 0)
    private let readCount = OSAllocatedUnfairLock<Int>(initialState: 0)

    /// The footprint now, in bytes.
    var value: UInt64 {
        footprint.withLock { $0 }
    }

    /// Set the footprint to `bytes`.
    func set(_ bytes: UInt64) {
        footprint.withLock { $0 = bytes }
    }

    /// How many times the guard has read the footprint.
    var reads: Int {
        readCount.withLock { $0 }
    }

    /// The footprint now, counted as a reading by the guard.
    func read() -> UInt64 {
        readCount.withLock { $0 += 1 }
        return value
    }
}

/// What a test's guard did, in order, in place of writing, saving, and
/// quitting.
private final class GuardActions: Sendable {
    /// One thing the guard did.
    enum Action: Equatable, Sendable {
        case marker(MemoryQuitMarker)
        case savePendingWrites
        case quit
        case quitFromAnyThread
    }

    private let actions = OSAllocatedUnfairLock<[Action]>(initialState: [])

    /// What the guard did, oldest first.
    var recorded: [Action] {
        actions.withLock { $0 }
    }

    /// Record that the guard did `action`.
    func record(_ action: Action) {
        actions.withLock { $0.append(action) }
    }
}

/// A reader the guard watches, which records what the guard asks of it.
@MainActor
private final class StandInReader: MemoryGuardedReader {
    let readerID = UUID()
    let title: String
    let hasClosed: Bool
    /// The footprints it was stopped for.
    private(set) var stops: [UInt64] = []
    /// How many times its place was saved.
    private(set) var saves = 0

    init(title: String, hasClosed: Bool = false) {
        self.title = title
        self.hasClosed = hasClosed
    }

    func stopPlaybackForMemoryRunaway(footprint: UInt64) {
        stops.append(footprint)
    }

    func savePosition() {
        saves += 1
    }
}
