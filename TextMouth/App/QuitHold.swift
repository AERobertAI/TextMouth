import Foundation

/// The work a quit that is sure to go ahead, with nothing unsaved or Quit
/// Anyway chosen, must not cut off, and how it waits for it: feed downloads
/// keeping their place (`FeedQuitHold`, FR03), a book's text being read again
/// in another encoding (`TextRereads`, encodingchoice), and a book being
/// spoken into an audio file, stopped with its chapters kept
/// (`SpeechExportsUnderWay`, FMT43).
///
/// There are two ways, by who asks (`AppDelegate.applicationShouldTerminate`):
///
/// - The person quits (Command-Q, the Quit menu item, the Dock): `QuitFinisher`
///   cancels that quit, says what it is finishing, ends the work, and asks to
///   quit again. The quit is not left pending, since a second request to quit
///   while a reply is pending quits at once without asking the delegate
///   (shown by the review's `terminate_later` and `terminate_key` probes),
///   which cut the work off.
/// - The system ends the session (log out, restart, shut down): `hold` answers
///   `.terminateLater`, since a cancel would stop the log out, and replies once
///   each piece of work has ended, or has had the longest it may wait.
///
/// Either way a quit waits no longer than the sum of the work's longest
/// waits, so work that cannot end never keeps TextMouth open.
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
        /// What kind of work it is, the same for every piece of that kind
        /// ("feeds", "rereads", "exports"). A quit that waited for a kind goes
        /// on without waiting for that kind again, but waits for a kind that
        /// began in the meantime (`QuitFinisher`).
        let kind: String
        /// What the work is doing for the quit, as a phrase after "TextMouth is
        /// finishing up before it quits:", such as "reading a book's text
        /// again". It is said aloud and shown (`QuitHoldWording`), and counts
        /// the work when several pieces of a kind run, so it is read when the
        /// quit is asked, not when the work is made.
        let finishing: @MainActor () -> String
    }

    /// Holds the quit while each of `works` that runs now reaches its end,
    /// one after another, each for at most its longest wait, and returns
    /// whether it holds it, for the delegate to answer `.terminateLater`.
    /// `reply` is then called once, with true, as the last of them ends or
    /// gives up waiting. Only for the system ending the session: a quit the
    /// person asks for goes through `QuitFinisher`.
    static func hold(_ works: [Work], reply: @escaping @MainActor (Bool) -> Void) -> Bool {
        let running = works.filter { $0.isRunning() }
        guard !running.isEmpty else { return false }
        Task {
            for work in running {
                await end(work)
            }
            reply(true)
        }
        return true
    }

    /// Returns once `work` has ended or its longest wait has passed,
    /// whichever comes first.
    static func end(_ work: Work) async {
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
