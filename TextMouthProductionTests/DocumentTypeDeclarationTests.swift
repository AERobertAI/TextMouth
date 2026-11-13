import XCTest
import UniformTypeIdentifiers
@testable import TextMouth

/// The Finder offers TextMouth for a file only when the app's Info.plist
/// declares the file's type among its document types. These tests pin that
/// each text format TextMouth reads is declared, as a Viewer at rank
/// Alternate (TextMouth never claims to be the default app for them), and
/// that an RTFD, which is a folder the Finder shows as one file, is one book
/// in a folder or a ZIP of books.
final class DocumentTypeDeclarationTests: XCTestCase {
    /// One row of the document types the formats declare: the type's name,
    /// the extensions and the content types it lists, and whether it is a
    /// package.
    private struct Declaration {
        let name: String
        let extensions: [String]
        let contentTypes: [String]
        var isPackage = false
    }

    /// The document types the text formats added (FMT01, FMT03, FMT04, FMT07,
    /// FMT13, and FMT20) declare, in the order the Info.plist lists them.
    private let declarations = [
        Declaration(name: "Rich Text Document (RTF)", extensions: ["rtf"], contentTypes: ["public.rtf"]),
        Declaration(name: "Rich Text Document with Attachments (RTFD)", extensions: ["rtfd"],
                    contentTypes: ["com.apple.rtfd"], isPackage: true),
        Declaration(name: "Word 97-2003 Document (DOC)", extensions: ["doc", "dot"],
                    contentTypes: ["com.microsoft.word.doc", "com.microsoft.word.dot"]),
        Declaration(name: "OpenDocument Text (ODT)", extensions: ["odt", "ott"],
                    contentTypes: ["org.oasis-open.opendocument.text", "org.oasis-open.opendocument.text-template"]),
        Declaration(name: "XML Document (DTBook, Word 2003 XML, or PEF)", extensions: ["xml"],
                    contentTypes: ["public.xml"]),
        Declaration(name: "Web Archive", extensions: ["webarchive"], contentTypes: ["com.apple.webarchive"]),
        Declaration(name: "SSML Document", extensions: ["ssml"], contentTypes: ["org.w3.ssml"]),
        Declaration(name: "BRF Braille File", extensions: ["brf"], contentTypes: ["com.textmouth.brf"]),
        Declaration(name: "BRL Braille File", extensions: ["brl"], contentTypes: ["com.textmouth.brl"]),
        Declaration(name: "PEF Braille File", extensions: ["pef"], contentTypes: ["org.daisy.pef"]),
        // Kindle books (FMT42). The order of the rows does not matter: each is found by its extension.
        Declaration(name: "Kindle Book (MOBI)", extensions: ["mobi", "prc", "azw", "azw3"], contentTypes: ["com.textmouth.mobi"]),
        // Kindle KFX books (FMT52); a .kpf is listed so it can be refused with its own sentence.
        Declaration(name: "Kindle Book (KFX)", extensions: ["kfx", "kfx-zip", "azw8", "kpf"], contentTypes: ["com.textmouth.kfx"]),
        // Video files whose audio is the book (an audio-only .mp4, .m4v, or .mov is read as an audiobook). A Viewer at
        // rank Alternate puts TextMouth in Open With without ever making it the default app for a video.
        Declaration(name: "MP4 / QuickTime Video", extensions: ["mp4", "m4v", "mov"],
                    contentTypes: ["public.mpeg-4", "com.apple.m4v-video", "com.apple.quicktime-movie"])
    ]

    // MARK: - Document types

    /// Each declaration is a Viewer at rank Alternate that lists its
    /// extensions and its content types, and only an RTFD is a package.
    func testEachNewFormatIsOfferedAsAnAlternateViewer() throws {
        for declaration in declarations {
            for fileExtension in declaration.extensions {
                let type = try XCTUnwrap(
                    documentType(listing: fileExtension),
                    "No document type lists .\(fileExtension)"
                )
                XCTAssertEqual(type["CFBundleTypeName"] as? String, declaration.name, ".\(fileExtension)")
                XCTAssertEqual(type["CFBundleTypeRole"] as? String, "Viewer", declaration.name)
                XCTAssertEqual(type["LSHandlerRank"] as? String, "Alternate", declaration.name)
                XCTAssertEqual(
                    type["CFBundleTypeExtensions"] as? [String], declaration.extensions, declaration.name)
                XCTAssertEqual(
                    type["LSItemContentTypes"] as? [String], declaration.contentTypes, declaration.name)
                XCTAssertEqual(
                    type["LSTypeIsPackage"] as? Bool ?? false, declaration.isPackage, declaration.name)
            }
        }
    }

    /// Every extension of every format, the audio formats' (mp4, m4v, and
    /// mov among them) too, is listed by some document type, so a format
    /// added later without one fails here rather than going unnoticed in the
    /// Finder.
    func testEveryFormatsExtensionIsListedInSomeDocumentType() {
        for format in BookFormat.allCases {
            for fileExtension in format.fileExtensions {
                XCTAssertNotNil(
                    documentType(listing: fileExtension),
                    "No document type lists .\(fileExtension), a \(format.displayName) extension"
                )
            }
        }
    }

    // MARK: - SSML's type

    /// macOS declares no type for .ssml, so the app imports one: the
    /// identifier is known (not a dynamic type made up for the extension),
    /// conforms to XML, and is the type the extension gives.
    func testSSMLHasADeclaredTypeThatConformsToXML() throws {
        let type = try XCTUnwrap(UTType("org.w3.ssml"))
        XCTAssertTrue(type.isDeclared)
        XCTAssertFalse(type.isDynamic)
        XCTAssertTrue(type.conforms(to: .xml))
        XCTAssertEqual(type.preferredMIMEType, "application/ssml+xml")
        XCTAssertEqual(UTType(filenameExtension: "ssml"), type)
    }

    // MARK: - An RTFD in a folder or a ZIP

    /// A sandbox folder holding a copy of the RTFD sample (a package with its
    /// TXT.rtf and a picture), a copy of the RTF sample, and a stray file.
    private func makeFolderOfBooks() throws -> URL {
        let folder = try makeSandboxDirectory("RTFDFolder")
        let fileManager = FileManager.default
        try fileManager.copyItem(
            at: try formatSampleURL("rtfd/with-image.rtfd"),
            to: folder.appendingPathComponent("with-image.rtfd"))
        try fileManager.copyItem(
            at: try formatSampleURL("rtf/headings.rtf"),
            to: folder.appendingPathComponent("headings.rtf"))
        try Data("not a book".utf8).write(to: folder.appendingPathComponent("notes.dat"))
        return folder
    }

    /// An RTFD in a folder is one book, listed as the package itself, and so
    /// is the RTF beside it. The files inside the package are neither books
    /// nor counted among the files passed over: only the stray file is.
    func testAnRTFDInAFolderIsOneBookAndItsFilesAreNotCounted() throws {
        let folder = try makeFolderOfBooks()
        let unpacking = NestedArchiveUnpacking(
            directory: try makeSandboxDirectory("RTFDNested"),
            budget: ArchiveBudget(),
            depth: 1,
            isCancelled: { false },
            progress: nil
        )

        let found = try FileImportService.importCandidates(in: folder, unpacking: unpacking)

        XCTAssertEqual(found.books.map(\.lastPathComponent), ["headings.rtf", "with-image.rtfd"])
        XCTAssertEqual(found.nonBookFiles.countsByExtension, ["dat": 1])
        XCTAssertTrue(found.failures.isEmpty)
    }

    /// A ZIP of the same folder imports as two books, an RTFD and an RTF,
    /// and no book is made of the package's TXT.rtf.
    func testAZIPWithAnRTFDImportsItAsOneBook() throws {
        let folder = try makeFolderOfBooks()
        let package = folder.appendingPathComponent("with-image.rtfd")
        // The archive holds the package's folder and both of its files, the
        // way the Finder's Compress would make it.
        let entries: [TestZIPEntry] = [
            .folder("Books/"),
            .folder("Books/with-image.rtfd/"),
            TestZIPEntry("Books/with-image.rtfd/TXT.rtf",
                         try Data(contentsOf: package.appendingPathComponent("TXT.rtf"))),
            TestZIPEntry("Books/with-image.rtfd/Attachment.png",
                         try Data(contentsOf: package.appendingPathComponent("Attachment.png"))),
            TestZIPEntry("Books/headings.rtf",
                         try Data(contentsOf: folder.appendingPathComponent("headings.rtf"))),
            TestZIPEntry("Books/notes.dat", Data("not a book".utf8))
        ]
        let archive = try makeTemporaryZip(prefix: "RTFDArchive", orderedEntries: entries)
        addTeardownBlock { try? FileManager.default.removeItem(at: archive) }

        let result = try FileImportService.importZip(from: archive)
        for book in result.books {
            addTeardownBlock { try? FileManager.default.removeItem(at: book.tmbDirectory) }
        }

        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        XCTAssertEqual(result.books.map(\.format).sorted { $0.rawValue < $1.rawValue }, [.rtf, .rtfd])
        XCTAssertEqual(result.books.count, 2, "TXT.rtf must not become a book of its own")
        XCTAssertEqual(result.nonBookFiles.countsByExtension, ["dat": 1])
    }
}
