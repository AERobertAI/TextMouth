import Foundation

// MARK: - The Plan

/// The decisions of the iPhone's copy step, which runs before the shared
/// import ever sees a file (the spec's "Adding a book", the engineering
/// review's F14): where the scratch copies go, how much room a copy needs,
/// and how a file iCloud hasn't downloaded is named. Pure functions, so the
/// Mac's tests reach every one.
enum PhoneImportCopyPlan {
    /// The folder, in the app's temporary directory, that holds every
    /// scratch copy: `tmp/PhoneImport`. Swept at launch, and once nothing
    /// imports and no question waits.
    static let scratchFolderName = "PhoneImport"

    /// How many times a book's size must be free before it is copied: once
    /// for the scratch copy, once for the library's own copy the shared
    /// import makes from it.
    static let roomFactor: Int64 = 2

    /// `tmp/PhoneImport` in the temporary directory `temporary`.
    static func scratchRoot(in temporary: URL) -> URL {
        temporary.appendingPathComponent(scratchFolderName, isDirectory: true)
    }

    /// The scratch folder of one item: `tmp/PhoneImport/<id>`, a folder of
    /// its own, so two items with one name never meet. The copy inside keeps
    /// the item's own name, since the book's title comes from it.
    static func scratchFolder(in temporary: URL, id: UUID) -> URL {
        scratchRoot(in: temporary).appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// The bytes that must be free to copy items of `sourceBytes` in all:
    /// `roomFactor` times as many, kept from overflowing.
    static func neededBytes(forSourceBytes sourceBytes: Int64) -> Int64 {
        let (product, overflowed) = max(sourceBytes, 0).multipliedReportingOverflow(by: roomFactor)
        return overflowed ? .max : product
    }

    /// Whether `availableBytes` free is room for items of `sourceBytes`. A
    /// volume that doesn't say how much is free is given the benefit of the
    /// doubt: the copy then fails on its own if the space runs out, and says
    /// so in the Mac's words.
    static func hasRoom(availableBytes: Int64?, sourceBytes: Int64) -> Bool {
        guard let availableBytes else { return true }
        return availableBytes >= neededBytes(forSourceBytes: sourceBytes)
    }

    /// The real name of a file iCloud lists by a placeholder, as
    /// ".Dune.epub.icloud" stands for "Dune.epub"; nil for any other name.
    /// A coordinated read of the real name downloads the file.
    static func realFileName(ofPlaceholder name: String) -> String? {
        let prefix = "."
        let suffix = ".icloud"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix), name.count > prefix.count + suffix.count else { return nil }
        return String(name.dropFirst(prefix.count).dropLast(suffix.count))
    }

    /// Whether `url` lies inside `folder`, comparing their standardized,
    /// symlink-resolved paths, so "/private/var/…" and "/var/…" agree. The
    /// folder itself is not inside itself.
    static func isInside(_ url: URL, folder: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        var folderPath = folder.standardizedFileURL.resolvingSymlinksInPath().path
        if !folderPath.hasSuffix("/") { folderPath += "/" }
        return path.hasPrefix(folderPath)
    }
}

// MARK: - The Stall Limit

/// Whether a download has stalled: no progress for `limit` (two minutes, as
/// the spec says), a pure value with time passed in, so tests need no clock.
/// Progress is any change in what `Marker` reads of the files being
/// downloaded, or access being granted, which ends the watch.
struct PhoneImportStallWatch: Equatable {
    /// What is read of an item's files to see whether a download moves.
    struct Marker: Equatable, Sendable {
        /// How many of the item's files are no longer only in the cloud.
        let downloadedFiles: Int
        /// The bytes the item's files take on this device so far.
        let localBytes: Int64
    }

    /// How long a download may make no progress before the copy is cancelled.
    static let limit: TimeInterval = 120

    /// The last marker read, nil before the first.
    private(set) var lastMarker: Marker?
    /// When progress was last seen: the watch's start, or the last change.
    private(set) var lastProgress: Date

    /// A watch that starts counting at `start`.
    init(startingAt start: Date) {
        lastProgress = start
    }

    /// Takes `marker`, read at `date`: a change from the last is progress,
    /// and restarts the count. The first marker is the baseline.
    mutating func note(_ marker: Marker, at date: Date) {
        if let lastMarker, lastMarker != marker {
            lastProgress = date
        }
        lastMarker = marker
    }

    /// Whether no progress has been seen for `limit` by `date`.
    func hasStalled(at date: Date) -> Bool {
        date.timeIntervalSince(lastProgress) >= Self.limit
    }
}

// MARK: - One Item

/// One item a person chose or another app sent, planned for its copy: a file,
/// or a folder (a DAISY book's folder, a folder of tracks, or a TextMouth
/// package), whose files are coordinated one by one, since a coordinated read
/// of a folder doesn't bring down its children.
struct PhoneImportCopyItem: Equatable, Sendable {
    /// One file to copy.
    struct File: Equatable, Sendable {
        /// Where it is read from: for a placeholder iCloud lists, the real
        /// name's URL, whose coordinated read downloads it.
        let source: URL
        /// Its path inside the item, "Dune.epub" for a file item, and
        /// "Disc 1/01.mp3" for a track in a folder.
        let relativePath: String
    }

    /// The URL chosen or sent, which the scope is started on.
    let source: URL
    /// Its name, which its copy keeps.
    let name: String
    /// Whether it is a folder, whose copy is a folder of the same name.
    let isFolder: Bool
    /// Its files, in a stable order.
    let files: [File]
    /// Their size in all, as far as their metadata tells.
    let byteCount: Int64
    /// Whether any file is only in the cloud, so the copy downloads it first,
    /// and the card says "Downloading".
    let needsDownload: Bool

    /// The item at `url`, planned by listing it. Reads metadata only: no
    /// file's content is read, and nothing is downloaded.
    /// - Throws: the file system's error when `url` can't be read at all.
    static func plan(for url: URL) throws -> PhoneImportCopyItem {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
        let values = try url.resourceValues(forKeys: keys)
        let name = url.lastPathComponent
        guard values.isDirectory == true else {
            let realURL = realURL(of: url)
            return PhoneImportCopyItem(
                source: url,
                name: realURL.lastPathComponent,
                isFolder: false,
                files: [File(source: realURL, relativePath: realURL.lastPathComponent)],
                byteCount: Int64(values.fileSize ?? 0),
                needsDownload: isOnlyInCloud(url)
            )
        }
        var files: [File] = []
        var bytes: Int64 = 0
        var needsDownload = false
        // Hidden files are listed too: iCloud may list a file not yet
        // downloaded as a hidden placeholder, which stands for a real file.
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [])
        let base = url.standardizedFileURL.resolvingSymlinksInPath().path
        while let child = enumerator?.nextObject() as? URL {
            let childValues = try? child.resourceValues(forKeys: keys)
            guard childValues?.isDirectory != true else { continue }
            let realChild = realURL(of: child)
            let childPath = realChild.standardizedFileURL.resolvingSymlinksInPath().path
            // The path inside the item; a child that somehow lies outside it
            // is copied by its name alone.
            let relative = childPath.hasPrefix(base + "/") ? String(childPath.dropFirst(base.count + 1)) : realChild.lastPathComponent
            files.append(File(source: realChild, relativePath: relative))
            bytes += Int64(childValues?.fileSize ?? 0)
            needsDownload = needsDownload || isOnlyInCloud(child)
        }
        files.sortStably { $0.relativePath < $1.relativePath }
        return PhoneImportCopyItem(source: url, name: name, isFolder: true, files: files, byteCount: bytes, needsDownload: needsDownload)
    }

    /// The URL a coordinated read must name for the file at `url`: its real
    /// name's, when `url` is an iCloud placeholder; `url` itself otherwise.
    private static func realURL(of url: URL) -> URL {
        guard let real = PhoneImportCopyPlan.realFileName(ofPlaceholder: url.lastPathComponent) else { return url }
        return url.deletingLastPathComponent().appendingPathComponent(real)
    }

    /// Whether the file at `url` is only in the cloud: an iCloud placeholder,
    /// a dataless file, or an item whose downloading status isn't current.
    private static func isOnlyInCloud(_ url: URL) -> Bool {
        if PhoneImportCopyPlan.realFileName(ofPlaceholder: url.lastPathComponent) != nil { return true }
        if DatalessFiles.isDataless(url) { return true }
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard values?.isUbiquitousItem == true, let status = values?.ubiquitousItemDownloadingStatus else { return false }
        return status != .current
    }

    /// What the stall watch reads of this item's files now.
    func marker() -> PhoneImportStallWatch.Marker {
        var downloaded = 0
        var localBytes: Int64 = 0
        for file in files {
            if !DatalessFiles.isDataless(file.source), FileManager.default.fileExists(atPath: file.source.path) {
                downloaded += 1
            }
            let values = try? file.source.resourceValues(forKeys: [.fileAllocatedSizeKey])
            localBytes += Int64(values?.fileAllocatedSize ?? 0)
        }
        return PhoneImportStallWatch.Marker(downloadedFiles: downloaded, localBytes: localBytes)
    }

    /// Copies this item's files, read at `grantedURLs` (each file's URL as
    /// its coordinated read granted it, in `files`' order), into `folder`,
    /// keeping their names and the folder's shape. Stops between files once
    /// `cancellation` is cancelled.
    /// - Returns: The copy of the item: the file, or the folder.
    /// - Throws: `ImportCancelled` once cancelled; the file system's error
    ///   for a file that can't be copied.
    func copy(readingFrom grantedURLs: [URL], into folder: URL, cancellation: ImportCancellation) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let itemCopy = folder.appendingPathComponent(name, isDirectory: isFolder)
        if isFolder {
            try manager.createDirectory(at: itemCopy, withIntermediateDirectories: true)
        }
        for (index, file) in files.enumerated() {
            guard !cancellation.isCancelled else { throw ImportCancelled() }
            let readURL = index < grantedURLs.count ? grantedURLs[index] : file.source
            let destination = isFolder ? itemCopy.appendingPathComponent(file.relativePath) : itemCopy
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.copyItem(at: readURL, to: destination)
        }
        return itemCopy
    }
}

// MARK: - One Run

/// One coordinated copy of the items a person chose or another app sent,
/// into scratch folders of the app's own, before the shared import is handed
/// the copies (the spec's "Adding a book", the engineering review's F14).
///
/// Nothing reads a chosen file plainly: each file is read under
/// `NSFileCoordinator`, which downloads a file that's only in iCloud first
/// ("the coordinated read operation blocks until the file finishes
/// downloading (or fails to download)", Apple's iCloud design guide). The
/// asynchronous form, `coordinate(with:queue:byAccessor:)`, keeps the wait
/// off every queue, so `cancel()` (Cancel Import) and the stall limit can end
/// it from the main thread: the header says `cancel()` "can be invoked from
/// any thread" and a waiting call then "will stop waiting and return
/// immediately" with `NSUserCancelledError`.
///
/// The run works on a queue of its own, never the import queue, so a file
/// provider that hangs never holds up an import. It starts each item's
/// security scope, checks there is room for twice the items' size, copies,
/// stops the scopes, and says how it ended once, on the main thread.
@MainActor
final class PhoneImportCopyRun {
    /// How a run ended.
    enum Outcome: Equatable, Sendable {
        /// Every item was copied: their copies, in the order given.
        case copied([URL])
        /// There wasn't room for twice the items' size.
        case noRoom
        /// The item named `name` made no download progress for the stall
        /// limit, and its copy was cancelled.
        case stalled(name: String)
        /// `cancel()` was called.
        case cancelled
        /// The item named `name` couldn't be read or copied, for
        /// `description`, the system's sentence.
        case failed(name: String, description: String)
    }

    /// What the run is doing, for the progress card.
    struct Status: Equatable, Sendable {
        /// The item being copied, by its display name ("Dune").
        let name: String
        /// Whether it is coming down from the cloud.
        let isDownloading: Bool
    }

    /// The URLs to copy, in order.
    let sources: [URL]
    /// Where the scratch folders go: the app's temporary directory.
    private let temporaryDirectory: URL
    /// How many bytes are free where the scratch folders go, nil when the
    /// volume doesn't say: `volumeAvailableCapacityForImportantUsage`, unless
    /// a test passes its own.
    private let availableBytes: @Sendable (URL) -> Int64?
    /// Tells the time, for the stall limit.
    private let now: @MainActor () -> Date
    /// How often a download's progress is read.
    private let stallCheckInterval: TimeInterval
    /// Told on the main thread each time the item under way changes.
    private let statusChanged: @MainActor (Status?) -> Void

    /// The run's own serial queue, which plans, starts and stops the scopes,
    /// and copies; never the import queue.
    private let workQueue = DispatchQueue(label: "com.textmouth.phone-import-copy", qos: .userInitiated)
    /// The queue the coordinator calls each accessor on, over `workQueue`.
    private let accessQueue: OperationQueue
    /// Ends a copy between files, set by `cancel()` and the stall limit.
    private let cancellation = ImportCancellation()
    /// The coordinator of the item waiting for access, nil between items.
    private var coordinator: NSFileCoordinator?
    /// The stall limit's timer while an item waits for access.
    private var stallTimer: Timer?
    /// The watch of the item waiting for access.
    private var stallWatch: PhoneImportStallWatch?
    /// Why the run is ending early, set before the coordinator is cancelled.
    private var endingReason: Outcome?
    /// The copies made so far, in order.
    private var copies: [URL] = []
    /// The items, once planned.
    private var items: [PhoneImportCopyItem] = []
    /// The scopes started, to stop at the end.
    private var scopedURLs: [URL] = []
    /// Called once, as the run ends.
    private var completion: (@MainActor (Outcome) -> Void)?

    /// A run over `sources`. The defaults are the app's: the system's
    /// temporary directory and free space, the clock, a check every five
    /// seconds.
    init(
        sources: [URL],
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        availableBytes: @escaping @Sendable (URL) -> Int64? = PhoneImportCopyRun.systemAvailableBytes(at:),
        now: @escaping @MainActor () -> Date = { Date() },
        stallCheckInterval: TimeInterval = 5,
        statusChanged: @escaping @MainActor (Status?) -> Void = { _ in }
    ) {
        self.sources = sources
        self.temporaryDirectory = temporaryDirectory
        self.availableBytes = availableBytes
        self.now = now
        self.stallCheckInterval = stallCheckInterval
        self.statusChanged = statusChanged
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.underlyingQueue = workQueue
        queue.name = "com.textmouth.phone-import-copy.access"
        accessQueue = queue
    }

    /// The bytes free for important use on the volume of `url`, which is what
    /// Apple's documentation says to check before a copy a person asked for.
    nonisolated static func systemAvailableBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Starts the run; `completion` hears how it ended, once, on the main
    /// thread. A second call does nothing.
    func start(completion: @escaping @MainActor (Outcome) -> Void) {
        guard self.completion == nil else { return }
        self.completion = completion
        let sources = sources
        let temporary = temporaryDirectory
        let availableBytes = availableBytes
        workQueue.async { [weak self] in
            // Read once, so the closures below capture a constant.
            let run = self
            // The scopes start first: listing a security-scoped folder needs it.
            let scoped = sources.filter { $0.startAccessingSecurityScopedResource() }
            var planned: [PhoneImportCopyItem] = []
            var failure: Outcome?
            for source in sources {
                do {
                    planned.append(try PhoneImportCopyItem.plan(for: source))
                } catch {
                    failure = .failed(name: source.lastPathComponent, description: error.localizedDescription)
                    break
                }
            }
            if failure == nil {
                let total = planned.reduce(Int64(0)) { $0 + $1.byteCount }
                // The folder the copies go in may not exist yet: its volume is
                // the temporary directory's.
                if !PhoneImportCopyPlan.hasRoom(availableBytes: availableBytes(temporary), sourceBytes: total) {
                    failure = .noRoom
                }
            }
            // Constants, for the closure that crosses to the main thread.
            let plan = planned
            let ending = failure
            DispatchQueue.main.async {
                run?.planned(plan, scoped: scoped, failure: ending)
            }
        }
    }

    /// Cancels the run: an item waiting for access stops waiting, and a copy
    /// under way stops before its next file. Its scratch copies are left for
    /// the sweep. Does nothing once the run has ended.
    func cancel() {
        end(early: .cancelled)
    }

    // MARK: Steps

    /// Takes the plan made on the work queue: copies its first item, or ends
    /// with `failure`.
    private func planned(_ planned: [PhoneImportCopyItem], scoped: [URL], failure: Outcome?) {
        scopedURLs = scoped
        items = planned
        if let failure {
            finish(failure)
        } else if endingReason != nil {
            finish(endingReason ?? .cancelled)
        } else {
            copyItem(at: 0)
        }
    }

    /// Copies the item at `index` under coordination, or ends the run once
    /// every item is copied.
    private func copyItem(at index: Int) {
        if let endingReason {
            finish(endingReason)
            return
        }
        guard index < items.count else {
            finish(.copied(copies))
            return
        }
        let item = items[index]
        statusChanged(Status(name: PhoneImportWording.displayName(ofFileNamed: item.name), isDownloading: item.needsDownload))
        let intents = item.files.map { NSFileAccessIntent.readingIntent(with: $0.source, options: []) }
        let folder = PhoneImportCopyPlan.scratchFolder(in: temporaryDirectory, id: UUID())
        let coordinator = NSFileCoordinator(filePresenter: nil)
        self.coordinator = coordinator
        startStallWatch(for: item)
        let cancellation = cancellation
        coordinator.coordinate(with: intents, queue: accessQueue) { [weak self] error in
            // On the access queue: the files can be read only inside here.
            let run = self
            let result: Result<URL, Error>
            if let error {
                result = .failure(error)
            } else {
                // Access is granted: the download, if any, is done.
                DispatchQueue.main.async { run?.stopStallWatch() }
                do {
                    result = .success(try item.copy(readingFrom: intents.map(\.url), into: folder, cancellation: cancellation))
                } catch {
                    result = .failure(error)
                }
            }
            DispatchQueue.main.async {
                run?.copiedItem(at: index, result: result)
            }
        }
    }

    /// Takes the result of the item at `index`'s copy: the next item, or the
    /// end of the run.
    private func copiedItem(at index: Int, result: Result<URL, Error>) {
        stopStallWatch()
        coordinator = nil
        switch result {
        case .success(let copy):
            copies.append(copy)
            copyItem(at: index + 1)
        case .failure(let error):
            if let endingReason {
                finish(endingReason)
            } else if error is ImportCancelled || Self.isCancellation(error) {
                finish(.cancelled)
            } else {
                finish(.failed(name: items[index].name, description: error.localizedDescription))
            }
        }
    }

    /// Whether `error` is the coordinator's word for a cancelled wait.
    private static func isCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
    }

    /// Ends the run early for `reason`: the coordinator stops waiting, the
    /// copy stops before its next file, and the end follows from the
    /// coordinator's call, or at once when nothing waits.
    private func end(early reason: Outcome) {
        guard completion != nil, endingReason == nil else { return }
        endingReason = reason
        cancellation.cancel()
        stopStallWatch()
        coordinator?.cancel()
    }

    /// Ends the run with `outcome`, once: the scopes stop on the work queue,
    /// the card hears nothing is under way, and `completion` is told.
    private func finish(_ outcome: Outcome) {
        guard let completion else { return }
        self.completion = nil
        stopStallWatch()
        coordinator = nil
        let scoped = scopedURLs
        scopedURLs = []
        workQueue.async {
            for url in scoped { url.stopAccessingSecurityScopedResource() }
        }
        statusChanged(nil)
        completion(outcome)
    }

    // MARK: The Stall Limit

    /// Starts reading `item`'s download progress every `stallCheckInterval`,
    /// for an item that needs downloading; one already here never stalls.
    private func startStallWatch(for item: PhoneImportCopyItem) {
        stopStallWatch()
        guard item.needsDownload else { return }
        stallWatch = PhoneImportStallWatch(startingAt: now())
        let timer = Timer(timeInterval: stallCheckInterval, repeats: true) { [weak self] _ in
            // A timer on the main run loop fires on the main thread.
            MainActor.assumeIsolated { self?.checkStall(of: item) }
        }
        RunLoop.main.add(timer, forMode: .common)
        stallTimer = timer
    }

    /// Reads `item`'s progress off the main thread, then judges it on it.
    private func checkStall(of item: PhoneImportCopyItem) {
        workQueue.async { [weak self] in
            let run = self
            let marker = item.marker()
            DispatchQueue.main.async {
                run?.judgeStall(marker, of: item)
            }
        }
    }

    /// Notes `marker` and ends the run once `item` has made no progress for
    /// the stall limit.
    private func judgeStall(_ marker: PhoneImportStallWatch.Marker, of item: PhoneImportCopyItem) {
        guard var watch = stallWatch else { return }
        let date = now()
        watch.note(marker, at: date)
        stallWatch = watch
        if watch.hasStalled(at: date) {
            end(early: .stalled(name: PhoneImportWording.displayName(ofFileNamed: item.name)))
        }
    }

    /// Stops the stall limit's timer.
    private func stopStallWatch() {
        stallTimer?.invalidate()
        stallTimer = nil
        stallWatch = nil
    }
}
