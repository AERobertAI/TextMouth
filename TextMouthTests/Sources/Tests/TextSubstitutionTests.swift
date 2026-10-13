import Foundation

@testable import TextMouth

/// Hosted-test adapter: every legacy substitution scenario is routed through
/// the dependency-injected production service instead of the historical copy.
func applyRules(_ rules: [SubstitutionRule], to text: String) -> String {
    MainActor.assumeIsolated {
        TextSubstitutionService(rules: rules).transform(text).modifiedText
    }
}

/// Preserve the legacy scenario syntax while exercising production OffsetMap.
struct TestOffsetMap {
    private let map: OffsetMap

    init(points: [(modifiedPos: Int, cumulativeDelta: Int)] = []) {
        map = OffsetMap(points: points.map {
            (targetPos: $0.modifiedPos, cumulativeDelta: $0.cumulativeDelta)
        })
    }

    func toOriginal(_ modified: Int) -> Int { map.toSource(modified) }
    func toModified(_ original: Int) -> Int { map.toTarget(original) }
}

@MainActor
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

print("\n--- Text Substitution: Whole Word ---")

// The OCR-pipe-to-I scenario the feature was added for: a book where
// every standalone "I" was misread as "|". The user wants to fix the
// pipes back to "I" without disturbing legitimate "|" usages elsewhere.
test("Whole word: pipe matches standalone but not when adjacent to letters") {
    let rules = [SubstitutionRule(pattern: "|", replacement: "I", wholeWord: true)]
    try assertEqual(
        applyRules(rules, to: "And |, who am | really?"),
        "And I, who am I really?",
        "Standalone pipes should be replaced"
    )
    try assertEqual(
        applyRules(rules, to: "code|with|pipes"),
        "code|with|pipes",
        "Pipes embedded between word characters must not match"
    )
}

test("Whole word: doubled pipes do match (each pipe has non-word neighbours)") {
    // Pipes are non-word characters, so each "|" in "||" has a non-word
    // neighbour on each side and DOES qualify as standalone under the
    // lookaround definition. Pinning this in a test so the behaviour
    // for non-word patterns is unambiguous — users picking wholeWord
    // for a non-word pattern get a "no letters/digits adjacent" rule,
    // not "isolated by whitespace" semantics.
    let rules = [SubstitutionRule(pattern: "|", replacement: "I", wholeWord: true)]
    try assertEqual(applyRules(rules, to: "||"), "II")
}

test("Whole word: cat does not match category") {
    let rules = [SubstitutionRule(pattern: "cat", replacement: "dog", wholeWord: true)]
    try assertEqual(applyRules(rules, to: "a cat sat in the category"), "a dog sat in the category")
}

test("Whole word: matches at start and end of string") {
    let r = SubstitutionRule(pattern: "I", replacement: "eye", caseSensitive: true, wholeWord: true)
    try assertEqual(applyRules([r], to: "I am here"), "eye am here", "Match at start of string")
    try assertEqual(applyRules([r], to: "here I am"), "here eye am", "Match in middle")
    try assertEqual(applyRules([r], to: "here am I"), "here am eye", "Match at end of string")
}

test("Whole word: case-insensitive by default") {
    let r = SubstitutionRule(pattern: "I", replacement: "eye", wholeWord: true)
    try assertEqual(applyRules([r], to: "i love I"), "eye love eye")
}

test("Whole word: case-sensitive when set") {
    let r = SubstitutionRule(pattern: "I", replacement: "eye", caseSensitive: true, wholeWord: true)
    try assertEqual(applyRules([r], to: "i love I"), "i love eye", "Lowercase i must not match")
}

test("Whole word: empty replacement deletes the matched word") {
    let r = SubstitutionRule(pattern: "umm", replacement: "", wholeWord: true)
    try assertEqual(applyRules([r], to: "well, umm, yes"), "well, , yes")
    try assertEqual(applyRules([r], to: "summer"), "summer", "Substring inside another word must remain")
}

test("Whole word: surrounded by punctuation matches") {
    let r = SubstitutionRule(pattern: "TBD", replacement: "to be done", caseSensitive: true, wholeWord: true)
    try assertEqual(applyRules([r], to: "[TBD] handle later"), "[to be done] handle later")
    try assertEqual(applyRules([r], to: "(TBD)."), "(to be done).")
}

test("Whole word: pattern with regex metacharacters is treated literally") {
    // "Mr." contains a regex metacharacter (".") — wholeWord must escape
    // the pattern so the dot doesn't accidentally match any character.
    let r = SubstitutionRule(pattern: "Mr.", replacement: "Mister", wholeWord: true)
    try assertEqual(applyRules([r], to: "Mr. Smith"), "Mister Smith")
    try assertEqual(applyRules([r], to: "MrX Smith"), "MrX Smith", "Regex dot must NOT match X")
}

test("Whole word: replacement with $ is taken literally") {
    // $1 in the replacement must NOT be interpreted as a capture-group
    // back-reference (the wholeWord path uses NSRegularExpression's
    // template engine internally, but escaped templates must be literal).
    let r = SubstitutionRule(pattern: "money", replacement: "$1 dollars", wholeWord: true)
    try assertEqual(applyRules([r], to: "got money today"), "got $1 dollars today")
}

test("Whole word: ignored when isRegex is true") {
    // wholeWord stored alongside isRegex must NOT silently apply
    // boundaries — the user enabled regex precisely so they could
    // express their own boundaries (or not).
    let r = SubstitutionRule(pattern: "cat", replacement: "dog", isRegex: true, wholeWord: true)
    try assertEqual(applyRules([r], to: "category"), "dogegory",
                    "When isRegex is true, wholeWord should be ignored — substring match applies")
    try assertTrue(!r.isWholeWordEffective, "isWholeWordEffective should be false when isRegex is on")
}

test("Whole word: ignored when pattern contains whitespace") {
    let r = SubstitutionRule(pattern: "hello world", replacement: "greeting", wholeWord: true)
    try assertEqual(applyRules([r], to: "hello worlds unite"), "greetings unite",
                    "When the pattern contains whitespace, wholeWord should be ignored — substring match applies")
    try assertTrue(!r.isWholeWordEffective, "isWholeWordEffective should be false when pattern has whitespace")
}

test("Whole word: tab in pattern also disables the whole-word predicate") {
    let r = SubstitutionRule(pattern: "a\tb", replacement: "x", wholeWord: true)
    try assertTrue(!r.isWholeWordEffective, "Tab must count as whitespace for the predicate")
}

test("Whole word: empty pattern is not effective") {
    let r = SubstitutionRule(pattern: "", replacement: "x", wholeWord: true)
    try assertTrue(!r.isWholeWordEffective)
}

test("Whole word: Unicode letter is treated as a word character") {
    // \p{L} covers accented Latin letters, so "I" inside "naïve" must
    // not match — the î to its right is a letter neighbour.
    let r = SubstitutionRule(pattern: "I", replacement: "eye", caseSensitive: true, wholeWord: true)
    try assertEqual(applyRules([r], to: "naïve I am"), "naïve eye am",
                    "I attached to ï counts as a word neighbour and must not match; standalone I must")
}

test("Whole word: Unicode digit blocks the boundary") {
    let r = SubstitutionRule(pattern: "id", replacement: "identifier", wholeWord: true)
    try assertEqual(applyRules([r], to: "id 42"), "identifier 42")
    try assertEqual(applyRules([r], to: "id1234"), "id1234", "Digit after must block whole-word match")
}

test("Whole word: underscore counts as a word character") {
    let r = SubstitutionRule(pattern: "var", replacement: "variable", wholeWord: true)
    try assertEqual(applyRules([r], to: "var x"), "variable x")
    try assertEqual(applyRules([r], to: "var_name"), "var_name", "Underscore after must block whole-word match")
}

test("Whole word: multiple matches in a single string") {
    let r = SubstitutionRule(pattern: "I", replacement: "eye", caseSensitive: true, wholeWord: true)
    try assertEqual(applyRules([r], to: "I and I and I"), "eye and eye and eye")
}

test("Whole word: rule still respects isEnabled=false") {
    let r = SubstitutionRule(pattern: "cat", replacement: "dog", isEnabled: false, wholeWord: true)
    try assertEqual(applyRules([r], to: "a cat sat"), "a cat sat")
}

test("Whole word: emoji-adjacent text does not crash on grapheme/UTF-16 mismatch") {
    // NSRegularExpression returns UTF-16-indexed ranges. The naive
    // `String.index(_:offsetBy:)` walk treats the NSRange as Character
    // offsets, which traps when the difference matters (text contains
    // emoji or other surrogate-pair characters whose grapheme count
    // diverges from the UTF-16 unit count). Production and the test
    // mock both convert via Range(_:in:); these cases exercise the
    // conversion across "before-the-match" and "match-near-end-of-string"
    // shapes so a regression in either would show up.
    let r = SubstitutionRule(pattern: "cat", replacement: "dog", wholeWord: true)

    // Match starts past several emoji — UTF-16 location > character count.
    // Without the fix this either produces wrong slicing or traps on the
    // index-out-of-bounds precondition.
    try assertEqual(applyRules([r], to: "🙂🙂🙂 cat"), "🙂🙂🙂 dog")
    try assertEqual(applyRules([r], to: "🙂 cat sat"), "🙂 dog sat")
    try assertEqual(applyRules([r], to: "🙂cat"), "🙂dog",
                    "Emoji to the left of the word — emoji is non-letter, so wholeWord should match")
    try assertEqual(applyRules([r], to: "cat 🙂"), "dog 🙂")
    // Match where the end runs to the very last UTF-16 unit.
    try assertEqual(applyRules([r], to: "🙂🙂cat"), "🙂🙂dog")
}

test("Whole word: combining mark anchors the diacritic to its base") {
    // U+0301 (combining acute) attached to a preceding letter — the
    // base+mark pair is one user-perceived "word character". A pattern
    // match that ends just before the combining mark would orphan it,
    // so \p{M} must be in the right-side word class.
    let r = SubstitutionRule(pattern: "cafe", replacement: "coffee", caseSensitive: true, wholeWord: true)
    let withCombining = "cafe\u{0301}"  // grapheme: café (e + combining acute)
    try assertEqual(applyRules([r], to: withCombining), withCombining,
                    "Pattern 'cafe' must NOT match when followed by a combining mark")
    // Plain "cafe" with no following mark still matches
    try assertEqual(applyRules([r], to: "cafe today"), "coffee today")
}

test("Regex: emoji-adjacent text does not crash on grapheme/UTF-16 mismatch") {
    // Same fix applies to the regex path. Pre-existing bug — added a
    // covering test now that it's been hardened.
    let r = SubstitutionRule(pattern: "cat", replacement: "dog", isRegex: true)
    try assertEqual(applyRules([r], to: "🙂 cat sat"), "🙂 dog sat")
    try assertEqual(applyRules([r], to: "cat 🙂"), "dog 🙂")
}

print("\n--- Text Substitution: Whole Word — Persistence ---")

test("Whole word: JSON round-trip preserves the field") {
    let rule = SubstitutionRule(pattern: "|", replacement: "I", wholeWord: true)
    let data = try JSONEncoder().encode(rule)
    let decoded = try JSONDecoder().decode(SubstitutionRule.self, from: data)
    try assertTrue(decoded.wholeWord, "wholeWord must round-trip through JSON")
    try assertEqual(decoded.pattern, "|")
    try assertEqual(decoded.replacement, "I")
}

test("Whole word: legacy JSON without the field decodes as false") {
    // Prior versions wrote rule files without `wholeWord`. Decoding
    // such a file must succeed and default the new field to false.
    let id = UUID().uuidString
    let legacyJSON = """
    {
        "id": "\(id)",
        "name": "Hermione",
        "pattern": "Hermione",
        "replacement": "Her-MY-oh-nee",
        "isRegex": false,
        "isEnabled": true,
        "caseSensitive": false
    }
    """
    let decoded = try JSONDecoder().decode(SubstitutionRule.self, from: legacyJSON.data(using: .utf8)!)
    try assertTrue(!decoded.wholeWord, "Missing key must default to false")
    try assertEqual(decoded.pattern, "Hermione")
    try assertEqual(decoded.name, "Hermione")
}

test("Whole word: array of rules with mixed wholeWord round-trips") {
    let rules = [
        SubstitutionRule(pattern: "cat", replacement: "dog"),
        SubstitutionRule(pattern: "I", replacement: "eye", wholeWord: true),
        SubstitutionRule(pattern: "Mr.", replacement: "Mister", isRegex: true),
    ]
    let data = try JSONEncoder().encode(rules)
    let decoded = try JSONDecoder().decode([SubstitutionRule].self, from: data)
    try assertEqual(decoded.count, 3)
    try assertTrue(!decoded[0].wholeWord)
    try assertTrue(decoded[1].wholeWord)
    try assertTrue(!decoded[2].wholeWord, "Regex rule's stored wholeWord round-trips as-is")
}

print("\n--- Text Substitution: Whole Word — isWholeWordEffective Predicate ---")

// The same predicate is consulted by the matcher, the editor UI (to
// hide the toggle), the rule row badge, and the accessibility label.
// These tests pin down the truth table so all four call sites stay in
// sync if the predicate ever needs to change.

test("Predicate: plain rule with simple pattern → effective") {
    let r = SubstitutionRule(pattern: "cat", wholeWord: true)
    try assertTrue(r.isWholeWordEffective)
}

test("Predicate: wholeWord=false → not effective") {
    let r = SubstitutionRule(pattern: "cat", wholeWord: false)
    try assertTrue(!r.isWholeWordEffective)
}

test("Predicate: isRegex=true → not effective") {
    let r = SubstitutionRule(pattern: "cat", isRegex: true, wholeWord: true)
    try assertTrue(!r.isWholeWordEffective)
}

test("Predicate: pattern with space → not effective") {
    let r = SubstitutionRule(pattern: "hello world", wholeWord: true)
    try assertTrue(!r.isWholeWordEffective)
}

test("Predicate: empty pattern → not effective") {
    let r = SubstitutionRule(pattern: "", wholeWord: true)
    try assertTrue(!r.isWholeWordEffective)
}

test("Predicate: pattern of only whitespace → not effective") {
    let r = SubstitutionRule(pattern: "   ", wholeWord: true)
    try assertTrue(!r.isWholeWordEffective)
}

} // end runTextSubstitutionTests
