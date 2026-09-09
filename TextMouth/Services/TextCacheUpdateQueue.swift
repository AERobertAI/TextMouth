import Foundation

/// Keep ordinary EPUB updates moving on two utility workers without allowing
/// an entire library to parse at once. Large sources and other parsers run alone
/// to avoid stacking their memory use or their own internal parallel work.
enum TextCacheUpdateQueue {
    static let maximumParallelEPUBBytes = 16 * 1024 * 1024

    /// Enqueue independent packages, then finish only after every update callback
    /// has returned. OperationQueue retains itself until its work is complete.
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
            let package = book.tmbDirectory.resolvingSymlinksInPath().standardizedFileURL.path
            let isRepeatedPackage = !scheduledPackages.insert(package).inserted
            let size = try? URL(fileURLWithPath: book.filePath).resourceValues(forKeys: [.fileSizeKey]).fileSize
            let canOverlap = book.format == .epub && !isRepeatedPackage
                && size.map { $0 <= maximumParallelEPUBBytes } == true
            let operation: @Sendable () -> Void = { update(book) }
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
