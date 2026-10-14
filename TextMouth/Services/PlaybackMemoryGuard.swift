import AppKit
import Darwin
import os

// MARK: - TextMouth's Memory

/// How much memory TextMouth uses: its physical footprint, the figure
/// Activity Monitor's Memory column shows and the system's memory pressure
/// counts.
enum MemoryFootprint {
    /// TextMouth's physical footprint now, in bytes
    /// (`task_vm_info.phys_footprint`), or nil when the kernel does not say.
    static func current() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    /// `bytes` in gigabytes of 1,024 megabytes, to one decimal place, as the
    /// listener is told it: "6.1".
    static func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / Double(1 << 30))
    }
}

// MARK: - The Ceilings

/// What the memory guard does about TextMouth's footprint while anything
/// plays (B07), decided from each reading alone, so it can be tested
/// without a clock.
///
/// On October 14, 2026 Apple's Vorbis decoder, stuck inside AudioToolbox,
/// kept allocating while a book played, and TextMouth grew to 34 GB on an
/// 8 GB Mac in about nine minutes, until the Mac had to be reset. Nothing
/// inside the app can stop such a runaway, so the guard stops playback at
/// a first ceiling, and at a second saves everything and quits.
struct MemoryGuardPolicy: Equatable, Sendable {
    /// The footprint at which playback stops: 3 GB. TextMouth's own
    /// footprint stays far below it: 80 MB in the app with the library
    /// open, and 70 to 200 MB in the test host, which holds the whole
    /// suite, while it plays a book (measured October 14, 2026); a long
    /// book's text and rendered speech add tens of megabytes, a 20 MB
    /// one-chapter book some hundreds while it opens. Only memory taken by
    /// something gone wrong reaches it.
    static let stopCeiling: UInt64 = 3 << 30

    /// The footprint at which TextMouth saves and quits: 6 GB, three
    /// quarters of the 8 GB Mac it ran away on, beyond which the system
    /// itself stops responding. At the runaway's rate of about 60 MB a
    /// second it leaves some fifty seconds between the two ceilings.
    static let quitCeiling: UInt64 = 6 << 30

    /// What the guard does about one reading.
    enum Action: Equatable, Sendable {
        /// Nothing: the footprint is below the stop ceiling, or playback
        /// has already been stopped for it and it has not reached the quit
        /// ceiling.
        case none
        /// Stop playback, which has grown the footprint to this many bytes.
        case stopPlayback(footprint: UInt64)
        /// Save everything and quit, the footprint having reached this many
        /// bytes.
        case saveAndQuit(footprint: UInt64)
    }

    /// The ceilings: the real ones unless a test sets its own.
    var stopCeiling = MemoryGuardPolicy.stopCeiling
    var quitCeiling = MemoryGuardPolicy.quitCeiling

    /// Whether playback was stopped for a runaway still under way: the
    /// footprint has not fallen back below the stop ceiling since.
    private(set) var hasStoppedPlayback = false

    /// Whether the guard reads the footprint: while anything plays, and
    /// while a runaway it stopped playback for goes on, nothing playing.
    func isWatching(whileAnythingPlays isAnythingPlaying: Bool) -> Bool {
        isAnythingPlaying || hasStoppedPlayback
    }

    /// Decide what to do about a reading of `footprint` bytes, taken while
    /// something plays (`isAnythingPlaying`) or while a runaway goes on.
    mutating func act(onFootprint footprint: UInt64, isAnythingPlaying: Bool) -> Action {
        guard footprint >= stopCeiling else {
            // The runaway is over, or never began.
            hasStoppedPlayback = false
            return .none
        }
        guard isWatching(whileAnythingPlays: isAnythingPlaying) else { return .none }
        if footprint >= quitCeiling {
            return .saveAndQuit(footprint: footprint)
        }
        guard isAnythingPlaying else { return .none }
        hasStoppedPlayback = true
        return .stopPlayback(footprint: footprint)
    }
}

// MARK: - The Marker a Quit Leaves

/// What TextMouth leaves when it quits to protect the Mac, for the next
/// launch to tell the listener: when, how large its memory had grown, and
/// which book was playing.
struct MemoryQuitMarker: Codable, Equatable, Sendable {
    /// When TextMouth quit.
    let date: Date
    /// Its footprint then, in bytes.
    let footprint: UInt64
    /// The title of the book playing, or last playing, then; nil when none
    /// is known.
    let bookTitle: String?

    /// Where the marker is kept: beside the library index in the data
    /// directory.
    static var url: URL {
        TextMouthPaths.root.appendingPathComponent("memory-quit.json")
    }

    /// What the next launch says, in an alert:
    /// "TextMouth quit on October 14, 2026 at 5:03 PM to protect your Mac:
    /// its memory grew to 6.1 GB while Ferry Timetables played, because of a
    /// fault in macOS's audio. Your place was saved."
    ///
    /// - Parameters:
    ///   - locale: The locale the date is written in: the listener's own.
    ///   - timeZone: The time zone it is written in: the Mac's.
    func announcement(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var style = Date.FormatStyle(date: .long, time: .shortened)
        style.locale = locale
        style.timeZone = timeZone
        let book = bookTitle.map { $0.isEmpty ? "a book" : $0 } ?? "a book"
        return "TextMouth quit on \(date.formatted(style)) to protect your Mac: its memory grew to "
            + "\(MemoryFootprint.gigabytes(footprint)) GB while \(book) played, because of a fault in "
            + "macOS's audio. Your place was saved."
    }

    /// Write the marker to `url`, replacing any there.
    func write(to url: URL = MemoryQuitMarker.url) throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }

    /// The marker at `url`, removed as it is read, so it is told once; nil
    /// when there is none, or what is there cannot be read.
    static func take(from url: URL = MemoryQuitMarker.url) -> MemoryQuitMarker? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return try? JSONDecoder().decode(MemoryQuitMarker.self, from: data)
    }
}

// MARK: - The Readers the Guard Watches

/// A reader the memory guard watches: it says when it plays, and the guard
/// stops it, or saves its place, through these.
@MainActor
protocol MemoryGuardedReader: AnyObject {
    /// The reader's own ID, one for each window.
    var readerID: UUID { get }
    /// Whether the reader has closed: a closed reader is neither stopped
    /// nor saved.
    var hasClosed: Bool { get }
    /// Stop playback because TextMouth's memory grew to `footprint` bytes,
    /// and say so.
    func stopPlaybackForMemoryRunaway(footprint: UInt64)
    /// Save the reader's place now.
    func savePosition()
}

// MARK: - The Guard

/// A guard on TextMouth's memory while anything plays (B07): every five
/// seconds while audio or speech plays it reads TextMouth's footprint, and
/// at the first ceiling (`MemoryGuardPolicy.stopCeiling`) stops playback in
/// every reader that plays, which says why. At the second
/// (`MemoryGuardPolicy.quitCeiling`), reached afterwards or at once, it
/// saves the library, every open reader's place, and every pending write,
/// leaves a marker for the next launch to tell the listener about, and
/// quits, asking nothing: a runaway inside Apple's audio code cannot be
/// stopped from inside the app, and would otherwise take the Mac down.
///
/// The footprint is read off the main thread, on the guard's own queue, so
/// the guard keeps reading should the main thread be stuck behind the
/// system's audio, as it was on October 14, 2026. The marker is written
/// there too; the saving is the main thread's, and should the main thread
/// not have quit `quitGrace` seconds later, the queue quits on its own.
///
/// Readers say when they play (`reader(_:isPlaying:title:)`). The app's
/// guard (`shared`) watches nothing in hosted tests, which build their own
/// with a footprint, clock, and actions of their own.
@MainActor
final class PlaybackMemoryGuard {
    /// What the guard reads and does, each replaceable by a test.
    struct Environment: Sendable {
        /// Reads TextMouth's footprint, in bytes; called on the guard's
        /// queue.
        var readFootprint: @Sendable () -> UInt64? = { MemoryFootprint.current() }
        /// The time now, for the marker.
        var now: @Sendable () -> Date = { Date() }
        /// How often the footprint is read while anything plays.
        var readInterval: TimeInterval = 5
        /// How long the main thread has to save and quit before the guard's
        /// queue quits on its own.
        var quitGrace: TimeInterval = 15
        /// Writes the marker; called on the guard's queue.
        var writeMarker: @Sendable (MemoryQuitMarker) -> Void = { marker in
            do {
                try marker.write()
            } catch {
                let error = error as NSError
                DiagnosticLog.event(.app, "AUDIO_MEMORY_QUIT_MARKER_FAILED: error=\(error.domain) \(error.code)")
            }
        }
        /// Saves the library and every pending write; called on the main
        /// thread after every open reader's place is saved.
        var savePendingWrites: @MainActor @Sendable () -> Void = { PlaybackMemoryGuard.savePendingWrites() }
        /// Quits from the main thread, asking nothing.
        var quit: @MainActor @Sendable () -> Void = { PlaybackMemoryGuard.quitAskingNothing() }
        /// Quits at once from the guard's queue, when the main thread has
        /// not quit in time.
        var quitFromAnyThread: @Sendable () -> Void = { PlaybackMemoryGuard.quitAtOnce() }
    }

    /// The guard the app's readers report to: one that watches nothing in
    /// hosted tests, whose test host must never be stopped or quit by the
    /// memory the suite takes.
    static let shared = PlaybackMemoryGuard(isEnabled: !TextMouthRuntime.current.isHostedTest)

    /// Set as the guard quits, so the quit asks no question
    /// (`AppDelegate.applicationShouldTerminate(_:)`).
    private(set) var isQuittingToProtectTheMac = false

    /// Whether the guard reads anything at all.
    let isEnabled: Bool
    /// The part of the guard that runs on its own queue.
    private let watch: MemoryWatch
    /// The readers that have reported to the guard, by their IDs, held
    /// weakly: a closed reader, or one released, is skipped.
    private var readers: [UUID: WatchedReader] = [:]

    /// A reader held weakly, and whether it last said it plays.
    private struct WatchedReader {
        weak var reader: (any MemoryGuardedReader)?
        var isPlaying: Bool
    }

    /// A guard reading and acting through `environment`, when `isEnabled`.
    init(isEnabled: Bool = true, environment: Environment = Environment()) {
        self.isEnabled = isEnabled
        watch = MemoryWatch(environment: environment)
        watch.actThrough(self)
    }

    /// Note whether `reader`, playing the book `title`, plays now: playing,
    /// not paused, or waiting to play on. The guard reads the footprint
    /// while any reader plays.
    func reader(_ reader: any MemoryGuardedReader, isPlaying: Bool, title: String) {
        readers = readers.filter { $0.value.reader != nil }
        readers[reader.readerID] = WatchedReader(reader: reader, isPlaying: isPlaying)
        guard isEnabled else { return }
        watch.note(reader.readerID, isPlaying: isPlaying, title: title)
    }

    /// Read the footprint now and act on it, as the guard's queue does every
    /// `readInterval` while anything plays; for tests, which drive the guard
    /// reading by reading, waiting for the action it takes on the main
    /// thread.
    func readNow() {
        watch.readAndAct()
    }

    // MARK: Acting, on the Main Thread

    /// Stop playback in every open reader that plays, because TextMouth's
    /// footprint grew to `footprint` bytes; each says why.
    fileprivate func stopEveryReader(footprint: UInt64) {
        for reader in openReaders(playingOnly: true) {
            reader.stopPlaybackForMemoryRunaway(footprint: footprint)
        }
    }

    /// Save every open reader's place and every pending write, then quit,
    /// asking nothing.
    fileprivate func saveEverythingAndQuit(_ environment: Environment) {
        isQuittingToProtectTheMac = true
        for reader in openReaders(playingOnly: false) {
            reader.savePosition()
        }
        environment.savePendingWrites()
        environment.quit()
    }

    /// The readers still open: those that last said they play, when
    /// `playingOnly` is true, or all of them.
    private func openReaders(playingOnly: Bool) -> [any MemoryGuardedReader] {
        readers.values
            .filter { $0.isPlaying || !playingOnly }
            .compactMap(\.reader)
            .filter { !$0.hasClosed }
    }

    // MARK: The Next Launch

    /// Tell the listener, once, that TextMouth quit at its last launch to
    /// protect the Mac: the marker the guard left is taken, and its
    /// announcement shown in an alert, which VoiceOver reads, once the
    /// launch has gone on. Nothing is told, and no marker taken, in hosted
    /// tests.
    static func tellOfAQuitToProtectTheMac() {
        guard !TextMouthRuntime.current.isHostedTest, let marker = MemoryQuitMarker.take() else { return }
        DiagnosticLog.event(.app, "AUDIO_MEMORY_QUIT_TOLD: TextMouth quit at its last launch to protect the Mac")
        Task { @MainActor in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "TextMouth Quit to Protect Your Mac"
            alert.informativeText = marker.announcement()
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    // MARK: The App's Actions

    /// Save what the termination path saves: the library index and every
    /// queued book record, then the statistics, whose listening session is
    /// credited so far.
    static func savePendingWrites() {
        UnsavedChangesTerminationGuard.flushPendingWrites()
        TextMouthPaths.flushLogs()
    }

    /// Quit through AppKit, which asks nothing while
    /// `isQuittingToProtectTheMac` is set, so `applicationWillTerminate`
    /// shuts down as it always does.
    static func quitAskingNothing() {
        NSApplication.shared.terminate(nil)
    }

    /// Quit at once, from any thread, without running anything more: the
    /// main thread is stuck, and the place was saved as it was last left.
    nonisolated static func quitAtOnce() {
        TextMouthPaths.flushLogs()
        _exit(0)
    }
}

// MARK: - The Guard's Queue

/// The part of the memory guard that runs on a queue of its own: it reads
/// the footprint every `readInterval` while anything plays, decides
/// (`MemoryGuardPolicy`), and acts: stopping and saving on the main
/// thread, writing the marker and, should the main thread not have quit in
/// time, quitting from its own queue.
private final class MemoryWatch: Sendable {
    /// What the queue knows, under `state`'s lock.
    private struct State: Sendable {
        /// What to do about each reading.
        var policy = MemoryGuardPolicy()
        /// The readers that play, by their IDs, each with its book's title.
        var playing: [UUID: String] = [:]
        /// The title of the book that played last, for a marker written
        /// once playback has stopped.
        var lastTitle: String?
        /// Whether a reading is scheduled.
        var isScheduled = false
        /// Whether the guard has begun to quit, after which it reads no
        /// more.
        var isQuitting = false
        /// The main-thread guard the actions are taken through, held weakly:
        /// it owns this watch.
        weak var mainGuard: PlaybackMemoryGuard?
    }

    /// What the guard reads and does.
    private let environment: PlaybackMemoryGuard.Environment
    /// The queue's knowledge, shared with the main thread, which says which
    /// readers play.
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// The queue the footprint is read on.
    private let queue = DispatchQueue(label: "TextMouth.memoryGuard", qos: .utility)

    init(environment: PlaybackMemoryGuard.Environment) {
        self.environment = environment
    }

    /// Take `mainGuard` as the guard the actions are taken through.
    func actThrough(_ mainGuard: PlaybackMemoryGuard) {
        state.withLock { $0.mainGuard = mainGuard }
    }

    /// Note whether the reader `readerID` plays the book `title`, and begin
    /// reading the footprint if the guard now watches and is not reading.
    func note(_ readerID: UUID, isPlaying: Bool, title: String) {
        let startsReading = state.withLock { state -> Bool in
            if isPlaying {
                state.playing[readerID] = title
                state.lastTitle = title
            } else {
                state.playing[readerID] = nil
            }
            return Self.takeTheNextReading(&state)
        }
        if startsReading {
            scheduleReading()
        }
    }

    /// Read the footprint, decide, and act; then read again
    /// `readInterval` later while the guard still watches.
    func readAndAct() {
        let footprint = environment.readFootprint()
        let (action, title, mainGuard) = state.withLock { state -> (MemoryGuardPolicy.Action, String?, PlaybackMemoryGuard?) in
            guard let footprint, !state.isQuitting else { return (.none, nil, nil) }
            let action = state.policy.act(onFootprint: footprint, isAnythingPlaying: !state.playing.isEmpty)
            if case .saveAndQuit = action {
                state.isQuitting = true
            }
            return (action, state.playing.values.sorted().first ?? state.lastTitle, state.mainGuard)
        }
        switch action {
        case .none:
            break
        case .stopPlayback(let footprint):
            DiagnosticLog.event(
                .playback,
                "AUDIO_MEMORY_RUNAWAY: footprint=\(footprint) bytes (\(MemoryFootprint.gigabytes(footprint)) GB) "
                    + "while audio played; stopping playback"
            )
            Task { @MainActor in
                mainGuard?.stopEveryReader(footprint: footprint)
            }
        case .saveAndQuit(let footprint):
            DiagnosticLog.event(
                .playback,
                "AUDIO_MEMORY_RUNAWAY: footprint=\(footprint) bytes (\(MemoryFootprint.gigabytes(footprint)) GB); "
                    + "saving and quitting to protect the Mac"
            )
            quit(footprint: footprint, title: title, through: mainGuard)
        }
        if state.withLock({ Self.takeTheNextReading(&$0) }) {
            scheduleReading()
        }
    }

    /// Quit, the footprint having reached `footprint` bytes while `title`
    /// played: the marker is written here, the main thread saves and
    /// quits, and should it not have quit `quitGrace` seconds later, this
    /// queue quits on its own.
    private func quit(footprint: UInt64, title: String?, through mainGuard: PlaybackMemoryGuard?) {
        let environment = environment
        environment.writeMarker(MemoryQuitMarker(date: environment.now(), footprint: footprint, bookTitle: title))
        Task { @MainActor in
            mainGuard?.saveEverythingAndQuit(environment)
        }
        queue.asyncAfter(deadline: .now() + environment.quitGrace) {
            DiagnosticLog.event(.app, "AUDIO_MEMORY_QUIT_FORCED: the main thread had not quit; quitting from the guard's queue")
            environment.quitFromAnyThread()
        }
    }

    /// Schedule the next reading, `readInterval` from now.
    private func scheduleReading() {
        queue.asyncAfter(deadline: .now() + environment.readInterval) { [self] in
            state.withLock { $0.isScheduled = false }
            readAndAct()
        }
    }

    /// Whether to schedule a reading now: the guard watches, is not
    /// quitting, and has none scheduled. Notes it scheduled when so.
    private static func takeTheNextReading(_ state: inout State) -> Bool {
        guard !state.isScheduled, !state.isQuitting,
              state.policy.isWatching(whileAnythingPlays: !state.playing.isEmpty) else { return false }
        state.isScheduled = true
        return true
    }
}
