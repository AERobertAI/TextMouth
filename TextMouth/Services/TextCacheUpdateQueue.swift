import Foundation

/// Keep ordinary EPUB updates moving on two utility workers without allowing
/// an entire library to parse at once. Large sources and other parsers run alone
/// to avoid stacking their memory use or their own internal parallel work.
enum TextCacheUpdateQueue {
    static let maximumParallelEPUBBytes = 16 * 1024 * 1024

    /// Enqueue independent packages, then finish only after every update callback
    /// has returned. OperationQueue retains itself until its work is complete.
    ///
    /// Each update receives a book as it was when the batch was queued, which
    /// can be minutes old by its turn. That copy names the content to analyze;
    /// the result is committed through `LibraryPersistenceService.saveContentAnalysis`,
    /// which merges it into the book's latest state instead of saving the copy.
    ///
    /// Each update is storage work (TODO S04): a data-directory move waits
    /// for the updates under way and holds the rest until it has published.
    /// A book queued before the move then reaches its update with its file
    /// path in the new data directory.
    static func run(
        books: [Book],
        concurrentEPUBs: Int = 2,
        update: @escaping @Sendable (Book) -> Void,
        completion: @escaping @Sendable () -> Void
    ) {
        // Resolving package aliases and reading file sizes can involve slow
        // storage. Keep that scheduling work off the main actor as well.
        DispatchQueue.global(qos: .utility).async {
            enqueue(books: books, concurrentEPUBs: concurrentEPUBs, update: update, completion: completion)
        }
    }

    /// Inspect and enqueue packages from a utility queue, never from UI code.
    ///
    /// The inspection reads only metadata, with dataless files left in the
    /// cloud (FR02): resolving a path through a dataless folder fails instead
    /// of downloading its listing, and a source whose size cannot be read
    /// runs alone, as a large one does. Each update decides for itself
    /// whether its book's files are on this Mac to be read.
    private static func enqueue(
        books: [Book],
        concurrentEPUBs: Int,
        update: @escaping @Sendable (Book) -> Void,
        completion: @escaping @Sendable () -> Void
    ) {
        let queue = OperationQueue()
        queue.name = "com.textmouth.cacheUpdates"
        queue.qualityOfService = .utility
        // Serial mode supports comparative profiling; callers cannot raise the
        // production cap and accidentally schedule an unbounded parser batch.
        queue.maxConcurrentOperationCount = min(2, max(1, concurrentEPUBs))
        var scheduledPackages: Set<String> = []

        for book in books {
            let (package, size) = DatalessFiles.withoutDownloading { () -> (String, Int?) in
                (
                    book.tmbDirectory.resolvingSymlinksInPath().standardizedFileURL.path,
                    try? URL(fileURLWithPath: book.filePath).resourceValues(forKeys: [.fileSizeKey]).fileSize
                )
            }
            let isRepeatedPackage = !scheduledPackages.insert(package).inserted
            let canOverlap = book.format == .epub && !isRepeatedPackage
                && size.map { $0 <= maximumParallelEPUBBytes } == true
            let operation: @Sendable () -> Void = {
                StorageBoundary.shared.perform(.textExtraction) { _ in
                    update(StorageBoundary.shared.rebasedToCurrent(book))
                }
            }
            if canOverlap {
                queue.addOperation(operation)
            } else {
                // A barrier also prevents duplicate package aliases from writing
                // the same content.md concurrently inside this batch.
                queue.addBarrierBlock(operation)
            }
        }
        queue.addBarrierBlock(completion)
    }
}
