import AppKit
import XCTest
import os
@testable import TextMouth

/// A chapter nested too deeply, exported as it is written or not at all
/// (FR24), end to end through the export service as the Export dialog calls
/// it, and through the dialog's model with a scripted answer:
///
/// - every text format writes the chapter as plain paragraphs of its lines when
///   it is asked, at the limit (no question) and one level past it;
/// - Cancel Export leaves no file for the book and ends the export as Stop
///   does, saying what was written before;
/// - "every such chapter" holds for the rest of one export and no other;
/// - the plain text export, which has always kept such a chapter as written,
///   still does, and never asks;
/// - the alert's buttons and keys.
///
/// No test shows an alert: every question is answered by a script, through the
/// export's own seam (`BookExportService.export(..., askAboutDeepChapters:)`
/// and `BookExportModel`'s `deepChapterPrompt`). Every book lives in a library
/// folder of the test's own and every export goes to a sandbox folder. A deep
/// content.md is put in a shallow book's package after its import, since an
/// import refuses a source that deep. The depths are those of the limit and
/// one past it, which the old walk, that refused them, survives.
@MainActor
final class ExportDeepChapterExportTests: XCTestCase {

    // MARK: - Helpers

    /// The deepest nesting read (128).
    private var limit: Int { MarkupGuard.Limits.standard.deepestNesting }

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
    /// it.
    private func deepChapter(_ levels: Int) -> String {
        "<!-- chapter: Notes -->\n" + DeepMarkdown.quotes(levels)
    }

    /// The one line of `deepChapter(_:)`.
    private func deepLine(_ levels: Int) -> String {
        DeepMarkdown.quotes(levels)
    }

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

    /// Every text format writes a chapter nested one level past the limit as
    /// the paragraph of its line when it is asked, once, naming the book and
    /// the chapter's number, and writes one nested as far as the limit allows
    /// as it always did, with no question.
    func testEveryFormatWritesTheDeepChapterAsWrittenWhenAsked() throws {
        let world = try makeIntegrationWorld("Export Deep Formats")
        var writers: [any TextExportWriter] = [MarkdownExportWriter()]
        writers += TextExportWriters.all
        for levels in [limit, limit + 1] {
            let book = try makeBook(in: world, named: "Deep Notes \(levels)", content: deepChapter(levels))
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
                try checkFile(file, of: writer, isDeep: isDeep, levels: levels, name: name)
            }
        }
    }

    /// What `file`, which `writer` wrote of a one-chapter book whose line is
    /// `levels` quotes deep, holds: the text, with no quote when it is
    /// written as written.
    private func checkFile(_ file: URL, of writer: any TextExportWriter, isDeep: Bool, levels: Int, name: String) throws {
        let data = try Data(contentsOf: file)
        XCTAssertFalse(data.isEmpty, name)
        let text = String(decoding: data, as: UTF8.self)
        switch writer.fileExtension {
        case "md":
            // The Markdown is a correct file: it reads back, with no refusal,
            // and its paragraph is the line as it was written.
            let document = try ExportDocumentWalker.document(fromMarkdown: text, book: ExportBookDetails(title: ""))
            let paragraphs = document.blocks.compactMap { block -> String? in
                if case let .paragraph(runs) = block { return runs.plainText }
                return nil
            }
            XCTAssertTrue(text.contains("Quoted words"), name)
            if isDeep {
                XCTAssertEqual(paragraphs, [deepLine(levels)], name)
            }
        case "html":
            XCTAssertTrue(text.contains("Quoted words"), name)
            XCTAssertEqual(text.contains("<blockquote"), !isDeep, name)
        case "rtf":
            XCTAssertTrue(text.contains("Quoted words"), name)
        case "epub":
            XCTAssertEqual(String(decoding: data.prefix(2), as: UTF8.self), "PK", "\(name) is a ZIP package")
        default:
            // Word 97-2003, BRF, and PEF are binary or braille: their files
            // are made, and are not empty.
            break
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
    /// the question offers it, since the export has more than one book.
    func testEveryChapterAnswerHoldsForTheRestOfTheExport() throws {
        let world = try makeIntegrationWorld("Export Deep Every")
        let first = try makeBook(in: world, named: "Deep One", content: deepChapter(limit + 1))
        let middle = try makeBook(in: world, named: "Shallow Two", content: "<!-- chapter: Notes -->\nShallow words.")
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

    /// Without "every such chapter", each deep book is asked about on its own,
    /// naming that book, and a later Cancel Export keeps the books written
    /// before it and stops the rest, saying so.
    func testEachDeepBookIsAskedAndACancelStopsTheRest() throws {
        let world = try makeIntegrationWorld("Export Deep Each")
        let first = try makeBook(in: world, named: "Deep One", content: deepChapter(limit + 1))
        let middle = try makeBook(in: world, named: "Shallow Two", content: "<!-- chapter: Notes -->\nShallow words.")
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
        let second = try makeBook(in: world, named: "Shallow Two", content: "<!-- chapter: Notes -->\nShallow words.")
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

    // MARK: - The dialog

    /// The questions the dialog's model puts, in order, kept on the main actor.
    @MainActor
    private final class PromptLog {
        var questions: [ExportDeepChapterQuestion] = []
    }

    /// The dialog's export asks through its prompt, on the main actor, with
    /// the book's title and the chapter's number, and writes the chapter as
    /// written when the answer says so.
    func testTheDialogAsksThroughItsPromptAndExportsAsWritten() async throws {
        let world = try makeIntegrationWorld("Export Deep Dialog")
        let book = try makeBook(in: world, named: "Deep Notes", content: deepChapter(limit + 1))
        let folder = try makeSandboxDirectory("Export Deep Dialog Destination")
        let log = PromptLog()
        let model = BookExportModel(books: [book], destination: folder, deepChapterPrompt: { question in
            log.questions.append(question)
            return .exportAsWritten
        })
        await model.load()
        model.checked = [.markdown]
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }

        let outcome = try XCTUnwrap(await model.export())

        XCTAssertEqual(
            log.questions,
            [ExportDeepChapterQuestion(bookTitle: book.title, chapter: 1, limit: limit, offersEveryOne: false)]
        )
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
        let model = BookExportModel(books: [book], destination: folder, deepChapterPrompt: { _ in .cancelExport })
        await model.load()
        model.checked = [.markdown]
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }

        let outcome = try XCTUnwrap(await model.export())

        XCTAssertTrue(outcome.wasCancelled)
        XCTAssertEqual(outcome.exported, [])
        XCTAssertEqual(model.summary, "Export stopped. Nothing was exported.")
        XCTAssertEqual(announcements.messages.last, "Export stopped. Nothing was exported.")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    // MARK: - The alert

    /// The alert of one book's question has Export as Written, which Return
    /// presses as the first button, and Cancel Export, which Escape presses;
    /// of an export of several books, Export Every Such Chapter as Written
    /// between them. Every button has its hint, and the alert its words.
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
}
