import Foundation
import Network

// MARK: - Network Reachability (FR02)

/// Whether this Mac can reach the network now, as the cloud services ask it
/// (FR02). A download of a book that is only in the cloud fails at once
/// while this Mac is offline, instead of waiting on a sync service that
/// cannot fetch anything.
///
/// A value wraps the question in a function, so tests answer it themselves
/// (`online`, `offline`, or any function) while the app asks the system
/// through `NWPathMonitor` (`system`).
struct NetworkReachability: Sendable {
    /// Whether this Mac can reach the network now.
    let isOnline: @Sendable () -> Bool

    /// Reachability that answers with `isOnline`.
    init(isOnline: @escaping @Sendable () -> Bool) {
        self.isOnline = isOnline
    }

    /// The system's answer: the current network path, followed by one
    /// `NWPathMonitor` that starts on first use and runs for the life of
    /// the app.
    static let system: NetworkReachability = {
        let monitor = NetworkPathMonitor()
        return NetworkReachability { monitor.isOnline }
    }()

    /// Always online: for tests.
    static let online = NetworkReachability { true }

    /// Always offline: for tests.
    static let offline = NetworkReachability { false }

    /// Whether a network path with `status` lets this Mac reach the
    /// network, where nil means no path has been reported yet.
    ///
    /// Only an unsatisfied path counts as offline. A path that requires a
    /// connection, such as a VPN that connects on demand, comes up when the
    /// sync service connects. Before the monitor's first report, which
    /// follows its start almost at once, the answer is online: a false
    /// "offline" would refuse a download that could work, while a download
    /// that cannot is still caught when it stalls.
    static func isOnline(given status: NWPath.Status?) -> Bool {
        status != .unsatisfied
    }
}

// MARK: - The Path Monitor

/// One `NWPathMonitor` and the status of the latest path it reported
/// (https://developer.apple.com/documentation/network/nwpathmonitor).
///
/// `@unchecked Sendable`: the monitor reports on its own queue while any
/// thread asks `isOnline`, so the reported status is guarded by a lock; the
/// monitor itself is a constant.
private final class NetworkPathMonitor: @unchecked Sendable {
    /// The system's monitor of the current network path.
    private let monitor = NWPathMonitor()
    /// Guards `latestStatus`.
    private let lock = NSLock()
    /// The status of the latest path the monitor reported; nil until its
    /// first report.
    private var latestStatus: NWPath.Status?

    /// Starts monitoring at once, reporting on a queue of its own.
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.record(path.status)
        }
        monitor.start(queue: DispatchQueue(label: "com.textmouth.network-path", qos: .utility))
    }

    deinit {
        monitor.cancel()
    }

    /// Whether this Mac can reach the network, by the latest report.
    var isOnline: Bool {
        NetworkReachability.isOnline(given: lock.withLock { latestStatus })
    }

    /// Keeps the status of a path the monitor reported.
    private func record(_ status: NWPath.Status) {
        lock.withLock { latestStatus = status }
    }
}
