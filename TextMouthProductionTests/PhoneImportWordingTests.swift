import XCTest
@testable import TextMouth

/// `PhoneImportWording` and `PhoneImportRefusal`: every sentence the iPhone's
/// importing says that the Mac doesn't, word for word as the spec gives it,
/// and how a refusal names the audio it can't play.
@MainActor
final class PhoneImportWordingTests: XCTestCase {

    // MARK: - Names

    /// A file is named without its extension, as its book's title will be; a
    /// name that is all extension is kept whole.
    func testDisplayNameDropsTheExtension() {
        XCTAssertEqual(PhoneImportWording.displayName(of: URL(fileURLWithPath: "/tmp/Dune.epub")), "Dune")
        XCTAssertEqual(PhoneImportWording.displayName(ofFileNamed: "Radio Drama.zip"), "Radio Drama")
        XCTAssertEqual(PhoneImportWording.displayName(ofFileNamed: "Ledger"), "Ledger")
        XCTAssertEqual(PhoneImportWording.displayName(ofFileNamed: ".epub"), ".epub")
    }

    // MARK: - Starting

    /// One item is named; several are counted; none says nothing.
    func testImportingSaysTheBookOrTheCount() {
        XCTAssertEqual(PhoneImportWording.importing(["Dune"]), "Importing Dune")
        XCTAssertEqual(PhoneImportWording.importing(["Dune", "Emma", "Ulysses"]), "Importing 3 books")
        XCTAssertNil(PhoneImportWording.importing([]))
    }

    /// A count in a sentence is a count, grouped for the region as every
    /// count is, in both sentences that hold one (FR34).
    func testACountInASentenceIsGroupedForTheRegion() {
        let many = Array(repeating: "Dune", count: 1234)
        let grouped = 1234.formatted()
        XCTAssertEqual(PhoneImportWording.importing(many), "Importing \(grouped) books")
        XCTAssertEqual(
            PhoneImportWording.stoppedWhenClosed(many),
            "Importing \(grouped) books was stopped when TextMouth closed. Add them again."
        )
    }

    // MARK: - Downloading

    /// The card's line, and the sentence after a stalled download.
    func testDownloadWords() {
        XCTAssertEqual(PhoneImportWording.downloading("Dune"), "Downloading “Dune”")
        XCTAssertEqual(
            PhoneImportWording.downloadFailed("Dune"),
            "“Dune” couldn't be downloaded from iCloud. Check the connection, then add it again."
        )
    }

    // MARK: - Stopped by Closing

    /// One import is the spec's sentence; up to three are named; more are
    /// counted; none says nothing.
    func testStoppedWhenClosed() {
        XCTAssertEqual(
            PhoneImportWording.stoppedWhenClosed(["Dune"]),
            "Importing “Dune” was stopped when TextMouth closed. Add it again."
        )
        XCTAssertEqual(
            PhoneImportWording.stoppedWhenClosed(["Dune", "Emma"]),
            "Importing “Dune” and “Emma” was stopped when TextMouth closed. Add them again."
        )
        XCTAssertEqual(
            PhoneImportWording.stoppedWhenClosed(["A", "B", "C", "D", "E"]),
            "Importing 5 books was stopped when TextMouth closed. Add them again."
        )
        XCTAssertNil(PhoneImportWording.stoppedWhenClosed([]))
    }

    // MARK: - Refusals

    /// The refusals, each naming the file and the next step, as the spec's
    /// "What can't be imported" gives them. Braille has none since DR34: the
    /// iPhone reads it.
    func testRefusalSentences() {
        XCTAssertEqual(
            PhoneImportRefusal.convertedAudio(kind: "Ogg").sentence(naming: "Radio Drama"),
            "“Radio Drama” is in Ogg, which TextMouth on iPhone can't play yet. Add it on your Mac, then send the book here."
        )
        XCTAssertEqual(
            PhoneImportRefusal.wordSixOrNinetyFive.sentence(naming: "Notes"),
            "“Notes” is a Word 6 or Word 95 document, which TextMouth on iPhone can't read yet. Add it on your Mac, then send the book here."
        )
        XCTAssertEqual(
            PhoneImportRefusal.macBrailleTable("fr-bfu-g2.ctb").sentence(naming: "Manuel"),
            "“Manuel” needs “fr-bfu-g2.ctb”, one of a Mac's own braille tables, which TextMouth on iPhone doesn't have. "
                + "Add it on your Mac, then send the book here."
        )
    }

    /// Only one of a Mac's own braille tables that the app's pack has no table of the same file name for is refused, by its
    /// file name; a bundled table passes, and so does a Mac's table whose file name the pack has (FR40: the Mac's pack has
    /// the four English tables, the iPhone's has them and every other table it ships).
    func testOnlyAMacsOwnBrailleTableTheAppLacksIsRefused() {
        XCTAssertThrowsError(try PhoneImportRefusal.refuseMacBrailleTable("mac:no-such-table.ctb")) {
            XCTAssertEqual($0 as? PhoneImportRefusal, .macBrailleTable("no-such-table.ctb"))
        }
        for bundled in ["en-ueb-g2.ctb", "en_US.tbl", "mac:en-ueb-g2.ctb", "mac:en_US.tbl"] {
            XCTAssertNoThrow(try PhoneImportRefusal.refuseMacBrailleTable(bundled), bundled)
        }
        #if os(iOS)
        XCTAssertNoThrow(try PhoneImportRefusal.refuseMacBrailleTable("mac:fr-bfu-g2.ctb"), "the iPhone's pack has the French table")
        #else
        XCTAssertThrowsError(try PhoneImportRefusal.refuseMacBrailleTable("mac:fr-bfu-g2.ctb"), "the Mac's pack has English alone")
        #endif
    }

    /// Without a name, a refusal says "This file", which its error
    /// description is.
    func testRefusalWithoutANameSaysThisFile() {
        XCTAssertEqual(
            PhoneImportRefusal.wordSixOrNinetyFive.errorDescription,
            "This file is a Word 6 or Word 95 document, which TextMouth on iPhone can't read yet. Add it on your Mac, then send the book here."
        )
    }

    /// The kind is named by the content first: Ogg named .m4a is Ogg, Ogg
    /// named .opus is Opus, and the Mac's names are kept ("AC-3", "MP2").
    func testAudioKindNames() {
        XCTAssertEqual(PhoneImportRefusal.audioKindName(content: .ogg, fileExtension: "ogg"), "Ogg")
        XCTAssertEqual(PhoneImportRefusal.audioKindName(content: .ogg, fileExtension: "m4a"), "Ogg")
        XCTAssertEqual(PhoneImportRefusal.audioKindName(content: .ogg, fileExtension: "OPUS"), "Opus")
        XCTAssertEqual(PhoneImportRefusal.audioKindName(content: .ac3, fileExtension: "mp3"), "AC-3")
        XCTAssertEqual(PhoneImportRefusal.audioKindName(content: .amr, fileExtension: "amr"), "AMR")
        XCTAssertEqual(PhoneImportRefusal.audioKindName(content: .mpegLayerII, fileExtension: "mp3"), "MP2")
        XCTAssertEqual(PhoneImportRefusal.audioKindName(content: .caf, fileExtension: "caf"), "CAF")
        // Content that doesn't settle it is named by the extension.
        XCTAssertEqual(PhoneImportRefusal.audioKindName(content: .unknown, fileExtension: "ec3"), "AC-3")
        XCTAssertEqual(PhoneImportRefusal.audioKindName(content: .mpeg4, fileExtension: "3gp"), "3GPP")
        XCTAssertEqual(PhoneImportRefusal.audioKindName(content: .unknown, fileExtension: "wma"), "WMA")
    }

    /// Every extension the import converts is named among the Mac's names
    /// of its formats, never by the capitals fallback, so no refusal says
    /// "OGG" or "AIFC"; those only ffmpeg reads by their names (FMT31). The
    /// formats of TextMouth's own readers are never refused, so have none.
    func testEveryConvertedExtensionHasAName() {
        let names: Set<String> = [
            "Ogg", "Opus", "AC-3", "CAF", "AIFF-C", "AU", "Wave64", "AMR", "3GPP", "MP1", "MP2",
            "WMA", "WMV video", "Windows Media", "Speex", "Musepack", "WebM", "Matroska", "AVI video", "Flash video",
            "RealMedia",
        ]
        for ext in ImportAudioConverter.convertedExtensions.subtracting(ImportAudioConverter.ownReaderExtensions) {
            let name = PhoneImportRefusal.audioKindName(content: .unknown, fileExtension: ext)
            XCTAssertTrue(names.contains(name), "\(ext) is named \(name)")
        }
    }

    /// A refusal is thrown only for files there are: none means the import
    /// goes on.
    func testRefuseConversionThrowsOnlyForFiles() throws {
        XCTAssertNoThrow(try PhoneImportRefusal.refuseConversion(of: []))
        let ogg = URL(fileURLWithPath: "/nonexistent/Radio Drama.ogg")
        XCTAssertThrowsError(try PhoneImportRefusal.refuseConversion(of: [ogg])) { error in
            XCTAssertEqual(error as? PhoneImportRefusal, .convertedAudio(kind: "Ogg"))
        }
    }

    // MARK: - The Progress Card

    /// While a file comes down from iCloud the card says so; while a local
    /// file is copied it says the Mac's first step; once the shared import
    /// has it, the Mac's own lines; and VoiceOver reads the Mac's title
    /// before them.
    func testCardLines() {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let idle = ImportProgressState()
        let downloading = PhoneImportCopyRun.Status(name: "Dune", isDownloading: true)
        let local = PhoneImportCopyRun.Status(name: "Dune", isDownloading: false)

        XCTAssertEqual(PhoneImportWording.cardLines(copying: downloading, state: idle, at: now), ["Downloading “Dune”"])
        XCTAssertEqual(
            PhoneImportWording.cardLines(copying: local, state: idle, at: now),
            [ImportProgressWording.book("Dune", step: .readingSource)]
        )
        XCTAssertEqual(
            PhoneImportWording.cardSummary(copying: downloading, state: idle, at: now),
            "Importing Books: Downloading “Dune”."
        )

        let importing = ImportProgressState(book: "Dune.epub", at: now, step: .readingText)
        XCTAssertEqual(PhoneImportWording.cardLines(copying: nil, state: importing, at: now), importing.lines(at: now))
        XCTAssertEqual(PhoneImportWording.cardLines(copying: nil, state: idle, at: now), [], "An empty line is left out")
    }

    // MARK: - The Library's Button

    /// The phone's hint offers only what its sheet does.
    func testAddToLibraryButtonHint() {
        XCTAssertEqual(
            PhoneImportWording.addToLibraryButtonHint,
            "Opens options to open a book or import a folder."
        )
    }

    /// The sheet's last line names each feature the phone lacks and the Mac
    /// has, and says they are coming, so a person looking for them learns
    /// where they are (FR53).
    func testOnlyOnTheMacNote() {
        XCTAssertEqual(
            PhoneImportWording.onlyOnTheMacNote,
            "Feeds, recording, editing audio, and transcribing are only on the Mac for now."
        )
    }

    /// The phone's Add to Library sheet shows the note, after its two rows,
    /// in the footer of their section; read from the sheet's source, since
    /// the Mac's test host cannot draw an iPhone view (the order itself is
    /// `ScreenOrderUITests`'s, on GitHub).
    func testTheAddToLibrarySheetShowsTheNoteAfterItsRows() throws {
        let file = AppSourceFile.folder.appendingPathComponent("Platform/iOS/Views/Import/PhoneAddToLibrarySheet.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let importFolder = try XCTUnwrap(source.range(of: "row(for: .importFolder, mode: .folder)"))
        let footer = try XCTUnwrap(source.range(of: "} footer: {\n                    onlyOnTheMacNote"))
        XCTAssertLessThan(importFolder.lowerBound, footer.lowerBound)
        XCTAssertTrue(source.contains("Text(PhoneImportWording.onlyOnTheMacNote)"))
    }
}
