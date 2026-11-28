import Foundation

/// How far a book read page by page has got, told to the import reading it
/// (FMT34). A picture of several pages, or a comic book archive, is read by
/// text recognition a page at a time, up to seconds a page, so the import
/// overlay counts the pages read, as it counts the tracks it converts:
/// "“Harbour Notices.cbz”, reading its text: 3 of 12 pages".
///
/// The reader learns nothing of the import: it says how many pages it has
/// read (`pagesRead(_:of:)`), and the import that is running on this thread,
/// if any, hears it (`reporting(to:while:)`). The import, the text cache's
/// generation inside it, and the reader all run on the import's own thread,
/// one inside the other, so what an import is told is kept with the thread,
/// as `StorageBoundary` keeps how deep the thread is in its work. A reading
/// outside an import, as a cache rebuild or the reader's own load is, finds
/// nobody listening and tells nobody.
enum ImportPageProgress {
    /// The key under which the thread keeps whom it tells.
    private static let listenerKey = "TextMouth.ImportPageProgress.listener"

    /// Whom a thread tells of the pages read: a class, so the thread's
    /// dictionary holds it as an object.
    private final class Listener {
        /// Told the pages read and the total.
        let report: (_ done: Int, _ total: Int) throws -> Void

        init(_ report: @escaping (_ done: Int, _ total: Int) throws -> Void) {
            self.report = report
        }
    }

    /// Runs `body` with `report` told, on this thread, of every page a
    /// reader reads inside it, then puts back whoever was told before, so
    /// readings may nest.
    static func reporting<Value>(
        to report: @escaping (_ done: Int, _ total: Int) throws -> Void,
        while body: () throws -> Value
    ) rethrows -> Value {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[listenerKey]
        dictionary[listenerKey] = Listener(report)
        defer { dictionary[listenerKey] = previous }
        return try body()
    }

    /// Tells the import running on this thread that `done` of the book's
    /// `total` pages are read; tells nobody outside an import.
    /// - Throws: what the import's listener throws, as a test's step observer
    ///   may, to stop the import there.
    static func pagesRead(_ done: Int, of total: Int) throws {
        guard let listener = Thread.current.threadDictionary[listenerKey] as? Listener else { return }
        try listener.report(done, total)
    }
}
