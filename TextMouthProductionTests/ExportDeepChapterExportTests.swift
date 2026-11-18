import AppKit
import XCTest
import os
@testable import TextMouth

/// A chapter nested too deeply, exported as it is written or not at all
/// (FR24), end to end through the export service as the Export dialog calls
/// it, and through the dialog's model with a scripted answer:
///
/// - every text format writes the chapter's words, as the book holds them
///   (content.md's backslash escapes undone, its markers no words), when it is
///   asked, at the limit (no question) and one level past it;
/// - Cancel Export leaves no file for the book and ends the export as Stop
///   does, saying what was written before;
/// - "every such chapter" holds for the rest of one export and no other, and
///   is offered only while more may follow;
/// - the plain text export, which has always kept such a chapter as written,
///   still does, and never asks;
/// - Stop, and the guard before the question, and the alert's buttons, keys,
///   and way onto the screen.
///
/// No test shows an alert: every question is answered by a script, through the
/// export's own seam (`BookExportService.export(..., askAboutDeepChapters:)`,
/// `BookExportModel`'s `deepChapterPrompting`, and the alert's `present` and
/// `take`). Every book lives in a library folder of the test's own and every
/// export goes to a sandbox folder. A deep content.md is put in a shallow
/// book's package after its import, since an import refuses a source that
/// deep. The depths are those of the limit and one past it, which the old
/// walk, that refused them, survives.
@MainActor
final class ExportDeepChapterExportTests: XCTestCase {

    // MARK: - Helpers

    /// The deepest nesting read (128).
    private var limit: Int { MarkupGuard.Limits.standard.deepestNesting }

    /// The words of the real chapters below, as the book holds them.
    private let words = "Quoted words, he said (twice). Then left."

    /// A script of answers to the export's questions, which records each
    /// question. A script that has run out of answers says Cancel Export.
    private final class Script: Sendable {
        private let remaining: OSAllocatedUnfairLock<[ExportDeepChapterAnswer]>
        private let asked = OSAllocatedUnfairLock<[ExportDeepChapterQuestion]>(initialState: [])

        init(_ answers: [ExportDeepChapterAnswer]) {
            remaining = OSAllocatedUnfairLock(initialState: answers)
        }

        /// The closure the export asks through.
        var ask: ExportDeepChapterQuestioner.Ask {
            { [self] question in
                asked.withLock { $0.append(question) }
                return remaining.withLock { queue -> ExportDeepChapterAnswer in
                    queue.isEmpty ? .cancelExport : queue.removeFirst()
                }
            }
        }

        /// The questions asked, in order.
        var questions: [ExportDeepChapterQuestion] { asked.withLock { $0 } }
    }

    /// A chapter of one line nested `levels` quotes deep, as content.md holds
    /// it: the quote marks as they are, the words through
    /// `MarkdownLiteral.escaped`, as every converter writes them (a backslash
    /// before each comma, period, and parenthesis), and a page marker written
    /// by `MarkdownMarkerWriter` within the words.
    private func realChapter(_ levels: Int) -> String {
        var line = String(repeating: "> ", count: levels) + MarkdownLiteral.escaped("Quoted words, he said (twice).")
        MarkdownMarkerWriter.write(MarkdownWalkCorpusKit.page("12"), inline: true, into: &line)
        line += MarkdownLiteral.escaped(" Then left.")
        return "<!-- chapter: Notes -->\n" + line
    }

    /// A chapter of one line nested `levels` quotes deep, as an unescaped test
    /// text (`DeepMarkdown`): for the tests of who is asked and when.
    private func deepChapter(_ levels: Int) -> String {
        "<!-- chapter: Notes -->\n" + DeepMarkdown.quotes(levels)
    }

    /// The one line of `deepChapter(_:)`.
    private func deepLine(_ levels: Int) -> String {
        DeepMarkdown.quotes(levels)
    }

    /// A shallow chapter.
    private let shallowChapter = "<!-- chapter: Notes -->\nShallow words."

    /// A book in `world` whose content.md is `content`: a shallow book
    /// imported, then its text replaced, as an edit saved while TextMouth was
    /// closed puts a deep text there.
    private func makeBook(in world: IntegrationWorld, named name: String, content: String) throws -> Book {
        let source = try makeSandboxDirectory("Export Deep Source").appendingPathComponent("\(name).md")
        try Data("# \(name)\n\nWords.".utf8).write(to: source)
        let book = try world.importBook(from: source)
        try Data(content.utf8).write(to: MarkdownCacheService.cacheURL(for: book))
        return book
    }

    /// The conversion that writes `writer`'s files with its options as a
    /// dialog starts them.
    private func conversion(of writer: any TextExportWriter) -> BookExportConversion {
        .text(TextExportWriters.optionsState(for: writer).conversion())
    }

    /// The HTML conversion, the writer of most tests here.
    private var html: BookExportConversion {
        .text(TextExportConversion(HTMLExportWriter(), options: NoTextExportOptions()))
    }

    /// The name of a book's text file when one book is exported.
    private func fileName(of book: Book, extension fileExtension: String) -> String {
        "\(BookExportService.fileNameStem(for: book.title)) - Text.\(fileExtension)"
    }

    // MARK: - Every format

    /// Every text format writes a chapter nested one level past the limit, as
    /// content.md holds it, with the book's own words, once asked (naming the
    /// book and the chapter's number), and one nested as far as the limit
    /// allows as it always did, with no question. Each format is read back its
    /// own way: Markdown through the walk, HTML and RTF as text, Word 97-2003
    /// through TextMouth's own reader, EPUB's chapter file through its EPUB
    /// reader, BRF and PEF cell for cell against the same words in a shallow
    /// book.
    func testEveryFormatWritesTheDeepChapterAsWrittenWhenAsked() throws {
        let world = try makeIntegrationWorld("Export Deep Formats")
        var writers: [any TextExportWriter] = [MarkdownExportWriter()]
        writers += TextExportWriters.all
        for levels in [limit, limit + 1] {
            let book = try makeBook(in: world, named: "Deep Notes \(levels)", content: realChapter(levels))
            let isDeep = levels > limit
            for writer in writers {
                let name = "\(writer.name) at \(levels)"
                let destination = try makeSandboxDirectory("Export Deep Destination \(writer.id)")
                let script = Script([.exportAsWritten])

                let outcome = BookExportService.export(
                    [BookExportService.offer(for: book)],
                    kinds: [.markdown],
                    conversions: [.markdown: conversion(of: writer)],
                    to: destination,
                    askAboutDeepChapters: script.ask
                )

                XCTAssertEqual(outcome.failures, [], name)
                XCTAssertFalse(outcome.wasCancelled, name)
                XCTAssertEqual(outcome.exported.map(\.lastPathComponent), [fileName(of: book, extension: writer.fileExtension)], name)
                XCTAssertEqual(
                    script.questions,
                    isDeep ? [ExportDeepChapterQuestion(bookTitle: book.title, chapter: 1, limit: limit, offersEveryOne: false)] : [],
                    name
                )
                let file = try XCTUnwrap(outcome.exported.first, name)
                try checkFile(file, of: writer, isDeep: isDeep, levels: levels, name: name, world: world, conversion: conversion(of: writer))
            }
        }
    }

    /// What `file`, which `writer` wrote of the one-chapter book of
    /// `realChapter(levels)`, holds: the words, with no backslash and no
    /// comment, and no quote when it is written as written.
    private func checkFile(
        _ file: URL,
        of writer: any TextExportWriter,
        isDeep: Bool,
        levels: Int,
        name: String,
        world: IntegrationWorld,
        conversion: BookExportConversion
    ) throws {
        let data = try Data(contentsOf: file)
        XCTAssertFalse(data.isEmpty, name)
        let text = String(decoding: data, as: UTF8.self)
        let line = String(repeating: "> ", count: levels) + words
        switch writer.fileExtension {
        case "md":
            // The Markdown is a correct file: it reads back, with no refusal,
            // and its paragraph is the line, words and all.
            let document = try ExportDocumentWalker.document(fromMarkdown: text, book: ExportBookDetails(title: ""))
            let paragraphs = document.blocks.compactMap { block -> String? in
                if case let .paragraph(runs) = block { return runs.plainText }
                return nil
            }
            XCTAssertFalse(text.contains("<!--"), name)
            if isDeep {
                XCTAssertEqual(paragraphs, [line], name)
            } else {
                XCTAssertTrue(text.contains(words), name)
            }
        case "html":
            XCTAssertTrue(text.contains(words), name)
            XCTAssertFalse(text.contains("\\,") || text.contains("<!--") || text.contains("page: 12"), name)
            XCTAssertEqual(text.contains("<blockquote"), !isDeep, name)
        case "rtf", "doc":
            // TextMouth's own reader reads the file back as a book.
            let imported = try importedForTest(file)
            let read = allText(of: try openedContent(of: imported.book))
            XCTAssertTrue(read.contains(words), "\(name): \(read)")
            XCTAssertFalse(read.contains("\\,") || read.contains("<!--"), name)
        case "epub":
            let reading = try EPUBRoundTrip.reading(ofEPUB: file)
            let expectedWords = words.split(whereSeparator: \.isWhitespace).map(String.init)
            XCTAssertEqual(Array(reading.words.suffix(expectedWords.count)), expectedWords, name)
            XCTAssertFalse(reading.words.contains { $0.contains("<!--") || $0.contains("\\") }, name)
            XCTAssertEqual(reading.pages.count, 1, "\(name): the page marker is a page, not words: \(reading.pages)")
            XCTAssertTrue(reading.pages.first?.hasPrefix("12@") == true, name)
        case "brf", "pef":
            if isDeep {
                try checkCells(of: file, writer: writer, line: line, world: world, conversion: conversion, name: name)
            }
        default:
            XCTFail("no reader for \(name)")
        }
    }

    /// The cells of a braille file made from the deep chapter are the cells
    /// of the same line in a shallow book (its quote marks escaped, so that
    /// they are characters of a paragraph): a BRF's whole file, a PEF's body,
    /// whose head holds a book's own identifier and date.
    private func checkCells(
        of file: URL,
        writer: any TextExportWriter,
        line: String,
        world: IntegrationWorld,
        conversion: BookExportConversion,
        name: String
    ) throws {
        let control = try makeBook(in: world, named: "Control \(name)", content: "<!-- chapter: Notes -->\n" + MarkdownLiteral.escaped(line))
        let destination = try makeSandboxDirectory("Export Deep Control")
        let outcome = BookExportService.export(
            [BookExportService.offer(for: control)], kinds: [.markdown], conversions: [.markdown: conversion], to: destination
        )
        let controlFile = try XCTUnwrap(outcome.exported.first, name)
        let cells = try String(contentsOf: file, encoding: .utf8)
        let controlCells = try String(contentsOf: controlFile, encoding: .utf8)
        if writer.fileExtension == "pef" {
            let body = { (text: String) in text.range(of: "<body").map { String(text[$0.lowerBound...]) } }
            XCTAssertNotNil(body(cells), name)
            XCTAssertEqual(body(cells), body(controlCells), name)
        } else {
            XCTAssertFalse(cells.isEmpty, name)
            XCTAssertEqual(cells, controlCells, name)
        }
    }

    // MARK: - Cancel

    /// Cancel Export leaves no file for the book, no failure, and says the
    /// export stopped with nothing exported.
    func testCancelLeavesNoFileForTheBook() throws {
        let world = try makeIntegrationWorld("Export Deep Cancel")
        let book = try makeBook(in: world, named: "Deep Notes", content: deepChapter(limit + 1))
        let destination = try makeSandboxDirectory("Export Deep Cancel Destination")
        let script = Script([.cancelExport])

        let outcome = BookExportService.export(
            [BookExportService.offer(for: book)], kinds: [.markdown], conversions: [.markdown: html], to: destination,
            askAboutDeepChapters: script.ask
        )

        XCTAssertTrue(outcome.wasCancelled)
        XCTAssertEqual(outcome.exported, [])
        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
        XCTAssertEqual(BookExportWording.finished(outcome, folderName: "Destination"), "Export stopped. Nothing was exported.")
    }

    /// Without a way to ask, a chapter nested too deeply is refused as it was
    /// before, with the same sentence, and the other books are exported.
    func testWithoutAQuestionTheBookIsStillRefused() throws {
        let world = try makeIntegrationWorld("Export Deep Refused")
        let book = try makeBook(in: world, named: "Deep Notes", content: deepChapter(limit + 1))
        let destination = try makeSandboxDirectory("Export Deep Refused Destination")

        let outcome = BookExportService.export(
            [BookExportService.offer(for: book)], kinds: [.markdown], conversions: [.markdown: html], to: destination
        )

        XCTAssertEqual(outcome.exported, [])
        XCTAssertEqual(
            outcome.failures,
            [BookExportFailure(
                name: fileName(of: book, extension: "html"),
                reason: ExportWalkError.nestedTooDeeply(chapter: 1, limit: limit).localizedDescription
            )]
        )
    }

    // MARK: - Many books

    /// A deep book, a shallow one, and a deep one again: answering "every
    /// such chapter" at the first writes both deep books and asks once, and
    /// the question offers it, since more files remain.
    func testEveryChapterAnswerHoldsForTheRestOfTheExport() throws {
        let world = try makeIntegrationWorld("Export Deep Every")
        let first = try makeBook(in: world, named: "Deep One", content: deepChapter(limit + 1))
        let middle = try makeBook(in: world, named: "Shallow Two", content: shallowChapter)
        let last = try makeBook(in: world, named: "Deep Three", content: deepChapter(limit + 5))
        let destination = try makeSandboxDirectory("Export Deep Every Destination")
        let script = Script([.exportEveryOneAsWritten])

        let outcome = BookExportService.export(
            [first, middle, last].map { BookExportService.offer(for: $0) },
            kinds: [.markdown], conversions: [.markdown: html], to: destination, askAboutDeepChapters: script.ask
        )

        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(outcome.exported.map(\.lastPathComponent), [first, middle, last].map { fileName(of: $0, extension: "html") })
        XCTAssertEqual(
            script.questions,
            [ExportDeepChapterQuestion(bookTitle: first.title, chapter: 1, limit: limit, offersEveryOne: true)],
            "asked once, at the first deep chapter"
        )
    }

    /// "Every such chapter" is offered where more may follow: not for the
    /// last deep chapter of the last text file, though the export holds several
    /// books, and for a deep book that more books follow, though its own
    /// chapter is its last.
    func testEveryChapterIsOfferedOnlyWhileMoreMayFollow() throws {
        let world = try makeIntegrationWorld("Export Deep Offered")
        let shallow = try makeBook(in: world, named: "Shallow One", content: shallowChapter)
        let deep = try makeBook(in: world, named: "Deep Two", content: deepChapter(limit + 1))
        let after = try makeBook(in: world, named: "Shallow Three", content: shallowChapter)

        let last = Script([.exportAsWritten])
        _ = BookExportService.export(
            [shallow, deep].map { BookExportService.offer(for: $0) }, kinds: [.markdown], conversions: [.markdown: html],
            to: try makeSandboxDirectory("Export Deep Offered Last"), askAboutDeepChapters: last.ask
        )
        XCTAssertEqual(last.questions.map(\.offersEveryOne), [false], "nothing follows the last book's only chapter")

        let more = Script([.exportAsWritten])
        _ = BookExportService.export(
            [deep, after].map { BookExportService.offer(for: $0) }, kinds: [.markdown], conversions: [.markdown: html],
            to: try makeSandboxDirectory("Export Deep Offered More"), askAboutDeepChapters: more.ask
        )
        XCTAssertEqual(more.questions.map(\.offersEveryOne), [true], "another book follows")

        let twoChapters = try makeBook(
            in: world, named: "Deep Four", content: deepChapter(limit + 1) + "\n\n<!-- chapter: Two -->\nWords."
        )
        let chapters = Script([.exportAsWritten])
        _ = BookExportService.export(
            [BookExportService.offer(for: twoChapters)], kinds: [.markdown], conversions: [.markdown: html],
            to: try makeSandboxDirectory("Export Deep Offered Chapters"), askAboutDeepChapters: chapters.ask
        )
        XCTAssertEqual(chapters.questions.map(\.offersEveryOne), [true], "a chapter follows in the same book")
    }

    /// Without "every such chapter", each deep book is asked about on its own,
    /// naming that book, and a later Cancel Export keeps the books written
    /// before it and stops the rest, saying so.
    func testEachDeepBookIsAskedAndACancelStopsTheRest() throws {
        let world = try makeIntegrationWorld("Export Deep Each")
        let first = try makeBook(in: world, named: "Deep One", content: deepChapter(limit + 1))
        let middle = try makeBook(in: world, named: "Shallow Two", content: shallowChapter)
        let last = try makeBook(in: world, named: "Deep Three", content: deepChapter(limit + 1))
        let after = try makeBook(in: world, named: "Shallow Four", content: "<!-- chapter: Notes -->\nMore words.")
        let destination = try makeSandboxDirectory("Export Deep Each Destination")
        let script = Script([.exportAsWritten, .cancelExport])

        let outcome = BookExportService.export(
            [first, middle, last, after].map { BookExportService.offer(for: $0) },
            kinds: [.markdown], conversions: [.markdown: html], to: destination, askAboutDeepChapters: script.ask
        )

        XCTAssertEqual(script.questions.map(\.bookTitle), [first.title, last.title])
        XCTAssertTrue(outcome.wasCancelled)
        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(outcome.exported.map(\.lastPathComponent), [first, middle].map { fileName(of: $0, extension: "html") })
        XCTAssertEqual(
            BookExportWording.finished(outcome, folderName: "Destination"),
            "Exported 2 items to Destination. The export was stopped before the rest."
        )
        // Nothing of the deep book that was cancelled, nor of the one after it.
        let folders = try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted()
        XCTAssertEqual(folders, [first, middle].map { BookExportService.fileNameStem(for: $0.title) }.sorted())
    }

    /// A Cancel Export at the first book of several writes nothing, and
    /// makes no folder for any.
    func testACancelAtTheFirstBookWritesNothing() throws {
        let world = try makeIntegrationWorld("Export Deep First Cancel")
        let first = try makeBook(in: world, named: "Deep One", content: deepChapter(limit + 1))
        let second = try makeBook(in: world, named: "Shallow Two", content: shallowChapter)
        let destination = try makeSandboxDirectory("Export Deep First Cancel Destination")

        let outcome = BookExportService.export(
            [first, second].map { BookExportService.offer(for: $0) },
            kinds: [.markdown], conversions: [.markdown: html], to: destination, askAboutDeepChapters: Script([.cancelExport]).ask
        )

        XCTAssertTrue(outcome.wasCancelled)
        XCTAssertEqual(outcome.exported, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }

    /// "Every such chapter" belongs to one export: the next export asks again.
    func testEveryChapterAnswerIsForOneExportOnly() throws {
        let world = try makeIntegrationWorld("Export Deep One Export")
        let book = try makeBook(in: world, named: "Deep One", content: deepChapter(limit + 1))
        let script = Script([.exportEveryOneAsWritten, .exportAsWritten])

        for run in 1...2 {
            let destination = try makeSandboxDirectory("Export Deep One Export Destination")
            let outcome = BookExportService.export(
                [BookExportService.offer(for: book)], kinds: [.markdown], conversions: [.markdown: html], to: destination,
                askAboutDeepChapters: script.ask
            )
            XCTAssertEqual(outcome.exported.count, 1, "export \(run)")
            XCTAssertEqual(script.questions.count, run, "export \(run) asks once")
        }
    }

    // MARK: - Plain text

    /// The plain text export has always kept a chapter nested too deeply as
    /// written, as the reader shows it, so it never asks: past the limit its
    /// file holds the chapter's line with its marks, and at the limit, which
    /// the reader parses, only its words.
    func testThePlainTextExportKeepsTheChapterAsWrittenAndNeverAsks() throws {
        let world = try makeIntegrationWorld("Export Deep Plain Text")
        for levels in [limit, limit + 1] {
            let book = try makeBook(in: world, named: "Deep Notes \(levels)", content: deepChapter(levels))
            let destination = try makeSandboxDirectory("Export Deep Plain Text Destination")
            let script = Script([])

            let outcome = BookExportService.export(
                [BookExportService.offer(for: book)], kinds: [.plainText], to: destination, askAboutDeepChapters: script.ask
            )

            XCTAssertEqual(outcome.failures, [], "\(levels)")
            XCTAssertEqual(script.questions, [], "\(levels)")
            let file = try XCTUnwrap(outcome.exported.first)
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertTrue(text.contains("Quoted words"), "\(levels)")
            XCTAssertEqual(text.contains(deepLine(levels)), levels > limit, "\(levels): the marks are kept past the limit only")
        }
    }

    /// The Plain Text export of a chapter nested too deeply writes its words as
    /// they are written (B16): no marker comment, and no backslash before a
    /// punctuation mark, which content.md's converters add and the reader's
    /// raw chapter no longer keeps.
    func testThePlainTextExportOfADeepChapterHasNoMarkerAndNoEscape() throws {
        let world = try makeIntegrationWorld("Export Deep Plain Text Raw")
        let content = "<!-- chapter: Notes -->\n<!-- page: 7 -->\n\(deepLine(limit + 1)) Done\\. Costs \\$5\\!"
            + " <!-- page: 8 -->More\\, words\\.\n"
        let book = try makeBook(in: world, named: "Deep Notes Raw", content: content)
        let destination = try makeSandboxDirectory("Export Deep Plain Text Raw Destination")

        let outcome = BookExportService.export([BookExportService.offer(for: book)], kinds: [.plainText], to: destination)

        XCTAssertEqual(outcome.failures, [])
        let file = try XCTUnwrap(outcome.exported.first)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("Done. Costs $5! More, words."), text)
        XCTAssertFalse(text.contains("<!--"), "no marker comment")
        XCTAssertFalse(text.contains("\\"), "no backslash escape")
    }

    // MARK: - The dialog

    /// What a scripted prompt saw, kept on the main actor, and what a task
    /// that waits for an answer was given.
    @MainActor
    private final class PromptLog {
        var questions: [ExportDeepChapterQuestion] = []
        var windows: [NSWindow?] = []
        var outcome: BookExportOutcome?
        var answer: ExportDeepChapterAnswer?
        /// How many times the export under test ended, or its question was
        /// answered: each exactly once, so a second call fails a test
        /// rather than over-fulfilling an expectation.
        var endings = 0
    }

    /// A prompt that records each question and the window it was asked over,
    /// and answers `answer`.
    private func scriptedPrompt(_ log: PromptLog, answer: ExportDeepChapterAnswer) -> BookExportModel.DeepChapterPrompting {
        .custom(BookExportModel.DeepChapterPrompt(ask: { question, window in
            log.questions.append(question)
            log.windows.append(window)
            return answer
        }))
    }

    /// The dialog's export asks through its prompt, on the main actor, with
    /// the book's title and the chapter's number, over the dialog's own
    /// window, and writes the chapter as written when the answer says so.
    func testTheDialogAsksThroughItsPromptAndExportsAsWritten() async throws {
        let world = try makeIntegrationWorld("Export Deep Dialog")
        let book = try makeBook(in: world, named: "Deep Notes", content: deepChapter(limit + 1))
        let folder = try makeSandboxDirectory("Export Deep Dialog Destination")
        let log = PromptLog()
        let model = BookExportModel(
            books: [book], destination: folder, deepChapterPrompting: scriptedPrompt(log, answer: .exportAsWritten)
        )
        await model.load()
        model.checked = [.markdown]
        let dialog = NSWindow()
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }

        let exported = await model.export(presentingFrom: dialog)
        let outcome = try XCTUnwrap(exported)

        XCTAssertEqual(
            log.questions,
            [ExportDeepChapterQuestion(bookTitle: book.title, chapter: 1, limit: limit, offersEveryOne: false)]
        )
        XCTAssertTrue(log.windows.first.map { $0 === dialog } == true, "the question is shown over the dialog's own window")
        XCTAssertTrue(BookExportModel.didEverything(outcome))
        XCTAssertEqual(outcome.exported.map(\.lastPathComponent), [fileName(of: book, extension: "md")])
    }

    /// Cancel Export, answered in the dialog, ends the export as Stop does:
    /// nothing is written, and the dialog says what happened, which VoiceOver
    /// is told too.
    func testTheDialogsCancelStopsTheExport() async throws {
        let world = try makeIntegrationWorld("Export Deep Dialog Cancel")
        let book = try makeBook(in: world, named: "Deep Notes", content: deepChapter(limit + 1))
        let folder = try makeSandboxDirectory("Export Deep Dialog Cancel Destination")
        let model = BookExportModel(
            books: [book], destination: folder, deepChapterPrompting: scriptedPrompt(PromptLog(), answer: .cancelExport)
        )
        await model.load()
        model.checked = [.markdown]
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }

        let exported = await model.export()
        let outcome = try XCTUnwrap(exported)

        XCTAssertTrue(outcome.wasCancelled)
        XCTAssertEqual(outcome.exported, [])
        XCTAssertEqual(model.summary, "Export stopped. Nothing was exported.")
        XCTAssertEqual(announcements.messages.last, "Export stopped. Nothing was exported.")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    /// Where nobody can be asked (the iPhone, or a model told so), the book
    /// fails with #5512's sentence and the others are exported, never a silent
    /// stop of the whole export.
    func testWhereNobodyCanBeAskedTheBookFailsAndTheOthersExport() async throws {
        let world = try makeIntegrationWorld("Export Deep Unavailable")
        let deep = try makeBook(in: world, named: "Deep One", content: deepChapter(limit + 1))
        let shallow = try makeBook(in: world, named: "Shallow Two", content: shallowChapter)
        let folder = try makeSandboxDirectory("Export Deep Unavailable Destination")
        let model = BookExportModel(books: [deep, shallow], destination: folder, deepChapterPrompting: .unavailable)
        await model.load()
        model.checked = [.markdown]
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }

        let exported = await model.export()
        let outcome = try XCTUnwrap(exported)

        XCTAssertFalse(outcome.wasCancelled)
        XCTAssertEqual(outcome.exported.map(\.lastPathComponent), [fileName(of: shallow, extension: "md")])
        XCTAssertEqual(outcome.failures.map(\.name), [fileName(of: deep, extension: "md")])
        XCTAssertEqual(
            outcome.failures.first?.reason, ExportWalkError.nestedTooDeeply(chapter: 1, limit: limit).localizedDescription
        )
    }

    /// A question is put only while the export is still going: Stop or Close,
    /// pressed after the export thread asked and before the main actor's turn,
    /// answers Cancel Export without showing the question; otherwise the
    /// prompt is asked, over the window given.
    func testAStoppedExportIsNotAsked() async {
        let question = ExportDeepChapterQuestion(bookTitle: "Deep Notes", chapter: 1, limit: 128, offersEveryOne: false)
        let log = PromptLog()
        let prompt = BookExportModel.DeepChapterPrompt(ask: { question, window in
            log.questions.append(question)
            log.windows.append(window)
            return .exportAsWritten
        })
        let dialog = NSWindow()

        let stopped = BookExportCancellation()
        stopped.cancel()
        let stoppedAnswer = await BookExportModel.put(question, through: prompt, over: dialog, unless: stopped)
        XCTAssertEqual(stoppedAnswer, .cancelExport)
        XCTAssertEqual(log.questions, [], "no question is shown for a stopped export")

        let running = BookExportCancellation()
        let answer = await BookExportModel.put(question, through: prompt, over: dialog, unless: running)
        XCTAssertEqual(answer, .exportAsWritten)
        XCTAssertEqual(log.questions, [question])
        XCTAssertTrue(log.windows.first.map { $0 === dialog } == true)
    }

    /// A box the scripted prompt waits in, until the model takes its question
    /// down.
    @MainActor
    private final class WaitingPrompt {
        /// The question being asked, set when the prompt is asked.
        var question: ExportDeepChapterQuestion?
        /// The export's wait, resumed by `dismiss`.
        var continuation: CheckedContinuation<ExportDeepChapterAnswer, Never>?
        /// How many times the model took the question down.
        var dismissals = 0
        /// How many times the model asked the question: once.
        var asks = 0

        /// A prompt that waits here, answers Cancel Export when dismissed,
        /// and counts its dismissals.
        var prompt: BookExportModel.DeepChapterPrompt {
            BookExportModel.DeepChapterPrompt(
                ask: { [self] question, _ in
                    asks += 1
                    self.question = question
                    return await withCheckedContinuation { self.continuation = $0 }
                },
                dismiss: { [self] in
                    dismissals += 1
                    continuation?.resume(returning: .cancelExport)
                    continuation = nil
                }
            )
        }
    }

    /// Stop, pressed while the question is on screen, takes it down through the
    /// prompt's seam as Cancel Export, and the export, which waited for the
    /// answer, ends stopped with nothing written: the wait never lasts for ever.
    func testStopTakesTheQuestionDown() async throws {
        let world = try makeIntegrationWorld("Export Deep Stop")
        let book = try makeBook(in: world, named: "Deep Notes", content: deepChapter(limit + 1))
        let folder = try makeSandboxDirectory("Export Deep Stop Destination")
        let waiting = WaitingPrompt()
        let model = BookExportModel(books: [book], destination: folder, deepChapterPrompting: .custom(waiting.prompt))
        await model.load()
        model.checked = [.markdown]
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }
        let finished = expectation(description: "the export ends")
        // A second ending is counted and fails below, never trapping the host.
        finished.assertForOverFulfill = false
        let result = PromptLog()
        let export = Task { @MainActor in
            result.outcome = await model.export()
            result.endings += 1
            finished.fulfill()
        }
        defer { export.cancel() }

        // Waits, with a limit, until the question is on screen.
        let asked = expectation(description: "the question is asked")
        asked.assertForOverFulfill = false
        let poll = Task { @MainActor in
            while waiting.question == nil { try? await Task.sleep(nanoseconds: 20_000_000) }
            asked.fulfill()
        }
        defer { poll.cancel() }
        await fulfillment(of: [asked], timeout: 20)
        model.stop()
        await fulfillment(of: [finished], timeout: 20)

        XCTAssertEqual(waiting.dismissals, 1)
        XCTAssertEqual(waiting.asks, 1, "the question was asked once")
        XCTAssertEqual(result.endings, 1, "the export ended once")
        let outcome = try XCTUnwrap(result.outcome)
        XCTAssertTrue(outcome.wasCancelled)
        XCTAssertEqual(outcome.exported, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    // MARK: - The alert

    /// The alert of one book's question has Export as Written, the first
    /// button, which Return presses as the default, and Cancel Export, which
    /// Escape presses; of an export that more may follow, Export Every Such
    /// Chapter as Written between them. Every button has its hint, and the
    /// alert its words.
    func testTheAlertsButtonsAndKeys() {
        let single = ExportDeepChapterQuestion(bookTitle: "Deep Notes", chapter: 2, limit: 128, offersEveryOne: false)
        let alert = ExportDeepChapterAlert.makeAlert(for: single)

        XCTAssertEqual(alert.messageText, BookExportDeepChapterWording.title(for: single))
        XCTAssertEqual(alert.informativeText, BookExportDeepChapterWording.message(for: single))
        XCTAssertEqual(alert.buttons.map(\.title), ["Export as Written", "Cancel Export"])
        XCTAssertEqual(alert.buttons.map { $0.accessibilityHelp() ?? "" }, [
            BookExportDeepChapterWording.exportAsWrittenHint,
            BookExportDeepChapterWording.cancelHint,
        ])
        XCTAssertEqual(alert.buttons.last?.keyEquivalent, "\u{1b}", "Escape presses Cancel Export")
        XCTAssertNotEqual(alert.buttons.first?.keyEquivalent, "\u{1b}")

        let several = ExportDeepChapterQuestion(bookTitle: "Deep Notes", chapter: nil, limit: 128, offersEveryOne: true)
        let longer = ExportDeepChapterAlert.makeAlert(for: several)
        XCTAssertEqual(longer.buttons.map(\.title), ["Export as Written", "Export Every Such Chapter as Written", "Cancel Export"])
        XCTAssertEqual(
            longer.buttons.dropFirst().first?.accessibilityHelp(), BookExportDeepChapterWording.exportEveryOneAsWrittenHint
        )
        XCTAssertEqual(longer.buttons.last?.keyEquivalent, "\u{1b}")
    }

    /// Each button's response is its answer, by position, and anything else,
    /// such as the alert being taken down by Stop, is Cancel Export.
    func testTheAlertsResponsesAreAnswers() {
        typealias Alert = ExportDeepChapterAlert
        XCTAssertEqual(Alert.answer(for: .alertFirstButtonReturn, offersEveryOne: false), .exportAsWritten)
        XCTAssertEqual(Alert.answer(for: .alertSecondButtonReturn, offersEveryOne: false), .cancelExport)
        XCTAssertEqual(Alert.answer(for: .alertFirstButtonReturn, offersEveryOne: true), .exportAsWritten)
        XCTAssertEqual(Alert.answer(for: .alertSecondButtonReturn, offersEveryOne: true), .exportEveryOneAsWritten)
        XCTAssertEqual(Alert.answer(for: .alertThirdButtonReturn, offersEveryOne: true), .cancelExport)
        XCTAssertEqual(Alert.answer(for: .cancel, offersEveryOne: true), .cancelExport)
        XCTAssertEqual(Alert.answer(for: .abort, offersEveryOne: false), .cancelExport)
    }

    /// The alert is a sheet only on a window that is on screen and has no sheet
    /// of its own yet; with no window (none was given), one that is not shown,
    /// or one that has a sheet already, it is a window of its own. A window the
    /// test makes is never shown, so it is not on screen.
    func testTheAlertIsASheetOnlyOnAWindowOnScreen() {
        typealias Alert = ExportDeepChapterAlert
        XCTAssertEqual(Alert.presentation(windowIsOnScreen: true, windowHasSheet: false), .sheet)
        XCTAssertEqual(Alert.presentation(windowIsOnScreen: true, windowHasSheet: true), .modal)
        XCTAssertEqual(Alert.presentation(windowIsOnScreen: false, windowHasSheet: false), .modal)
        XCTAssertEqual(Alert.presentation(windowIsOnScreen: nil, windowHasSheet: false), .modal)
        let hidden = NSWindow()
        XCTAssertEqual(Alert.presentation(windowIsOnScreen: hidden.isVisible, windowHasSheet: hidden.attachedSheet != nil), .modal)
    }

    /// What a scripted alert presenter saw.
    @MainActor
    private final class PresentedAlerts {
        var alerts: [NSAlert] = []
        var windows: [NSWindow?] = []
        var completions: [(NSApplication.ModalResponse) -> Void] = []
        var taken = 0
    }

    /// The alert shows over the window it is given, and `dismiss()` answers
    /// Cancel Export once, takes the alert down once, and leaves a completion
    /// AppKit calls afterwards, a second answer, with nothing to resume: the
    /// export waits for exactly one answer.
    func testDismissAnswersOnceWhateverAppKitDoesNext() async {
        let log = PresentedAlerts()
        let presenter = ExportDeepChapterAlert(
            present: { alert, window, completion in
                log.alerts.append(alert)
                log.windows.append(window)
                log.completions.append(completion)
            },
            take: { _ in log.taken += 1 }
        )
        let dialog = NSWindow()
        let question = ExportDeepChapterQuestion(bookTitle: "Deep Notes", chapter: 1, limit: 128, offersEveryOne: false)
        let answered = expectation(description: "the question is answered")
        // A second answer is counted and fails below, never trapping the host.
        answered.assertForOverFulfill = false
        let given = PromptLog()
        let asking = Task { @MainActor in
            given.answer = await presenter.ask(question, in: dialog)
            given.endings += 1
            answered.fulfill()
        }
        defer { asking.cancel() }

        let shown = expectation(description: "the alert is shown")
        shown.assertForOverFulfill = false
        let poll = Task { @MainActor in
            while log.alerts.isEmpty { try? await Task.sleep(nanoseconds: 20_000_000) }
            shown.fulfill()
        }
        defer { poll.cancel() }
        await fulfillment(of: [shown], timeout: 20)
        XCTAssertTrue(log.windows.first.map { $0 === dialog } == true, "over the dialog's own window")

        presenter.dismiss()
        await fulfillment(of: [answered], timeout: 20)
        XCTAssertEqual(given.answer, .cancelExport)
        XCTAssertEqual(given.endings, 1, "the question was answered once")
        XCTAssertEqual(log.alerts.count, 1, "the alert was shown once")
        XCTAssertEqual(log.taken, 1)

        // AppKit calls the sheet's completion after the sheet ends: nothing waits, and nothing traps.
        log.completions.first?(.alertFirstButtonReturn)
        presenter.dismiss()
        XCTAssertEqual(log.taken, 1, "no alert is on screen to take down again")
        XCTAssertEqual(given.endings, 1, "the late completion answered nothing again")
    }

    /// A button pressed answers once as its response says, and `dismiss()`
    /// after it finds nothing to take down.
    func testAButtonAnswersAndThereIsNothingLeftToDismiss() async {
        let log = PresentedAlerts()
        let presenter = ExportDeepChapterAlert(
            present: { alert, window, completion in
                log.alerts.append(alert)
                log.windows.append(window)
                log.completions.append(completion)
            },
            take: { _ in log.taken += 1 }
        )
        let question = ExportDeepChapterQuestion(bookTitle: "Deep Notes", chapter: 1, limit: 128, offersEveryOne: true)
        let answered = expectation(description: "the question is answered")
        // A second answer is counted and fails below, never trapping the host.
        answered.assertForOverFulfill = false
        let given = PromptLog()
        let asking = Task { @MainActor in
            given.answer = await presenter.ask(question, in: nil)
            given.endings += 1
            answered.fulfill()
        }
        defer { asking.cancel() }
        let shown = expectation(description: "the alert is shown")
        shown.assertForOverFulfill = false
        let poll = Task { @MainActor in
            while log.alerts.isEmpty { try? await Task.sleep(nanoseconds: 20_000_000) }
            shown.fulfill()
        }
        defer { poll.cancel() }
        await fulfillment(of: [shown], timeout: 20)

        log.completions.first?(.alertSecondButtonReturn)
        await fulfillment(of: [answered], timeout: 20)

        XCTAssertEqual(given.answer, .exportEveryOneAsWritten)
        XCTAssertEqual(given.endings, 1, "the question was answered once")
        XCTAssertEqual(log.alerts.count, 1, "the alert was shown once")
        presenter.dismiss()
        XCTAssertEqual(log.taken, 0)
    }
}
