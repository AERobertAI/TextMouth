#!/usr/bin/env xcrun swift
/// PDF Integration Tests — runs via `xcrun swift` since PDFKit requires Apple frameworks.
/// These tests verify the actual PDF parsing pipeline end-to-end.
///
/// Run with: xcrun swift TextMouthTests/PDFIntegrationTests.swift

import Foundation
import PDFKit
import Vision
import AppKit

// MARK: - Test Framework

var totalTests = 0
var passedTests = 0
var failedTests = 0

func test(_ name: String, _ block: () throws -> Void) {
    totalTests += 1
    do {
        try block()
        passedTests += 1
        print("  PASS: \(name)")
    } catch {
        failedTests += 1
        print("  FAIL: \(name) -- \(error)")
    }
}

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String = "") throws {
    guard a == b else {
        throw NSError(domain: "test", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Expected \(a) == \(b) \(msg)"])
    }
}

func assertTrue(_ condition: Bool, _ msg: String = "") throws {
    guard condition else {
        throw NSError(domain: "test", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Expected true \(msg)"])
    }
}

func assertGreater(_ a: Int, _ b: Int, _ msg: String = "") throws {
    guard a > b else {
        throw NSError(domain: "test", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Expected \(a) > \(b) \(msg)"])
    }
}

// MARK: - Test Data

let testDataDir: String = {
    let cwd = FileManager.default.currentDirectoryPath
    for candidate in ["\(cwd)/TestData", "\(cwd)/../TestData"] {
        let resolved = (candidate as NSString).standardizingPath
        if FileManager.default.fileExists(atPath: "\(resolved)/test_formatted.pdf") {
            return resolved
        }
    }
    return "/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TestData"
}()

// MARK: - Tests

print("=" + String(repeating: "=", count: 59))
print("PDF Integration Tests (PDFKit + Vision)")
print("=" + String(repeating: "=", count: 59))
print("Test data: \(testDataDir)\n")

// --- Basic Loading ---

print("--- Basic PDF Loading ---")

test("Load formatted test PDF") {
    let url = URL(fileURLWithPath: "\(testDataDir)/test_formatted.pdf")
    let doc = PDFDocument(url: url)
    try assertTrue(doc != nil, "Should open PDF")
    try assertEqual(doc!.pageCount, 3, "Should have 3 pages")
}

test("Load PDF with outline") {
    let url = URL(fileURLWithPath: "\(testDataDir)/test_with_outline.pdf")
    let doc = PDFDocument(url: url)
    try assertTrue(doc != nil, "Should open PDF")
}

test("Load Einstein PDF (154 pages) — optional") {
    let path = "\(testDataDir)/relativity-einstein.pdf"
    guard FileManager.default.fileExists(atPath: path) else {
        print("    (skipped — file not present)")
        return
    }
    let doc = PDFDocument(url: URL(fileURLWithPath: path))
    try assertTrue(doc != nil, "Should open PDF")
    try assertEqual(doc!.pageCount, 154)
}

// --- Text Extraction ---

print("\n--- Text Extraction ---")

test("Extract text from formatted PDF") {
    let url = URL(fileURLWithPath: "\(testDataDir)/test_formatted.pdf")
    guard let doc = PDFDocument(url: url) else { throw NSError(domain: "", code: 0) }
    var text = ""
    for i in 0..<doc.pageCount {
        text += doc.page(at: i)?.string ?? ""
    }
    try assertTrue(text.contains("Spring"), "Should contain 'Spring'")
    try assertTrue(text.contains("Summer"), "Should contain 'Summer'")
    try assertTrue(text.contains("Autumn"), "Should contain 'Autumn'")
    try assertTrue(text.contains("equinox"), "Should contain 'equinox'")
}

test("Extract text from Einstein PDF — optional") {
    let path = "\(testDataDir)/relativity-einstein.pdf"
    guard FileManager.default.fileExists(atPath: path) else {
        print("    (skipped — file not present)")
        return
    }
    guard let doc = PDFDocument(url: URL(fileURLWithPath: path)), let page = doc.page(at: 0) else {
        throw NSError(domain: "", code: 0)
    }
    let text = page.string ?? ""
    try assertGreater(text.count, 100, "First page should have substantial text")
}

// --- Font Analysis ---

print("\n--- Font Analysis ---")

test("Detect multiple font sizes") {
    let url = URL(fileURLWithPath: "\(testDataDir)/test_formatted.pdf")
    guard let doc = PDFDocument(url: url), let page = doc.page(at: 0),
          let attrStr = page.attributedString else {
        throw NSError(domain: "", code: 0)
    }
    var sizes: Set<CGFloat> = []
    let range = NSRange(location: 0, length: attrStr.length)
    attrStr.enumerateAttribute(.font, in: range, options: []) { val, _, _ in
        if let font = val as? NSFont {
            sizes.insert((font.pointSize * 2).rounded() / 2)
        }
    }
    try assertGreater(sizes.count, 1, "Should detect multiple font sizes")
    try assertTrue(sizes.contains(24.0) || sizes.contains(23.5) || sizes.contains(24.5),
                   "Should detect heading font size (~24pt)")
}

test("Identify body font size as most common") {
    let url = URL(fileURLWithPath: "\(testDataDir)/test_formatted.pdf")
    guard let doc = PDFDocument(url: url), let page = doc.page(at: 0),
          let attrStr = page.attributedString else {
        throw NSError(domain: "", code: 0)
    }
    var sizeCounts: [CGFloat: Int] = [:]
    let range = NSRange(location: 0, length: attrStr.length)
    attrStr.enumerateAttribute(.font, in: range, options: []) { val, r, _ in
        if let font = val as? NSFont {
            let rounded = (font.pointSize * 2).rounded() / 2
            sizeCounts[rounded, default: 0] += r.length
        }
    }
    let bodySize = sizeCounts.max(by: { $0.value < $1.value })?.key ?? 0
    try assertTrue(bodySize >= 10 && bodySize <= 12, "Body size should be ~11pt, got \(bodySize)")
}

test("Detect bold traits in font descriptor") {
    let url = URL(fileURLWithPath: "\(testDataDir)/test_formatted.pdf")
    guard let doc = PDFDocument(url: url), let page = doc.page(at: 0),
          let attrStr = page.attributedString else {
        throw NSError(domain: "", code: 0)
    }
    var foundBold = false
    let range = NSRange(location: 0, length: attrStr.length)
    attrStr.enumerateAttribute(.font, in: range, options: []) { val, _, _ in
        if let font = val as? NSFont,
           font.fontDescriptor.symbolicTraits.contains(.bold) {
            foundBold = true
        }
    }
    try assertTrue(foundBold, "Should detect bold text in formatted PDF")
}

// --- Outline / Table of Contents ---

print("\n--- Outline / Table of Contents ---")

test("PDF with outline has outlineRoot") {
    let url = URL(fileURLWithPath: "\(testDataDir)/test_with_outline.pdf")
    guard let doc = PDFDocument(url: url) else { throw NSError(domain: "", code: 0) }
    try assertTrue(doc.outlineRoot != nil, "Should have outline root")
}

test("Outline has correct number of top-level entries") {
    let url = URL(fileURLWithPath: "\(testDataDir)/test_with_outline.pdf")
    guard let doc = PDFDocument(url: url), let root = doc.outlineRoot else {
        throw NSError(domain: "", code: 0)
    }
    try assertGreater(root.numberOfChildren, 0, "Should have outline entries")
}

test("Outline entries have labels") {
    let url = URL(fileURLWithPath: "\(testDataDir)/test_with_outline.pdf")
    guard let doc = PDFDocument(url: url), let root = doc.outlineRoot,
          root.numberOfChildren > 0, let first = root.child(at: 0) else {
        throw NSError(domain: "", code: 0)
    }
    try assertTrue(first.label != nil && !(first.label!.isEmpty), "Should have a label")
}

test("Outline entries have page destinations") {
    let url = URL(fileURLWithPath: "\(testDataDir)/test_with_outline.pdf")
    guard let doc = PDFDocument(url: url), let root = doc.outlineRoot,
          root.numberOfChildren > 0, let first = root.child(at: 0) else {
        throw NSError(domain: "", code: 0)
    }
    try assertTrue(first.destination?.page != nil, "Should have page destination")
}

test("Outline contains chapter names") {
    let url = URL(fileURLWithPath: "\(testDataDir)/test_with_outline.pdf")
    guard let doc = PDFDocument(url: url), let root = doc.outlineRoot else {
        throw NSError(domain: "", code: 0)
    }
    var labels: [String] = []
    for i in 0..<root.numberOfChildren {
        if let label = root.child(at: i)?.label { labels.append(label) }
    }
    let allLabels = labels.joined(separator: ", ")
    try assertTrue(allLabels.contains("Spring"), "Should contain 'Spring' in outline")
    try assertTrue(allLabels.contains("Summer"), "Should contain 'Summer' in outline")
}

test("Einstein PDF has outline — optional") {
    let path = "\(testDataDir)/relativity-einstein.pdf"
    guard FileManager.default.fileExists(atPath: path) else {
        print("    (skipped — file not present)")
        return
    }
    guard let doc = PDFDocument(url: URL(fileURLWithPath: path)), let root = doc.outlineRoot else {
        throw NSError(domain: "", code: 0)
    }
    try assertGreater(root.numberOfChildren, 0, "Einstein should have outline entries")
}

// --- Metadata ---

print("\n--- Metadata ---")

test("Extract title from PDF attributes") {
    let url = URL(fileURLWithPath: "\(testDataDir)/test_with_outline.pdf")
    guard let doc = PDFDocument(url: url) else { throw NSError(domain: "", code: 0) }
    let title = doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String ?? ""
    try assertTrue(title.contains("Seasonal Almanac"), "Title should contain 'Seasonal Almanac'")
}

test("Extract author from PDF attributes") {
    let url = URL(fileURLWithPath: "\(testDataDir)/test_with_outline.pdf")
    guard let doc = PDFDocument(url: url) else { throw NSError(domain: "", code: 0) }
    let author = doc.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String ?? ""
    try assertTrue(author.contains("Dorothy Whitfield"), "Author should contain 'Dorothy Whitfield'")
}

// --- Scanned Page Detection ---

print("\n--- Scanned Page Detection ---")

test("Detect empty pages in scanned PDF — optional") {
    let path = "\(testDataDir)/scanned-github.pdf"
    guard FileManager.default.fileExists(atPath: path) else {
        print("    (skipped — file not present)")
        return
    }
    guard let doc = PDFDocument(url: URL(fileURLWithPath: path)), let page = doc.page(at: 0) else {
        throw NSError(domain: "", code: 0)
    }
    let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    try assertTrue(text.count < 10, "Scanned page should have little/no embedded text")
}

test("Text PDF pages have embedded text") {
    let url = URL(fileURLWithPath: "\(testDataDir)/test_formatted.pdf")
    guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else {
        throw NSError(domain: "", code: 0)
    }
    let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    try assertGreater(text.count, 50, "Text PDF page should have embedded text")
}

// --- OCR ---

print("\n--- OCR (Vision Framework) ---")

test("OCR extracts text from scanned page — optional") {
    let path = "\(testDataDir)/scanned-github.pdf"
    guard FileManager.default.fileExists(atPath: path) else {
        print("    (skipped — file not present)")
        return
    }
    guard let doc = PDFDocument(url: URL(fileURLWithPath: path)), let page = doc.page(at: 0) else {
        throw NSError(domain: "", code: 0)
    }

    // Render to CGImage
    let pageRect = page.bounds(for: .mediaBox)
    let scale: CGFloat = 2.0
    let w = Int(pageRect.width * scale)
    let h = Int(pageRect.height * scale)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: w, height: h,
                              bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "", code: 0)
    }
    ctx.setFillColor(CGColor.white)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.scaleBy(x: scale, y: scale)
    page.draw(with: .mediaBox, to: ctx)
    guard let cgImage = ctx.makeImage() else { throw NSError(domain: "", code: 0) }

    // Run OCR
    let sem = DispatchSemaphore(value: 0)
    var ocrText = ""
    let req = VNRecognizeTextRequest { req, _ in
        defer { sem.signal() }
        guard let obs = req.results as? [VNRecognizedTextObservation] else { return }
        ocrText = obs.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = true
    try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([req])
    sem.wait()

    try assertGreater(ocrText.count, 50, "OCR should extract substantial text")
}

// --- Summary ---

print("\n" + String(repeating: "=", count: 60))
print("RESULTS: \(passedTests)/\(totalTests) passed, \(failedTests) failed")
print(String(repeating: "=", count: 60))

if failedTests > 0 { exit(1) }
