import Foundation

// MARK: - The Recorder's Timing (FR43, section 6)

/// Hears of each change to the library and runs the recording a short while
/// after the last one (2 seconds), so a burst of changes, such as a reader's
/// checkpoints, is one recording. The recording itself compares the library
/// with the baseline (`SyncEngine.record`); this holds only the timing, so a
/// test passes its own sleep and needs no clock.
///
/// It does nothing until `isOn`, and nothing runs while a merge is applied.
@MainActor final class SyncRecorder {
    /// How long after the last change the recording runs.
    static let delay: Duration = .seconds(2)

    /// Whether recording is on: sync is set up.
    var isOn = false
    /// True while a merge is applied: the library's changes then are the merge's own.
    var isApplying = false
    /// Waits `delay`; a test replaces it.
    private let sleep: @Sendable (Duration) async throws -> Void
    /// Records now.
    private let record: @MainActor () async -> Void
    /// The waiting task, replaced by each change.
    private var waiting: Task<Void, Never>?

    /// A recorder that runs `record` two seconds after the last change.
    init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }, record: @escaping @MainActor () async -> Void) {
        self.sleep = sleep
        self.record = record
    }

    /// The library changed: record after the delay, counted from now.
    func noteChange() {
        guard isOn, !isApplying else { return }
        waiting?.cancel()
        waiting = Task { [sleep, record] in
            do { try await sleep(Self.delay) } catch { return }
            await record()
        }
    }

    /// Records now, before a merge, as the iPhone goes to the background, or as the Mac quits.
    func flush() async {
        waiting?.cancel()
        waiting = nil
        guard isOn else { return }
        await record()
    }

    /// Forgets a waiting recording: sync stopped.
    func cancel() {
        waiting?.cancel()
        waiting = nil
    }
}
