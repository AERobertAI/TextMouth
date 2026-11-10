#if os(macOS)
import AppKit
#else
import Foundation
#endif

/// The words TextMouth says, aloud and on screen, while it finishes work
/// before it quits (`QuitFinisher`). One place, so the announcement and the
/// panel say the same thing, as often as the person asks to quit again.
enum QuitHoldWording {
    /// The panel's title.
    static let title = "Quitting TextMouth"

    /// The words for `phrases`, what each piece of work is doing
    /// (`QuitHold.Work.finishing`): what is under way, and that TextMouth
    /// quits afterwards.
    static func message(finishing phrases: [String]) -> String {
        "TextMouth is finishing up before it quits: \(list(phrases)). It will quit as soon as that is done."
    }

    /// The words for `works`, each as it describes itself now.
    @MainActor
    static func message(for works: [QuitHold.Work]) -> String {
        message(finishing: works.map { $0.finishing() })
    }

    /// `items` in a sentence: "a", "a and b", or "a, b, and c".
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and " + items[items.count - 1]
        }
    }
}

/// Finishes the work a quit must not cut off, for a quit the person asked
/// for, and then asks to quit again.
///
/// The delegate cancels the quit while this works (`finish(_:)` returns
/// true), instead of leaving the quit pending. A pending quit does not ask
/// the delegate again when the person presses Command-Q a second time, or
/// chooses Quit in the Dock: AppKit quits at once, cutting the work off. A
/// cancelled quit does ask. The delegate then asks `answerRepeatedRequest()`,
/// which says again what is finishing and cancels that request too, so a
/// second request never cuts anything off and never goes unanswered.
///
/// The system ending the session while the work is finished is not cancelled,
/// which would stop the log out: `answerSessionEnd(replyLater:)` says the
/// same words, and the reply it keeps is given when the work ends, in place
/// of asking to quit again.
///
/// When the work has ended, or has had its longest wait, `askAgain` asks to
/// quit once more (`QuitRequest.ask()`), and `takeFinished()` tells that
/// request, once, which kinds of work were waited for, so a wait is not begun
/// again for work that gave up waiting, while work of another kind that began
/// meanwhile is waited for.
@MainActor
final class QuitFinisher {
    /// Says its message, aloud and on screen.
    private let tell: @MainActor (String) -> Void
    /// Called when the work has ended, to take the notice down.
    private let finished: @MainActor () -> Void
    /// Asks to quit again.
    private let askAgain: @MainActor () -> Void

    /// The wait for the work, while it runs.
    private var finishing: Task<Void, Never>?
    /// What is said while the work runs, to say again.
    private var message: String?
    /// The kinds of work being waited for now.
    private var waitingFor: Set<String> = []
    /// The kinds of work waited for since the delegate last asked, so the
    /// quit asked again goes ahead without waiting for them again.
    private var waitedFor: Set<String> = []
    /// The reply of a session end that came while the work was finished, to
    /// give when it ends.
    private var sessionReply: (@MainActor (Bool) -> Void)?

    /// A finisher that `tell`s the person what it is finishing, calls
    /// `finished` when the work is done, and `askAgain` to quit again.
    init(
        tell: @escaping @MainActor (String) -> Void,
        finished: @escaping @MainActor () -> Void,
        askAgain: @escaping @MainActor () -> Void = { QuitRequest.ask() }
    ) {
        self.tell = tell
        self.finished = finished
        self.askAgain = askAgain
    }

    /// Whether the work is being finished now.
    var isFinishing: Bool {
        finishing != nil
    }

    /// Starts finishing each of `works` that runs now, one after another,
    /// each for at most its longest wait, saying what it finishes, and
    /// returns whether it did, for the delegate to cancel this quit. When it
    /// returns false, nothing runs and the quit goes ahead. Work already
    /// being finished is not started again.
    func finish(_ works: [QuitHold.Work]) -> Bool {
        guard !isFinishing else { return true }
        let running = works.filter { $0.isRunning() }
        guard !running.isEmpty else { return false }
        let words = QuitHoldWording.message(for: running)
        message = words
        waitingFor = Set(running.map(\.kind))
        tell(words)
        finishing = Task { [weak self] in
            for work in running {
                await QuitHold.end(work)
            }
            self?.didFinish()
        }
        return true
    }

    /// Answers a request to quit that comes while the work is being
    /// finished, such as a second Command-Q: says again what is finishing and
    /// returns true, for the delegate to cancel that request. Returns false
    /// when no work is being finished.
    func answerRepeatedRequest() -> Bool {
        guard isFinishing, let message else { return false }
        tell(message)
        return true
    }

    /// Answers the system ending the session while the work is being
    /// finished: says the same words again and keeps `replyLater`, to be
    /// called with true when the work ends, and returns true, for the
    /// delegate to answer `.terminateLater`. Returns false when no work is
    /// being finished. Only the first reply is kept: a second session end
    /// while one is pending quits at once, whatever is answered.
    func answerSessionEnd(replyLater: @escaping @MainActor (Bool) -> Void) -> Bool {
        guard isFinishing, let message else { return false }
        tell(message)
        if sessionReply == nil {
            sessionReply = replyLater
        }
        return true
    }

    /// The kinds of work waited for since the last call, for the request to
    /// quit that follows. The answer is given once; none when no wait ended.
    func takeFinished() -> Set<String> {
        defer { waitedFor = [] }
        return waitedFor
    }

#if os(macOS)
    /// The answer for a quit that is sure to go ahead, with nothing unsaved
    /// or asked first. Work of a kind in `waitedFor` (`takeFinished()`) was
    /// waited for already, and is not waited for again; the rest that runs is
    /// finished first. The person's quit is cancelled while `finish(_:)`
    /// works and asks again; the system ending the session
    /// (`endsTheSession`) is answered later, with `.terminateLater`,
    /// saying the same words, and `replyLater` called as the work ends, since
    /// a cancel would stop the log out.
    func reply(
        forQuitWith works: [QuitHold.Work],
        waitedFor: Set<String>,
        endsTheSession: Bool,
        replyLater: @escaping @MainActor (Bool) -> Void
    ) -> NSApplication.TerminateReply {
        let remaining = works.filter { !waitedFor.contains($0.kind) }
        guard endsTheSession else {
            return finish(remaining) ? .terminateCancel : .terminateNow
        }
        let running = remaining.filter { $0.isRunning() }
        let held = QuitHold.hold(running) { [self] in
            finished()
            replyLater($0)
        }
        guard held else { return .terminateNow }
        tell(QuitHoldWording.message(for: running))
        return .terminateLater
    }
#endif

    /// The work has ended or had its longest wait: the notice comes down and
    /// the quit goes on, by the reply of a session end that came meanwhile,
    /// or by asking to quit again.
    private func didFinish() {
        finishing = nil
        message = nil
        finished()
        if let reply = sessionReply {
            sessionReply = nil
            reply(true)
            return
        }
        waitedFor = waitingFor
        waitingFor = []
        askAgain()
    }
}
