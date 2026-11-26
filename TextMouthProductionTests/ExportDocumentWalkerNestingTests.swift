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
/// nesting. Every depth that reaches the walk here is one the old walk, with
/// no limit, survives on a main thread's stack, or on a probe's (`StackProbe`:
/// 8 MiB, which the test measures instead of running out of) (a few hundred
/// levels); the very deep texts go to the layers that never recurse, in
/// `MarkdownDepthLimitTests`. The one test that walks on a worker's 512 KiB
/// stack keeps its inline shapes to 120 levels, which the old walk survives.
/// Hermetic: no library, and the writers write into a sandbox folder.
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

    /// `ExportWalkError.nestedTooDeeply` for the chapter numbered `chapter`
    /// (nil for a text with no chapter markers), at the standard limit.
    private func tooDeep(chapter: Int? = nil) -> ExportWalkError {
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
    /// as they did: the words of a tree of 63 levels (the quotes) and one of
    /// 123 (the lists) are all there.
    func testTextsNestedAsBooksNestWalkAsTheyDid() throws {
        let nested = try walk(DeepMarkdown.quotes(60))
        XCTAssertEqual(words(of: nested), "Quoted words")
        let list = try walk(DeepMarkdown.lists(60))
        XCTAssertTrue(words(of: list).contains("Listed words"))
        // A shallow text is no different for the thread it is walked on.
        XCTAssertEqual(words(of: try walk("A plain paragraph.")), "A plain paragraph.")
    }

    /// The refusal names the chapter a deep text is in by its number, the
    /// first of them, and no chapter for a text with no chapter markers.
    func testTheRefusalNamesTheChapterByItsNumber() {
        let deep = DeepMarkdown.quotes(limits.deepestNesting + 1)
        let book = "\(MarkdownCacheService.chapterMarker(title: "First"))\nWords.\n\n"
            + "\(MarkdownCacheService.chapterMarker(title: "Second"))\n\(deep)\n\n"
            + "\(MarkdownCacheService.chapterMarker(title: "Third"))\n\(deep)"
        XCTAssertEqual(refusal(of: book), tooDeep(chapter: 2))
        XCTAssertEqual(refusal(of: deep), tooDeep(chapter: nil))
        // A chapter deep at the limit's edge is walked, whatever surrounds it.
        let edge = "\(MarkdownCacheService.chapterMarker(title: "Edge"))\n\(DeepMarkdown.quotes(limits.deepestNesting))"
        XCTAssertNil(refusal(of: edge))
    }

    /// The rest of a line that markers lead is a text of its own, held to
    /// the limit as the reader holds it: at the limit it walks, past it the
    /// whole text is refused, and the reader refuses the same.
    func testTheRestOfAMarkerLineIsHeldToTheLimitAsTheReaderHoldsIt() throws {
        let marker = MarkdownMarkers.page("1")
        let atTheLimit = marker + DeepMarkdown.quotes(limits.deepestNesting)
        let pastTheLimit = marker + DeepMarkdown.quotes(limits.deepestNesting + 1)

        XCTAssertTrue(words(of: try walk(atTheLimit)).contains("Quoted words"))
        XCTAssertEqual(refusal(of: pastTheLimit), tooDeep())

        XCTAssertNoThrow(try MarkdownDocParser.parseChapter(markdown: atTheLimit))
        XCTAssertThrowsError(try MarkdownDocParser.parseChapter(markdown: pastTheLimit)) {
            XCTAssertEqual($0 as? MarkupRefusal, .nestedTooDeeply(limit: self.limits.deepestNesting))
        }
    }

    /// The rest of a marker line is counted on top of the level its HTML block
    /// stands at, as the reader counts it, so a rest that is shallow by itself
    /// inside a deep quote is refused by both: 100 quotes, a page marker, and
    /// 100 lists reach 302 levels, though the lists alone are 203 and the
    /// quotes 102. The two agree at every depth around the edge, which the
    /// quotes (102 levels to the block) and the lists (two levels each) set.
    func testTheRestOfAMarkerLineIsCountedOnTopOfItsBlocksLevel() {
        func text(lists: Int) -> String {
            String(repeating: "> ", count: 100) + MarkdownMarkers.page("1") + " "
                + String(repeating: "- ", count: lists) + "words"
        }
        XCTAssertNotNil(refusal(of: text(lists: 100)), "the export walked what the reader refuses")
        XCTAssertThrowsError(try MarkdownDocParser.parseChapter(markdown: text(lists: 100)))
        for lists in 80...90 {
            var readerRefuses = false
            do { _ = try MarkdownDocParser.parseChapter(markdown: text(lists: lists)) } catch { readerRefuses = true }
            XCTAssertEqual(refusal(of: text(lists: lists)) != nil, readerRefuses, "\(lists) lists in the rest")
        }
        // Some depth of lists is read by both: the edge is inside this range.
        XCTAssertNil(refusal(of: text(lists: 10)))
        XCTAssertNotNil(refusal(of: text(lists: 100)))
    }

    /// The walk is held to the limits in force, as the reader is: a limit
    /// lifted for a test is the walk's too, and one lowered refuses sooner.
    func testTheWalkKeepsToTheLimitsInForce() throws {
        var lowered = limits
        lowered.deepestNesting = 3
        MarkupGuard.$limits.withValue(lowered) {
            XCTAssertNil(refusal(of: DeepMarkdown.quotes(3)))
            XCTAssertEqual(refusal(of: DeepMarkdown.quotes(4)), .nestedTooDeeply(chapter: nil, limit: 3))
        }
        var shallowTree = limits
        shallowTree.deepestTree = 5
        MarkupGuard.$limits.withValue(shallowTree) {
            XCTAssertNil(refusal(of: "> words"))
            XCTAssertEqual(refusal(of: "> > > words"), tooDeep())
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

    /// The walk at the limit uses none of the stack of the thread that asks:
    /// it runs on a thread of a large stack of its own (`onLargeStack`), so
    /// the 512 KiB of an export's worker thread are never needed. Measured,
    /// not survived (`StackProbe`): each shape is walked at its edge on a
    /// thread of 8 MiB whose unused stack is filled with a pattern, and none of
    /// the stack more than 64 KiB below the walk's entry may have been written. The old walk,
    /// which has no hop, writes about 0.83 MB for the inline shapes and 0.17
    /// to 0.23 MB for quotes and lists in a debug build, so a regression of
    /// the hop fails here and overflows nothing.
    ///
    /// It fills a thread's stack, so it runs on GitHub's runner only: a probe
    /// that miscounted by a guard page would end the test host here.
    func testTheWalkAtTheLimitUsesNoStackOfTheThreadThatAsks() throws {
        try TestMachine.skipUnlessGitHubRunner("This test fills a thread's stack with a pattern to measure the walk")
        for shape in DeepMarkdown.shapes() {
            let markdown = shape.text(shape.edge)
            let probe = StackProbe.run {
                Result { try ExportDocumentWalker.document(fromMarkdown: markdown, book: ExportBookDetails(title: "")) }
            }
            let document = try XCTUnwrap(probe.value, "\(shape.name): no thread").get()
            XCTAssertTrue(words(of: document).contains(shape.word), shape.name)
            XCTAssertNil(
                probe.deepestWrite,
                "\(shape.name) at \(shape.edge) walked on the asking thread's own stack, \(probe.deepestWrite ?? 0) bytes deep"
            )
        }
    }

    /// A smoke test on the 512 KiB stack of a worker thread, which an export
    /// runs on: quotes and lists at the limit, the inline shapes at 120
    /// levels, which the old walk survives there too (about 0.37 MB), so
    /// this test cannot end the test host if the hop were lost.
    func testTheWalkRunsOnAWorkerThread() throws {
        for shape in DeepMarkdown.shapes() {
            let markdown = shape.text(min(shape.edge, 120))
            let walked = try XCTUnwrap(onWorkerSizedStack { () -> Result<ExportDocument, Error> in
                Result { try ExportDocumentWalker.document(fromMarkdown: markdown, book: ExportBookDetails(title: "")) }
            }, shape.name)
            XCTAssertTrue(words(of: try walked.get()).contains(shape.word), shape.name)
        }
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

    /// The sentence a refused export says: it names the chapter by its number,
    /// or the book's text, the limit, and what to do, and it sits in an
    /// export's summary as every failure's reason does, a sentence of its own.
    /// No chapter title is in it: a title is the book's text, which the log of
    /// the failure may not hold.
    func testTheSentenceNamesTheChapterTheLimitAndWhatToDo() {
        let chapter = tooDeep(chapter: 3).localizedDescription
        XCTAssertEqual(
            chapter,
            "Chapter 3 of this book nests quotes, lists, or emphasis more than 128 levels deep, "
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
            "Couldn't export Night - Text.html: Chapter 3 of this book nests quotes, lists, or emphasis more than "
                + "128 levels deep, which TextMouth can't export safely. Choose Edit Text, flatten the nesting, and save; "
                + "then export again."
        )
    }
}
