import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import TextMouth

// Shared by the tests of what the library list, the reader's sheets, and
// closed windows cost (PERF27, PERF28, PERF30): hosting views offscreen,
// letting SwiftUI catch up, reading malloc, and making books and libraries.

// MARK: - Hosting

/// A window for hosted views that never comes on screen, even when the
/// app's VoiceOver focus code asks it forward, as the standard focus request
/// does when no other window is key: a test's window must never appear in
/// front of the user or move VoiceOver.
final class OffscreenTestWindow: NSWindow {
    override func makeKeyAndOrderFront(_ sender: Any?) {}
    override func orderFront(_ sender: Any?) {}
    override func orderFrontRegardless() {}
    override func makeKey() {}
}

extension XCTestCase {
    /// Hosts `view` in a titled `OffscreenTestWindow`, laid out once.
    /// Callers take it down with `takeDown(_:)`.
    @MainActor
    func hostOffscreen<Content: View>(
        _ view: Content,
        size: NSSize = NSSize(width: 900, height: 700)
    ) -> (window: NSWindow, hostingView: NSView) {
        let hostingView = NSHostingView(rootView: view)
        let window = OffscreenTestWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        // The test owns the window; AppKit must not release it again on close.
        window.isReleasedWhenClosed = false
        // An untitled window is taken for a sheet, which focus requests
        // always bring forward.
        window.title = "Hosted views and windows test"
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        return (window, hostingView)
    }

    /// Takes a hosted view out of its window, then closes the window.
    @MainActor
    func takeDown(_ window: NSWindow) {
        window.contentView = NSView()
        window.close()
    }

    /// Spins the main run loop for `seconds`, laying `view` out each turn,
    /// so SwiftUI applies every update published meanwhile.
    @MainActor
    func settle(_ view: NSView?, seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            view?.layoutSubtreeIfNeeded()
        }
    }

    /// One short turn of the main run loop and a layout of `view`, so
    /// SwiftUI applies what was just published.
    @MainActor
    func flush(_ view: NSView?) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.002))
        view?.layoutSubtreeIfNeeded()
    }

    /// How many times the body of each view in `names` ran while `publish`
    /// was called `count` times, each followed by a flush of `view`, after
    /// three warm-up publishes; by view name.
    @MainActor
    func bodyRuns(
        of names: [String],
        in view: NSView?,
        publishing count: Int = 10,
        _ publish: (Int) -> Void
    ) -> [String: Int] {
        for warmUp in 0..<3 {
            publish(-1 - warmUp)
            flush(view)
        }
        let before = names.map { ViewBodyCounter.count(of: $0) }
        for index in 0..<count {
            publish(index)
            flush(view)
        }
        var runs: [String: Int] = [:]
        for (name, countBefore) in zip(names, before) {
            runs[name] = ViewBodyCounter.count(of: name) - countBefore
        }
        return runs
    }
}

// MARK: - Memory

/// Bytes malloc holds for live allocations, across every zone.
func mallocBytesInUse() -> Int {
    var statistics = malloc_statistics_t()
    malloc_zone_statistics(nil, &statistics)
    return Int(statistics.size_in_use)
}

// MARK: - Books and Libraries

extension XCTestCase {
    /// A Markdown book in the test library with `chapters` chapters of about
    /// `charactersPerChapter` characters, each opening with a level-1
    /// heading and holding `sectionsPerChapter` level-2 headings, its text
    /// cache and index written as an import leaves them. Removed when the
    /// test ends.
    @MainActor
    func makeMarkdownBook(chapters: Int, charactersPerChapter: Int, sectionsPerChapter: Int) throws -> Book {
        try TextMouthPaths.ensureDirectoryStructure()
        let name = "ViewsAndWindows-\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: "", tmbName: name)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: package) }
        let file = package.appendingPathComponent("book.md")
        try ViewsAndWindowsFixtures.markdown(
            chapters: chapters,
            charactersPerChapter: charactersPerChapter,
            sectionsPerChapter: sectionsPerChapter
        )
        .write(to: file, atomically: true, encoding: .utf8)
        var book = Book(
            title: "Views and Windows \(UUID().uuidString)",
            format: .markdown,
            filePath: file.path,
            md5Hash: UUID().uuidString,
            tmbDirectoryName: name
        )
        let index = try XCTUnwrap(MarkdownCacheService.generateCacheAnalyzeAndStamp(for: &book))
        try LibraryPersistenceService.saveContentAnalysis(
            for: book, index: index, cacheFormatVersion: book.cacheFormatVersion
        )
        return book
    }
}

/// Libraries and texts for the views and windows tests.
enum ViewsAndWindowsFixtures {
    /// Markdown source of `chapters` chapters: a level-1 heading each, then
    /// `sectionsPerChapter` level-2 headings, and plain paragraphs of one
    /// repeated sentence, about `charactersPerChapter` characters a chapter.
    static func markdown(chapters: Int, charactersPerChapter: Int, sectionsPerChapter: Int) -> String {
        let sentence = "The reader moves through the long passage at an even pace, word after word. "
        let paragraph = String(repeating: sentence, count: 6) + "\n\n"
        let paragraphsPerSection = max(1, charactersPerChapter / (sectionsPerChapter + 1) / paragraph.count)
        var source = ""
        for chapter in 1...chapters {
            source += "<!-- chapter: Chapter \(chapter) -->\n# Chapter \(chapter)\n\n"
            for section in 0...sectionsPerChapter {
                if section > 0 {
                    source += "## Section \(chapter).\(section)\n\n"
                }
                source += String(repeating: paragraph, count: paragraphsPerSection)
            }
        }
        return source
    }

    /// The folder of `shapedLibrary`'s books in manual order.
    static let manualFolder = "Science Fiction"

    /// A library shaped like the user's: `bookCount` books under 12 folders
    /// at the root. The first `manualCount` books are directly in
    /// `manualFolder`, numbered in a manual order; each of the other eleven
    /// folders holds two subfolders sharing the rest. Every other book has
    /// been opened and has a reading position.
    static func shapedLibrary(bookCount: Int = 643, manualCount: Int = 134) -> Library {
        var folders = [BookFolder(name: manualFolder)]
        var books: [Book] = []
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        func addBook(in folder: String, manualOrder: Int?) {
            let number = books.count
            let opened = number % 2 == 0
            books.append(Book(
                title: "Shelved Book \(number)",
                author: "Author \(number % 97)",
                format: .epub,
                filePath: "/nonexistent/views-and-windows/\(number).epub",
                md5Hash: "views-and-windows-\(number)",
                folderPath: folder,
                dateAdded: epoch.addingTimeInterval(Double(number) * 3_600),
                lastOpened: opened ? epoch.addingTimeInterval(Double(number) * 7_200) : nil,
                readingPosition: opened ? ReadingPosition(chapterIndex: 0, characterOffset: number * 10) : nil,
                totalWordCount: 80_000 + number,
                totalCharacterCount: 450_000 + number,
                manualSortOrder: manualOrder
            ))
        }
        for position in 0..<min(manualCount, bookCount) {
            addBook(in: manualFolder, manualOrder: position)
        }
        let others = [
            "Classics", "History", "Mystery", "Poetry", "Science", "Biography",
            "Fantasy", "Essays", "Travel", "Drama", "Philosophy",
        ]
        for name in others {
            folders.append(BookFolder(name: name))
            folders.append(BookFolder(name: "Shelf A", parentPath: name))
            folders.append(BookFolder(name: "Shelf B", parentPath: name))
        }
        let shelves = others.flatMap { ["\($0)/Shelf A", "\($0)/Shelf B"] }
        var shelf = 0
        while books.count < bookCount {
            addBook(in: shelves[shelf % shelves.count], manualOrder: nil)
            shelf += 1
        }
        return Library(books: books, folders: folders)
    }

    /// Moves the reading position of the book `bookID` in `model`'s library:
    /// a change to one book, which publishes the library.
    @MainActor
    static func move(_ bookID: UUID, to offset: Int, in model: LibraryViewModel) {
        guard let index = model.library.books.firstIndex(where: { $0.id == bookID }) else { return }
        model.library.books[index].readingPosition = ReadingPosition(chapterIndex: 0, characterOffset: offset)
    }
}
