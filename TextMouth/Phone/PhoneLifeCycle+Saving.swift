import Foundation

/// Saving on the iPhone (spec: "Saving"): iOS gives a suspended app no last
/// call, so what the Mac writes as it quits is written as the app leaves the
/// screen, as the book stops in the background, as a sleep timer puts it to
/// sleep there, and at a memory warning, each time on the main thread inside a
/// background task, with its time written to the log for the first runs on a
/// phone. Nothing is written at `willResignActive`, which Control Center and a
/// call's banner also bring, and which `PhoneLifeCycle` does not even hear.
extension PhoneLifeCycle {
    /// Flushes every write waiting to be saved, as the Mac's quit does
    /// (`UnsavedChangesTerminationGuard.flushPendingWrites()`): every open
    /// reader's place, the library index and its book records, the statistics,
    /// and the settings. The listening session is not ended: a book playing in
    /// the background is still being listened to.
    ///
    /// It runs on the main thread, where the flush's work belongs: the
    /// engineering review found it waits on the two persistence queues, and
    /// nothing on them waits for the main thread, so it cannot deadlock. About
    /// half a megabyte is written for a large library.
    ///
    /// - Parameters:
    ///   - reason: Why, for the log.
    ///   - flush: The flush itself; a test gives its own.
    ///   - now: The clock the time is read from; a test gives its own.
    /// - Returns: How long the flush took.
    @discardableResult
    static func flushPendingWrites(
        because reason: String,
        flush: @MainActor () -> Void = { UnsavedChangesTerminationGuard.flushPendingWrites() },
        now: @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) -> Duration {
        let start = now()
        flush()
        let took = start.duration(to: now())
        DiagnosticLog.event(.storage, "PHONE_FLUSH: reason=\(reason) milliseconds=\(milliseconds(took))")
        return took
    }

    /// `duration` in whole milliseconds, rounded down, for the log.
    nonisolated static func milliseconds(_ duration: Duration) -> Int64 {
        let (seconds, attoseconds) = duration.components
        return seconds * 1_000 + attoseconds / 1_000_000_000_000_000
    }

    /// The system warned that memory runs low (spec: "Memory"): what can be
    /// made again is let go, and every place saved, as Apple's documentation on
    /// memory warnings asks: free what can be reloaded, and "consider writing
    /// any unsaved data to disk".
    ///
    /// - Each open reader drops its look-ahead (`discardLookAhead()`), the
    ///   next chapter's rendered audio, up to about 98 MB for the longest: that
    ///   chapter then starts the ordinary way, with direct speech, as one does
    ///   when nothing was rendered. The chapter being read is left alone.
    /// - Every open reader saves its place, if it moved
    ///   (`PlaybackMemoryGuard.saveEveryOpenReaderPosition()`), and in the
    ///   background the save is flushed inside a hold, since the system may
    ///   end a suspended app next.
    ///
    /// The spec also names `ReadingTextCache`, which holds its texts on disk,
    /// not in memory, so nothing of it is dropped here.
    func memoryWarningReceived(in session: PhoneSession, isInBackground: Bool) {
        let readers = [session.reader, session.listeningReader].compactMap { $0 }
        for reader in readers {
            reader.discardLookAhead()
        }
        PlaybackMemoryGuard.shared.saveEveryOpenReaderPosition()
        DiagnosticLog.event(
            .app,
            "PHONE_MEMORY_WARNING: look-ahead dropped for \(readers.count) readers, places saved, "
                + "background=\(isInBackground)"
        )
        guard isInBackground else { return }
        let endHold = beginHold("Saving at a memory warning")
        Self.flushPendingWrites(because: "memory-warning")
        endHold()
    }
}
