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
    ///   - isOn: Whether sync is set up. With it off every handler does nothing,
    ///     so no task, file, or word comes before a folder is chosen (R1).
    ///   - moment: Tells the sync of a moment (`SyncCenter.moment(_:)`).
    ///   - hold: How long the background hold lasts before it is ended.
    ///   - wait: Waits for a duration; a test's own ends at once.
    static func install(
        on lifeCycle: PhoneLifeCycle,
        isOn: @escaping @MainActor () -> Bool = { SyncCenter.shared.status.isOn },
        moment: @escaping @MainActor (SyncReason) -> Void = { SyncCenter.shared.moment($0) },
        hold: Duration = backgroundHold,
        wait: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        lifeCycle.onDidBecomeActive {
            guard isOn() else { return }
            moment(.active)
        }
        lifeCycle.onDidEnterBackground {
            guard isOn() else { return }
            // The phone may suspend the app as soon as it leaves the screen: a background task keeps it running while the
            // outbox is copied, and ends at the limit, whether or not the sync has finished.
            let end = lifeCycle.beginHold("sync")
            moment(.background)
            Task { @MainActor in
                await wait(hold)
                end()
            }
        }
    }
}
