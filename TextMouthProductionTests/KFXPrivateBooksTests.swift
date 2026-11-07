import XCTest
@testable import TextMouth

/// The user's own DRM-free KFX books, which are not public domain and so are
/// never in the repository, a commit, a sample list, or a log. The user copies
/// them into `build/kfx-private/` in the main checkout; the orchestrator runs
/// this by hand there. In a train's worktree the folder is absent and the
/// test skips.
///
/// It reads each book and reports **only counts**: books, words, headings,
/// pages, and refusals. No title, author, file name, or word is ever written
/// or put in a failure message; a book is named by its place in the sorted
/// list of the folder.
final class KFXPrivateBooksTests: XCTestCase {

    /// The folder, beside this repository's `TextMouthProductionTests`.
    private var folder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/kfx-private", isDirectory: true)
    }

    /// The extensions of the files that are books.
    private static let bookExtensions: Set<String> = ["kfx", "kfx-zip", "azw8", "azw"]

    /// The book files of the folder, sorted by name, not looking inside any `.sdr` folder.
    private func bookFiles() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.sorted()
            .filter { Self.bookExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .map { folder.appendingPathComponent($0) }
    }

    func testEveryPrivateBookReadsAndOnlyCountsAreReported() throws {
        let files = bookFiles()
        try XCTSkipIf(files.isEmpty, "no private books in build/kfx-private")

        var read = 0, words = 0, headings = 0, pages = 0, chapters = 0
        // How many were refused, by the sentence a listener would hear.
        var refusals: [String: Int] = [:]
        for file in files {
            do {
                // Through the import's own readers: .azw is read as the MOBI reader reads it.
                let book = file.pathExtension.lowercased() == "azw"
                    ? try MOBIParser.prepareBook(url: file)
                    : try KFXParser.prepareBook(url: file)
                read += 1
                chapters += book.chapters.count
                for prepared in book.chapters {
                    words += prepared.chapter.wordCount
                    headings += prepared.chapter.headings.count
                    pages += prepared.chapter.pages.count
                }
            } catch {
                // A file-system error names the file, so only the reader's own
                // sentences are kept; anything else is counted by its type.
                let known = error is MOBIError || error is KFXError || error is DocumentTooLargeError
                refusals[known ? error.localizedDescription : "\(type(of: error))", default: 0] += 1
            }
        }
        // The sentences are the reader's fixed ones; a damaged-book sentence carries
        // a detail about the file's structure, never its words or names.
        let refused = refusals.values.reduce(0, +)
        print("KFXPrivateBooks: books=\(files.count) read=\(read) refused=\(refused) chapters=\(chapters) words=\(words) headings=\(headings) pages=\(pages)")
        for (sentence, count) in refusals.sorted(by: { $0.key < $1.key }) {
            print("KFXPrivateBooks: refused \(count) with \u{201C}\(sentence)\u{201D}")
        }
        XCTAssertEqual(read + refused, files.count)
        // A book that is neither read nor refused with a sentence of the reader's own is a bug.
        XCTAssertEqual(refusals.keys.filter { !$0.hasSuffix(".") }.count, 0, "refused with something that is no sentence")
    }
}
