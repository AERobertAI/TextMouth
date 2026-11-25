import Foundation

// MARK: - When Sync Runs (FR43, section 7)

/// The scheduler's times (section 7), each a constant so a test checks them.
struct SyncTiming: Equatable, Sendable {
    /// After the first unsent change, and at most this often after that.
    var afterChange: TimeInterval = 180
    /// Between the automatic syncs while TextMouth runs.
    var hourly: TimeInterval = 3600
    /// A path must stay satisfied this long before "the network is back" counts.
    var networkHold: TimeInterval = 30
    /// At most one sync for the network's return in this time.
    var networkGap: TimeInterval = 300
}

/// Decides when the automatic moments are due: three minutes after a change,
/// hourly, and when the network is back. A value with no timers of its own:
/// the caller feeds it events with their times, asks what is due, and sleeps
/// until `nextWake`, so a test needs no clock. The launch, the iPhone's
/// activation, Sync Now, the background and quit moments are not decided
/// here: the center runs them at once.
///
/// One run at a time (section 7): while a run is going `nextDue` says
/// nothing, and what came during it makes one run after it.
struct SyncScheduler: Equatable, Sendable {
    /// The times in use.
    var timing = SyncTiming()
    /// Whether a run is going now.
    private(set) var isRunning = false
    /// When the first change not yet sent was made, if any.
    private var firstUnsentChange: Date?
    /// When the last run of any kind finished, which the hourly moment counts from.
    private var lastRunEnd: Date?
    /// When the network came back as a satisfied path, if it is waiting out its hold.
    private var networkBackSince: Date?
    /// When the last run for the network's return started.
    private var lastNetworkRun: Date?
    /// Whether the last path report was satisfied; nil before the first.
    private var pathSatisfied: Bool?
    /// Whether sync is on: nothing is due while it is off (R1).
    var isOn = false

    /// Starts counting the hour from `now`, as sync turns on or the app launches.
    mutating func turnOn(at now: Date) {
        isOn = true
        lastRunEnd = now
    }

    /// Forgets every pending moment: sync stopped.
    mutating func turnOff() {
        self = SyncScheduler(timing: timing)
    }

    /// The library changed at `now`: the first change not yet sent starts the three minutes.
    mutating func noteChange(at now: Date) {
        guard isOn else { return }
        if firstUnsentChange == nil { firstUnsentChange = now }
    }

    /// The network path was reported at `now`. A satisfied path after one
    /// that wasn't starts the hold; an unsatisfied one cancels it.
    mutating func notePath(satisfied: Bool, at now: Date) {
        defer { pathSatisfied = satisfied }
        guard isOn else { return }
        if !satisfied {
            networkBackSince = nil
        } else if pathSatisfied == false {
            networkBackSince = now
        }
    }

    /// A run started at `now`, for `reason`.
    mutating func runStarted(for reason: SyncReason, at now: Date) {
        guard isOn else { return }
        isRunning = true
        // Every run sends what is waiting, so a change made so far is no longer unsent.
        firstUnsentChange = nil
        if reason == .networkBack {
            lastNetworkRun = now
            networkBackSince = nil
        }
    }

    /// The run ended at `now`.
    mutating func runFinished(at now: Date) {
        isRunning = false
        lastRunEnd = now
    }

    /// The moment due at `now`, or nil. While a run is going nothing is
    /// due: the moments wait, and then make one run.
    func nextDue(at now: Date) -> SyncReason? {
        guard isOn, !isRunning else { return nil }
        if let wake = changeDue, now >= wake { return .afterChange }
        if let wake = networkDue, now >= wake { return .networkBack }
        if let wake = hourlyDue, now >= wake { return .hourly }
        return nil
    }

    /// When the caller should look again: the earliest time any moment becomes due.
    func nextWake(after now: Date) -> Date? {
        guard isOn, !isRunning else { return nil }
        return [changeDue, networkDue, hourlyDue].compactMap { $0 }.min()
    }

    // MARK: Each moment's time

    /// Three minutes after the first change not yet sent. A run sends every
    /// change made before it, so the next such change starts three minutes
    /// of its own, and two such runs are never closer than that.
    private var changeDue: Date? {
        firstUnsentChange?.addingTimeInterval(timing.afterChange)
    }

    /// The hold after the network returned, and at least five minutes after the last such run.
    private var networkDue: Date? {
        guard let since = networkBackSince else { return nil }
        let held = since.addingTimeInterval(timing.networkHold)
        guard let last = lastNetworkRun else { return held }
        return max(held, last.addingTimeInterval(timing.networkGap))
    }

    /// An hour after the last run, or after sync turned on.
    private var hourlyDue: Date? {
        lastRunEnd?.addingTimeInterval(timing.hourly)
    }
}
