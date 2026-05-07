import Foundation
import SwiftSoup

func runHTMLToMarkdownTests() {
print("\n--- HTML to Markdown Converter Tests ---")

test("Basic paragraph conversion") {
    let html = "<p>Hello world</p>"
    let md = try convertHTMLToMarkdown(html)
    try assertTrue(md.contains("Hello world"), "Should contain paragraph text")
}

test("Heading conversion preserves levels") {
    let html = "<h1>Title</h1><h2>Subtitle</h2><h3>Section</h3>"
    let md = try convertHTMLToMarkdown(html)
    try assertTrue(md.contains("# Title"), "Should have h1 as #")
    try assertTrue(md.contains("## Subtitle"), "Should have h2 as ##")
    try assertTrue(md.contains("### Section"), "Should have h3 as ###")
}

test("Emphasis and strong conversion") {
    let html = "<p>This is <em>italic</em> and <strong>bold</strong> text.</p>"
    let md = try convertHTMLToMarkdown(html)
    try assertTrue(md.contains("*italic*"), "Should convert em to *")
    try assertTrue(md.contains("**bold**"), "Should convert strong to **")
}

test("Link conversion") {
    let html = "<p>Visit <a href=\"https://example.com\">Example</a> site.</p>"
    let md = try convertHTMLToMarkdown(html)
    try assertTrue(md.contains("[Example](https://example.com)"), "Should convert anchor to markdown link")
}

test("Unordered list conversion") {
    let html = "<ul><li>Item 1</li><li>Item 2</li><li>Item 3</li></ul>"
    let md = try convertHTMLToMarkdown(html)
    try assertTrue(md.contains("- Item 1"), "Should convert li to - prefix")
    try assertTrue(md.contains("- Item 2"), "Should contain second item")
    try assertTrue(md.contains("- Item 3"), "Should contain third item")
}

test("Ordered list conversion") {
    let html = "<ol><li>First</li><li>Second</li></ol>"
    let md = try convertHTMLToMarkdown(html)
    try assertTrue(md.contains("1. First"), "Should have numbered items")
    try assertTrue(md.contains("2. Second"), "Should have second numbered item")
}

test("Blockquote conversion") {
    let html = "<blockquote><p>A quoted passage</p></blockquote>"
    let md = try convertHTMLToMarkdown(html)
    try assertTrue(md.contains("> "), "Should prefix with >")
    try assertTrue(md.contains("A quoted passage"), "Should contain quote text")
}

test("Script and style removal") {
    let html = "<p>Visible</p><script>alert('hidden')</script><style>.foo{}</style><p>Also visible</p>"
    let md = try convertHTMLToMarkdown(html)
    try assertTrue(md.contains("Visible"), "Should keep visible text")
    try assertTrue(md.contains("Also visible"), "Should keep second visible text")
    try assertTrue(!md.contains("alert"), "Should remove script content")
    try assertTrue(!md.contains(".foo"), "Should remove style content")
}

test("Empty HTML produces empty output") {
    let md = try convertHTMLToMarkdown("<html><body></body></html>")
    try assertTrue(md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty HTML should produce empty markdown")
}

test("Nested emphasis and strong") {
    let html = "<p><strong><em>Both</em></strong></p>"
    let md = try convertHTMLToMarkdown(html)
    try assertTrue(md.contains("**") && md.contains("*"), "Should contain both emphasis markers")
    try assertTrue(md.contains("Both"), "Should preserve text")
}

test("Horizontal rule conversion") {
    let html = "<p>Before</p><hr><p>After</p>"
    let md = try convertHTMLToMarkdown(html)
    try assertTrue(md.contains("---"), "Should convert hr to ---")
}

test("Duplicate nav stripping removes EPUB TOC when body headings exist") {
    let html = """
    <html><body>
    <nav><ol>
    <li><a href="#ch1">Chapter 1</a></li>
    <li><a href="#ch2">Chapter 2</a></li>
    </ol></nav>
    <h1 id="ch1">Chapter 1</h1>
    <p>Actual chapter content.</p>
    </body></html>
    """
    let md = try convertHTMLToMarkdown(html, stripDuplicateNavigation: true)
    let count = md.components(separatedBy: "Chapter 1").count - 1
    try assertEqual(count, 1, "Chapter heading should appear once")
    try assertTrue(!md.contains("Chapter 2"), "Link-only nav entries should be stripped")
}

test("Duplicate nav stripping preserves nav-only headings") {
    let html = """
    <html><body>
    <nav><h1>Contents</h1></nav>
    <p>No heading exists outside nav.</p>
    </body></html>
    """
    let md = try convertHTMLToMarkdown(html, stripDuplicateNavigation: true)
    try assertTrue(md.contains("# Contents"), "Nav heading should be preserved when it is the only heading")
}

test("Frankenstein HTML converts to Markdown") {
    let url = try requireFile("frankenstein.html")
    let html = try String(contentsOf: url, encoding: .utf8)
    let md = try convertHTMLToMarkdown(html)
    try assertGreater(md.count, 1000, "Should produce substantial Markdown")
    // Verify some structure is preserved
    try assertTrue(md.contains("#"), "Should have at least one heading")
    print("    Input HTML: \(html.count) chars -> Output MD: \(md.count) chars")
}

} // end runHTMLToMarkdownTests

// MARK: - HTML to Markdown Converter (copied from app)

func convertHTMLToMarkdown(_ html: String, stripDuplicateNavigation: Bool = false) throws -> String {
    let doc = try SwiftSoup.parse(html)
    try doc.select("script, style").remove()
    let body = doc.body() ?? doc
    if stripDuplicateNavigation {
        try stripDuplicateNavigationFromHTML(body)
    }
    var result = ""
    convertHTMLNode(body, into: &result)
    result = result.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func stripDuplicateNavigationFromHTML(_ body: Element) throws {
    let allHeadingCount = try body.select("h1, h2, h3, h4, h5, h6").size()
    let navHeadingCount = try body.select("nav h1, nav h2, nav h3, nav h4, nav h5, nav h6").size()
    if allHeadingCount > navHeadingCount {
        try body.select("nav").remove()
    }
}

private func convertHTMLNode(_ node: Node, into result: inout String) {
    for child in node.getChildNodes() {
        if let textNode = child as? TextNode {
            let text = textNode.getWholeText()
            let collapsed = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            result += collapsed
        } else if let element = child as? Element {
            convertHTMLElement(element, into: &result)
        }
    }
}

private func convertHTMLElement(_ element: Element, into result: inout String) {
    let tag = element.tagName().lowercased()
    switch tag {
    case "h1", "h2", "h3", "h4", "h5", "h6":
        let level = Int(String(tag.last!)) ?? 1
        let prefix = String(repeating: "#", count: level)
        ensureHTMLBlankLine(&result)
        result += "\(prefix) "
        convertHTMLNode(element, into: &result)
        result += "\n\n"
    case "p":
        ensureHTMLBlankLine(&result)
        convertHTMLNode(element, into: &result)
        result += "\n\n"
    case "br":
        result += "  \n"
    case "em", "i":
        result += "*"
        convertHTMLNode(element, into: &result)
        result += "*"
    case "strong", "b":
        result += "**"
        convertHTMLNode(element, into: &result)
        result += "**"
    case "a":
        let href = (try? element.attr("href")) ?? ""
        result += "["
        convertHTMLNode(element, into: &result)
        result += "]"
        if !href.isEmpty { result += "(\(href))" }
    case "ul":
        ensureHTMLBlankLine(&result)
        let items = (try? element.select(":root > li")) ?? Elements()
        for item in items.array() {
            result += "- "
            var itemContent = ""
            convertHTMLNode(item, into: &itemContent)
            result += itemContent.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        }
        result += "\n"
    case "ol":
        ensureHTMLBlankLine(&result)
        let items = (try? element.select(":root > li")) ?? Elements()
        for (index, item) in items.array().enumerated() {
            result += "\(index + 1). "
            var itemContent = ""
            convertHTMLNode(item, into: &itemContent)
            result += itemContent.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        }
        result += "\n"
    case "blockquote":
        ensureHTMLBlankLine(&result)
        var inner = ""
        convertHTMLNode(element, into: &inner)
        let lines = inner.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        for line in lines { result += "> \(line)\n" }
        result += "\n"
    case "hr":
        ensureHTMLBlankLine(&result)
        result += "---\n\n"
    case "pre":
        ensureHTMLBlankLine(&result)
        result += "```\n"
        let text = (try? element.text()) ?? ""
        result += text
        if !text.hasSuffix("\n") { result += "\n" }
        result += "```\n\n"
    case "code":
        if element.parent()?.tagName().lowercased() == "pre" {
            convertHTMLNode(element, into: &result)
        } else {
            result += "`"
            convertHTMLNode(element, into: &result)
            result += "`"
        }
    default:
        convertHTMLNode(element, into: &result)
    }
}

private func ensureHTMLBlankLine(_ result: inout String) {
    if result.isEmpty { return }
    if !result.hasSuffix("\n\n") {
        if result.hasSuffix("\n") { result += "\n" } else { result += "\n\n" }
    }
}
