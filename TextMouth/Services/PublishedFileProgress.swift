import Foundation

// MARK: - Progress Published for a File (FR02)

/// Listens for the progress the system publishes for one file, as a sync
/// service may while it downloads the file, through
/// `Progress.addSubscriber(forFileURL:withPublishingHandler:)`, and hands on
/// each fraction heard, from 0 to 1.
///
/// The system calls the publishing handler on the main thread for each
/// progress published for the file, one published before the listening
/// began included, with a proxy of the publisher's progress; that proxy's
/// later fractions arrive through key-value observing, on whatever thread
/// the system updates it. Whether a sync service publishes at all is up to
/// the service: Dropbox was heard to publish only 0 and 100 percent for
/// small files, and iCloud Drive and Google Drive are still to be tried.
/// A book's download folds what it hears into its progress
/// (`BookCloudStorageService`), and the real-drive tests record it.
///
/// `@unchecked Sendable`: the system calls its handlers on the main thread
/// while the download listening stops it from a thread of its own, so every
/// variable is read and changed only under `lock`.
final class PublishedFileProgress: @unchecked Sendable {
    /// Guards every variable below.
    private let lock = NSLock()
    /// The subscription, until `stop()` removes it.
    private var subscriber: Any?
    /// The observations of the progress published so far, until `stop()`
    /// ends them.
    private var observations: [NSKeyValueObservation] = []
    /// Whether `stop()` has been called, after which nothing is heard.
    private var isStopped = false

    /// A listener that has not subscribed yet: `listen(to:hearing:)` makes one.
    private init() {}

    /// A listener let go without `stop()` stops as it goes, so its
    /// subscription never outlives it.
    deinit {
        stop()
    }

    /// Starts listening for the progress published for `file`, handing each
    /// fraction heard to `hear`, on the thread the system reports it on.
    /// The listening goes on until `stop()`.
    static func listen(to file: URL, hearing hear: @escaping @Sendable (Double) -> Void) -> PublishedFileProgress {
        let listening = PublishedFileProgress()
        let subscriber = Progress.addSubscriber(forFileURL: file) { [weak listening] progress in
            listening?.follow(progress, hearing: hear)
            // Nothing to do when the progress is unpublished: its
            // observation ends with the listening.
            return nil
        }
        listening.keep(subscriber)
        return listening
    }

    /// Stops listening: the subscription is removed and every observation
    /// ended, and nothing is heard afterwards. A second stop does nothing.
    func stop() {
        let (subscriber, observations) = lock.withLock { () -> (Any?, [NSKeyValueObservation]) in
            isStopped = true
            defer {
                self.subscriber = nil
                self.observations = []
            }
            return (self.subscriber, self.observations)
        }
        observations.forEach { $0.invalidate() }
        if let subscriber {
            Progress.removeSubscriber(subscriber)
        }
    }

    /// Keeps `subscriber` for `stop()` to remove, or removes it at once when
    /// the listening has already stopped.
    private func keep(_ subscriber: Any) {
        let kept = lock.withLock { () -> Bool in
            guard !isStopped else { return false }
            self.subscriber = subscriber
            return true
        }
        if !kept {
            Progress.removeSubscriber(subscriber)
        }
    }

    /// Hears `progress`, a proxy of progress published for the file: the
    /// fraction it has now, then each later one, until the listening stops.
    private func follow(_ progress: Progress, hearing hear: @escaping @Sendable (Double) -> Void) {
        let observation = progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] progress, _ in
            guard let self, !self.lock.withLock({ self.isStopped }) else { return }
            hear(progress.fractionCompleted)
        }
        let kept = lock.withLock { () -> Bool in
            guard !isStopped else { return false }
            observations.append(observation)
            return true
        }
        if !kept {
            observation.invalidate()
        }
    }
}
