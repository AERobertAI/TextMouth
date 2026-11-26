import BackgroundTasks
import Foundation
import os

/// The system's continued processing task of a spoken audio export (FR31, phase 2), new in iOS 26: it keeps TextMouth
/// running with the screen locked and the sheet closed, and shows the export as a Live Activity the person can cancel.
/// A spoken audio export plays no audio, so the audio background mode that keeps a book playing keeps nothing here.
///
/// - **Begun with a person's action.** The system requires one, and `PhoneExportSession.begin(_:)` is called as Export is
///   pressed. The request's strategy is `fail`: a task the system cannot start at once is refused, and the export goes on
///   as it always does, held by a background task, rather than waiting in a queue that a swipe in the app switcher
///   would empty without telling the app.
/// - **A name of its own.** Each task is `com.textmouth.TextMouth.iOS.export.` and a UUID, which the wildcard of
///   `BGTaskSchedulerPermittedIdentifiers` permits (`Scripts/ios/sync-info-plist.py`); the handler is registered just
///   before the request is submitted, as Apple's engineer says to do for a name made as the task begins.
/// - **Progress.** The system expires a task that reports none, so every change of the export's progress is passed on
///   (`PhoneExportTaskMirror`).
/// - **Cancel.** The Live Activity's Cancel, and the system's own expiry, run the expiration handler, which is the export's
///   Stop: the chapters already spoken are kept.
///
/// The system calls the launch handler on a queue of its own, perhaps after the export has begun to make progress, or
/// ended; what the task has not been told yet is kept for it, and an end that came first is applied as it launches.
/// Everything the two threads share is held under one lock, and the class has no other state, so it is `Sendable`
/// without any unchecked promise.
final class PhoneExportBackgroundTask: PhoneExportTaskHandle {
    /// What the task is, and has been told, under the lock.
    private struct State {
        /// The system's task, once it has launched.
        var task: BGContinuedProcessingTask?
        /// The latest update told, which a task that launches late is given.
        var latest: PhoneExportTaskMirror.Update?
        /// How the export ended, if it has, which a task that launches late is ended with.
        var ended: Bool?
    }

    /// The identifiers of these tasks begin with this, and the wildcard of the permitted identifiers ends it.
    static let identifierPrefix = "com.textmouth.TextMouth.iOS.export."

    /// The state the system's launch handler and the export both reach. Its state is not Sendable (the system's task
    /// is not), so it is made unchecked: only the lock's closures touch it.
    private let state = OSAllocatedUnfairLock<State>(uncheckedState: State())
    /// What the system's expiry does: the export's Stop.
    private let onExpire: @Sendable () -> Void

    private init(onExpire: @escaping @Sendable () -> Void) {
        self.onExpire = onExpire
    }

    // MARK: Beginning

    /// Registers a handler under a new identifier and submits the request, titled `title` and subtitled `subtitle`, and
    /// gives the task, or nil when the system would not register or take it.
    @MainActor
    static func begin(title: String, subtitle: String, onExpire: @escaping @Sendable () -> Void) -> PhoneExportBackgroundTask? {
        let identifier = identifierPrefix + UUID().uuidString
        let task = PhoneExportBackgroundTask(onExpire: onExpire)
        let isRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { launched in
            task.launched(launched)
        }
        guard isRegistered else { return nil }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            DiagnosticLog.event(.app, "EXPORT_TASK refused")
            // The handler stays registered, as the system lets none go; the task is ended, so that a launch it might still
            // get completes at once and holds nothing.
            task.finish(success: false)
            return nil
        }
        return task
    }

    /// The system launched the task: gives it what the export has told so far, and ends it if the export already has.
    private func launched(_ launched: BGTask) {
        guard let task = launched as? BGContinuedProcessingTask else {
            launched.setTaskCompleted(success: false)
            return
        }
        task.progress.totalUnitCount = PhoneExportTaskMirror.totalUnits
        task.expirationHandler = { [onExpire] in onExpire() }
        let pending = state.withLockUnchecked { state -> (PhoneExportTaskMirror.Update?, Bool?) in
            state.task = task
            return (state.latest, state.ended)
        }
        if let update = pending.0 { apply(update, to: task) }
        if let success = pending.1 { task.setTaskCompleted(success: success) }
    }

    /// Shows `update` in `task`: its title and subtitle, and how far it has come.
    private func apply(_ update: PhoneExportTaskMirror.Update, to task: BGContinuedProcessingTask) {
        task.updateTitle(update.title, subtitle: update.subtitle)
        task.progress.completedUnitCount = update.completedUnits
    }

    // MARK: The Export's Word

    func update(_ update: PhoneExportTaskMirror.Update) {
        let task = state.withLockUnchecked { state -> BGContinuedProcessingTask? in
            state.latest = update
            return state.task
        }
        if let task { apply(update, to: task) }
    }

    func finish(success: Bool) {
        let task = state.withLockUnchecked { state -> BGContinuedProcessingTask? in
            state.ended = success
            return state.task
        }
        task?.setTaskCompleted(success: success)
    }
}

extension PhoneExportTasking {
    /// The iPhone's: the system's continued processing task.
    static let system = PhoneExportTasking { title, subtitle, onExpire in
        PhoneExportBackgroundTask.begin(title: title, subtitle: subtitle, onExpire: onExpire)
    }
}
