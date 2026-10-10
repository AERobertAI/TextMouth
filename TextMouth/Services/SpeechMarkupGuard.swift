import Foundation

/// Keeps the Mac's speech engine from reading tag-shaped text as markup.
///
/// TextMouth never sends SSML: every utterance is made with
/// `AVSpeechUtterance(string:)`. Even so, the speech engine of macOS 26.3.1
/// scans that plain string for tags, and a book can hold some: *Rainbows
/// End* marks its silent messages `<sm>…</sm>`, which the text cache keeps
/// as the Markdown escapes `\<sm\>` and the parser gives back as text.
/// What the engine then does was measured offline, with
/// `AVSpeechSynthesizer.write(_:toBufferCallback:)` in the compact Samantha
/// voice, which renders audio and plays nothing (the frames each text
/// produced are given; `SpeechMarkupGuardTests` renders the same way):
///
/// - A closing tag with no opening tag before it in the same utterance is
///   refused: "could recruit, Alfred?</sm> Alfred didn't reply directly."
///   was cancelled with 0 frames, before its first word. So were `</ >` and
///   `< /sm>`, since the engine's own closing-tag pattern,
///   `^<\s*\/\s*(?<name>[^<>\/]*)\s*>`, allows spaces and an empty name,
///   and a closing tag broken by a line break. Direct speech cuts a chapter
///   into chunks of about 5,000 UTF-16 units (`DirectSpeechChunk`), so a
///   chunk can begin after a book's opening tag and hold only its closing
///   tag. After one refusal the same synthesizer never speaks again: a
///   plain text on it waited 10 s for nothing, while a fresh instance spoke
///   it at once (`SpeechService` replaces its synthesizer for that reason).
/// - An opening tag with no closing tag swallows everything after it:
///   "Mitsuri: <sm>In fact, I'm in my office." rendered 14,174 frames
///   against 153,179 for the same words without the tag. A single name
///   between spaced brackets counts as a tag too: "x < y > z …" rendered
///   9,659 frames against 110,774 without the brackets, and so did
///   "x < 5 > y …", `see < a href="x" > here …`, and "x << 2 >> 1 …".
///   So did every other name of characters other than brackets, spaces,
///   and slashes measured on October 7, and no name at all, in a sentence
///   of 145,418 frames, which each of these cut to 46,602 or fewer, in the
///   legacy Alex voice too: `<...>`, `<=>`, `<->`, `<$fh>`, `<*>`, `<#>`,
///   `<@reader>`, `<=x>`, `<a=b>`, `<"x">`, `<\>`, `<!>`, `<?>`, `<>`,
///   `< >`, and "a <> b". The one exception was an emoji alone, `<🙂>`,
///   spoken in full, brackets and all, as if the engine read the emoji's
///   name, words with spaces, in its place
///   (`Scripts/agents/probes/speech-markup-probe-shapes.swift` holds every
///   result).
/// - Balanced tags are read as markup: the words between them are spoken
///   and the tags are silent.
/// - Brackets that are not tag-shaped are spoken, as "less than" and
///   "greater than": "x < y and y > z, so 3 < 4. …" rendered 175,547 frames,
///   more than the same text without them, as did "a <= b and c >= d …",
///   "a<b and c>d …", "see <a b c> here …", "see <a b> here …", and
///   "x <- 5 and y > 2 …". Only `name=value` attributes make a bracketed
///   run with more than one word a tag: `<-- aside -->`, `<x y=1 z>`, and
///   `Map<String, Int>` were spoken in full. A slash inside the name ends
///   it too: `<a/b>` and `<https://example.com/page>` were spoken.
/// - The ampersand never stopped or swallowed anything, bare or in an
///   entity: the engine speaks `&amp;` as "and", and a `&lt;sm&gt;` it
///   decodes is spoken, never taken as a tag. The guard leaves it alone.
/// - A NUL character (U+0000) ends the text for the engine: every word
///   after it is dropped, silently, with no cancel that `SpeechService`
///   could hear as a refusal (board #1542). "The reader went on with the
///   story a<NUL>b and every word after it …" rendered 39,434 frames
///   against 150,282 without the NUL, and 151,050 with a space in its
///   place. Every other control character was spoken in full: C0 (U+0001
///   to U+001F, tab and line breaks among them), DEL, and C1 (U+0080 to
///   U+009F); in the legacy Alex voice nothing was lost, the NUL included
///   (`Scripts/agents/probes/speech-control-character-probe.swift` holds
///   every result, of October 10, 2026). The guard turns each NUL into a
///   space.
///
/// The guard replaces the two brackets of every tag-shaped run with the
/// single angle quotation marks U+2039 and U+203A, which the engine does
/// not read as markup: the brackets fall silent, and the words between
/// them and a tag's name are spoken ("sm"). "write a ‹sm› message …"
/// rendered 120,477 frames, exactly as "write a sm message …" did, and the
/// refused chunk above rendered 170,197 frames once guarded. A zero-width
/// space after `<`, or an entity such as `&lt;`, would have the engine
/// spell the markup out ("less than, slash, s, m"), which nobody wants.
///
/// Each replacement is one UTF-16 unit for one, so the guarded text has
/// exactly the length of its original, and nothing else in it moves: the
/// range of every word the synthesizer reports, every chunk boundary, and
/// every offset the frame map of rendered audio counts, remains an offset
/// into the original text.
enum SpeechMarkupGuard {
    /// What the opening bracket of a tag-shaped run becomes: the single
    /// left-pointing angle quotation mark, one UTF-16 unit like `<`.
    static let openingBracketReplacement = "\u{2039}"

    /// What its closing bracket becomes: the single right-pointing angle
    /// quotation mark, one UTF-16 unit like `>`.
    static let closingBracketReplacement = "\u{203A}"

    /// A tag-shaped run, from its `<` to its `>`, as the engine takes one.
    /// Neither bracket occurs inside, so runs never overlap, and a `<` with
    /// no `>` after it before the next `<` is no run at all. The run is one
    /// of:
    /// - a closing tag: optional spaces, a slash, then anything, since the
    ///   engine's own closing pattern allows spaces before and after the
    ///   slash and an empty name (`</sm>`, `</ >`, `< /sm>`, `</>`);
    /// - a declaration, comment, or processing instruction, which begins
    ///   with `!` or `?` (`<!DOCTYPE html>`, `<!-- -->`, `<?xml ?>`). The
    ///   engine spoke the longer ones as text, but `<!>` and `<?>` swallowed
    ///   what followed; the guard silences all their brackets, as it did
    ///   before, which spares a listener "less than" around markup;
    /// - an opening tag: optional spaces, a name of any characters other
    ///   than brackets, spaces, and slashes, then only `name=value`
    ///   attributes, with the value in double quotes, in single quotes, or
    ///   bare, and an optional self-closing slash (`<sm>`, `< sm >`, `<5>`,
    ///   `<...>`, `<=x>`, `<a href="x">`, `<td colspan=2>`, `<br/>`,
    ///   `<br />`). Bare words after the name make no tag, as they make none
    ///   for the engine, so "x < y and y > z", "a<b and c>d", `<a b c>`, and
    ///   `<-- aside -->` are left alone and spoken, and neither does a slash
    ///   inside the name (`<a/b>`, `<https://example.com/page>`). An emoji
    ///   alone between brackets, which the engine spoke, is taken for a tag
    ///   too: guarding it only silences its brackets;
    /// - an empty tag: only spaces between the brackets (`<>`, `< >`).
    ///
    /// The empty tag is its own alternative, and the self-closing slash
    /// brings its own spaces (`\s*(?:/\s*)?`), so that no two runs of
    /// spaces in the pattern can trade spaces: a `<` followed by a long run
    /// of spaces and no `>` is given up in time linear in the run.
    static let tagPattern = #"""
        <(?:\s*/[^<>]*|[!?][^<>]*|\s*[^<>\s/]+(?:\s+[^<>\s/=]+\s*=\s*(?:"[^"<>]*"|'[^'<>]*'|[^<>\s"']+))*\s*(?:/\s*)?|\s*)>
        """#

    /// `tagPattern`, compiled once. The pattern is a constant that this
    /// file's tests exercise, so compiling it cannot fail.
    private static let tagExpression = try! NSRegularExpression(pattern: tagPattern, options: [])

    /// The UTF-16 unit of `<`, which every tag-shaped run begins with.
    private static let lessThan: UInt16 = 0x3C

    /// The UTF-16 unit of `>`, which every tag-shaped run ends with.
    private static let greaterThan: UInt16 = 0x3E

    /// `openingBracketReplacement` and `closingBracketReplacement` as the
    /// single UTF-16 units they are.
    private static let openingReplacementUnit: UInt16 = 0x2039
    private static let closingReplacementUnit: UInt16 = 0x203A

    /// What a NUL character becomes: a space, one UTF-16 unit like it.
    static let nulReplacement = " "

    /// The UTF-16 unit of the NUL character, U+0000, which ends the text
    /// for the speech engine.
    private static let nulUnit: UInt16 = 0x0000

    /// `nulReplacement` as the single UTF-16 unit it is.
    private static let nulReplacementUnit: UInt16 = 0x0020

    /// The ranges of the tag-shaped runs in `text`, in UTF-16 units as
    /// `NSRange` counts them, in text order; each begins with the run's `<`
    /// and ends with its `>`.
    static func tagRanges(in text: String) -> [NSRange] {
        // Most text holds no "<" at all: nothing to scan for.
        guard text.utf16.contains(lessThan) else { return [] }
        let whole = NSRange(location: 0, length: text.utf16.count)
        return tagExpression.matches(in: text, options: [], range: whole).map(\.range)
    }

    /// `text` with the brackets of every tag-shaped run replaced by the
    /// angle quotation marks and every NUL character by a space, and nothing
    /// else changed; `text` itself when it holds neither. The result has
    /// exactly the UTF-16 length of `text`, so every offset into it is an
    /// offset into `text`.
    static func neutralized(_ text: String) -> String {
        replacingNULs(in: neutralizingTags(in: text))
    }

    /// `text` with the brackets of every tag-shaped run replaced by the
    /// angle quotation marks, and nothing else changed; `text` itself when
    /// it holds no such run.
    private static func neutralizingTags(in text: String) -> String {
        let ranges = tagRanges(in: text)
        guard !ranges.isEmpty else { return text }
        let guarded = NSMutableString(string: text)
        for range in ranges {
            // The run's first unit is its "<" and its last its ">"; the
            // pattern admits neither inside. One unit replaces one, so the
            // ranges found before the replacements still hold after them.
            guarded.replaceCharacters(
                in: NSRange(location: range.location, length: 1),
                with: openingBracketReplacement
            )
            guarded.replaceCharacters(
                in: NSRange(location: NSMaxRange(range) - 1, length: 1),
                with: closingBracketReplacement
            )
        }
        return guarded as String
    }

    /// `text` with every NUL character (U+0000) replaced by a space, one
    /// UTF-16 unit for one, and nothing else changed; `text` itself when it
    /// holds none, as nearly every text does.
    private static func replacingNULs(in text: String) -> String {
        guard text.utf16.contains(nulUnit) else { return text }
        let units = text.utf16.map { $0 == nulUnit ? nulReplacementUnit : $0 }
        // A NUL and a space are single units outside the surrogate range,
        // so replacing one never splits a character.
        return String(decoding: units, as: UTF16.self)
    }

    // MARK: - The strict guard

    /// `text` with every `<` and `>` replaced by the angle quotation marks,
    /// tag-shaped or not, and every NUL by a space, as `neutralized(_:)`
    /// replaces it, one UTF-16 unit for one, and nothing else changed, so it
    /// has exactly the length of `text`.
    ///
    /// For text the engine refused although `neutralized(_:)` had guarded
    /// it, which only a shape this guard does not know could make it do:
    /// with no bracket left, the engine finds no markup to parse at all.
    /// The price is that a lone "less than" or "greater than", which the
    /// engine would speak, is silent in that text; `SpeechService` pays it
    /// only for the rest of a chunk the engine refused, and speaks every
    /// other chunk through `neutralized(_:)`.
    ///
    /// The ampersand stays. The engine reads character entities (`&amp;`
    /// was spoken as "and"), but no text with an ampersand, bare or in an
    /// entity, with or without tags beside it, was refused or lost a word in
    /// the October 7 probes (`Scripts/agents/probes/speech-markup-probe-shapes.swift`),
    /// while a bare `&`, spoken as "and", fell silent as U+FF06 or U+FE60.
    static func neutralizedStrictly(_ text: String) -> String {
        neutralized(text, strictlyWithin: 0..<text.utf16.count)
    }

    /// `text` guarded by `neutralized(_:)`, and within `strictRange`, in
    /// UTF-16 offsets into `text`, by `neutralizedStrictly(_:)` as well:
    /// every bracket there replaced, every other unit left as it is. The
    /// part of `strictRange` outside `text` is ignored, so a caller may give
    /// a range that begins before `text` or ends after it. The result has
    /// exactly the length of `text`.
    ///
    /// The strict part may begin or end anywhere, even inside a tag-shaped
    /// run: both guards put the same mark in place of a bracket, so where
    /// both touch one they agree.
    static func neutralized(_ text: String, strictlyWithin strictRange: Range<Int>) -> String {
        let guarded = neutralized(text)
        // The strict part that lies in `text`; none when the range misses
        // it, as it does for every chunk after a refused one.
        let lower = max(0, strictRange.lowerBound)
        let upper = min(guarded.utf16.count, strictRange.upperBound)
        guard lower < upper else { return guarded }
        var units = Array(guarded.utf16)
        var changed = false
        for index in lower..<upper {
            switch units[index] {
            case lessThan:
                units[index] = openingReplacementUnit
                changed = true
            case greaterThan:
                units[index] = closingReplacementUnit
                changed = true
            default:
                break
            }
        }
        // Brackets and their marks are single units outside the surrogate
        // range, so replacing them never splits a character.
        return changed ? String(decoding: units, as: UTF16.self) : guarded
    }
}
