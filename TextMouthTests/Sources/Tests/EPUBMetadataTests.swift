import Foundation
import ZIPFoundation

func runEPUBMetadataTests() {
print("\n--- EPUB Metadata Tests ---")

test("EPUB metadata extraction") {
    let url = try requireFile("alice.epub")
    let archive: Archive
    do {
        archive = try Archive(url: url, accessMode: .read)
    } catch {
        throw EPUBParserError.invalidArchive
    }
    let containerXML = try extractStringFromArchive(archive, path: "META-INF/container.xml")
    let opfPath = try parseContainerForOPFPath(containerXML)
    let opfXML = try extractStringFromArchive(archive, path: opfPath)

    // Parse the OPF for metadata fields
    let doc = try XMLDocument(xmlString: opfXML)
    let title = (try? doc.nodes(forXPath: "//*[local-name()='title']"))?.first?.stringValue ?? ""
    let author = (try? doc.nodes(forXPath: "//*[local-name()='creator']"))?.first?.stringValue ?? ""
    let language = (try? doc.nodes(forXPath: "//*[local-name()='language']"))?.first?.stringValue ?? ""
    let identifiers = (try? doc.nodes(forXPath: "//*[local-name()='identifier']")) ?? []
    let packageNodes = try doc.nodes(forXPath: "//*[local-name()='package']")
    let version = (packageNodes.first as? XMLElement)?.attribute(forName: "version")?.stringValue ?? ""

    try assertTrue(!title.isEmpty, "Should have title")
    try assertTrue(!author.isEmpty, "Should have author")
    try assertTrue(!language.isEmpty, "Should have language")
    try assertGreater(identifiers.count, 0, "Should have at least one identifier")
    try assertTrue(!version.isEmpty, "Should have EPUB version")

    print("    Title: \(title)")
    print("    Author: \(author)")
    print("    Language: \(language)")
    print("    Identifiers: \(identifiers.count)")
    print("    EPUB Version: \(version)")
    for id in identifiers {
        print("      - \(id.stringValue ?? "?")")
    }
}

test("EPUB publisher and date extraction (may be empty for Gutenberg)") {
    let url = try requireFile("alice.epub")
    let archive = try Archive(url: url, accessMode: .read)
    let containerXML = try extractStringFromArchive(archive, path: "META-INF/container.xml")
    let opfPath = try parseContainerForOPFPath(containerXML)
    let opfXML = try extractStringFromArchive(archive, path: opfPath)
    let doc = try XMLDocument(xmlString: opfXML)

    let publisher = (try? doc.nodes(forXPath: "//*[local-name()='publisher']"))?.first?.stringValue ?? "(none)"
    let date = (try? doc.nodes(forXPath: "//*[local-name()='date']"))?.first?.stringValue ?? "(none)"
    print("    Publisher: \(publisher)")
    print("    Date: \(date)")
    // These may be empty for Gutenberg books, that's OK
}

} // end runEPUBMetadataTests
