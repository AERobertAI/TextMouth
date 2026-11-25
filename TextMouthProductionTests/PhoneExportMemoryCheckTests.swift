import XCTest
@testable import TextMouth

/// `PhoneExportMemoryCheck`: the iPhone's refusal, before a book's text is
/// walked, of a conversion the memory left would not hold (FR31), and the way
/// that refusal fails one file alone while the others export.
final class PhoneExportMemoryCheckTests: XCTestCase {
    /// A megabyte.
    private let megabyte: Int64 = 1 << 20
    /// The id of the HTML writer, a writer of text with no options.
    private let html = HTMLExportWriter().id

    // MARK: - The Arithmetic

    /// The estimate is the writer's figure times the text, and a text of no
    /// size, or a size that is wrong, estimates none.
    func testTheEstimateIsAMultipleOfTheText() {
        XCTAssertEqual(PhoneExportMemoryCheck.estimatedPeak(textBytes: 10 * megabyte, writerID: html), 10 * UInt64(megabyte) * PhoneExportMemoryCheck.peakBytesPerTextByte)
        XCTAssertEqual(PhoneExportMemoryCheck.estimatedPeak(textBytes: 0, writerID: html), 0)
        XCTAssertEqual(PhoneExportMemoryCheck.estimatedPeak(textBytes: -5, writerID: html), 0)
    }

    /// The braille writers have a figure of their own, larger than the text writers', which holds the
    /// peaks measured on GitHub's simulator (19.0 to 28.8 for braille, 5.4 to 10.9 for the others); every
    /// other writer has the text figure, an unknown one included.
    func testTheBrailleWritersHaveALargerFigure() {
        XCTAssertGreaterThan(PhoneExportMemoryCheck.braillePeakBytesPerTextByte, PhoneExportMemoryCheck.peakBytesPerTextByte)
        XCTAssertGreaterThanOrEqual(PhoneExportMemoryCheck.braillePeakBytesPerTextByte, 29, "the most measured is 28.8")
        XCTAssertGreaterThanOrEqual(PhoneExportMemoryCheck.peakBytesPerTextByte, 11, "the most measured is 10.9")
        for id in [BRFExportWriter().id, PEFExportWriter().id] {
            XCTAssertEqual(PhoneExportMemoryCheck.peakBytesPerTextByte(forWriter: id), PhoneExportMemoryCheck.braillePeakBytesPerTextByte, id)
        }
        for id in [html, RTFExportWriter().id, EPUBExportWriter().id, TextExportWriters.markdownID, "a-writer-not-yet-written"] {
            XCTAssertEqual(PhoneExportMemoryCheck.peakBytesPerTextByte(forWriter: id), PhoneExportMemoryCheck.peakBytesPerTextByte, id)
        }
    }

    /// A conversion is allowed when the estimate and the floor both fit in the
    /// memory left, exactly at the edge and not a byte under it.
    func testAConversionIsAllowedWhenTheEstimateAndTheFloorFit() {
        let text = 4 * megabyte
        for id in [html, BRFExportWriter().id] {
            let needed = PhoneExportMemoryCheck.estimatedPeak(textBytes: text, writerID: id) + PhoneExportMemoryCheck.floorBytes

            XCTAssertTrue(PhoneExportMemoryCheck.allows(writerID: id, textBytes: text, availableBytes: needed), id)
            XCTAssertFalse(PhoneExportMemoryCheck.allows(writerID: id, textBytes: text, availableBytes: needed - 1), id)
            XCTAssertTrue(PhoneExportMemoryCheck.allows(writerID: id, textBytes: text, availableBytes: needed + 1), id)
        }
    }

    /// A book the estimate of a braille writer cannot fit is refused where a web page of the same text is not:
    /// with 600 MB left, 4 MB of text fits HTML (64 MB and the floor) and not BRF (128 MB and the floor).
    func testBrailleIsRefusedWhereHTMLFits() {
        let left: UInt64 = 600 << 20

        XCTAssertTrue(PhoneExportMemoryCheck.allows(writerID: html, textBytes: 4 * megabyte, availableBytes: left))
        XCTAssertFalse(PhoneExportMemoryCheck.allows(writerID: BRFExportWriter().id, textBytes: 4 * megabyte, availableBytes: left))
        XCTAssertFalse(PhoneExportMemoryCheck.allows(writerID: PEFExportWriter().id, textBytes: 4 * megabyte, availableBytes: left))
        XCTAssertThrowsError(try PhoneExportMemoryCheck.check(writerID: BRFExportWriter().id, textBytes: 4 * megabyte, availableBytes: left))
        XCTAssertNoThrow(try PhoneExportMemoryCheck.check(writerID: html, textBytes: 4 * megabyte, availableBytes: left))
    }

    /// The floor is the in-app converter's 512 MB: even an empty text is
    /// refused when less than that is left.
    func testTheFloorHoldsEvenForAnEmptyText() {
        XCTAssertEqual(PhoneExportMemoryCheck.floorBytes, 512 << 20)
        XCTAssertTrue(PhoneExportMemoryCheck.allows(writerID: html, textBytes: 0, availableBytes: PhoneExportMemoryCheck.floorBytes))
        XCTAssertFalse(PhoneExportMemoryCheck.allows(writerID: html, textBytes: 0, availableBytes: PhoneExportMemoryCheck.floorBytes - 1))
        XCTAssertFalse(PhoneExportMemoryCheck.allows(writerID: html, textBytes: 0, availableBytes: 0), "0 left is an app over its limit")
    }

    /// Where the system sets the app no limit, as in the simulator, every
    /// conversion is allowed.
    func testNoKnownLimitAllowsEverything() {
        XCTAssertTrue(PhoneExportMemoryCheck.allows(writerID: html, textBytes: Int64.max, availableBytes: nil))
    }

    /// A text so large that its estimate overflows is refused, never wrapped
    /// round to a small figure that passes.
    func testAnOverflowingEstimateIsRefused() {
        XCTAssertFalse(PhoneExportMemoryCheck.allows(writerID: html, textBytes: Int64.max, availableBytes: UInt64.max))
    }

    // MARK: - The Refusal

    /// A refusal is a text-export error saying what happened and what to do,
    /// in the one sentence of the iPhone's own.
    func testARefusalSaysWhatToDo() {
        XCTAssertThrowsError(try PhoneExportMemoryCheck.check(writerID: html, textBytes: 64 * megabyte, availableBytes: 600 << 20)) { error in
            XCTAssertEqual(
                (error as? TextExportError)?.sentence,
                "The iPhone has too little memory free to convert this book now. Close other apps, then export again."
            )
        }
        XCTAssertNoThrow(try PhoneExportMemoryCheck.check(writerID: html, textBytes: megabyte, availableBytes: 2 << 30))
    }

    // MARK: - An Export Through the Guard

    /// The guard fails the file of a book too large for the memory left, with
    /// the refusal's sentence, before anything of the book is read, while the
    /// books that fit still export, and the folder holds only theirs.
    func testABookTooLargeFailsAloneAndTheOthersExport() throws {
        let sandbox = try makeSandboxDirectory("Phone Export Memory")
        let small = try makeOffer(title: "Small Harbour", bytes: 1_000, in: sandbox)
        let large = try makeOffer(title: "Large Harbour", bytes: 8 * 1_048_576, in: sandbox)
        let destination = sandbox.appendingPathComponent("Chosen", isDirectory: true)
        let conversion = BookExportConversion.text(TextExportConversion(HTMLExportWriter(), options: NoTextExportOptions()))
        // 600 MB left holds the small book, and not 8 MB of text, whose estimate and the floor come to more.
        let memoryLeft: UInt64 = 600 << 20
        let memoryGuard: BookExportMemoryGuard = { writerID, textBytes in
            try PhoneExportMemoryCheck.check(writerID: writerID, textBytes: textBytes, availableBytes: memoryLeft)
        }

        let outcome = BookExportService.export(
            [small, large],
            kinds: [.markdown],
            conversions: [.markdown: conversion],
            to: destination,
            delivery: .coordinatedCopy,
            memoryGuard: memoryGuard
        )

        XCTAssertEqual(outcome.exported.map(\.lastPathComponent), ["Small Harbour - Text.html"])
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertEqual(outcome.failures.first?.reason, PhoneExportWording.tooLittleMemory)
        XCTAssertTrue(outcome.failures.first?.name.hasPrefix("Large Harbour") == true, "\(String(describing: outcome.failures.first?.name))")
        XCTAssertFalse(outcome.wasCancelled)
    }

    /// A book the braille factor cannot fit is refused as a BRF, before the translator is asked for anything, while
    /// the same book exported as Markdown, whose factor is smaller, is written: 4 MB of text with 600 MB left.
    func testTheSameBookIsRefusedAsBrailleAndWrittenAsMarkdown() throws {
        let sandbox = try makeSandboxDirectory("Phone Export Braille Refused")
        let book = try makeOffer(title: "Large Harbour", bytes: 4 * 1_048_576, in: sandbox)
        let memoryLeft: UInt64 = 600 << 20
        let memoryGuard: BookExportMemoryGuard = { writerID, textBytes in
            try PhoneExportMemoryCheck.check(writerID: writerID, textBytes: textBytes, availableBytes: memoryLeft)
        }
        let brf = BookExportConversion.text(TextExportConversion(BRFExportWriter(), options: BrailleExportOptions()))

        let asBraille = BookExportService.export(
            [book], kinds: [.markdown], conversions: [.markdown: brf],
            to: sandbox.appendingPathComponent("Braille", isDirectory: true), delivery: .coordinatedCopy, memoryGuard: memoryGuard
        )
        let asMarkdown = BookExportService.export(
            [book], kinds: [.markdown], conversions: [.markdown: .markdown],
            to: sandbox.appendingPathComponent("Markdown", isDirectory: true), delivery: .coordinatedCopy, memoryGuard: memoryGuard
        )

        XCTAssertEqual(asBraille.exported, [])
        XCTAssertEqual(asBraille.failures.map(\.reason), [PhoneExportWording.tooLittleMemory])
        XCTAssertEqual(asMarkdown.failures, [])
        XCTAssertEqual(asMarkdown.exported.map(\.lastPathComponent), ["Large Harbour - Text.md"])
    }

    /// With no guard, as on the Mac, a book is converted whatever its size.
    func testWithNoGuardEveryBookIsConverted() throws {
        let sandbox = try makeSandboxDirectory("Phone Export No Guard")
        let offer = try makeOffer(title: "Harbour", bytes: 1_000, in: sandbox)
        let conversion = BookExportConversion.text(TextExportConversion(HTMLExportWriter(), options: NoTextExportOptions()))

        let outcome = BookExportService.export(
            [offer],
            kinds: [.markdown],
            conversions: [.markdown: conversion],
            to: sandbox.appendingPathComponent("Chosen", isDirectory: true)
        )

        XCTAssertEqual(outcome.exported.count, 1)
        XCTAssertEqual(outcome.failures, [])
    }

    // MARK: - Helpers

    /// An offer, made by hand, of a book's Markdown, whose text cache holds
    /// `bytes` bytes of paragraphs: written in `folder`, and sized as the
    /// offer sizes it.
    private func makeOffer(title: String, bytes: Int, in folder: URL) throws -> BookExportOffer {
        let package = folder.appendingPathComponent("\(title) \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let cache = package.appendingPathComponent("content.md")
        let paragraph = "The pilot boat ties up at the slip.\n\n"
        let text = String(repeating: paragraph, count: max(1, bytes / paragraph.utf8.count))
        try Data(text.utf8).write(to: cache)
        let size = Int64(text.utf8.count)
        let book = Book(title: title, format: .markdown, filePath: cache.path, md5Hash: "")
        let file = BookExportFile(
            source: .converted(from: cache, book: ExportBookDetails(book), by: .markdown),
            path: "\(BookExportService.fileNameStem(for: title)) - Text.md",
            byteCount: size
        )
        let item = BookExportItem(kind: .markdown, folderName: nil, files: [file], fileInCloud: nil)
        return BookExportOffer(book: book, items: [item], isPackageInCloud: false)
    }
}
