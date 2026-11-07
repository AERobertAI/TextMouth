import XCTest
@testable import TextMouth

/// The import's iOS branches in shared code, read from the source, since the
/// Mac never compiles them and nothing can run on iOS tonight: each refusal
/// sits where the Mac would start a helper the phone lacks, each soft
/// announcement is iOS's alone, and the Mac's own lines are still there.
final class PhoneImportBranchTests: XCTestCase {

    // MARK: - Refusals

    /// A failure around a refusal says the refusal's sentence on iOS, and the
    /// Mac's two sentences are as they were.
    func testAFailureAroundARefusalSaysTheRefusal() throws {
        let source = try Self.source("Services/ImportFailure.swift")
        let reason = try Self.iOSBranch(after: "var reason: String {", in: source)
        XCTAssertTrue(reason.contains("if let refusal = underlying as? PhoneImportRefusal {"))
        XCTAssertTrue(reason.contains("refusal.sentence(naming: PhoneImportWording.displayName(ofFileNamed: fileName))"))
        let description = try Self.iOSBranch(after: "var errorDescription: String? {", in: source)
        XCTAssertTrue(description.contains("if underlying is PhoneImportRefusal { return reason }"))
        // The Mac's two sentences, in the #else branches, as they were.
        XCTAssertTrue(source.contains("#else\n        \"\\(step.activity) failed: \\(Self.description(of: underlying))\"\n        #endif"))
        XCTAssertTrue(source.contains("#else\n        \"Could not import “\\(fileName)”. \\(reason)\"\n        #endif"))
    }

    /// Audio the import would convert is refused on iOS in both of the
    /// conversion's paths, a folder's tracks and a single file, before any
    /// conversion starts.
    func testConvertedAudioIsRefusedBeforeItsConversion() throws {
        let source = try Self.source("Services/FileImportService+AudioConversion.swift")
        for (refusal, conversion) in [
            ("try PhoneImportRefusal.refuseConversion(of: sources)", "convertTracks(sources,"),
            ("try PhoneImportRefusal.refuseConversion(of: needed)", "convertTracks([bookURL],"),
        ] {
            let refused = try XCTUnwrap(source.range(of: refusal), "\(refusal) is gone")
            let converted = try XCTUnwrap(source.range(of: conversion), "\(conversion) moved")
            XCTAssertLessThan(refused.lowerBound, converted.lowerBound, "\(refusal) comes after the conversion")
            XCTAssertTrue(Self.isInsideIOSBranch(refused, of: source), "\(refusal) is outside #if os(iOS)")
        }
    }

    /// A Word 6 or Word 95 document is refused on iOS where it would go to
    /// textutil: after TextMouth's own readers, before the converter.
    func testWordSixOrNinetyFiveIsRefusedBeforeTextutil() throws {
        let source = try Self.source("Parsers/TextutilDocumentReader.swift")
        let refusal = try XCTUnwrap(source.range(of: "if format == .doc { throw PhoneImportRefusal.wordSixOrNinetyFive }"))
        let own = try XCTUnwrap(source.range(of: "if let own = try OwnDocumentReaders.html(of: url, as: format, includesPages: includesPages) {"))
        let textutil = try XCTUnwrap(source.range(of: "let html = try TextutilConverter.html(of: url, as: format, workingIn: folder)"))
        XCTAssertLessThan(own.lowerBound, refusal.lowerBound)
        XCTAssertLessThan(refusal.lowerBound, textutil.lowerBound)
        XCTAssertTrue(Self.isInsideIOSBranch(refusal, of: source))
    }

    /// A braille book is refused on iOS before anything of it is read.
    func testABrailleBookIsRefusedBeforeItIsRead() throws {
        let source = try Self.source("Parsers/BrailleBookReader.swift")
        let refusal = try XCTUnwrap(source.range(of: "try PhoneImportRefusal.refuseBrailleBook()"))
        let firstRead = try XCTUnwrap(source.range(of: "try requireUnchangedTable(table, recordedVersion: recordedVersion)"))
        XCTAssertLessThan(refusal.lowerBound, firstRead.lowerBound)
        XCTAssertTrue(Self.isInsideIOSBranch(refusal, of: source))
        XCTAssertThrowsError(try PhoneImportRefusal.refuseBrailleBook()) { error in
            XCTAssertEqual(error as? PhoneImportRefusal, .braille)
        }
    }

    // MARK: - What an Import Says

    /// On iOS an import's end and a batch's quarters are said at low priority,
    /// a quarter only while no book plays, and one book's end however short;
    /// the Mac's calls are as they were.
    func testAnImportSpeaksSoftlyOnThePhone() throws {
        let source = try Self.source("ViewModels/ImportProgress.swift")
        XCTAssertTrue(source.contains("static let unaskedPriority = NSAccessibilityPriorityLevel.low"))
        let quarter = try Self.iOSBranch(after: "guard quarter < 4, !state.isCancelling, hasRunLong(at: date), let subject else { return }", in: source)
        XCTAssertTrue(quarter.contains("guard !isBookPlaying() else { return }"))
        XCTAssertTrue(quarter.contains("priority: Self.unaskedPriority"))
        let end = try Self.iOSBranch(after: "if let words = endAnnouncement(for: ending) {", in: source)
        XCTAssertTrue(end.contains("VoiceOverAnnouncer.announce(words, priority: Self.unaskedPriority)"))
        let book = try Self.iOSBranch(after: "case .book:", in: source)
        XCTAssertTrue(book.contains("return ImportProgressWording.finished(book: subject)"))
        // The Mac's lines, in their #else branches.
        XCTAssertTrue(source.contains("            priority: .medium\n        )\n        #endif"))
        XCTAssertTrue(source.contains("return ranLong ? ImportProgressWording.finished(book: subject) : nil"))
    }

    /// The phone's alert for a failed import is titled Nothing Imported; the
    /// Mac's has no title, as before.
    func testAFailedImportsAlertIsTitledOnThePhone() throws {
        let source = try Self.source("ViewModels/LibraryViewModel+Import.swift")
        let branch = try Self.iOSBranch(after: "importProgress.end(.failure)", in: source)
        XCTAssertTrue(branch.contains("presentImportMessage(error.localizedDescription, title: ImportProgressWording.nothingImportedTitle)"))
        XCTAssertTrue(source.contains("        #else\n        presentImportMessage(error.localizedDescription)\n        #endif"))
    }

    // MARK: - Helpers

    /// The app source file at `path`, under the source folder.
    private static func source(_ path: String) throws -> String {
        try String(contentsOf: AppSourceFile.folder.appendingPathComponent(path), encoding: .utf8)
    }

    /// The text of the first `#if os(iOS)` branch after `anchor`, up to its
    /// `#else` or `#endif`.
    private static func iOSBranch(after anchor: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: anchor), "\(anchor) moved")
        let branch = try XCTUnwrap(source.range(of: "#if os(iOS)", range: start.upperBound..<source.endIndex), "No iOS branch after \(anchor)")
        let rest = source[branch.upperBound...]
        let end = [rest.range(of: "#else"), rest.range(of: "#endif")].compactMap { $0 }.min { $0.lowerBound < $1.lowerBound }
        let close = try XCTUnwrap(end, "The iOS branch after \(anchor) never closes")
        return String(source[branch.upperBound..<close.lowerBound])
    }

    /// Whether `range` lies between an `#if os(iOS)` and the next `#else` or
    /// `#endif` after it, with no other `#if` between.
    private static func isInsideIOSBranch(_ range: Range<String.Index>, of source: String) -> Bool {
        guard let opening = source.range(of: "#if os(iOS)", options: .backwards, range: source.startIndex..<range.lowerBound) else {
            return false
        }
        let between = source[opening.upperBound..<range.lowerBound]
        return !between.contains("#else") && !between.contains("#endif") && !between.contains("#if ")
    }
}
