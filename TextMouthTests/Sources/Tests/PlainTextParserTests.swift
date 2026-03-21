import Foundation

func runPlainTextParserTests() {
print("\n--- Plain Text Parser Tests (Pride and Prejudice) ---")

test("TXT file exists and loads") {
    let url = try requireFile("pride.txt")
    let text = try String(contentsOf: url, encoding: .utf8)
    try assertGreater(text.count, 1000, "Text should be substantial")
    print("    File size: \(text.count) characters")
}

test("TXT parse produces content") {
    let url = try requireFile("pride.txt")
    let text = try String(contentsOf: url, encoding: .utf8)
    let content = parsePlainText(text: text, title: "Pride and Prejudice")
    try assertEqual(content.title, "Pride and Prejudice")
    try assertGreater(content.chapters[0].text.count, 1000)
    print("    Text length: \(content.chapters[0].text.count) chars")
}

test("TXT heading detection finds chapter headers") {
    let url = try requireFile("pride.txt")
    let text = try String(contentsOf: url, encoding: .utf8)
    let content = parsePlainText(text: text, title: "Pride and Prejudice")
    let headings = content.allHeadings
    print("    Headings detected: \(headings.count)")
    for h in headings.prefix(10) {
        print("    H\(h.level): \"\(h.text)\" (offset:\(h.characterOffset))")
    }
}

test("TXT contains expected Pride and Prejudice content") {
    let url = try requireFile("pride.txt")
    let text = try String(contentsOf: url, encoding: .utf8)
    let lower = text.lowercased()
    try assertTrue(lower.contains("darcy"), "Should contain 'Darcy'")
    try assertTrue(lower.contains("elizabeth") || lower.contains("bennet"), "Should contain Elizabeth or Bennet")
}

} // end runPlainTextParserTests
