import XCTest
@testable import TextMouth

/// Export of a book whose content.md nests too deeply (#5512), end to end
/// through the export service as the Export dialog calls it: the text Edit
/// Text left in content.md before it refused such an edit, or any other deep
/// text that got there, is refused with a sentence that names the file and
/// says what to do, nothing is written for it, and the books exported with
/// it are exported as ever.
///
/// Every book lives in a library folder of the test's own and every export
/// goes to a sandbox folder. A deep content.md is put in a shallow book's
/// package after its import, as an edit saved while TextMouth was closed
/// puts one, since an import refuses a source that deep. The depths are
/// those of the limit, a few hundred levels at the most.
@MainActor
final class BookExportNestingTests: XCTestCase {

    // MARK: - A deep text

    /// A deep content.md, refused, for every writer the picker offers and for
    /// Markdown: the failure says the sentence, once, with the file's name,
    /// and the folder holds no file.
    func testABookNestedTooDeeplyIsRefusedForEveryWriter() throws {
        let world = try makeIntegrationWorld("Export Nested Too Deeply")
        let deep = try world.importBook(from: writeSource(named: "Deep Notes.md", "# Deep\n\nWords."))
        let limit = MarkupGuard.Limits.standard.deepestNesting
        let chapters = "<!-- chapter: Notes -->\n# Notes\n\n" + DeepMarkdown.quotes(limit + 1) + "\n"
        try Data(chapters.utf8).write(to: MarkdownCacheService.cacheURL(for: deep))

        var writers: [any TextExportWriter] = [MarkdownExportWriter()]
        writers += TextExportWriters.all
        for writer in writers {
            let destination = try makeSandboxDirectory("Export Nested Destination \(writer.id)")
            let conversion = BookExportConversion.text(TextExportWriters.optionsState(for: writer).conversion())

            let outcome = BookExportService.export(
                [BookExportService.offer(for: deep)], kinds: [.markdown], conversions: [.markdown: conversion], to: destination
            )

            let name = "\(BookExportService.fileNameStem(for: deep.title)) - Text.\(writer.fileExtension)"
            let sentence = ExportWalkError.nestedTooDeeply(chapter: 1, limit: limit).localizedDescription
            XCTAssertEqual(outcome.failures, [BookExportFailure(name: name, reason: sentence)], writer.name)
            XCTAssertEqual(outcome.exported, [], writer.name)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [], writer.name)
        }
    }

    /// A refused book does not stop the export: the book beside it is written.
    func testTheBookBesideARefusedOneIsExported() throws {
        let world = try makeIntegrationWorld("Export Nested Neighbour")
        let deep = try world.importBook(from: writeSource(named: "Deep Notes.md", "# Deep\n\nWords."))
        let shallow = try world.importBook(from: writeSource(named: "Shallow Notes.md", "# Shallow\n\nWords."))
        let limit = MarkupGuard.Limits.standard.deepestNesting
        try Data(DeepMarkdown.lists(limit + 1).utf8).write(to: MarkdownCacheService.cacheURL(for: deep))
        let destination = try makeSandboxDirectory("Export Nested Neighbour Destination")
        let html = BookExportConversion.text(TextExportConversion(HTMLExportWriter(), options: NoTextExportOptions()))

        let outcome = BookExportService.export(
            [BookExportService.offer(for: deep), BookExportService.offer(for: shallow)],
            kinds: [.markdown],
            conversions: [.markdown: html],
            to: destination
        )

        XCTAssertEqual(outcome.failures.map(\.name), ["\(BookExportService.fileNameStem(for: deep.title)) - Text.html"])
        XCTAssertEqual(outcome.exported.map(\.lastPathComponent), ["\(BookExportService.fileNameStem(for: shallow.title)) - Text.html"])
    }

    /// What the export says once it ends: the file named, the chapter named
    /// by its number, and what to do, as one sentence VoiceOver reads from the
    /// summary; the chapter's title is not in the sentence, the only text the
    /// failure's log line adds to the file's name.
    func testTheSummaryNamesTheFileTheChapterAndWhatToDo() throws {
        let world = try makeIntegrationWorld("Export Nested Summary")
        let book = try world.importBook(from: writeSource(named: "Deep Notes.md", "# Deep\n\nWords."))
        let limit = MarkupGuard.Limits.standard.deepestNesting
        let deepChapter = "<!-- chapter: Notes -->\n" + DeepMarkdown.lists(limit + 1)
        try Data(deepChapter.utf8).write(to: MarkdownCacheService.cacheURL(for: book))
        let destination = try makeSandboxDirectory("Export Nested Summary Destination")

        let outcome = BookExportService.export([BookExportService.offer(for: book)], kinds: [.markdown], to: destination)

        let stem = BookExportService.fileNameStem(for: book.title)
        XCTAssertEqual(
            BookExportWording.finished(outcome, folderName: "Destination"),
            "Couldn't export \(stem) - Text.md: Chapter 1 of this book nests quotes, lists, or emphasis more than 128 levels deep, "
                + "which TextMouth can't export safely. Choose Edit Text, flatten the nesting, and save; then export again."
        )
    }

    /// A book nested as far as the limit allows exports, the words in the file.
    func testABookNestedAtTheLimitIsExported() throws {
        let world = try makeIntegrationWorld("Export Nested At The Limit")
        let book = try world.importBook(from: writeSource(named: "Edge Notes.md", "# Edge\n\nWords."))
        let limit = MarkupGuard.Limits.standard.deepestNesting
        let edge = "<!-- chapter: Notes -->\n" + DeepMarkdown.quotes(limit)
        try Data(edge.utf8).write(to: MarkdownCacheService.cacheURL(for: book))
        let destination = try makeSandboxDirectory("Export Nested At The Limit Destination")
        let html = BookExportConversion.text(TextExportConversion(HTMLExportWriter(), options: NoTextExportOptions()))

        let outcome = BookExportService.export(
            [BookExportService.offer(for: book)], kinds: [.markdown], conversions: [.markdown: html], to: destination
        )

        XCTAssertEqual(outcome.failures, [])
        let file = try XCTUnwrap(outcome.exported.first)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("Quoted words"))
    }

    // MARK: - Helpers

    /// Writes `text` as a file named `name` in a sandbox folder of its own,
    /// for an import to read.
    private func writeSource(named name: String, _ text: String) throws -> URL {
        let file = try makeSandboxDirectory("Export Nested Source").appendingPathComponent(name)
        try Data(text.utf8).write(to: file)
        return file
    }
}
