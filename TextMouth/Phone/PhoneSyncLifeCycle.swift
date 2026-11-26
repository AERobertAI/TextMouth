import Foundation

// PhoneSyncLifeCycle.swift: the iPhone's sync moments that the life cycle makes
// (FR43, section 7 of research/CLOUD-SYNC-BUILD-PLAN-2026-11-25.md): each time
// the app becomes active, and as it goes to the background. Plain types, so the
// Mac's test host runs them with a stand-in for the sync.

/// Joins the sync's moments to the phone's life cycle, as each other slice joins it.
@MainActor
enum PhoneSyncLifeCycle {
    /// The longest the app is held awake in the background to send its outbox
    /// (section 7): the sync reads nothing then, and a hold the system would
    /// cut short is ended before it can.
    static let backgroundHold: Duration = .seconds(20)

    /// Registers the handlers on `lifeCycle`, once for the process.
    /// - Parameters:
    ///   - lifeCycle: The phone's life cycle.
    ///   - launchedInBackground: Whether the app was launched with no screen (a remote Play, say). Its first activation is then
    ///     its first real opening, and a moment like any other; one launched to the screen has its launch sync already.
    ///   - isOn: Whether sync is set up. With it off every handler does nothing,
    ///     so no task, file, or word comes before a folder is chosen (R1).
    ///   - moment: Tells the sync of a moment (`SyncCenter.moment(_:)`).
    ///   - idle: Returns once the sync has nothing running or waiting (`SyncCenter.waitUntilIdle()`).
    ///   - hold: The longest the background hold lasts.
    ///   - wait: Waits for a duration; a test's own ends at once or never.
    static func install(
        on lifeCycle: PhoneLifeCycle,
        launchedInBackground: Bool = false,
        isOn: @escaping @MainActor () -> Bool = { SyncCenter.shared.status.isOn },
        moment: @escaping @MainActor (SyncReason) -> Void = { SyncCenter.shared.moment($0) },
        idle: @escaping @MainActor () async -> Void = { await SyncCenter.shared.waitUntilIdle() },
        hold: Duration = backgroundHold,
        wait: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        // The first activation is the launch itself: the center's own launch moment has begun a full sync already, and a
        // second one at once would read every other device's files again. Each later activation is a moment.
        let activations = ActivationCount(skipsTheFirst: !launchedInBackground)
        lifeCycle.onDidBecomeActive {
            guard activations.isNotTheFirst() else { return }
            guard isOn() else { return }
            moment(.active)
        }
        lifeCycle.onDidEnterBackground {
            guard isOn() else { return }
            // The phone may suspend the app as soon as it leaves the screen: a background task keeps it running while the
            // outbox is sent, and ends when the send does, or at the limit, whichever is first.
            let end = lifeCycle.beginHold("sync")
            moment(.background)
            // Two tasks race: the sync going idle, and the limit. Neither waits for the other (the idle wait can't be
            // cancelled), so the hold ends at whichever comes first, once.
            let finish = HoldEnd(end)
            Task { @MainActor in
                await idle()
                finish.end()
            }
            Task { @MainActor in
                await wait(hold)
                finish.end()
            }
        }
    }
}

/// Counts a life cycle's activations, to tell the first, which is the launch.
@MainActor
private final class ActivationCount {
    private var seen = 0
    /// Whether the first activation is the launch itself.
    private let skipsTheFirst: Bool

    init(skipsTheFirst: Bool) { self.skipsTheFirst = skipsTheFirst }

    /// Notes one activation; whether it is a later one than the first.
    func isNotTheFirst() -> Bool {
        seen += 1
        return seen > 1 || !skipsTheFirst
    }
}

/// A background hold's end, which runs once however many times it is asked.
@MainActor
final class HoldEnd {
    /// What ends the hold.
    private let ending: @MainActor () -> Void
    /// Whether it has ended.
    private var isEnded = false

    init(_ ending: @escaping @MainActor () -> Void) { self.ending = ending }

    /// Ends the hold, the first time only.
    func end() {
        guard !isEnded else { return }
        isEnded = true
        ending()
    }
}
