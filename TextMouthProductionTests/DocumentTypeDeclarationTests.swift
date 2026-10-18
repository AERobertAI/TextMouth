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
    /// and FMT13) declare, in the order the Info.plist lists them.
    private let declarations = [
        Declaration(name: "Rich Text Document (RTF)", extensions: ["rtf"], contentTypes: ["public.rtf"]),
        Declaration(name: "Rich Text Document with Attachments (RTFD)", extensions: ["rtfd"],
                    contentTypes: ["com.apple.rtfd"], isPackage: true),
        Declaration(name: "Word 97-2003 Document (DOC)", extensions: ["doc", "dot"],
                    contentTypes: ["com.microsoft.word.doc", "com.microsoft.word.dot"]),
        Declaration(name: "OpenDocument Text (ODT)", extensions: ["odt", "ott"],
                    contentTypes: ["org.oasis-open.opendocument.text", "org.oasis-open.opendocument.text-template"]),
        Declaration(name: "XML Document (DTBook or Word 2003 XML)", extensions: ["xml"],
                    contentTypes: ["public.xml"]),
        Declaration(name: "Web Archive", extensions: ["webarchive"], contentTypes: ["com.apple.webarchive"]),
        Declaration(name: "SSML Document", extensions: ["ssml"], contentTypes: ["org.w3.ssml"])
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

    /// Every extension of every format (the audio formats' are team
    /// audiofmt's to keep) is listed by some document type, so a format added
    /// later without one fails here rather than going unnoticed in the Finder.
    func testEveryFormatsExtensionIsListedInSomeDocumentType() {
        for format in BookFormat.allCases where format != .audio {
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
}
