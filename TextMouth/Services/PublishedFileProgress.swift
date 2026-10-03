import Foundation

// MARK: - Progress Published for an Item (FR02)

/// Listens for the progress the system publishes for one item, a file or a
/// book's package folder, as a sync service may while it downloads the
/// item, through `Progress.addSubscriber(forFileURL:withPublishingHandler:)`,
/// and hands on each fraction heard, from 0 to 1.
///
/// The system calls the publishing handler on the main thread for each
/// progress published for the item, one published before the listening
/// began included, with a proxy of the publisher's progress; that proxy's
/// later fractions arrive through key-value observing, on whatever thread
/// the system updates it. The system also hands a folder's listeners the
/// progress published for each item directly inside the folder, and hands
/// on uploads as well as downloads: only a download of the item itself is
/// heard (`isDownload(_:of:)`).
///
/// Whether a sync service publishes at all is up to the service. On the
/// real drives (October 3), iCloud Drive published a book package's
/// progress for the package alone, never for a file inside it; Google Drive
/// published each file's, which a listener on the package was handed too;
/// Dropbox was heard to publish only 0 and 100 percent for small files. A
/// book's download folds what it hears into its progress
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

    /// Starts listening for the progress published for a download of
    /// `item`, a file or a folder, handing each fraction heard to `hear`, on
    /// the thread the system reports it on. The listening goes on until
    /// `stop()`.
    static func listen(to item: URL, hearing hear: @escaping @Sendable (Double) -> Void) -> PublishedFileProgress {
        let listening = PublishedFileProgress()
        let subscriber = Progress.addSubscriber(forFileURL: item) { [weak listening] progress in
            // An upload, or the progress of an item inside a folder
            // listened to, is no part of this item's download.
            if isDownload(progress, of: item) {
                listening?.follow(progress, hearing: hear)
            }
            // Nothing to do when the progress is unpublished: its
            // observation ends with the listening.
            return nil
        }
        listening.keep(subscriber)
        return listening
    }

    /// Whether `progress`, which the system handed to a listener of `item`,
    /// is the progress of a download of `item` itself. An upload is not, nor
    /// the progress published for an item directly inside `item`, which the
    /// system hands a folder's listeners too: such an item has a name of its
    /// own, while the progress of `item` bears its name, however the path to
    /// it is spelled (through a link, say). Progress that names no item is
    /// taken as `item`'s, since the system matched it to `item`.
    ///
    /// The proxy the system hands over keeps the publisher's operation and
    /// URL in its user info, while its `fileOperationKind` and `fileURL`
    /// properties can still read nil at that moment (seen in hosted tests),
    /// so the user info is read first.
    static func isDownload(_ progress: Progress, of item: URL) -> Bool {
        let info = progress.userInfo
        let operation = (info[.fileOperationKindKey] as? String).map(Progress.FileOperationKind.init(rawValue:))
            ?? progress.fileOperationKind
        guard operation != .uploading else { return false }
        guard let published = (info[.fileURLKey] as? URL) ?? progress.fileURL else { return true }
        return published.lastPathComponent.caseInsensitiveCompare(item.lastPathComponent) == .orderedSame
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
