#if os(macOS)
import AppKit
#else
import UIKit
#endif
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

    /// The footprint from which the guard reads at the short interval even
    /// while nothing plays: 1 GB, an order of magnitude above TextMouth's
    /// own footprint. A runaway at the October 14 rate of about 60 MB a
    /// second grows 1.8 GB in the 30 seconds of the long wait, so from
    /// under 1 GB it reaches about 2.8 GB, still below the stop ceiling:
    /// the reading after it is taken at the short interval, in time for the
    /// quit ceiling, and no reading that matters is missed.
    static let watchCloselyFootprint: UInt64 = 1 << 30

    /// What the guard does about one reading.
    enum Action: Equatable, Sendable {
        /// Nothing: the footprint is below the stop ceiling, or playback
        /// has already been stopped for it and it has not reached the quit
        /// ceiling, or nothing plays to be stopped.
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

    /// The footprint the last reading found, or nil before the first.
    private(set) var lastFootprint: UInt64?

    /// Whether the guard watches closely, reading at the short interval:
    /// while anything plays, while a runaway it stopped playback for goes
    /// on, and while the last footprint read was at or above
    /// `watchCloselyFootprint`. Otherwise it still reads, at the long one
    /// (`readWait`), since a runaway can begin when nothing plays at all.
    func isWatching(whileAnythingPlays isAnythingPlaying: Bool) -> Bool {
        isAnythingPlaying || hasStoppedPlayback || (lastFootprint ?? 0) >= MemoryGuardPolicy.watchCloselyFootprint
    }

    /// How long to wait before the next reading: `readInterval` while the
    /// guard watches closely, `idleReadInterval` otherwise. Decided from
    /// the state and the last reading alone, so it can be tested without a
    /// clock.
    func readWait(whileAnythingPlays isAnythingPlaying: Bool, readInterval: TimeInterval, idleReadInterval: TimeInterval) -> TimeInterval {
        isWatching(whileAnythingPlays: isAnythingPlaying) ? readInterval : idleReadInterval
    }

    /// Decide what to do about a reading of `footprint` bytes. The quit
    /// ceiling acts in every state, since a runaway can begin while
    /// nothing plays; the stop ceiling only while something plays
    /// (`isAnythingPlaying`), when there is something to stop.
    mutating func act(onFootprint footprint: UInt64, isAnythingPlaying: Bool) -> Action {
        lastFootprint = footprint
        if footprint >= quitCeiling {
            return .saveAndQuit(footprint: footprint)
        }
        guard footprint >= stopCeiling else {
            // The runaway is over, or never began.
            hasStoppedPlayback = false
            return .none
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
    /// Whether nothing was playing, and no playback had been stopped for
    /// this runaway, when TextMouth quit: the memory grew with the audio
    /// idle (a stuck import or decoder), so the book is no part of the
    /// story. False in a marker written before this was kept.
    let wasNothingPlaying: Bool

    /// The keys the marker is kept under.
    private enum CodingKeys: String, CodingKey {
        case date, footprint, bookTitle, wasNothingPlaying
    }

    init(date: Date, footprint: UInt64, bookTitle: String?, wasNothingPlaying: Bool = false) {
        self.date = date
        self.footprint = footprint
        self.bookTitle = bookTitle
        self.wasNothingPlaying = wasNothingPlaying
    }

    /// Decode a marker, reading one written before `wasNothingPlaying`
    /// existed (no such key) as a quit while a book played.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        date = try values.decode(Date.self, forKey: .date)
        footprint = try values.decode(UInt64.self, forKey: .footprint)
        bookTitle = try values.decodeIfPresent(String.self, forKey: .bookTitle)
        wasNothingPlaying = try values.decodeIfPresent(Bool.self, forKey: .wasNothingPlaying) ?? false
    }

    /// Where the marker is kept: beside the library index in the data
    /// directory.
    static var url: URL {
        TextMouthPaths.root.appendingPathComponent("memory-quit.json")
    }

    /// What the next launch says, in an alert:
    /// "TextMouth quit on October 14, 2026 at 5:03 PM to protect your Mac:
    /// its memory grew to 6.1 GB while Ferry Timetables played, because of a
    /// fault in macOS's audio. Your place was saved."
    /// When nothing was playing: "TextMouth quit on October 14, 2026 at
    /// 5:03 PM to protect your Mac: its memory grew to 6.1 GB while nothing
    /// was playing. Your place was saved."
    ///
    /// - Parameters:
    ///   - locale: The locale the date is written in: the listener's own.
    ///   - timeZone: The time zone it is written in: the Mac's.
    func announcement(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var style = Date.FormatStyle(date: .long, time: .shortened)
        style.locale = locale
        style.timeZone = timeZone
        let opening = "TextMouth quit on \(date.formatted(style)) to protect your Mac: its memory grew to "
            + "\(MemoryFootprint.gigabytes(footprint)) GB"
        if wasNothingPlaying {
            return opening + " while nothing was playing. Your place was saved."
        }
        let book = bookTitle.map { $0.isEmpty ? "a book" : $0 } ?? "a book"
        return opening + " while \(book) played, because of a fault in macOS's audio. Your place was saved."
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
    /// Save the reader's place now, but only if it moved since its last
    /// durable save. A reader that cannot tell saves it regardless.
    func savePositionIfMoved()
}

extension MemoryGuardedReader {
    /// A reader that does not track its last saved place saves every time.
    func savePositionIfMoved() { savePosition() }
}

// MARK: - The Guard

/// A guard on TextMouth's memory (B07): every five seconds while audio or
/// speech plays, and every thirty seconds otherwise (five again once the
/// footprint is above a gigabyte), it reads TextMouth's footprint, and
/// at the first ceiling (`MemoryGuardPolicy.stopCeiling`) stops playback in
/// every reader that plays, which says why. At the second
/// (`MemoryGuardPolicy.quitCeiling`), reached afterwards, at once, or while
/// nothing plays at all, it saves the library, every open reader's place,
/// and every pending write, leaves a marker for the next launch to tell the
/// listener about, and quits, asking nothing: a runaway inside Apple's
/// audio code cannot be stopped from inside the app, and would otherwise
/// take the Mac down.
///
/// The footprint is read off the main thread, on the guard's own queue, so
/// the guard keeps reading should the main thread be stuck behind the
/// system's audio, as it was on October 14, 2026. The marker is written
/// there too; the saving is the main thread's, and should the main thread
/// not have quit `quitGrace` seconds later, the queue quits on its own.
///
/// Readers say when they play (`reader(_:isPlaying:title:)`), and the app
/// begins the reading at launch (`beginWatching()`). The app's guard
/// (`shared`) watches nothing in hosted tests, which build their own
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
        /// How often the footprint is read while the guard watches closely:
        /// while anything plays, while a runaway it stopped goes on, and
        /// while the last footprint read was at or above
        /// `MemoryGuardPolicy.watchCloselyFootprint`.
        var readInterval: TimeInterval = 5
        /// How often it is read otherwise: 30 seconds, since a runaway can
        /// begin while nothing plays (a stuck import, or a decoder left
        /// wedged after its track failed), and the quit ceiling must act
        /// then too. Costs one cheap kernel call twice a minute.
        var idleReadInterval: TimeInterval = 30
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
        #if os(iOS)
        /// Reads the bytes left to TextMouth before the system's limit on the
        /// iPhone, which the iOS guard acts on in place of the footprint:
        /// `os_proc_available_memory()`, which the SDK's `os/proc.h` says is
        /// "equivalent to the task_vm_info.limit_bytes_remaining field" and
        /// cheap enough to ask "whenever it is needed". Called on the guard's
        /// queue.
        var readAvailableMemory: @Sendable () -> UInt64 = { UInt64(os_proc_available_memory()) }
        #endif
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

    /// Begin reading the footprint, now and for as long as TextMouth runs,
    /// if the guard `isEnabled` and no reading loop runs: the app calls it
    /// at launch, so the quit ceiling acts even when nothing ever plays.
    /// Calling it again starts no second loop.
    func beginWatching() {
        guard isEnabled else { return }
        watch.begin()
    }

    /// Note whether `reader`, playing the book `title`, plays now: playing,
    /// not paused, or waiting to play on. The guard reads the footprint
    /// every `readInterval` while any reader plays; this begins the reading
    /// loop too, should the app not have.
    func reader(_ reader: any MemoryGuardedReader, isPlaying: Bool, title: String) {
        readers = readers.filter { $0.value.reader != nil }
        readers[reader.readerID] = WatchedReader(reader: reader, isPlaying: isPlaying)
        guard isEnabled else { return }
        watch.note(reader.readerID, isPlaying: isPlaying, title: title)
    }

    /// Read the footprint now and act on it, as the guard's queue does every
    /// `readInterval` or `idleReadInterval`; for tests, which drive the guard
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
    /// asking nothing. The app's pending writes are the quit's own flush,
    /// which saves the same places again; the guard saves them itself all
    /// the same, so a guard whose writes a test replaces saves them too.
    fileprivate func saveEverythingAndQuit(_ environment: Environment) {
        isQuittingToProtectTheMac = true
        saveEveryOpenReaderPosition()
        environment.savePendingWrites()
        environment.quit()
    }

    /// Save the place of every open reader, playing or not, as TextMouth
    /// quits: the guard's own quit does, and so does every other quit,
    /// whose flush calls this first
    /// (`UnsavedChangesTerminationGuard.flushPendingWrites()`). A playing
    /// reader saves its place only every thirty seconds
    /// (`PlaybackCheckpointPolicy`), and SwiftUI closes no reader window as
    /// TextMouth quits, so without this the next launch could open a book
    /// up to thirty seconds back. Every reader reports to the guard as it
    /// opens, whether or not the guard `isEnabled`, so this finds them all;
    /// a closed reader saved its place as it closed, and is skipped. A
    /// reader at rest, whose place has not moved since it was last saved,
    /// writes nothing (`savePositionIfMoved()`): saving it would date its
    /// place anew and write this Mac's library index over a newer one that
    /// another Mac on a shared library saved.
    func saveEveryOpenReaderPosition() {
        for reader in openReaders(playingOnly: false) {
            reader.savePositionIfMoved()
        }
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
#if os(macOS)
        Task { @MainActor in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "TextMouth Quit to Protect Your Mac"
            alert.informativeText = marker.announcement()
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
#else
        // Phase 0: iOS shows no alert (an iPhone app cannot quit itself to
        // protect the device, so no quit marker is ever left to announce).
        _ = marker
#endif
    }

    // MARK: The App's Actions

    /// Save what the termination path saves: every open reader's place,
    /// then the library index and every queued book record, then the
    /// statistics, whose listening session is credited so far.
    static func savePendingWrites() {
        UnsavedChangesTerminationGuard.flushPendingWrites()
        TextMouthPaths.flushLogs()
    }

    /// Quit through AppKit, which asks nothing while
    /// `isQuittingToProtectTheMac` is set, so `applicationWillTerminate`
    /// shuts down as it always does. This is the one quit that calls
    /// `terminate(_:)` itself rather than through `QuitRequest.ask()`: the
    /// delegate answers it at once, holding nothing, so there is no wait for
    /// a reply to hang, and an emergency should not wait a turn of the run
    /// loop.
    static func quitAskingNothing() {
#if os(macOS)
        NSApplication.shared.terminate(nil) // quit-ok: the memory guard's emergency quit, answered at once
#else
        // Phase 0: iOS lets an app end only by the system's choice, so there
        // is nothing to quit; the system itself ends apps under memory pressure.
#endif
    }

    /// Quit at once, from any thread, without running anything more: the
    /// main thread is stuck, and the place was saved as it was last left.
    /// The converting children end first (`WatchedProcess.terminateAll()`),
    /// since `_exit` would leave them running on, orphaned, with the
    /// runaway the guard acts for possibly among them.
    nonisolated static func quitAtOnce() {
        WatchedProcess.terminateAll()
        TextMouthPaths.flushLogs()
        #if os(iOS)
        // Never on an iPhone, where the guard never quits: Apple's QA1561
        // says "Do not call the exit function", and only the system ends an
        // app. The phone's guard has no path here (its readings never ask to
        // quit); this keeps any path not foreseen from ending the app.
        DiagnosticLog.event(.app, "AUDIO_MEMORY_QUIT_REFUSED: an iPhone app never quits itself")
        #else
        _exit(0) // quit-ok: the memory guard's last resort, from a stuck main thread
        #endif
    }
}

#if os(iOS)
// MARK: - The iPhone's Guard

/// The memory guard's iOS branch (spec: "Memory"): it reads the memory left to
/// TextMouth (`os_proc_available_memory()`) in place of its footprint, and under
/// about 150 MB while a book plays, stops the book, which says why, and saves
/// (`PhoneMemoryPolicy`). It never quits. Nothing here has run on an iPhone.
extension PlaybackMemoryGuard {
    /// Stop playback in every open reader that plays, because only
    /// `availableBytes` were left to TextMouth, its footprint then
    /// `footprint` bytes; each reader says why, in the Mac's words, with the
    /// footprint. Then every open reader's place is saved and every pending
    /// write flushed, since the system may end the app soon after: Apple's
    /// documentation on memory warnings says to "consider writing any unsaved
    /// data to disk".
    fileprivate func stopEveryReaderForLowMemory(footprint: UInt64, _ environment: Environment) {
        stopEveryReader(footprint: footprint)
        saveEveryOpenReaderPosition()
        environment.savePendingWrites()
    }

    /// Whether a look-ahead render may start now on the iPhone: with enough
    /// memory left, and the phone not too hot (`PhoneMemoryPolicy.mayRenderAhead`).
    /// Read afresh at each ask, from any thread: both readings are cheap, and
    /// the SDK's header says the memory left is "only a snapshot" that should
    /// not be cached.
    nonisolated static func mayRenderAhead() -> Bool {
        PhoneMemoryPolicy.mayRenderAhead(
            availableBytes: UInt64(os_proc_available_memory()),
            thermalState: ProcessInfo.processInfo.thermalState
        )
    }
}

extension MemoryWatch {
    /// The iPhone's reading: the memory left, decided by `PhoneMemoryPolicy`
    /// against whether anything plays, and acted on. A guard whose first
    /// reading is 0 can't measure this process, as in the Simulator, and reads
    /// no more (`takeTheNextReading`); otherwise the next reading is scheduled
    /// at the Mac's waits, every five seconds while anything plays.
    fileprivate func readAvailableAndAct() {
        let available = environment.readAvailableMemory()
        let (action, mainGuard) = state.withLock { state -> (PhoneMemoryPolicy.Action, PlaybackMemoryGuard?) in
            guard !state.isQuitting else { return (.none, nil) }
            let action = state.phonePolicy.act(onAvailable: available, isAnythingPlaying: !state.playing.isEmpty)
            return (action, state.mainGuard)
        }
        switch action {
        case .none:
            break
        case .goIdle:
            DiagnosticLog.event(
                .playback,
                "AUDIO_MEMORY_GUARD_IDLE: the memory left read 0 at the first reading; this process can't be measured"
            )
        case .stopPlayback(let availableBytes):
            let footprint = environment.readFootprint() ?? 0
            DiagnosticLog.event(
                .playback,
                "AUDIO_MEMORY_LOW: \(PhoneMemoryPolicy.megabytes(availableBytes)) MB left, "
                    + "footprint=\(footprint) bytes, while audio played; stopping playback and saving"
            )
            let environment = environment
            Task { @MainActor in
                mainGuard?.stopEveryReaderForLowMemory(footprint: footprint, environment)
            }
        }
        if let wait = state.withLock({ takeTheNextReading(&$0) }) {
            scheduleReading(after: wait)
        }
    }
}
#endif

// MARK: - The Guard's Queue

/// The part of the memory guard that runs on a queue of its own: it reads
/// the footprint (every `readInterval` or `idleReadInterval`, as the policy
/// says: `MemoryGuardPolicy.readWait`), decides
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
        #if os(iOS)
        /// What to do about each reading of the memory left, on the iPhone,
        /// in place of `policy`, which acts on the footprint.
        var phonePolicy = PhoneMemoryPolicy()
        #endif
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

    /// Begin reading the footprint if the guard is not reading.
    func begin() {
        if let wait = state.withLock({ takeTheNextReading(&$0) }) {
            scheduleReading(after: wait)
        }
    }

    /// Note whether the reader `readerID` plays the book `title`, and begin
    /// reading the footprint if the guard is not reading.
    func note(_ readerID: UUID, isPlaying: Bool, title: String) {
        let wait = state.withLock { state -> TimeInterval? in
            if isPlaying {
                state.playing[readerID] = title
                state.lastTitle = title
            } else {
                state.playing[readerID] = nil
            }
            return takeTheNextReading(&state)
        }
        if let wait {
            scheduleReading(after: wait)
        }
    }

    /// Read the footprint, decide, and act; then read again later, at the
    /// wait the policy gives, until the guard begins to quit.
    func readAndAct() {
        #if os(iOS)
        // The iPhone reads the memory left before the system's limit, and
        // never quits (`readAvailableAndAct()`).
        readAvailableAndAct()
        #else
        let footprint = environment.readFootprint()
        let (action, title, wasNothingPlaying, mainGuard) = state.withLock { state -> (MemoryGuardPolicy.Action, String?, Bool, PlaybackMemoryGuard?) in
            guard let footprint, !state.isQuitting else { return (.none, nil, false, nil) }
            let action = state.policy.act(onFootprint: footprint, isAnythingPlaying: !state.playing.isEmpty)
            if case .saveAndQuit = action {
                state.isQuitting = true
            }
            // Nothing played, and no playback was stopped for this runaway,
            // when it quit: the marker says so, and the words leave the
            // book out.
            let wasNothingPlaying = state.playing.isEmpty && !state.policy.hasStoppedPlayback
            return (action, state.playing.values.sorted().first ?? state.lastTitle, wasNothingPlaying, state.mainGuard)
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
            quit(footprint: footprint, title: title, wasNothingPlaying: wasNothingPlaying, through: mainGuard)
        }
        if let wait = state.withLock({ takeTheNextReading(&$0) }) {
            scheduleReading(after: wait)
        }
        #endif
    }

    /// Quit, the footprint having reached `footprint` bytes while `title`
    /// played, or while nothing did (`wasNothingPlaying`): the marker is
    /// written here, the main thread saves and quits, and should it not have
    /// quit `quitGrace` seconds later, this queue quits on its own.
    private func quit(footprint: UInt64, title: String?, wasNothingPlaying: Bool, through mainGuard: PlaybackMemoryGuard?) {
        let environment = environment
        environment.writeMarker(MemoryQuitMarker(
            date: environment.now(), footprint: footprint, bookTitle: title, wasNothingPlaying: wasNothingPlaying
        ))
        Task { @MainActor in
            mainGuard?.saveEverythingAndQuit(environment)
        }
        queue.asyncAfter(deadline: .now() + environment.quitGrace) {
            DiagnosticLog.event(.app, "AUDIO_MEMORY_QUIT_FORCED: the main thread had not quit; quitting from the guard's queue")
            environment.quitFromAnyThread()
        }
    }

    /// Schedule the next reading, `wait` seconds from now.
    private func scheduleReading(after wait: TimeInterval) {
        queue.asyncAfter(deadline: .now() + wait) { [self] in
            state.withLock { $0.isScheduled = false }
            readAndAct()
        }
    }

    /// How long to wait before the next reading, or nil when none is to be
    /// scheduled: the guard always reads, so a reading is scheduled unless
    /// the guard is quitting or already has one scheduled. Notes it
    /// scheduled one when it gives a wait.
    private func takeTheNextReading(_ state: inout State) -> TimeInterval? {
        guard !state.isScheduled, !state.isQuitting else { return nil }
        #if os(iOS)
        // A guard that can't measure this process reads no more.
        guard !state.phonePolicy.isIdle else { return nil }
        #endif
        state.isScheduled = true
        return state.policy.readWait(
            whileAnythingPlays: !state.playing.isEmpty,
            readInterval: environment.readInterval,
            idleReadInterval: environment.idleReadInterval
        )
    }
}
