import Foundation

struct SubstitutionRule: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var pattern: String
    var replacement: String
    var isRegex: Bool
    var isEnabled: Bool
    var caseSensitive: Bool

    init(
        id: UUID = UUID(),
        name: String = "",
        pattern: String,
        replacement: String = "",
        isRegex: Bool = false,
        isEnabled: Bool = true,
        caseSensitive: Bool = false
    ) {
        self.id = id; self.name = name; self.pattern = pattern
        self.replacement = replacement; self.isRegex = isRegex
        self.isEnabled = isEnabled; self.caseSensitive = caseSensitive
    }
}

/// Apply substitution rules to text (mirrors TextSubstitutionService.transform logic)
func applyRules(_ rules: [SubstitutionRule], to text: String) -> String {
    var current = text
    for rule in rules where rule.isEnabled && !rule.pattern.isEmpty {
        if rule.isRegex {
            var options: NSRegularExpression.Options = []
            if !rule.caseSensitive { options.insert(.caseInsensitive) }
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: options) else { continue }
            let nsText = current as NSString
            let matches = regex.matches(in: current, range: NSRange(location: 0, length: nsText.length))
            var result = current
            for match in matches.reversed() {
                let expanded = regex.replacementString(for: match, in: current, offset: 0, template: rule.replacement)
                let startIdx = result.index(result.startIndex, offsetBy: match.range.location)
                let endIdx = result.index(startIdx, offsetBy: match.range.length)
                result.replaceSubrange(startIdx..<endIdx, with: expanded)
            }
            current = result
        } else {
            let searchText = rule.caseSensitive ? current : current.lowercased()
            let searchPattern = rule.caseSensitive ? rule.pattern : rule.pattern.lowercased()
            var result = ""
            var searchStart = searchText.startIndex
            var origStart = current.startIndex
            while let range = searchText.range(of: searchPattern, range: searchStart..<searchText.endIndex) {
                let origRange = Range(uncheckedBounds: (
                    current.index(current.startIndex, offsetBy: searchText.distance(from: searchText.startIndex, to: range.lowerBound)),
                    current.index(current.startIndex, offsetBy: searchText.distance(from: searchText.startIndex, to: range.upperBound))
                ))
                result += current[origStart..<origRange.lowerBound]
                result += rule.replacement
                origStart = origRange.upperBound
                searchStart = range.upperBound
            }
            result += current[origStart...]
            current = result
        }
    }
    return current
}

/// Simplified offset mapping for testing
struct TestOffsetMap {
    var points: [(modifiedPos: Int, cumulativeDelta: Int)] = []

    func toOriginal(_ modified: Int) -> Int {
        var delta = 0
        for point in points {
            if point.modifiedPos <= modified { delta = point.cumulativeDelta } else { break }
        }
        return modified + delta
    }

    func toModified(_ original: Int) -> Int {
        var delta = 0
        for point in points {
            let origAtPoint = point.modifiedPos + point.cumulativeDelta
            if origAtPoint <= original { delta = point.cumulativeDelta } else { break }
        }
        return max(0, original - delta)
    }
}

func runTextSubstitutionTests() {
print("\n--- Text Substitution: Rule Model ---")

test("SubstitutionRule: JSON round-trip") {
    let rule = SubstitutionRule(name: "Test", pattern: "foo", replacement: "bar", isRegex: false, isEnabled: true, caseSensitive: false)
    let data = try JSONEncoder().encode(rule)
    let decoded = try JSONDecoder().decode(SubstitutionRule.self, from: data)
    try assertEqual(decoded.name, "Test")
    try assertEqual(decoded.pattern, "foo")
    try assertEqual(decoded.replacement, "bar")
    try assertEqual(decoded.isRegex, false)
    try assertEqual(decoded.isEnabled, true)
    try assertEqual(decoded.caseSensitive, false)
}

test("SubstitutionRule: regex rule encodes correctly") {
    let rule = SubstitutionRule(name: "URLs", pattern: "https?://\\S+", replacement: "link", isRegex: true, caseSensitive: true)
    let data = try JSONEncoder().encode(rule)
    let decoded = try JSONDecoder().decode(SubstitutionRule.self, from: data)
    try assertEqual(decoded.isRegex, true)
    try assertEqual(decoded.caseSensitive, true)
    try assertEqual(decoded.pattern, "https?://\\S+")
}

test("SubstitutionRule: array of rules round-trips") {
    let rules = [
        SubstitutionRule(name: "A", pattern: "a", replacement: "b"),
        SubstitutionRule(name: "B", pattern: "\\d+", replacement: "", isRegex: true),
    ]
    let data = try JSONEncoder().encode(rules)
    let decoded = try JSONDecoder().decode([SubstitutionRule].self, from: data)
    try assertEqual(decoded.count, 2)
    try assertEqual(decoded[0].name, "A")
    try assertEqual(decoded[1].isRegex, true)
}

// --- Plain text substitution ---
print("\n--- Text Substitution: Plain Text Replacements ---")

test("Plain replace: simple word replacement") {
    let rules = [SubstitutionRule(pattern: "hello", replacement: "hi")]
    try assertEqual(applyRules(rules, to: "hello world"), "hi world")
}

test("Plain replace: multiple occurrences") {
    let rules = [SubstitutionRule(pattern: "cat", replacement: "dog")]
    try assertEqual(applyRules(rules, to: "the cat sat on the cat"), "the dog sat on the dog")
}

test("Plain replace: case insensitive by default") {
    let rules = [SubstitutionRule(pattern: "HELLO", replacement: "hi", caseSensitive: false)]
    try assertEqual(applyRules(rules, to: "Hello World"), "hi World")
}

test("Plain replace: case sensitive when set") {
    let rules = [SubstitutionRule(pattern: "Hello", replacement: "Hi", caseSensitive: true)]
    let result = applyRules(rules, to: "Hello hello HELLO")
    try assertEqual(result, "Hi hello HELLO")
}

test("Plain replace: empty replacement skips/deletes match") {
    let rules = [SubstitutionRule(pattern: "secret", replacement: "")]
    try assertEqual(applyRules(rules, to: "this is secret stuff"), "this is  stuff")
}

test("Plain replace: no match leaves text unchanged") {
    let rules = [SubstitutionRule(pattern: "xyz", replacement: "abc")]
    try assertEqual(applyRules(rules, to: "hello world"), "hello world")
}

test("Plain replace: disabled rule is skipped") {
    let rules = [SubstitutionRule(pattern: "hello", replacement: "hi", isEnabled: false)]
    try assertEqual(applyRules(rules, to: "hello world"), "hello world")
}

test("Plain replace: empty pattern is skipped") {
    let rules = [SubstitutionRule(pattern: "", replacement: "oops")]
    try assertEqual(applyRules(rules, to: "hello"), "hello")
}

// --- Regex substitution ---
print("\n--- Text Substitution: Regex Replacements ---")

test("Regex replace: simple pattern") {
    let rules = [SubstitutionRule(pattern: "\\d+", replacement: "NUM", isRegex: true)]
    try assertEqual(applyRules(rules, to: "I have 42 cats and 7 dogs"), "I have NUM cats and NUM dogs")
}

test("Regex replace: group references") {
    let rules = [SubstitutionRule(pattern: "(\\w+)@(\\w+)", replacement: "$1 at $2", isRegex: true)]
    try assertEqual(applyRules(rules, to: "user@example"), "user at example")
}

test("Regex replace: word boundary for abbreviations") {
    let rules = [SubstitutionRule(pattern: "\\bDr\\.", replacement: "Doctor", isRegex: true)]
    try assertEqual(applyRules(rules, to: "Dr. Smith drove to the address"), "Doctor Smith drove to the address")
}

test("Regex replace: URL skipping") {
    let rules = [SubstitutionRule(pattern: "https?://\\S+", replacement: "link", isRegex: true)]
    let input = "Visit https://example.com/page for more info"
    try assertEqual(applyRules(rules, to: input), "Visit link for more info")
}

test("Regex replace: footnote bracket removal") {
    let rules = [SubstitutionRule(pattern: "\\[\\d+\\]", replacement: "", isRegex: true)]
    try assertEqual(applyRules(rules, to: "The theory[1] was proven[2] correct"), "The theory was proven correct")
}

test("Regex replace: case insensitive") {
    let rules = [SubstitutionRule(pattern: "\\betc\\.", replacement: "etcetera", isRegex: true, caseSensitive: false)]
    try assertEqual(applyRules(rules, to: "Things Etc. stuff"), "Things etcetera stuff")
}

test("Regex replace: case sensitive") {
    let rules = [SubstitutionRule(pattern: "\\bFoo\\b", replacement: "Bar", isRegex: true, caseSensitive: true)]
    try assertEqual(applyRules(rules, to: "Foo foo FOO"), "Bar foo FOO")
}

test("Regex replace: invalid pattern is skipped gracefully") {
    let rules = [SubstitutionRule(pattern: "[invalid", replacement: "x", isRegex: true)]
    // Invalid regex should be skipped, text unchanged
    try assertEqual(applyRules(rules, to: "hello"), "hello")
}

test("Regex replace: email address replacement") {
    let rules = [SubstitutionRule(pattern: "\\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}\\b", replacement: "email address", isRegex: true)]
    try assertEqual(applyRules(rules, to: "Contact john@example.com for info"), "Contact email address for info")
}

test("Regex replace: collapse whitespace") {
    let rules = [SubstitutionRule(pattern: "[ \\t]{3,}", replacement: "  ", isRegex: true)]
    try assertEqual(applyRules(rules, to: "too     much    space"), "too  much  space")
}

// --- Multiple rules ---
print("\n--- Text Substitution: Multiple Rules ---")

test("Multiple rules: applied in order") {
    let rules = [
        SubstitutionRule(pattern: "cat", replacement: "dog"),
        SubstitutionRule(pattern: "dog", replacement: "fish"),
    ]
    // "cat" → "dog" then "dog" → "fish"
    try assertEqual(applyRules(rules, to: "I have a cat"), "I have a fish")
}

test("Multiple rules: second rule only applies to result of first") {
    let rules = [
        SubstitutionRule(pattern: "\\bMr\\.", replacement: "Mister", isRegex: true),
        SubstitutionRule(pattern: "\\bDr\\.", replacement: "Doctor", isRegex: true),
    ]
    try assertEqual(applyRules(rules, to: "Mr. Smith and Dr. Jones"), "Mister Smith and Doctor Jones")
}

test("Multiple rules: disabled rules skipped") {
    let rules = [
        SubstitutionRule(pattern: "a", replacement: "b", isEnabled: true),
        SubstitutionRule(pattern: "b", replacement: "c", isEnabled: false),
    ]
    try assertEqual(applyRules(rules, to: "abc"), "bbc")
}

test("Multiple rules: mix of plain and regex") {
    let rules = [
        SubstitutionRule(pattern: "\u{2014}", replacement: " \u{2014} "),  // plain
        SubstitutionRule(pattern: "\\[\\d+\\]", replacement: "", isRegex: true),  // regex
    ]
    try assertEqual(applyRules(rules, to: "word\u{2014}word[1] more"), "word \u{2014} word more")
}

// --- Offset mapping ---
print("\n--- Text Substitution: Offset Mapping ---")

test("Offset map: identity when no substitutions") {
    let map = TestOffsetMap()
    try assertEqual(map.toOriginal(0), 0)
    try assertEqual(map.toOriginal(50), 50)
    try assertEqual(map.toModified(50), 50)
}

test("Offset map: single replacement shorter than original") {
    // "Dr. Smith" (9 chars) → "Doctor Smith" (12 chars)
    // "Dr." (3 chars) replaced with "Doctor" (6 chars), delta = 3 - 6 = -3
    // After replacement at modified pos 6, cumDelta = -3
    // Original offset 4 (S of Smith) → modified offset = 4 - (-3) = 7
    let map = TestOffsetMap(points: [(modifiedPos: 6, cumulativeDelta: -3)])
    // Before the replacement point, no shift
    try assertEqual(map.toOriginal(0), 0)
    // After the replacement, modified 7 → original 7 + (-3) = 4? No...
    // Actually: "Dr." is 3 chars in original, "Doctor" is 6 chars in modified
    // So modified offset 6 is right after "Doctor", original offset 3 is right after "Dr."
    // delta = originalLen - modifiedLen = 3 - 6 = -3
    // toOriginal(7) = 7 + (-3) = 4 ✓ (that's "S" in original "Dr. Smith")
    try assertEqual(map.toOriginal(7), 4)
}

test("Offset map: single deletion (skip)") {
    // "[1]foo" → "foo"
    // "[1]" (3 chars) replaced with "" (0 chars), delta = 3 - 0 = 3
    // After replacement at modified pos 0, cumDelta = 3
    let map = TestOffsetMap(points: [(modifiedPos: 0, cumulativeDelta: 3)])
    // Modified offset 0 → original offset 3 (start of "foo")
    try assertEqual(map.toOriginal(0), 3)
    try assertEqual(map.toOriginal(1), 4)
}

test("Offset map: multiple replacements") {
    // "a[1]b[2]c" → "abc"
    // First [1] at orig 1-3, removed: delta += 3
    // Second [2] at orig 5-7 (after first removal: mod 2-4), removed: delta += 3
    let map = TestOffsetMap(points: [
        (modifiedPos: 1, cumulativeDelta: 3),  // after removing [1]
        (modifiedPos: 2, cumulativeDelta: 6),  // after removing [2]
    ])
    try assertEqual(map.toOriginal(0), 0)  // "a"
    try assertEqual(map.toOriginal(1), 4)  // "b" (orig pos 4, after "[1]")
    try assertEqual(map.toOriginal(2), 8)  // "c" (orig pos 8, after "[2]")
}

// --- Default rules ---
print("\n--- Text Substitution: Default Rules ---")

test("Default rules: Mr. expansion") {
    let rules = [SubstitutionRule(name: "Mr.", pattern: "\\bMr\\.", replacement: "Mister", isRegex: true)]
    try assertEqual(applyRules(rules, to: "Mr. Jones arrived"), "Mister Jones arrived")
}

test("Default rules: Mrs. expansion") {
    let rules = [SubstitutionRule(name: "Mrs.", pattern: "\\bMrs\\.", replacement: "Missus", isRegex: true)]
    try assertEqual(applyRules(rules, to: "Mrs. Smith left"), "Missus Smith left")
}

test("Default rules: Dr. doesn't affect 'drive' or 'dress'") {
    let rules = [SubstitutionRule(name: "Dr.", pattern: "\\bDr\\.", replacement: "Doctor", isRegex: true)]
    let result = applyRules(rules, to: "Dr. Frankenstein drove to the address")
    try assertTrue(result.contains("Doctor Frankenstein"))
    try assertTrue(result.contains("drove"))
    try assertTrue(result.contains("address"))
}

test("Default rules: e.g. and i.e. expansion") {
    let rules = [
        SubstitutionRule(pattern: "\\be\\.g\\.", replacement: "for example", isRegex: true),
        SubstitutionRule(pattern: "\\bi\\.e\\.", replacement: "that is", isRegex: true),
    ]
    try assertEqual(applyRules(rules, to: "e.g. this and i.e. that"), "for example this and that is that")
}

test("Default rules: URL replacement") {
    let rules = [SubstitutionRule(pattern: "https?://\\S+", replacement: "link", isRegex: true)]
    let input = "See https://example.com and http://test.org/path?q=1"
    let result = applyRules(rules, to: input)
    try assertEqual(result, "See link and link")
}

test("Default rules: em dash spacing") {
    let rules = [SubstitutionRule(pattern: "\u{2014}", replacement: " \u{2014} ")]
    try assertEqual(applyRules(rules, to: "word\u{2014}word"), "word \u{2014} word")
}

// --- Performance ---
print("\n--- Text Substitution: Performance ---")

test("Performance: large text with many rules completes quickly") {
    // 50KB of text, 15 rules
    let paragraph = "Dr. Smith visited Mrs. Jones at the address[1] on Main St. for a meeting etc. about the project e.g. the new system i.e. version 2. See https://example.com for details.\n\n"
    let largeText = String(repeating: paragraph, count: 300) // ~50KB
    let rules: [SubstitutionRule] = [
        SubstitutionRule(pattern: "\\bDr\\.", replacement: "Doctor", isRegex: true),
        SubstitutionRule(pattern: "\\bMrs\\.", replacement: "Missus", isRegex: true),
        SubstitutionRule(pattern: "\\bSt\\.", replacement: "Street", isRegex: true),
        SubstitutionRule(pattern: "\\betc\\.", replacement: "etcetera", isRegex: true),
        SubstitutionRule(pattern: "\\be\\.g\\.", replacement: "for example", isRegex: true),
        SubstitutionRule(pattern: "\\bi\\.e\\.", replacement: "that is", isRegex: true),
        SubstitutionRule(pattern: "https?://\\S+", replacement: "link", isRegex: true),
        SubstitutionRule(pattern: "\\[\\d+\\]", replacement: "", isRegex: true),
        SubstitutionRule(pattern: "\u{2014}", replacement: " \u{2014} "),
        SubstitutionRule(pattern: "[ \\t]{3,}", replacement: "  ", isRegex: true),
    ]

    let start = Date()
    let result = applyRules(rules, to: largeText)
    let elapsed = Date().timeIntervalSince(start)

    try assertTrue(result.count > 0, "Should produce output")
    try assertTrue(!result.contains("Dr."), "Dr. should be expanded")
    try assertTrue(result.contains("Doctor"), "Should contain Doctor")
    try assertTrue(elapsed < 2.0, "Should complete in under 2 seconds, took \(elapsed)s")
    print("    50KB text, 10 rules: \(String(format: "%.3f", elapsed))s")
}

test("Performance: empty rules list is instant") {
    let largeText = String(repeating: "Hello world. ", count: 10000)
    let rules: [SubstitutionRule] = []
    let start = Date()
    let result = applyRules(rules, to: largeText)
    let elapsed = Date().timeIntervalSince(start)
    try assertEqual(result, largeText)
    try assertTrue(elapsed < 0.01, "Empty rules should be instant")
}

// --- Edge cases ---
print("\n--- Text Substitution: Edge Cases ---")

test("Edge case: overlapping matches handled correctly") {
    let rules = [SubstitutionRule(pattern: "aa", replacement: "b")]
    // "aaa" has overlapping "aa" at pos 0 and 1. Non-overlapping should give "ba"
    try assertEqual(applyRules(rules, to: "aaa"), "ba")
}

test("Edge case: replacement longer than original") {
    let rules = [SubstitutionRule(pattern: "x", replacement: "xyz")]
    try assertEqual(applyRules(rules, to: "axb"), "axyzb")
}

test("Edge case: replacement same length as original") {
    let rules = [SubstitutionRule(pattern: "cat", replacement: "dog")]
    try assertEqual(applyRules(rules, to: "cat"), "dog")
}

test("Edge case: empty text") {
    let rules = [SubstitutionRule(pattern: "x", replacement: "y")]
    try assertEqual(applyRules(rules, to: ""), "")
}

test("Edge case: unicode text") {
    let rules = [SubstitutionRule(pattern: "caf\u{00E9}", replacement: "coffee")]
    try assertEqual(applyRules(rules, to: "I went to the caf\u{00E9}"), "I went to the coffee")
}

test("Edge case: regex with no captures and group ref") {
    // $1 with no group should produce empty or literal
    let rules = [SubstitutionRule(pattern: "hello", replacement: "$0 world", isRegex: true)]
    try assertEqual(applyRules(rules, to: "say hello"), "say hello world")
}

test("Edge case: pronunciation-style replacement") {
    let rules = [SubstitutionRule(name: "Hermione", pattern: "\\bHermione\\b", replacement: "Her-MY-oh-nee", isRegex: true)]
    try assertEqual(applyRules(rules, to: "Hermione said hello"), "Her-MY-oh-nee said hello")
}

test("Edge case: multiple regex groups") {
    let rules = [SubstitutionRule(pattern: "(\\w+)\\s+(\\w+)", replacement: "$2 $1", isRegex: true)]
    try assertEqual(applyRules(rules, to: "hello world"), "world hello")
}

} // end runTextSubstitutionTests
