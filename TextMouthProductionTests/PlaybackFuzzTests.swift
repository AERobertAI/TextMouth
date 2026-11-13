import AVFoundation
import CoreAudio
import XCTest
@testable import TextMouth

/// A seeded state-machine fuzzer of a reader's playback (TODO P09: "repeated
/// pause/resume/seek/voice changes and disconnect/reconnect preserve the
/// cursor, stop old audio, and release render resources").
///
/// Each test opens a reader of one kind of book, applies a seeded random
/// sequence of operations to it (`PlaybackOperation`: play, pause, seeks,
/// skips, headings, voice and speed changes, route losses, media commands,
/// stale renders, sleep timers, and time passing), and after every operation
/// checks what a listener depends on. A failure message starts with the
/// seed, the step, and the operations so far; the seed alone reruns the
/// sequence (`TEXTMOUTH_PLAYBACK_FUZZ_SEED=<seed>`, `..._SEQUENCES=1`).
///
/// Nothing is ever heard. A text book's chapters are longer than speech ever
/// renders (`SpeechRenderCoordinator.maximumTextLength`), so its speech is
/// always direct, and every direct utterance goes to a recorder that drops
/// it in place of the synthesizer; look-ahead renders are held, never run.
/// Audiobooks play silent WAV files. Announcements are recorded, not posted.
///
/// Sized by the environment, for a long run through
/// `Scripts/test/run-area.py --classes PlaybackFuzzTests --env ...`:
/// `TEXTMOUTH_PLAYBACK_FUZZ_SEQUENCES` (default 5 sequences per kind),
/// `TEXTMOUTH_PLAYBACK_FUZZ_LENGTH` (default 30 operations), and
/// `TEXTMOUTH_PLAYBACK_FUZZ_SEED` (the first sequence's seed; sequence `n`
/// uses the seed plus `n`).
@MainActor
final class PlaybackFuzzTests: XCTestCase {

    // MARK: - The Tests

    func testTextBookSurvivesRandomOperations() throws {
        try fuzz(.text)
    }

    func testSingleFileAudioBookSurvivesRandomOperations() throws {
        try fuzz(.singleFileAudio)
    }

    func testMultiFileAudioBookSurvivesRandomOperations() throws {
        try fuzz(.multiFileAudio)
    }

    // MARK: - Sizes

    /// An integer setting from the environment, or `fallback` where the
    /// variable is unset or not a non-negative number.
    private static func environmentNumber(_ name: String, fallback: UInt64) -> UInt64 {
        ProcessInfo.processInfo.environment[name].flatMap { UInt64($0) } ?? fallback
    }

    private static let sequenceCount = Int(clamping: environmentNumber("TEXTMOUTH_PLAYBACK_FUZZ_SEQUENCES", fallback: 5))
    private static let sequenceLength = Int(clamping: environmentNumber("TEXTMOUTH_PLAYBACK_FUZZ_LENGTH", fallback: 30))
    private static let firstSeed = environmentNumber("TEXTMOUTH_PLAYBACK_FUZZ_SEED", fallback: 20_261_017)

    // MARK: - The Kinds of Book

    /// The books the fuzzer plays.
    private enum BookKind: String {
        /// Two chapters of a text book, each with three headings.
        case text
        /// An audiobook of one silent file: one chapter.
        case singleFileAudio
        /// An audiobook of three silent tracks: three chapters.
        case multiFileAudio

        var isAudio: Bool { self != .text }
    }

    /// The text book's two chapters, each over the length speech renders so
    /// that speech stays direct, with three headings each at known offsets.
    private static let textChapters: [Chapter] = (1...2).map { number in
        var text = ""
        var headings: [Heading] = []
        // A third of the render limit and a little more for each section.
        let sectionLength = SpeechRenderCoordinator.maximumTextLength / 3 + 400
        for section in 1...3 {
            let title = "Section \(number).\(section)"
            headings.append(Heading(level: 1, text: title, chapterIndex: number - 1, characterOffset: text.utf16.count))
            text += "\(title)\n\n"
            var entry = 0
            while text.utf16.count < section * sectionLength {
                entry += 1
                text += "Entry \(entry) of the harbour ledger is noted. "
            }
        }
        return Chapter(title: "Ledger \(number)", text: text, headings: headings)
    }

    // MARK: - The System's Side

    /// The system's side of the media session: the coordinator the reader
    /// joins (made as the app makes its own, without system integrations or
    /// Core Audio listeners), the AirPods and speakers it hears of, and the
    /// clock it receives commands by. Commands are delivered as MediaPlayer
    /// does, and their actions run at once.
    @MainActor
    private final class FuzzRoute {
        nonisolated static let airPods: AudioDeviceID = 41
        nonisolated static let speakers: AudioDeviceID = 73

        /// What the coordinator reaches through its providers.
        @MainActor
        private final class State {
            var now = Date(timeIntervalSince1970: 1_000)
            var defaultOutput: AudioDeviceID? = FuzzRoute.airPods
            var outputs: [AudioDeviceID] = [FuzzRoute.airPods, FuzzRoute.speakers]
            var waitingActions: [@MainActor @Sendable () -> Void] = []
        }

        private let state: State
        let coordinator: NowPlayingService

        init() {
            let state = State()
            self.state = state
            coordinator = NowPlayingService(
                installsSystemIntegrations: false,
                diagnosticSink: { _ in },
                now: { state.now },
                defaultOutputDevice: { state.defaultOutput },
                audioDeviceIDs: { state.outputs },
                isBluetoothDevice: { $0 == FuzzRoute.airPods },
                scheduleRemoteCommandAction: { state.waitingActions.append($0) },
                systemNowPlaying: { _ in }
            )
        }

        /// Deliver `request` as MediaPlayer does, a little later than the
        /// last command so that none is taken for a repeat, and run its
        /// action.
        func press(_ request: RemoteMediaCommandRequest) {
            advanceClock(by: 5)
            _ = coordinator.acceptRemoteCommand(request)
            while !state.waitingActions.isEmpty {
                state.waitingActions.removeFirst()()
            }
        }

        /// Move the clock commands are received by.
        func advanceClock(by seconds: TimeInterval) {
            state.now = state.now.addingTimeInterval(seconds)
        }

        /// The AirPods go back in their case.
        func takeAirPodsOut() {
            state.defaultOutput = FuzzRoute.speakers
            state.outputs = [FuzzRoute.speakers]
            coordinator.handleDefaultOutputChange()
        }

        /// The AirPods connect.
        func putAirPodsIn() {
            state.defaultOutput = FuzzRoute.airPods
            state.outputs = [FuzzRoute.airPods, FuzzRoute.speakers]
            coordinator.handleDefaultOutputChange()
        }
    }

    // MARK: - One Sequence

    /// A place in the book.
    private struct Place: Equatable {
        let chapter: Int
        let offset: Int
    }

    /// What a check compares before and after an operation.
    private struct Snapshot {
        let place: Place
        /// Whether the AirPods, the Bluetooth output, are connected.
        let airPodsIn: Bool
        /// Whether the system holds off media commands, as it does for a
        /// while after a route change.
        let commandsHeldOff: Bool
        /// The cursor as one number across chapters.
        let global: Int
        let isPlaying: Bool
    }

    /// How much a fuzz run exercised, so that a run which never played
    /// anything cannot pass unnoticed.
    private struct Tally {
        /// Operations applied.
        var steps = 0
        /// Operations applied to a book that was playing.
        var playingSteps = 0
        /// Route losses checked on a playing book.
        var routeLossChecks = 0
        /// Plays checked to resume from the cursor a route loss kept.
        var resumeChecks = 0
        /// Pauses and stops checked, and checked again 0.1 s later.
        var stopChecks = 0
    }

    /// One sequence's reader and what the checks remember between steps.
    @MainActor
    private final class Run {
        let kind: BookKind
        let seed: UInt64
        let reader: ReaderViewModel
        /// The system's side of the media session the reader joined.
        let route: FuzzRoute
        /// Holds the reader's look-ahead renders and never runs them.
        let held: HeldRenderQueue
        /// The operations applied so far.
        var applied: [PlaybackOperation] = []
        /// What the sequence has exercised.
        var tally = Tally()
        /// Whether the AirPods, the Bluetooth output, are connected.
        var airPodsIn = true
        /// Where a route loss paused a playing book, until something moves
        /// the cursor or a Play checks that it resumed from there.
        var pausedByRouteLossAt: Place?

        init(kind: BookKind, seed: UInt64, reader: ReaderViewModel, route: FuzzRoute, held: HeldRenderQueue) {
            self.kind = kind
            self.seed = seed
            self.reader = reader
            self.route = route
            self.held = held
        }
    }

    /// The first six English voices, in a fixed order, for voice changes.
    private static let voices: [AVSpeechSynthesisVoice] = Array(
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { $0.identifier < $1.identifier }
            .prefix(6)
    )

    // MARK: - Running

    /// Run `sequenceCount` sequences against books of `kind`, and fail with
    /// the first sequence that breaks an invariant (a later one would only
    /// repeat it).
    private func fuzz(_ kind: BookKind) throws {
        // Before the world, so the world's readers close first.
        preserveSleepTimers()
        let world = try makeIntegrationWorld("Playback Fuzz \(kind.rawValue)")
        // Resuming goes on from the cursor, so a check can compare them.
        world.settings.rewindOnResumeUnit = .none
        world.settings.punctuationPauseLevel = 0
        // The AirPods leaving pauses a playing book only where the app
        // watches for them, as AudioRouteMonitoringTests sets it.
        world.settings.bluetoothMonitoringEnabled = true
        world.settings.bluetoothDisconnectDelay = 2
        let book = try makeBook(kind, in: world)
        var failure: String?
        var tally = Tally()
        recordingAnnouncements {
            for index in 0..<Self.sequenceCount where failure == nil {
                failure = runSequence(
                    seed: Self.firstSeed &+ UInt64(index), kind: kind, book: book, world: world, tally: &tally
                )
            }
        }
        if let failure {
            XCTFail(failure)
        }
        // Seen in the test log, with the seeds, to show what a run covered.
        print("PlaybackFuzz \(kind.rawValue): \(Self.sequenceCount) sequences from seed \(Self.firstSeed), \(tally)")
        // A run that never played anything checks nothing.
        if failure == nil, Self.sequenceCount * Self.sequenceLength >= 100 {
            XCTAssertGreaterThan(tally.playingSteps, 0, "No operation was applied to a playing book")
        }
    }

    /// The book of `kind`, listed in `world`.
    private func makeBook(_ kind: BookKind, in world: IntegrationWorld) throws -> Book {
        switch kind {
        case .text:
            return listTextBook(titled: "Quay Ledger", in: world, endOfBook: .stop)
        case .singleFileAudio:
            return try world.makeSilentAudioFileBook(title: "Single Soundings", duration: 120)
        case .multiFileAudio:
            return try world.makeSilentAudioBook(title: "Three Soundings", trackDurations: [30, 30, 30])
        }
    }

    /// Open a reader of `book` at its start, joined to a media system of its
    /// own, loaded and ready to play silently.
    private func openReader(seed: UInt64, kind: BookKind, book: Book, world: IntegrationWorld) -> Run {
        let held = HeldRenderQueue()
        let route = FuzzRoute()
        let reader = world.openReader(for: book, renderScheduler: held, nowPlaying: route.coordinator)
        let run = Run(kind: kind, seed: seed, reader: reader, route: route, held: held)
        waitForReaderToLoad(reader)
        // The AirPods are the output the reader starts with.
        route.coordinator.refreshPreviousDeviceInfo()
        if kind == .text {
            // Direct speech goes nowhere: nothing reaches the synthesizer.
            reader.speechService._directUtteranceRecorderForTesting = { _ in }
            reader.errorMessage = nil
            reader.content = DocumentContent(title: book.title, author: "Test Author", chapters: Self.textChapters)
        }
        // An earlier sequence saved its place in the book.
        reader.navigateTo(chapterIndex: 0, characterOffset: 0)
        return run
    }

    /// Play one seeded sequence on a fresh reader.
    ///
    /// - Returns: The first failure, which starts with the seed, the step,
    ///   and the operations so far; nil where every check held.
    private func runSequence(
        seed: UInt64, kind: BookKind, book: Book, world: IntegrationWorld, tally: inout Tally
    ) -> String? {
        let run = openReader(seed: seed, kind: kind, book: book, world: world)
        // Closed whatever happens, so no reader, timer, or render outlives it.
        // The tally is handed back the same way.
        defer {
            run.reader.close()
            tally.steps += run.tally.steps
            tally.playingSteps += run.tally.playingSteps
            tally.routeLossChecks += run.tally.routeLossChecks
            tally.resumeChecks += run.tally.resumeChecks
            tally.stopChecks += run.tally.stopChecks
        }
        let lengths = run.reader.content?.chapters.map { $0.text.utf16.count } ?? []
        let operations = PlaybackOperation.sequence(
            seed: seed,
            length: Self.sequenceLength,
            shape: PlaybackBookShape(chapterLengths: lengths)
        )
        for (step, operation) in operations.enumerated() {
            run.applied.append(operation)
            let before = snapshot(run)
            run.tally.steps += 1
            if before.isPlaying { run.tally.playingSteps += 1 }
            apply(operation, to: run)
            if let problem = check(after: operation, from: before, in: run) {
                return "\(PlaybackOperation.describe(seed: seed, run.applied)) failed at step \(step + 1) "
                    + "(\(operation)) of a \(kind.rawValue) book: \(problem)"
            }
        }
        return checkEnd(of: run).map {
            "\(PlaybackOperation.describe(seed: seed, run.applied)) failed at the end of a \(kind.rawValue) book: \($0)"
        }
    }

    // MARK: - Applying an Operation

    /// Give `operation` to the reader of `run`, or to the system's side.
    private func apply(_ operation: PlaybackOperation, to run: Run) {
        let reader = run.reader
        switch operation {
        case .play:
            reader.play()
        case .pause:
            reader.pause()
        case .toggle:
            reader.togglePlayPause()
        case .stop:
            reader.stop()
        case .skipForward:
            // Skips closer together than the debounce are ignored.
            reader.lastSkipTime = .distantPast
            reader.skipForward()
        case .skipBackward:
            reader.lastSkipTime = .distantPast
            reader.skipBackward()
        case .seek(let chapter, let offset):
            reader.navigateTo(chapterIndex: chapter, characterOffset: offset)
        case .nextHeading:
            reader.nextHeading()
        case .previousHeading:
            reader.previousHeading()
        case .changeVoice(let choice):
            if !Self.voices.isEmpty {
                reader.setLocalVoice(Self.voices[choice % Self.voices.count])
            }
        case .changeSpeed(let faster):
            reader.stepSpeed(forward: faster)
        case .run(let milliseconds):
            spinMainRunLoop(for: Double(milliseconds) / 1_000)
            // Time passes for the media commands too, which a route change
            // holds off for a while.
            run.route.advanceClock(by: 30)
        case .routeLost:
            run.route.takeAirPodsOut()
            run.airPodsIn = false
        case .routeBack:
            run.route.putAirPodsIn()
            run.route.advanceClock(by: 30)
            run.airPodsIn = true
        case .mediaPause:
            run.route.press(.pause)
        case .mediaPlay:
            run.route.press(.play)
        case .invalidateRenders:
            reader.refreshLookAhead()
        case .sleepTimerSet(let minutes):
            reader.startSleepTimer(duration: .minutes(minutes))
        case .sleepTimerCancel:
            reader.cancelSleepTimer()
        }
    }

    // MARK: - What the Reader Reports

    /// Whether the reader's playback service is playing, not paused.
    private func isPlaying(_ reader: ReaderViewModel) -> Bool {
        reader.isAudioBook
            ? reader.audioPlaybackService.isPlaying && !reader.audioPlaybackService.isPaused
            : reader.speechService.isSpeaking && !reader.speechService.isPaused
    }

    /// Whether either service holds a source, playing or paused.
    private func holdsASource(_ reader: ReaderViewModel) -> Bool {
        reader.audioPlaybackService.isPlaying || reader.speechService.isSpeaking
    }

    /// The reader's cursor, and whether it plays, now.
    private func snapshot(_ run: Run) -> Snapshot {
        let reader = run.reader
        return Snapshot(
            place: Place(chapter: reader.currentChapterIndex, offset: reader.currentCharacterOffset),
            airPodsIn: run.airPodsIn,
            commandsHeldOff: run.route.coordinator.isRouteCommandSuppressed,
            global: reader.currentGlobalOffset,
            isPlaying: isPlaying(reader)
        )
    }

    /// How far the cursor of an audiobook may move in the instant between
    /// two readings: a second of audio. A text book's cursor moves only as
    /// speech reports words, and none is reported.
    private func cursorDrift(of reader: ReaderViewModel) -> Int {
        reader.isAudioBook ? Int(ReaderViewModel.audioCharsPerSecond) : 0
    }

    // MARK: - The Invariants

    /// The operations that may move the cursor backward: a seek, a skip
    /// back, a previous heading, and those that start playing or stop it,
    /// where the book may start again from its place or rest at its start.
    private func mayMoveBackward(_ operation: PlaybackOperation) -> Bool {
        switch operation {
        case .play, .toggle, .stop, .seek, .skipBackward, .previousHeading, .mediaPlay:
            return true
        default:
            return false
        }
    }

    /// Check what must hold after `operation`, which began with the reader
    /// as `before` shows.
    ///
    /// - Returns: What does not hold, or nil.
    private func check(after operation: PlaybackOperation, from before: Snapshot, in run: Run) -> String? {
        let reader = run.reader
        let immediate = snapshot(run)

        // A route lost while playing, with the AirPods in: the reader pauses
        // and keeps its place (AudioRouteMonitoringTests).
        let lostWhilePlaying = operation == .routeLost && before.isPlaying && before.airPodsIn
        if lostWhilePlaying, isPlaying(reader) {
            return "the book was still playing after the AirPods went"
        }
        if lostWhilePlaying {
            run.tally.routeLossChecks += 1
            if let problem = placeKept(before.place, immediate.place, reader) {
                return "the route loss moved the cursor: \(problem)"
            }
            run.pausedByRouteLossAt = before.place
        }

        // Let callbacks arrive before looking at what the services report.
        spinMainRunLoop(for: 0.05)

        // Nothing but the listener or time moves the cursor backward.
        let settled = snapshot(run)
        if !mayMoveBackward(operation), !reader.hasFinishedBook,
           settled.global < before.global - cursorDrift(of: reader) {
            return "the cursor moved backward from \(before.place) to \(settled.place)"
        }

        if let problem = checkCursorIsInTheBook(settled.place, reader) {
            return problem
        }
        if reader.audioPlaybackService.isPlaying, reader.speechService.isSpeaking {
            return "the audio service plays while speech speaks"
        }
        if reader.isAudioBook, reader.speechService.isSpeaking {
            return "speech speaks in an audiobook"
        }
        if !reader.isAudioBook, reader.audioPlaybackService.isPlaying {
            return "the audio service plays in a text book"
        }
        if let problem = checkReaderAgreesWithServices(reader) {
            return problem
        }

        // After a pause or a stop nothing plays, and nothing starts it again.
        let stopsPlayback = operation == .pause || operation == .stop || (operation == .mediaPause && !before.commandsHeldOff)
        if stopsPlayback {
            run.tally.stopChecks += 1
            if let problem = checkNothingPlays(reader, stopped: operation == .stop) {
                return "right after the \(operation): \(problem)"
            }
            spinMainRunLoop(for: 0.1)
            if let problem = checkNothingPlays(reader, stopped: operation == .stop) {
                return "0.1 s after the \(operation), by a stale completion: \(problem)"
            }
        }

        // A Play after a route loss goes on from the cursor the loss kept.
        switch operation {
        case .seek, .skipForward, .skipBackward, .nextHeading, .previousHeading, .stop:
            run.pausedByRouteLossAt = nil
        case .play, .toggle, .mediaPlay:
            if let kept = run.pausedByRouteLossAt, isPlaying(reader) {
                run.pausedByRouteLossAt = nil
                run.tally.resumeChecks += 1
                if let problem = placeKept(kept, snapshot(run).place, reader) {
                    return "playing after the route loss did not go on from the kept cursor: \(problem)"
                }
            }
        default:
            break
        }
        return nil
    }

    /// Whether `now` is `kept`, within a second of audio.
    ///
    /// - Returns: What differs, or nil.
    private func placeKept(_ kept: Place, _ now: Place, _ reader: ReaderViewModel) -> String? {
        if kept.chapter == now.chapter, abs(kept.offset - now.offset) <= cursorDrift(of: reader) {
            return nil
        }
        return "\(kept) became \(now)"
    }

    /// The cursor names a chapter of the book and a place inside its text.
    private func checkCursorIsInTheBook(_ place: Place, _ reader: ReaderViewModel) -> String? {
        guard let chapters = reader.content?.chapters, chapters.indices.contains(place.chapter) else {
            return "the cursor is in chapter \(place.chapter), which the book does not have"
        }
        let length = chapters[place.chapter].text.utf16.count
        guard (0...length).contains(place.offset) else {
            return "the cursor is at \(place.offset) of a chapter \(length) long"
        }
        return nil
    }

    /// The reader's flags, which its window shows, agree with the service
    /// that plays, once the run loop has settled (an audiobook takes a
    /// moment to start).
    private func checkReaderAgreesWithServices(_ reader: ReaderViewModel) -> String? {
        let agrees = { (reader.isCurrentlyPlaying && !reader.isCurrentlyPaused) == self.isPlaying(reader) }
        guard !waitUntil(timeout: 1, agrees) else { return nil }
        return "the reader shows playing=\(reader.isCurrentlyPlaying) paused=\(reader.isCurrentlyPaused), "
            + "but its service plays=\(isPlaying(reader))"
    }

    /// Nothing plays; after a stop, no source is held either.
    private func checkNothingPlays(_ reader: ReaderViewModel, stopped: Bool) -> String? {
        if isPlaying(reader) {
            return "the book plays"
        }
        if stopped, holdsASource(reader) {
            return "a source is still held (audio \(reader.audioPlaybackService.isPlaying), "
                + "speech \(reader.speechService.isSpeaking))"
        }
        return nil
    }

    /// After the reader closes: nothing plays or is held, no render is
    /// running or asked for, and no sleep timer runs.
    private func checkEnd(of run: Run) -> String? {
        let reader = run.reader
        reader.close()
        let rendersAsked = run.held.requested.count
        spinMainRunLoop(for: 0.1)
        if isPlaying(reader) || holdsASource(reader) {
            return "the closed reader still holds a source"
        }
        if reader.lookAhead != nil {
            return "the closed reader still holds a look-ahead render"
        }
        if run.held.running != nil {
            return "a render is still running"
        }
        if run.held.requested.count != rendersAsked {
            return "the closed reader asked for a render"
        }
        if SleepTimerService.shared.isActive {
            return "a sleep timer is still running"
        }
        return nil
    }
}
