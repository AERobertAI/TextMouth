import XCTest
@testable import TextMouth

/// The iPhone app draws no fixed-size font (A11Y-GOTO).
///
/// A phone text field's Dynamic Type finding from Apple's audit is accepted
/// because the field's font grows (`Accepted.swiftUITextField`); that holds only
/// while no sheet gives a font a fixed size. This scan refuses, in every file
/// under `Platform/iOS/`, the two SwiftUI fonts that do not follow the text size:
/// `.system(size:` and `.custom(_:fixedSize:`. A text style (`.body`,
/// `.system(.title3, design: .monospaced)`) and `.custom(_:size:relativeTo:)`
/// scale and pass. Comments and string literals are not code and are skipped.
final class PhoneFontPolicyTests: XCTestCase {

    // MARK: - The Scan

    /// The patterns of a fixed-size font. `.system(size:` allows any space or line break after the bracket;
    /// `.custom(<name>, fixedSize:` takes the name as one expression with no comma.
    private static let fixedFontPatterns = [
        #"\.system\(\s*size\s*:"#,
        #"\.custom\(\s*[^,()]*(\([^()]*\))?[^,()]*,\s*fixedSize\s*:"#,
    ]

    /// `source` with every comment and every string literal made blank
    /// (spaces), its line breaks and length kept, so that a pattern read in it
    /// finds code only and reports the line it is on. Handles `//`, nested
    /// `/* */`, `"…"` with escapes, multi-line `"""…"""`, and raw `#"…"#`
    /// strings. A string's interpolation `\(…)` is code in Swift, but a font
    /// call inside one is not a font anyone draws, so it is blanked with it.
    static func codeOnly(_ source: String) -> String {
        let characters = Array(source)
        var output = characters
        var index = 0
        /// Blanks the characters from `start` up to (not including) `end`, keeping line breaks.
        func blank(_ start: Int, _ end: Int) {
            for position in start..<min(end, characters.count) where characters[position] != "\n" {
                output[position] = " "
            }
        }
        /// Whether the characters at `position` begin with `text`.
        func has(_ text: String, at position: Int) -> Bool {
            let wanted = Array(text)
            guard position + wanted.count <= characters.count else { return false }
            return Array(characters[position..<position + wanted.count]) == wanted
        }
        while index < characters.count {
            if has("//", at: index) {
                // A line comment runs to the end of its line.
                let start = index
                while index < characters.count && characters[index] != "\n" { index += 1 }
                blank(start, index)
            } else if has("/*", at: index) {
                // A block comment, which Swift lets nest.
                let start = index
                var depth = 0
                while index < characters.count {
                    if has("/*", at: index) { depth += 1; index += 2 }
                    else if has("*/", at: index) { depth -= 1; index += 2; if depth == 0 { break } }
                    else { index += 1 }
                }
                blank(start, index)
            } else if characters[index] == "\"" || (characters[index] == "#" && rawStringStart(characters, at: index) != nil) {
                // A string literal, plain, multi-line, or raw (`#"…"#`, with the same number of #s each end).
                let start = index
                let hashes = rawStringStart(characters, at: index) ?? 0
                index += hashes
                let multiline = has("\"\"\"", at: index)
                index += multiline ? 3 : 1
                let closing = String(repeating: "\"", count: multiline ? 3 : 1) + String(repeating: "#", count: hashes)
                while index < characters.count {
                    // A backslash (with the string's hashes) escapes the next character.
                    if characters[index] == "\\" && hashes == 0 { index += 2; continue }
                    if has(closing, at: index) { index += closing.count; break }
                    // A plain string ends at its line.
                    if !multiline && characters[index] == "\n" { break }
                    index += 1
                }
                blank(start, index)
            } else {
                index += 1
            }
        }
        return String(output)
    }

    /// The number of `#` before the quote that opens a raw string at `position`, or nil when no quote follows them.
    private static func rawStringStart(_ characters: [Character], at position: Int) -> Int? {
        var count = 0
        var next = position
        while next < characters.count && characters[next] == "#" { count += 1; next += 1 }
        return next < characters.count && characters[next] == "\"" ? count : nil
    }

    /// The numbered lines of `source`'s code that give a font a fixed size.
    static func fixedFontLines(in source: String) throws -> [Int] {
        let code = codeOnly(source)
        let whole = NSRange(code.startIndex..., in: code)
        var lines = Set<Int>()
        for pattern in fixedFontPatterns {
            for match in try NSRegularExpression(pattern: pattern).matches(in: code, range: whole) {
                guard let range = Range(match.range, in: code) else { continue }
                // The line number is one more than the line breaks before the match.
                lines.insert(code[code.startIndex..<range.lowerBound].filter { $0 == "\n" }.count + 1)
            }
        }
        return lines.sorted()
    }

    // MARK: - The Phone's Sources

    /// No file under `Platform/iOS/` gives a font a fixed size.
    func testThePhoneDrawsNoFixedSizeFont() throws {
        let files = try AppSourceFile.all().filter { $0.path.hasPrefix("Platform/iOS/") }
        // The phone's folder is big: a folder that moved finds none.
        XCTAssertGreaterThan(files.count, 30, "The iPhone's source folder moved")
        var found: [String] = []
        for file in files {
            for line in try Self.fixedFontLines(in: file.text) { found.append("\(file.path):\(line)") }
        }
        XCTAssertEqual(found, [], "A fixed-size font in the phone, which does not follow Dynamic Type: \(found.joined(separator: ", "))")
    }

    // MARK: - The Scanner Itself

    /// A sample with both kinds of fixed font, one on each of lines 2 and 5 (the second split over two lines), is
    /// found, and the text styles, `relativeTo`, comments, and strings around them are not.
    func testTheScannerFindsBothKindsOfFixedFontAndNothingElse() throws {
        let sample = """
        Text("a").font(.system(.title3, design: .monospaced))
        Text("b").font(.system(size: 14))
        Text("c").font(.custom("Menlo", size: 14, relativeTo: .body))
        // Text("d").font(.system(size: 20))
        Text("e").font(.custom("Menlo",
                               fixedSize: 14))
        /* a block
           Text("f").font(.system(size: 20)) */
        Text("g: .system(size: 9) and .custom(\\"X\\", fixedSize: 9)")
        let note = \"\"\"
            .system(size: 12)
            \"\"\"
        Text("h").font(.body)
        """
        XCTAssertEqual(try Self.fixedFontLines(in: sample), [2, 5])
    }

    /// Nested block comments and a raw string are skipped, and code after them is read.
    func testTheScannerSkipsNestedCommentsAndRawStrings() throws {
        let sample = """
        /* outer /* inner .system(size: 1) */ still comment .system(size: 2) */
        let raw = #"a "quoted" .system(size: 3)"#
        Text("x").font(.system(size: 4))
        """
        XCTAssertEqual(try Self.fixedFontLines(in: sample), [3])
    }
}
