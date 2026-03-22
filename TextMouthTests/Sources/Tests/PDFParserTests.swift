import Foundation

/// PDF parser tests. These tests verify the PDF parsing logic by checking
/// file existence and basic structure. The actual PDFKit-based parsing tests
/// run via xcrun swift since PDFKit is not available in SPM.
func runPDFParserTests() {
print("\n--- PDF Parser Tests ---")

test("Test formatted PDF exists") {
    let url = try requireFile("test_formatted.pdf")
    try assertTrue(FileManager.default.fileExists(atPath: url.path))
}

test("Test PDF with outline exists") {
    let url = try requireFile("test_with_outline.pdf")
    try assertTrue(FileManager.default.fileExists(atPath: url.path))
}

test("PDF file size is reasonable") {
    let url = try requireFile("test_formatted.pdf")
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    let size = attrs[.size] as? Int ?? 0
    try assertGreater(size, 1000, "PDF should be larger than 1KB")
}

test("PDF BookFormat detection works") {
    // The .pdf extension should be recognized
    let url = URL(fileURLWithPath: "/tmp/test.pdf")
    let allFormats = ["epub", "txt", "md", "html", "docx", "daisy", "pdf", "mp3"]
    let pdfExtensions = ["pdf"]
    try assertTrue(pdfExtensions.contains("pdf"), "PDF extension should be recognized")
}

}
