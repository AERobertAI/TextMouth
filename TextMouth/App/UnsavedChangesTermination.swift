#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// What to do with a request to quit (TODO S09).
enum TerminationDecision: Equatable {
    /// Quit now.
    case terminate
    /// Cancel this request, stay open, and ask about the unsaved changes.
    case cancelAndPrompt

    /// The decision for one request to quit: while changes are unsaved, stay
    /// open and ask, unless the user has just chosen Quit Anyway; otherwise
    /// quit. Pure, so the rule is tested without quitting anything.
    static func decide(hasUnsavedChanges: Bool, userChoseQuitAnyway: Bool) -> TerminationDecision {
        hasUnsavedChanges && !userChoseQuitAnyway ? .cancelAndPrompt : .terminate
    }
}

/// The answers to the prompt shown when quitting would leave changes unsaved.
enum UnsavedChangesChoice: Equatable {
    /// Run the unsaved writes again, then ask to quit again.
    case retry
    /// Quit without them.
    case quitAnyway
    /// Keep TextMouth open.
    case cancel
}

/// The prompt shown when quitting would leave changes unsaved: what is
/// unsaved, in the banner's words, then Retry, Quit Anyway, and Cancel.
enum UnsavedChangesPrompt {
    /// The alert's title.
    static let title = "Some Changes Could Not Be Saved"

    /// What the alert explains: each unsaved subsystem's sentence, as the
    /// Library window's banner words it, between a line saying that
    /// quitting leaves them unsaved and one saying what each button does,
    /// so a VoiceOver user hears the whole decision before choosing.
    static func message(for unsaved: [PersistenceFailure]) -> String {
        let rows = PersistenceBannerRow.rows(for: unsaved).map(\.text)
        return (["Quitting now leaves these changes unsaved:"] + rows + [choices]).joined(separator: "\n\n")
    }

    /// What each of the prompt's buttons does.
    static let choices = "Choose Retry to try saving them again, Quit Anyway to quit without them, "
        + "or Cancel to keep TextMouth open."

#if os(macOS)
    /// Shows the prompt as an app-modal alert, bringing TextMouth forward,
    /// and returns the choice. Retry is the default button, so Return
    /// chooses it; Escape chooses Cancel.
    @MainActor
    static func run(_ unsaved: [PersistenceFailure]) -> UnsavedChangesChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message(for: unsaved)
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Quit Anyway")
        // AppKit gives the button titled Cancel the Escape key.
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .retry
        case .alertSecondButtonReturn: return .quitAnyway
        default: return .cancel
        }
    }
#endif
}

/// Holds a request to quit while changes are unsaved (TODO S09). The
/// application delegate's `applicationShouldTerminate` asks `reply()`; the
/// sequence is stated there.
@MainActor
final class UnsavedChangesTerminationGuard {
    /// Where unsaved changes are known.
    private let failureCenter: PersistenceFailureCenter
    /// Writes everything pending, without ending anything.
    private let flush: @MainActor () -> Void
    /// Shows the prompt for the given unsaved failures and returns the choice.
    private let prompt: @MainActor ([PersistenceFailure]) -> UnsavedChangesChoice
    /// Asks AppKit to quit again.
    private let requestTermination: @MainActor () -> Void

    /// Set by Quit Anyway for the one request it makes.
    private var userChoseQuitAnyway = false
    /// Whether the prompt is on its way or showing.
    private var isPrompting = false

#if os(macOS)
    /// A guard over `failureCenter`. Tests replace the flush, the prompt,
    /// and the request to quit, so nothing is shown and nothing quits.
    init(
        failureCenter: PersistenceFailureCenter = .shared,
        flush: @escaping @MainActor () -> Void = UnsavedChangesTerminationGuard.flushPendingWrites,
        prompt: @escaping @MainActor ([PersistenceFailure]) -> UnsavedChangesChoice = UnsavedChangesPrompt.run,
        requestTermination: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }
    ) {
        self.failureCenter = failureCenter
        self.flush = flush
        self.prompt = prompt
        self.requestTermination = requestTermination
    }
#else
    /// A guard over `failureCenter`. The iPhone has no quit to hold: the
    /// prompt defaults to Cancel and the request to quit to nothing.
    init(
        failureCenter: PersistenceFailureCenter = .shared,
        flush: @escaping @MainActor () -> Void = UnsavedChangesTerminationGuard.flushPendingWrites,
        prompt: @escaping @MainActor ([PersistenceFailure]) -> UnsavedChangesChoice = { _ in .cancel },
        requestTermination: @escaping @MainActor () -> Void = {}
    ) {
        self.failureCenter = failureCenter
        self.flush = flush
        self.prompt = prompt
        self.requestTermination = requestTermination
    }
#endif

#if os(macOS)
    /// Answers a request to quit: flushes, then quits unless changes are
    /// left unsaved. If they are, this request is cancelled and the prompt
    /// is shown once AppKit has the answer, since a modal alert run inside
    /// its question would hold up the quit event. A request that arrives
    /// while the prompt is on its way or showing is cancelled without
    /// another prompt.
    func reply() -> NSApplication.TerminateReply {
        guard !isPrompting else { return .terminateCancel }
        flush()
        let decision = TerminationDecision.decide(
            hasUnsavedChanges: failureCenter.hasUnsavedChanges,
            userChoseQuitAnyway: userChoseQuitAnyway
        )
        // Quit Anyway answers one request: the one it makes.
        userChoseQuitAnyway = false
        switch decision {
        case .terminate:
            return .terminateNow
        case .cancelAndPrompt:
            isPrompting = true
            DispatchQueue.main.async { [self] in
                MainActor.assumeIsolated { presentPrompt() }
            }
            return .terminateCancel
        }
    }
#endif

    /// Shows the prompt and carries out the choice. Changes saved since the
    /// request leave nothing to ask about: TextMouth asks to quit again at
    /// once, and that request quits.
    private func presentPrompt() {
        let unsaved = failureCenter.unsavedFailures()
        let choice = unsaved.isEmpty ? nil : prompt(unsaved)
        // The prompt is gone, so the next request is answered afresh.
        isPrompting = false
        switch choice {
        case .none:
            requestTermination()
        case .retry:
            failureCenter.retryUnsavedChanges()
            requestTermination()
        case .quitAnyway:
            userChoseQuitAnyway = true
            requestTermination()
        case .cancel:
            break
        }
    }

    /// Writes what the termination path writes, without ending anything:
    /// first every open reader's place, saved now, since a playing reader
    /// saves it only every thirty seconds and no reader window closes as
    /// TextMouth quits (`PlaybackMemoryGuard.saveEveryOpenReaderPosition()`);
    /// then the library index and every queued book record, those places
    /// among them; then the statistics, whose open listening session is
    /// credited so far but stays open in case the user stays; then the
    /// settings changed in the last moment, whose config.json save waits for
    /// changes to pause (PERF17). Substitution rules are written as they
    /// change, so nothing of theirs is pending. Each write's failure reaches
    /// the failure center before this returns. A quit then cancelled has
    /// only saved the places sooner than their next checkpoints would have.
    static func flushPendingWrites() {
        // Before the library's flush, so that flush writes the places.
        PlaybackMemoryGuard.shared.saveEveryOpenReaderPosition()
        LibraryPersistenceService.flushPendingSave()
        ReadingStatsService.shared.flushPendingSaves()
        ConfigService.shared.flushScheduledSave()
    }
}

// MARK: - Holding a Quit

/// Holds a quit that is sure to go ahead, with nothing unsaved or Quit
/// Anyway chosen, while work a quit must not cut off reaches a safe end:
/// feed downloads keeping their place (`FeedQuitHold`, FR03), a book's
/// text being read again in another encoding (`TextRereads`,
/// encodingchoice), and a book being spoken into an audio file, stopped with
/// its chapters kept (`SpeechExportsUnderWay`, FMT43). The application
/// delegate answers `.terminateLater` while it holds, and TextMouth quits
/// once each piece of work has ended, or has had the longest it may wait, so
/// a quit that leaves TextMouth open never stops anything.
@MainActor
enum QuitHold {
    /// One piece of work a quit may wait for.
    struct Work {
        /// Whether the work runs now, so a quit waits for it.
        let isRunning: @MainActor () -> Bool
        /// Brings the work to its safe end, returning once it is there.
        let end: @MainActor () async -> Void
        /// The longest a quit waits for it: past this, TextMouth quits anyway.
        let longestWait: Duration
    }

    /// Holds the quit while each of `works` that runs now reaches its end,
    /// one after another, each for at most its longest wait, and returns
    /// whether it holds it, for the delegate to answer `.terminateLater`.
    /// `reply` is then called once, with true, as the last of them ends or
    /// gives up waiting. A one-off hold: the application holds its quits
    /// with one `Holder`, so a second request while a quit is held does not
    /// answer twice.
    static func hold(_ works: [Work], reply: @escaping @MainActor (Bool) -> Void) -> Bool {
        Holder().hold(works, reply: reply)
    }

    /// The holder of an application's quits: one hold at a time, whatever
    /// kind of work it waits for. AppKit asks again to quit when the person
    /// presses Command-Q while a quit is held (`.terminateLater`), and a
    /// second hold would stop the same work a second time and reply to
    /// AppKit a second time, which AppKit does not accept. While a hold
    /// waits, a request to hold again is told it is held, and starts, and
    /// replies, nothing: the hold under way replies once.
    @MainActor
    final class Holder {
        /// Whether a hold waits for its work to end now.
        private var isHolding = false

        /// A holder with no hold under way.
        init() {}

        /// Holds the quit as `QuitHold.hold(_:reply:)` does, unless a hold
        /// is under way already, which then answers it: this returns true
        /// and does nothing more.
        func hold(_ works: [Work], reply: @escaping @MainActor (Bool) -> Void) -> Bool {
            guard !isHolding else { return true }
            let running = works.filter { $0.isRunning() }
            guard !running.isEmpty else { return false }
            isHolding = true
            Task {
                for work in running {
                    await QuitHold.end(work)
                }
                // Free again before the reply, in case the quit that follows
                // is refused and a later one must hold afresh.
                isHolding = false
                reply(true)
            }
            return true
        }
    }

    /// Returns once `work` has ended or its longest wait has passed,
    /// whichever comes first.
    fileprivate static func end(_ work: Work) async {
        await withCheckedContinuation { (ended: CheckedContinuation<Void, Never>) in
            let resume = RunOnce { ended.resume() }
            Task {
                await work.end()
                resume.run()
            }
            Task {
                try? await Task.sleep(for: work.longestWait)
                resume.run()
            }
        }
    }
}

/// An action run once, by whichever of its callers comes first: a held
/// quit's wait for one piece of work, ended by the work or by its longest
/// wait (`QuitHold`).
@MainActor
private final class RunOnce {
    /// The action, until it has run.
    private var action: (() -> Void)?

    /// An action run by the first call of `run()`.
    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    /// Runs the action, unless it has run already.
    func run() {
        guard let action else { return }
        self.action = nil
        action()
    }
}
