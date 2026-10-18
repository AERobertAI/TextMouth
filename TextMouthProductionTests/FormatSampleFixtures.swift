import XCTest
import ZIPFoundation
@testable import TextMouth

/// The format samples in `TestData/format-samples` (FMT01, FMT03, FMT04,
/// FMT07, and FMT13), which came partly from outside: `samples.tsv` gives
/// each one's source. They are untrusted input that every importer must
/// survive, so a test never imports a sample where it lies and never
/// changes the samples' folder: it imports a copy in a folder of its own.
extension XCTestCase {
    /// The sample at `relativePath` inside `TestData/format-samples`, such
    /// as "rtf/headings.rtf" or the folder "rtfd/headings.rtfd".
    /// - Throws: `TestError.fileNotFound` when the sample is missing.
    func formatSampleURL(_ relativePath: String) throws -> URL {
        try requireFile("format-samples/\(relativePath)")
    }

    /// A copy of the sample at `relativePath`, a file or a folder (an RTFD
    /// or a NIMAS package), named `name`, or the sample's own name when
    /// that is nil, in a new folder of this test's own that is removed when
    /// the test ends. A name lets a test give a sample another extension,
    /// as a WordML sample needs to import as an .xml file.
    func copyOfFormatSample(_ relativePath: String, named name: String? = nil) throws -> URL {
        let sample = try formatSampleURL(relativePath)
        let folder = try makeSandboxDirectory("FormatSample")
        let copy = folder.appendingPathComponent(name ?? sample.lastPathComponent)
        try FileManager.default.copyItem(at: sample, to: copy)
        return copy
    }

    /// The book `url` imports as, through the import path Open Book takes
    /// (`FileImportService.importFileWithReport`), with its package removed
    /// from the hosted tests' library when the test ends.
    func importedForTest(_ url: URL) throws -> ImportedBook {
        let imported = try FileImportService.importFileWithReport(from: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: imported.book.tmbDirectory) }
        return imported
    }

    /// What the reader shows for `book`, read from its package as the
    /// reader reads it (`BookContentAnalysisService.load`).
    func openedContent(of book: Book) throws -> DocumentContent {
        try BookContentAnalysisService.load(book: book).content
    }

    /// The headings of `content`, chapter by chapter, as "level: label"
    /// lines, such as "1: Harbour Notes", for one comparison that names
    /// every heading.
    func headingLines(of content: DocumentContent) -> [String] {
        content.chapters.flatMap { chapter in
            chapter.headings.map { "\($0.level): \($0.text)" }
        }
    }

    /// Every chapter's text of `content`, joined by blank lines, for a
    /// test that looks for words wherever they fall.
    func allText(of content: DocumentContent) -> String {
        content.chapters.map(\.text).joined(separator: "\n\n")
    }

    /// The document type the app's own Info.plist
    /// (`CFBundleDocumentTypes`) declares for files named with `fileExtension`
    /// (without its dot), or nil when none lists it. The app is the hosted
    /// tests' main bundle, so this is what the Finder and the Open With menu
    /// read. A test pins from it that the extension is offered in a Viewer
    /// role, which later format tasks reuse for their own extensions.
    func documentType(listing fileExtension: String) -> [String: Any]? {
        documentType(listing: fileExtension, inKey: "CFBundleTypeExtensions")
    }

    /// The document type the app's Info.plist declares for the content type
    /// `identifier` (a UTI, such as "org.idpf.epub-container"), or nil when
    /// none lists it, found the way `documentType(listing:)` finds an
    /// extension.
    func documentType(listingContentType identifier: String) -> [String: Any]? {
        documentType(listing: identifier, inKey: "LSItemContentTypes")
    }

    /// The first document type whose list under `key` holds `value`.
    private func documentType(listing value: String, inKey key: String) -> [String: Any]? {
        let types = Bundle.main.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
        return types.first { ($0[key] as? [String] ?? []).contains(value) }
    }
}

// MARK: - Making a Word or OpenDocument Sample Protected by a Password

/// Helpers that turn a copy of a sample into a document protected by a
/// password (FMT13), shared by the tests of the source check and of the
/// import. They change only the copy the test passes in.
extension XCTestCase {
    /// The offset of the File Information Block in the Word document at
    /// `url`, found by the code under test, failing the test when none is.
    func fibOffset(of url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(TextutilSourceCheck.fibOffset(in: data), "No File Information Block in \(url.lastPathComponent)")
    }

    /// The little-endian flags word of the block at `offset` in the file at `url`.
    func fibFlags(of url: URL, at offset: Int) throws -> UInt16 {
        let data = try Data(contentsOf: url)
        return UInt16(data[offset + 0x0A]) | UInt16(data[offset + 0x0B]) << 8
    }

    /// Writes `flags` as the flags word of the block at `offset` in the file at `url`.
    func setFibFlags(_ flags: UInt16, of url: URL, at offset: Int) throws {
        var data = try Data(contentsOf: url)
        data[offset + 0x0A] = UInt8(flags & 0xFF)
        data[offset + 0x0B] = UInt8(flags >> 8)
        try data.write(to: url)
    }

    /// Replaces `META-INF/manifest.xml` in the ZIP at `url` with `manifest`.
    func replaceManifest(in url: URL, with manifest: String) throws {
        let archive = try Archive(url: url, accessMode: .update)
        let old = try XCTUnwrap(archive["META-INF/manifest.xml"])
        try archive.remove(old)
        let data = Data(manifest.utf8)
        try archive.addEntry(
            with: "META-INF/manifest.xml",
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: .deflate,
            provider: { position, size in
                let start = Int(position)
                return data[start..<min(start + size, data.count)]
            }
        )
    }

    /// A manifest whose `content.xml` entry carries encryption data.
    var encryptedManifest: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.3">
        <manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.text"/>
        <manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml">\
        <manifest:encryption-data manifest:checksum-type="SHA1/1K" manifest:checksum="AAAA"/>\
        </manifest:file-entry>
        </manifest:manifest>
        """
    }
}
