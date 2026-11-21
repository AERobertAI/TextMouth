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
        XCTAssertTrue(source.contains("#else\n        Self.failedSentence(step: step, because: Self.description(of: underlying))\n        #endif"))
        XCTAssertTrue(source.contains("#else\n        SentenceWording.joined([ImportProgressWording.failed(fileName), reason])\n        #endif"))
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

    /// The iPhone refuses no file of TextMouth's own readers (True Audio,
    /// WavPack, Monkey's Audio): the refusal asks the one shared rule
    /// (`isReadByOwnReader`) beside FFmpeg's, and the converter's one iPhone
    /// branch, where afinfo would have answered, tells a file named for such
    /// a format whose bytes are of none unreadable, as the Mac does; every
    /// other file that gets there is still told "not available on iPhone yet".
    func testTheOwnReadersFormatsAreNotRefusedOnThePhone() throws {
        let refusal = try Self.source("Phone/PhoneImportRefusal.swift")
        XCTAssertTrue(refusal.contains("!FFmpegAudioConverter.converts($0) && !isReadByOwnReader($0)"))
        XCTAssertFalse(refusal.contains("OwnAudioFormat.allCases"), "the refusal still names the own readers' formats")
        let converter = try Self.source("Services/ImportAudioConverter.swift")
        let branch = try Self.iOSBranch(after: "var described = try OwnAudioConverter.sourceInfo(of: source)", in: converter)
        XCTAssertTrue(branch.contains("guard ownReaderExtensions.contains(source.pathExtension.lowercased()) else {"))
        XCTAssertTrue(branch.contains("throw IOSUnavailable.feature(\"Converting this kind of file\")"))
        XCTAssertTrue(branch.contains("throw Failure.unreadable(fileName: name)"))
    }

    /// A conversion by TextMouth's own readers asks the memory floor before
    /// each block on the iPhone alone (`OwnAudioMemoryWatch`); the Mac's
    /// check is nothing, and the one writer FFmpeg's import shares
    /// (`writeBlocks`) is not changed. The watch itself is tested on the
    /// iPhone (`OwnAudioMemoryWatchTests`).
    func testTheOwnReadersAskTheMemoryFloorBeforeEachBlockOnThePhoneOnly() throws {
        let source = try Self.source("Services/OwnAudioConverter.swift")
        let branch = try Self.iOSBranch(after: "var decoder = try format.decoder(of: bytes, companion: companionBytes(of: source))", in: source)
        XCTAssertTrue(branch.contains("let beforeEachBlock = OwnAudioMemoryWatch(fileName: name).check"))
        XCTAssertTrue(source.contains("#else\n            let beforeEachBlock: () throws -> Void = {}\n            #endif"))
        XCTAssertTrue(source.contains("try beforeEachBlock()\n            return try decoder.nextBlock()"))
        let writer = try XCTUnwrap(source.range(of: "static func writeBlocks("), "writeBlocks moved")
        let tags = try XCTUnwrap(source.range(of: "// MARK: - Tags"), "the Tags section moved")
        XCTAssertFalse(source[writer.lowerBound..<tags.lowerBound].contains("OwnAudioMemoryWatch"), "the shared writer asks the floor")
        let watch = try Self.source("Platform/iOS/Services/OwnAudioMemoryWatch+iOS.swift")
        XCTAssertTrue(watch.contains("memory.leftWhenCrossed()"), "the watch does not ask the one floor")
        XCTAssertTrue(watch.contains("ImportAudioConverter.Failure.killed("))
    }

    /// A book of several tracks leaves out what only ffmpeg reads and can't
    /// be converted (review9 finding 2) by one shared line on both platforms,
    /// asking the FFmpeg tool where its session runs (the iPhone's is in the
    /// app since FMT54, so it converts what the Mac converts), before the
    /// iPhone refuses the rest of its converted audio; and the iPhone's words
    /// for a track left out for want of FFmpeg are gone with the refusal.
    func testWhatOnlyFFmpegReadsIsLeftOutBeforeTheRefusal() throws {
        let source = try Self.source("Services/FileImportService+AudioConversion.swift")
        let leftOut = try XCTUnwrap(
            source.range(of: "try leavingOutWhatOnlyFFmpegReads(found, from: bookURL) { FFmpegAudioConverter.tool.locate() }"))
        let refused = try XCTUnwrap(source.range(of: "try PhoneImportRefusal.refuseConversion(of: sources)"))
        XCTAssertLessThan(leftOut.lowerBound, refused.lowerBound)
        XCTAssertFalse(Self.isInsideIOSBranch(leftOut, of: source), "the leaving out is the iPhone's alone")
        XCTAssertEqual(source.components(separatedBy: "leavingOutWhatOnlyFFmpegReads(found").count - 1, 1,
                       "the leaving out is not one line for both platforms")
        XCTAssertFalse(source.contains("PhoneImportWording.ffmpeg"), "the iPhone still has words of its own for FFmpeg's files")
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

    /// A braille book is read on iOS as on the Mac (DR34): the braille
    /// reader's one iPhone branch refuses only a book that needs one of a
    /// Mac's own tables, which the iPhone lacks (the review of November 16,
    /// finding 5), and does nothing else; no refusal is braille's own; and
    /// the translator's iPhone branch translates in the app's own process.
    func testABrailleBookIsReadOnThePhoneAsOnTheMac() throws {
        let reader = try Self.source("Parsers/BrailleBookReader.swift")
        XCTAssertEqual(reader.components(separatedBy: "#if os(iOS)").count - 1, 1, "the braille reader reads otherwise on the phone")
        let branch = try Self.iOSBranch(after: "static func markdown(", in: reader)
        let statements = branch.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") }
        XCTAssertEqual(
            statements, ["try PhoneImportRefusal.refuseMacBrailleTable(table)"],
            "the braille reader refuses more than a Mac's own table on the phone"
        )
        let refusals = try Self.source("Phone/PhoneImportRefusal.swift")
        XCTAssertFalse(refusals.contains("case braille"), "a refusal is still braille's")
        let translator = try Self.source("Services/BrailleTranslator.swift")
        let inProcess = try XCTUnwrap(
            translator.range(of: "return try translateInProcess(texts, table: table, direction: direction)"),
            "the translator's iPhone branch is gone"
        )
        XCTAssertTrue(Self.isInsideIOSBranch(inProcess, of: translator), "the in-process translation is outside #if os(iOS)")
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
