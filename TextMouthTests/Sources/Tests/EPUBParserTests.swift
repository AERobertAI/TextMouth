import Foundation
import ZIPFoundation

func runEPUBParserTests() {
print("\n--- EPUB Parser Tests (Alice in Wonderland) ---")

test("EPUB file exists") {
    let url = try requireFile("alice.epub")
    try assertTrue(FileManager.default.fileExists(atPath: url.path))
}

test("EPUB opens as ZIP archive") {
    let url = try requireFile("alice.epub")
    let archive = try Archive(url: url, accessMode: .read)
    var count = 0
    for _ in archive { count += 1 }
    try assertGreater(count, 0, "Should open as ZIP with entries")
}

test("EPUB has container.xml") {
    let url = try requireFile("alice.epub")
    let archive = try Archive(url: url, accessMode: .read)
    let xml = try extractStringFromArchive(archive, path: "META-INF/container.xml")
    try assertTrue(xml.contains("rootfile"), "Should contain rootfile element")
}

test("EPUB container.xml points to OPF") {
    let url = try requireFile("alice.epub")
    let archive = try Archive(url: url, accessMode: .read)
    let xml = try extractStringFromArchive(archive, path: "META-INF/container.xml")
    let opfPath = try parseContainerForOPFPath(xml)
    try assertTrue(!opfPath.isEmpty, "OPF path should not be empty")
    print("    OPF path: \(opfPath)")
}

test("EPUB OPF parses with title and author") {
    let url = try requireFile("alice.epub")
    let archive = try Archive(url: url, accessMode: .read)
    let containerXML = try extractStringFromArchive(archive, path: "META-INF/container.xml")
    let opfPath = try parseContainerForOPFPath(containerXML)
    let opfXML = try extractStringFromArchive(archive, path: opfPath)
    let opf = try parseOPF(opfXML)
    try assertTrue(!opf.title.isEmpty, "Title should not be empty")
    try assertTrue(!opf.author.isEmpty, "Author should not be empty")
    try assertGreater(opf.manifest.count, 0, "Manifest should have items")
    try assertGreater(opf.spineItemRefs.count, 0, "Spine should have items")
    print("    Title: \(opf.title)")
    print("    Author: \(opf.author)")
    print("    Manifest items: \(opf.manifest.count)")
    print("    Spine items: \(opf.spineItemRefs.count)")
}

test("EPUB full parse produces chapters with text") {
    let url = try requireFile("alice.epub")
    let content = try parseEPUB(url: url)
    try assertTrue(!content.title.isEmpty, "Title should not be empty")
    try assertGreater(content.chapters.count, 0, "Should have chapters")
    let totalText = content.chapters.map { $0.text.count }.reduce(0, +)
    try assertGreater(totalText, 1000, "Should have substantial text")
    print("    Title: \(content.title)")
    print("    Author: \(content.author)")
    print("    Chapters: \(content.chapters.count)")
    print("    Total characters: \(totalText)")
    // Print first 3 chapter titles
    for (i, ch) in content.chapters.prefix(5).enumerated() {
        print("    Chapter \(i+1): \"\(ch.title)\" (\(ch.text.count) chars, \(ch.headings.count) headings)")
    }
}

test("EPUB heading extraction finds headings") {
    let url = try requireFile("alice.epub")
    let content = try parseEPUB(url: url)
    let allHeadings = content.allHeadings
    try assertGreater(allHeadings.count, 0, "Should find headings")
    print("    Total headings found: \(allHeadings.count)")
    for h in allHeadings.prefix(8) {
        print("    H\(h.level): \"\(h.text)\" (ch:\(h.chapterIndex), offset:\(h.characterOffset))")
    }
}

test("EPUB chapter text contains expected content") {
    let url = try requireFile("alice.epub")
    let content = try parseEPUB(url: url)
    let allText = content.chapters.map { $0.text }.joined(separator: " ").lowercased()
    // Alice in Wonderland should contain these words
    try assertTrue(allText.contains("alice"), "Should contain 'alice'")
    try assertTrue(allText.contains("rabbit"), "Should contain 'rabbit'")
    try assertTrue(allText.contains("wonderland") || allText.contains("wonder"), "Should contain 'wonderland' or 'wonder'")
}

} // end runEPUBParserTests
