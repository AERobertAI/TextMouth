import XCTest
import os
@testable import TextMouth

/// The limit on nesting in the export walk (#5512, `ExportDocumentWalker`):
/// a content.md that nests block quotes, lists, emphasis, or links past what
/// the reader reads is refused with `ExportWalkError.nestedTooDeeply`, naming
/// the chapter, before any writer is handed a document; anything nested as
/// books nest, and up to the limit, walks as it did, and is written by every
/// writer; and the walk runs on a thread whose stack holds a tree at the
/// limit, however small the stack of the thread that asks.
///
/// Edit Text lets the user's own text into content.md, so a text of a few
/// thousand `>` marks reached a walk that calls itself once for each level of
/// nesting. Every depth that reaches the walk here is one the old walk,
/// with no limit, survives on a main thread's stack (a few hundred levels);
/// the very deep texts go to the layers that never recurse, in
/// `MarkdownDepthLimitTests`. Hermetic: no library, and the writers write
/// into a sandbox folder.
@MainActor
final class ExportDocumentWalkerNestingTests: XCTestCase {

    // MARK: - Helpers

    private let limits = MarkupGuard.Limits.standard

    /// The document of `markdown`, walked as `options` ask.
    private func walk(_ markdown: String, options: ExportWalkOptions = .plain) throws -> ExportDocument {
        try ExportDocumentWalker.document(fromMarkdown: markdown, book: ExportBookDetails(title: ""), options: options)
    }

    /// Every word of `document`, block by block, joined.
    private func words(of document: ExportDocument) -> String {
        document.blocks.map(\.plainText).joined(separator: " ")
    }

    /// The refusal a walk of `markdown` ends with, or nil when it walks.
    private func refusal(of markdown: String, options: ExportWalkOptions = .plain) -> ExportWalkError? {
        do {
            _ = try walk(markdown, options: options)
            return nil
        } catch {
            XCTAssertTrue(error is ExportWalkError, "\(error)")
            return error as? ExportWalkError
        }
    }

    /// `ExportWalkError.nestedTooDeeply` for the chapter `chapter`, at the standard limit.
    private func tooDeep(chapter: String = "") -> ExportWalkError {
        .nestedTooDeeply(chapter: chapter, limit: limits.deepestNesting)
    }

    // MARK: - The limit

    /// A text nested as far as the limit allows is walked, with its words
    /// kept, and one level more is refused, for every shape, and for the walk
    /// of the words alone and of the book's structure alike.
    func testEveryShapeWalksAtTheLimitAndIsRefusedJustPastIt() throws {
        for options in [ExportWalkOptions.plain, .bookStructure] {
            for shape in DeepMarkdown.shapes() {
                let document = try walk(shape.text(shape.edge), options: options)
                XCTAssertTrue(words(of: document).contains(shape.word), "\(shape.name) at \(shape.edge) lost its words")
                XCTAssertEqual(refusal(of: shape.text(shape.edge + 1), options: options), tooDeep(), "\(shape.name) just past")
            }
        }
    }

    /// Texts nested as books nest, and as the walk has always cut them (a
    /// list or quote deeper than the model's cap joins its container), walk
    /// as they did: the words of a tree 200 levels deep are all there.
    func testTextsNestedAsBooksNestWalkAsTheyDid() throws {
        let nested = try walk(DeepMarkdown.quotes(60))
        XCTAssertEqual(words(of: nested), "Quoted words")
        let list = try walk(DeepMarkdown.lists(60))
        XCTAssertTrue(words(of: list).contains("Listed words"))
        // A shallow text is no different for the thread it is walked on.
        XCTAssertEqual(words(of: try walk("A plain paragraph.")), "A plain paragraph.")
    }

    /// The refusal names the chapter a deep text is in, the first of them,
    /// and says nothing of a text with no chapter markers.
    func testTheRefusalNamesTheChapter() {
        let deep = DeepMarkdown.quotes(limits.deepestNesting + 1)
        let book = "\(MarkdownCacheService.chapterMarker(title: "First"))\nWords.\n\n"
            + "\(MarkdownCacheService.chapterMarker(title: "Second"))\n\(deep)\n\n"
            + "\(MarkdownCacheService.chapterMarker(title: "Third"))\n\(deep)"
        XCTAssertEqual(refusal(of: book), tooDeep(chapter: "Second"))
        XCTAssertEqual(refusal(of: deep), tooDeep(chapter: ""))
        // A chapter deep at the limit's edge is walked, whatever surrounds it.
        let edge = "\(MarkdownCacheService.chapterMarker(title: "Edge"))\n\(DeepMarkdown.quotes(limits.deepestNesting))"
        XCTAssertNil(refusal(of: edge))
    }

    /// The rest of a line that markers lead is a text of its own, held to
    /// the limit as the reader holds it: at the limit it walks, past it the
    /// whole text is refused, and the reader refuses the same.
    func testTheRestOfAMarkerLineIsHeldToTheLimitAsTheReaderHoldsIt() throws {
        let marker = MarkdownWalkCorpusKit.page("1")
        let atTheLimit = marker + DeepMarkdown.quotes(limits.deepestNesting)
        let pastTheLimit = marker + DeepMarkdown.quotes(limits.deepestNesting + 1)

        XCTAssertTrue(words(of: try walk(atTheLimit)).contains("Quoted words"))
        XCTAssertEqual(refusal(of: pastTheLimit), tooDeep())

        XCTAssertNoThrow(try MarkdownDocParser.parseChapter(markdown: atTheLimit))
        XCTAssertThrowsError(try MarkdownDocParser.parseChapter(markdown: pastTheLimit)) {
            XCTAssertEqual($0 as? MarkupRefusal, .nestedTooDeeply(limit: self.limits.deepestNesting))
        }
    }

    /// The walk is held to the limits in force, as the reader is: a limit
    /// lifted for a test is the walk's too, and one lowered refuses sooner.
    func testTheWalkKeepsToTheLimitsInForce() throws {
        var lowered = limits
        lowered.deepestNesting = 3
        MarkupGuard.$limits.withValue(lowered) {
            XCTAssertNil(refusal(of: DeepMarkdown.quotes(3)))
            XCTAssertEqual(refusal(of: DeepMarkdown.quotes(4)), .nestedTooDeeply(chapter: "", limit: 3))
        }
        var shallowTree = limits
        shallowTree.deepestTree = 5
        MarkupGuard.$limits.withValue(shallowTree) {
            XCTAssertNil(refusal(of: "> words"))
            XCTAssertEqual(refusal(of: "> > words"), tooDeep())
        }
    }

    /// Whatever the walk refuses, the reader refuses: no text the walk reads
    /// is one the reader would not, at the standard limit.
    func testTheWalkAndTheReaderRefuseTheSameShapes() {
        for shape in DeepMarkdown.shapes() {
            for count in [shape.edge - 1, shape.edge, shape.edge + 1] {
                let markdown = shape.text(count)
                let readerRefuses: Bool
                do {
                    _ = try MarkdownDocParser.parseChapter(markdown: markdown)
                    readerRefuses = false
                } catch {
                    readerRefuses = true
                }
                XCTAssertEqual(refusal(of: markdown) != nil, readerRefuses, "\(shape.name) \(count) deep")
            }
        }
    }

    // MARK: - The stack

    /// The walk at the limit fits the stack of an export's own thread, which
    /// is 512 KiB: the walk runs on a thread of a large stack of its own, so
    /// the thread that asks needs none.
    func testTheWalkAtTheLimitFitsTheStackOfAnExportThread() throws {
        for shape in DeepMarkdown.shapes() {
            let document = try walkOnSmallThread(shape.text(shape.edge))
            XCTAssertTrue(words(of: document).contains(shape.word), shape.name)
        }
    }

    /// The document of `markdown`, walked by a call made on a new thread with
    /// the 512 KiB stack every thread but the main one has.
    private func walkOnSmallThread(_ markdown: String) throws -> ExportDocument {
        // Written by the thread alone, before it signals, and read here, after the wait.
        let outcome = OSAllocatedUnfairLock<Result<ExportDocument, Error>?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            let walked = Result {
                try ExportDocumentWalker.document(fromMarkdown: markdown, book: ExportBookDetails(title: ""))
            }
            outcome.withLock { $0 = walked }
            done.signal()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        XCTAssertEqual(done.wait(timeout: .now() + 120), .success, "the walk did not end")
        return try XCTUnwrap(outcome.withLock { $0 }).get()
    }

    // MARK: - Every writer

    /// Every writer the picker offers, and Markdown: a text nested at the
    /// limit is written to a file, and one past it is refused by the walk
    /// that is made for the writer's own options, with the same sentence, so
    /// no writer is ever handed a deep document.
    func testEveryWriterWritesAtTheLimitAndIsNeverHandedAPastIt() throws {
        let folder = try makeSandboxDirectory("Export Nesting Writers")
        var writers: [any TextExportWriter] = [MarkdownExportWriter()]
        writers += TextExportWriters.all
        XCTAssertGreaterThanOrEqual(writers.count, 6, "a writer is missing from the picker's list")

        for writer in writers {
            let conversion = TextExportWriters.optionsState(for: writer).conversion()
            for shape in DeepMarkdown.shapes() {
                let label = "\(writer.name), \(shape.name)"
                let document = try ExportDocumentWalker.document(
                    fromMarkdown: shape.text(shape.edge),
                    book: ExportBookDetails(title: "Deep"),
                    options: conversion.walkOptions
                )
                let file = folder.appendingPathComponent("\(writer.id)-\(shape.name).\(conversion.fileExtension)")
                try conversion.write(document, to: file, cancellation: BookExportCancellation())
                XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), label)

                XCTAssertThrowsError(try ExportDocumentWalker.document(
                    fromMarkdown: shape.text(shape.edge + 1),
                    book: ExportBookDetails(title: "Deep"),
                    options: conversion.walkOptions
                ), label) {
                    XCTAssertEqual($0 as? ExportWalkError, self.tooDeep(), label)
                }
            }
        }
    }

    // MARK: - The sentence

    /// The sentence a refused export says: it names the chapter, or the book's
    /// text, the limit, and what to do, and it sits in an export's summary as
    /// every failure's reason does, a sentence of its own.
    func testTheSentenceNamesTheChapterTheLimitAndWhatToDo() {
        let chapter = tooDeep(chapter: "The Long Night").localizedDescription
        XCTAssertEqual(
            chapter,
            "The chapter called The Long Night nests quotes, lists, or emphasis more than 128 levels deep, "
                + "which TextMouth can't export safely. Choose Edit Text, flatten the nesting, and save; then export again."
        )
        XCTAssertEqual(
            tooDeep().localizedDescription,
            "The text of this book nests quotes, lists, or emphasis more than 128 levels deep, "
                + "which TextMouth can't export safely. Choose Edit Text, flatten the nesting, and save; then export again."
        )
        let summary = BookExportWording.failureSentence([BookExportFailure(name: "Night - Text.html", reason: chapter)])
        XCTAssertEqual(
            summary,
            "Couldn't export Night - Text.html: The chapter called The Long Night nests quotes, lists, or emphasis more than "
                + "128 levels deep, which TextMouth can't export safely. Choose Edit Text, flatten the nesting, and save; "
                + "then export again."
        )
    }
}
