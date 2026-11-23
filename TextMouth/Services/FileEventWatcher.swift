import Foundation

/// Watches one file for changes made by anyone, and says when a burst of them has settled (FR39 step 1).
///
/// This is the one file watcher of the app: `ConfigService` watches config.json with it, the editor of a book's text
/// watches content.md and manifest.json with it, and the interface text watches interface_text.json with it. It
/// listens with a `DispatchSource` on a descriptor opened for events only (`O_EVTONLY`), which keeps no volume busy and
/// never reads the file.
///
/// - **Replacement.** An editor's save may replace the file (an atomic save renames a new file over it). The watcher
///   then listens to whichever file sits at the path now, at once, so no edit to the new file goes unreported while the
///   burst settles. When no file is there yet, as while an editor is partway through a save that removes the old file
///   before the new one lands, it looks again after each of `retryDelays`, and calls `gaveUp` when none shows.
/// - **Bursts.** An editor's save arrives as several events, and a file written in place may be incomplete until they
///   end, so `settled` is called once, with every event of the burst combined, after `quietPeriod` passes without a new
///   one.
/// - **Every wait has a limit.** The quiet period and each retry are bounded sleeps; stopping the watcher cancels them.
///
/// All of its state lives on the main actor, where its source delivers: the handler only passes the event mask on.
@MainActor
final class FileEventWatcher {
    /// The events that matter for a file a program rewrites whole: a write in place, and the rename, deletion, or
    /// revocation (its volume was unmounted) that ends the watched file's time at the path.
    static let wholeFileEvents: DispatchSource.FileSystemEvent = [.write, .rename, .delete, .revoke]

    /// The events that matter for a file an editor of the person's saves, however it saves: also growth, attribute
    /// changes, and a new link.
    static let editedFileEvents: DispatchSource.FileSystemEvent = [.write, .extend, .delete, .rename, .revoke, .attrib, .link]

    /// The pauses before each look for a missing file: short at first, for an editor that puts the new file in place a
    /// moment after removing the old one, and longer at the end, for a slow volume. About 1.5 seconds in all.
    static let defaultRetryDelays: [Duration] = [50, 100, 200, 400, 800].map { .milliseconds($0) }

    /// The file-system calls the watcher makes, replaceable so tests can count them.
    struct Calls {
        /// Opens a path for event notification only, returning a descriptor, or -1 when it cannot be opened.
        var openForEvents: @MainActor (_ path: String) -> Int32
        /// Closes a descriptor that `openForEvents` returned.
        var close: @MainActor (_ descriptor: Int32) -> Void

        /// The calls the app makes.
        static var system: Calls {
            Calls(
                openForEvents: { path in FileEventWatcher.openRegularFileForEvents(path) },
                close: { descriptor in _ = Darwin.close(descriptor) }
            )
        }
    }

    /// A descriptor for event notification only on the regular file at `path`, or -1 when there is none.
    ///
    /// - `O_NONBLOCK`: opening a FIFO by the file's name would otherwise wait for a writer, forever, on the main thread.
    /// - `O_CLOEXEC`: the descriptor never passes to a helper program the app starts.
    /// - Only a regular file is watched. A FIFO, a device, or a folder by that name is no file of the app's, so it is not
    ///   watched, and the watcher treats it as missing.
    nonisolated static func openRegularFileForEvents(_ path: String) -> Int32 {
        let descriptor = Darwin.open(path, O_EVTONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return -1 }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            _ = Darwin.close(descriptor)
            return -1
        }
        return descriptor
    }

    /// Owns the source of a watched file, and cancels it when released, so that a watcher dropped without `stop()`
    /// still closes its descriptor: cancelling runs the source's cancel handler, the one safe place to close it.
    ///
    /// Its own class, with an ordinary deinit, because `DispatchSource.cancel()` may be called from any thread. The
    /// watcher itself keeps no deinit: an isolated deinit (SE-0371), which this used to be, crashed in the Swift runtime's
    /// back-deployed `swift_task_deinitOnExecutor` ("pointer being freed was not allocated") when the last release came
    /// on the main thread during a test's wait, on macOS 26.3 with the app's macOS 14 deployment target.
    private final class SourceOwner {
        let source: DispatchSourceFileSystemObject

        init(_ source: DispatchSourceFileSystemObject) {
            self.source = source
        }

        deinit {
            source.cancel()
        }
    }

    /// The file listened to: which file it is, whatever path later leads to it, and the source delivering its events.
    private struct WatchedFile {
        let identity: FileIdentity
        /// Delivers its events; cancelling it, or releasing it, closes its descriptor.
        let owner: SourceOwner
    }

    // MARK: - Settings (fixed at creation)

    /// The file to watch, as it is now; nil when there is none to watch (a file only in the cloud, or none yet), which
    /// is looked for again after the retry delays.
    private let file: @MainActor () -> URL?
    /// Whether the file may be watched at all now: false while its folder is unavailable, when nothing is watched and
    /// nothing is looked for until `rearm()` is called again.
    private let isAvailable: @MainActor () -> Bool
    private let events: DispatchSource.FileSystemEvent
    private let quietPeriod: Duration
    private let retryDelays: [Duration]
    /// Whether a newly attached file is checked once events settle: an edit saved before the watcher attached reports
    /// no event of its own, so the check keeps the moment between two watched files covered.
    private let checksWhenAttached: Bool
    private let calls: Calls
    /// Called once a burst of events has settled, with the events combined (empty for the check of a newly attached file).
    private let settled: @MainActor (DispatchSource.FileSystemEvent) -> Void
    /// Called when every look for a missing file found none.
    private let gaveUp: @MainActor () -> Void

    // MARK: - State

    /// Whether the watcher is on: from `start()` until `stop()`.
    private var isWatching = false
    /// The events received since the last settled burst, combined.
    private var pendingEvents: DispatchSource.FileSystemEvent = []
    /// The call of `settled` waiting for the burst to end.
    private var pendingCheck: Task<Void, Never>?
    /// The file listened to, if any.
    private var watchedFile: WatchedFile?
    /// The search for a file that went missing, while it goes on.
    private var retry: Task<Void, Never>?

    /// A watcher of the file `file` names; it listens from `start()` on.
    init(
        file: @escaping @MainActor () -> URL?,
        isAvailable: @escaping @MainActor () -> Bool = { true },
        events: DispatchSource.FileSystemEvent = FileEventWatcher.wholeFileEvents,
        quietPeriod: Duration = .milliseconds(200),
        retryDelays: [Duration] = FileEventWatcher.defaultRetryDelays,
        checksWhenAttached: Bool = true,
        calls: Calls = .system,
        settled: @escaping @MainActor (DispatchSource.FileSystemEvent) -> Void,
        gaveUp: @escaping @MainActor () -> Void = {}
    ) {
        self.file = file
        self.isAvailable = isAvailable
        self.events = events
        self.quietPeriod = quietPeriod
        self.retryDelays = retryDelays
        self.checksWhenAttached = checksWhenAttached
        self.calls = calls
        self.settled = settled
        self.gaveUp = gaveUp
    }

    // A watcher dropped without `stop()` closes its descriptor all the same: releasing it releases its watched file's
    // `SourceOwner`, which cancels the source. So the watcher needs no deinit of its own.

    // MARK: - Starting and stopping

    /// Whether a file is being listened to now.
    var isArmed: Bool { watchedFile != nil }

    /// Starts listening to the file now at the path.
    func start() {
        isWatching = true
        rearm()
    }

    /// Stops for good, until `start()`: pending checks and searches are dropped, and the watched file's descriptor is
    /// closed once its source is cancelled. Events that arrive later are ignored.
    func stop() {
        isWatching = false
        pendingCheck?.cancel()
        pendingCheck = nil
        pendingEvents = []
        retry?.cancel()
        retry = nil
        disarm()
    }

    // MARK: - Decisions

    /// Whether `event` means the watched file no longer sits at the path: it was renamed, deleted, or revoked, as when
    /// an atomic save renames a new file over it.
    nonisolated static func replacesWatchedFile(_ event: DispatchSource.FileSystemEvent) -> Bool {
        !event.isDisjoint(with: [.rename, .delete, .revoke])
    }

    // MARK: - Following the file

    /// Moves the watcher to the file now at the path (a data directory may have moved, or a save replaced the file).
    /// Does nothing while the watcher is off, and watches nothing while the file may not be watched.
    func rearm() {
        guard isWatching else { return }
        guard isAvailable() else {
            disarm()
            return
        }
        if attach() {
            retry?.cancel()
            retry = nil
            return
        }
        // The watched file is gone or renamed away: stop listening to it, and look again a few times.
        disarm()
        guard retry == nil else { return }
        retry = Task { [weak self] in
            await self?.lookForMissingFile()
        }
    }

    /// Looks for the file after each of the retry delays, listening to it as soon as it is back. Giving up is reported.
    private func lookForMissingFile() async {
        for delay in retryDelays {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, isWatching else { return }
            if attach() {
                retry = nil
                return
            }
        }
        retry = nil
        gaveUp()
    }

    /// Attaches to the file now at the path, unless it already listens to that very file, and returns whether a file is
    /// listened to. A newly attached file is checked once events settle when `checksWhenAttached`.
    @discardableResult
    private func attach() -> Bool {
        guard isAvailable(), let url = file() else { return false }
        // Identify the file before opening it. A replacement in between makes the next rearm see a different file and
        // open it again: one open too many at worst, never an edit missed.
        guard let identity = FileIdentity(of: url) else { return false }
        if watchedFile?.identity == identity { return true }
        let descriptor = calls.openForEvents(url.path)
        guard descriptor >= 0 else { return false }
        disarm()

        // The source delivers on the main queue, where all of the watcher's state lives.
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: events,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.receive(source.data)
            }
        }
        // Dispatch runs this once the source has stopped using the descriptor, the only safe moment to close it.
        let close = calls.close
        source.setCancelHandler {
            MainActor.assumeIsolated {
                close(descriptor)
            }
        }
        source.resume()
        watchedFile = WatchedFile(identity: identity, owner: SourceOwner(source))
        if checksWhenAttached { scheduleCheck() }
        return true
    }

    /// Stops listening to the watched file. Cancelling its source closes the descriptor and releases the handlers that
    /// hold the source.
    private func disarm() {
        watchedFile?.owner.source.cancel()
        watchedFile = nil
    }

    // MARK: - Events

    /// Collects an event from the watched file's source. A replacement is followed at once, so no edit to the new file
    /// goes unreported while the burst settles; the batch goes to `settled` once no further event has arrived for the
    /// quiet period.
    private func receive(_ event: DispatchSource.FileSystemEvent) {
        guard isWatching else { return }
        if Self.replacesWatchedFile(event) {
            rearm()
        }
        pendingEvents.formUnion(event)
        scheduleCheck()
    }

    /// Calls `settled` once the quiet period passes without a new event, with every event collected until then as one
    /// batch: an editor's save arrives as several events, and a file written in place may be incomplete until they end.
    private func scheduleCheck() {
        pendingCheck?.cancel()
        pendingCheck = Task { [weak self, quietPeriod] in
            try? await Task.sleep(for: quietPeriod)
            guard !Task.isCancelled, let self, self.isWatching else { return }
            let events = self.pendingEvents
            self.pendingEvents = []
            self.pendingCheck = nil
            self.settled(events)
        }
    }
}
