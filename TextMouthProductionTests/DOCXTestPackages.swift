import XCTest
@testable import TextMouth

// MARK: - Small Word Documents Built in the Tests

/// Builders for the small `.docx` packages the DOCX reader's tests read:
/// a package holding a text part, and optionally styles, footnotes, and
/// endnotes, each written from the XML a test gives. Every package is made in
/// a folder of its own that the test removes.
extension XCTestCase {

    /// The namespaces a Word text part declares, which the small documents
    /// below use: the document's own, relationships, markup compatibility,
    /// word processing shapes, symbol extensions (typed emoji), and the VML that
    /// older Word writes.
    static let docxNamespaces = """
        xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" \
        xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape" \
        xmlns:w16se="http://schemas.microsoft.com/office/word/2015/wordml/symex" \
        xmlns:v="urn:schemas-microsoft-com:vml"
        """

    /// The XML of a text part whose body is `body`.
    func docxDocumentXML(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document \(Self.docxNamespaces)><w:body>\(body)</w:body></w:document>
        """
    }

    /// The XML of a notes part: `root` is `footnotes` or `endnotes` and
    /// `entries` its `w:footnote` or `w:endnote` elements.
    func docxNotesXML(root: String, _ entries: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:\(root) \(Self.docxNamespaces)>\(entries)</w:\(root)>
        """
    }

    /// A run holding `text`, with `properties` as its run properties.
    func docxRun(_ text: String, _ properties: String = "") -> String {
        let rPr = properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>"
        return "<w:r>\(rPr)<w:t xml:space=\"preserve\">\(text)</w:t></w:r>"
    }

    /// A paragraph of `runs`, in paragraph style `style` when given, with
    /// `markProperties` as the run properties of its paragraph mark.
    func docxParagraph(_ runs: String, style: String? = nil, markProperties: String = "") -> String {
        var properties = ""
        if let style { properties += "<w:pStyle w:val=\"\(style)\"/>" }
        if !markProperties.isEmpty { properties += "<w:rPr>\(markProperties)</w:rPr>" }
        let pPr = properties.isEmpty ? "" : "<w:pPr>\(properties)</w:pPr>"
        return "<w:p>\(pPr)\(runs)</w:p>"
    }

    /// A note of the notes part with `text`, as Word writes one: a run for
    /// the note's own number, then the words. `kind` is `footnote` or
    /// `endnote`; `type` is the entry's `w:type` when it has one.
    func docxNote(_ kind: String, id: Int, text: String, type: String? = nil, paragraphStyle: String? = nil) -> String {
        let typeAttribute = type.map { " w:type=\"\($0)\"" } ?? ""
        let mark = "<w:r><w:rPr><w:rStyle w:val=\"NoteReference\"/></w:rPr><w:\(kind)Ref/></w:r>"
        let paragraph = docxParagraph(mark + docxRun(" " + text), style: paragraphStyle)
        return "<w:\(kind) w:id=\"\(id)\"\(typeAttribute)>\(paragraph)</w:\(kind)>"
    }

    /// The package at a new `.docx` file holding the given parts, in a
    /// folder the test removes. `document` is required; the others are left
    /// out of the package when nil. `otherParts` are further parts by path.
    func makeDOCXPackage(
        document: String,
        styles: String? = nil,
        numbering: String? = nil,
        footnotes: String? = nil,
        endnotes: String? = nil,
        otherParts: [String: String] = [:]
    ) throws -> URL {
        var parts: [String: Data] = [DOCXParser.Part.document: Data(document.utf8)]
        if let styles { parts[DOCXParser.Part.styles] = Data(styles.utf8) }
        if let numbering { parts[DOCXParser.Part.numbering] = Data(numbering.utf8) }
        if let footnotes { parts[DOCXParser.Part.footnotes] = Data(footnotes.utf8) }
        if let endnotes { parts[DOCXParser.Part.endnotes] = Data(endnotes.utf8) }
        for (path, text) in otherParts { parts[path] = Data(text.utf8) }
        let zip = try makeTemporaryZip(prefix: "TextMouthDOCXPackage", entries: parts)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextMouthDOCXPackage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let docx = directory.appendingPathComponent("Small Document.docx")
        try FileManager.default.moveItem(at: zip, to: docx)
        return docx
    }

    /// The Markdown the reader makes of a package with the given parts.
    func docxMarkdown(
        body: String,
        styles: String? = nil,
        numbering: String? = nil,
        footnotes: String? = nil,
        endnotes: String? = nil,
        includesPages: Bool = false
    ) throws -> String {
        let docx = try makeDOCXPackage(
            document: docxDocumentXML(body), styles: styles, numbering: numbering,
            footnotes: footnotes, endnotes: endnotes
        )
        return try DOCXParser.extractMarkdown(from: docx, includesPages: includesPages)
    }

    /// What a listener hears of the package with the given parts: the reading
    /// text the app's Markdown parser makes of the Markdown, with no marks of
    /// emphasis, comments, or list numbers. The tests that ask whether a mark
    /// would be spoken ask this, not the Markdown string.
    func docxReadingText(
        body: String,
        styles: String? = nil,
        numbering: String? = nil,
        footnotes: String? = nil,
        endnotes: String? = nil
    ) throws -> String {
        let markdown = try docxMarkdown(
            body: body, styles: styles, numbering: numbering, footnotes: footnotes, endnotes: endnotes
        )
        return try MarkdownDocParser.parseChapter(markdown: markdown).text
    }

    /// The labels of the pages the Markdown `markdown` marks.
    func pageLabels(of markdown: String) throws -> [String] {
        try MarkdownDocParser.parseChapter(markdown: markdown, includeNavigationHeadings: true).pages.map(\.label)
    }

    /// `markdown` with each run of blank lines made one: an empty paragraph
    /// writes a blank line of its own, which says nothing about what is read.
    func compact(_ markdown: String) -> String {
        markdown.replacingOccurrences(of: "\n{2,}", with: "\n\n", options: .regularExpression)
    }

    /// How many times `needle` is in `text`.
    func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }
}
