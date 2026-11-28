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
    static var title: String {
        // Translators: Title of the alert shown when TextMouth is asked to quit while some changes could not be written to disk.
        InterfaceText.line("unsavedChangesPrompt.title", "Some Changes Could Not Be Saved")
    }

    /// What the alert explains: each unsaved subsystem's sentence, as the
    /// Library window's banner words it, between a line saying that
    /// quitting leaves them unsaved and one saying what each button does,
    /// so a VoiceOver user hears the whole decision before choosing.
    static func message(for unsaved: [PersistenceFailure]) -> String {
        let rows = PersistenceBannerRow.rows(for: unsaved).map(\.text)
        return ([quittingLeavesUnsaved] + rows + [choices]).joined(separator: "\n\n")
    }

    /// The line that opens the alert's message, before the list of what is
    /// unsaved.
    static var quittingLeavesUnsaved: String {
        // Translators: First line of the alert's message when quitting would leave changes unsaved; a list of what is unsaved follows it.
        InterfaceText.line("unsavedChangesPrompt.quittingLeavesUnsaved", "Quitting now leaves these changes unsaved:")
    }

    /// What each of the prompt's buttons does. The names it quotes are the
    /// buttons' own words (`retryTitle`, `quitAnywayTitle`, `cancelTitle`),
    /// so the sentence and the buttons agree in every language.
    static var choices: String {
        // Translators: Last line of the alert's message, saying what each button does. %1$@ is the name of the first button, which tries saving again, %2$@ the name of the second, which quits without saving, and %3$@ the name of the third, which keeps TextMouth open. Keep each name exactly as the buttons show it.
        InterfaceText.line("unsavedChangesPrompt.choices", "\(retryTitle) tries again, \(quitAnywayTitle) quits without saving, \(cancelTitle) keeps TextMouth open.")
    }

    /// The first button: tries to save again.
    static var retryTitle: String {
        // Translators: Button of the unsaved-changes alert that tries to save the changes again.
        InterfaceText.line("common.retry", "Retry")
    }

    /// The second button: quits without saving.
    static var quitAnywayTitle: String {
        // Translators: Button of the unsaved-changes alert that quits TextMouth and leaves the changes unsaved.
        InterfaceText.line("unsavedChangesPrompt.quitAnywayTitle", "Quit Anyway")
    }

    /// The third button: keeps TextMouth open.
    static var cancelTitle: String {
        // Translators: Button that closes a sheet or answers a question without doing or changing anything.
        InterfaceText.line("common.cancel", "Cancel")
    }

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
        alert.addButton(withTitle: retryTitle)
        alert.addButton(withTitle: quitAnywayTitle)
        // AppKit gives Escape to a button titled Cancel in the system's
        // language only, so the key is set explicitly, whatever the title.
        let cancelButton = alert.addButton(withTitle: cancelTitle)
        cancelButton.keyEquivalent = "\u{1b}" // l10n: no (the Escape key)
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

    /// Set by Quit Anyway for the one request it makes: the keys of the
    /// unsaved failures its prompt listed, the changes the person chose to
    /// quit without. A failure of another key reported since, such as a feed
    /// change a quit's wait for its records gave up on, is asked about once
    /// more. Keys, not failure IDs: a failure that recurs while a disk is
    /// away is reported again under a new ID for the same file.
    private var quitAnywayCovers: Set<PersistenceFailure.Key>?
    /// Whether the prompt is on its way or showing.
    private var isPrompting = false

    /// What else the prompt's Cancel ends, beside this quit: the app
    /// delegate forgets the work the quit had waited for, which a later quit
    /// must wait for again (`QuitFinisher.forgetFinished()`).
    var promptCancelled: @MainActor () -> Void = {}

#if os(macOS)
    /// A guard over `failureCenter`. Tests replace the flush, the prompt,
    /// and the request to quit, so nothing is shown and nothing quits.
    init(
        failureCenter: PersistenceFailureCenter = .shared,
        flush: @escaping @MainActor () -> Void = UnsavedChangesTerminationGuard.flushPendingWrites,
        prompt: @escaping @MainActor ([PersistenceFailure]) -> UnsavedChangesChoice = UnsavedChangesPrompt.run,
        requestTermination: @escaping @MainActor () -> Void = { QuitRequest.ask() }
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
    ///
    /// When the quit is to go ahead, `whenQuitting` has the last word: it
    /// may hold the quit for work to finish, answering `.terminateCancel`
    /// (and asking to quit again itself later) or `.terminateLater`. A cancel
    /// keeps Quit Anyway for the request that follows, which must not ask
    /// about the changes it covers again; a change reported meanwhile that
    /// its prompt did not list is asked about (`quitAnywayCovers`).
    func reply(
        whenQuitting answer: @MainActor () -> NSApplication.TerminateReply = { .terminateNow }
    ) -> NSApplication.TerminateReply {
        guard !isPrompting else { return .terminateCancel }
        flush()
        let unsaved = failureCenter.unsavedFailures()
        let coveredByQuitAnyway = quitAnywayCovers.map { covered in
            unsaved.allSatisfy { covered.contains($0.key) }
        } ?? false
        let decision = TerminationDecision.decide(
            hasUnsavedChanges: !unsaved.isEmpty,
            userChoseQuitAnyway: coveredByQuitAnyway
        )
        // Quit Anyway answers one request: the one it makes.
        let keptQuitAnyway = quitAnywayCovers
        quitAnywayCovers = nil
        switch decision {
        case .terminate:
            let reply = answer()
            if reply == .terminateCancel {
                quitAnywayCovers = keptQuitAnyway
            }
            return reply
        case .cancelAndPrompt:
            isPrompting = true
            DispatchQueue.main.async { [self] in
                MainActor.assumeIsolated { presentPrompt() }
            }
            return .terminateCancel
        }
    }
#endif

    /// Forgets a Quit Anyway kept for the request that follows work a quit
    /// waited for, when that request is cancelled before it reaches the guard
    /// (a take, an editor's edits, or a library move began meanwhile): the
    /// choice belonged to that quit, and a later one must ask again.
    func forgetQuitAnyway() {
        quitAnywayCovers = nil
    }

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
            quitAnywayCovers = Set(unsaved.map(\.key))
            requestTermination()
        case .cancel:
            promptCancelled()
        }
    }

    /// Writes what the termination path writes, without ending anything:
    /// first every open reader's place, saved now, since a playing reader
    /// saves it only every thirty seconds and no reader window closes as
    /// TextMouth quits (`PlaybackMemoryGuard.saveEveryOpenReaderPosition()`);
    /// then each retry an operation holding the storage work made wait, when
    /// that operation has ended but the retry's turn has not come yet
    /// (`PersistenceFailureCenter.runRetriesKeptForStorageWork()`); then the
    /// library index and every queued book record, those places among them;
    /// then the statistics, whose open listening session is credited so far
    /// but stays open in case the user stays; then the settings changed in
    /// the last moment, whose config.json save waits for changes to pause
    /// (PERF17). Substitution rules are written as they change, so nothing
    /// of theirs is pending. Each write's failure reaches the failure center
    /// before this returns. A quit then cancelled has only saved the places
    /// sooner than their next checkpoints would have. Feed records are
    /// written on a queue of their own, which a quit waits for once it goes
    /// ahead (`FeedStore.quitWork()`), since a write there can be waiting
    /// for an operation only the main actor ends.
    static func flushPendingWrites() {
        // Before the library's flush, so that flush writes the places.
        PlaybackMemoryGuard.shared.saveEveryOpenReaderPosition()
        PersistenceFailureCenter.shared.runRetriesKeptForStorageWork()
        LibraryPersistenceService.flushPendingSave()
        ReadingStatsService.shared.flushPendingSaves()
        ConfigService.shared.flushScheduledSave()
    }
}
